"""The helper's address lookups, offline. Every place here is invented.

The history is read from a throwaway cache; the two services' answers are
parsed from canned JSON in their documented shapes. Nothing here touches
the network — and one test checks that nothing can while the setting is
off.
"""
import importlib.machinery
import importlib.util
import os
import sqlite3
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "..", "helper", "omarcal-helper")
_loader = importlib.machinery.SourceFileLoader("omarcal_helper_places", HELPER)
_spec = importlib.util.spec_from_loader("omarcal_helper_places", _loader)
helper = importlib.util.module_from_spec(_spec)
_loader.exec_module(helper)


def event(uid, location, structured="", start=0):
    lines = ["BEGIN:VCALENDAR", "BEGIN:VEVENT", f"UID:{uid}", f"LOCATION:{location}"]
    if structured:
        lines.append(structured)
    lines += ["END:VEVENT", "END:VCALENDAR"]
    return "\r\n".join(lines), start


class History(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.conn = sqlite3.connect(os.path.join(self.dir.name, "c.db"))
        self.conn.executescript(helper.SCHEMA)
        rows = [
            event("a", "12 Oak Lane\\nSpringfield", 'X-APPLE-STRUCTURED-LOCATION;VALUE=URI;'
                  'X-ADDRESS="12 Oak Lane\\\\nSpringfield";X-TITLE="12 Oak Lane":geo:30.1,-92.0', 10),
            event("b", "12 oak lane\\nspringfield", start=20),
            event("c", "Library\\, Main St", start=5),
        ]
        for i, (ics, start) in enumerate(rows):
            self.conn.execute("INSERT INTO objects(url,calendar,ics,first_start) VALUES(?,?,?,?)",
                              (f"u{i}", "cal", ics, start))

    def tearDown(self):
        self.conn.close()
        self.dir.cleanup()

    def test_most_used_first_with_its_point(self):
        places = helper.places_history(self.conn)
        self.assertEqual(len(places), 2, "case and spacing do not make a new place")
        self.assertEqual(places[0]["count"], 2)
        self.assertEqual(places[0]["text"], "12 oak lane\nspringfield", "latest spelling wins")
        self.assertEqual(places[0]["place"]["lat"], 30.1)
        self.assertEqual(places[0]["place"]["title"], "12 Oak Lane")
        self.assertEqual(places[1]["text"], "Library, Main St")
        self.assertIsNone(places[1]["place"])


class Services(unittest.TestCase):
    def test_photon(self):
        data = {"features": [
            {"geometry": {"coordinates": [-92.0, 30.1]},
             "properties": {"name": "Oak Park", "street": "Oak Lane", "housenumber": "12",
                            "city": "Springfield", "state": "LA", "country": "United States"}},
            {"geometry": {"coordinates": []}, "properties": {"name": "No point"}},
        ]}
        self.assertEqual(helper.photon_places(data), [
            {"title": "Oak Park", "text": "Oak Park, 12 Oak Lane, Springfield, LA, United States",
             "lat": 30.1, "lon": -92.0}])

    def test_nominatim(self):
        data = [{"lat": "30.1", "lon": "-92.0", "name": "Oak Park",
                 "display_name": "Oak Park, Oak Lane, Springfield, United States"},
                {"lat": "x", "lon": "1", "display_name": "bad"}]
        self.assertEqual(helper.nominatim_places(data), [
            {"title": "Oak Park", "text": "Oak Park, Oak Lane, Springfield, United States",
             "lat": 30.1, "lon": -92.0}])


class Consent(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.conn = sqlite3.connect(os.path.join(self.dir.name, "c.db"))
        self.conn.executescript(helper.SCHEMA)

    def tearDown(self):
        self.conn.close()
        self.dir.cleanup()

    def test_no_request_while_off(self):
        with mock.patch.object(helper.http.client, "HTTPSConnection") as opened:
            with self.assertRaises(helper.Failure) as caught:
                helper.search_places(self.conn, "12 Oak Lane")
            opened.assert_not_called()
        self.assertEqual(caught.exception.code, "places-off")

    def test_short_queries_are_not_sent(self):
        self.conn.execute("INSERT INTO settings VALUES('placesProvider','\"photon\"')")
        with mock.patch.object(helper.http.client, "HTTPSConnection") as opened:
            self.assertEqual(helper.search_places(self.conn, "12")["places"], [])
            opened.assert_not_called()


if __name__ == "__main__":
    unittest.main()
