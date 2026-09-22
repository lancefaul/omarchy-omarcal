"""The update check's limits, against a pretend GitHub. Offline.

The shell used to ask GitHub itself, with no timeout and no cap on the
answer; a marketplace security review flagged it. The helper asks now, and
these are its bounds: a stall, a declared-too-large answer, an answer that
grows too large while being read, and the two answers that are fine.
"""
import importlib.machinery
import importlib.util
import os
import sys
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "..", "helper", "omarcal-helper")
_loader = importlib.machinery.SourceFileLoader("omarcal_helper_update", HELPER)
_spec = importlib.util.spec_from_loader("omarcal_helper_update", _loader)
helper = importlib.util.module_from_spec(_spec)
_loader.exec_module(helper)


class Response:
    def __init__(self, status=200, body=b"", length=None, stall=False):
        self.status, self.body, self.length, self.stall = status, body, length, stall

    def getheader(self, name):
        return str(self.length) if name == "Content-Length" and self.length is not None else None

    def read(self, n):
        if self.stall:
            raise TimeoutError("timed out")
        chunk, self.body = self.body[:n], self.body[n:]
        return chunk


class Connection:
    answer = None
    seen = {}

    def __init__(self, host, timeout=None, context=None):
        Connection.seen["timeout"] = timeout

    def request(self, method, path, headers=None):
        pass

    def getresponse(self):
        return Connection.answer

    def close(self):
        pass


class UpdateCheck(unittest.TestCase):
    def setUp(self):
        self.saved = helper.http.client.HTTPSConnection
        helper.http.client.HTTPSConnection = Connection

    def tearDown(self):
        helper.http.client.HTTPSConnection = self.saved

    def check(self, answer):
        Connection.answer = answer
        return helper.update_check()

    def test_every_read_has_a_timeout(self):
        self.check(Response(body=b"{}"))
        self.assertEqual(Connection.seen["timeout"], helper.UPDATE_TIMEOUT)

    def test_a_stall_is_a_failure_not_a_hang(self):
        r = self.check(Response(stall=True))
        self.assertFalse(r["ok"])
        self.assertIn("could not be reached", r["error"])

    def test_a_declared_oversize_answer_is_refused_unread(self):
        r = self.check(Response(body=b"x" * 10, length=helper.UPDATE_MAX_BYTES + 1))
        self.assertEqual(r, {"ok": False, "code": "update", "error": "GitHub's answer was too large"})

    def test_an_answer_that_grows_too_large_is_refused(self):
        big = Response(body=b"x" * (helper.UPDATE_MAX_BYTES * 3))
        r = self.check(big)
        self.assertEqual(r["error"], "GitHub's answer was too large")
        # Read no further than one byte past the cap.
        self.assertEqual(len(big.body), helper.UPDATE_MAX_BYTES * 3 - helper.UPDATE_MAX_BYTES - 1)

    def test_a_release_and_no_release(self):
        self.assertEqual(self.check(Response(body=b'{"tag_name": "v1.0.2"}')),
                         {"ok": True, "status": 200, "body": '{"tag_name": "v1.0.2"}'})
        self.assertEqual(self.check(Response(status=404)), {"ok": True, "status": 404})
        self.assertFalse(self.check(Response(status=500))["ok"])


if __name__ == "__main__":
    unittest.main()
