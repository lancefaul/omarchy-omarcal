"""The helper's contact parsing, offline. Run by test/all.

Only a name and an address may leave a card; these check that nothing else
does, and that Apple's grouped and folded lines are read the way it writes
them. Every name and address here is invented.
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
_loader = importlib.machinery.SourceFileLoader("omarcal_helper", HELPER)
_spec = importlib.util.spec_from_loader("omarcal_helper", _loader)
helper = importlib.util.module_from_spec(_spec)
_loader.exec_module(helper)

CARDS = (
    "BEGIN:VCARD\r\nVERSION:3.0\r\nN:Rivera;Sam;;;\r\nFN:Sam Rivera\r\n"
    "item1.EMAIL;type=INTERNET;type=pref:sam@example.com\r\n"
    "item1.X-ABLabel:_$!<Work>!$_\r\nEMAIL;type=HOME:Sam.Home@example.org\r\n"
    "TEL;type=CELL:+1 555 0100\r\nADR;type=HOME:;;1 Main St;Town;;;\r\n"
    "NOTE:private\r\nEND:VCARD\r\n"
    "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:O\\, Brien\; Pat\r\n"
    "EMAIL:mailto:pat@exam\r\n ple.com\r\nEMAIL:PAT@EXAMPLE.COM\r\nEND:VCARD\r\n"
    "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:No Address\r\nTEL:+1 555 0101\r\nEND:VCARD\r\n"
)


class Parse(unittest.TestCase):
    def test_names_and_addresses_only(self):
        self.assertEqual(helper.vcard_people(CARDS), [
            ("Sam Rivera", "sam@example.com"),
            ("Sam Rivera", "Sam.Home@example.org"),
            # Unescaped, unfolded, mailto: dropped, one address kept once.
            ("O, Brien; Pat", "pat@example.com"),
        ])

    def test_nothing_else_survives(self):
        flat = repr(helper.vcard_people(CARDS))
        for leaked in ("555", "Main St", "private", "Work"):
            self.assertNotIn(leaked, flat)


class Consent(unittest.TestCase):
    """Nothing is read without the setting, and switching it off deletes."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.conn = sqlite3.connect(os.path.join(self.dir.name, "c.db"))
        self.conn.executescript(helper.SCHEMA)

    def tearDown(self):
        self.conn.close()
        self.dir.cleanup()

    def test_sync_refuses_while_off(self):
        with self.assertRaises(helper.Failure) as caught:
            helper.sync_contacts(self.conn)
        self.assertEqual(caught.exception.code, "contacts-off")

    def test_list_is_empty_while_off(self):
        self.conn.execute("INSERT INTO contacts VALUES('a','Sam','sam@example.com')")
        self.assertEqual(helper.contact_list(self.conn)["contacts"], [])

    def test_off_deletes(self):
        self.conn.execute("INSERT INTO settings VALUES('contactsEnabled','true')")
        self.conn.execute("INSERT INTO contacts VALUES('a','Sam','sam@example.com')")
        self.assertEqual(helper.contact_list(self.conn)["count"], 1)
        self.assertEqual(helper.forget_contacts(self.conn), 1)
        self.assertEqual(helper.contact_list(self.conn)["count"], 0)


class RemovedAccount(unittest.TestCase):
    def test_removing_an_account_removes_its_contacts(self):
        import argparse
        folder = tempfile.TemporaryDirectory()
        conn = sqlite3.connect(os.path.join(folder.name, "c.db"))
        conn.executescript(helper.SCHEMA)
        conn.execute("INSERT INTO accounts(user, server) VALUES('me@a', 'https://caldav.icloud.com/')")
        conn.execute("INSERT INTO contacts VALUES('me@a', 'Sam', 'sam@example.com')")
        conn.execute("INSERT INTO contacts VALUES('me@b', 'Jo', 'jo@example.com')")
        conn.execute("INSERT INTO contact_state(account, error) VALUES('me@a', 'old error')")
        saved_forget, saved_reclaim = helper.forget_password, helper.reclaim
        helper.forget_password = lambda account: None   # never the real keyring
        helper.reclaim = lambda conn: None
        try:
            helper.dispatch(conn, argparse.Namespace(command="remove-account", user="me@a"))
        finally:
            helper.forget_password, helper.reclaim = saved_forget, saved_reclaim
        self.assertEqual(conn.execute("SELECT account FROM contacts").fetchall(), [("me@b",)])
        self.assertEqual(conn.execute("SELECT count(*) FROM contact_state").fetchone()[0], 0)
        conn.close()
        folder.cleanup()


if __name__ == "__main__":
    unittest.main()
