# omarcal

A CalDAV calendar for the Omarchy shell: a clock in the bar, and a month,
week and day view behind it.

It talks to the server directly rather than going through Evolution Data
Server, so every request carries a real socket timeout and one slow calendar
degrades to an error on that calendar alone instead of hanging the widget.
Parsing, recurrence expansion and VTIMEZONE handling come from `libical`,
which is already on the system.

**iCloud is the only provider tested so far.** The account form is built
around an Apple ID and an app-specific password; `PROVIDER_PRESETS` is a list
so another provider is one entry plus a chip, and more are coming.

## What it does

- **Month, week and day views.** The week is drawn on its side — days down,
  hours across — so overlapping appointments stack and keep their names
  instead of splitting a column into stripes.
- **An event viewer**: when, how it repeats, where, its alerts, organiser,
  invitees, notes and any link it carries.
- **Search** across every synced calendar, grouped by day, newest first.
- **Several accounts**, each with its own calendars, shown or hidden
  individually and syncable one at a time.
- **Settings** for the week start, 12- or 24-hour time, week numbers, the
  sync interval, the hours the day and week rails draw, and the bar clock's
  own face.

Read-only for now. Creating, editing and deleting events is 2.0.0, and
support for more CalDAV providers is coming with it.

## Install

```bash
omarchy plugin add https://github.com/lancefaul/omarchy-omarcal.git --enable
```

For local development, link the checkout into the plugins directory instead,
so edits apply without reinstalling:

```bash
# from the root of your checkout
ln -s "$PWD" ~/.config/omarchy/plugins/lancefaul.omarcal
omarchy-shell shell rescanPlugins
```

Then add the widget to the bar and open it: the calendar list on the left has
an **Add calendar** button at the bottom.

## Connecting to iCloud

Apple requires an app-specific password to give a third party access to your
calendar; your real Apple ID password will not work and is never asked for.
The form links to the steps, and generates nothing itself.

The password is stored in your keyring under the schema `org.omarchy.omarcal`
and is passed to the helper over stdin, never on a command line — `argv` is
readable from `/proc` by anything running as your user. Revoking the
app-specific password from Apple's account page removes this plugin's access
and nothing else's.

## Requirements

Everything here ships with Omarchy; none of it comes from pip.

| Needs | For |
| --- | --- |
| `python3` | the CalDAV helper |
| `python-gobject` | `gi`, the binding layer |
| `libical-glib` | `ICalGLib 4.0` — parsing, recurrence, VTIMEZONE |
| `libsecret` | `secret-tool`, for the keyring |
| `wl-clipboard` | `wl-copy`, for the copy buttons |

## Where things are kept

| Path | Holds |
| --- | --- |
| `~/.local/state/omarcal/cache.db` | synced events, calendars, accounts, settings |
| keyring, schema `org.omarchy.omarcal` | app-specific passwords |

Removing the plugin leaves both; `Disconnect account` in the account form
deletes an account's calendars, its cached events and its stored password.

## Remove

```bash
omarchy plugin remove lancefaul.omarcal
```

## Development

```bash
./test/all          # every suite, headless, no display needed
```

`Logic.js` holds every layout and formatting decision the views make and is
covered by the suite; the QML only draws. The test fixture is a real month's
worth of shapes with the names, addresses and identifiers replaced.

## Licence

MIT — see [LICENSE](LICENSE).
