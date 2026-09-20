# omarcal — plan

A CalDAV calendar widget for the Omarchy shell that talks to the server
directly instead of going through Evolution Data Server.

Status: **the read backend is complete.** Every command the UI needs is
implemented and measured against a real iCloud account. Nothing is wired to
QML yet.

---

## Why not use the existing plugin

`sirwizardlizard.calendar` (9,462 lines, 59 commits) is a QML front-end over
Evolution Data Server. It is carefully written — it has connect timeouts,
deadline budgets threaded through the pull path, `CALDAV_SYNC_SECONDS = 45.0`,
paging and byte caps. It still hangs, and the reason is structural rather than
sloppy:

```python
client = modules.ECal.Client.connect_sync(source, ..., 10, None)
```

That `10` is `wait_for_connected_seconds`. It waits for the backend to report
connected; it does not abort the underlying D-Bus call. When an EDS backend is
wedged the timeout is decorative. **A correct timeout cannot be written on top
of EDS**, so no amount of care in the plugin fixes it.

Measured on this account (13 collections, 3 of them VEVENT calendars):

| | EDS | direct CalDAV |
|---|---|---|
| Birthdays (174 objects) | 182 cached, ok | 1.4s |
| Personal (648 objects) | ~60s to connect, then ok | 4.6s |
| Family (3,098 objects) | **never completes**, wedges the backend | **20.9s** |
| All three, cold | — | **27.7s** |
| All three, warm | — | **1.5s** |

A wedged EDS backend also blocks *every other calendar* until its factory
service is restarted by hand, which is why the widget showed nothing at all
rather than showing the two calendars that were fine.

## Architecture

```
BarWidget.qml  ──▶  Service.qml  ──▶  helper/omarcal-helper  ──▶  iCloud
   clock            IPC, polling        CalDAV over HTTP         CalDAV
                                        libical for parsing
                                        SQLite cache
```

Three deliberate choices:

1. **Plain HTTP, not EDS.** `urllib` with an explicit socket timeout on every
   request. A slow server degrades to "this calendar didn't load", never to a
   hung widget.
2. **libical (`ICalGLib-4.0`) for parsing and recurrence.** Owned by the
   standalone `libical` package — `pactree -r libical` shows EDS depends on
   libical, not the reverse, and it is already installed via `bluez-obex`.
   `Component.foreach_recurrence()` honours RRULE, RDATE and EXDATE and clips
   to a window, verified. **Zero pip dependencies**, which keeps the
   marketplace security baseline clean (it flags pip/pacman installs as
   `package-manager`, review-required — see the omedia-controls notes).
3. **Span index.** Every object stores `first_start`, `last_end` and
   `open_ended` at sync time, so a window query discards most objects in SQL
   before parsing. Measured: a month query parses 161 of 3,920 objects,
   **0.04s instead of 2.43s**.

## What is built

`helper/omarcal-helper` — the complete read backend. Every command prints one
JSON object and exits 0; failures are reported inside it, so the QML side
always has something to parse.

| command | does |
|---|---|
| `login --user U` | store the password, discover and register calendars |
| `calendars` | the calendar list with colour, visibility, read-only, counts |
| `set-calendar --calendar C` | colour / visibility / rename |
| `sync [--calendar C] [--force]` | incremental pull, all calendars in parallel |
| `events --from --to [--only C]` | occurrences in a window |
| `event --uid U [--rid R]` | one event: description, attendees, alarms, rrule, meeting link, etag |
| `search --query Q` | title match, recurring hits projected to the next occurrence |
| `agenda [--days N]` | what is coming up |
| `status` | health, last sync, per-calendar errors, cache size |
| `settings [--set k=v]` | UI preferences |
| `watch [--interval S]` | refresh loop, one JSON line per change |

### Measured (3 calendars, 3,921 objects)

| | time |
|---|---|
| cold sync | **9.3s** |
| warm sync (ctag unchanged) | **0.7s**, zero REPORTs |
| forced full resync | 11.3s |
| month window | **0.04s** (parses 162 of 3,921) |
| 3-year window, 2,991 occurrences | 0.5s |

Efficiency comes from four things: pooled keep-alive HTTPS connections
(cold sync was 27.7s with a handshake per request), calendars and multiget
batches running in parallel on one bounded pool, the ctag short-circuit that
skips an unchanged calendar entirely, and the span index that discards
objects in SQL before parsing.

Credentials live in the login keyring under `org.omarchy.omarcal`, put there
by `login`. **`login` deliberately does not store when `OMARCAL_PASSWORD` is
set** — that variable exists so testing can borrow a password without writing
to the keyring, and it means a session spent testing that way leaves the
plugin with no credential of its own. The symptom is `no stored password for
<account>` in the panel while the month still draws, because reads come from
the cache and only the sync needs the server:

```bash
printf '%s' '<app-specific-password>' | ./helper/omarcal-helper login --user <apple-id>
```

### iCloud quirks already handled

- Discovery redirects to a per-account host (`pNN-caldav.icloud.com`); follow
  it and use the returned `calendar-home-set` verbatim.
- **A wrong password comes back 403 at the principal lookup, not 401.** Both
  are treated as an auth failure.
- **`login` reads one line from stdin, not to EOF.** A QML `Process` has no
  way to close stdin, so reading to EOF hangs the helper forever and the form
  sits on "Saving…".
- **iCloud ignores `<c:calendar-data/>` inside `sync-collection`** and answers
  with etags only. Bodies must come from a separate `calendar-multiget`. This
  is the single biggest gotcha in the protocol work.
- `<d:limit><d:nresults>` in `sync-collection` is ignored.
- `resourcetype` on a `Depth: 0` PROPFIND of a calendar returns only
  `<collection/>`; the `<calendar/>` type appears on the `Depth: 1` listing of
  the home collection. Discover from the home, not per-calendar.
- Apple writes alarm sounds as `ATTACH;VALUE=URI:Basso`, which is not a URI.
  It makes glib log `g_uri_join_internal` assertions; harmless, ignore it.

## What is not built

### Next — finish the read path
- [x] Local timezone rendering — timed events emit local ISO with offset,
      verified against `DTSTART;TZID=America/Chicago` in the source data
- [x] All-day events emit a bare date (`2026-09-22`), never an instant.
      Converting an all-day event to local time lands it on the previous day
      west of UTC; this was live before the fix.
- [x] Multi-day spans resolved as **correct overlap**, not a clipping bug
      (a 9-day novena legitimately appears in a 3-day window)
- [x] Per-calendar error isolation in the JSON envelope. `status` carries an
      `error` per calendar, and the sidebar names a failed one in red without
      the others noticing.
- [x] Background refresh loop + ctag short-circuit. The service syncs on the
      interval `refreshMinutes` asks for, with a one-minute floor; a calendar
      whose ctag has not moved is skipped before the etag REPORT is even
      sent, and reports itself as `skipped`.
- [x] Vacuum on removal. A hard cache cap is not meaningful for a calendar —
      there is nothing safe to evict while the events are still wanted — but a
      removed account or forgotten calendar genuinely frees pages, and sqlite
      does not hand them back until told.

### Then — the QML layer
- [x] `Logic.js` — month grid, day bucketing, all-day band lanes, timed
      overlap lanes, formatting. 58 tests (`./test/all`), including 11 run
      against a real month pulled from iCloud.
- [x] `BarWidget.qml` — the bar clock. Default face is
      `Saturday, September 19, 2026 • 08:15:34 PM`, pinned by tst_format.qml.
      Ticks at `SystemClock.Seconds`.
- [x] `Service.qml` — runs the helper, per-calendar errors surfaced, refresh
      on the interval `refreshMinutes` asks for; a slow sync leaves the last
      events on screen.
- [x] `Panel.qml` — month view: six-by-seven grid, all-day bars spanning the
      days they cover, timed chips, selected-day list, `[` `]` `t` and arrow
      keys. A calendar list sits to its left under the title **Omarcal**,
      each entry a coloured swatch that toggles that calendar's visibility.
      The list is headed by the provider it comes from (`Logic.providerName`
      maps the server to "iCloud", "Fastmail", … and falls back to the host)
      with the account beneath it. The column is headed by the same
      `PanelHero` omedia uses — glyph, title over a letter-spaced meta line,
      trailing action — over a scrolling list and an "Add calendar" footer
      pinned to the bottom of the card.

**UI conventions are omedia-controls', copied rather than reinvented**: every
control is `qs.Ui`'s `Button` with `bordered: true`; colour and family come
from the bar (`root.foreground`, `root.fontFamily`); rules are 2px through a
local `Rule` alias over `PanelSeparator`; headers are `PanelHero`; spacing is
`Style.spacing.md` almost everywhere (omedia uses it for 17 of its 17 layout
gaps), except around a rule, which is set off on both sides by
`Style.spacing.popupPadding` — what `KeyboardPanel` pads the card by — so a
header reads as a band of even depth; list rows follow omedia's library row —
a `BorderSurface` with `Style.selectedFillFor` when selected,
`Style.normalFillFor` on hover, a `Border.controlSpec` outline, a leading
glyph and a second label line that hides when empty; icon buttons are square via `root.controlSize`, and text buttons take
the same height so a row shares one baseline; **anything that scrolls goes
through the local `Scroller`**, a Flickable whose viewport reaches one
`ruleGap` past its own `contentWidth` so the scrollbar rides in the padding
beside the column instead of over the last few pixels of it. Reach for what omedia already
does before inventing anything here.

**One thing the kit could not supply**: `Picker`, a local dropdown. qs.Ui's
`Dropdown` sizes its popup by hand — every row, plus the gaps, plus `xxs` —
and then pays the border and hairline padding out of that same total, so its
list comes out `xxs - 2 * (1 + hairline)` short of its own content: two
pixels on this theme, whatever the row height or option count. The last row
is clipped, hovering it sets the ListView's currentIndex, the view scrolls to
contain it and every row jumps under the pointer. No caller can size its way
out of it. `Picker` has no arithmetic to get wrong: a Column of rows in a
Popup that takes its height from them, so the list always fits and a list
that cannot scroll cannot jump. The trigger is still the kit's, down to the
fill and border states.

**One grammar for events**: a **bar** is an all-day event, a **dot** is one
with a time. The month already read that way — bars spanning the days they
cover, dotted chips for appointments — so the day column and the viewer say
it the same way instead of marking everything alike. A bar runs the height of
what it marks and grows with a title that wraps; a dot sits on the line it
marks, measured off a hidden probe of that line's font rather than guessed
from a pixel size. A calendar's own colour is a bar too, in the account
form's list, so a block of colour on this card always means the same thing —
the sidebar list marks a calendar with a checkbox instead, because there the
colour is not what is being chosen.

**One deliberate departure**: the calendar list. Its rows sit twice omedia's
`space(2)` apart and a selected one is filled with *its own* colour at 20%
rather than the theme accent. omedia's library lists one kind of thing, so
one accent is right there; this lists several calendars that are already
told apart by colour everywhere else in the card, and the fill is the
quickest way to read which is which. The selected day is a matching column on
      the right: weekday, date, count, then each event as time over title
      with the calendar's colour as a rule. The grid is left-aligned, ruled
      top and bottom per cell, weekends on a lighter ground, and today marked
      by a circular bubble on the date rather than a ring around the cell.
      Every string from the server goes through `Logic.singleLine` before it
      is drawn: iCloud writes locations across several lines and `elide` only
      trims the last line laid out, so the rest escape the column.
- [x] **Contrast.** Several Omarchy themes ship a `muted` that is unreadable —
      Hackerman's `#2d3450` on `#0B0C16` is **1.59:1**. `Logic.ensureContrast`
      lifts subdued text to WCAG AA (4.5:1) against whatever background it
      lands on, lightening on dark themes and darkening on light ones, and
      stopping at the threshold rather than overshooting to white. Hackerman's
      muted becomes `#74798c` at exactly 4.50:1.
- [x] **`defaultView`.** The view survives a restart now: picking Day, Week
      or Month writes it, and the panel seeds itself from it when the first
      `status` lands. Settings names it "Opens on", which is what it means —
      and says that the view buttons leave it there, since a setting that
      changes itself should say so.

- [x] **Search.** A magnifier beside the sync button swaps the calendar list
      for a search box and what it finds: matches grouped under the whole
      date they fall on, newest first. It runs over the cache, not the
      server, so it reaches back through every synced year and answers in
      milliseconds — and typing is debounced two hundred milliseconds, so a
      name is not searched a letter at a time.

      A match is drawn with the same `DayEntry` the day panel uses, and
      clicking one selects that day and opens it in the viewer. The count
      says `200+ matches` rather than `200` when the helper hit its limit:
      the number that came back is not the number that exist, and saying so
      precisely would be a lie.

- [x] **The updater**, in Settings under `UPDATES`, copied from omedia and
      archamp rather than designed again. Two lines whose height never
      depends on what they say, so nothing below them moves while a check
      runs; `Check now` beside `Releases`, sized off the button whose label
      never changes so "Checking…" cannot resize the row; an `Update to …`
      button that appears only when there is one; a daily-check switch; and
      the command shown as selectable text with a copy beside it, because
      somebody should be able to read what a button is about to run.

      The installed version is read from `manifest.json` at runtime, so it
      cannot drift from what was released. An update reloads the plugin and
      takes the service with it, so the attempt is written to the settings
      table *before* the command runs and read back by whatever loads next —
      `updateAttemptState` says whether it applied, failed, or is still
      plausibly running.

      A 404 from GitHub is an answer, not a failure: "no releases yet" rather
      than an error, and distinct from "not checked yet", which the line
      under it would otherwise contradict.

      **The repository URL is a guess.** `lancefaul/omarchy-omarcal`, from
      how omedia's is spelled. One constant in Logic.js if it is wrong.

- [x] **The event viewer.** Click an event in the day panel and the whole
      record opens over the card: when, how it repeats, where, its alerts,
      organiser, invitees, notes and any link it carries — and nothing where
      it carries nothing, because most of what a CalDAV event can hold is
      absent most of the time and a column of empty headings says less than
      a short card.

      It takes the day column rather than covering the card: reading an
      event is what that column is for, so it replaces its contents the way
      settings replace the calendar list, with a way back above the title.

      It opens on what the list already knows — title, colour, when — and
      fills in the rest when `event --uid` answers, so it never opens on a
      spinner. The two are merged rather than swapped: a recurring event
      stores one VEVENT and a rule, and asked for it by uid the helper
      answers with that master, whose own dates are the *first* occurrence.
      `Logic.mergeOccurrence` keeps the instant that was clicked and takes
      everything else from the detail, which is why a weekly event opened on
      1 September does not head itself 30 June.

      The reading is all in Logic.js and tested: `eventWhen` (one day, several
      days, past midnight, all-day ending the morning after),
      `describeRecurrence` (FREQ, INTERVAL, BYDAY, COUNT, UNTIL, and "Repeats"
      for a rule it does not know), `describeAlarm` (relative triggers said
      out loud, and Apple's absolute 1976 placeholders dropped rather than
      shown as a date from fifty years ago) and `isWebLink`, because iCloud
      writes `sms://` URLs that get a copy button but no open.

- [x] **Day view.** The selected day against the clock: a band of all-day
      bars over a rail of 24 hours, each appointment where its time puts it
      and as wide as the events it overlaps leave it. `layoutTimed` already
      did the hard part — it clamps an event that runs past midnight to the
      day and works out the columns a cluster needs — so the new arithmetic
      is only where a block lands on a rail: `hourLabels` (padded, so a
      column of hours has one width), `openingHour` (a day opens an hour
      before its first event, or on the working morning when it is empty),
      `blockGeometry` and `blockColumn`.

      The arrows, `[` `]` and the wheel step a day here and a month
      elsewhere, through one `stepView` so they cannot disagree; up and down
      step a week rather than a year. The header names the day instead of the
      month. Today draws a line across the rail, over the blocks rather than
      under them.

- [x] **Week view, on its side.** Days down, hours across — the opposite of
      every calendar that ships with anything, and deliberately so. A day is
      a length of time, so it is drawn as one: seven timelines stacked, and
      the shape of a week readable by running an eye down the left of them.

      The first build was the conventional one, seven columns sharing an hour
      rail. It worked and it was unreadable: laid out in columns, two
      appointments at once halve a day's width and a third makes it a stripe.
      Laid out in rows they stack instead, so a busy day grows taller and
      every event keeps its full length and its title. An all-day event takes
      the whole row, which is exactly how long it is.

      Both rails run a `dayWindow`, so narrowing a day narrows it the same
      way whichever way it is drawn, and it is one setting rather than two
      opinions. A block wholly outside the window is not drawn at all rather
      than left as a sliver against an edge.

      Both rails fill the room they are given. A week's rows share out
      whatever height is spare, and a narrowed day stretches its hours to the
      same end; a week or a day too tall to fit keeps its natural size and
      scrolls. What the rows want is worked out from the events rather than
      measured off the rows, because a row about to be stretched cannot also
      be what decides the stretching.

      The week's rail carries an hour of margin past each end — an hour of
      yesterday, an hour of tomorrow, dimmed. Not the convention, and it pays
      for itself twice: the first and last hour marks straddle their ticks
      like every other one instead of being tucked against the edge, and an
      event that came from yesterday or runs into tomorrow shows a tail in
      the margin, so a day that is part of something longer looks like one at
      a glance rather than after reading the dates.

      `weekHeading` names the span — "September 6 – 12" over the year, naming
      both months when a week crosses one and putting two years in the
      quieter line rather than saying them twice in the first. `blockSpan` is
      `blockGeometry` turned on its side, `dayDepth` is how many rows deep a
      day stacks, and `hourTickStep` decides how often the clock along the top
      can afford to name itself.
- [x] Adding and editing an account, in the plugin's own UI: account and
      password, with the provider's own hint about app passwords. **iCloud
      only** — `PROVIDER_PRESETS` is a list so another provider is one entry
      plus a chip, but nothing else has been tested against a real account.
      The password goes to the helper over stdin, never argv, as the network
      panel does it, and is dropped when the form or the card closes. An
      account that already holds one says so, shows it masked behind a reveal
      toggle, and replaces it behind a key — `reveal-password` is its own
      command so a secret is only ever read on purpose, and `login` with no
      password keeps the one already stored. The form leads with why Apple
      needs a separate password at all, and a link opens step-by-step
      instructions over the card — every URL readable and copiable as well as
      clickable, the way omedia shows an update command. Connecting is its
      own button and leaves the form open — the calendars it finds are listed
      under it with a switch each, all on, and Save commits only what moved.
- [x] **Settings, in the plugin's own UI** (the standing rule: nothing
      configurable only from a terminal or a config file). The gear swaps the
      calendar list for a settings pane in the same column, laid out the way
      omedia lays its own out — sections under `PanelSectionHeader` caps, a
      row of equal bordered buttons where there are a few answers, a labelled
      switch where there are two, and **no Save**: each one is written as it
      changes, which is what the subtitle says. Week start (all seven days),
      12/24-hour, week numbers, sync interval, and the bar clock's face, with
      a way out to a format string and a live preview of whatever is set.
      Cache size and event count sit under the sync section, because a cache
      that has stopped making sense should be visible before it has to be
      explained.

      **Where they live.** The helper's `settings` table, and nowhere else.
      `shell.json` belongs to the shell and a plugin cannot write it — the
      manifest's `defaults` are a starting point, read through `setting()`
      until the first `status` answers, and after that the helper's copy is
      the only one. The same keys were also declared in the manifest's
      `schema`, which put them in Omarchy's generic widget-settings screen as
      raw numbers and strings; that entry is now empty, because two editors
      writing two different stores is worse than a crude one.

      `refreshMinutes` was the clearest symptom of the split: it existed,
      Omarchy's screen could set it, and `Service.qml` ignored it in favour of
      a hardcoded 15 minutes. The timer reads it now, with a one-minute floor
      so a typed zero cannot spin.
- [x] Removing an account (its calendars, their events and its stored
      password) and forgetting a calendar (stops syncing it, drops its cache;
      it stays on the server).
- [x] **Several accounts.** The schema held exactly one under a
      `CHECK (id = 1)`, so adding a second silently replaced the first while
      its calendars lingered. Accounts are their own table now, each calendar
      knows which it came from, and sync walks them one at a time so a broken
      account does not stop the others. Old databases migrate on open.
- [x] Syncing one calendar on its own, from its row.

Notes from wiring it up, all of which cost a shell restart to find:

- The surface is **`KeyboardPanel`**, not `PopupCard`. `qs.Ui`'s `Panel` is a
  controller plus IPC with no visual surface of its own, and `PopupCard` never
  maps against the bar. Both omedia-controls and the CalDav plugin use
  `KeyboardPanel`; so does Omarchy itself.
- A `Column` computes `implicitWidth` from its children, so it is read-only.
  Set `width`.
- `property var events` already generates `eventsChanged()`; declaring that
  signal by hand is a fatal duplicate that silently fails the whole service.
- Font sizes are `Style.font.caption/body/heading`, not `Style.fontSize.*`,
  and transparency is `Util.alpha`, not `Qt.alpha`.
- Opening the panel over IPC maps it, but it dismisses as soon as anything
  takes focus, so it cannot be screenshotted that way. Capturing it needs the
  temporary-IPC-rect method used for omedia's preview.

### Later — writes (a second release)
- [ ] Create / edit / delete via PUT and DELETE with `If-Match`
- [ ] **Recurring edits**: single occurrence via `RECURRENCE-ID`, versus
      `THISANDFUTURE`. This is where CalDAV clients are usually wrong and it
      deserves its own test suite.
- [ ] Conflict handling on 412

### Not planned
- Google and Outlook — they need OAuth app review, same as the existing plugin.
- VTODO / Reminders lists — 10 of the 13 collections on this account are
  reminders lists. Out of scope for a calendar widget.

## Effort

Roughly **6,500–8,000 lines** at the shape above — archamp-sized (7,710),
under omedia-controls (12,561). The read path is the cheap 40% and is mostly
done. Writes on recurring events are the expensive part.

Publishing overhead is near zero: the release flow, the
`.github/workflows`-omitted-from-public-tree trick, the security-baseline
check and the `grim -g` preview-capture method all carry over from
omedia-controls.

## Publishing

Two remotes, on purpose.

- `dev` → `lancefaul/omarcal-dev`, **private**, the full history with every
  commit as it happened. Day-to-day work goes here.
- `public` → `lancefaul/omarchy-omarcal`, **public**, a single squashed
  commit per release on the `public` branch, authored as
  `lancefaul@users.noreply.github.com`.

The public history is deliberately not the development history. The fixture
was a real family's month before it was sanitised, and an earlier commit of
it would still be a real family's month; nothing is gained by shipping the
archaeology and a great deal could be lost.

To publish a release:

```bash
git checkout public && git checkout master -- .   # take master's tree
GIT_AUTHOR_EMAIL=lancefaul@users.noreply.github.com \
GIT_COMMITTER_EMAIL=lancefaul@users.noreply.github.com \
  git commit --amend --author="lancefaul <lancefaul@users.noreply.github.com>"
git push public public:main --force-with-lease
```

Before every push, re-run the sweep: no real names, addresses, account
identifiers, shard hostnames or `@proton` addresses in any tracked file.
The test fixture keeps a real month's *shapes* — spans, overlaps,
recurrences, timezone edges — with every identity field replaced.

## Testing

Against a real account, because the iCloud quirks above are exactly what a
fake server would get wrong:

```bash
./test/all                      # 58 tests, no display needed

export OMARCAL_USER=<apple-id>
export OMARCAL_PASSWORD=<app-specific-password>
./helper/omarcal-helper discover --user "$OMARCAL_USER"
./helper/omarcal-helper sync     --user "$OMARCAL_USER"
./helper/omarcal-helper events --from 2026-09-01T00:00:00Z --to 2026-10-01T00:00:00Z
```

An app-specific password is generated at account.apple.com → Sign-In and
Security → App-Specific Passwords, and grants CalDAV **plus** iCloud Mail
(IMAP) and Contacts (CardDAV) — it is scoped to an app, not to a service.
