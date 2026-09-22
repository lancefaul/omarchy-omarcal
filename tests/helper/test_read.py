"""What the helper hands the panel when it reads an event: text, unescaped.

libical's generic `get_value_as_string` returns a TEXT property still in
its escaped file form — a line break as the two characters \\n, a comma as
\\, — and the viewer showed exactly that. Invented event; throwaway cache.
"""
import importlib.machinery
import importlib.util
import os
import sqlite3
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "..", "helper", "omarcal-helper")
_loader = importlib.machinery.SourceFileLoader("omarcal_helper_read", HELPER)
_spec = importlib.util.spec_from_loader("omarcal_helper_read", _loader)
helper = importlib.util.module_from_spec(_spec)
_loader.exec_module(helper)

ICS = "\r\n".join([
    "BEGIN:VCALENDAR", "VERSION:2.0", "BEGIN:VEVENT", "UID:read-1",
    "DTSTART:20260922T140000Z", "DTEND:20260922T150000Z", "SUMMARY:Lunch\\, then a walk",
    "DESCRIPTION:Bring:\\nshoes\\, water\; a hat", "LOCATION:12 Oak Lane\\nSpringfield",
    "END:VEVENT", "END:VCALENDAR", ""])


class Read(unittest.TestCase):
    def test_text_comes_back_unescaped(self):
        with tempfile.TemporaryDirectory() as folder:
            conn = sqlite3.connect(os.path.join(folder, "c.db"))
            conn.executescript(helper.SCHEMA)
            conn.execute("INSERT INTO calendars(url, name, enabled) VALUES('https://x/cal/', 'Cal', 1)")
            conn.execute("INSERT INTO objects(url, calendar, ics, uid) VALUES(?,?,?,?)",
                         ("https://x/cal/read-1.ics", "https://x/cal/", ICS, "read-1"))
            event = helper.event_detail(conn, "read-1", "")["event"]
            conn.close()
        self.assertEqual(event["description"], "Bring:\nshoes, water; a hat")
        self.assertEqual(event["title"], "Lunch, then a walk")
        self.assertEqual(event["location"], "12 Oak Lane\nSpringfield")


class Organizer(unittest.TestCase):
    def test_icloud_organizer_is_read_from_its_email(self):
        import gi
        gi.require_version("ICalGLib", "4.0")
        from gi.repository import ICalGLib as ICal
        comp = ICal.Component.new_from_string(
            "BEGIN:VEVENT\r\nUID:o\r\nORGANIZER;EMAIL=me@example.com;CN=Me:/aBc123/principal/\r\n"
            "END:VEVENT\r\n")
        self.assertEqual(helper.organizer_of(comp), "me@example.com")
        comp = ICal.Component.new_from_string(
            "BEGIN:VEVENT\r\nUID:o\r\nORGANIZER:mailto:me@example.com\r\nEND:VEVENT\r\n")
        self.assertEqual(helper.organizer_of(comp), "me@example.com")


if __name__ == "__main__":
    unittest.main()
