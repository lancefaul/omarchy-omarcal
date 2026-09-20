import QtQuick
import QtTest
import "../Logic.js" as Logic

// The search pane's grouping. A search reaches back through years, so what it
// shows first matters more here than anywhere else in the card.
TestCase {
  name: "search"

  function whole(title, day) {
    return { title: title, allDay: true, start: day, end: day }
  }
  function timed(title, at) {
    return { title: title, allDay: false, start: at, end: at }
  }

  function test_groups_run_newest_first() {
    var groups = Logic.searchGroups([
      whole("Old", "2019-09-14"),
      whole("Newer", "2026-09-20"),
      whole("Middle", "2021-06-22")
    ])
    compare(groups.length, 3)
    compare(groups[0].key, "2026-09-20")
    compare(groups[1].key, "2021-06-22")
    compare(groups[2].key, "2019-09-14")
  }

  function test_a_day_holds_all_its_matches() {
    var groups = Logic.searchGroups([
      timed("Second", "2026-09-20T13:00:00-05:00"),
      whole("First", "2026-09-20"),
      timed("Third", "2026-09-20T18:00:00-05:00")
    ])
    compare(groups.length, 1)
    compare(groups[0].events.length, 3)
    // All-day first, then by the clock, the way the day panel reads.
    compare(groups[0].events[0].title, "First")
    compare(groups[0].events[1].title, "Second")
    compare(groups[0].events[2].title, "Third")
  }

  // A search crosses years, so a bare weekday would say nothing about which.
  function test_day_label_is_the_whole_date() {
    compare(Logic.searchDayLabel("2026-09-20"), "Sunday, September 20, 2026")
  }

  function test_groups_of_nothing() {
    compare(Logic.searchGroups([]).length, 0)
    compare(Logic.searchGroups(null).length, 0)
  }

  function test_summary() {
    compare(Logic.searchSummary("", 0, false), "Type to search every calendar.")
    compare(Logic.searchSummary("   ", 0, false), "Type to search every calendar.")
    compare(Logic.searchSummary("cake", 0, true), "Searching…")
    compare(Logic.searchSummary("cake", 0, false), "Nothing matches.")
    compare(Logic.searchSummary("cake", 1, false), "1 match")
    compare(Logic.searchSummary("cake", 7, false), "7 matches")
  }

  // Saying "200 matches" for an unknown number of them would be a lie told
  // precisely.
  function test_summary_says_when_it_was_cut_short() {
    compare(Logic.searchSummary("a", Logic.searchLimit(), false, true),
            "200+ matches — narrow it down")
    compare(Logic.searchLimit(), 200)
  }

  function test_view_keys_round_trip() {
    compare(Logic.viewKey("Week"), "week")
    compare(Logic.viewKey("Day"), "day")
    compare(Logic.viewKey("Month"), "month")
    // Anything it does not know is the month, which is what it opens on.
    compare(Logic.viewKey("Agenda"), "month")
    compare(Logic.viewKey(null), "month")

    compare(Logic.viewFromKey("week"), "Week")
    compare(Logic.viewFromKey("DAY"), "Day")
    compare(Logic.viewFromKey(""), "Month")
    compare(Logic.viewFromKey(Logic.viewKey("Week")), "Week")
  }

  function test_view_options() {
    var options = Logic.viewOptions()
    compare(options.length, 3)
    compare(options[0].value, "day")
    compare(options[2].label, "Month")
  }
}
