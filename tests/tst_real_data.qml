import QtQuick
import QtTest
import "../Logic.js" as Logic

// Logic.js against a real month pulled from iCloud.
//
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/tst_real_data.qml
//
// tst_logic.qml pins the behaviour with hand-written fixtures; this checks the
// same code survives the shapes a real calendar actually contains — 115
// occurrences across three calendars, all-day and timed, single and recurring,
// including a nine-day span and several simultaneous appointments.
//
// Regenerate with:
//   ./helper/omarcal-helper events --from 2026-09-01 --to 2026-10-01 \
//     > tests/fixture-september.json
TestCase {
  name: "RealData"

  property var events: []

  function initTestCase() {
    var request = new XMLHttpRequest()
    request.open("GET", Qt.resolvedUrl("fixture-september.json"), false)
    request.send(null)
    events = JSON.parse(request.responseText).events
    verify(events.length > 0, "fixture did not load")
  }

  function test_fixture_is_the_month_we_expect() {
    compare(events.length, 115)
  }

  // Every occurrence lands on at least one day, and nothing runs away.
  function test_every_event_buckets_somewhere() {
    for (var i = 0; i < events.length; i++) {
      var keys = Logic.eventDayKeys(events[i])
      verify(keys.length >= 1, "no days for " + events[i].title)
      verify(keys.length <= 400, "runaway span for " + events[i].title)
      verify(keys[0] === Logic.dateKey(events[i].start),
             "first day is not the start for " + events[i].title)
    }
  }

  // The month grid must account for every occurrence that falls inside it.
  function test_month_buckets_hold_every_september_event() {
    var cells = Logic.monthGrid(2026, 9, 0, "")
    var days = []
    for (var c = 0; c < cells.length; c++) days.push(cells[c].key)
    var buckets = Logic.bucketByDay(events, days)

    var placed = {}
    for (var d = 0; d < days.length; d++) {
      var bucket = buckets[days[d]]
      for (var a = 0; a < bucket.allDay.length; a++) placed[bucket.allDay[a].uid + bucket.allDay[a].start] = true
      for (var t = 0; t < bucket.timed.length; t++) placed[bucket.timed[t].uid + bucket.timed[t].start] = true
    }

    // Everything starting inside the grid's range must have been placed.
    var missing = 0
    for (var i = 0; i < events.length; i++) {
      var key = Logic.dateKey(events[i].start)
      if (key < days[0] || key > days[days.length - 1]) continue
      if (!placed[events[i].uid + events[i].start]) missing++
    }
    compare(missing, 0)
  }

  // Nothing may be filed as both a band and a timed block on the same day.
  function test_no_event_is_in_both_buckets() {
    var days = Logic.weekDays("2026-09-22", 0)
    var buckets = Logic.bucketByDay(events, days)
    for (var d = 0; d < days.length; d++) {
      var bucket = buckets[days[d]]
      for (var a = 0; a < bucket.allDay.length; a++) {
        for (var t = 0; t < bucket.timed.length; t++) {
          verify(!(bucket.allDay[a].uid === bucket.timed[t].uid
                   && bucket.allDay[a].start === bucket.timed[t].start),
                 "double-filed: " + bucket.allDay[a].title)
        }
      }
    }
  }

  // Lane packing must never put two overlapping bars in the same lane.
  function test_all_day_bars_never_collide() {
    var cells = Logic.monthGrid(2026, 9, 0, "")
    var rows = Logic.monthRows(cells)
    for (var r = 0; r < rows.length; r++) {
      var days = []
      for (var c = 0; c < rows[r].length; c++) days.push(rows[r][c].key)
      var bars = Logic.allDayBars(events, days)
      for (var i = 0; i < bars.length; i++) {
        for (var j = i + 1; j < bars.length; j++) {
          if (bars[i].lane !== bars[j].lane) continue
          var iEnd = bars[i].startCol + bars[i].span
          var jEnd = bars[j].startCol + bars[j].span
          verify(bars[i].startCol >= jEnd || bars[j].startCol >= iEnd,
                 "lane " + bars[i].lane + " collision: "
                 + bars[i].event.title + " / " + bars[j].event.title)
        }
      }
    }
  }

  // A span longer than a week is in this month and must clip to each of the
  // weeks it crosses. Found by its length rather than by its name: the test
  // is about the clipping, and tying it to a title only pinned the fixture.
  function test_long_span_clips_to_each_week() {
    // The two weeks the month's longest span actually crosses.
    var weeks = [Logic.weekDays("2026-09-13", 0), Logic.weekDays("2026-09-20", 0)]
    var longest = 0
    for (var e = 0; e < events.length; e++) {
      if (!events[e].allDay) continue
      var span = Logic.eventDayKeys(events[e]).length
      if (span > longest) longest = span
    }
    verify(longest >= 8, "the fixture has no span longer than a week")

    var clipped = 0
    for (var w = 0; w < weeks.length; w++) {
      var bars = Logic.allDayBars(events, weeks[w])
      for (var b = 0; b < bars.length; b++) {
        verify(bars[b].startCol >= 0, "bar starts before the week")
        verify(bars[b].startCol + bars[b].span <= 7, "bar runs past the week")
        if (Logic.eventDayKeys(bars[b].event).length >= 8) clipped++
      }
    }
    // It crosses both of them, so it is drawn in both.
    compare(clipped, 2)
  }

  // Timed blocks in one column must not overlap within a lane, and every
  // block must fit the day.
  function test_timed_layout_is_consistent_every_day() {
    var cells = Logic.monthGrid(2026, 9, 0, "")
    for (var c = 0; c < cells.length; c++) {
      var day = cells[c].key
      var buckets = Logic.bucketByDay(events, [day])
      var blocks = Logic.layoutTimed(buckets[day].timed, day)
      for (var i = 0; i < blocks.length; i++) {
        verify(blocks[i].startMinute >= 0 && blocks[i].endMinute <= 1440,
               "block outside the day on " + day)
        verify(blocks[i].endMinute > blocks[i].startMinute, "empty block on " + day)
        verify(blocks[i].lane < blocks[i].lanes, "lane index exceeds lane count")
        for (var j = i + 1; j < blocks.length; j++) {
          if (blocks[i].lane !== blocks[j].lane) continue
          verify(blocks[i].startMinute >= blocks[j].endMinute
                 || blocks[j].startMinute >= blocks[i].endMinute,
                 "overlap in lane " + blocks[i].lane + " on " + day)
        }
      }
    }
  }

  // This calendar really does have simultaneous appointments; the busiest day
  // must end up with more than one lane.
  function test_a_busy_day_needs_several_lanes() {
    var widest = 0
    var cells = Logic.monthGrid(2026, 9, 0, "")
    for (var c = 0; c < cells.length; c++) {
      var day = cells[c].key
      var buckets = Logic.bucketByDay(events, [day])
      var blocks = Logic.layoutTimed(buckets[day].timed, day)
      for (var i = 0; i < blocks.length; i++) widest = Math.max(widest, blocks[i].lanes)
    }
    verify(widest >= 2, "no day needed side-by-side blocks, which cannot be right")
  }

  // Formatting must produce something for every occurrence.
  function test_every_event_formats() {
    for (var i = 0; i < events.length; i++) {
      var text = Logic.formatRange(events[i], "12h")
      verify(text.length > 0, "no range text for " + events[i].title)
      if (events[i].allDay) compare(text, "All day")
    }
  }
}
