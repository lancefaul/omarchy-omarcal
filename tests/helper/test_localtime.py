"""Reading an event's time back: each date takes the offset of its own day.

The helper once used today's offset for every event, so anything across a
DST change came out an hour wrong. Offline; nothing here reads the cache.
"""
import importlib.machinery
import importlib.util
import os
import sys
import unittest
from zoneinfo import ZoneInfo

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "..", "helper", "omarcal-helper")
_loader = importlib.machinery.SourceFileLoader("omarcal_helper_localtime", HELPER)
_spec = importlib.util.spec_from_loader("omarcal_helper_localtime", _loader)
helper = importlib.util.module_from_spec(_spec)
_loader.exec_module(helper)


class LocalTime(unittest.TestCase):
    def test_each_date_gets_its_own_offset(self):
        saved = helper.LOCAL_TZ
        helper.LOCAL_TZ = ZoneInfo("America/Chicago")
        try:
            # 2026-09-30 23:15Z and 2026-11-05 00:15Z: both 6:15 PM in Chicago,
            # on either side of the change back to standard time on Nov 1.
            self.assertEqual(helper.local_iso(1790810100), "2026-09-30T18:15:00-05:00")
            self.assertEqual(helper.local_iso(1793837700), "2026-11-04T18:15:00-06:00")
        finally:
            helper.LOCAL_TZ = saved

    def test_the_system_zone_has_rules(self):
        # Whatever this machine is set to, it is a zone, not a fixed offset,
        # wherever /etc/localtime names one.
        if "/zoneinfo/" in os.path.realpath("/etc/localtime"):
            self.assertIsInstance(helper.system_zone(), ZoneInfo)


if __name__ == "__main__":
    unittest.main()
