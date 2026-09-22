"""Saving while offline, against a pretend iCloud. Every event is invented.

The pretend server keeps what it is sent, can be switched off (every request
raises, as a dropped connection does), and can refuse a write the way iCloud
does when the event changed elsewhere (412).
"""
import importlib.machinery
import importlib.util
import os
import re
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timezone

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "..", "helper", "omarcal-helper")
_loader = importlib.machinery.SourceFileLoader("omarcal_helper_offline", HELPER)
_spec = importlib.util.spec_from_loader("omarcal_helper_offline", _loader)
helper = importlib.util.module_from_spec(_spec)
_loader.exec_module(helper)

CAL = "https://example.invalid/home/cal/"


class Server:
    def __init__(self):
        self.online = True
        self.refuse = False
        self.objects = {}
        self.version = 0

    def send(self, session, method, url, body, headers):
        if not self.online:
            raise OSError("network is unreachable")
        if method == "GET":
            if url not in self.objects:
                return 404, {}, b""
            etag, text = self.objects[url]
            return 200, {"etag": etag}, text.encode()
        if self.refuse and method in ("PUT", "DELETE") and headers.get("If-Match"):
            return 412, {}, b""
        if method == "PUT":
            match = headers.get("If-Match")
            if match and url in self.objects and self.objects[url][0] != match:
                return 412, {}, b""
            self.version += 1
            self.objects[url] = (f'"v{self.version}"', body.decode())
            return 201, {"etag": f'"v{self.version}"'}, b""
        if method == "DELETE":
            self.objects.pop(url, None)
            return 204, {}, b""
        return 200, {}, b""


def event(**over):
    base = {"title": "Lunch", "calendarUrl": CAL, "allDay": False,
            "start": "2026-10-01T12:00:00", "end": "2026-10-01T13:00:00", "rrule": "",
            "location": "", "place": None, "url": "", "conference": "", "travel": "",
            "description": ""}
    base.update(over)
    return base


def create_request(**over):
    req = {"href": "", "etag": "", "calendarUrl": "", "targetCalendarUrl": CAL, "scope": "",
           "occurrenceStart": "", "rid": "",
           "changes": ["title", "start", "end", "alarms", "location"], "event": event(),
           "alarmPlan": {"set": {}, "remove": [], "add": ["-PT15M", "-P1D"]},
           "invitees": [], "organizer": "me@example.com", "addFiles": [],
           "removeManaged": [], "removeNames": []}
    req.update(over)
    return req


class Offline(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.conn = helper.sqlite3.connect(os.path.join(self.dir.name, "c.db"))
        self.conn.executescript(helper.SCHEMA)
        cols = {r[1] for r in self.conn.execute("PRAGMA table_info(objects)")}
        if "pending" not in cols:
            self.conn.execute("ALTER TABLE objects ADD COLUMN pending INTEGER NOT NULL DEFAULT 0")
        self.conn.execute("INSERT INTO accounts(user, server) VALUES('me@example.com', ?)",
                          (helper.ICLOUD,))
        self.conn.execute("INSERT INTO calendars(url, name, enabled, account) VALUES(?, 'Cal', 1, "
                          "'me@example.com')", (CAL,))
        self.server = Server()
        self.saved = (helper.send, helper.load_password)
        helper.send = self.server.send
        helper.load_password = lambda account: "not-a-password"

    def tearDown(self):
        helper.send, helper.load_password = self.saved
        self.conn.close()
        self.dir.cleanup()

    def rows(self):
        return self.conn.execute("SELECT url, pending, ics FROM objects").fetchall()

    def detail(self, url):
        uid = self.conn.execute("SELECT uid FROM objects WHERE url=?", (url,)).fetchone()[0]
        return helper.event_detail(self.conn, uid, "")["event"]

    def test_a_new_event_offline_is_shown_then_sent(self):
        self.server.online = False
        answer = helper.write_event(self.conn, create_request(), False)
        self.assertTrue(answer["queued"])
        (url, pending, _), = self.rows()
        self.assertEqual(pending, 1, "shown at once, marked pending")
        shown = helper.events(self.conn, datetime(2026, 10, 1, tzinfo=timezone.utc),
                              datetime(2026, 10, 2, tzinfo=timezone.utc), [])["events"]
        self.assertTrue(shown and shown[0].get("pending"))
        self.server.online = True
        self.assertEqual(helper.flush_pending(self.conn)["sent"], 1)
        (url2, pending, _), = self.rows()
        self.assertEqual((url2, pending), (url, 0), "the same object, no longer pending")
        self.assertIn(url, self.server.objects)
        self.assertEqual(helper.queued_count(self.conn), 0)

    def test_queued_edits_replay_once_each_in_order(self):
        helper.write_event(self.conn, create_request(), False)
        url = self.rows()[0][0]
        self.server.online = False
        d = self.detail(url)
        edit = create_request(href=url, etag=d["etag"], calendarUrl=CAL, changes=["alarms"],
                              alarmPlan={"set": {}, "remove": [0], "add": []})
        helper.write_event(self.conn, edit, False)
        d = self.detail(url)
        rename = create_request(href=url, etag=d["etag"], calendarUrl=CAL, changes=["title"],
                                event=event(title="Long lunch"), alarmPlan={"set": {}, "remove": [], "add": []})
        helper.write_event(self.conn, rename, False)
        self.assertEqual(helper.queued_count(self.conn), 2)
        self.server.online = True
        self.assertEqual(helper.flush_pending(self.conn)["sent"], 2)
        text = re.sub(r"\r?\n[ \t]", "", self.server.objects[url][1])
        # Replayed on the pending version instead, the first alarm would go
        # and then the second too: "remove the first" applied twice.
        self.assertEqual(re.findall(r"TRIGGER:(\S+)", text), ["-P1D"], "the first alarm removed once")
        self.assertIn("SUMMARY:Long lunch", text)

    def test_while_anything_is_queued_new_saves_queue_behind_it(self):
        self.server.online = False
        helper.write_event(self.conn, create_request(), False)
        self.server.online = True
        # The first flushes before the second is sent: order kept, both sent.
        helper.write_event(self.conn, create_request(event=event(title="Dinner")), False)
        self.assertEqual(helper.queued_count(self.conn), 0)
        self.assertEqual(len(self.server.objects), 2)

    def test_a_refused_change_comes_off_the_display_with_what_followed(self):
        helper.write_event(self.conn, create_request(), False)
        url = self.rows()[0][0]
        original = self.rows()[0][2]
        self.server.online = False
        d = self.detail(url)
        helper.write_event(self.conn, create_request(
            href=url, etag=d["etag"], calendarUrl=CAL, changes=["title"],
            event=event(title="Mine"), alarmPlan={"set": {}, "remove": [], "add": []}), False)
        helper.write_event(self.conn, create_request(event=event(title="Later")), False)
        self.assertEqual(len(self.rows()), 2)
        self.server.online, self.server.refuse = True, True
        self.assertTrue(helper.flush_pending(self.conn).get("conflict"))
        self.assertEqual([(u, p) for u, p, _ in self.rows()], [(url, 0)], "back to iCloud's version")
        self.assertEqual(self.rows()[0][2], original)
        problems = helper.pending_status(self.conn)["pendingProblems"]
        self.assertEqual([p["title"] for p in problems], ["Mine", "Later"])
        self.assertIn("changed on iCloud", problems[0]["error"])

    def test_still_offline_stays_queued(self):
        self.server.online = False
        helper.write_event(self.conn, create_request(), False)
        self.assertEqual(helper.flush_pending(self.conn), {"sent": 0, "offline": True})
        self.assertEqual(helper.queued_count(self.conn), 1)
        self.assertEqual(self.rows()[0][1], 1)


if __name__ == "__main__":
    unittest.main()
