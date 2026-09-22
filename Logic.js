.pragma library

// Pure functions used by the omarcal views, kept here so tests/tst_logic.qml
// can exercise exactly the code the widget runs.
//
// Everything works on the shapes the backend emits:
//
//   all-day  { allDay: true,  start: "2026-09-22",                end: "2026-09-23" }
//   timed    { allDay: false, start: "2026-09-22T08:00:00-05:00", end: "2026-09-22T16:00:00-05:00" }
//
// Two properties of that contract matter here and are relied on throughout:
//
//   * DTEND is EXCLUSIVE, as in iCalendar. A one-day all-day event ends on
//     the following date.
//   * Timed values are already in the viewer's zone, so the local date and
//     wall-clock time are the first 10 and the 11th-16th characters. No
//     timezone conversion happens in the UI, and none should be added — the
//     offset is carried only so the value round-trips.

// ----------------------------------------------------------- date primitives

function pad(value, width) {
  var text = String(value)
  while (text.length < width) text = "0" + text
  return text
}

// The local calendar date of either shape.
function dateKey(value) {
  return String(value || "").slice(0, 10)
}

// The local wall clock of a timed value, "HH:MM". Empty for an all-day one.
function timeOf(value) {
  var text = String(value || "")
  return text.length >= 16 && text.charAt(10) === "T" ? text.slice(11, 16) : ""
}

function parseKey(key) {
  var parts = String(key).split("-")
  return { y: parseInt(parts[0], 10), m: parseInt(parts[1], 10), d: parseInt(parts[2], 10) }
}

// Calendar arithmetic runs in UTC so a DST transition can never add or drop an
// hour and move a date. These keys are dates, not instants.
function addDays(key, count) {
  var p = parseKey(key)
  var moved = new Date(Date.UTC(p.y, p.m - 1, p.d + count))
  return pad(moved.getUTCFullYear(), 4) + "-" + pad(moved.getUTCMonth() + 1, 2)
       + "-" + pad(moved.getUTCDate(), 2)
}

// 0 = Sunday .. 6 = Saturday
function weekdayOf(key) {
  var p = parseKey(key)
  return new Date(Date.UTC(p.y, p.m - 1, p.d)).getUTCDay()
}

function daysBetween(fromKey, toKey) {
  var a = parseKey(fromKey), b = parseKey(toKey)
  var first = Date.UTC(a.y, a.m - 1, a.d), second = Date.UTC(b.y, b.m - 1, b.d)
  return Math.round((second - first) / 86400000)
}

function minutesOfDay(value) {
  var clock = timeOf(value)
  if (!clock) return 0
  return parseInt(clock.slice(0, 2), 10) * 60 + parseInt(clock.slice(3, 5), 10)
}

function daysInMonth(year, month) {
  return new Date(Date.UTC(year, month, 0)).getUTCDate()
}

// ------------------------------------------------------------------- periods

// Saturday and Sunday, regardless of which day the week is drawn from: the
// weekend does not move when the grid starts on Monday.
function isWeekend(weekday) {
  return weekday === 0 || weekday === 6
}

// The first day of the week `key` falls in, for a week starting on
// weekStartDay (0 = Sunday, 1 = Monday).
function weekStart(key, weekStartDay) {
  var shift = (weekdayOf(key) - (weekStartDay || 0) + 7) % 7
  return addDays(key, -shift)
}

function weekDays(key, weekStartDay) {
  var first = weekStart(key, weekStartDay)
  var days = []
  for (var i = 0; i < 7; i++) days.push(addDays(first, i))
  return days
}

// The six-by-seven grid a month view draws, leading and trailing days
// included so every row is full. `month` is 1-based.
function monthGrid(year, month, weekStartDay, todayKey) {
  var first = pad(year, 4) + "-" + pad(month, 2) + "-01"
  var start = weekStart(first, weekStartDay)
  var cells = []
  for (var i = 0; i < 42; i++) {
    var key = addDays(start, i)
    var parts = parseKey(key)
    var weekday = weekdayOf(key)
    cells.push({
      key: key,
      day: parts.d,
      month: parts.m,
      inMonth: parts.m === month && parts.y === year,
      weekday: weekday,
      isWeekend: isWeekend(weekday),
      isToday: !!todayKey && key === todayKey
    })
  }
  return cells
}

function monthRows(cells) {
  var rows = []
  for (var i = 0; i < cells.length; i += 7) rows.push(cells.slice(i, i + 7))
  return rows
}

// ISO-8601 week number: weeks start Monday and week 1 holds the first Thursday.
function isoWeekNumber(key) {
  var p = parseKey(key)
  var date = new Date(Date.UTC(p.y, p.m - 1, p.d))
  // Shift to the Thursday of this week, whose year names the week.
  var weekday = (date.getUTCDay() + 6) % 7
  date.setUTCDate(date.getUTCDate() - weekday + 3)
  var firstThursday = new Date(Date.UTC(date.getUTCFullYear(), 0, 4))
  var offset = (firstThursday.getUTCDay() + 6) % 7
  firstThursday.setUTCDate(firstThursday.getUTCDate() - offset + 3)
  return 1 + Math.round((date - firstThursday) / (7 * 86400000))
}

// ------------------------------------------------------------------ bucketing

// Every local date an event touches, inclusive of both ends.
function eventDayKeys(event) {
  var startKey = dateKey(event.start)
  var endKey
  if (event.allDay) {
    // DTEND is exclusive: 09-22 -> 09-23 is one day, the 22nd.
    endKey = addDays(dateKey(event.end), -1)
  } else {
    endKey = dateKey(event.end)
    // An event ending exactly at midnight belongs to the previous day, not to
    // the untouched day that starts at that instant.
    if (endKey > startKey && timeOf(event.end) === "00:00") endKey = addDays(endKey, -1)
  }
  if (!endKey || endKey < startKey) endKey = startKey

  var keys = []
  for (var key = startKey; key <= endKey; key = addDays(key, 1)) {
    keys.push(key)
    if (keys.length > 400) break  // a runaway span must not hang a view
  }
  return keys
}

function spansMultipleDays(event) {
  return eventDayKeys(event).length > 1
}

// { "2026-09-22": { allDay: [...], timed: [...] } } for the days given.
//
// An event is placed on every day it touches, so a multi-day event appears in
// each cell it crosses. Timed events sort by start, all-day ones by title, to
// match the order the backend already emits.
function bucketByDay(events, dayKeys) {
  var buckets = {}
  var wanted = {}
  var i
  for (i = 0; i < dayKeys.length; i++) {
    wanted[dayKeys[i]] = true
    buckets[dayKeys[i]] = { allDay: [], timed: [] }
  }
  for (i = 0; i < events.length; i++) {
    var event = events[i]
    // A multi-day timed event reads as a band, the way Apple's calendar shows
    // it, rather than as a sliver in every column it crosses.
    var band = event.allDay || spansMultipleDays(event)
    var keys = eventDayKeys(event)
    for (var k = 0; k < keys.length; k++) {
      if (!wanted[keys[k]]) continue
      buckets[keys[k]][band ? "allDay" : "timed"].push(event)
    }
  }
  for (var key in buckets) {
    buckets[key].timed.sort(function (a, b) {
      return minutesOfDay(a.start) - minutesOfDay(b.start)
    })
  }
  return buckets
}

// ------------------------------------------------------------ all-day band

// Bars for the all-day band above a week, packed into lanes so none overlap.
//
// Returns [{ event, startCol, span, lane, continuesBefore, continuesAfter }],
// where startCol and span are column indexes into the week that was passed in.
function allDayBars(events, dayKeys) {
  if (!dayKeys.length) return []
  var firstKey = dayKeys[0], lastKey = dayKeys[dayKeys.length - 1]

  var bars = []
  for (var i = 0; i < events.length; i++) {
    var event = events[i]
    if (!event.allDay && !spansMultipleDays(event)) continue
    var keys = eventDayKeys(event)
    var from = keys[0], to = keys[keys.length - 1]
    if (to < firstKey || from > lastKey) continue
    var startCol = Math.max(0, daysBetween(firstKey, from))
    var endCol = Math.min(dayKeys.length - 1, daysBetween(firstKey, to))
    bars.push({
      event: event,
      startCol: startCol,
      span: endCol - startCol + 1,
      lane: 0,
      continuesBefore: from < firstKey,
      continuesAfter: to > lastKey
    })
  }

  // Longest bars first so they take the top lanes, which is what reads well
  // and is what Apple's calendar does.
  bars.sort(function (a, b) {
    if (a.startCol !== b.startCol) return a.startCol - b.startCol
    if (a.span !== b.span) return b.span - a.span
    return String(a.event.title || "").localeCompare(String(b.event.title || ""))
  })

  var lanes = []  // lanes[n] = first free column in lane n
  for (var b = 0; b < bars.length; b++) {
    var bar = bars[b]
    var lane = 0
    while (lane < lanes.length && lanes[lane] > bar.startCol) lane++
    bar.lane = lane
    lanes[lane] = bar.startCol + bar.span
  }
  return bars
}

function laneCount(bars) {
  var most = 0
  for (var i = 0; i < bars.length; i++) most = Math.max(most, bars[i].lane + 1)
  return most
}

// How deep the all-day stack actually is over each day of a week, as an
// array one entry per column.
//
// Lanes are assigned across the whole week, so `laneCount` answers for the
// busiest day in it. Reserving that on every cell pushed a day whose only
// event is one appointment three rows down, under two lanes of nothing,
// wasting the room that appointment needed. A day is only as deep as the
// bars that actually cover it.
//
// A bar below `maxLanes` is not drawn, so it does not reserve anything
// either. A day may still be deeper than the bar count suggests: a bar sits
// in the lane its whole span could take, so a day can carry one at lane 1
// with lane 0 empty above it, and the space above has to stay for the bar
// beside it to run straight.
function barDepths(bars, dayCount, maxLanes) {
  var limit = maxLanes === undefined ? Infinity : maxLanes
  var out = []
  for (var i = 0; i < dayCount; i++) out.push(0)
  for (var b = 0; b < bars.length; b++) {
    var bar = bars[b]
    if (bar.lane >= limit) continue
    var end = Math.min(bar.startCol + bar.span, dayCount)
    for (var c = Math.max(0, bar.startCol); c < end; c++)
      if (bar.lane + 1 > out[c]) out[c] = bar.lane + 1
  }
  return out
}

// How one day cell in the month divides its slots.
//
// A cell holds `slotCount` lines and an all-day bar is one line exactly like
// an appointment is, so the two line up across the week. `barSlots` is how
// deep the bars already run over this day (see `barDepths`); whatever is left
// goes to timed events.
//
// When they do not all fit, the last free slot becomes the count of what is
// missing rather than another event — and that count includes any all-day
// event the bars could not draw, because from the cell's point of view a
// hidden event is hidden however it would have been drawn.
//
// `more` is false when the bars have taken every slot: there is nowhere to
// put the line. The day panel still lists the day in full, and a cell filled
// edge to edge with bars is visibly full.
function cellSlots(barSlots, allDayCount, timedCount, slotCount) {
  var free = Math.max(0, slotCount - barSlots)
  // A bar past the lanes the month draws is hidden however many slots are
  // free, because a free slot is under the bars and a bar cannot move into
  // it — so its presence alone means the day needs a count.
  var undrawnBars = Math.max(0, allDayCount - barSlots)
  if (undrawnBars === 0 && timedCount <= free)
    return { shownTimed: timedCount, hidden: 0, more: false }
  var shown = Math.min(timedCount, Math.max(0, free - 1))
  return {
    shownTimed: shown,
    hidden: undrawnBars + timedCount - shown,
    more: free > 0
  }
}

// ----------------------------------------------------------- timed layout

// Side-by-side placement for timed events in one day column.
//
// Returns [{ event, lane, lanes, startMinute, endMinute }]. `lanes` is how
// many columns the event's own overlapping cluster needs, so a view sizes
// each block as width / lanes — two overlapping events take half the column
// each even when the rest of the day is empty.
function layoutTimed(events, dayKey) {
  var blocks = []
  for (var i = 0; i < events.length; i++) {
    var event = events[i]
    if (event.allDay) continue
    var startsToday = dateKey(event.start) === dayKey
    var endsToday = dateKey(event.end) === dayKey
    var from = startsToday ? minutesOfDay(event.start) : 0
    var to = endsToday ? minutesOfDay(event.end) : 1440
    if (to <= from) to = from + 15   // a zero-length event still needs a box
    blocks.push({ event: event, lane: 0, lanes: 1, startMinute: from, endMinute: to })
  }
  blocks.sort(function (a, b) {
    if (a.startMinute !== b.startMinute) return a.startMinute - b.startMinute
    return b.endMinute - a.endMinute
  })

  // Walk the day, collecting runs of mutually overlapping events. Every block
  // in a cluster is laid out against the same column count.
  var cluster = []
  var clusterEnd = -1
  var out = []

  function flush() {
    if (!cluster.length) return
    var lanes = []
    for (var c = 0; c < cluster.length; c++) {
      var block = cluster[c]
      var lane = 0
      while (lane < lanes.length && lanes[lane] > block.startMinute) lane++
      block.lane = lane
      lanes[lane] = block.endMinute
    }
    for (var d = 0; d < cluster.length; d++) cluster[d].lanes = lanes.length
    out = out.concat(cluster)
    cluster = []
    clusterEnd = -1
  }

  for (var b = 0; b < blocks.length; b++) {
    if (cluster.length && blocks[b].startMinute >= clusterEnd) flush()
    cluster.push(blocks[b])
    clusterEnd = Math.max(clusterEnd, blocks[b].endMinute)
  }
  flush()
  return out
}

// -------------------------------------------------------------------- colour

// Themes choose their own "muted" colour and some of them are unreadable: in
// Hackerman it is #2d3450 on a #0B0C16 background, a contrast ratio of
// 1.59:1. Rather than pick a colour per theme, subdued text is pushed until
// it clears the WCAG AA threshold for body text against whatever background
// it actually lands on.

function parseColor(value) {
  var text = String(value || "").trim()
  var six = /^#([0-9a-fA-F]{6})$/.exec(text)
  if (six) {
    return { r: parseInt(six[1].substr(0, 2), 16),
             g: parseInt(six[1].substr(2, 2), 16),
             b: parseInt(six[1].substr(4, 2), 16) }
  }
  // QML stringifies colours as #AARRGGBB; the alpha is dropped here because
  // contrast is measured against the composited result, not the source.
  var eight = /^#([0-9a-fA-F]{8})$/.exec(text)
  if (eight) {
    return { r: parseInt(eight[1].substr(2, 2), 16),
             g: parseInt(eight[1].substr(4, 2), 16),
             b: parseInt(eight[1].substr(6, 2), 16) }
  }
  return null
}

function hexOf(rgb) {
  function part(v) {
    var clamped = Math.max(0, Math.min(255, Math.round(v)))
    return pad(clamped.toString(16), 2)
  }
  return "#" + part(rgb.r) + part(rgb.g) + part(rgb.b)
}

function channelLuminance(value) {
  var v = value / 255
  return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
}

function relativeLuminance(color) {
  var rgb = parseColor(color)
  if (!rgb) return 0
  return 0.2126 * channelLuminance(rgb.r)
       + 0.7152 * channelLuminance(rgb.g)
       + 0.0722 * channelLuminance(rgb.b)
}

function contrastRatio(a, b) {
  var first = relativeLuminance(a), second = relativeLuminance(b)
  var lighter = Math.max(first, second), darker = Math.min(first, second)
  return (lighter + 0.05) / (darker + 0.05)
}

function mixColor(from, to, amount) {
  return { r: from.r + (to.r - from.r) * amount,
           g: from.g + (to.g - from.g) * amount,
           b: from.b + (to.b - from.b) * amount }
}

// `foreground` lightened or darkened just enough to reach `minRatio` against
// `background`. Returns a hex string, or the input unchanged when it already
// passes or cannot be parsed.
function ensureContrast(foreground, background, minRatio) {
  var target = minRatio || 4.5
  var fg = parseColor(foreground), bg = parseColor(background)
  if (!fg || !bg) return String(foreground)
  if (contrastRatio(hexOf(fg), hexOf(bg)) >= target) return hexOf(fg)

  // Move away from the background: toward white on a dark one, black on a
  // light one.
  var limit = relativeLuminance(hexOf(bg)) < 0.5
    ? { r: 255, g: 255, b: 255 }
    : { r: 0, g: 0, b: 0 }
  if (contrastRatio(hexOf(limit), hexOf(bg)) < target) return hexOf(limit)

  var low = 0, high = 1
  for (var step = 0; step < 24; step++) {
    var mid = (low + high) / 2
    if (contrastRatio(hexOf(mixColor(fg, limit, mid)), hexOf(bg)) >= target) high = mid
    else low = mid
  }
  return hexOf(mixColor(fg, limit, high))
}

// ------------------------------------------------------------------ provider

// A readable name for the CalDAV server the account lives on, used as the
// heading above the calendar list. Anything unrecognised falls back to the
// registrable part of the host, so a self-hosted server still reads as
// something rather than as a bare URL.
var PROVIDERS = [
  { match: "icloud.com", name: "iCloud" },
  { match: "fastmail.com", name: "Fastmail" },
  { match: "google.com", name: "Google" },
  { match: "yahoo.com", name: "Yahoo" },
  { match: "posteo.de", name: "Posteo" },
  { match: "mailbox.org", name: "mailbox.org" }
]

// What the setup form offers. iCloud only for now — the shape is a list so
// another provider is a line here and a chip in the form, but nothing else
// has been tested against a real account, and offering an untested provider
// is worse than not offering it.
var PROVIDER_PRESETS = [
  { name: "iCloud", server: "https://caldav.icloud.com/",
    hint: "Apple needs an app-specific password, from account.apple.com under Sign-In and Security." }
]

// How to get an app-specific password out of Apple, step by step. Kept here
// rather than in the panel so the wording is reviewable in one place and the
// links can be checked by a test.
//
// Every link is shown as text as well as opened, because a person being asked
// for a password is entitled to see where a button would send them before
// pressing it.
var APP_PASSWORD_STEPS = [
  { title: "Sign in to your Apple account",
    text: "The same Apple ID you use on your iPhone or Mac.",
    link: "https://account.apple.com" },
  { title: "Go to Sign-In & Security",
    text: "Use the navigation down the left-hand side of the page.",
    link: "https://account.apple.com/account/manage/section/security" },
  { title: "Check that two-factor authentication is enabled",
    text: "Apple does not offer app-specific passwords without it. If it is disabled, enable it before going further.",
    link: "" },
  { title: "Open App-Specific Passwords",
    text: "It sits inside Sign-In & Security. Choose to generate a new one.",
    link: "" },
  { title: "Name it",
    text: "Something you will recognise on that list a year from now — omarcal, for instance.",
    link: "" },
  { title: "Enter your Apple ID password",
    text: "Apple asks for your real password to confirm it is you. That one stays with Apple; it is not what you paste here.",
    link: "" },
  { title: "Copy what Apple shows you",
    text: "It looks like abcd-efgh-ijkl-mnop. Apple shows it once and never again.",
    link: "" },
  { title: "Paste it into the Password box",
    text: "Revoke it any time from that same Apple page and this plugin loses access — nothing else you use does.",
    link: "" }
]

function appPasswordSteps() {
  return APP_PASSWORD_STEPS
}

function providerPresets() {
  var out = []
  for (var i = 0; i < PROVIDER_PRESETS.length; i++) out.push(PROVIDER_PRESETS[i].name)
  return out
}

function presetFor(name) {
  for (var i = 0; i < PROVIDER_PRESETS.length; i++)
    if (PROVIDER_PRESETS[i].name === name) return PROVIDER_PRESETS[i]
  return PROVIDER_PRESETS[PROVIDER_PRESETS.length - 1]
}

// What is wrong with the form, or "" when nothing is. Said as a sentence,
// since it is shown to the person filling it in.
//
// `passwordHeld` is true when the account already has one in the keyring and
// the form is not replacing it, in which case an empty box is the correct
// state rather than a missing answer.
function accountProblem(user, server, password, passwordHeld) {
  if (!String(user || "").trim()) return "An account is needed."
  // An Apple ID is an email address or, in some regions, a phone number —
  // account.apple.com takes either. Anything with an @ counts as the first;
  // enough digits counts as the second.
  var trimmed = String(user).trim()
  var looksLikeEmail = trimmed.indexOf("@") > 0
  var looksLikePhone = /^[+()\-. 0-9]{7,}$/.test(trimmed)
  if (!looksLikeEmail && !looksLikePhone)
    return "That does not look like an Apple ID or a phone number."
  if (!/^https?:\/\/[^\s]+$/.test(String(server || "").trim()))
    return "The server needs to be a URL, starting https://."
  if (!passwordHeld && !String(password || "")) return "A password is needed."
  return ""
}

function providerName(server) {
  var text = String(server || "").trim()
  if (!text) return "Calendars"
  var host = text.replace(/^[a-z]+:\/\//i, "").split("/")[0].split(":")[0].toLowerCase()
  if (!host) return "Calendars"

  for (var i = 0; i < PROVIDERS.length; i++) {
    if (host === PROVIDERS[i].match || host.indexOf("." + PROVIDERS[i].match) >= 0
        || host.indexOf(PROVIDERS[i].match) === 0) {
      return PROVIDERS[i].name
    }
  }

  // Drop a leading service label such as "caldav." or "dav.", then title-case
  // what is left of the name: dav.example.co.uk -> Example.
  var parts = host.split(".")
  while (parts.length > 2 && /^(caldav|dav|calendar|cal|www)$/.test(parts[0])) parts.shift()
  var label = parts[0] || host
  return label.charAt(0).toUpperCase() + label.slice(1)
}

// ----------------------------------------------------------------- formatting

var MONTH_NAMES = ["January", "February", "March", "April", "May", "June",
                   "July", "August", "September", "October", "November", "December"]
var DAY_NAMES = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

function monthLabel(year, month) {
  return MONTH_NAMES[month - 1] + " " + year
}

// The two halves of that label, for a header that stacks the name over the
// year the way the calendar column's does.
function monthName(month) {
  return MONTH_NAMES[month - 1]
}

function weekdayLabels(weekStartDay, width) {
  var labels = []
  for (var i = 0; i < 7; i++) {
    var name = DAY_NAMES[(i + (weekStartDay || 0)) % 7]
    labels.push(width ? name.slice(0, width) : name)
  }
  return labels
}

// "09:00 PM" or "21:00". Always two digits and always the minutes, including
// on the hour: a column of times reads as a column when every one of them is
// the same width.
function formatTime(value, timeFormat) {
  var clock = timeOf(value)
  if (!clock) return ""
  var hour = parseInt(clock.slice(0, 2), 10)
  var minute = clock.slice(3, 5)
  if (timeFormat === "24h") return clock
  var suffix = hour < 12 ? "AM" : "PM"
  var shown = hour % 12
  if (shown === 0) shown = 12
  return pad(shown, 2) + ":" + minute + " " + suffix
}

function formatRange(event, timeFormat) {
  if (event.allDay) return "All day"
  var from = formatTime(event.start, timeFormat)
  var to = formatTime(event.end, timeFormat)
  return to && to !== from ? from + " – " + to : from
}

// Anything from the server drawn on one line has to be flattened first.
//
// iCloud stores a location as several lines — the venue name, then the street
// address — and Text renders every one of them. `elide` only trims the last
// line it lays out, so the rest simply run past the column. Titles can carry
// newlines too. Collapsing to one line is what makes eliding mean anything.
function singleLine(value) {
  var text = String(value === undefined || value === null ? "" : value)
  return text.replace(/\s*[\r\n]+\s*/g, ", ").replace(/[ \t]+/g, " ").trim()
}

// A location as the lines it was written on. iCloud stores an address block,
// usually a venue or street on the first line and the town on the second, but
// anything from one line to four. Each is drawn on its own line and elided on
// its own, which is what singleLine exists to avoid having to do when there is
// only room for one.
function locationLines(value) {
  var text = String(value === undefined || value === null ? "" : value)
  var out = []
  var parts = text.split(/[\r\n]+/)
  for (var i = 0; i < parts.length; i++) {
    var line = parts[i].replace(/[ \t]+/g, " ").trim()
    if (line) out.push(line)
  }
  return out
}

function formatDayHeader(key) {
  var p = parseKey(key)
  return DAY_NAMES[weekdayOf(key)] + ", " + MONTH_NAMES[p.m - 1] + " " + p.d
}

// The two halves of that header, for a column narrow enough to need them
// stacked: "Saturday" over "September 19, 2026".
function weekdayOfName(key) {
  return DAY_NAMES[weekdayOf(key)]
}

function formatDayLabel(key) {
  var p = parseKey(key)
  return MONTH_NAMES[p.m - 1] + " " + p.d + ", " + p.y
}

// Sits under a section heading, so the empty case is a word rather than a
// sentence: "All Day" over "None" reads, "All Day" over "Nothing scheduled"
// does not.
// The same shape for a list of things that are not events.
function availableLabel(count) {
  if (!count) return "None"
  return count === 1 ? "1 available" : count + " available"
}

function eventCountLabel(count) {
  if (!count) return "None"
  return count === 1 ? "1 event" : count + " events"
}

// ------------------------------------------------------------------ settings
//
// The values the settings panel offers and how they are labelled. Kept here
// so the list a person sees and the list the tests check are the same one.

// All seven, because a week does not start on Sunday or Monday everywhere and
// the month grid already handles any of them.
var WEEK_START_OPTIONS = [
  { value: "0", label: "Sunday" },
  { value: "1", label: "Monday" },
  { value: "2", label: "Tuesday" },
  { value: "3", label: "Wednesday" },
  { value: "4", label: "Thursday" },
  { value: "5", label: "Friday" },
  { value: "6", label: "Saturday" }
]

var TIME_FORMAT_OPTIONS = [
  { value: "12h", label: "12-hour" },
  { value: "24h", label: "24-hour" }
]

// Minutes between background syncs. A warm sync answers in well under a
// second, so the cost of the short end is bandwidth rather than time; the
// long end is for someone whose calendar barely moves.
var REFRESH_OPTIONS = [5, 15, 30, 60]

function weekStartOptions() { return WEEK_START_OPTIONS }
function timeFormatOptions() { return TIME_FORMAT_OPTIONS }
function refreshOptions() { return REFRESH_OPTIONS }

function weekStartLabel(day) {
  var index = Number(day)
  if (!isFinite(index) || index < 0 || index > 6) index = 0
  return WEEK_START_OPTIONS[index].label
}

function refreshLabel(minutes) {
  var value = Number(minutes)
  if (!isFinite(value) || value <= 0) return "Never"
  if (value % 60 === 0) return (value / 60) + (value === 60 ? " hour" : " hours")
  return value + " min"
}

// The bar clock's face, as choices rather than a format string. The default
// is first and is the one the widget ships with.
//
// Named rather than shown as examples: the sidebar is too narrow for
// "Saturday, September 19, 2026 • 08:15:34 PM" and a dropdown row that
// elides its own preview is worse than no preview. The panel renders the
// chosen format underneath instead, where it can wrap.
var CLOCK_PRESETS = [
  { label: "Full date and time", format: "dddd, MMMM d, yyyy '•' hh:mm:ss AP" },
  { label: "Short date and time", format: "ddd, MMM d '•' hh:mm AP" },
  { label: "Short date, 24-hour", format: "MMM d '•' HH:mm" },
  { label: "Time only", format: "hh:mm:ss AP" },
  { label: "Time only, 24-hour", format: "HH:mm" }
]

function clockPresets() { return CLOCK_PRESETS }

// Which preset a stored format is, or -1 when it is one the person typed.
function clockPresetIndex(format) {
  for (var i = 0; i < CLOCK_PRESETS.length; i++)
    if (CLOCK_PRESETS[i].format === format) return i
  return -1
}

// "17.4 MB · 5,405 events". Both halves come straight from `status`, and the
// point of showing them is that a cache which has stopped making sense is
// visible before it has to be explained.
function cacheLabel(bytes, objects) {
  return byteLabel(bytes) + " · " + countLabel(objects) + " cached"
}

function byteLabel(bytes) {
  var value = Number(bytes)
  if (!isFinite(value) || value <= 0) return "0 KB"
  if (value < 1024) return value + " B"
  if (value < 1024 * 1024) return Math.round(value / 1024) + " KB"
  return (value / (1024 * 1024)).toFixed(1) + " MB"
}

// Thousands separated, because five thousand events and five hundred look
// alike at a glance otherwise.
function countLabel(count) {
  var value = Math.max(0, Math.round(Number(count) || 0))
  var text = String(value)
  var out = ""
  for (var i = 0; i < text.length; i++) {
    if (i > 0 && (text.length - i) % 3 === 0) out += ","
    out += text[i]
  }
  return out
}

// What `status` last reported, filled in from the defaults for anything it
// did not carry. The helper answers with every key, but a panel that has not
// heard from it yet still has to draw something.
var SETTING_DEFAULTS = {
  weekStartDay: 0,
  timeFormat: "12h",
  showWeekNumbers: false,
  refreshMinutes: 15,
  format: CLOCK_PRESETS[0].format,
  verticalFormat: "HH\nmm\nss",
  wrapEvents: false,
  dayStartHour: 0,
  dayEndHour: 24
}

// The hours a day can be narrowed to, for the two pickers that set it. The
// end runs to midnight of the next day, which is the only way to say "all of
// it" without saying "0".
function dayStartOptions() {
  var out = []
  for (var h = 0; h < 24; h++)
    out.push({ value: String(h), label: hourLabels("12h")[h] })
  return out
}

function dayEndOptions() {
  var out = []
  for (var h = 1; h <= 24; h++)
    out.push({ value: String(h), label: hourLabels("12h")[h % 24] })
  return out
}

// How the day panel treats a title or an address too long for its column.
// Cutting it off is the default because it keeps every entry the same height
// and the list scannable; wrapping is for when the whole name matters more
// than the shape of the list.
var WRAP_OPTIONS = [
  { value: "false", label: "One line" },
  { value: "true", label: "Wrap" }
]

function wrapOptions() { return WRAP_OPTIONS }

function settingDefaults() { return SETTING_DEFAULTS }

function settingDefault(name) { return SETTING_DEFAULTS[name] }

// ------------------------------------------------------------- event detail
//
// What the viewer says about one event. All of it is derived from the fields
// `event --uid` returns, and none of it touches the screen — the panel draws
// whatever these hand back.

var RRULE_DAYS = { SU: "Sun", MO: "Mon", TU: "Tue", WE: "Wed", TH: "Thu",
                   FR: "Fri", SA: "Sat" }

// "Sunday, September 20, 2026", the long form the viewer heads its When with.
function longDate(key) {
  var p = parseKey(key)
  if (!isFinite(p.y) || !isFinite(p.m) || !isFinite(p.d)) return ""
  return weekdayOfName(key) + ", " + formatDayLabel(key)
}

// The whole of an event's when, in at most two lines: the day, and the hours
// under it. An all-day event says so rather than showing midnight to
// midnight, and one that runs past its own day names both ends.
function eventWhen(event, timeFormat) {
  if (!event || !event.start) return []
  var from = dateKey(event.start)
  var to = dateKey(event.end)
  if (event.allDay) {
    // An all-day event's end is the morning after, which is not a day it
    // covers. One that ends the next morning is a single day.
    var last = addDays(to, -1)
    if (!to || last === from) return [longDate(from), "All day"]
    return [longDate(from) + " – " + longDate(last), "All day"]
  }
  var hours = formatTime(event.start, timeFormat)
  var close = formatTime(event.end, timeFormat)
  if (close && close !== hours) hours += " – " + close
  if (to && to !== from) return [longDate(from) + " – " + longDate(to), hours]
  return [longDate(from), hours]
}

// An RRULE said out loud. Only the parts iCloud actually writes are
// understood; anything else falls back to saying that it repeats at all,
// which is still truer than showing the rule.
function describeRecurrence(rrule) {
  var text = String(rrule || "").trim()
  if (!text) return ""
  var parts = {}
  var pieces = text.split(";")
  for (var i = 0; i < pieces.length; i++) {
    var pair = pieces[i].split("=")
    if (pair.length === 2) parts[pair[0].toUpperCase()] = pair[1]
  }
  var every = Number(parts.INTERVAL || 1)
  if (!isFinite(every) || every < 1) every = 1
  var unit = { DAILY: "day", WEEKLY: "week", MONTHLY: "month", YEARLY: "year" }[
    String(parts.FREQ || "").toUpperCase()]
  if (!unit) return "Repeats"
  var out = every === 1 ? "Every " + unit : "Every " + every + " " + unit + "s"

  if (parts.BYDAY && unit === "week") {
    var days = [], codes = parts.BYDAY.split(",")
    for (var d = 0; d < codes.length; d++) {
      // A BYDAY can be ordinal (2MO); the viewer only names the day.
      var code = codes[d].replace(/^[-+]?\d+/, "").toUpperCase()
      if (RRULE_DAYS[code]) days.push(RRULE_DAYS[code])
    }
    if (days.length) out += " on " + days.join(", ")
  }

  if (parts.COUNT) {
    var times = Number(parts.COUNT)
    if (isFinite(times) && times > 0)
      out += ", " + times + (times === 1 ? " time" : " times")
  } else if (/^\d{8}/.test(parts.UNTIL || "")) {
    var raw = parts.UNTIL
    var said = longDate(raw.slice(0, 4) + "-" + raw.slice(4, 6) + "-" + raw.slice(6, 8))
    if (said) out += ", until " + said
  }
  return out
}

// A VALARM trigger said out loud. Apple writes some as an absolute instant in
// 1976, which is a placeholder rather than a time anybody set — those are
// dropped rather than shown as a date from fifty years ago.
function describeAlarm(trigger) {
  var text = String(trigger || "").trim().toUpperCase()
  if (!text) return ""
  var match = text.match(/^(-|\+)?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/)
  if (!match) return ""
  // An unsigned duration is positive, which in a TRIGGER means after the
  // event starts. Only a leading minus means before it.
  var before = match[1] === "-"
  var weeks = Number(match[2] || 0), days = Number(match[3] || 0)
  var hours = Number(match[4] || 0), mins = Number(match[5] || 0)
  var secs = Number(match[6] || 0)
  var total = ((weeks * 7 + days) * 24 + hours) * 60 + mins + (secs ? secs / 60 : 0)
  if (total === 0) return "At the time of the event"
  var said = []
  if (weeks) said.push(plural(weeks, "week"))
  if (days) said.push(plural(days, "day"))
  if (hours) said.push(plural(hours, "hour"))
  if (mins) said.push(plural(mins, "minute"))
  if (!said.length && secs) said.push(plural(secs, "second"))
  return said.join(" ") + (before ? " before" : " after")
}

function plural(n, word) {
  return n + " " + word + (n === 1 ? "" : "s")
}

// Every alarm worth showing, in order, with the placeholders dropped.
function alarmLines(alarms) {
  var out = []
  for (var i = 0; i < (alarms || []).length; i++) {
    var said = describeAlarm(alarms[i])
    if (said && out.indexOf(said) === -1) out.push(said)
  }
  return out
}

// Only a link a browser can open gets a button; the rest are shown as text.
// iCloud writes `sms://` and `message://` URLs that would go nowhere useful.
function isWebLink(url) {
  return /^https?:\/\//i.test(String(url || "").trim())
}

// The record the viewer draws: everything `event --uid` knows about the
// series, on the occurrence that was actually clicked.
//
// A recurring event stores one VEVENT and a rule. Asked for it by uid alone
// the helper answers with that master, whose own dates are the *first*
// occurrence — for a weekly event that is months or years before the one on
// screen. The list already carries the right instant for the row that was
// clicked, so the when comes from there and everything else from the detail.
function mergeOccurrence(seed, detail) {
  if (!seed) return detail || null
  if (!detail || detail.uid !== seed.uid) return seed
  var out = {}
  for (var key in detail) out[key] = detail[key]
  out.start = seed.start
  out.end = seed.end
  out.allDay = seed.allDay
  return out
}

// ---------------------------------------------------------------- day view
//
// A day as a rail of hours with blocks laid on it. `layoutTimed` already
// works out the lanes; these are the rest of the arithmetic a grid needs.

var DAY_MINUTES = 24 * 60

// The slice of a day a timeline shows. Both rails run one of these, so a day
// narrowed to waking hours narrows the same way whichever way it is drawn.
//
// A window that is not a real span is the whole day rather than nothing: a
// setting typed backwards should show too much, not leave the view blank.
function dayWindow(startHour, endHour) {
  var from = Math.round(Number(startHour))
  var to = Math.round(Number(endHour))
  if (!isFinite(from) || from < 0) from = 0
  from = Math.min(23, from)
  if (!isFinite(to) || to <= from) to = 24
  to = Math.min(24, Math.max(from + 1, to))
  return { from: from, to: to, hours: to - from,
           startMinute: from * 60, endMinute: to * 60 }
}

var WHOLE_DAY = dayWindow(0, 24)

// Whether a block has anything inside the window at all. One that does not
// is not drawn, rather than drawn as a sliver against an edge.
function inWindow(block, win) {
  var w = win || WHOLE_DAY
  return block.endMinute > w.startMinute && block.startMinute < w.endMinute
}

// The rail down the side. Padded like `formatTime`, so a column of hours has
// one width and does not shuffle left and right between 9 and 10.
function hourLabels(timeFormat) {
  var out = []
  for (var h = 0; h < 24; h++) {
    if (timeFormat === "24h") { out.push(pad(h, 2) + ":00"); continue }
    var twelve = h % 12 === 0 ? 12 : h % 12
    out.push(pad(twelve, 2) + " " + (h < 12 ? "AM" : "PM"))
  }
  return out
}

// Where a day should open. A day with something in it opens an hour before
// its first event, so the first block is not jammed against the top edge; an
// empty day opens on the working morning rather than at midnight.
function openingHour(blocks, fallbackHour) {
  var start = fallbackHour === undefined ? 8 : fallbackHour
  var earliest = -1
  for (var i = 0; i < (blocks || []).length; i++) {
    var minute = blocks[i].startMinute
    if (earliest < 0 || minute < earliest) earliest = minute
  }
  if (earliest < 0) return Math.max(0, Math.min(23, start))
  return Math.max(0, Math.floor(earliest / 60) - 1)
}

// Where one block sits on a rail `hourHeight` tall per hour, and how tall it
// is. A very short event still gets a box big enough to read.
function blockGeometry(block, hourHeight, minimumHeight, win) {
  var w = win || WHOLE_DAY
  var from = Math.max(w.startMinute, Math.min(w.endMinute, block.startMinute))
  var to = Math.max(from, Math.min(w.endMinute, block.endMinute))
  var top = (from - w.startMinute) * hourHeight / 60
  var height = (to - from) * hourHeight / 60
  var floor = minimumHeight === undefined ? 0 : minimumHeight
  return { y: Math.round(top), height: Math.round(Math.max(height, floor)) }
}

// The horizontal share of one block: which of its cluster's columns it takes
// and how wide that column is, with `gap` left between neighbours.
function blockColumn(block, width, gap) {
  var lanes = Math.max(1, block.lanes)
  var span = width / lanes
  var pad = lanes > 1 ? (gap === undefined ? 0 : gap) : 0
  return {
    x: Math.round(block.lane * span),
    width: Math.max(1, Math.round(span - pad))
  }
}

// The minute the rail should be scrolled to for a given hour, so a view can
// open on it without knowing how the rail is drawn.
function hourOffset(hour, hourHeight) {
  return Math.max(0, Math.round(hour * hourHeight))
}

// --------------------------------------------------------------- week view

// The two lines of a week's header: the span of days, and the year under it.
// A week that crosses a month names both, and one that crosses a new year
// says so in the second line rather than repeating itself in the first.
function weekHeading(days) {
  if (!days || !days.length) return { title: "", meta: "" }
  var a = parseKey(days[0]), b = parseKey(days[days.length - 1])
  if (!isFinite(a.y) || !isFinite(b.y)) return { title: "", meta: "" }
  var title = a.m === b.m
    ? MONTH_NAMES[a.m - 1] + " " + a.d + " – " + b.d
    : MONTH_NAMES[a.m - 1] + " " + a.d + " – "
      + MONTH_NAMES[b.m - 1] + " " + b.d
  return { title: title, meta: a.y === b.y ? String(a.y) : a.y + " – " + b.y }
}

// --------------------------------------------------- week view, flipped
//
// Days down, hours across. A day is a row and its events lie along it, which
// is the shape a day actually has — a length of time, not a column. Events
// that overlap stack within the row instead of splitting its width, so a busy
// day grows taller rather than narrower and stays readable.

// The horizontal twin of `blockGeometry`: where a block sits along a rail
// running `win` across `railWidth`, and how wide it is.
function blockSpan(block, railWidth, minimumWidth, win) {
  var w = win || WHOLE_DAY
  var from = Math.max(w.startMinute, Math.min(w.endMinute, block.startMinute))
  var to = Math.max(from, Math.min(w.endMinute, block.endMinute))
  var span = w.endMinute - w.startMinute
  var left = (from - w.startMinute) * railWidth / span
  var width = (to - from) * railWidth / span
  var floor = minimumWidth === undefined ? 0 : minimumWidth
  return {
    x: Math.round(left),
    width: Math.max(1, Math.round(Math.max(width, floor)))
  }
}

// How many rows deep a day is when its events stack: the all-day ones first,
// each on its own, then the deepest overlap among the timed. An empty day is
// still one row deep — a row of nothing is how you see there is nothing.
function dayDepth(allDayCount, blocks) {
  return Math.max(1, (allDayCount || 0) + laneCount(blocks || []))
}

// How many hours apart the rail's labels can stand without touching, given
// how wide one is and how many hours it is showing.
function hourTickStep(railWidth, labelWidth, hours) {
  var count = hours === undefined ? 24 : Math.max(1, hours)
  var steps = [1, 2, 3, 4, 6, 8, 12]
  for (var i = 0; i < steps.length; i++)
    if (railWidth / (count / steps[i]) >= labelWidth * 1.6) return steps[i]
  return steps[steps.length - 1]
}

// Where an hour falls along the rail. An hour outside the window still gets
// an answer, clamped to the ends, so a caller can position without checking.
function hourAcross(hour, railWidth, win) {
  var w = win || WHOLE_DAY
  var at = (Math.max(w.from, Math.min(w.to, hour)) - w.from) / w.hours
  return Math.round(at * railWidth)
}

// The rail the flipped week actually draws: the window it shows, plus an
// hour of margin at each end.
//
// The margin earns its keep twice. It is the room the first and last hour
// marks need to straddle their tick like every other one, instead of being
// tucked against the edge; and it is where an event that came from yesterday
// or runs into tomorrow shows its tail, so a day that is part of something
// longer looks like one.
function railWindow(win, marginHours) {
  var w = win || WHOLE_DAY
  var pad = marginHours === undefined ? 1 : marginHours
  return {
    from: w.from - pad, to: w.to + pad, hours: w.hours + pad * 2,
    startMinute: (w.from - pad) * 60, endMinute: (w.to + pad) * 60,
    pad: pad, day: w
  }
}

// Whether an event runs past the day it is being drawn on, in either
// direction.
//
// An all-day event's end is the morning after its last day, and a timed one
// that ends exactly at midnight stops at the edge — neither spills into the
// next day just because the clock rolled over.
function eventOverflow(event, dayKey) {
  if (!event || !dayKey) return { before: false, after: false }
  var from = dateKey(event.start)
  var end = dateKey(event.end)
  var after = event.allDay
    ? addDays(end, -1) > dayKey
    : (end > dayKey && minutesOfDay(event.end) > 0)
  return { before: from < dayKey, after: after }
}

// The minutes a block is drawn across once its overflow is allowed to show:
// out to the margin on whichever side it continues.
function spilledSpan(startMinute, endMinute, overflow, rail) {
  var flow = overflow || { before: false, after: false }
  return {
    startMinute: flow.before ? rail.startMinute : startMinute,
    endMinute: flow.after ? rail.endMinute : endMinute
  }
}

// How many rows deep a whole week is, before any spare room is shared out.
//
// Pure, and worked out from the events rather than from the rows themselves,
// so a view can ask how tall it wants to be and then decide how tall to make
// its rows without the two chasing each other.
function weekNaturalRows(dayKeys, buckets) {
  var total = 0
  var days = dayKeys || []
  var byDay = buckets || {}
  for (var i = 0; i < days.length; i++) {
    var bucket = byDay[days[i]] || {}
    total += dayDepth((bucket.allDay || []).length,
                      layoutTimed(bucket.timed || [], days[i]))
  }
  return total
}

// -------------------------------------------------------------- which view
//
// Stored lower case, because that is how the first schema wrote it and a
// settings table is not worth a migration over a capital letter.

function viewOptions() {
  return [{ value: "day", label: "Day" },
          { value: "week", label: "Week" },
          { value: "month", label: "Month" }]
}

function viewKey(mode) {
  var name = String(mode || "").toLowerCase()
  return name === "day" || name === "week" ? name : "month"
}

function viewFromKey(key) {
  var name = String(key || "").toLowerCase()
  if (name === "day") return "Day"
  if (name === "week") return "Week"
  return "Month"
}

// ------------------------------------------------------------------ search
//
// Matches grouped under the day they fall on, newest first. A search reaches
// back through years of calendar, and what somebody is looking for is far
// more often the last one than the first — so the list runs from whatever is
// furthest ahead down into the past.

function searchGroups(events) {
  var byDay = {}
  var order = []
  for (var i = 0; i < (events || []).length; i++) {
    var event = events[i]
    var key = dateKey(event.start)
    if (!key) continue
    if (!byDay[key]) { byDay[key] = []; order.push(key) }
    byDay[key].push(event)
  }
  order.sort(function (a, b) { return a < b ? 1 : a > b ? -1 : 0 })
  var out = []
  for (var d = 0; d < order.length; d++) {
    var day = order[d]
    // Within a day, all-day first and then by the clock, the way the day
    // panel reads.
    byDay[day].sort(function (a, b) {
      if (!!a.allDay !== !!b.allDay) return a.allDay ? -1 : 1
      return String(a.start) < String(b.start) ? -1
           : String(a.start) > String(b.start) ? 1 : 0
    })
    out.push({ key: day, label: searchDayLabel(day), events: byDay[day] })
  }
  return out
}

// "Sunday, September 20, 2026" — the whole date, because a search crosses
// years and a bare weekday would say nothing about which one.
function searchDayLabel(key) {
  return longDate(key)
}

// What a search says about itself. `capped` is true when the helper hit its
// limit, in which case the count is what came back and not what exists —
// saying "200 matches" for an unknown number of them would be a lie told
// precisely.
function searchSummary(query, count, searching, capped) {
  if (searching) return "Searching\u2026"
  if (!String(query || "").trim()) return "Type to search every calendar."
  if (!count) return "Nothing matches."
  if (capped) return count + "+ matches \u2014 narrow it down"
  return count === 1 ? "1 match" : count + " matches"
}

// How many a search asks for. Shared, so the panel and the summary agree on
// when the answer was cut short.
var SEARCH_LIMIT = 200

function searchLimit() { return SEARCH_LIMIT }


// ----------------------------------------------------------------- updates
//
// The third copy of this, after omedia and archamp, and deliberately the same
// one: an updater is not a place to have ideas.

var PLUGIN_ID = "lancefaul.omarcal"
var RELEASES_API =
  "https://api.github.com/repos/lancefaul/omarchy-omarcal/releases/latest"
var RELEASES_PAGE = "https://github.com/lancefaul/omarchy-omarcal/releases/"
var UPDATE_COMMAND = ["omarchy", "plugin", "update", PLUGIN_ID, "--yes"]
var RESTART_COMMAND = ["omarchy", "restart", "shell"]
var UPDATE_CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000
// An update reloads the plugin, taking the widget with it, so an attempt is
// written down before it runs and read back by whatever loads next. One older
// than this was abandoned somewhere along the way.
var UPDATE_ATTEMPT_TIMEOUT_MS = 5 * 60 * 1000

function updateCommand() { return UPDATE_COMMAND }
function restartCommand() { return RESTART_COMMAND }
function releasesPage() { return RELEASES_PAGE }
function releasesApi() { return RELEASES_API }
function updateCheckInterval() { return UPDATE_CHECK_INTERVAL_MS }

function parseVersion(text) {
  var m = /^v?(\d{1,4})\.(\d{1,4})\.(\d{1,6})$/.exec(String(text || "").trim())
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null
}

function isNewerVersion(a, b) {
  var x = parseVersion(a), y = parseVersion(b)
  if (!x || !y) return false
  for (var i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] > y[i]
  return false
}

// GitHub's answer, reduced to what the panel draws. A draft or a prerelease
// is not an update, and a tag that is not a version is not one either.
function parseLatestRelease(text) {
  if (typeof text !== "string" || text.length > 2000000) return null
  var data
  try { data = JSON.parse(text) } catch (e) { return null }
  if (!data || typeof data !== "object" || data.draft || data.prerelease) return null
  var v = parseVersion(data.tag_name)
  if (!v) return null
  var tag = String(data.tag_name).trim()
  return {
    version: v.join("."),
    tag: tag,
    url: RELEASES_PAGE + "tag/" + encodeURIComponent(tag),
    published: /^\d{4}-\d{2}-\d{2}T/.test(String(data.published_at || ""))
      ? String(data.published_at).slice(0, 10) : ""
  }
}

// What became of an update that was started before the plugin reloaded.
// "applied" when the installed version caught up, "failed" when it did not
// within the timeout, and "" while it is still plausibly running.
function updateAttemptState(attempt, installed, now) {
  if (!attempt || !parseVersion(attempt.version)) return ""
  if (parseVersion(installed) && !isNewerVersion(attempt.version, installed))
    return "applied"
  var at = Number(attempt.at)
  if (!isFinite(at) || now - at >= UPDATE_ATTEMPT_TIMEOUT_MS || now < at)
    return "failed"
  return ""
}

// The two lines the panel holds at a fixed height, so nothing below them
// moves while a check runs.
function updateStatusLine(installed, release, error, checkedAt) {
  var have = installed ? installed : "?"
  if (error) return "Installed " + have + " · " + error
  if (release && isNewerVersion(release.version, installed))
    return "Installed " + have + " · " + release.version + " available"
  if (release) return "Installed " + have + " · up to date"
  // Asked and told there is nothing is not the same as never having asked,
  // and the line under this one would contradict it.
  if (Number(checkedAt) > 0) return "Installed " + have + " · no releases yet"
  return "Installed " + have + " · not checked yet"
}


function updateCheckedLine(checkedAt, checking, now) {
  if (checking) return "Checking…"
  var at = Number(checkedAt)
  if (!isFinite(at) || at <= 0) return "Not checked yet"
  var minutes = Math.floor((now - at) / 60000)
  if (minutes < 1) return "Checked just now"
  if (minutes < 60) return "Checked " + plural(minutes, "minute") + " ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return "Checked " + plural(hours, "hour") + " ago"
  return "Checked " + plural(Math.floor(hours / 24), "day") + " ago"
}

// Whether a daily check is due. Worked out here so the timer is only a timer.
function updateCheckDue(checkedAt, now, enabled) {
  if (!enabled) return false
  var at = Number(checkedAt)
  if (!isFinite(at) || at <= 0) return true
  return now - at >= UPDATE_CHECK_INTERVAL_MS || now < at
}

// ----------------------------------------------------------------- editing
//
// The form works on a draft: flat values a field can hold, made from the
// event the viewer shows and turned back into an event when it is saved.
// Nothing here writes — the helper does that — so every rule about what a
// save means lives here where it can be tested without a server.
//
// A timed value leaves the draft as a wall-clock time with no offset,
// "2026-09-22T09:00:00". The offset an event arrived with belongs to the day
// it was on; move it across a DST change and that offset is an hour wrong.
// Which zone the time is in is the writer's decision, not the form's.

var DEFAULT_START = "09:00"
var DAY_CODES = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
var DAY_INITIALS = ["S", "M", "T", "W", "T", "F", "S"]

// One occurrence of a rule, or an exception to one. Either way it has
// siblings, and a change to it has to say which of them it means.
function isSeries(event) {
  return !!(event && (event.recurring || event.rid))
}

// Only once the detail is in — the href is what a write is addressed to —
// and never on a calendar shared with this account read-only.
function canEdit(event) {
  return !!(event && event.uid && event.href && !event.readonly)
}

function isDateKey(key) {
  var text = String(key || "")
  return /^\d{4}-\d{2}-\d{2}$/.test(text) && addDays(text, 0) === text
}

function isClock(clock) {
  var match = String(clock || "").match(/^(\d{2}):(\d{2})$/)
  return !!match && Number(match[1]) < 24 && Number(match[2]) < 60
}

// "HH:MM" moved by some minutes, wrapping at midnight. The date it wrapped
// into is the caller's to decide; see withField.
function addClock(clock, minutes) {
  var at = Number(clock.slice(0, 2)) * 60 + Number(clock.slice(3, 5)) + minutes
  at = ((at % DAY_MINUTES) + DAY_MINUTES) % DAY_MINUTES
  return pad(Math.floor(at / 60), 2) + ":" + pad(at % 60, 2)
}

// The offset a timed value carries, in minutes east of UTC: "-05:00" is
// -300. Zero for a value without one, which is what an all-day date is.
function offsetOf(value) {
  var match = String(value || "").match(/([+-])(\d{2}):?(\d{2})$/)
  if (!match || String(value).length < 19) return 0
  var minutes = Number(match[2]) * 60 + Number(match[3])
  return match[1] === "-" ? -minutes : minutes
}

// A signed duration in minutes, or null for anything that is not one —
// Apple's 1976 alarm placeholder, say. Two spellings of the same length
// ("-PT60M", "-PT1H") are the same number.
function durationMinutes(text) {
  var value = String(text || "").trim().toUpperCase()
  var match = value.match(/^(-|\+)?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/)
  if (!match || /T$/.test(value)) return null
  if (!match[2] && !match[3] && !match[4] && !match[5] && !match[6]) return null
  var total = ((Number(match[2] || 0) * 7 + Number(match[3] || 0)) * 24
               + Number(match[4] || 0)) * 60 + Number(match[5] || 0)
               + Number(match[6] || 0) / 60
  return match[1] === "-" ? -total : total
}

// A number of minutes as the duration it is, in the form Apple writes one.
function minutesDuration(minutes) {
  var sign = minutes < 0 ? "-" : ""
  var left = Math.abs(Math.round(minutes))
  if (left === 0) return "PT0S"
  var days = Math.floor(left / DAY_MINUTES)
  left -= days * DAY_MINUTES
  var hours = Math.floor(left / 60), mins = left % 60
  var out = sign + "P" + (days ? days + "D" : "")
  if (hours || mins) out += "T" + (hours ? hours + "H" : "") + (mins ? mins + "M" : "")
  return out
}

// ------------------------------------------------------------- repeat
//
// A rule is held as its parts — how often, every how many, on which days,
// how it ends — so each is a control of its own. Only the shapes those
// controls can say are parsed; anything else (an hourly rule, several
// month days, a rule that names months the event is not in) is kept as
// the text it came as, shown in words, and written back untouched unless
// another choice replaces it.
//
// Monthly and yearly rules that fall on a weekday follow the start date:
// "the fourth Tuesday" is whichever Tuesday the start is, so moving the
// start moves the rule with it rather than leaving a rule the event no
// longer sits on.

var REPEAT_PRESETS = [
  { value: "daily", label: "Every day" },
  { value: "weekdays", label: "Every weekday" },
  { value: "weekly", label: "Every week" },
  { value: "biweekly", label: "Every 2 weeks" },
  { value: "monthly", label: "Every month" },
  { value: "yearly", label: "Every year" }
]

var FREQ_OPTIONS = [
  { value: "DAILY", label: "Daily", unit: "day" },
  { value: "WEEKLY", label: "Weekly", unit: "week" },
  { value: "MONTHLY", label: "Monthly", unit: "month" },
  { value: "YEARLY", label: "Yearly", unit: "year" }
]

var ORDINALS = ["", "first", "second", "third", "fourth", "fifth"]
var WEEKDAYS = ["MO", "TU", "WE", "TH", "FR"]

function ruleParts(rrule) {
  var parts = {}
  var pieces = String(rrule || "").trim().split(";")
  for (var i = 0; i < pieces.length; i++) {
    var pair = pieces[i].split("=")
    if (pair.length === 2 && pair[0]) parts[pair[0].toUpperCase()] = pair[1].toUpperCase()
  }
  return parts
}

// Which of its weekday a date is in its month: the 22nd is the fourth
// Tuesday. And whether it is also the last one, which a fifth always is.
function weekdayOrdinal(key) {
  return Math.floor((parseKey(key).d - 1) / 7) + 1
}

function isLastWeekday(key) {
  return parseKey(addDays(key, 7)).m !== parseKey(key).m
}

function defaultRule(freq, startKey) {
  return {
    freq: freq,
    interval: 1,
    days: isDateKey(startKey) ? [DAY_CODES[weekdayOf(startKey)]] : [],
    monthBy: "date",
    ends: "never",
    until: "",
    count: 0
  }
}

function sameDays(a, b) {
  if (a.length !== b.length) return false
  for (var i = 0; i < a.length; i++) if (b.indexOf(a[i]) === -1) return false
  return true
}

// Days in week order, Sunday first, the order DAY_CODES and the grid use.
function sortDays(days) {
  return days.slice().sort(function (a, b) {
    return DAY_CODES.indexOf(a) - DAY_CODES.indexOf(b)
  })
}

// UNTIL as the last local date the rule reaches. A date is taken as it is.
// A UTC instant is moved into the event's own offset first: Apple ends a
// rule at the last second of the final day in local time, written in UTC,
// which for anywhere west of Greenwich is already the next day.
function untilKey(text, offsetMinutes) {
  var value = String(text || "")
  var match = value.match(/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z?))?$/)
  if (!match) return ""
  var key = match[1] + "-" + match[2] + "-" + match[3]
  if (!isDateKey(key)) return ""
  if (!match[4] || match[7] !== "Z") return key
  var minutes = Number(match[4]) * 60 + Number(match[5]) + (offsetMinutes || 0)
  return addDays(key, Math.floor(minutes / DAY_MINUTES))
}

// The rule as its parts, or null when the controls cannot say it.
// `untilDate`, when given, is the helper's own reading of UNTIL as a local
// date, made with the zone's rules; the offset is only a fallback, and is
// wrong when a DST change falls between the start and the end.
function parseRule(rrule, startKey, offsetMinutes, untilDate) {
  var parts = ruleParts(rrule)
  var known = { FREQ: 1, INTERVAL: 1, BYDAY: 1, BYMONTHDAY: 1, BYMONTH: 1,
                BYSETPOS: 1, UNTIL: 1, COUNT: 1, WKST: 1 }
  for (var key in parts) if (!known[key]) return null
  if (!parts.FREQ || !isDateKey(startKey)) return null
  var found = false
  for (var f = 0; f < FREQ_OPTIONS.length; f++) if (FREQ_OPTIONS[f].value === parts.FREQ) found = true
  if (!found || (parts.UNTIL && parts.COUNT)) return null

  var rule = defaultRule(parts.FREQ, startKey)
  if (parts.INTERVAL !== undefined) {
    var every = Number(parts.INTERVAL)
    if (!(every >= 1) || Math.floor(every) !== every) return null
    rule.interval = every
  }
  if (parts.UNTIL !== undefined) {
    rule.until = isDateKey(untilDate) ? untilDate : untilKey(parts.UNTIL, offsetMinutes)
    if (!rule.until) return null
    rule.ends = "on"
  }
  if (parts.COUNT !== undefined) {
    var times = Number(parts.COUNT)
    if (!(times >= 1) || Math.floor(times) !== times) return null
    rule.count = times
    rule.ends = "after"
  }

  var start = parseKey(startKey)
  var startDay = DAY_CODES[weekdayOf(startKey)]

  if (parts.FREQ === "DAILY") {
    if (parts.BYDAY || parts.BYMONTHDAY || parts.BYMONTH || parts.BYSETPOS) return null
    return rule
  }

  if (parts.FREQ === "WEEKLY") {
    if (parts.BYMONTHDAY || parts.BYMONTH || parts.BYSETPOS) return null
    if (parts.BYDAY) {
      var codes = parts.BYDAY.split(",")
      var days = []
      for (var d = 0; d < codes.length; d++) {
        if (DAY_CODES.indexOf(codes[d]) === -1) return null
        if (days.indexOf(codes[d]) === -1) days.push(codes[d])
      }
      rule.days = sortDays(days)
    }
    return rule
  }

  // Monthly and yearly: on the start's date, or on its weekday.
  if (parts.FREQ === "YEARLY" && parts.BYMONTH && Number(parts.BYMONTH) !== start.m) return null
  if (parts.FREQ === "MONTHLY" && parts.BYMONTH) return null
  if (parts.BYMONTHDAY) {
    if (parts.BYDAY || parts.BYSETPOS || Number(parts.BYMONTHDAY) !== start.d) return null
    return rule
  }
  if (!parts.BYDAY) return parts.BYSETPOS ? null : rule
  // A yearly weekday rule has to name its month, or it is every Tuesday
  // of the year.
  if (parts.FREQ === "YEARLY" && !parts.BYMONTH) return null

  var byday = parts.BYDAY.match(/^([+-]?\d)?([A-Z]{2})$/)
  if (!byday || byday[2] !== startDay) return null
  var ordinal = byday[1] !== undefined ? Number(byday[1]) : null
  if (parts.BYSETPOS !== undefined) {
    if (ordinal !== null) return null
    ordinal = Number(parts.BYSETPOS)
  }
  if (ordinal === -1 && isLastWeekday(startKey)) { rule.monthBy = "last"; return rule }
  if (ordinal === weekdayOrdinal(startKey) && ordinal <= 4) { rule.monthBy = "weekday"; return rule }
  return null
}

// The parts back as a rule, against a start date — the date is what an
// implicit day, and a weekday rule's day and ordinal, come from. An end
// date is written as a DATE; the writer turns it into the UTC instant a
// timed event's rule needs, because only it knows the event's zone.
function buildRule(rule, startKey) {
  var out = ["FREQ=" + rule.freq]
  if (rule.interval > 1) out.push("INTERVAL=" + rule.interval)
  var startDay = DAY_CODES[weekdayOf(startKey)]
  if (rule.freq === "WEEKLY" && rule.days.length && !sameDays(rule.days, [startDay]))
    out.push("BYDAY=" + sortDays(rule.days).join(","))
  if ((rule.freq === "MONTHLY" || rule.freq === "YEARLY") && rule.monthBy !== "date") {
    if (rule.freq === "YEARLY") out.push("BYMONTH=" + parseKey(startKey).m)
    // A fifth weekday is only ever offered as the last, and is written so.
    var ordinal = rule.monthBy === "last" || weekdayOrdinal(startKey) > 4
      ? -1 : weekdayOrdinal(startKey)
    out.push("BYDAY=" + ordinal + startDay)
  }
  if (rule.ends === "on" && isDateKey(rule.until))
    out.push("UNTIL=" + rule.until.replace(/-/g, ""))
  if (rule.ends === "after" && rule.count >= 1) out.push("COUNT=" + rule.count)
  return out.join(";")
}

// Which preset a rule is, ignoring how it ends — "Every week, until
// December" is Every week with an end — or "custom".
function presetOf(rule, startKey) {
  if (!rule) return "none"
  var startDay = isDateKey(startKey) ? DAY_CODES[weekdayOf(startKey)] : ""
  if (rule.freq === "DAILY" && rule.interval === 1) return "daily"
  if (rule.freq === "WEEKLY") {
    if (rule.interval === 1 && sameDays(rule.days, WEEKDAYS)) return "weekdays"
    if (sameDays(rule.days, [startDay])) {
      if (rule.interval === 1) return "weekly"
      if (rule.interval === 2) return "biweekly"
    }
  }
  if (rule.freq === "MONTHLY" && rule.interval === 1 && rule.monthBy === "date") return "monthly"
  if (rule.freq === "YEARLY" && rule.interval === 1 && rule.monthBy === "date") return "yearly"
  return "custom"
}

// A preset's parts, keeping whatever end the rule already had.
function presetRule(preset, startKey, current) {
  var freq = { daily: "DAILY", weekdays: "WEEKLY", weekly: "WEEKLY", biweekly: "WEEKLY",
               monthly: "MONTHLY", yearly: "YEARLY" }[preset]
  var rule = defaultRule(freq, startKey)
  if (preset === "weekdays") rule.days = WEEKDAYS.slice()
  if (preset === "biweekly") rule.interval = 2
  if (current) {
    rule.ends = current.ends
    rule.until = current.until
    rule.count = current.count
  }
  return rule
}

// Kept for its existing callers: what the dropdown shows for a stored rule.
function repeatKey(rrule, startKey) {
  if (String(rrule || "").trim() === "") return "none"
  var rule = parseRule(rrule, startKey, 0)
  return rule ? presetOf(rule, startKey) : "kept"
}

// The dropdown's rows: Never, the presets, Custom, and a rule the controls
// cannot say offered as itself in words, so opening the form on one does
// not quietly replace it.
function repeatChoices(draft) {
  var out = [{ value: "none", label: "Never" }]
  for (var i = 0; i < REPEAT_PRESETS.length; i++) out.push(REPEAT_PRESETS[i])
  out.push({ value: "custom", label: "Custom\u2026" })
  if (draft && draft.repeat === "kept")
    out.push({ value: "kept", label: describeRecurrence(draft.rrule) })
  return out
}

function freqOptions() { return FREQ_OPTIONS }

function freqUnit(freq, count) {
  for (var i = 0; i < FREQ_OPTIONS.length; i++)
    if (FREQ_OPTIONS[i].value === freq)
      return FREQ_OPTIONS[i].unit + (count === 1 ? "" : "s")
  return ""
}

// The week's days as the day toggles show them, from the card's own week
// start so the row reads like the month above it.
function dayToggles(weekStartDay) {
  var out = []
  for (var i = 0; i < 7; i++) {
    var day = (i + (weekStartDay || 0)) % 7
    out.push({ value: DAY_CODES[day], label: DAY_INITIALS[day], name: DAY_NAMES[day] })
  }
  return out
}

// "On day 22", "On the fourth Tuesday", "On the last Tuesday" — whichever
// the start date can be. A fifth Tuesday is always the last, and a rule on
// "the fifth" would skip every month that has four, so it is only offered
// as the last.
function monthByOptions(startKey, freq) {
  if (!isDateKey(startKey)) return []
  var p = parseKey(startKey)
  var day = DAY_NAMES[weekdayOf(startKey)]
  var inMonth = freq === "YEARLY" ? " of " + MONTH_NAMES[p.m - 1] : ""
  var out = [{ value: "date", label: freq === "YEARLY"
               ? "On " + MONTH_NAMES[p.m - 1] + " " + p.d : "On day " + p.d }]
  var ordinal = weekdayOrdinal(startKey)
  if (ordinal <= 4)
    out.push({ value: "weekday", label: "On the " + ORDINALS[ordinal] + " " + day + inMonth })
  if (isLastWeekday(startKey))
    out.push({ value: "last", label: "On the last " + day + inMonth })
  return out
}

var END_OPTIONS = [
  { value: "never", label: "Never" },
  { value: "on", label: "On date" },
  { value: "after", label: "After" }
]

function endOptions() { return END_OPTIONS }

// The rule the draft stands for, in words, under the controls — so a
// custom rule is read back the way it will be kept.
function ruleSummary(draft) {
  if (!draft || draft.repeat === "none") return ""
  if (draft.repeat === "kept") return describeRecurrence(draft.rrule)
  var rule = draft.rule
  var unit = freqUnit(rule.freq, rule.interval)
  var out = rule.interval === 1 ? "Every " + unit : "Every " + rule.interval + " " + unit
  if (rule.freq === "WEEKLY" && rule.days.length) {
    var names = []
    var ordered = sortDays(rule.days)
    for (var i = 0; i < ordered.length; i++)
      names.push(DAY_NAMES[DAY_CODES.indexOf(ordered[i])].slice(0, 3))
    out += " on " + names.join(", ")
  }
  if (rule.freq === "MONTHLY" || rule.freq === "YEARLY") {
    var options = monthByOptions(draft.startDate, rule.freq)
    for (var o = 0; o < options.length; o++)
      if (options[o].value === rule.monthBy)
        out += ", " + options[o].label.charAt(0).toLowerCase() + options[o].label.slice(1)
  }
  if (rule.ends === "on" && isDateKey(rule.until)) out += ", until " + longDate(rule.until)
  if (rule.ends === "after" && rule.count >= 1)
    out += ", " + rule.count + (rule.count === 1 ? " time" : " times")
  return out
}

// ------------------------------------------------------------- alerts
//
// Values are the TRIGGER itself, so a choice needs no table to be written.
// An all-day event starts at midnight, and "15 minutes before" one is a
// quarter to twelve the night before; its choices are times of day instead.

var ALERT_OPTIONS = [
  { value: "none", label: "None" },
  { value: "PT0S", label: "At the time of the event" },
  { value: "-PT5M", label: "5 minutes before" },
  { value: "-PT10M", label: "10 minutes before" },
  { value: "-PT15M", label: "15 minutes before" },
  { value: "-PT30M", label: "30 minutes before" },
  { value: "-PT1H", label: "1 hour before" },
  { value: "-PT2H", label: "2 hours before" },
  { value: "-P1D", label: "1 day before" },
  { value: "-P2D", label: "2 days before" },
  { value: "-P1W", label: "1 week before" }
]

var ALL_DAY_ALERT_OPTIONS = [
  { value: "none", label: "None" },
  { value: "PT9H", label: "On the day, 9 AM" },
  { value: "-PT15H", label: "1 day before, 9 AM" },
  { value: "-P1DT15H", label: "2 days before, 9 AM" },
  { value: "-P6DT15H", label: "1 week before, 9 AM" }
]

// The form edits two alerts, the most any calendar on a phone offers.
var ALERT_SLOTS = 2

function alarmMinutes(trigger) {
  return durationMinutes(trigger)
}

function alertPresets(allDay) {
  return allDay ? ALL_DAY_ALERT_OPTIONS : ALERT_OPTIONS
}

// The preset a trigger is, by the moment it names rather than its spelling;
// the trigger itself when no preset matches.
function alertValue(trigger, allDay) {
  var minutes = alarmMinutes(trigger)
  if (minutes === null) return "none"
  var presets = alertPresets(allDay)
  for (var i = 1; i < presets.length; i++)
    if (alarmMinutes(presets[i].value) === minutes) return presets[i].value
  return String(trigger).trim().toUpperCase()
}

// One slot's rows. A trigger no preset matches is offered as itself.
function alertChoices(draft, slot) {
  var presets = alertPresets(draft && draft.allDay)
  var out = presets.slice()
  var value = draft ? draft.alerts[slot || 0] : "none"
  if (value && value !== "none") {
    for (var i = 0; i < presets.length; i++)
      if (presets[i].value === value) return out
    out.push({ value: value, label: describeAlarm(value) || value })
  }
  return out
}

// The alarms an event leaves with. The form edits the first two that mean
// anything, in place; every other alarm, placeholders included, goes back
// exactly as it came. A slot switched off takes its alarm out; a slot set
// that had none adds one at the end.
function draftAlarms(draft) {
  var out = (draft.alarms || []).slice()
  var drop = []
  for (var slot = 0; slot < ALERT_SLOTS; slot++) {
    var index = draft.alertIndexes[slot]
    var value = draft.alerts[slot]
    if (index >= 0) {
      if (value === "none") drop.push(index)
      else out[index] = value
    }
  }
  drop.sort(function (a, b) { return b - a })
  for (var d = 0; d < drop.length; d++) out.splice(drop[d], 1)
  for (slot = 0; slot < ALERT_SLOTS; slot++)
    if (draft.alertIndexes[slot] < 0 && draft.alerts[slot] !== "none") out.push(draft.alerts[slot])
  return out
}

// ------------------------------------------------------------- travel
//
// Apple's travel time is a duration blocked out before the event. It can
// also be worked out from a route in Apple Maps, which is not open to
// anyone else; this sets the plain duration, which Apple writes the same
// way. A length the list does not have — a routed 23 minutes — is offered
// as itself.

var TRAVEL_OPTIONS = [0, 5, 10, 15, 30, 60, 90, 120]

function travelLabel(minutes) {
  if (!minutes) return "None"
  if (minutes < 60) return minutes + " minutes"
  var hours = minutes / 60
  if (hours === Math.floor(hours)) return hours === 1 ? "1 hour" : hours + " hours"
  if (minutes % 30 === 0) return hours + " hours"
  return Math.floor(hours) + " h " + (minutes % 60) + " min"
}

function travelChoices(draft) {
  var out = []
  for (var i = 0; i < TRAVEL_OPTIONS.length; i++)
    out.push({ value: String(TRAVEL_OPTIONS[i]), label: travelLabel(TRAVEL_OPTIONS[i]) })
  var current = draft ? Number(draft.travel) : 0
  if (current > 0 && TRAVEL_OPTIONS.indexOf(current) === -1)
    out.push({ value: String(current), label: travelLabel(current) })
  return out
}

// --------------------------------------------------------- invitees

// An address a mail server would take, by the shape RFC 5321 allows for
// the ones people actually have. Deliberately not the whole grammar —
// quoted local parts and bare IP domains are legal and nobody types them —
// and deliberately not looser than it: a typo that gets through here goes
// out as an invitation to nobody.
function isEmail(text) {
  var value = String(text || "").trim()
  if (value.length > 254) return false
  var at = value.lastIndexOf("@")
  if (at < 1 || at !== value.indexOf("@")) return false
  var local = value.slice(0, at), domain = value.slice(at + 1)
  if (local.length > 64) return false
  if (!/^[A-Za-z0-9!#$%&'*+\/=?^_`{|}~-]+(\.[A-Za-z0-9!#$%&'*+\/=?^_`{|}~-]+)*$/.test(local))
    return false
  var labels = domain.split(".")
  if (labels.length < 2) return false
  for (var i = 0; i < labels.length; i++)
    if (!/^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/.test(labels[i])) return false
  return /^[A-Za-z]{2,}$/.test(labels[labels.length - 1])
}

function sameEmail(a, b) {
  return String(a || "").trim().toLowerCase() === String(b || "").trim().toLowerCase()
}

// Only whoever organises an event can change who is invited to it; an
// event with nobody invited yet is yours to invite people to.
function canInvite(event, account) {
  if (!event) return false
  var organizer = String(event.organizer || "")
  return !organizer || sameEmail(organizer, account)
}

// What stops an address being added, or "".
function inviteeProblem(draft, email, account) {
  var value = String(email || "").trim()
  if (!value) return ""
  if (!isEmail(value)) return "Invalid email. Please fix or remove."
  if (sameEmail(value, account)) return "That\u2019s you \u2014 you\u2019re the organiser."
  var list = draft ? draft.invitees : []
  for (var i = 0; i < list.length; i++)
    if (sameEmail(list[i].email, value)) return "Already invited."
  return ""
}

function withInvitee(draft, email, name) {
  var out = withField(draft, "invitees", draft.invitees.concat([
    { email: String(email).trim(), name: String(name || "").trim(), status: "NEEDS-ACTION" }]))
  return out
}

function withoutInvitee(draft, email) {
  var kept = []
  for (var i = 0; i < draft.invitees.length; i++)
    if (!sameEmail(draft.invitees[i].email, email)) kept.push(draft.invitees[i])
  return withField(draft, "invitees", kept)
}

var STATUS_LABELS = { "ACCEPTED": "Accepted", "DECLINED": "Declined",
                      "TENTATIVE": "Maybe", "NEEDS-ACTION": "No reply yet",
                      "DELEGATED": "Delegated" }

function inviteeStatus(status) {
  return STATUS_LABELS[String(status || "").toUpperCase()] || "No reply yet"
}

// Contacts that match what is being typed, by name or address, those
// starting with it first. Anyone already invited is left out, and so is
// every address a contact has that is not one.
function contactSuggestions(contacts, query, draft, limit) {
  var needle = String(query || "").trim().toLowerCase()
  if (needle.length < 2) return []
  var starts = [], within = []
  var invited = draft ? draft.invitees : []
  for (var i = 0; i < (contacts || []).length; i++) {
    var c = contacts[i]
    if (!isEmail(c.email)) continue
    var taken = false
    for (var j = 0; j < invited.length; j++) if (sameEmail(invited[j].email, c.email)) taken = true
    if (taken) continue
    var name = String(c.name || "").toLowerCase(), email = String(c.email).toLowerCase()
    var words = name.split(/\s+/)
    var prefix = email.indexOf(needle) === 0
    for (var w = 0; w < words.length; w++) if (words[w].indexOf(needle) === 0) prefix = true
    if (prefix) starts.push(c)
    else if (name.indexOf(needle) !== -1 || email.indexOf(needle) !== -1) within.push(c)
  }
  return starts.concat(within).slice(0, limit || 6)
}

// ------------------------------------------------------- attachments
//
// An attachment already on the event is known by the id iCloud gave it (or
// its name, for one that came with an emailed invitation); one picked to
// add is known by its path until a save uploads it.

function attachmentKeys(list) {
  var out = []
  for (var i = 0; i < list.length; i++) {
    var a = list[i]
    out.push(a.path ? "add:" + a.path : "has:" + (a.managedId || a.name))
  }
  return out
}

function attachmentLabel(a) {
  var size = Number(a && a.size) || 0
  return size > 0 ? a.name + " \u00b7 " + byteLabel(size) : String(a ? a.name : "")
}

function attachmentLines(list) {
  var out = []
  for (var i = 0; i < (list || []).length; i++) out.push(attachmentLabel(list[i]))
  return out
}

function withoutAttachment(draft, index) {
  var list = draft.attachments.slice()
  list.splice(index, 1)
  return withField(draft, "attachments", list)
}

// What the helper's file picker answered: the file picked, null when
// nothing was (a cancel), or { error } when the picker could not open.
function parsePicked(text) {
  var payload
  try { payload = JSON.parse(String(text || "").trim()) } catch (e) { return null }
  if (!payload) return null
  if (!payload.ok) return { error: "The file picker could not open: " + (payload.error || "unknown error") }
  if (!payload.picked || String(payload.path || "").charAt(0) !== "/") return null
  return { path: payload.path, name: payload.name || "", size: Number(payload.size) || 0 }
}

// iCloud's limits on attachments, as Apple states them — not published by
// the server itself, which answers "not found" when asked. 20 MB is taken
// as 20,000,000 bytes, the smaller reading, so a file that passes here
// cannot be the one iCloud refuses for size.
var MAX_ATTACHMENTS = 20
var MAX_ATTACHMENT_BYTES = 20 * 1000 * 1000
// A name iCloud will not load or sync. "/" can never reach here — it ends
// a path — but it is listed because Apple lists it.
var BAD_NAME_CHARS = /[\\\/:*?"<>|]/

function attachmentBytes(list) {
  var total = 0
  for (var i = 0; i < (list || []).length; i++) total += Number(list[i].size) || 0
  return total
}

// Why a file cannot join the event, or "".
function attachmentProblem(draft, file) {
  var list = draft ? draft.attachments : []
  var name = String(file && (file.name || String(file.path || "").split("/").pop()) || "")
  if (list.length >= MAX_ATTACHMENTS)
    return "An event can hold " + MAX_ATTACHMENTS + " attachments."
  if (BAD_NAME_CHARS.test(name))
    return "iCloud can\u2019t sync a file named with \\ / : * ? \" < > | \u2014 rename it first."
  var size = Number(file && file.size) || 0
  if (attachmentBytes(list) + size > MAX_ATTACHMENT_BYTES)
    return name + " would take the event past iCloud\u2019s 20 MB for attachments."
  return ""
}

// The line under the list: how much of the allowance is used.
function attachmentSummary(list) {
  var count = (list || []).length
  if (count === 0) return "None"
  return count + " of " + MAX_ATTACHMENTS + " \u00b7 "
       + byteLabel(attachmentBytes(list)) + " of 20 MB"
}

// A file picked to add. The same path twice is one file.
function withAttachment(draft, file) {
  var path = String(file && file.path || "")
  if (!path) return draft
  for (var i = 0; i < draft.attachments.length; i++)
    if (draft.attachments[i].path === path) return draft
  var name = String(file.name || path.split("/").pop())
  return withField(draft, "attachments", draft.attachments.concat([
    { name: name, size: Number(file.size) || 0, path: path, managedId: "", type: "", url: "" }]))
}

// -------------------------------------------------------------- draft

// Every 15 minutes of a day, as the time dropdown lists them. A time off
// that grid — an event at 10:05 — is slotted into its place rather than
// being rounded, so the form never moves an event nobody asked it to move.
function timeChoices(timeFormat, current) {
  var out = []
  var extra = isClock(current) ? current : ""
  for (var at = 0; at < DAY_MINUTES; at += 15) {
    var clock = pad(Math.floor(at / 60), 2) + ":" + pad(at % 60, 2)
    if (extra && extra < clock) {
      out.push({ value: extra, label: formatTime("2000-01-01T" + extra, timeFormat) })
      extra = ""
    }
    if (clock === extra) extra = ""
    out.push({ value: clock, label: formatTime("2000-01-01T" + clock, timeFormat) })
  }
  if (extra) out.push({ value: extra, label: formatTime("2000-01-01T" + extra, timeFormat) })
  return out
}

// "Tue, Sep 22, 2026" — the date field's face, short enough to sit beside
// a time in a sidebar.
function shortDate(key) {
  if (!isDateKey(key)) return ""
  var p = parseKey(key)
  return DAY_NAMES[weekdayOf(key)].slice(0, 3) + ", "
       + MONTH_NAMES[p.m - 1].slice(0, 3) + " " + p.d + ", " + p.y
}

// Where a new event goes: the calendar the person chose in settings, while
// it can still be written to; otherwise the busiest writable calendar of
// the first account — the one in use, rather than the first by name, which
// put new events in Birthdays, and within one account, so a second account
// with a busier calendar does not take them over. Failing that, the busiest
// anywhere. Empty when nothing can be written to.
//
// A provider's own default would beat all of this, but iCloud does not
// publish one: `schedule-default-calendar-URL` comes back empty (probed
// 2026-09-21).
function defaultCalendar(calendars, chosen, primaryAccount) {
  var best = "", most = -1, bestHere = "", mostHere = -1
  for (var i = 0; i < (calendars || []).length; i++) {
    var cal = calendars[i]
    if (cal.enabled === false || cal.readonly) continue
    if (chosen && cal.url === chosen) return chosen
    var count = Number(cal.objects) || 0
    if (count > most) { most = count; best = cal.url }
    if ((cal.account || "") === (primaryAccount || "") && count > mostHere) {
      mostHere = count
      bestHere = cal.url
    }
  }
  return bestHere || best
}

// Said under the setting when the calendar chosen there has gone — its
// account removed, or it switched off or made read-only.
function defaultCalendarNote(calendars, chosen, primaryAccount) {
  if (!chosen) return ""
  if (defaultCalendar(calendars, chosen, primaryAccount) === chosen) return ""
  var instead = calendarOf(calendars, defaultCalendar(calendars, "", primaryAccount))
  return "The calendar chosen here can\u2019t take new events any more"
       + (instead ? "; they go to " + singleLine(instead.name) + " until you pick another." : ".")
}

// A new event, as the form starts it: an hour long on the day selected,
// at the next full hour when that day is today and at nine otherwise, in
// the first calendar it can be written to. It has no uid — nothing on the
// server knows it yet — and no rule, alarms or invitees.
function newEvent(dayKey, todayKey, nowClock, calendarUrl) {
  var start = DEFAULT_START
  if (dayKey === todayKey && isClock(nowClock)) {
    var hour = Number(nowClock.slice(0, 2)) + 1
    // Past eleven there is no next hour left in the day to start it at.
    start = hour <= 23 ? pad(hour, 2) + ":00" : "23:00"
  }
  var end = addClock(start, 60)
  var endDay = end < start ? addDays(dayKey, 1) : dayKey
  return {
    uid: "", title: "", calendarUrl: calendarUrl || "", allDay: false,
    start: dayKey + "T" + start + ":00", end: endDay + "T" + end + ":00",
    rrule: "", alarms: [], attendeeList: [], attachments: [],
    location: "", url: "", description: ""
  }
}

// A copy of an event, as a new event's starting point: everything that
// describes it, on the occurrence that was open, but nothing that ties it to
// the original — no uid, no href, no etag. Invitees are left off, since
// saving would send each of them a second invitation, and so are
// attachments, which live on the server under the original and would have
// to be downloaded to go anywhere else.
function duplicateOf(event) {
  var e = event || {}
  var out = {}
  for (var key in e) out[key] = e[key]
  out.uid = ""
  out.href = ""
  out.etag = ""
  out.rid = ""
  out.recurring = false
  out.organizer = ""
  out.attendees = []
  out.attendeeList = []
  out.attachments = []
  // The rule is kept as written; the copy repeats the way the original does.
  // An exception carries none of its own, so its copy is a single event.
  return out
}

// The form's starting point, from the event the viewer is showing.
//
// An all-day event's end is exclusive, and the form shows the last day it
// covers instead — nobody thinks of a one-day event as ending tomorrow. It
// also gets times to fall back on, so switching All day off lands on an
// hour rather than on midnight to midnight.
//
// Times are the event's own: in the zone each end is written in, as the
// helper read them (startWall, endWall), so an event set for 09:00 in Tokyo
// edits as 09:00 Tokyo. Without them — a new event, or an event that has no
// zone — they are the viewer's, and the zones default to `localZone`.
function editDraft(event, localZone) {
  var e = event || {}
  var allDay = !!e.allDay
  var here = localZone || e.localZone || ""
  var startSource = !allDay && e.startWall ? e.startWall : e.start
  var endSource = !allDay && e.endWall ? e.endWall : e.end
  var startDate = dateKey(startSource)
  var endDate = dateKey(endSource) || startDate
  var startTime = allDay ? DEFAULT_START : (timeOf(startSource) || DEFAULT_START)
  var endTime = allDay ? addClock(startTime, 60) : (timeOf(endSource) || addClock(startTime, 60))
  if (allDay) {
    endDate = addDays(endDate, -1)
    if (!isDateKey(endDate) || endDate < startDate) endDate = startDate
  }

  var alarms = (e.alarms || []).slice()
  var alerts = [], alertIndexes = []
  for (var i = 0; i < alarms.length && alerts.length < ALERT_SLOTS; i++) {
    if (alarmMinutes(alarms[i]) === null) continue
    alerts.push(alertValue(alarms[i], allDay))
    alertIndexes.push(i)
  }
  while (alerts.length < ALERT_SLOTS) { alerts.push("none"); alertIndexes.push(-1) }

  var offset = offsetOf(e.start)
  var rrule = e.rrule || ""
  var rule = rrule ? parseRule(rrule, startDate, offset, e.untilDate) : null
  var repeat = !rrule ? "none" : rule ? presetOf(rule, startDate) : "kept"

  var travel = durationMinutes(e.travel)
  var invitees = []
  var list = e.attendeeList || []
  for (var a = 0; a < list.length; a++)
    invitees.push({ email: list[a].email || "", name: list[a].name || "",
                    status: list[a].status || "NEEDS-ACTION" })

  var startZone = (e.startZone && e.startZone !== "") ? e.startZone : here
  var endZone = (e.endZone && e.endZone !== "") ? e.endZone : startZone

  return {
    title: e.title || "",
    calendarUrl: e.calendarUrl || "",
    allDay: allDay,
    localZone: here,
    startZone: startZone,
    endZone: endZone,
    startDate: startDate,
    startTime: startTime,
    endDate: endDate,
    endTime: endTime,
    repeat: repeat,
    rule: rule || defaultRule("WEEKLY", startDate),
    rrule: rrule,
    untilDate: e.untilDate || "",
    ruleTouched: false,
    offset: offset,
    alerts: alerts,
    alertIndexes: alertIndexes,
    alarms: alarms,
    travel: travel !== null && travel > 0 ? String(Math.round(travel)) : "0",
    invitees: invitees,
    location: e.location || "",
    // The point the address is at, when Apple stored one or a suggestion
    // brought one. Typing over the address lets it go: the point no longer
    // says where the words do.
    place: e.place || null,
    // Files already on the event, and any picked to go with it. Only a
    // name and a size are shown; what a save does with them is the writer's.
    attachments: (e.attachments || []).slice(),
    conference: e.conference || "",
    url: e.url || "",
    notes: e.description || ""
  }
}

function copyOf(draft) {
  var out = {}
  for (var key in draft) out[key] = draft[key]
  return out
}

// A copy with one field changed, for a binding to notice. Moving the start
// carries the end with it, the way every calendar does: the length of the
// event is what was set, and a start dragged past its end is not a request
// for a negative one.
function withField(draft, field, value) {
  var out = copyOf(draft)
  out[field] = value

  if ((field === "startDate" || field === "startTime") && isDateKey(draft.startDate)
      && isDateKey(out.startDate)) {
    if (draft.allDay || field === "startDate") {
      var shift = daysBetween(draft.startDate, out.startDate)
      if (isDateKey(draft.endDate)) out.endDate = addDays(draft.endDate, shift)
    } else if (isClock(draft.startTime) && isClock(value) && isClock(draft.endTime)) {
      var length = minutesBetween(draft, draft.endDate, draft.endTime)
      var moved = Number(value.slice(0, 2)) * 60 + Number(value.slice(3, 5)) + length
      out.endDate = addDays(out.startDate, Math.floor(moved / DAY_MINUTES))
      out.endTime = addClock("00:00", moved)
    }
  }

  if (field === "location" && value !== draft.location) out.place = null

  // The end follows the start into another zone, unless it was already set
  // to one of its own — a flight lands where it lands.
  if (field === "startZone" && draft.endZone === draft.startZone) out.endZone = value

  // A rule nobody has touched is read again against the new start, so one
  // that was implicitly "on the start's day" still says so.
  if (field === "startDate" && !draft.ruleTouched && draft.rrule
      && draft.repeat !== "kept") {
    var reread = parseRule(draft.rrule, out.startDate, draft.offset, draft.untilDate)
    if (reread) out.rule = reread
  }

  // Picking from the dropdown. A preset replaces the rule but keeps its
  // end; Custom opens the controls on the rule as it stands.
  if (field === "repeat") {
    out.ruleTouched = true
    if (value !== "none" && value !== "custom" && value !== "kept")
      out.rule = presetRule(value, out.startDate, draft.rule)
  }

  // Switching All day changes which alerts make sense; each one set keeps
  // its moment and is offered as itself if it is not in the new list.
  if (field === "allDay") {
    out.alerts = []
    for (var s = 0; s < draft.alerts.length; s++)
      out.alerts.push(draft.alerts[s] === "none" ? "none" : alertValue(draft.alerts[s], value))
  }
  return out
}

// One part of the rule changed from the custom controls.
function withRule(draft, part, value) {
  var rule = {}
  for (var key in draft.rule) rule[key] = draft.rule[key]
  rule[part] = value
  if (part === "freq" && value === "WEEKLY" && !rule.days.length)
    rule.days = [DAY_CODES[weekdayOf(draft.startDate)]]
  // A rule ending on a date needs a date; a month on is where Apple starts.
  if (part === "ends" && value === "on" && !isDateKey(rule.until))
    rule.until = addDays(draft.startDate, 30)
  if (part === "ends" && value === "after" && !(rule.count >= 1)) rule.count = 10
  var out = withField(draft, "rule", rule)
  out.ruleTouched = true
  return out
}

// A day toggled in or out of a weekly rule. The last one cannot go: a
// weekly rule on no days is no rule.
function withDayToggled(draft, code) {
  var days = draft.rule.days.slice()
  var at = days.indexOf(code)
  if (at === -1) days.push(code)
  else if (days.length > 1) days.splice(at, 1)
  return withRule(draft, "days", sortDays(days))
}

function withAlert(draft, slot, value) {
  var alerts = draft.alerts.slice()
  alerts[slot] = value
  return withField(draft, "alerts", alerts)
}

function minutesBetween(draft, endDate, endTime) {
  return daysBetween(draft.startDate, endDate) * DAY_MINUTES
       + (Number(endTime.slice(0, 2)) - Number(draft.startTime.slice(0, 2))) * 60
       + Number(endTime.slice(3, 5)) - Number(draft.startTime.slice(3, 5))
}

// What stops a save, in the words the form shows under itself. Empty when
// nothing does. A timed event may end the moment it starts — iCalendar
// allows it and reminders are made that way — but never before.
// `typedInvitee` is whatever is in the add box and not yet added: saving
// past it would drop someone the person meant to invite.
function draftProblem(draft, typedInvitee) {
  if (!draft) return "Nothing to save."
  if (!singleLine(draft.title)) return "Give the event a title."
  if (!isDateKey(draft.startDate) || !isDateKey(draft.endDate))
    return "Pick a start and an end date."
  if (draft.allDay) {
    if (draft.endDate < draft.startDate) return "It ends before it starts."
  } else {
    if (!isClock(draft.startTime) || !isClock(draft.endTime))
      return "Pick a start and an end time."
    // Two walls in two zones cannot be compared as text; the helper keeps
    // the times as given and iCloud shows them where each belongs.
    if (draft.startZone === draft.endZone
        && draft.endDate + "T" + draft.endTime < draft.startDate + "T" + draft.startTime)
      return "It ends before it starts."
  }
  if (draft.repeat !== "none" && draft.repeat !== "kept") {
    var rule = draft.rule
    if (!(rule.interval >= 1) || Math.floor(rule.interval) !== rule.interval)
      return "Repeat every 1 or more."
    if ((rule.freq === "MONTHLY" || rule.freq === "YEARLY") && rule.monthBy !== "date") {
      var fits = false, options = monthByOptions(draft.startDate, rule.freq)
      for (var o = 0; o < options.length; o++) if (options[o].value === rule.monthBy) fits = true
      if (!fits) return "Pick which day of the month it repeats on."
    }
    if (rule.ends === "on" && (!isDateKey(rule.until) || rule.until < draft.startDate))
      return "The repeat has to end on or after the first day."
    if (rule.ends === "after" && !(rule.count >= 1 && Math.floor(rule.count) === rule.count))
      return "The repeat has to run at least once."
  }
  if (String(draft.conference || "").trim()
      && !/^[a-z][a-z0-9+.-]*:/i.test(String(draft.conference).trim()))
    return "A video call needs its full address, like https:// or tel:."
  if (String(draft.url || "").trim() && !/^[a-z][a-z0-9+.-]*:/i.test(String(draft.url).trim()))
    return "A link needs its scheme, like https://."
  var files = draft.attachments || []
  if (files.length > MAX_ATTACHMENTS)
    return "Remove attachments down to " + MAX_ATTACHMENTS + "."
  if (attachmentBytes(files) > MAX_ATTACHMENT_BYTES)
    return "Attachments come to more than iCloud\u2019s 20 MB for one event."
  // Something typed in the invitee box and never added: saving past it
  // would drop someone the person meant to invite. Said as what is wrong
  // with it when it is not an address at all.
  var typed = String(typedInvitee || "").trim()
  if (typed && !isEmail(typed)) return "Invalid email. Please fix or remove."
  if (typed) return "Add the invitee you typed, or clear it."
  return ""
}

// The event a draft stands for, in the backend's shape. All-day ends go
// back to exclusive here, the one place they were made inclusive. A rule
// nobody touched goes back as the text it came as, so opening and saving
// an event never rewrites a rule the form merely read.
function draftEvent(draft) {
  var rrule = ""
  if (draft.repeat === "kept" || (!draft.ruleTouched && draft.repeat !== "none"))
    rrule = draft.rrule
  else if (draft.repeat !== "none")
    rrule = buildRule(draft.rule, draft.startDate)

  var travel = Number(draft.travel) || 0
  var invitees = []
  for (var i = 0; i < draft.invitees.length; i++)
    invitees.push(String(draft.invitees[i].email).trim().toLowerCase())

  return {
    title: String(draft.title || "").trim(),
    calendarUrl: draft.calendarUrl,
    allDay: !!draft.allDay,
    start: draft.allDay ? draft.startDate : draft.startDate + "T" + draft.startTime + ":00",
    end: draft.allDay ? addDays(draft.endDate, 1) : draft.endDate + "T" + draft.endTime + ":00",
    rrule: rrule,
    // A date has no zone; a time is in the zone chosen for its end.
    startZone: draft.allDay ? "" : (draft.startZone || ""),
    endZone: draft.allDay ? "" : (draft.endZone || draft.startZone || ""),
    alarms: draftAlarms(draft),
    // Apple has no travel time on an all-day event.
    travel: !draft.allDay && travel > 0 ? minutesDuration(travel) : "",
    invitees: invitees,
    location: draft.location,
    place: draft.place ? { lat: draft.place.lat, lon: draft.place.lon,
                           title: draft.place.title || "" } : null,
    attachments: attachmentKeys(draft.attachments || []),
    // RFC 7986 CONFERENCE: a video call or dial-in, apart from the URL.
    conference: String(draft.conference || "").trim(),
    url: String(draft.url || "").trim(),
    description: draft.notes
  }
}

var EDIT_FIELDS = ["title", "calendarUrl", "allDay", "start", "end", "startZone", "endZone", "rrule",
                   "alarms", "travel", "invitees", "location", "place", "attachments",
                   "conference", "url", "description"]

// Which fields a save would change. The original goes through the same
// draft and back, so a value the form spells differently from how it was
// stored — an exclusive end, a trimmed title — is not mistaken for an edit.
function draftChanges(draft, original) {
  var now = draftEvent(draft)
  var was = draftEvent(editDraft(original, draft.localZone))
  var out = []
  for (var i = 0; i < EDIT_FIELDS.length; i++) {
    var key = EDIT_FIELDS[i]
    if (JSON.stringify(now[key]) !== JSON.stringify(was[key])) out.push(key)
  }
  return out
}

// ----------------------------------------------------------- requests
//
// What a save or a delete asks the helper to do, as one object. The helper
// edits the stored event rather than rebuilding it, so it is told what
// changed, not handed the whole event to overwrite.

// The alarms, as edits to the ones the event already has: which to change
// (by the index the form counted them at), which to take out, which to add.
// Alarms the form never showed are not mentioned, so they are left alone.
function alarmPlan(draft) {
  var plan = { set: {}, remove: [], add: [] }
  for (var slot = 0; slot < ALERT_SLOTS; slot++) {
    var index = draft.alertIndexes[slot]
    var value = draft.alerts[slot]
    if (index >= 0) {
      if (value === "none") plan.remove.push(index)
      else if (alarmMinutes(value) !== alarmMinutes(draft.alarms[index])) plan.set[index] = value
    } else if (value !== "none") {
      plan.add.push(value)
    }
  }
  return plan
}

// Files: picked ones to upload, and the ones taken out — by iCloud's id for
// an uploaded file, by name for one that came with an emailed invitation.
function attachmentPlan(draft, base) {
  var add = [], removeManaged = [], removeNames = []
  var kept = {}
  for (var i = 0; i < draft.attachments.length; i++) {
    var a = draft.attachments[i]
    if (a.path) add.push({ path: a.path, type: a.type || "" })
    else kept[a.managedId || ("name:" + a.name)] = true
  }
  var before = (base && base.attachments) || []
  for (var b = 0; b < before.length; b++) {
    var was = before[b]
    if (kept[was.managedId || ("name:" + was.name)]) continue
    if (was.managedId) removeManaged.push(was.managedId)
    else removeNames.push(was.name)
  }
  return { addFiles: add, removeManaged: removeManaged, removeNames: removeNames }
}

// The occurrence a series edit is about: where it starts, and its rid when
// it is an exception — the helper finds an exception by its rid, since its
// start may have been moved off its slot.
function occurrenceOf(seed) {
  return { occurrenceStart: seed ? String(seed.start || "") : "",
           rid: seed ? String(seed.rid || "") : "" }
}

function saveRequest(draft, base, seed, scope, creating, organizer) {
  var files = attachmentPlan(draft, base)
  var where = occurrenceOf(creating ? null : seed)
  var invitees = []
  for (var i = 0; i < draft.invitees.length; i++)
    invitees.push({ email: draft.invitees[i].email, name: draft.invitees[i].name || "" })
  return {
    href: creating ? "" : String(base.href || ""),
    etag: creating ? "" : String(base.etag || ""),
    calendarUrl: creating ? "" : String(base.calendarUrl || ""),
    targetCalendarUrl: draft.calendarUrl,
    scope: scope || "",
    occurrenceStart: where.occurrenceStart,
    rid: where.rid,
    changes: creating ? EDIT_FIELDS.slice() : draftChanges(draft, base),
    event: draftEvent(draft),
    alarmPlan: creating ? { set: {}, remove: [], add: draftAlarms(draft) } : alarmPlan(draft),
    invitees: invitees,
    organizer: organizer || "",
    addFiles: files.addFiles,
    removeManaged: files.removeManaged,
    removeNames: files.removeNames
  }
}

function deleteRequest(base, seed, scope) {
  var where = occurrenceOf(seed)
  return {
    href: String(base.href || ""), etag: String(base.etag || ""),
    calendarUrl: String(base.calendarUrl || ""), scope: scope || "",
    occurrenceStart: isSeries(base) ? where.occurrenceStart : "",
    rid: isSeries(base) ? where.rid : ""
  }
}

// What the foot says after a write came back.
function writeOutcome(action, payload) {
  if (!payload) return { done: false, message: "omarcal could not reach its helper." }
  if (!payload.ok) return { done: false, conflict: payload.code === "conflict",
                            message: payload.error || "That did not save." }
  if (payload.queued)
    return { done: true, queued: true,
             message: (action === "delete" ? "Deleted" : "Saved")
               + " on this computer \u2014 iCloud can\u2019t be reached, so it will be "
               + "sent the next time it can." }
  var problems = payload.problems || []
  var said = action === "delete" ? "Deleted." : "Saved."
  if (problems.length) said += " But " + problems.join("; ") + "."
  return { done: true, message: said }
}

// --------------------------------------------------------------- zones
//
// A zone is named by its IANA name and shown by its place: "Tokyo", with
// the offset it has today. The list comes from the helper, which has the
// zone database; searching it is here.

function utcOffsetLabel(minutes) {
  var m = Number(minutes) || 0
  if (m === 0) return "UTC"
  var sign = m < 0 ? "\u2212" : "+"
  var abs = Math.abs(m)
  var hours = Math.floor(abs / 60), mins = abs % 60
  return "UTC" + sign + hours + (mins ? ":" + pad(mins, 2) : "")
}

function zoneCity(name) {
  var parts = String(name || "").split("/")
  return parts[parts.length - 1].replace(/_/g, " ")
}

// "Tokyo" with its region as a note: "Asia · UTC+9". The zone the person is
// in says so, since that is the one most often wanted back.
function zoneRow(zone, localZone) {
  var parts = String(zone.name).split("/")
  var region = parts.length > 2 ? parts.slice(0, -1).join(" / ").replace(/_/g, " ") : parts[0]
  return {
    value: zone.name,
    label: zoneCity(zone.name) + (zone.name === localZone ? " (your time zone)" : ""),
    note: region + " \u00b7 " + utcOffsetLabel(zone.offset)
  }
}

function zoneLabel(name, zones, localZone) {
  if (!name) return "Floating"
  for (var i = 0; i < (zones || []).length; i++)
    if (zones[i].name === name) return zoneCity(name) + " (" + utcOffsetLabel(zones[i].offset) + ")"
  return zoneCity(name)
}

// The zones that match what is typed — by place or region, words first —
// with the person's own zone first when nothing is typed.
function zoneChoices(zones, query, localZone, limit) {
  var needle = String(query || "").trim().toLowerCase().replace(/\s+/g, "_")
  var starts = [], within = [], mine = null
  for (var i = 0; i < (zones || []).length; i++) {
    var z = zones[i]
    if (z.name === localZone) mine = z
    var name = z.name.toLowerCase()
    if (!needle) continue
    var city = zoneCity(z.name).toLowerCase().replace(/ /g, "_")
    if (city.indexOf(needle) === 0 || name.indexOf(needle) === 0) starts.push(z)
    else if (name.indexOf(needle) !== -1) within.push(z)
  }
  var found = needle ? starts.concat(within) : (mine ? [mine] : [])
  var out = []
  for (var f = 0; f < found.length && out.length < (limit || 30); f++)
    out.push(zoneRow(found[f], localZone))
  return out
}

// ------------------------------------------------------------- scope
//
// A change to one of a series has to say how far it reaches. A single
// occurrence cannot take a rule of its own or live in another calendar —
// both belong to the series — so a change to either is not offered for
// one event alone. An empty list means the question does not arise.

var SCOPE_OPTIONS = [
  { value: "this", label: "This event" },
  { value: "following", label: "This and following" },
  { value: "all", label: "All events" }
]

function scopeChoices(event, changes) {
  if (!isSeries(event)) return []
  // Attachments too: iCloud attaches a file to every occurrence of the
  // object it is uploaded to, so one cannot be given to a single occurrence.
  var seriesOnly = (changes || []).indexOf("rrule") !== -1
                || (changes || []).indexOf("calendarUrl") !== -1
                || (changes || []).indexOf("attachments") !== -1
  return seriesOnly ? SCOPE_OPTIONS.slice(1) : SCOPE_OPTIONS.slice()
}

// Which calendars an event can be written into: on, and not read-only.
// The one it is in stays on the list whatever it is, so the dropdown never
// opens on a value it does not have.
//
// With more than one account on the list, each row says whose it is — two
// calendars called Personal are otherwise the same row twice. With one, it
// would only repeat the same address down the side.
function editableCalendars(calendars, currentUrl) {
  var out = [], accounts = {}
  for (var i = 0; i < (calendars || []).length; i++) {
    var cal = calendars[i]
    var usable = cal.enabled !== false && !cal.readonly
    if (usable || cal.url === currentUrl) {
      out.push({ value: cal.url, label: singleLine(cal.name), color: cal.color || "",
                 account: cal.account || "" })
      accounts[cal.account || ""] = true
    }
  }
  var several = Object.keys(accounts).length > 1
  for (var o = 0; o < out.length; o++) out[o].note = several ? out[o].account : ""
  return out
}

function calendarOf(calendars, url) {
  for (var i = 0; i < (calendars || []).length; i++)
    if (calendars[i].url === url) return calendars[i]
  return null
}

// What changing an event's calendar will do, when the new one belongs to
// another account. Within one account it is a move; across two it is a
// new event on one server and a deletion on the other, and what belongs to
// the first account does not come along.
function moveNote(calendars, fromUrl, toUrl) {
  if (!fromUrl || !toUrl || fromUrl === toUrl) return ""
  var from = calendarOf(calendars, fromUrl), to = calendarOf(calendars, toUrl)
  if (!from || !to || (from.account || "") === (to.account || "")) return ""
  return "This moves the event to " + (to.account || "another account")
       + ". It is added there and deleted here: invitees are invited again "
       + "from that account, and attachments stay behind."
}

// What the question over a save or a delete says. Written for the scopes it
// is offering, so a list without "This event" explains why it is missing.
// A save that changes who is invited says that iCloud will tell them.
function actionPrompt(action, scopes, changes) {
  if (action === "discard")
    return "The changes to this event haven\u2019t been saved. Discarding them can\u2019t be undone."
  var count = (scopes || []).length
  var verb = action === "delete" ? "Delete" : "Change"
  var mails = action === "save" && (changes || []).indexOf("invitees") !== -1
    ? " iCloud emails anyone added or removed." : ""
  if (count === 0)
    return action === "delete"
      ? "This deletes the event from iCloud and from every device that syncs with it."
      : mails.trim()
  if (count === 3)
    return "This event repeats. " + verb + " only this one, this one and every "
         + "one after it, or the whole series?" + mails
  return "This event repeats, and how it repeats, which calendar it is in and "
       + "its attachments belong to the whole series. " + verb + " this one and every one after "
       + "it, or all of them?" + mails
}

// -------------------------------------------------------------- places
//
// Suggestions for the address field. The calendar's own history is always
// offered and never leaves the machine; a lookup service is the person's
// choice, asked about before any address is sent to it.

var PLACE_PROVIDERS = [
  { value: "none", label: "Your calendar only" },
  { value: "photon", label: "Photon" },
  { value: "nominatim", label: "Nominatim" }
]

function placeProviders() { return PLACE_PROVIDERS }

function placeKey(text) {
  return String(text || "").replace(/\s+/g, " ").trim().toLowerCase()
}

// Addresses from the calendar that match what is being typed, word starts
// first, the rest after, in the order the history ranks them — most used.
// The address already in the box is not offered back.
function placeSuggestions(history, query, limit) {
  var needle = placeKey(query)
  if (needle.length < 2) return []
  var starts = [], within = []
  for (var i = 0; i < (history || []).length; i++) {
    var key = placeKey(history[i].text)
    if (key === needle) continue
    var at = key.indexOf(needle)
    if (at === -1) continue
    if (at === 0 || /[\s,]/.test(key.charAt(at - 1))) starts.push(history[i])
    else within.push(history[i])
  }
  return starts.concat(within).slice(0, limit || 5)
}

// A suggestion taken: its words, and its point when it has one — from the
// history's stored place, or from a lookup's own coordinates.
function withPlace(draft, suggestion) {
  var out = withField(draft, "location", String(suggestion.text || ""))
  var point = suggestion.place
    || (isFinite(suggestion.lat) && isFinite(suggestion.lon)
        ? { lat: suggestion.lat, lon: suggestion.lon, title: suggestion.title || "" } : null)
  out.place = point
  return out
}

function placesPermissionText(provider) {
  var who = provider === "nominatim"
    ? "Nominatim, run by the OpenStreetMap Foundation"
    : "Photon, run by komoot"
  var when = provider === "nominatim"
    ? "Nominatim searches only when you press Search \u2014 its rules do not "
      + "allow suggestions as you type."
    : "Photon suggests places as you type, once there are three letters."
  return "Omarcal will send what you type in Address to " + who + " to find "
       + "places. The text you type and your IP address go to their servers; "
       + "nothing else from your calendar is sent.\n\n" + when + "\n\n"
       + "Addresses you have used before are always suggested from your own "
       + "calendar, without sending anything. Switch back to \u201cYour "
       + "calendar only\u201d at any time."
}

function placesStatusLine(provider) {
  if (provider === "photon") return "Addresses you type are sent to Photon (komoot)."
  if (provider === "nominatim")
    return "Addresses are sent to Nominatim (OpenStreetMap) when you press Search."
  return "Nothing leaves this computer; addresses you\u2019ve used before are suggested."
}

// ------------------------------------------------------------ contacts
//
// Reading contacts is opt-in and asked for in so many words. These are
// what the question and the setting say, kept here so the wording the
// person agrees to is the wording that was tested.

function contactsPermissionText() {
  return "Omarcal will read the names and email addresses in your iCloud "
       + "Contacts, using the account you already connected, and keep them on "
       + "this computer to suggest people as you type an invitee. Nothing else "
       + "in a contact is kept, and nothing is sent anywhere.\n\n"
       + "Turning this off deletes every contact omarcal has kept."
}

function contactsStatusLine(enabled, count, error) {
  if (!enabled) return "Off \u2014 invite people by typing their email address."
  if (error) return error
  if (count === 0) return "No contacts with an email address found in iCloud "
                        + "\u2014 type addresses instead."
  return count === 1 ? "1 contact available" : count + " contacts available"
}
