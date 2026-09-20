import QtQuick
import QtTest
import "../Logic.js" as Logic

// Tests for Logic.js, the pure functions the omarcal views run.
//
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/tst_logic.qml
//
// The fixtures use the shapes the backend emits, including the two properties
// the whole layer rests on: DTEND is exclusive, and timed values are already
// in the viewer's zone.
TestCase {
  name: "Logic"

  function allDay(title, from, to) {
    return { title: title, allDay: true, start: from, end: to, uid: title }
  }
  function timed(title, from, to) {
    return { title: title, allDay: false, start: from, end: to, uid: title }
  }

  // ------------------------------------------------------- date primitives

  function test_date_key_reads_both_shapes() {
    compare(Logic.dateKey("2026-09-22"), "2026-09-22")
    compare(Logic.dateKey("2026-09-22T08:00:00-05:00"), "2026-09-22")
    compare(Logic.dateKey(""), "")
  }

  function test_time_of_is_local_wall_clock() {
    compare(Logic.timeOf("2026-09-22T08:30:00-05:00"), "08:30")
    compare(Logic.timeOf("2026-09-22"), "")
  }

  function test_minutes_of_day() {
    compare(Logic.minutesOfDay("2026-09-22T00:00:00-05:00"), 0)
    compare(Logic.minutesOfDay("2026-09-22T08:30:00-05:00"), 510)
    compare(Logic.minutesOfDay("2026-09-22T23:59:00-05:00"), 1439)
  }

  function test_add_days_crosses_months_and_years() {
    compare(Logic.addDays("2026-09-30", 1), "2026-10-01")
    compare(Logic.addDays("2026-01-01", -1), "2025-12-31")
    compare(Logic.addDays("2026-03-01", -1), "2026-02-28")
    compare(Logic.addDays("2024-03-01", -1), "2024-02-29")  // leap year
  }

  // A US DST transition: adding a day must not slip to the same date or skip
  // one. This is why the arithmetic runs in UTC.
  function test_add_days_survives_dst() {
    compare(Logic.addDays("2026-03-07", 1), "2026-03-08")
    compare(Logic.addDays("2026-03-08", 1), "2026-03-09")
    compare(Logic.addDays("2026-11-01", 1), "2026-11-02")
  }

  function test_weekday_of() {
    compare(Logic.weekdayOf("2026-09-20"), 0)  // Sunday
    compare(Logic.weekdayOf("2026-09-21"), 1)
    compare(Logic.weekdayOf("2026-09-26"), 6)  // Saturday
  }

  function test_days_between() {
    compare(Logic.daysBetween("2026-09-20", "2026-09-27"), 7)
    compare(Logic.daysBetween("2026-09-27", "2026-09-20"), -7)
    compare(Logic.daysBetween("2026-09-20", "2026-09-20"), 0)
  }

  // ----------------------------------------------------------- month grid

  function test_month_grid_is_six_full_weeks() {
    var cells = Logic.monthGrid(2026, 9, 0, "")
    compare(cells.length, 42)
    compare(Logic.monthRows(cells).length, 6)
  }

  // September 2026 starts on a Tuesday, so a Sunday-start grid opens with two
  // trailing days of August.
  function test_month_grid_pads_with_neighbouring_days() {
    var cells = Logic.monthGrid(2026, 9, 0, "")
    compare(cells[0].key, "2026-08-30")
    compare(cells[0].inMonth, false)
    compare(cells[2].key, "2026-09-01")
    compare(cells[2].inMonth, true)
    compare(cells[2].day, 1)
  }

  function test_month_grid_honours_week_start() {
    var sunday = Logic.monthGrid(2026, 9, 0, "")
    var monday = Logic.monthGrid(2026, 9, 1, "")
    compare(sunday[0].key, "2026-08-30")
    compare(monday[0].key, "2026-08-31")
  }

  function test_month_grid_marks_today() {
    var cells = Logic.monthGrid(2026, 9, 0, "2026-09-22")
    var marked = cells.filter(function (c) { return c.isToday })
    compare(marked.length, 1)
    compare(marked[0].key, "2026-09-22")
  }

  function test_month_grid_covers_every_day_of_the_month() {
    var cells = Logic.monthGrid(2026, 2, 0, "")
    var inMonth = cells.filter(function (c) { return c.inMonth })
    compare(inMonth.length, 28)
    var leap = Logic.monthGrid(2024, 2, 0, "").filter(function (c) { return c.inMonth })
    compare(leap.length, 29)
  }

  function test_weekend_is_saturday_and_sunday() {
    compare(Logic.isWeekend(0), true)   // Sunday
    compare(Logic.isWeekend(6), true)   // Saturday
    compare(Logic.isWeekend(3), false)
  }

  // The weekend must not shift when the grid starts on Monday.
  function test_weekend_flag_survives_a_monday_start() {
    var sunday = Logic.monthGrid(2026, 9, 0, "")
    var monday = Logic.monthGrid(2026, 9, 1, "")
    function weekendKeys(cells) {
      return cells.filter(function (c) { return c.isWeekend })
                  .map(function (c) { return c.key }).sort().join(",")
    }
    // Same set of dates either way, just in different columns.
    var a = weekendKeys(sunday).split(",").filter(function (k) {
      return k >= "2026-09-01" && k <= "2026-09-30" })
    var b = weekendKeys(monday).split(",").filter(function (k) {
      return k >= "2026-09-01" && k <= "2026-09-30" })
    compare(a.join(","), b.join(","))
    verify(a.length === 8 || a.length === 9, "September 2026 has 8 weekend days")
  }

  function test_iso_week_number() {
    compare(Logic.isoWeekNumber("2026-01-01"), 1)
    compare(Logic.isoWeekNumber("2026-09-22"), 39)
    // 2027-01-01 is a Friday, so it belongs to week 53 of 2026.
    compare(Logic.isoWeekNumber("2027-01-01"), 53)
  }

  // ---------------------------------------------------------------- weeks

  function test_week_days() {
    var days = Logic.weekDays("2026-09-22", 0)
    compare(days.length, 7)
    compare(days[0], "2026-09-20")
    compare(days[6], "2026-09-26")
    compare(Logic.weekDays("2026-09-22", 1)[0], "2026-09-21")
  }

  // ------------------------------------------------------------ day spans

  // DTEND is exclusive, so a one-day all-day event covers exactly one day.
  function test_all_day_end_is_exclusive() {
    var keys = Logic.eventDayKeys(allDay("Birthday", "2026-09-22", "2026-09-23"))
    compare(keys.length, 1)
    compare(keys[0], "2026-09-22")
  }

  function test_multi_day_all_day_covers_every_day() {
    var keys = Logic.eventDayKeys(allDay("Novena", "2026-09-18", "2026-09-27"))
    compare(keys.length, 9)
    compare(keys[0], "2026-09-18")
    compare(keys[8], "2026-09-26")
  }

  function test_timed_event_covers_one_day() {
    var keys = Logic.eventDayKeys(
      timed("Standup", "2026-09-22T08:00:00-05:00", "2026-09-22T09:00:00-05:00"))
    compare(keys.length, 1)
    compare(keys[0], "2026-09-22")
  }

  function test_overnight_timed_event_covers_both_days() {
    var keys = Logic.eventDayKeys(
      timed("Red eye", "2026-09-22T22:00:00-05:00", "2026-09-23T06:00:00-05:00"))
    compare(keys.length, 2)
    compare(keys[1], "2026-09-23")
  }

  // Ending at midnight belongs to the day that just closed, not to the next
  // one, which the event never actually occupies.
  function test_event_ending_at_midnight_stops_the_day_before() {
    var keys = Logic.eventDayKeys(
      timed("Late", "2026-09-22T21:00:00-05:00", "2026-09-23T00:00:00-05:00"))
    compare(keys.length, 1)
    compare(keys[0], "2026-09-22")
  }

  function test_backwards_event_does_not_hang() {
    var keys = Logic.eventDayKeys(allDay("Broken", "2026-09-22", "2026-09-01"))
    compare(keys.length, 1)
    compare(keys[0], "2026-09-22")
  }

  // ------------------------------------------------------------ bucketing

  function test_bucket_splits_all_day_from_timed() {
    var days = Logic.weekDays("2026-09-22", 0)
    var buckets = Logic.bucketByDay([
      allDay("Birthday", "2026-09-22", "2026-09-23"),
      timed("Standup", "2026-09-22T08:00:00-05:00", "2026-09-22T09:00:00-05:00")
    ], days)
    compare(buckets["2026-09-22"].allDay.length, 1)
    compare(buckets["2026-09-22"].timed.length, 1)
    compare(buckets["2026-09-21"].allDay.length, 0)
  }

  function test_bucket_repeats_a_multi_day_event_on_each_day() {
    var days = Logic.weekDays("2026-09-22", 0)
    var buckets = Logic.bucketByDay([allDay("Novena", "2026-09-20", "2026-09-23")], days)
    compare(buckets["2026-09-20"].allDay.length, 1)
    compare(buckets["2026-09-21"].allDay.length, 1)
    compare(buckets["2026-09-22"].allDay.length, 1)
    compare(buckets["2026-09-23"].allDay.length, 0)
  }

  // A timed event crossing midnight reads as a band, like Apple's calendar.
  function test_bucket_treats_multi_day_timed_as_a_band() {
    var days = Logic.weekDays("2026-09-22", 0)
    var buckets = Logic.bucketByDay([
      timed("Red eye", "2026-09-22T22:00:00-05:00", "2026-09-23T06:00:00-05:00")
    ], days)
    compare(buckets["2026-09-22"].allDay.length, 1)
    compare(buckets["2026-09-22"].timed.length, 0)
  }

  function test_bucket_sorts_timed_by_start() {
    var buckets = Logic.bucketByDay([
      timed("Late", "2026-09-22T16:00:00-05:00", "2026-09-22T17:00:00-05:00"),
      timed("Early", "2026-09-22T08:00:00-05:00", "2026-09-22T09:00:00-05:00")
    ], ["2026-09-22"])
    compare(buckets["2026-09-22"].timed[0].title, "Early")
  }

  function test_bucket_ignores_events_outside_the_days_asked_for() {
    var buckets = Logic.bucketByDay(
      [allDay("Elsewhere", "2026-01-01", "2026-01-02")], ["2026-09-22"])
    compare(buckets["2026-09-22"].allDay.length, 0)
  }

  // ------------------------------------------------------- all-day band

  function test_bars_span_the_right_columns() {
    var days = Logic.weekDays("2026-09-22", 0)   // Sun 20th .. Sat 26th
    var bars = Logic.allDayBars([allDay("Trip", "2026-09-21", "2026-09-24")], days)
    compare(bars.length, 1)
    compare(bars[0].startCol, 1)   // Monday
    compare(bars[0].span, 3)       // 21, 22, 23
  }

  function test_bars_clip_to_the_week_and_flag_continuation() {
    var days = Logic.weekDays("2026-09-22", 0)
    var bars = Logic.allDayBars([allDay("Novena", "2026-09-18", "2026-09-30")], days)
    compare(bars[0].startCol, 0)
    compare(bars[0].span, 7)
    compare(bars[0].continuesBefore, true)
    compare(bars[0].continuesAfter, true)
  }

  function test_overlapping_bars_take_separate_lanes() {
    var days = Logic.weekDays("2026-09-22", 0)
    var bars = Logic.allDayBars([
      allDay("A", "2026-09-20", "2026-09-24"),
      allDay("B", "2026-09-21", "2026-09-23")
    ], days)
    compare(bars.length, 2)
    verify(bars[0].lane !== bars[1].lane)
    compare(Logic.laneCount(bars), 2)
  }

  function test_non_overlapping_bars_share_a_lane() {
    var days = Logic.weekDays("2026-09-22", 0)
    var bars = Logic.allDayBars([
      allDay("A", "2026-09-20", "2026-09-22"),
      allDay("B", "2026-09-23", "2026-09-25")
    ], days)
    compare(bars[0].lane, 0)
    compare(bars[1].lane, 0)
    compare(Logic.laneCount(bars), 1)
  }

  // Lanes are assigned across the whole week, so a day is only as deep as the
  // bars that actually cover it — reserving the week's deepest stack on every
  // cell was pushing lone appointments down under two lanes of nothing.
  function test_bar_depths_are_per_day_not_per_week() {
    var days = Logic.weekDays("2026-09-29", 0)   // Sun 27 Sep .. Sat 3 Oct
    var bars = Logic.allDayBars([
      allDay("The Day of Our", "2026-09-27", "2026-09-28"),
      allDay("Noah's Birthday", "2026-09-29", "2026-09-30"),
      allDay("Pay Day", "2026-09-30", "2026-10-01"),
      allDay("Second reminder", "2026-09-30", "2026-10-01"),
      allDay("Julianne's Birthday", "2026-10-02", "2026-10-03")
    ], days)
    compare(Logic.laneCount(bars), 2)
    var depths = Logic.barDepths(bars, 7)
    //        27 28 29 30  1  2  3
    compare(depths[0], 1)   // one bar
    compare(depths[1], 0)   // nothing at all — this was reserving two
    compare(depths[2], 1)
    compare(depths[3], 2)   // two stacked
    compare(depths[4], 0)
    compare(depths[5], 1)
    compare(depths[6], 0)
  }

  function test_bar_depths_ignore_lanes_that_are_not_drawn() {
    var days = Logic.weekDays("2026-09-22", 0)
    var bars = Logic.allDayBars([
      allDay("A", "2026-09-20", "2026-09-26"),
      allDay("B", "2026-09-20", "2026-09-26"),
      allDay("C", "2026-09-20", "2026-09-26")
    ], days)
    compare(Logic.laneCount(bars), 3)
    // The month draws two lanes; the third reserves nothing because nothing
    // is drawn for it.
    var depths = Logic.barDepths(bars, 7, 2)
    compare(depths[0], 2)
    compare(depths[3], 2)
  }

  function test_bar_depths_empty_week() {
    var depths = Logic.barDepths([], 7, 2)
    compare(depths.length, 7)
    for (var i = 0; i < 7; i++) compare(depths[i], 0)
  }

  // Four slots a day, all-day bars and appointments drawing from the same
  // four, and the last one turning into a count when they do not all fit.
  function test_cell_slots_everything_fits() {
    var s = Logic.cellSlots(0, 0, 3, 4)
    compare(s.shownTimed, 3)
    compare(s.hidden, 0)
    compare(s.more, false)
  }

  function test_cell_slots_exactly_full() {
    var s = Logic.cellSlots(1, 1, 3, 4)
    compare(s.shownTimed, 3)
    compare(s.hidden, 0)
    compare(s.more, false)
  }

  function test_cell_slots_one_over_keeps_a_slot_for_the_count() {
    // Two bars and three appointments is five things in four slots: two bars,
    // one appointment, "+2 more".
    var s = Logic.cellSlots(2, 2, 3, 4)
    compare(s.shownTimed, 1)
    compare(s.hidden, 2)
    compare(s.more, true)
  }

  // A bar the month could not draw is hidden whatever room is left below it,
  // so its presence alone means the day owes a count.
  function test_cell_slots_counts_undrawn_all_day_events() {
    var s = Logic.cellSlots(1, 3, 0, 4)
    compare(s.shownTimed, 0)
    compare(s.hidden, 2)
    compare(s.more, true)
  }

  // A bar sits in the lane its whole span could take, so a day can be two
  // deep while carrying one all-day event. The empty lane above it is not an
  // undrawn event and the day owes nothing for it.
  function test_cell_slots_ragged_lane_is_not_an_undrawn_event() {
    var s = Logic.cellSlots(2, 1, 2, 4)
    compare(s.shownTimed, 2)
    compare(s.hidden, 0)
    compare(s.more, false)
  }

  function test_cell_slots_full_of_bars_has_nowhere_for_the_count() {
    var s = Logic.cellSlots(4, 4, 2, 4)
    compare(s.shownTimed, 0)
    compare(s.more, false)
  }

  function test_bars_exclude_events_from_other_weeks() {
    var days = Logic.weekDays("2026-09-22", 0)
    compare(Logic.allDayBars([allDay("Old", "2026-08-01", "2026-08-05")], days).length, 0)
  }

  // ------------------------------------------------------- timed layout

  function test_single_event_takes_the_whole_column() {
    var blocks = Logic.layoutTimed(
      [timed("Solo", "2026-09-22T08:00:00-05:00", "2026-09-22T09:00:00-05:00")],
      "2026-09-22")
    compare(blocks.length, 1)
    compare(blocks[0].lane, 0)
    compare(blocks[0].lanes, 1)
    compare(blocks[0].startMinute, 480)
    compare(blocks[0].endMinute, 540)
  }

  function test_overlapping_events_split_the_column() {
    var blocks = Logic.layoutTimed([
      timed("A", "2026-09-22T08:00:00-05:00", "2026-09-22T10:00:00-05:00"),
      timed("B", "2026-09-22T09:00:00-05:00", "2026-09-22T11:00:00-05:00")
    ], "2026-09-22")
    compare(blocks.length, 2)
    compare(blocks[0].lanes, 2)
    compare(blocks[1].lanes, 2)
    verify(blocks[0].lane !== blocks[1].lane)
  }

  // Two appointments at the same time is the ordinary case in this calendar.
  function test_simultaneous_events_sit_side_by_side() {
    var blocks = Logic.layoutTimed([
      timed("Swimming lesson", "2026-09-22T08:00:00-05:00", "2026-09-22T16:00:00-05:00"),
      timed("Piano practice", "2026-09-22T08:00:00-05:00", "2026-09-22T15:00:00-05:00")
    ], "2026-09-22")
    compare(blocks[0].lanes, 2)
    compare(blocks[0].lane, 0)
    compare(blocks[1].lane, 1)
  }

  // A later pair that does not touch the earlier one must not be widened by it.
  function test_separate_clusters_are_sized_independently() {
    var blocks = Logic.layoutTimed([
      timed("A", "2026-09-22T08:00:00-05:00", "2026-09-22T09:00:00-05:00"),
      timed("B", "2026-09-22T13:00:00-05:00", "2026-09-22T15:00:00-05:00"),
      timed("C", "2026-09-22T14:00:00-05:00", "2026-09-22T16:00:00-05:00")
    ], "2026-09-22")
    var byTitle = {}
    for (var i = 0; i < blocks.length; i++) byTitle[blocks[i].event.title] = blocks[i]
    compare(byTitle["A"].lanes, 1)
    compare(byTitle["B"].lanes, 2)
    compare(byTitle["C"].lanes, 2)
  }

  // Touching but not overlapping: 9-10 and 10-11 belong in one lane.
  function test_back_to_back_events_do_not_overlap() {
    var blocks = Logic.layoutTimed([
      timed("A", "2026-09-22T09:00:00-05:00", "2026-09-22T10:00:00-05:00"),
      timed("B", "2026-09-22T10:00:00-05:00", "2026-09-22T11:00:00-05:00")
    ], "2026-09-22")
    compare(blocks[0].lanes, 1)
    compare(blocks[1].lanes, 1)
  }

  function test_event_continuing_from_yesterday_starts_at_midnight() {
    var blocks = Logic.layoutTimed(
      [timed("Red eye", "2026-09-21T22:00:00-05:00", "2026-09-22T06:00:00-05:00")],
      "2026-09-22")
    compare(blocks[0].startMinute, 0)
    compare(blocks[0].endMinute, 360)
  }

  function test_zero_length_event_still_gets_a_box() {
    var blocks = Logic.layoutTimed(
      [timed("Ping", "2026-09-22T08:00:00-05:00", "2026-09-22T08:00:00-05:00")],
      "2026-09-22")
    verify(blocks[0].endMinute > blocks[0].startMinute)
  }

  function test_layout_skips_all_day_events() {
    compare(Logic.layoutTimed([allDay("Birthday", "2026-09-22", "2026-09-23")],
                              "2026-09-22").length, 0)
  }

  // --------------------------------------------------------------- colour

  function test_contrast_ratio_matches_wcag() {
    // Black on white is the maximum, 21:1.
    fuzzyCompare(Logic.contrastRatio("#000000", "#ffffff"), 21, 0.01)
    compare(Logic.contrastRatio("#ffffff", "#ffffff"), 1)
  }

  // The real numbers from the Hackerman theme, which is why this exists.
  function test_detects_the_unreadable_theme_muted() {
    verify(Logic.contrastRatio("#2d3450", "#0B0C16") < 2.0)
    verify(Logic.contrastRatio("#ddf7ff", "#0B0C16") > 15.0)
  }

  function test_ensure_contrast_lifts_muted_to_aa() {
    var fixed = Logic.ensureContrast("#2d3450", "#0B0C16", 4.5)
    verify(Logic.contrastRatio(fixed, "#0B0C16") >= 4.5,
           fixed + " is still under 4.5:1")
  }

  function test_ensure_contrast_leaves_passing_colours_alone() {
    compare(Logic.ensureContrast("#ddf7ff", "#0B0C16", 4.5), "#ddf7ff")
  }

  // On a light theme it has to darken instead of lighten.
  function test_ensure_contrast_darkens_on_light_backgrounds() {
    var fixed = Logic.ensureContrast("#cccccc", "#ffffff", 4.5)
    verify(Logic.contrastRatio(fixed, "#ffffff") >= 4.5)
    verify(Logic.relativeLuminance(fixed) < Logic.relativeLuminance("#cccccc"))
  }

  // It should not overshoot to pure white when a nudge is enough.
  function test_ensure_contrast_stops_when_the_threshold_is_met() {
    var fixed = Logic.ensureContrast("#2d3450", "#0B0C16", 4.5)
    verify(fixed !== "#ffffff", "overshot all the way to white")
    verify(Logic.contrastRatio(fixed, "#0B0C16") < 6.0, "overshot well past AA")
  }

  // QML hands colours over as #AARRGGBB.
  function test_ensure_contrast_accepts_qml_argb() {
    var fixed = Logic.ensureContrast("#ff2d3450", "#ff0B0C16", 4.5)
    verify(Logic.contrastRatio(fixed, "#0B0C16") >= 4.5)
  }

  function test_ensure_contrast_survives_nonsense() {
    compare(Logic.ensureContrast("", "#000000", 4.5), "")
    compare(Logic.ensureContrast("transparent", "#000000", 4.5), "transparent")
  }

  // ---------------------------------------------------------------- setup

  // ------------------------------------------------------------ help steps

  function test_every_step_has_a_title_and_an_instruction() {
    var steps = Logic.appPasswordSteps()
    verify(steps.length >= 5, "too few steps to be instructions")
    for (var i = 0; i < steps.length; i++) {
      verify(steps[i].title.length > 3, "step " + i + " has no title")
      // A title names the step; it is not a sentence and takes no full stop.
      verify(steps[i].title.charAt(steps[i].title.length - 1) !== ".",
             "step " + i + " title ends in a full stop")
      verify(steps[i].text.length > 10, "step " + i + " says almost nothing")
      verify(steps[i].text.charAt(steps[i].text.length - 1) === ".",
             "step " + i + " instruction is not a sentence")
    }
  }

  // Signing in comes first, then where to go — the two steps that carry links.
  function test_the_first_two_steps_are_the_ones_with_links() {
    var steps = Logic.appPasswordSteps()
    verify(!!steps[0].link, "step 1 should link to the account page")
    verify(!!steps[1].link, "step 2 should link to Sign-In & Security")
    verify(steps[1].title.indexOf("Sign-In") >= 0, "step 2 is not Sign-In & Security")
  }

  // A link that is shown for trust has to be one, and has to be Apple's.
  function test_every_link_is_https_and_apple() {
    var steps = Logic.appPasswordSteps()
    var links = 0
    for (var i = 0; i < steps.length; i++) {
      if (!steps[i].link) continue
      verify(steps[i].link.indexOf("https://") === 0,
             "not https: " + steps[i].link)
      verify(steps[i].link.indexOf("apple.com") > 0,
             "not an Apple link: " + steps[i].link)
      links++
    }
    verify(links > 0, "no links at all")
  }

  // The instructions must mention the two things people get wrong.
  function test_steps_cover_two_factor_and_the_one_time_showing() {
    var all = Logic.appPasswordSteps().map(function (s) {
      return s.title + " " + s.text
    }).join(" ")
    verify(all.indexOf("two-factor") >= 0, "does not mention 2FA")
    verify(all.indexOf("once") >= 0, "does not say the password is shown once")
  }

  // iCloud only for now, and the form is built from this list.
  function test_only_icloud_is_offered() {
    compare(Logic.providerPresets(), ["iCloud"])
  }

  function test_preset_carries_a_server_and_a_hint() {
    compare(Logic.presetFor("iCloud").server, "https://caldav.icloud.com/")
    verify(Logic.presetFor("iCloud").hint.indexOf("app-specific") >= 0)
  }

  // An unknown name still yields a preset, so the form always has one to read.
  function test_preset_falls_back_rather_than_returning_nothing() {
    verify(!!Logic.presetFor("Nonsense").server)
  }

  function test_account_problem_catches_each_empty_field() {
    compare(Logic.accountProblem("", "https://x.y/", "pw"), "An account is needed.")
    compare(Logic.accountProblem("me@x.y", "https://x.y/", ""), "A password is needed.")
    verify(Logic.accountProblem("me@x.y", "", "pw").indexOf("URL") >= 0)
  }

  function test_account_problem_wants_an_apple_id_and_a_url() {
    verify(Logic.accountProblem("nobody", "https://x.y/", "pw").indexOf("Apple ID") >= 0)
    verify(Logic.accountProblem("me@x.y", "caldav.icloud.com", "pw").indexOf("URL") >= 0)
  }

  // An Apple ID can be a phone number, which account.apple.com accepts.
  function test_account_problem_accepts_a_phone_number() {
    compare(Logic.accountProblem("+1 337 555 0148", "https://x.y/", "pw"), "")
    compare(Logic.accountProblem("(337) 555-0148", "https://x.y/", "pw"), "")
  }

  function test_account_problem_still_rejects_a_bare_word() {
    verify(Logic.accountProblem("lancefaul", "https://x.y/", "pw") !== "")
  }

  // Editing an account that already holds a password: the empty box is the
  // stored one not being shown, not a missing answer.
  function test_account_problem_accepts_a_held_password() {
    compare(Logic.accountProblem("me@x.y", "https://x.y/", "", true), "")
    compare(Logic.accountProblem("me@x.y", "https://x.y/", "", false),
            "A password is needed.")
  }

  // A held password does not excuse the other fields.
  function test_account_problem_still_wants_the_account() {
    compare(Logic.accountProblem("", "https://x.y/", "", true), "An account is needed.")
  }

  function test_account_problem_passes_a_filled_form() {
    compare(Logic.accountProblem("me@example.com", "https://caldav.icloud.com/", "pw"), "")
  }

  // ------------------------------------------------------------- provider

  function test_provider_names_the_known_services() {
    compare(Logic.providerName("https://caldav.icloud.com/"), "iCloud")
    compare(Logic.providerName("https://p99-caldav.icloud.com:443/"), "iCloud")
    compare(Logic.providerName("https://caldav.fastmail.com/"), "Fastmail")
  }

  function test_provider_falls_back_to_the_host_name() {
    compare(Logic.providerName("https://dav.example.com/remote.php/dav/"), "Example")
    compare(Logic.providerName("https://cloud.mycompany.net/"), "Cloud")
  }

  function test_provider_handles_nothing() {
    compare(Logic.providerName(""), "Calendars")
    compare(Logic.providerName(null), "Calendars")
  }

  // ----------------------------------------------------------- formatting

  // Every time is the same width, so a column of them lines up: two-digit
  // hour, minutes always shown even on the hour.
  function test_format_time_12h_is_always_the_same_width() {
    compare(Logic.formatTime("2026-09-22T08:00:00-05:00", "12h"), "08:00 AM")
    compare(Logic.formatTime("2026-09-22T08:30:00-05:00", "12h"), "08:30 AM")
    compare(Logic.formatTime("2026-09-22T13:00:00-05:00", "12h"), "01:00 PM")
    compare(Logic.formatTime("2026-09-22T21:00:00-05:00", "12h"), "09:00 PM")
  }

  function test_every_12h_time_is_eight_characters() {
    for (var h = 0; h < 24; h++) {
      var iso = "2026-09-22T" + (h < 10 ? "0" + h : h) + ":05:00-05:00"
      compare(Logic.formatTime(iso, "12h").length, 8, "wrong width at hour " + h)
    }
  }

  function test_format_time_handles_noon_and_midnight() {
    compare(Logic.formatTime("2026-09-22T00:00:00-05:00", "12h"), "12:00 AM")
    compare(Logic.formatTime("2026-09-22T12:00:00-05:00", "12h"), "12:00 PM")
    compare(Logic.formatTime("2026-09-22T12:30:00-05:00", "12h"), "12:30 PM")
  }

  function test_format_time_24h() {
    compare(Logic.formatTime("2026-09-22T08:00:00-05:00", "24h"), "08:00")
    compare(Logic.formatTime("2026-09-22T13:05:00-05:00", "24h"), "13:05")
  }

  function test_format_range() {
    compare(Logic.formatRange(allDay("B", "2026-09-22", "2026-09-23"), "12h"), "All day")
    compare(Logic.formatRange(
      timed("S", "2026-09-22T08:00:00-05:00", "2026-09-22T09:00:00-05:00"), "12h"),
      "08:00 AM – 09:00 AM")
  }

  function test_weekday_labels_follow_week_start() {
    compare(Logic.weekdayLabels(0, 3)[0], "Sun")
    compare(Logic.weekdayLabels(1, 3)[0], "Mon")
    compare(Logic.weekdayLabels(1, 3)[6], "Sun")
  }

  function test_month_label() {
    compare(Logic.monthLabel(2026, 9), "September 2026")
  }

  // The header stacks the name over the year.
  function test_month_name_alone() {
    compare(Logic.monthName(9), "September")
    compare(Logic.monthName(1), "January")
    compare(Logic.monthName(12), "December")
  }

  function test_format_day_header() {
    compare(Logic.formatDayHeader("2026-09-22"), "Tuesday, September 22")
  }

  function test_day_header_splits_for_a_narrow_column() {
    compare(Logic.weekdayOfName("2026-09-19"), "Saturday")
    compare(Logic.formatDayLabel("2026-09-19"), "September 19, 2026")
  }

  // iCloud writes a location as venue name, newline, street address. Left
  // alone, Text draws both lines and elide only trims the last one, so the
  // address escapes the column.
  function test_single_line_flattens_a_multi_line_location() {
    compare(Logic.singleLine("Northgate Primary School\n908 Kestrel Rise, Dunmore, OX"),
            "Northgate Primary School, 908 Kestrel Rise, Dunmore, OX")
  }

  function test_single_line_handles_crlf_and_blank_lines() {
    compare(Logic.singleLine("A\r\nB"), "A, B")
    compare(Logic.singleLine("A\n\n  B  "), "A, B")
  }

  function test_single_line_collapses_runs_of_spaces() {
    compare(Logic.singleLine("LA  70508,   United States"), "LA 70508, United States")
  }

  function test_single_line_leaves_a_plain_string_alone() {
    compare(Logic.singleLine("Swimming lesson"), "Swimming lesson")
  }

  function test_single_line_survives_nothing() {
    compare(Logic.singleLine(""), "")
    compare(Logic.singleLine(null), "")
    compare(Logic.singleLine(undefined), "")
  }

  function test_location_lines_splits_an_address_block() {
    var lines = Logic.locationLines(
      "Northgate Primary School\n908 Kestrel Rise, Dunmore, OX  70508")
    compare(lines.length, 2)
    compare(lines[0], "Northgate Primary School")
    compare(lines[1], "908 Kestrel Rise, Dunmore, OX 70508")
  }

  function test_location_lines_drops_blank_lines() {
    compare(Logic.locationLines("A\r\n\n  B  ").join("|"), "A|B")
    compare(Logic.locationLines("One line").join("|"), "One line")
  }

  function test_location_lines_survives_nothing() {
    compare(Logic.locationLines("").length, 0)
    compare(Logic.locationLines(null).length, 0)
    compare(Logic.locationLines(undefined).length, 0)
  }

  function test_available_label() {
    compare(Logic.availableLabel(0), "None")
    compare(Logic.availableLabel(1), "1 available")
    compare(Logic.availableLabel(3), "3 available")
  }

  function test_event_count_label() {
    compare(Logic.eventCountLabel(0), "None")
    compare(Logic.eventCountLabel(1), "1 event")
    compare(Logic.eventCountLabel(3), "3 events")
  }
}
