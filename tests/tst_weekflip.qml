import QtQuick
import QtTest
import "../Logic.js" as Logic

// The flipped week: days down, hours across. A day is a length of time, so it
// is drawn as one.
TestCase {
  name: "weekflip"

  function timed(from, to) {
    return { allDay: false,
             start: "2026-09-09T" + from + ":00-05:00",
             end: "2026-09-09T" + to + ":00-05:00" }
  }

  function test_block_span() {
    var blocks = Logic.layoutTimed([timed("06:00", "12:00")], "2026-09-09")
    var box = Logic.blockSpan(blocks[0], 2400)
    // A quarter of the day in, a quarter of the day wide.
    compare(box.x, 600)
    compare(box.width, 600)
  }

  function test_block_span_has_a_floor() {
    var blocks = Logic.layoutTimed([timed("06:00", "06:10")], "2026-09-09")
    var box = Logic.blockSpan(blocks[0], 2400, 24)
    verify(box.width >= 24)
  }

  function test_block_span_clamps_to_the_day() {
    var box = Logic.blockSpan({ startMinute: -100, endMinute: 3000 }, 2400)
    compare(box.x, 0)
    compare(box.width, 2400)
  }

  // Overlapping events stack down the row instead of splitting its width, so
  // a busy day gets taller rather than unreadable.
  function test_day_depth_stacks_overlaps() {
    var blocks = Logic.layoutTimed([
      timed("08:00", "12:00"),
      timed("09:00", "10:00"),
      timed("09:30", "11:00")
    ], "2026-09-09")
    compare(Logic.dayDepth(0, blocks), 3)
  }

  function test_day_depth_counts_all_day_first() {
    var blocks = Logic.layoutTimed([timed("08:00", "09:00")], "2026-09-09")
    compare(Logic.dayDepth(2, blocks), 3)
  }

  function test_day_depth_of_an_empty_day() {
    compare(Logic.dayDepth(0, []), 1)
    compare(Logic.dayDepth(0, null), 1)
  }

  // Events that do not overlap share a row, which is the whole point of
  // laying a day out along its length.
  function test_day_depth_of_a_full_but_tidy_day() {
    var blocks = Logic.layoutTimed([
      timed("08:00", "09:00"),
      timed("10:00", "11:00"),
      timed("13:00", "17:00")
    ], "2026-09-09")
    compare(Logic.dayDepth(0, blocks), 1)
  }

  function test_hour_tick_step() {
    // Room for every hour.
    compare(Logic.hourTickStep(2400, 50), 1)
    // Room for half of them.
    compare(Logic.hourTickStep(1200, 50), 2)
    compare(Logic.hourTickStep(600, 50), 4)
    // A rail with no room at all still answers with a step that divides a day.
    verify(24 % Logic.hourTickStep(50, 50) === 0)
  }

  // A day narrowed to waking hours narrows both rails the same way.
  function test_day_window() {
    var all = Logic.dayWindow(0, 24)
    compare(all.hours, 24)
    compare(all.startMinute, 0)
    compare(all.endMinute, 1440)

    var waking = Logic.dayWindow(6, 22)
    compare(waking.hours, 16)
    compare(waking.startMinute, 360)
    compare(waking.endMinute, 1320)
  }

  // A setting typed backwards should show too much, not leave the view blank.
  function test_day_window_survives_nonsense() {
    compare(Logic.dayWindow(20, 8).hours, 4)      // 20 .. 24
    compare(Logic.dayWindow(-5, 99).hours, 24)
    compare(Logic.dayWindow(undefined, undefined).hours, 24)
    compare(Logic.dayWindow(23, 23).from, 23)
    compare(Logic.dayWindow(23, 23).to, 24)
  }

  function test_block_span_inside_a_window() {
    var blocks = Logic.layoutTimed([timed("12:00", "18:00")], "2026-09-09")
    var win = Logic.dayWindow(6, 18)          // twelve hours across the rail
    var box = Logic.blockSpan(blocks[0], 1200, 0, win)
    // Noon is half way through a rail that starts at six.
    compare(box.x, 600)
    compare(box.width, 600)
  }

  function test_block_span_clipped_by_the_window() {
    var blocks = Logic.layoutTimed([timed("04:00", "08:00")], "2026-09-09")
    var win = Logic.dayWindow(6, 18)
    var box = Logic.blockSpan(blocks[0], 1200, 0, win)
    compare(box.x, 0)
    compare(box.width, 200)                   // only six to eight shows
  }

  function test_block_geometry_inside_a_window() {
    var blocks = Logic.layoutTimed([timed("12:00", "13:00")], "2026-09-09")
    var box = Logic.blockGeometry(blocks[0], 60, 0, Logic.dayWindow(6, 18))
    compare(box.y, 6 * 60)
    compare(box.height, 60)
  }

  // A block wholly outside the window is not drawn at all, rather than drawn
  // as a sliver against an edge.
  function test_in_window() {
    var early = Logic.layoutTimed([timed("01:00", "02:00")], "2026-09-09")[0]
    var noon = Logic.layoutTimed([timed("12:00", "13:00")], "2026-09-09")[0]
    var win = Logic.dayWindow(6, 18)
    verify(!Logic.inWindow(early, win))
    verify(Logic.inWindow(noon, win))
    verify(Logic.inWindow(early))             // no window is the whole day
  }

  function test_hour_across_inside_a_window() {
    var win = Logic.dayWindow(6, 18)
    compare(Logic.hourAcross(6, 1200, win), 0)
    compare(Logic.hourAcross(12, 1200, win), 600)
    compare(Logic.hourAcross(18, 1200, win), 1200)
    // Outside the window, clamped rather than off the end.
    compare(Logic.hourAcross(2, 1200, win), 0)
    compare(Logic.hourAcross(23, 1200, win), 1200)
  }

  function test_tick_step_follows_the_window() {
    // Twelve hours in the room that fitted twenty-four gets a finer step.
    compare(Logic.hourTickStep(1200, 50, 24), 2)
    compare(Logic.hourTickStep(1200, 50, 12), 1)
  }

  // An hour of margin either side: room for the end marks to straddle their
  // tick, and somewhere for a spilling event to show its tail.
  function test_rail_window() {
    var rail = Logic.railWindow(Logic.dayWindow(0, 24))
    compare(rail.hours, 26)
    compare(rail.from, -1)
    compare(rail.to, 25)
    compare(rail.startMinute, -60)
    compare(rail.endMinute, 1500)
    // The day it is a rail for is still in there.
    compare(rail.day.from, 0)
    compare(rail.day.to, 24)
  }

  function test_rail_window_of_a_narrowed_day() {
    var rail = Logic.railWindow(Logic.dayWindow(6, 22))
    compare(rail.hours, 18)
    compare(rail.from, 5)
    compare(rail.to, 23)
  }

  // Both ends of the day now sit an hour in from the edge, which is the whole
  // point: a mark there can be centred.
  function test_the_day_starts_an_hour_in() {
    var win = Logic.dayWindow(0, 24)
    var rail = Logic.railWindow(win)
    compare(Logic.hourAcross(0, 2600, rail), 100)
    compare(Logic.hourAcross(24, 2600, rail), 2500)
  }

  function test_overflow_of_a_timed_event() {
    var night = { allDay: false, start: "2026-09-08T22:00:00-05:00",
                  end: "2026-09-09T02:00:00-05:00" }
    compare(Logic.eventOverflow(night, "2026-09-08").after, true)
    compare(Logic.eventOverflow(night, "2026-09-08").before, false)
    compare(Logic.eventOverflow(night, "2026-09-09").before, true)
    compare(Logic.eventOverflow(night, "2026-09-09").after, false)
  }

  // Ending exactly at midnight is stopping at the edge, not spilling over it.
  function test_an_event_ending_at_midnight_does_not_spill() {
    var late = { allDay: false, start: "2026-09-08T22:00:00-05:00",
                 end: "2026-09-09T00:00:00-05:00" }
    compare(Logic.eventOverflow(late, "2026-09-08").after, false)
  }

  // An all-day event's end is the morning after its last day.
  function test_overflow_of_an_all_day_event() {
    var span = { allDay: true, start: "2026-09-06", end: "2026-09-09" }
    compare(Logic.eventOverflow(span, "2026-09-06").before, false)
    compare(Logic.eventOverflow(span, "2026-09-06").after, true)
    compare(Logic.eventOverflow(span, "2026-09-07").before, true)
    compare(Logic.eventOverflow(span, "2026-09-07").after, true)
    // The last day it covers: it came from before, it goes nowhere after.
    compare(Logic.eventOverflow(span, "2026-09-08").before, true)
    compare(Logic.eventOverflow(span, "2026-09-08").after, false)
  }

  function test_overflow_of_a_single_day_all_day_event() {
    var one = { allDay: true, start: "2026-09-06", end: "2026-09-07" }
    compare(Logic.eventOverflow(one, "2026-09-06").before, false)
    compare(Logic.eventOverflow(one, "2026-09-06").after, false)
  }

  function test_spilled_span_reaches_the_margins() {
    var rail = Logic.railWindow(Logic.dayWindow(0, 24))
    var both = Logic.spilledSpan(0, 1440, { before: true, after: true }, rail)
    compare(both.startMinute, -60)
    compare(both.endMinute, 1500)

    var neither = Logic.spilledSpan(0, 1440, { before: false, after: false }, rail)
    compare(neither.startMinute, 0)
    compare(neither.endMinute, 1440)
  }

  // A week asks how tall it wants to be from its events, not from its rows —
  // a row that is about to be stretched cannot also be what decides the
  // stretching.
  function test_week_natural_rows() {
    var days = ["2026-09-06", "2026-09-07", "2026-09-08"]
    var buckets = {
      "2026-09-06": { allDay: [], timed: [] },
      "2026-09-07": { allDay: [{}, {}], timed: [] },
      "2026-09-08": { allDay: [], timed: [
        { allDay: false, start: "2026-09-08T08:00:00-05:00",
          end: "2026-09-08T12:00:00-05:00" },
        { allDay: false, start: "2026-09-08T09:00:00-05:00",
          end: "2026-09-08T10:00:00-05:00" }
      ] }
    }
    // One for the empty day, two all-day, two overlapping appointments.
    compare(Logic.weekNaturalRows(days, buckets), 5)
  }

  function test_week_natural_rows_of_an_empty_week() {
    var days = Logic.weekDays("2026-09-09", 0)
    // Seven days, each still one row deep, so an empty week is visibly empty.
    compare(Logic.weekNaturalRows(days, {}), 7)
    compare(Logic.weekNaturalRows(null, null), 0)
  }

  function test_hour_across() {
    compare(Logic.hourAcross(0, 2400), 0)
    compare(Logic.hourAcross(6, 2400), 600)
    compare(Logic.hourAcross(24, 2400), 2400)
  }
}
