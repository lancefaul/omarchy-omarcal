"""The helper's writes, planned offline. Every event here is invented.

`plan_save` and `plan_delete` turn a stored object and the form's request
into the PUTs and DELETEs a save comes to; nothing here reaches a server.
`run_writes` is exercised against a fake session, for the one answer that
matters most: 412, somebody else changed it first.
"""
import importlib.machinery
import importlib.util
import os
import re
import sys
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "..", "helper", "omarcal-helper")
_loader = importlib.machinery.SourceFileLoader("omarcal_helper_writes", HELPER)
_spec = importlib.util.spec_from_loader("omarcal_helper_writes", _loader)
helper = importlib.util.module_from_spec(_spec)
_loader.exec_module(helper)

ZONES = helper.Zones("America/Chicago")
CAL = "https://example.invalid/home/cal/"
HREF = CAL + "one.ics"


def vcal(*events):
    return "\r\n".join(["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//test//EN",
                        *events, "END:VCALENDAR", ""])


def vevent(*lines):
    return "\r\n".join(["BEGIN:VEVENT", *lines, "END:VEVENT"])


SINGLE = vcal(vevent(
    "UID:single-1", "DTSTAMP:20260101T000000Z", "SEQUENCE:2",
    "DTSTART;TZID=America/Chicago:20260922T090000",
    "DTEND;TZID=America/Chicago:20260922T093000",
    "SUMMARY:Standup", "X-APPLE-SOMETHING:keep me",
    "ATTENDEE;CN=Sam;PARTSTAT=ACCEPTED:mailto:sam@example.com",
    "ORGANIZER:mailto:me@icloud.com",
    "BEGIN:VALARM", "ACTION:AUDIO", "TRIGGER:-PT15M", "ATTACH;VALUE=URI:Basso", "END:VALARM",
    "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-P1D", "END:VALARM"))

# Weekly on Tuesdays from Sept 1, ten times; the Sept 15 one was moved.
SERIES = vcal(vevent(
    "UID:series-1", "DTSTAMP:20260101T000000Z",
    "DTSTART;TZID=America/Chicago:20260901T090000",
    "DTEND;TZID=America/Chicago:20260901T100000",
    "RRULE:FREQ=WEEKLY;COUNT=10", "SUMMARY:Class",
    "EXDATE;TZID=America/Chicago:20261006T090000"), vevent(
    "UID:series-1", "DTSTAMP:20260101T000000Z",
    "RECURRENCE-ID;TZID=America/Chicago:20260915T090000",
    "DTSTART;TZID=America/Chicago:20260915T110000",
    "DTEND;TZID=America/Chicago:20260915T120000", "SUMMARY:Class (moved)"))


def request(**over):
    base = {"href": HREF, "etag": '"e1"', "calendarUrl": CAL, "targetCalendarUrl": CAL,
            "scope": "", "occurrenceStart": "", "changes": [], "organizer": "me@icloud.com",
            "event": {"title": "Standup", "allDay": False,
                      "start": "2026-09-22T09:00:00", "end": "2026-09-22T09:30:00",
                      "rrule": "", "location": "", "place": None, "url": "",
                      "conference": "", "travel": "", "description": ""}}
    for key, value in over.items():
        if key == "event":
            base["event"] = dict(base["event"], **value)
        else:
            base[key] = value
    return base


def unfold(text):
    return re.sub(r"\r?\n[ \t]", "", text)


def events_of(body):
    return re.findall(r"BEGIN:VEVENT.*?END:VEVENT", unfold(body), re.S)


class Create(unittest.TestCase):
    def setUp(self):
        req = request(href="", etag="", changes=[], event={
            "title": "Dinner, with friends", "rrule": "FREQ=WEEKLY;UNTIL=20261231",
            "location": "12 Oak Lane\nSpringfield",
            "place": {"lat": 30.1, "lon": -92.0, "title": "12 Oak Lane"},
            "conference": "https://zoom.us/j/1", "travel": "PT30M"})
        req["alarmPlan"] = {"add": ["-PT15M"]}
        req["invitees"] = [{"email": "jo@example.com", "name": "Jo"}]
        self.ops = helper.plan_save("", req, ZONES)
        self.body = unfold(self.ops[0]["body"])

    def test_one_put_that_must_not_replace_anything(self):
        self.assertEqual(len(self.ops), 1)
        self.assertEqual(self.ops[0]["method"], "PUT")
        self.assertTrue(self.ops[0]["ifNoneMatch"])
        self.assertTrue(self.ops[0]["url"].startswith(CAL))
        self.assertIn("UID:" + self.ops[0]["uid"], self.body)

    def test_times_carry_the_zone_and_its_definition(self):
        self.assertIn("DTSTART;TZID=America/Chicago:20260922T090000", self.body)
        self.assertIn("BEGIN:VTIMEZONE", self.body)
        self.assertIn("TZID:America/Chicago", self.body)

    def test_until_becomes_the_last_second_of_that_day_in_utc(self):
        # 23:59:59 on Dec 31 in Chicago (CST, -6) is 05:59:59Z on Jan 1.
        self.assertIn("RRULE:FREQ=WEEKLY;UNTIL=20270101T055959Z", self.body)

    def test_every_part(self):
        self.assertIn("SUMMARY:Dinner\\, with friends", self.body)
        self.assertIn("CONFERENCE;VALUE=URI;FEATURE=VIDEO:https://zoom.us/j/1", self.body)
        self.assertIn("X-APPLE-TRAVEL-DURATION;VALUE=DURATION:PT30M", self.body)
        self.assertIn("geo:30.1,-92.0", self.body)
        self.assertIn("TRIGGER:-PT15M", self.body)
        self.assertIn("ORGANIZER:mailto:me@icloud.com", self.body)
        self.assertRegex(self.body, r"ATTENDEE;CN=Jo;.*PARTSTAT=NEEDS-ACTION.*:mailto:jo@example.com")


class Update(unittest.TestCase):
    def test_only_what_changed_and_everything_else_kept(self):
        ops = helper.plan_save(SINGLE, request(changes=["title"], event={"title": "Retro"}), ZONES)
        self.assertEqual([(o["method"], o["url"], o["ifMatch"]) for o in ops],
                         [("PUT", HREF, '"e1"')])
        body = unfold(ops[0]["body"])
        self.assertIn("SUMMARY:Retro", body)
        self.assertIn("X-APPLE-SOMETHING:keep me", body)
        # libical drops VALUE=URI, which is ATTACH's default: the same line.
        self.assertRegex(body, r"ATTACH(;VALUE=URI)?:Basso", "an alarm's sound survives")
        self.assertEqual(body.count("BEGIN:VTIMEZONE"), 1, "the zone it names, defined once")
        self.assertIn("DTSTART;TZID=America/Chicago:20260922T090000", body)
        self.assertIn("SEQUENCE:3", body)

    def test_no_zone_added_to_an_event_that_names_none(self):
        utc = SINGLE.replace("DTSTART;TZID=America/Chicago:20260922T090000", "DTSTART:20260922T140000Z") \
                    .replace("DTEND;TZID=America/Chicago:20260922T093000", "DTEND:20260922T143000Z")
        body = unfold(helper.plan_save(utc, request(changes=["title"], event={"title": "Retro"}),
                                       ZONES)[0]["body"])
        self.assertNotIn("BEGIN:VTIMEZONE", body)
        self.assertIn("DTSTART:20260922T140000Z", body)

    def test_alarm_plan(self):
        req = request(changes=["alarms"])
        req["alarmPlan"] = {"set": {"0": "-PT30M"}, "remove": [1], "add": ["-PT5M"]}
        body = unfold(helper.plan_save(SINGLE, req, ZONES)[0]["body"])
        triggers = re.findall(r"TRIGGER:(\S+)", body)
        self.assertEqual(triggers, ["-PT30M", "-PT5M"])
        self.assertRegex(body, r"ATTACH(;VALUE=URI)?:Basso", "the edited alarm keeps its sound")

    def test_invitees_keep_their_answers(self):
        req = request(changes=["invitees"])
        req["invitees"] = [{"email": "SAM@example.com", "name": "Sam"},
                           {"email": "jo@example.com", "name": "Jo"}]
        body = unfold(helper.plan_save(SINGLE, req, ZONES)[0]["body"])
        self.assertIn("PARTSTAT=ACCEPTED:mailto:sam@example.com", body)
        self.assertRegex(body, r"PARTSTAT=NEEDS-ACTION.*:mailto:jo@example.com")
        req["invitees"] = []
        body = unfold(helper.plan_save(SINGLE, req, ZONES)[0]["body"])
        self.assertNotIn("ATTENDEE", body)
        self.assertNotIn("ORGANIZER", body)

    def test_moving_calendars_creates_there_then_deletes_here(self):
        other = "https://example.invalid/home/other/"
        ops = helper.plan_save(SINGLE, request(changes=["calendarUrl"], targetCalendarUrl=other), ZONES)
        self.assertEqual([o["method"] for o in ops], ["PUT", "DELETE"])
        self.assertTrue(ops[0]["url"].startswith(other))
        self.assertTrue(ops[0]["ifNoneMatch"])
        self.assertEqual((ops[1]["url"], ops[1]["ifMatch"]), (HREF, '"e1"'))
        self.assertNotIn("UID:single-1", unfold(ops[0]["body"]), "a new UID there")


class Clean(unittest.TestCase):
    def test_libicals_own_error_lines_are_not_sent(self):
        empty_url = SINGLE.replace("SUMMARY:Standup", "SUMMARY:Standup\r\nURL:")
        body = unfold(helper.plan_save(empty_url, request(changes=["title"], event={"title": "R"}),
                                       ZONES)[0]["body"])
        self.assertNotIn("X-LIC-ERROR", body)
        self.assertIn("SUMMARY:R", body)


class Attachments(unittest.TestCase):
    def test_removing_a_managed_attachment_drops_its_line(self):
        with_file = SINGLE.replace("SUMMARY:Standup", "SUMMARY:Standup\r\n"
            "ATTACH;FILENAME=a.pdf;MANAGED-ID=m1;SIZE=3:https://example.invalid/a\r\n"
            "ATTACH;FILENAME=b.pdf;MANAGED-ID=m2;SIZE=3:https://example.invalid/b")
        req = request(changes=["attachments"])
        req["removeManaged"] = ["m1"]
        body = unfold(helper.plan_save(with_file, req, ZONES)[0]["body"])
        self.assertNotIn("MANAGED-ID=m1", body)
        self.assertIn("MANAGED-ID=m2", body)


class Unknown(unittest.TestCase):
    def test_parameters_libical_does_not_know_are_kept(self):
        apple = SINGLE.replace("SUMMARY:Standup", "SUMMARY:Standup\r\n"
                               'X-APPLE-TRAVEL-START;ROUTING=CAR;VALUE=URI;X-TITLE=Home:geo:1,2')
        body = unfold(helper.plan_save(apple, request(changes=["title"], event={"title": "R"}),
                                       ZONES)[0]["body"])
        self.assertIn("ROUTING=CAR", body)


class Series(unittest.TestCase):
    def occurrence(self, **over):
        req = request(scope=over.pop("scope"), occurrenceStart="2026-09-22T09:00:00-05:00",
                      **over)
        return req

    def test_this_event_makes_an_exception_for_its_slot(self):
        req = self.occurrence(scope="this", changes=["title"], event={
            "title": "Class (guest)", "start": "2026-09-22T09:00:00", "end": "2026-09-22T10:00:00"})
        ops = helper.plan_save(SERIES, req, ZONES)
        self.assertEqual(len(ops), 1)
        comps = events_of(ops[0]["body"])
        self.assertEqual(len(comps), 3)
        new = [c for c in comps if "RECURRENCE-ID;TZID=America/Chicago:20260922T090000" in c]
        self.assertEqual(len(new), 1)
        self.assertIn("SUMMARY:Class (guest)", new[0])
        self.assertNotIn("RRULE", new[0])
        master = [c for c in comps if "RRULE" in c][0]
        self.assertIn("SUMMARY:Class\r\n", master + "\r\n", "the series itself is untouched")

    def test_this_event_edits_an_existing_exception(self):
        req = request(scope="this", occurrenceStart="2026-09-15T09:00:00-05:00",
                      changes=["title"], event={"title": "Moved again"})
        comps = events_of(helper.plan_save(SERIES, req, ZONES)[0]["body"])
        self.assertEqual(len(comps), 2)
        self.assertIn("SUMMARY:Moved again", comps[1])
        self.assertIn("DTSTART;TZID=America/Chicago:20260915T110000", comps[1], "its own time kept")

    def test_an_exception_is_found_by_its_rid_not_its_start(self):
        # The Sept 15 class was moved to 11:00; its slot is still 09:00.
        req = request(scope="this", rid="20260915T090000",
                      occurrenceStart="2026-09-15T11:00:00-05:00",
                      changes=["title"], event={"title": "Found"})
        comps = events_of(helper.plan_save(SERIES, req, ZONES)[0]["body"])
        self.assertEqual(len(comps), 2, "the existing exception, not a new one")
        self.assertIn("SUMMARY:Found", comps[1])

    def test_following_splits_the_series(self):
        req = self.occurrence(scope="following", changes=["title"], event={
            "title": "Class (new room)", "start": "2026-09-22T09:00:00", "end": "2026-09-22T10:00:00"})
        ops = helper.plan_save(SERIES, req, ZONES)
        self.assertEqual([o["method"] for o in ops], ["PUT", "PUT"])
        old, new = unfold(ops[0]["body"]), unfold(ops[1]["body"])
        # 09:00 CDT on Sept 22 is 14:00Z; the old series ends one second before.
        self.assertIn("UNTIL=20260922T135959Z", old)
        self.assertNotIn("COUNT", old.split("BEGIN:VEVENT")[1].split("END:VEVENT")[0])
        self.assertIn("SUMMARY:Class (new room)", new)
        self.assertIn("DTSTART;TZID=America/Chicago:20260922T090000", new)
        # Three of ten happened before (Sept 1, 8, 15): seven left.
        self.assertIn("COUNT=7", new)
        self.assertTrue(ops[1]["ifNoneMatch"])
        self.assertTrue(ops[1]["primary"])
        self.assertIn("EXDATE;TZID=America/Chicago:20261006T090000", new, "later exclusions go along")

    def test_following_from_the_first_is_all(self):
        req = request(scope="following", occurrenceStart="2026-09-01T09:00:00-05:00",
                      changes=["title"], event={"title": "Renamed"})
        ops = helper.plan_save(SERIES, req, ZONES)
        self.assertEqual(len(ops), 1)
        comps = events_of(ops[0]["body"])
        self.assertTrue(all("SUMMARY:Renamed" in c for c in comps), "exceptions renamed too")

    def test_all_moves_the_series_and_its_exceptions_by_as_much(self):
        req = request(scope="all", occurrenceStart="2026-09-22T09:00:00-05:00",
                      changes=["start", "end"], event={
                          "start": "2026-09-22T10:00:00", "end": "2026-09-22T11:00:00"})
        body = unfold(helper.plan_save(SERIES, req, ZONES)[0]["body"])
        self.assertIn("DTSTART;TZID=America/Chicago:20260901T100000", body)
        self.assertIn("EXDATE;TZID=America/Chicago:20261006T100000", body)
        self.assertIn("RECURRENCE-ID;TZID=America/Chicago:20260915T100000", body)
        self.assertIn("DTSTART;TZID=America/Chicago:20260915T120000", body)


class ReviewFindings(unittest.TestCase):
    """The review of the write path, 2026-09-21: each finding, as it was
    reproduced, and what it should have done."""

    def test_following_from_a_moved_exception_starts_on_its_slot(self):
        # Sep 15's class was moved 09:00 -> 11:00. Renaming it "and following"
        # must not move the rest of the series to 11:00.
        req = request(scope="following", rid="20260915T090000",
                      occurrenceStart="2026-09-15T11:00:00-05:00", changes=["title"],
                      event={"title": "Class (new)", "start": "2026-09-15T11:00:00",
                             "end": "2026-09-15T12:00:00"})
        new = unfold(helper.plan_save(SERIES, req, ZONES)[1]["body"])
        comps = events_of(new)
        master = [c for c in comps if "RRULE" in c][0]
        self.assertIn("DTSTART;TZID=America/Chicago:20260915T090000", master)
        self.assertIn("EXDATE;TZID=America/Chicago:20261006T090000", master, "Oct 6 stays cancelled")
        carried = [c for c in comps if "RECURRENCE-ID" in c][0]
        self.assertIn("RECURRENCE-ID;TZID=America/Chicago:20260915T090000", carried)
        self.assertIn("DTSTART;TZID=America/Chicago:20260915T110000", carried, "still at 11")
        self.assertIn("SUMMARY:Class (new)", carried, "the edited occurrence shows the edit")

    def test_all_measures_a_move_from_where_the_exception_is(self):
        # The exception sits at 11:00; moved to 11:30, everything moves 30 min.
        req = request(scope="all", rid="20260915T090000",
                      occurrenceStart="2026-09-15T11:00:00-05:00", changes=["start", "end"],
                      event={"start": "2026-09-15T11:30:00", "end": "2026-09-15T12:30:00"})
        body = unfold(helper.plan_save(SERIES, req, ZONES)[0]["body"])
        self.assertIn("DTSTART;TZID=America/Chicago:20260901T093000", body)
        self.assertIn("DTSTART;TZID=America/Chicago:20260915T113000", body)
        self.assertIn("RECURRENCE-ID;TZID=America/Chicago:20260915T093000", body)

    def test_all_leaves_an_exceptions_own_alarms(self):
        with_alarm = SERIES.replace('"SUMMARY:Class (moved)"', "").replace(
            "SUMMARY:Class (moved)", "SUMMARY:Class (moved)\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\n"
            "TRIGGER:-PT2H\r\nEND:VALARM")
        req = request(scope="all", occurrenceStart="2026-09-22T09:00:00-05:00", changes=["alarms"])
        req["alarmPlan"] = {"set": {}, "remove": [], "add": ["-PT5M"]}
        comps = events_of(helper.plan_save(with_alarm, req, ZONES)[0]["body"])
        master = [c for c in comps if "RRULE" in c][0]
        exception = [c for c in comps if "RECURRENCE-ID" in c][0]
        self.assertIn("TRIGGER:-PT5M", master)
        self.assertNotIn("TRIGGER:-PT5M", exception)
        self.assertIn("TRIGGER:-PT2H", exception)

    def test_each_write_uses_its_own_accounts_session(self):
        asked = []
        original = helper.send
        helper.send = lambda session, method, url, body, headers: (201, {}, b"")
        try:
            helper.run_writes(lambda url: asked.append(url) or object(),
                              [{"method": "PUT", "url": "https://a.invalid/cal/x.ics", "body": "x",
                                "ifNoneMatch": True},
                               {"method": "DELETE", "url": "https://b.invalid/cal/y.ics", "ifMatch": "e"}])
        finally:
            helper.send = original
        self.assertEqual(asked, ["https://a.invalid/cal/x.ics", "https://b.invalid/cal/y.ics"])

    def test_account_of_url(self):
        import sqlite3, tempfile
        with tempfile.TemporaryDirectory() as folder:
            conn = sqlite3.connect(os.path.join(folder, "c.db"))
            conn.executescript(helper.SCHEMA)
            conn.execute("INSERT INTO calendars(url, account) VALUES('https://a.invalid/cal/', 'me@a')")
            conn.execute("INSERT INTO calendars(url, account) VALUES('https://b.invalid/cal/', 'me@b')")
            self.assertEqual(helper.account_of_url(conn, "https://b.invalid/cal/y.ics"), "me@b")
            self.assertEqual(helper.account_of_url(conn, "https://c.invalid/z.ics"), "")
            conn.close()

    def test_until_date_uses_the_zones_rules(self):
        from zoneinfo import ZoneInfo
        saved = helper.LOCAL_TZ
        helper.LOCAL_TZ = ZoneInfo("America/Chicago")
        try:
            # 05:59:59Z on Dec 31 is still Dec 30 in Chicago (CST, -6).
            self.assertEqual(helper.until_date("FREQ=WEEKLY;UNTIL=20261231T055959Z"), "2026-12-30")
            self.assertEqual(helper.until_date("FREQ=WEEKLY;UNTIL=20261231"), "2026-12-31")
            self.assertEqual(helper.until_date("FREQ=WEEKLY"), "")
        finally:
            helper.LOCAL_TZ = saved


class TimeZones(unittest.TestCase):
    def test_a_new_event_in_other_zones(self):
        req = request(href="", etag="", changes=[], event={
            "start": "2026-10-01T09:00:00", "end": "2026-10-01T11:00:00",
            "startZone": "America/Chicago", "endZone": "Asia/Tokyo"})
        body = unfold(helper.plan_save("", req, ZONES)[0]["body"])
        self.assertIn("DTSTART;TZID=America/Chicago:20261001T090000", body)
        self.assertIn("DTEND;TZID=Asia/Tokyo:20261001T110000", body)
        self.assertIn("TZID:Asia/Tokyo", body, "a definition for each zone used")
        self.assertIn("TZID:America/Chicago", body)

    def test_changing_only_the_zone_moves_a_series(self):
        # All of the series from 09:00 Chicago to 09:00 New York: an hour earlier.
        req = request(scope="all", occurrenceStart="2026-09-22T09:00:00-05:00",
                      changes=["startZone", "endZone"], event={
                          "start": "2026-09-22T09:00:00", "end": "2026-09-22T10:00:00",
                          "startZone": "America/New_York", "endZone": "America/New_York"})
        body = unfold(helper.plan_save(SERIES, req, ZONES)[0]["body"])
        self.assertIn("DTSTART;TZID=America/New_York:20260901T090000", body)
        self.assertIn("RECURRENCE-ID;TZID=America/Chicago:20260915T080000", body,
                      "the exception's slot moves by the hour too")

    def test_reading_zones_and_walls(self):
        import sqlite3, tempfile
        ics = vcal(vevent("UID:tz-1", "DTSTART;TZID=Asia/Tokyo:20261001T090000",
                          "DTEND;TZID=Asia/Tokyo:20261001T100000", "SUMMARY:Call"))
        with tempfile.TemporaryDirectory() as folder:
            conn = sqlite3.connect(os.path.join(folder, "c.db"))
            conn.executescript(helper.SCHEMA)
            conn.execute("INSERT INTO calendars(url, name, enabled) VALUES(?, 'Cal', 1)", (CAL,))
            conn.execute("INSERT INTO objects(url, calendar, ics, uid) VALUES(?,?,?,?)",
                         (HREF, CAL, ics, "tz-1"))
            event = helper.event_detail(conn, "tz-1", "")["event"]
            conn.close()
        self.assertEqual((event["startZone"], event["endZone"]), ("Asia/Tokyo", "Asia/Tokyo"))
        self.assertEqual((event["startWall"], event["endWall"]),
                         ("2026-10-01T09:00:00", "2026-10-01T10:00:00"))

    def test_zone_list(self):
        names = {z["name"]: z["offset"] for z in helper.zone_list()}
        self.assertIn("Asia/Tokyo", names)
        self.assertEqual(names["Asia/Tokyo"], 540)
        self.assertNotIn("US/Central", names, "aliases left out")


class Delete(unittest.TestCase):
    def test_single_is_a_delete(self):
        ops = helper.plan_delete(SINGLE, request(), ZONES)
        self.assertEqual([(o["method"], o["ifMatch"]) for o in ops], [("DELETE", '"e1"')])

    def test_this_excludes_its_date(self):
        req = request(scope="this", occurrenceStart="2026-09-22T09:00:00-05:00")
        body = unfold(helper.plan_delete(SERIES, req, ZONES)[0]["body"])
        self.assertIn("EXDATE;TZID=America/Chicago:20260922T090000", body)

    def test_this_on_an_exception_drops_it_too(self):
        req = request(scope="this", occurrenceStart="2026-09-15T09:00:00-05:00")
        body = helper.plan_delete(SERIES, req, ZONES)[0]["body"]
        self.assertEqual(len(events_of(body)), 1)
        self.assertIn("EXDATE;TZID=America/Chicago:20260915T090000", unfold(body))

    def test_following_ends_the_series(self):
        req = request(scope="following", occurrenceStart="2026-09-15T09:00:00-05:00")
        body = unfold(helper.plan_delete(SERIES, req, ZONES)[0]["body"])
        self.assertIn("UNTIL=20260915T135959Z", body)
        self.assertEqual(len(events_of(body)), 1, "the later exception goes")

    def test_following_from_the_first_deletes_it_all(self):
        req = request(scope="following", occurrenceStart="2026-09-01T09:00:00-05:00")
        self.assertEqual([o["method"] for o in helper.plan_delete(SERIES, req, ZONES)], ["DELETE"])


class Conflict(unittest.TestCase):
    def test_412_is_a_conflict_said_as_one(self):
        class Fake:
            headers = {"Authorization": "Basic x", "User-Agent": "t"}
        original = helper.send
        helper.send = lambda *a, **k: (412, {}, b"")
        try:
            with self.assertRaises(helper.Failure) as caught:
                helper.run_writes(Fake(), [{"method": "PUT", "url": HREF, "body": "x",
                                            "ifMatch": '"old"'}])
        finally:
            helper.send = original
        self.assertEqual(caught.exception.code, "conflict")
        self.assertIn("changed on iCloud", caught.exception.message)


if __name__ == "__main__":
    unittest.main()
