import QtQuick
import QtTest
import "../Logic.js" as Logic

// The day grid's arithmetic. The lanes come from layoutTimed, which the month
// already uses; this is where a block lands on the rail once it has one.
TestCase {
  name: "dayview"

  function timed(title, from, to) {
    return { title: title, allDay: false,
             start: "2026-09-20T" + from + ":00-05:00",
             end: "2026-09-20T" + to + ":00-05:00" }
  }

  function test_hour_labels_are_one_width() {
    var twelve = Logic.hourLabels("12h")
    compare(twelve.length, 24)
    compare(twelve[0], "12 AM")
    compare(twelve[1], "01 AM")
    compare(twelve[12], "12 PM")
    compare(twelve[13], "01 PM")
    compare(twelve[23], "11 PM")
    for (var i = 0; i < 24; i++) compare(twelve[i].length, twelve[0].length)
  }

  function test_hour_labels_24h() {
    var day = Logic.hourLabels("24h")
    compare(day[0], "00:00")
    compare(day[9], "09:00")
    compare(day[23], "23:00")
  }

  // A day opens an hour before its first event so the block is not jammed
  // against the top edge.
  function test_opening_hour() {
    var blocks = Logic.layoutTimed([timed("A", "13:00", "14:00")], "2026-09-20")
    compare(Logic.openingHour(blocks), 12)
  }

  function test_opening_hour_of_an_empty_day() {
    compare(Logic.openingHour([]), 8)
    compare(Logic.openingHour([], 6), 6)
  }

  function test_opening_hour_never_goes_above_midnight() {
    var blocks = Logic.layoutTimed([timed("A", "00:20", "00:50")], "2026-09-20")
    compare(Logic.openingHour(blocks), 0)
  }

  function test_block_geometry() {
    var blocks = Logic.layoutTimed([timed("A", "13:00", "14:30")], "2026-09-20")
    var box = Logic.blockGeometry(blocks[0], 60)
    compare(box.y, 13 * 60)
    compare(box.height, 90)
  }

  // A zero-length event is already widened to fifteen minutes by layoutTimed;
  // the floor is for a rail drawn small enough that fifteen is still nothing.
  function test_block_geometry_has_a_floor() {
    var blocks = Logic.layoutTimed([timed("A", "13:00", "13:05")], "2026-09-20")
    var box = Logic.blockGeometry(blocks[0], 30, 18)
    verify(box.height >= 18)
  }

  function test_block_geometry_clamps_to_the_day() {
    var box = Logic.blockGeometry({ startMinute: -60, endMinute: 2000 }, 60)
    compare(box.y, 0)
    compare(box.height, 24 * 60)
  }

  function test_block_column_alone() {
    var blocks = Logic.layoutTimed([timed("A", "13:00", "14:00")], "2026-09-20")
    var col = Logic.blockColumn(blocks[0], 300, 4)
    compare(col.x, 0)
    // No neighbour, so no gap is taken out of it.
    compare(col.width, 300)
  }

  function test_block_column_shared() {
    var blocks = Logic.layoutTimed([
      timed("A", "13:00", "15:00"),
      timed("B", "14:00", "16:00")
    ], "2026-09-20")
    compare(blocks[0].lanes, 2)
    var first = Logic.blockColumn(blocks[0], 300, 4)
    var second = Logic.blockColumn(blocks[1], 300, 4)
    compare(first.x, 0)
    compare(second.x, 150)
    compare(first.width, 146)
  }

  function test_hour_offset() {
    compare(Logic.hourOffset(0, 40), 0)
    compare(Logic.hourOffset(9, 40), 360)
    compare(Logic.hourOffset(-2, 40), 0)
  }
}
