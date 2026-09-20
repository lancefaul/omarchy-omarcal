import QtQuick
import QtTest
import "../Logic.js" as Logic

// The event viewer's own logic. Everything the modal says about an event is
// worked out here, so the panel only has to draw it.
TestCase {
  name: "event"

  function timed(start, end) {
    return { allDay: false, start: start, end: end }
  }
  function whole(start, end) {
    return { allDay: true, start: start, end: end }
  }

  function test_long_date() {
    compare(Logic.longDate("2026-09-20"), "Sunday, September 20, 2026")
    compare(Logic.longDate(""), "")
  }

  function test_when_for_a_timed_event() {
    var lines = Logic.eventWhen(
      timed("2026-09-20T13:00:00-05:00", "2026-09-20T18:00:00-05:00"), "12h")
    compare(lines[0], "Sunday, September 20, 2026")
    compare(lines[1], "01:00 PM – 06:00 PM")
  }

  function test_when_honours_the_time_format() {
    var lines = Logic.eventWhen(
      timed("2026-09-20T13:00:00-05:00", "2026-09-20T18:00:00-05:00"), "24h")
    compare(lines[1], "13:00 – 18:00")
  }

  // An all-day event ends the morning after the last day it covers, which is
  // not a day it covers — saying so would put it a day long everywhere.
  function test_when_for_one_whole_day() {
    var lines = Logic.eventWhen(whole("2026-09-20", "2026-09-21"), "12h")
    compare(lines[0], "Sunday, September 20, 2026")
    compare(lines[1], "All day")
  }

  function test_when_for_several_whole_days() {
    var lines = Logic.eventWhen(whole("2026-09-20", "2026-09-23"), "12h")
    compare(lines[0], "Sunday, September 20, 2026 – Tuesday, September 22, 2026")
    compare(lines[1], "All day")
  }

  function test_when_for_an_event_running_past_midnight() {
    var lines = Logic.eventWhen(
      timed("2026-09-20T22:00:00-05:00", "2026-09-21T02:00:00-05:00"), "12h")
    compare(lines[0], "Sunday, September 20, 2026 – Monday, September 21, 2026")
    compare(lines[1], "10:00 PM – 02:00 AM")
  }

  function test_when_of_nothing() {
    compare(Logic.eventWhen(null, "12h").length, 0)
    compare(Logic.eventWhen({}, "12h").length, 0)
  }

  // The rules iCloud actually writes.
  function test_recurrence_weekly() {
    compare(Logic.describeRecurrence("FREQ=WEEKLY"), "Every week")
  }

  function test_recurrence_interval() {
    compare(Logic.describeRecurrence("FREQ=WEEKLY;INTERVAL=2"), "Every 2 weeks")
    compare(Logic.describeRecurrence("FREQ=DAILY"), "Every day")
    compare(Logic.describeRecurrence("FREQ=MONTHLY"), "Every month")
    compare(Logic.describeRecurrence("FREQ=YEARLY"), "Every year")
  }

  function test_recurrence_by_day() {
    compare(Logic.describeRecurrence("FREQ=WEEKLY;BYDAY=MO,WE,FR"),
            "Every week on Mon, Wed, Fri")
    // An ordinal BYDAY names the day and drops the ordinal.
    compare(Logic.describeRecurrence("FREQ=MONTHLY;BYDAY=2MO"), "Every month")
  }

  function test_recurrence_end() {
    compare(Logic.describeRecurrence("FREQ=WEEKLY;COUNT=5"), "Every week, 5 times")
    compare(Logic.describeRecurrence("FREQ=WEEKLY;COUNT=1"), "Every week, 1 time")
    compare(Logic.describeRecurrence("FREQ=DAILY;UNTIL=20261231T000000Z"),
            "Every day, until Thursday, December 31, 2026")
  }

  function test_recurrence_unknown_still_says_it_repeats() {
    compare(Logic.describeRecurrence("FREQ=SECONDLY"), "Repeats")
    compare(Logic.describeRecurrence(""), "")
    compare(Logic.describeRecurrence(null), "")
  }

  function test_alarms() {
    compare(Logic.describeAlarm("-PT15M"), "15 minutes before")
    compare(Logic.describeAlarm("-PT1H"), "1 hour before")
    compare(Logic.describeAlarm("-P1D"), "1 day before")
    compare(Logic.describeAlarm("-P1W"), "1 week before")
    compare(Logic.describeAlarm("-PT1H30M"), "1 hour 30 minutes before")
    compare(Logic.describeAlarm("PT0S"), "At the time of the event")
    compare(Logic.describeAlarm("PT10M"), "10 minutes after")
  }

  // Apple writes some triggers as an absolute instant in 1976, which is a
  // placeholder rather than a time anybody set.
  function test_absolute_alarms_are_dropped() {
    compare(Logic.describeAlarm("19760401T005545Z"), "")
    compare(Logic.alarmLines(["19760401T005545Z"]).length, 0)
  }

  function test_alarm_lines_dedupe_and_keep_order() {
    var lines = Logic.alarmLines(["-PT15M", "19760401T005545Z", "-PT15M", "-P1D"])
    compare(lines.length, 2)
    compare(lines[0], "15 minutes before")
    compare(lines[1], "1 day before")
  }

  // A weekly event stores one VEVENT whose own dates are the first
  // occurrence. Asked for it by uid the helper answers with that, so the
  // viewer would head a row on this Tuesday with a date from months ago.
  function test_merge_keeps_the_occurrence_that_was_clicked() {
    var seed = { uid: "A", start: "2026-09-01T20:30:00-05:00",
                 end: "2026-09-01T23:30:00-05:00", allDay: false }
    var detail = { uid: "A", start: "2026-06-30T20:30:00-05:00",
                   end: "2026-06-30T23:30:00-05:00", allDay: false,
                   rrule: "FREQ=WEEKLY", location: "12 Alder Lane" }
    var merged = Logic.mergeOccurrence(seed, detail)
    compare(merged.start, "2026-09-01T20:30:00-05:00")
    compare(merged.end, "2026-09-01T23:30:00-05:00")
    // Everything the series knows still comes through.
    compare(merged.rrule, "FREQ=WEEKLY")
    compare(merged.location, "12 Alder Lane")
  }

  function test_merge_ignores_a_detail_for_another_event() {
    var seed = { uid: "A", start: "2026-09-01", allDay: true }
    compare(Logic.mergeOccurrence(seed, { uid: "B", location: "x" }).location,
            undefined)
    compare(Logic.mergeOccurrence(seed, null).uid, "A")
    compare(Logic.mergeOccurrence(null, { uid: "B" }).uid, "B")
  }

  // iCloud writes sms:// and message:// URLs that a browser cannot use.
  function test_web_links() {
    verify(Logic.isWebLink("https://example.com/x"))
    verify(Logic.isWebLink("http://example.com"))
    verify(!Logic.isWebLink("sms://open?message-guid=E8B1B617"))
    verify(!Logic.isWebLink(""))
    verify(!Logic.isWebLink(null))
  }
}
