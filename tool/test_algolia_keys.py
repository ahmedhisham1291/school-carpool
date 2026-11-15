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


if __name__ == "__main__":
    unittest.main()
