import QtQuick
import QtTest
import "../Logic.js" as Logic

// The week header. The grid itself reuses what the month and the day already
// have: allDayBars for the band, layoutTimed per column.
TestCase {
  name: "weekview"

  function test_heading_within_one_month() {
    var head = Logic.weekHeading(Logic.weekDays("2026-09-09", 0))
    compare(head.title, "September 6 – 12")
    compare(head.meta, "2026")
  }

  function test_heading_across_two_months() {
    var head = Logic.weekHeading(Logic.weekDays("2026-09-02", 0))
    compare(head.title, "August 30 – September 5")
    compare(head.meta, "2026")
  }

  function test_heading_across_a_new_year() {
    var days = Logic.weekDays("2026-12-31", 0)
    var head = Logic.weekHeading(days)
    compare(head.title, "December 27 – January 2")
    // The year belongs in the quieter line, not said twice in the first.
    compare(head.meta, "2026 – 2027")
  }

  function test_heading_follows_the_week_start() {
    var head = Logic.weekHeading(Logic.weekDays("2026-09-09", 1))
    compare(head.title, "September 7 – 13")
  }

  function test_heading_of_nothing() {
    compare(Logic.weekHeading([]).title, "")
    compare(Logic.weekHeading(null).meta, "")
  }
}
