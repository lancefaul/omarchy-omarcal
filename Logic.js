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
