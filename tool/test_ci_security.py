"""CI supply-chain rules (security review, 16 Nov 2026).

Run: python3 -m unittest discover -s tool -p 'test_*.py' (CI, backend job).
The repository is public: a workflow must not run untrusted pull request
code with secrets or a write token, every action is pinned to a commit,
and the checkout token is not left on disk where package scripts can read
it (except in the one job that pushes the lock files).
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOWS = sorted((ROOT / ".github" / "workflows").glob("*.y*ml"))


def jobs(text: str) -> dict:
    """Job name -> its text (top-level `jobs:` keys at two spaces)."""
    body = text.split("\njobs:\n", 1)[1]
    parts = re.split(r"\n  (?=[A-Za-z0-9_-]+:\n)", "\n" + body)
    out = {}
    for part in parts:
        part = part.strip("\n")
        if not part:
            continue
        name = part.split(":", 1)[0].strip()
        out[name] = part
    return out


class Workflows(unittest.TestCase):
    def test_there_are_workflows(self):
        self.assertTrue(WORKFLOWS)

    def test_no_untrusted_triggers(self):
        for wf in WORKFLOWS:
            text = wf.read_text(encoding="utf-8")
            with self.subTest(workflow=wf.name):
                self.assertNotIn("pull_request_target", text)
                self.assertNotIn("workflow_run", text)

    def test_actions_pinned_to_commits(self):
        for wf in WORKFLOWS:
            for line in wf.read_text(encoding="utf-8").splitlines():
                m = re.search(r"uses:\s*([^\s#]+)", line)
                if not m or m.group(1).startswith("./"):
                    continue
                with self.subTest(workflow=wf.name, uses=m.group(1)):
                    self.assertRegex(m.group(1), r"@[0-9a-f]{40}$")

    def test_default_token_is_read_only(self):
        for wf in WORKFLOWS:
            text = wf.read_text(encoding="utf-8")
            top = text.split("\njobs:\n", 1)[0]
            with self.subTest(workflow=wf.name):
                self.assertIn("contents: read", top)
                self.assertNotIn("contents: write", top)
                self.assertNotRegex(top, r"permissions:\s*write-all")

    def test_checkout_token_not_persisted_outside_the_lock_job(self):
        for wf in WORKFLOWS:
            for name, body in jobs(wf.read_text(encoding="utf-8")).items():
                if "actions/checkout@" not in body:
                    continue
                with self.subTest(workflow=wf.name, job=name):
                    if "contents: write" in body:
                        # Only the manual lock job pushes, and only to a work branch.
                        self.assertIn('[ "$BRANCH" = "main" ]', body)
                        continue
                    self.assertEqual(body.count("actions/checkout@"), body.count("persist-credentials: false"))

    def test_dependabot_covers_every_package_manager(self):
        text = (ROOT / ".github" / "dependabot.yml").read_text(encoding="utf-8")
        for eco, directory in (("npm", "/functions"), ("npm", "/tests/rules"), ("pub", "/"), ("github-actions", "/")):
            with self.subTest(ecosystem=eco, directory=directory):
                self.assertRegex(text, rf"package-ecosystem: {re.escape(eco)}\n\s+directory: {re.escape(directory)}\n")


if __name__ == "__main__":
    unittest.main()
