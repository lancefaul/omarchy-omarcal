import QtQuick
import QtTest
import "../Logic.js" as Logic

// The edit form's rules. The form holds a draft and draws it; everything
// about what a draft means, and what saving it would change, is here.
TestCase {
  name: "edit"

  function timed(extra) {
    var e = { uid: "u1", href: "/cal/u1.ics", title: "Standup",
              calendarUrl: "https://cal/work/", allDay: false,
              start: "2026-09-22T09:00:00-05:00", end: "2026-09-22T09:30:00-05:00",
              rrule: "", alarms: [], location: "", url: "", description: "" }
    for (var k in extra) e[k] = extra[k]
    return e
  }

  function whole(extra) {
    var e = timed({ allDay: true, start: "2026-09-22", end: "2026-09-23" })
    for (var k in extra) e[k] = extra[k]
    return e
  }

  // ---------------------------------------------------------- permission

  function test_can_edit_only_a_loaded_writable_event() {
    verify(Logic.canEdit(timed({})))
    verify(!Logic.canEdit(timed({ href: "" })), "detail not in yet")
    verify(!Logic.canEdit(timed({ readonly: true })), "shared read-only")
    verify(!Logic.canEdit(null))
  }

  function test_series_is_a_rule_or_an_occurrence_of_one() {
    verify(!Logic.isSeries(timed({})))
    verify(Logic.isSeries(timed({ recurring: true })))
    // An exception carries no rule of its own, but it is still one of many.
    verify(Logic.isSeries(timed({ rid: "20260922T140000Z" })))
  }

  // --------------------------------------------------------------- draft

  function test_draft_from_a_timed_event() {
    var d = Logic.editDraft(timed({}))
    compare(d.title, "Standup")
    compare(d.startDate, "2026-09-22")
    compare(d.startTime, "09:00")
    compare(d.endDate, "2026-09-22")
    compare(d.endTime, "09:30")
    compare(d.repeat, "none")
    compare(d.alerts, ["none", "none"])
    compare(d.travel, "0")
    compare(d.invitees, [])
  }

  // Exclusive in the data, inclusive on the form.
  function test_all_day_end_is_the_last_day_it_covers() {
    compare(Logic.editDraft(whole({})).endDate, "2026-09-22")
    compare(Logic.editDraft(whole({ end: "2026-09-25" })).endDate, "2026-09-24")
    compare(Logic.draftEvent(Logic.editDraft(whole({ end: "2026-09-25" }))).end,
            "2026-09-25")
  }

  function test_all_day_draft_has_hours_to_fall_back_on() {
    var d = Logic.editDraft(whole({}))
    compare(d.startTime, "09:00")
    compare(d.endTime, "10:00")
  }

  function test_draft_event_drops_the_offset() {
    var e = Logic.draftEvent(Logic.editDraft(timed({})))
    compare(e.start, "2026-09-22T09:00:00")
    compare(e.end, "2026-09-22T09:30:00")
  }

  function test_untouched_draft_changes_nothing() {
    compare(Logic.draftChanges(Logic.editDraft(timed({})), timed({})), [])
    compare(Logic.draftChanges(Logic.editDraft(whole({})), whole({})), [])
    var odd = timed({ rrule: "FREQ=WEEKLY;UNTIL=20261231T000000Z",
                      alarms: ["-PT7M", "19760401T005545Z"] })
    compare(Logic.draftChanges(Logic.editDraft(odd), odd), [])
  }

  function test_changes_name_the_fields() {
    var d = Logic.withField(Logic.editDraft(timed({})), "title", "Retro")
    compare(Logic.draftChanges(d, timed({})), ["title"])
    // Whitespace around a title is not an edit.
    d = Logic.withField(Logic.editDraft(timed({})), "title", "  Standup ")
    compare(Logic.draftChanges(d, timed({})), [])
  }

  // ------------------------------------------------------------- moving

  function test_moving_the_start_time_keeps_the_length() {
    var d = Logic.withField(Logic.editDraft(timed({})), "startTime", "13:15")
    compare(d.endTime, "13:45")
    compare(d.endDate, "2026-09-22")
  }

  function test_moving_the_start_late_carries_the_end_past_midnight() {
    var d = Logic.withField(Logic.editDraft(timed({})), "startTime", "23:45")
    compare(d.endDate, "2026-09-23")
    compare(d.endTime, "00:15")
  }

  function test_moving_the_start_date_carries_the_end_date() {
    var d = Logic.withField(Logic.editDraft(whole({ end: "2026-09-25" })),
                            "startDate", "2026-10-01")
    compare(d.endDate, "2026-10-03")
    d = Logic.withField(Logic.editDraft(timed({})), "startDate", "2026-09-30")
    compare(d.endDate, "2026-09-30")
    compare(d.endTime, "09:30")
  }

  function test_moving_the_end_moves_nothing_else() {
    var d = Logic.withField(Logic.editDraft(timed({})), "endTime", "11:00")
    compare(d.startTime, "09:00")
    compare(d.endTime, "11:00")
  }

  // ----------------------------------------------------------- problems

  function test_problems() {
    var d = Logic.editDraft(timed({}))
    compare(Logic.draftProblem(d), "")
    compare(Logic.draftProblem(Logic.withField(d, "title", "  ")),
            "Give the event a title.")
    compare(Logic.draftProblem(Logic.withField(d, "endTime", "08:00")),
            "It ends before it starts.")
    compare(Logic.draftProblem(Logic.withField(d, "endDate", "2026-02-30")),
            "Pick a start and an end date.")
    compare(Logic.draftProblem(Logic.withField(d, "url", "example.com")),
            "A link needs its scheme, like https://.")
    compare(Logic.draftProblem(Logic.withField(d, "url", "https://example.com")), "")
  }

  function test_a_timed_event_may_end_as_it_starts() {
    var d = Logic.withField(Logic.editDraft(timed({})), "endTime", "09:00")
    compare(Logic.draftProblem(d), "")
  }

  function test_all_day_ignores_the_times() {
    var d = Logic.withField(Logic.editDraft(whole({})), "endTime", "01:00")
    compare(Logic.draftProblem(d), "")
    d = Logic.withField(d, "endDate", "2026-09-21")
    compare(Logic.draftProblem(d), "It ends before it starts.")
  }

  // ------------------------------------------------------------- repeat

  function test_repeat_recognises_apples_spellings() {
    compare(Logic.repeatKey("", "2026-09-22"), "none")
    compare(Logic.repeatKey("FREQ=DAILY;INTERVAL=1", "2026-09-22"), "daily")
    compare(Logic.repeatKey("FREQ=WEEKLY;INTERVAL=1;WKST=SU", "2026-09-22"), "weekly")
    // 2026-09-22 is a Tuesday: a weekly rule naming Tuesday is just weekly.
    compare(Logic.repeatKey("FREQ=WEEKLY;BYDAY=TU", "2026-09-22"), "weekly")
    compare(Logic.repeatKey("FREQ=WEEKLY;BYDAY=WE", "2026-09-22"), "custom")
    compare(Logic.repeatKey("FREQ=HOURLY", "2026-09-22"), "kept")
    compare(Logic.repeatKey("FREQ=WEEKLY;INTERVAL=2", "2026-09-22"), "biweekly")
    compare(Logic.repeatKey("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", "2026-09-22"), "weekdays")
    compare(Logic.repeatKey("FREQ=YEARLY", "2026-09-22"), "yearly")
  }

  // A rule the controls cannot say is kept as it is and offered in words.
  function test_an_unsayable_rule_is_kept_as_it_is() {
    var rule = "FREQ=MONTHLY;BYMONTHDAY=1,15"
    var d = Logic.editDraft(timed({ rrule: rule, recurring: true }))
    compare(d.repeat, "kept")
    compare(Logic.draftEvent(d).rrule, rule)
    var rows = Logic.repeatChoices(d)
    compare(rows[rows.length - 1].value, "kept")
    compare(rows[rows.length - 1].label, "Every month")
  }

  function test_kept_is_only_offered_for_a_kept_rule() {
    var rows = Logic.repeatChoices(Logic.editDraft(timed({})))
    for (var i = 0; i < rows.length; i++) verify(rows[i].value !== "kept")
    compare(rows[rows.length - 1].value, "custom")
  }

  function test_picking_a_repeat_writes_its_rule() {
    var d = Logic.withField(Logic.editDraft(timed({})), "repeat", "monthly")
    compare(Logic.draftEvent(d).rrule, "FREQ=MONTHLY")
    compare(Logic.draftChanges(d, timed({})), ["rrule"])
    d = Logic.withField(Logic.editDraft(timed({ rrule: "FREQ=DAILY" })), "repeat", "none")
    compare(Logic.draftEvent(d).rrule, "")
  }

  // -------------------------------------------------------------- alert

  function test_alarm_minutes_ignore_spelling() {
    compare(Logic.alarmMinutes("-PT60M"), -60)
    compare(Logic.alarmMinutes("-PT1H"), -60)
    compare(Logic.alarmMinutes("PT0S"), 0)
    compare(Logic.alarmMinutes("-P1DT15H"), -(39 * 60))
    compare(Logic.alarmMinutes("19760401T005545Z"), null)
    compare(Logic.alarmMinutes("-P"), null)
    compare(Logic.alarmMinutes(""), null)
  }

  function test_alert_picks_the_first_real_alarm() {
    var d = Logic.editDraft(timed({ alarms: ["19760401T005545Z", "-PT60M"] }))
    compare(d.alertIndexes, [1, -1])
    compare(d.alerts, ["-PT1H", "none"])
  }

  function test_an_unlisted_alert_is_offered_as_itself() {
    var d = Logic.editDraft(timed({ alarms: ["-PT7M"] }))
    compare(d.alerts[0], "-PT7M")
    var rows = Logic.alertChoices(d)
    compare(rows[rows.length - 1].label, "7 minutes before")
  }

  function test_changing_the_alert_leaves_the_other_alarms() {
    var e = timed({ alarms: ["19760401T005545Z", "-PT15M", "-P1D"] })
    var d = Logic.withAlert(Logic.editDraft(e), 0, "-PT30M")
    compare(Logic.draftEvent(d).alarms, ["19760401T005545Z", "-PT30M", "-P1D"])
    d = Logic.withAlert(Logic.editDraft(e), 0, "none")
    compare(Logic.draftEvent(d).alarms, ["19760401T005545Z", "-P1D"])
    d = Logic.withAlert(Logic.editDraft(timed({})), 0, "-PT5M")
    compare(Logic.draftEvent(d).alarms, ["-PT5M"])
  }

  function test_all_day_offers_times_of_day() {
    var rows = Logic.alertChoices(Logic.editDraft(whole({})))
    compare(rows[1].label, "On the day, 9 AM")
  }

  function test_switching_all_day_keeps_the_alert() {
    var d = Logic.editDraft(timed({ alarms: ["-P1D"] }))
    d = Logic.withField(d, "allDay", true)
    compare(d.alerts[0], "-P1D")
    var rows = Logic.alertChoices(d)
    compare(rows[rows.length - 1].label, "1 day before")
  }

  // --------------------------------------------------------------- time

  function test_time_choices_every_quarter_hour() {
    var rows = Logic.timeChoices("24h", "09:00")
    compare(rows.length, 96)
    compare(rows[0].value, "00:00")
    compare(rows[37].label, "09:15")
    compare(Logic.timeChoices("12h", "")[52].label, "01:00 PM")
  }

  function test_an_off_grid_time_is_slotted_in() {
    var rows = Logic.timeChoices("24h", "10:05")
    compare(rows.length, 97)
    compare(rows[40].value, "10:00")
    compare(rows[41].value, "10:05")
    compare(rows[42].value, "10:15")
  }

  function test_short_date() {
    compare(Logic.shortDate("2026-09-22"), "Tue, Sep 22, 2026")
    compare(Logic.shortDate("nope"), "")
  }

  // -------------------------------------------------------------- scope

  function test_no_scope_for_a_single_event() {
    compare(Logic.scopeChoices(timed({}), ["title"]), [])
  }

  function test_all_three_scopes_for_a_series() {
    var rows = Logic.scopeChoices(timed({ recurring: true }), ["title"])
    compare(rows.map(function (r) { return r.value }), ["this", "following", "all"])
  }

  // A rule or a calendar belongs to the series, not to one occurrence.
  function test_series_only_changes_drop_this_event() {
    var s = timed({ recurring: true })
    compare(Logic.scopeChoices(s, ["rrule"]).map(function (r) { return r.value }),
            ["following", "all"])
    compare(Logic.scopeChoices(s, ["calendarUrl", "title"]).map(function (r) { return r.value }),
            ["following", "all"])
  }

  // ---------------------------------------------------------- calendars

  function test_editable_calendars() {
    var cals = [
      { url: "a", name: "Work", enabled: true },
      { url: "b", name: "Holidays", enabled: true, readonly: true },
      { url: "c", name: "Off", enabled: false },
      { url: "d", name: "Home" }
    ]
    compare(Logic.editableCalendars(cals, "a").map(function (c) { return c.value }), ["a", "d"])
    // The one it is in stays, so the dropdown has its own value.
    compare(Logic.editableCalendars(cals, "b").map(function (c) { return c.value }), ["a", "b", "d"])
  }

  // ------------------------------------------------------------- prompts

  function test_prompts_follow_the_scopes() {
    var one = Logic.actionPrompt("delete", [])
    verify(one.indexOf("deletes the event") !== -1)
    compare(Logic.actionPrompt("save", []), "")
    var all = Logic.scopeChoices({ recurring: true }, [])
    verify(Logic.actionPrompt("delete", all).indexOf("Delete only this one") !== -1)
    var some = Logic.scopeChoices({ recurring: true }, ["rrule"])
    verify(Logic.actionPrompt("save", some).indexOf("belong to the whole series") !== -1)
  }

  // ------------------------------------------------------ custom repeat

  function values(rows) { return rows.map(function (r) { return r.value }) }

  // 2026-09-22 is the fourth Tuesday of September; 2026-09-29 the last.
  function test_parse_the_shapes_the_controls_can_say() {
    var r = Logic.parseRule("FREQ=WEEKLY;INTERVAL=3;BYDAY=MO,WE,FR", "2026-09-22", 0)
    compare(r.freq, "WEEKLY"); compare(r.interval, 3); compare(r.days, ["MO", "WE", "FR"])
    compare(Logic.parseRule("FREQ=MONTHLY;BYDAY=4TU", "2026-09-22", 0).monthBy, "weekday")
    compare(Logic.parseRule("FREQ=MONTHLY;BYDAY=TU;BYSETPOS=4", "2026-09-22", 0).monthBy, "weekday")
    compare(Logic.parseRule("FREQ=MONTHLY;BYDAY=-1TU", "2026-09-29", 0).monthBy, "last")
    compare(Logic.parseRule("FREQ=YEARLY;BYMONTH=9;BYDAY=4TU", "2026-09-22", 0).monthBy, "weekday")
    compare(Logic.parseRule("FREQ=MONTHLY;BYMONTHDAY=22", "2026-09-22", 0).monthBy, "date")
  }

  function test_parse_refuses_what_it_cannot_say() {
    compare(Logic.parseRule("FREQ=MONTHLY;BYDAY=2TU", "2026-09-22", 0), null, "not the start's ordinal")
    compare(Logic.parseRule("FREQ=MONTHLY;BYDAY=-1TU", "2026-09-22", 0), null, "not the last")
    compare(Logic.parseRule("FREQ=YEARLY;BYDAY=4TU", "2026-09-22", 0), null, "no month")
    compare(Logic.parseRule("FREQ=DAILY;BYHOUR=9", "2026-09-22", 0), null)
    compare(Logic.parseRule("FREQ=WEEKLY;BYDAY=1MO", "2026-09-22", 0), null)
    compare(Logic.parseRule("FREQ=WEEKLY;COUNT=2;UNTIL=20261231", "2026-09-22", 0), null)
  }

  function test_build_round_trips() {
    var rules = ["FREQ=WEEKLY;INTERVAL=3;BYDAY=MO,WE,FR", "FREQ=MONTHLY;BYDAY=4TU",
                 "FREQ=YEARLY;BYMONTH=9;BYDAY=4TU", "FREQ=DAILY;INTERVAL=2;COUNT=5",
                 "FREQ=WEEKLY;UNTIL=20261231"]
    for (var i = 0; i < rules.length; i++)
      compare(Logic.buildRule(Logic.parseRule(rules[i], "2026-09-22", 0), "2026-09-22"), rules[i])
    compare(Logic.buildRule(Logic.parseRule("FREQ=MONTHLY;BYDAY=-1TU", "2026-09-29", 0),
                            "2026-09-29"), "FREQ=MONTHLY;BYDAY=-1TU")
  }

  // Apple ends a rule at the last second of the final local day, in UTC.
  function test_until_is_the_last_local_day() {
    compare(Logic.untilKey("20261231T045959Z", -300), "2026-12-30")
    compare(Logic.untilKey("20261231", -300), "2026-12-31")
    compare(Logic.untilKey("20261231T230000Z", 120), "2027-01-01")
    compare(Logic.untilKey("nope", 0), "")
    var d = Logic.editDraft(timed({ rrule: "FREQ=WEEKLY;UNTIL=20261231T045959Z" }))
    compare(d.rule.ends, "on")
    compare(d.rule.until, "2026-12-30")
  }

  function test_presets_ignore_how_a_rule_ends() {
    var d = Logic.editDraft(timed({ rrule: "FREQ=WEEKLY;COUNT=10" }))
    compare(d.repeat, "weekly")
    compare(Logic.ruleSummary(d), "Every week on Tue, 10 times")
  }

  function test_a_preset_keeps_the_end() {
    var d = Logic.editDraft(timed({ rrule: "FREQ=WEEKLY;COUNT=10" }))
    d = Logic.withField(d, "repeat", "monthly")
    compare(Logic.draftEvent(d).rrule, "FREQ=MONTHLY;COUNT=10")
  }

  // Opening and saving must not rewrite a rule the form only read.
  function test_an_untouched_rule_goes_back_as_it_came() {
    var rule = "FREQ=WEEKLY;INTERVAL=1;WKST=SU;UNTIL=20261231T045959Z"
    var d = Logic.editDraft(timed({ rrule: rule }))
    compare(Logic.draftEvent(d).rrule, rule)
    d = Logic.withField(d, "startDate", "2026-09-23")
    compare(Logic.draftEvent(d).rrule, rule)
    compare(Logic.draftChanges(d, timed({ rrule: rule })), ["start", "end"])
  }

  function test_custom_controls() {
    var d = Logic.withField(Logic.editDraft(timed({})), "repeat", "custom")
    d = Logic.withRule(d, "interval", 2)
    d = Logic.withDayToggled(d, "TH")
    compare(Logic.draftEvent(d).rrule, "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH")
    compare(Logic.ruleSummary(d), "Every 2 weeks on Tue, Thu")
    d = Logic.withRule(d, "freq", "MONTHLY")
    d = Logic.withRule(d, "monthBy", "weekday")
    compare(Logic.draftEvent(d).rrule, "FREQ=MONTHLY;INTERVAL=2;BYDAY=4TU")
    compare(Logic.ruleSummary(d), "Every 2 months, on the fourth Tuesday")
  }

  function test_the_last_day_cannot_be_toggled_off() {
    var d = Logic.withField(Logic.editDraft(timed({})), "repeat", "custom")
    d = Logic.withDayToggled(d, "TU")
    compare(d.rule.days, ["TU"])
  }

  function test_ends_get_a_starting_value() {
    var d = Logic.withField(Logic.editDraft(timed({})), "repeat", "weekly")
    d = Logic.withRule(d, "ends", "on")
    compare(d.rule.until, "2026-10-22")
    compare(Logic.draftEvent(d).rrule, "FREQ=WEEKLY;UNTIL=20261022")
    d = Logic.withRule(d, "ends", "after")
    compare(Logic.draftEvent(d).rrule, "FREQ=WEEKLY;COUNT=10")
  }

  function test_repeat_problems() {
    var d = Logic.withField(Logic.editDraft(timed({})), "repeat", "weekly")
    d = Logic.withRule(Logic.withRule(d, "ends", "on"), "until", "2026-09-01")
    compare(Logic.draftProblem(d), "The repeat has to end on or after the first day.")
    d = Logic.withRule(Logic.withRule(d, "ends", "after"), "count", 0)
    compare(Logic.draftProblem(d), "The repeat has to run at least once.")
    d = Logic.withRule(Logic.withRule(d, "ends", "never"), "interval", 0)
    compare(Logic.draftProblem(d), "Repeat every 1 or more.")
  }

  function test_month_options_follow_the_start() {
    compare(values(Logic.monthByOptions("2026-09-22", "MONTHLY")), ["date", "weekday"])
    compare(Logic.monthByOptions("2026-09-22", "MONTHLY")[1].label, "On the fourth Tuesday")
    // The 29th is the fifth and last Tuesday: offered only as the last.
    compare(values(Logic.monthByOptions("2026-09-29", "MONTHLY")), ["date", "last"])
    compare(Logic.monthByOptions("2026-09-22", "YEARLY")[1].label,
            "On the fourth Tuesday of September")
  }

  function test_day_toggles_follow_the_week_start() {
    compare(values(Logic.dayToggles(1)), ["MO", "TU", "WE", "TH", "FR", "SA", "SU"])
    compare(Logic.dayToggles(0)[0].label, "S")
  }

  // ---------------------------------------------------------- two alerts

  function test_two_alerts_from_the_first_two_real_alarms() {
    var e = timed({ alarms: ["19760401T005545Z", "-PT15M", "-P1D", "-PT5M"] })
    var d = Logic.editDraft(e)
    compare(d.alerts, ["-PT15M", "-P1D"])
    compare(d.alertIndexes, [1, 2])
    // A third alarm the form does not show goes back untouched.
    d = Logic.withAlert(d, 1, "-PT1H")
    compare(Logic.draftEvent(d).alarms, ["19760401T005545Z", "-PT15M", "-PT1H", "-PT5M"])
    d = Logic.withAlert(Logic.withAlert(d, 0, "none"), 1, "none")
    compare(Logic.draftEvent(d).alarms, ["19760401T005545Z", "-PT5M"])
  }

  function test_a_second_alert_is_added() {
    var d = Logic.withAlert(Logic.editDraft(timed({ alarms: ["-PT15M"] })), 1, "-P1D")
    compare(Logic.draftEvent(d).alarms, ["-PT15M", "-P1D"])
    compare(Logic.draftChanges(d, timed({ alarms: ["-PT15M"] })), ["alarms"])
  }

  // --------------------------------------------------------------- travel

  function test_travel_choices() {
    var rows = Logic.travelChoices(Logic.editDraft(timed({})))
    compare(rows.map(function (r) { return r.label }),
            ["None", "5 minutes", "10 minutes", "15 minutes", "30 minutes",
             "1 hour", "1.5 hours", "2 hours"])
  }

  function test_a_routed_travel_time_is_offered_as_itself() {
    var d = Logic.editDraft(timed({ travel: "PT23M" }))
    compare(d.travel, "23")
    var rows = Logic.travelChoices(d)
    compare(rows[rows.length - 1].label, "23 minutes")
    compare(Logic.draftEvent(d).travel, "PT23M")
  }

  function test_travel_is_written_as_a_duration() {
    var d = Logic.withField(Logic.editDraft(timed({})), "travel", "90")
    compare(Logic.draftEvent(d).travel, "PT1H30M")
    compare(Logic.draftChanges(d, timed({})), ["travel"])
    // None on an all-day event, which has no travel time.
    compare(Logic.draftEvent(Logic.withField(d, "allDay", true)).travel, "")
  }

  function test_minutes_duration() {
    compare(Logic.minutesDuration(5), "PT5M")
    compare(Logic.minutesDuration(120), "PT2H")
    compare(Logic.minutesDuration(-15), "-PT15M")
    compare(Logic.minutesDuration(0), "PT0S")
    compare(Logic.minutesDuration(1500), "P1DT1H")
  }

  // ------------------------------------------------------------- invitees

  function test_email_validation() {
    var good = ["a@b.co", "first.last@example.com", "x+tag@mail.example.org",
                "o'neil@example.ie", "UPPER@EXAMPLE.COM"]
    for (var i = 0; i < good.length; i++) verify(Logic.isEmail(good[i]), good[i])
    var bad = ["", "plain", "@example.com", "a@", "a@b", "a@b.c", "a b@example.com",
               "a@@example.com", "a@example..com", ".a@example.com", "a.@example.com",
               "a..b@example.com", "a@-example.com", "a@example.com.",
               "a@exam_ple.com", "a@example.c0m"]
    for (i = 0; i < bad.length; i++) verify(!Logic.isEmail(bad[i]), bad[i])
  }

  function test_invitee_problems() {
    var d = Logic.editDraft(timed({ attendeeList: [{ email: "Sam@Example.com", name: "Sam" }] }))
    compare(Logic.inviteeProblem(d, "", "me@icloud.com"), "")
    compare(Logic.inviteeProblem(d, "sam@example", "me@icloud.com"),
            "Invalid email. Please fix or remove.")
    compare(Logic.inviteeProblem(d, "sam@example.com", "me@icloud.com"), "Already invited.")
    verify(Logic.inviteeProblem(d, "ME@icloud.com", "me@icloud.com").indexOf("organiser") !== -1)
    compare(Logic.inviteeProblem(d, "jo@example.com", "me@icloud.com"), "")
  }

  function test_adding_and_removing_invitees() {
    var e = timed({ attendeeList: [{ email: "sam@example.com", name: "Sam", status: "ACCEPTED" }] })
    var d = Logic.withInvitee(Logic.editDraft(e), " jo@example.com ", "Jo")
    compare(d.invitees.length, 2)
    compare(d.invitees[1].status, "NEEDS-ACTION")
    compare(Logic.draftEvent(d).invitees, ["sam@example.com", "jo@example.com"])
    compare(Logic.draftChanges(d, e), ["invitees"])
    d = Logic.withoutInvitee(d, "SAM@example.com")
    compare(Logic.draftEvent(d).invitees, ["jo@example.com"])
  }

  function test_only_the_organiser_invites() {
    verify(Logic.canInvite(timed({}), "me@icloud.com"))
    verify(Logic.canInvite(timed({ organizer: "ME@icloud.com" }), "me@icloud.com"))
    verify(!Logic.canInvite(timed({ organizer: "boss@example.com" }), "me@icloud.com"))
  }

  function test_a_typed_but_unadded_invitee_blocks_saving() {
    var d = Logic.editDraft(timed({}))
    compare(Logic.draftProblem(d, "jo@exa"), "Invalid email. Please fix or remove.")
    compare(Logic.draftProblem(d, "jo@example.com"), "Add the invitee you typed, or clear it.")
    compare(Logic.draftProblem(d, "  "), "")
  }

  function test_status_labels() {
    compare(Logic.inviteeStatus("ACCEPTED"), "Accepted")
    compare(Logic.inviteeStatus("tentative"), "Maybe")
    compare(Logic.inviteeStatus(""), "No reply yet")
  }

  function test_saving_invitees_says_they_are_emailed() {
    verify(Logic.actionPrompt("save", [], ["invitees"]).indexOf("iCloud emails") !== -1)
    compare(Logic.actionPrompt("save", [], ["title"]), "")
  }

  // ------------------------------------------------------------- contacts

  function test_contact_suggestions() {
    var people = [
      { name: "Sam Rivera", email: "sam@example.com" },
      { name: "Jo Samuels", email: "jo@example.com" },
      { name: "Alex Kim", email: "akim@sample.org" },
      { name: "Broken", email: "not-an-address" }
    ]
    var d = Logic.editDraft(timed({}))
    compare(Logic.contactSuggestions(people, "s", d, 6), [], "one letter is too few")
    // Word and address prefixes first, then anything containing it.
    compare(Logic.contactSuggestions(people, "sam", d, 6).map(function (c) { return c.email }),
            ["sam@example.com", "jo@example.com", "akim@sample.org"])
    d = Logic.withInvitee(d, "sam@example.com", "Sam Rivera")
    compare(Logic.contactSuggestions(people, "sam", d, 6).length, 2, "already invited")
    compare(Logic.contactSuggestions(people, "broken", d, 6), [], "no usable address")
  }

  function test_contacts_status() {
    verify(Logic.contactsStatusLine(false, 0, "").indexOf("typing their email") !== -1)
    compare(Logic.contactsStatusLine(true, 3, ""), "3 contacts available")
    verify(Logic.contactsStatusLine(true, 0, "").indexOf("type addresses") !== -1)
    compare(Logic.contactsStatusLine(true, 3, "offline"), "offline")
  }

  // --------------------------------------------------------- conference

  // A video call has its own field, apart from the URL, so both can be set.
  function test_conference_is_its_own_field() {
    var e = timed({ url: "https://example.com/agenda", conference: "https://zoom.us/j/1" })
    var d = Logic.editDraft(e)
    compare(d.conference, "https://zoom.us/j/1")
    compare(Logic.draftChanges(d, e), [])
    d = Logic.withField(d, "conference", " https://meet.google.com/abc ")
    compare(Logic.draftEvent(d).conference, "https://meet.google.com/abc")
    compare(Logic.draftEvent(d).url, "https://example.com/agenda")
    compare(Logic.draftChanges(d, e), ["conference"])
  }

  function test_conference_needs_a_scheme() {
    var d = Logic.withField(Logic.editDraft(timed({})), "conference", "zoom.us/j/1")
    compare(Logic.draftProblem(d), "A video call needs its full address, like https:// or tel:.")
    compare(Logic.draftProblem(Logic.withField(d, "conference", "tel:+15550100")), "")
  }

  // ---------------------------------------------------------- attachments

  function test_attachments() {
    var e = timed({ attachments: [
      { name: "agenda.pdf", size: 2048, managedId: "m1" },
      { name: "invite.ics", size: 0, managedId: "" }] })
    var d = Logic.editDraft(e)
    compare(Logic.attachmentLines(d.attachments), ["agenda.pdf \u00b7 2 KB", "invite.ics"])
    compare(Logic.draftChanges(d, e), [])
    d = Logic.withoutAttachment(d, 0)
    compare(Logic.draftEvent(d).attachments, ["has:invite.ics"])
    compare(Logic.draftChanges(d, e), ["attachments"])
    d = Logic.withAttachment(d, { path: "/home/me/notes.txt", size: 90 })
    d = Logic.withAttachment(d, { path: "/home/me/notes.txt", size: 90 })
    compare(Logic.draftEvent(d).attachments, ["has:invite.ics", "add:/home/me/notes.txt"])
    compare(d.attachments[1].name, "notes.txt")
  }

  function test_parse_picked() {
    compare(Logic.parsePicked('{"ok": true, "picked": true, "path": "/home/me/a b.pdf", "name": "a b.pdf", "size": 2048}'),
            { path: "/home/me/a b.pdf", name: "a b.pdf", size: 2048 })
    compare(Logic.parsePicked('{"ok": true, "picked": false}'), null, "cancelled")
    compare(Logic.parsePicked(""), null)
    verify(Logic.parsePicked('{"ok": false, "error": "no session bus"}').error.indexOf("no session bus") !== -1)
  }

  // ----------------------------------------------------- attachment limits

  function draftWith(count, each) {
    var files = []
    for (var i = 0; i < count; i++) files.push({ name: "f" + i + ".pdf", size: each, managedId: "m" + i })
    return Logic.editDraft(timed({ attachments: files }))
  }

  function test_twenty_attachments_at_most() {
    compare(Logic.attachmentProblem(draftWith(19, 10), { path: "/a.txt", size: 10 }), "")
    compare(Logic.attachmentProblem(draftWith(20, 10), { path: "/a.txt", size: 10 }),
            "An event can hold 20 attachments.")
  }

  function test_twenty_megabytes_in_all() {
    var d = draftWith(2, 9 * 1000 * 1000)
    compare(Logic.attachmentProblem(d, { path: "/a.bin", size: 2 * 1000 * 1000 }), "")
    verify(Logic.attachmentProblem(d, { path: "/a.bin", size: 2 * 1000 * 1000 + 1 })
             .indexOf("past iCloud") !== -1)
  }

  function test_names_icloud_cannot_sync() {
    var d = draftWith(0, 0)
    var bad = ["a:b.txt", "what?.pdf", "star*.png", "q\".txt", "lt<.txt", "gt>.txt", "pipe|.txt", "back\\slash.txt"]
    for (var i = 0; i < bad.length; i++)
      verify(Logic.attachmentProblem(d, { path: "/home/me/" + bad[i], size: 1 }).indexOf("rename") !== -1, bad[i])
    compare(Logic.attachmentProblem(d, { path: "/home/me/fine name (1).pdf", size: 1 }), "")
  }

  function test_attachment_summary() {
    compare(Logic.attachmentSummary([]), "None")
    compare(Logic.attachmentSummary([{ size: 2048 }, { size: 0 }]), "2 of 20 \u00b7 2 KB of 20 MB")
  }

  // An event that arrives over the limits cannot be saved until it is under.
  function test_over_the_limit_blocks_saving() {
    compare(Logic.draftProblem(draftWith(21, 1)), "Remove attachments down to 20.")
    compare(Logic.draftProblem(draftWith(3, 7 * 1000 * 1000)),
            "Attachments come to more than iCloud\u2019s 20 MB for one event.")
  }

  // --------------------------------------------------------------- places

  function test_place_suggestions() {
    var history = [
      { text: "Grace Church, Main St", count: 9 },
      { text: "12 Oak Lane\nSpringfield", count: 4, place: { lat: 1, lon: 2, title: "12 Oak Lane" } },
      { text: "Bakery on Oakwood", count: 2 }
    ]
    compare(Logic.placeSuggestions(history, "o", 5), [], "one letter is too few")
    // "oak" starts a word in the second, sits inside a word in the third.
    compare(Logic.placeSuggestions(history, "oak", 5).map(function (p) { return p.count }), [4, 2])
    compare(Logic.placeSuggestions(history, "main", 5).length, 1)
    compare(Logic.placeSuggestions(history, "12 oak lane springfield", 5), [], "already in the box")
  }

  function test_a_picked_place_brings_its_point() {
    var d = Logic.withPlace(Logic.editDraft(timed({})),
      { text: "12 Oak Lane\nSpringfield", place: { lat: 1, lon: 2, title: "12 Oak Lane" } })
    compare(d.location, "12 Oak Lane\nSpringfield")
    compare(Logic.draftEvent(d).place, { lat: 1, lon: 2, title: "12 Oak Lane" })
    compare(Logic.draftChanges(d, timed({})), ["location", "place"])
    d = Logic.withPlace(Logic.editDraft(timed({})), { text: "Oak Park", lat: 3, lon: 4, title: "Oak Park" })
    compare(Logic.draftEvent(d).place, { lat: 3, lon: 4, title: "Oak Park" })
  }

  function test_typing_over_an_address_lets_its_point_go() {
    var e = timed({ location: "12 Oak Lane", place: { lat: 1, lon: 2, title: "12 Oak Lane" } })
    var d = Logic.editDraft(e)
    compare(Logic.draftChanges(d, e), [])
    d = Logic.withField(d, "location", "13 Oak Lane")
    compare(d.place, null)
    compare(Logic.draftChanges(d, e), ["location", "place"])
  }

  function test_places_wording_names_the_service() {
    verify(Logic.placesPermissionText("photon").indexOf("komoot") !== -1)
    verify(Logic.placesPermissionText("nominatim").indexOf("press Search") !== -1)
    verify(Logic.placesStatusLine("none").indexOf("Nothing leaves") !== -1)
  }

  // ------------------------------------------------------------ new event

  function test_new_event_defaults() {
    var e = Logic.newEvent("2026-09-24", "2026-09-21", "14:20", "cal-a")
    compare(e.start, "2026-09-24T09:00:00")
    compare(e.end, "2026-09-24T10:00:00")
    compare(e.calendarUrl, "cal-a")
    compare(e.uid, "")
    var d = Logic.editDraft(e)
    compare(d.repeat, "none")
    compare(Logic.draftProblem(d), "Give the event a title.")
  }

  function test_new_event_today_starts_at_the_next_hour() {
    var e = Logic.newEvent("2026-09-21", "2026-09-21", "14:20", "cal-a")
    compare(e.start, "2026-09-21T15:00:00")
    compare(e.end, "2026-09-21T16:00:00")
    // Late at night it still starts that day, and ends past midnight.
    e = Logic.newEvent("2026-09-21", "2026-09-21", "23:40", "cal-a")
    compare(e.start, "2026-09-21T23:00:00")
    compare(e.end, "2026-09-22T00:00:00")
  }

  function test_default_calendar() {
    var cals = [
      { url: "b", name: "Birthdays", objects: 174 },
      { url: "f", name: "Family", objects: 3104 },
      { url: "p", name: "Personal", objects: 647 },
      { url: "r", name: "Shared", objects: 9999, readonly: true },
      { url: "o", name: "Off", objects: 9999, enabled: false }
    ]
    compare(Logic.defaultCalendar(cals, "", ""), "f", "most events, writable, on")
    compare(Logic.defaultCalendar(cals, "p", ""), "p", "the chosen one")
    compare(Logic.defaultCalendar(cals, "r", ""), "f", "a chosen one that cannot be written to")
    compare(Logic.defaultCalendar([], "", ""), "")
  }

  // Two accounts: the first account's busiest wins, not the busiest anywhere.
  function severalAccounts() {
    return [
      { url: "i1", name: "Personal", account: "me@icloud.com", objects: 600 },
      { url: "i2", name: "Family", account: "me@icloud.com", objects: 900 },
      { url: "w1", name: "Personal", account: "me@work.com", objects: 5000 }
    ]
  }

  function test_default_stays_in_the_first_account() {
    compare(Logic.defaultCalendar(severalAccounts(), "", "me@icloud.com"), "i2")
    compare(Logic.defaultCalendar(severalAccounts(), "w1", "me@icloud.com"), "w1", "unless chosen")
    // No calendar of the first account can be written to: anywhere will do.
    compare(Logic.defaultCalendar(severalAccounts(), "", "gone@icloud.com"), "w1")
  }

  function test_rows_name_their_account_only_when_there_are_several() {
    var rows = Logic.editableCalendars(severalAccounts(), "")
    compare(rows.map(function (r) { return r.note }), ["me@icloud.com", "me@icloud.com", "me@work.com"])
    rows = Logic.editableCalendars(severalAccounts().slice(0, 2), "")
    compare(rows.map(function (r) { return r.note }), ["", ""])
  }

  function test_a_vanished_default_is_said() {
    compare(Logic.defaultCalendarNote(severalAccounts(), "i1", "me@icloud.com"), "")
    compare(Logic.defaultCalendarNote(severalAccounts(), "gone", "me@icloud.com"),
            "The calendar chosen here can\u2019t take new events any more; "
            + "they go to Family until you pick another.")
    compare(Logic.defaultCalendarNote(severalAccounts(), "", "me@icloud.com"), "")
  }

  function test_moving_between_accounts_is_said() {
    compare(Logic.moveNote(severalAccounts(), "i1", "i2"), "", "same account: a move")
    verify(Logic.moveNote(severalAccounts(), "i1", "w1").indexOf("me@work.com") !== -1)
    compare(Logic.moveNote(severalAccounts(), "i1", "i1"), "")
  }

  // ------------------------------------------------------------- requests

  function test_alarm_plan_names_only_what_changed() {
    var e = timed({ alarms: ["19760401T005545Z", "-PT15M", "-P1D", "-PT5M"] })
    var d = Logic.editDraft(e)
    compare(Logic.alarmPlan(d), { set: {}, remove: [], add: [] })
    d = Logic.withAlert(Logic.withAlert(d, 0, "-PT30M"), 1, "none")
    compare(Logic.alarmPlan(d), { set: { 1: "-PT30M" }, remove: [2], add: [] })
    d = Logic.withAlert(Logic.editDraft(timed({})), 0, "-PT5M")
    compare(Logic.alarmPlan(d), { set: {}, remove: [], add: ["-PT5M"] })
    // The same moment spelled differently is not a change.
    d = Logic.withAlert(Logic.editDraft(timed({ alarms: ["-PT60M"] })), 0, "-PT1H")
    compare(Logic.alarmPlan(d), { set: {}, remove: [], add: [] })
  }

  function test_attachment_plan() {
    var e = timed({ attachments: [{ name: "a.pdf", managedId: "m1", size: 1 },
                                  { name: "invite.ics", managedId: "", size: 0 }] })
    var d = Logic.withoutAttachment(Logic.withoutAttachment(Logic.editDraft(e), 0), 0)
    d = Logic.withAttachment(d, { path: "/home/me/new.txt", size: 3 })
    compare(Logic.attachmentPlan(d, e), { addFiles: [{ path: "/home/me/new.txt", type: "" }],
                                          removeManaged: ["m1"], removeNames: ["invite.ics"] })
  }

  function test_save_request_for_an_existing_event() {
    var e = timed({ href: "https://x/cal/1.ics", etag: '"e1"', calendarUrl: "https://x/cal/",
                    recurring: true, rid: "" })
    var d = Logic.withField(Logic.editDraft(e), "title", "Retro")
    var r = Logic.saveRequest(d, e, { start: "2026-09-22T09:00:00-05:00", rid: "" }, "this", false, "me@icloud.com")
    compare(r.href, "https://x/cal/1.ics")
    compare(r.etag, '"e1"')
    compare(r.scope, "this")
    compare(r.changes, ["title"])
    compare(r.occurrenceStart, "2026-09-22T09:00:00-05:00")
    compare(r.event.title, "Retro")
    compare(r.organizer, "me@icloud.com")
  }

  function test_save_request_for_a_new_event() {
    var base = Logic.newEvent("2026-09-24", "2026-09-21", "10:00", "https://x/cal/")
    var d = Logic.withAlert(Logic.withField(Logic.editDraft(base), "title", "Lunch"), 0, "-PT15M")
    var r = Logic.saveRequest(d, base, null, "", true, "me@icloud.com")
    compare(r.href, "")
    compare(r.targetCalendarUrl, "https://x/cal/")
    verify(r.changes.indexOf("title") !== -1 && r.changes.indexOf("start") !== -1)
    compare(r.alarmPlan.add, ["-PT15M"])
    compare(r.occurrenceStart, "")
  }

  function test_delete_request() {
    var one = timed({ href: "h", etag: "e" })
    compare(Logic.deleteRequest(one, { start: "s", rid: "" }, "").occurrenceStart, "", "not a series")
    var many = timed({ href: "h", etag: "e", recurring: true })
    var r = Logic.deleteRequest(many, { start: "2026-09-22T09:00:00-05:00", rid: "R" }, "this")
    compare([r.scope, r.occurrenceStart, r.rid], ["this", "2026-09-22T09:00:00-05:00", "R"])
  }

  function test_write_outcome() {
    compare(Logic.writeOutcome("save", { ok: true }).message, "Saved.")
    compare(Logic.writeOutcome("delete", { ok: true }).done, true)
    verify(Logic.writeOutcome("save", { ok: false, code: "conflict", error: "changed" }).conflict)
    compare(Logic.writeOutcome("save", { ok: true, problems: ["a.pdf was not attached (HTTP 507)"] }).message,
            "Saved. But a.pdf was not attached (HTTP 507).")
  }

  function test_discard_prompt() {
    verify(Logic.actionPrompt("discard", [], ["title"]).indexOf("haven\u2019t been saved") !== -1)
  }

  // ------------------------------------------------------ review findings

  function test_attachments_belong_to_the_series() {
    compare(Logic.scopeChoices({ recurring: true }, ["attachments"]).map(function (r) { return r.value }),
            ["following", "all"])
  }

  // The helper's reading of UNTIL, made with the zone's rules, wins over
  // the start's offset — which is a DST change out of date by December.
  function test_until_date_from_the_helper_wins() {
    var e = timed({ rrule: "FREQ=WEEKLY;UNTIL=20261231T055959Z", untilDate: "2026-12-30" })
    compare(Logic.editDraft(e).rule.until, "2026-12-30")
    // Without it, the September offset (-5) puts it on the 31st: the bug.
    compare(Logic.editDraft(timed({ rrule: "FREQ=WEEKLY;UNTIL=20261231T055959Z" })).rule.until, "2026-12-31")
  }

  // ------------------------------------------------------------ duplicate

  function test_duplicate_drops_what_ties_it_to_the_original() {
    var e = timed({ href: "h", etag: "e", rid: "R", recurring: true, rrule: "FREQ=WEEKLY",
                    organizer: "me@icloud.com", alarms: ["-PT15M"], travel: "PT30M",
                    attendeeList: [{ email: "sam@example.com", name: "Sam" }],
                    attachments: [{ name: "a.pdf", managedId: "m1", size: 1 }],
                    location: "12 Oak Lane", conference: "https://zoom.us/j/1" })
    var copy = Logic.duplicateOf(e)
    compare([copy.uid, copy.href, copy.etag, copy.rid], ["", "", "", ""])
    compare(copy.attendeeList, [])
    compare(copy.attachments, [])
    compare(copy.rrule, "FREQ=WEEKLY", "repeats as the original does")
    var d = Logic.editDraft(copy)
    compare(d.alerts[0], "-PT15M")
    compare(d.travel, "30")
    compare(d.location, "12 Oak Lane")
    compare(d.conference, "https://zoom.us/j/1")
    // Saved as a new event, with the alarms added rather than edited.
    var r = Logic.saveRequest(d, copy, null, "", true, "me@icloud.com")
    compare(r.href, "")
    compare(r.alarmPlan.add, ["-PT15M"])
    compare(r.invitees, [])
    compare(r.addFiles, [])
    compare(e.uid, "u1", "the original is untouched")
  }

  // ------------------------------------------------------------ time zones

  function test_zones_default_to_the_viewers() {
    var d = Logic.editDraft(timed({}), "America/Chicago")
    compare([d.startZone, d.endZone], ["America/Chicago", "America/Chicago"])
    compare(Logic.draftChanges(d, timed({})), [], "the default is not a change")
    var copy = Logic.editDraft(Logic.newEvent("2026-10-01", "2026-09-21", "10:00", "c"), "America/Chicago")
    compare(Logic.draftEvent(copy).startZone, "America/Chicago")
  }

  function test_an_event_in_another_zone_edits_in_it() {
    var e = timed({ start: "2026-09-30T19:00:00-05:00", end: "2026-09-30T20:00:00-05:00",
                    startZone: "Asia/Tokyo", endZone: "Asia/Tokyo",
                    startWall: "2026-10-01T09:00:00", endWall: "2026-10-01T10:00:00" })
    var d = Logic.editDraft(e, "America/Chicago")
    compare([d.startDate, d.startTime, d.startZone], ["2026-10-01", "09:00", "Asia/Tokyo"])
    compare(Logic.draftEvent(d).start, "2026-10-01T09:00:00")
    compare(Logic.draftChanges(d, e), [])
  }

  function test_the_end_follows_the_start_until_set_apart() {
    var d = Logic.editDraft(timed({}), "America/Chicago")
    d = Logic.withField(d, "startZone", "Europe/London")
    compare(d.endZone, "Europe/London")
    compare(Logic.draftChanges(d, timed({})), ["startZone", "endZone"])
    d = Logic.withField(d, "endZone", "Asia/Tokyo")
    d = Logic.withField(d, "startZone", "Europe/Paris")
    compare(d.endZone, "Asia/Tokyo", "set apart, it stays")
  }

  function test_all_day_events_have_no_zone() {
    var d = Logic.withField(Logic.editDraft(timed({}), "America/Chicago"), "allDay", true)
    compare([Logic.draftEvent(d).startZone, Logic.draftEvent(d).endZone], ["", ""])
  }

  function test_ends_in_two_zones_are_not_compared_as_text() {
    var d = Logic.editDraft(timed({}), "America/Chicago")
    d = Logic.withField(Logic.withField(d, "endZone", "Asia/Tokyo"), "endTime", "08:00")
    compare(Logic.draftProblem(d), "")
  }

  function test_zone_search_and_labels() {
    var zones = [{ name: "America/Chicago", offset: -300 }, { name: "Asia/Tokyo", offset: 540 },
                 { name: "America/Argentina/Buenos_Aires", offset: -180 },
                 { name: "Asia/Kolkata", offset: 330 }]
    compare(Logic.zoneChoices(zones, "", "America/Chicago", 30).map(function (z) { return z.value }),
            ["America/Chicago"], "nothing typed: your own")
    compare(Logic.zoneChoices(zones, "tok", "America/Chicago", 30)[0].value, "Asia/Tokyo")
    compare(Logic.zoneChoices(zones, "buenos a", "", 30)[0].label, "Buenos Aires")
    compare(Logic.zoneChoices(zones, "buenos a", "", 30)[0].note, "America / Argentina \u00b7 UTC\u22123")
    compare(Logic.zoneChoices(zones, "asia", "", 30).length, 2, "by region")
    compare(Logic.zoneLabel("Asia/Kolkata", zones, ""), "Kolkata (UTC+5:30)")
    compare(Logic.zoneRow(zones[0], "America/Chicago").label, "Chicago (your time zone)")
    compare(Logic.utcOffsetLabel(0), "UTC")
  }

  function test_a_queued_write_says_so() {
    var o = Logic.writeOutcome("save", { ok: true, queued: true, pending: 1 })
    verify(o.done && o.queued)
    verify(o.message.indexOf("on this computer") !== -1)
    verify(Logic.writeOutcome("delete", { ok: true, queued: true }).message.indexOf("Deleted") === 0)
  }
}
