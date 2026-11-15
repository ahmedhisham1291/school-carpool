"""Tests for tool/algolia_keys.py (F4): which Algolia keys cloud_setup.sh accepts.

    python3 -m unittest discover -s tool -p 'test_*.py' -v
"""

import io
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import algolia_keys  # noqa: E402

WRITE_ACL = ["search", "browse", "addObject", "deleteObject", "listIndexes", "deleteIndex", "settings", "editSettings"]


class VerdictTest(unittest.TestCase):
    def test_write_key(self):
        self.assertEqual(algolia_keys.verdict("write", 200, {"acl": WRITE_ACL})[0], 0)
        code, message = algolia_keys.verdict("write", 200, {"acl": ["search"]})
        self.assertEqual(code, 1)
        self.assertIn("addObject", message)
        # Valid key without the search right: cannot be checked here.
        self.assertEqual(algolia_keys.verdict("write", 403, {"message": "Method not allowed with this API key"})[0], 2)

    def test_search_key_must_not_write(self):
        code, message = algolia_keys.verdict("search", 200, {"acl": ["search"], "maxQueriesPerIPPerHour": 100})
        self.assertEqual((code, message), (0, "Search-only API key accepted"))
        self.assertIn("no hourly limit", algolia_keys.verdict("search", 200, {"acl": ["search"]})[1])
        self.assertEqual(algolia_keys.verdict("search", 200, {"acl": WRITE_ACL})[0], 1)
        self.assertEqual(algolia_keys.verdict("search", 200, {"acl": ["browse"]})[0], 1)
        # Read-only rights beyond search are refused too: the app's keys inherit them.
        for extra in ("logs", "analytics", "browse", "usage", "listIndexes"):
            code, message = algolia_keys.verdict("search", 200, {"acl": ["search", extra]})
            self.assertEqual(code, 1, extra)
            self.assertIn(extra, message)
        self.assertEqual(algolia_keys.verdict("search", 403, {"message": "Method not allowed with this API key"})[0], 2)

    def test_unknown_key(self):
        for kind in ("write", "search"):
            code, message = algolia_keys.verdict(kind, 403, {"message": "Invalid Application-ID or API key"})
            self.assertEqual(code, 1)
            self.assertIn("does not know this key", message)

    def test_the_key_is_never_printed(self):
        secret = "abcdef0123456789abcdef0123456789"
        out = io.StringIO()
        with mock.patch.object(algolia_keys, "ask", return_value=(200, {"acl": ["search"], "value": secret})), \
                mock.patch.object(sys, "stdin", io.StringIO(secret + "\n")), mock.patch.object(sys, "stdout", out):
            code = algolia_keys.main(["algolia_keys.py", "search", "app1234567"])
        self.assertEqual(code, 0)
        self.assertNotIn(secret, out.getvalue())

    def test_pasted_junk_is_refused_without_a_call(self):
        with mock.patch.object(algolia_keys, "ask") as ask, mock.patch.object(sys, "stdin", io.StringIO("key with spaces")), \
                mock.patch.object(sys, "stdout", io.StringIO()):
            self.assertEqual(algolia_keys.main(["algolia_keys.py", "write", "APP1234567"]), 1)
        ask.assert_not_called()


class StoreDecisionTest(unittest.TestCase):
    """What cloud_setup.sh step 6 says when it does or does not store the keys."""

    def decide(self, w_empty=False, s_empty=False, same=False, w_rc=0, s_rc=0, w_msg="W", s_msg="S"):
        return algolia_keys.store_decision(w_empty, s_empty, same, w_rc, s_rc, w_msg, s_msg)

    def test_good_pair_is_stored_without_lines(self):
        self.assertEqual(self.decide(), (True, []))

    def test_each_refusal_gives_its_own_reason(self):
        store, lines = self.decide(w_empty=True)
        self.assertFalse(store)
        self.assertEqual(lines, ["the Write API Key was empty (nothing pasted)"])
        store, lines = self.decide(s_empty=True)
        self.assertEqual((store, lines), (False, ["the Search-only API Key was empty (nothing pasted)"]))
        store, lines = self.decide(same=True)
        self.assertFalse(store)
        self.assertEqual(len(lines), 1)
        self.assertIn("same key was pasted twice", lines[0])
        store, lines = self.decide(w_rc=1, w_msg="this key cannot addObject")
        self.assertEqual((store, lines), (False, ["Write key refused: this key cannot addObject"]))
        store, lines = self.decide(s_rc=1, s_msg="this key can do more than search (logs)")
        self.assertEqual((store, lines), (False, ["Search key refused: this key can do more than search (logs)"]))
        # Different keys never get the "same key" reason (the old message said so every time).
        for kwargs in ({"w_rc": 1}, {"s_rc": 1}, {"w_empty": True}):
            self.assertFalse(any("same key" in line for line in self.decide(**kwargs)[1]), kwargs)

    def test_could_not_check_does_not_block(self):
        store, lines = self.decide(w_rc=2, w_msg="Algolia did not show this key's rights")
        self.assertTrue(store)
        self.assertIn("first index sync", lines[0])
        store, lines = self.decide(s_rc=2, s_msg="could not reach Algolia (URLError)")
        self.assertTrue(store)
        self.assertIn("Search key stored unchecked (could not reach Algolia (URLError))", lines[0])
        self.assertIn("only the search right", lines[0])
        # A refusal still wins over an unchecked key.
        self.assertFalse(self.decide(w_rc=1, s_rc=2)[0])

    def test_decide_command_line(self):
        out = io.StringIO()
        with mock.patch.object(sys, "stdout", out):
            code = algolia_keys.main(["algolia_keys.py", "decide", "0", "0", "1", "0", "1", "ok", "this key cannot search"])
        self.assertEqual(code, 1)
        self.assertEqual(
            out.getvalue().splitlines(),
            [
                "the same key was pasted twice: the Write API Key and the Search-only API Key are different keys",
                "Search key refused: this key cannot search",
            ],
        )
        with mock.patch.object(sys, "stdout", io.StringIO()):
            self.assertEqual(algolia_keys.main(["algolia_keys.py", "decide", "0", "0", "0", "0", "2", "ok", "x"]), 0)
        with mock.patch.object(sys, "stderr", io.StringIO()):
            self.assertEqual(algolia_keys.main(["algolia_keys.py", "decide", "0"]), 2)


if __name__ == "__main__":
    unittest.main()
