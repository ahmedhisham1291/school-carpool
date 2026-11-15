#!/usr/bin/env python3
"""Checks an Algolia key before tool/cloud_setup.sh stores it (F4).

    printf '%s' "$KEY" | python3 tool/algolia_keys.py write  <APP_ID>
    printf '%s' "$KEY" | python3 tool/algolia_keys.py search <APP_ID>

The key is read from standard input, so it never appears in a command line
or a log, and is never printed. Asks Algolia for the key's own rights
(GET /1/keys/{key}: any key may read its own rights if it has the "search"
right) and says on one line whether it fits:

  write   must be able to add and delete records and change settings
          (the dashboard's "Write API Key"); used by Cloud Functions and the
          index sync.
  search  must be able to search and must NOT be able to write: the app's
          one-hour keys are made from it and inherit its rights.

Exit codes: 0 fits, 1 does not fit (reason printed), 2 could not check
(network, or a write key without the "search" right: then the first index
sync in step 12 is the check).
"""

from __future__ import annotations

import json
import sys
import urllib.error
import urllib.parse
import urllib.request

WRITE_RIGHTS = ("addObject", "deleteObject", "editSettings")
FORBIDDEN_FOR_SEARCH = ("addObject", "deleteObject", "deleteIndex", "editSettings")


def verdict(kind: str, status: int, body: dict) -> tuple[int, str]:
    """(exit code, message) from Algolia's answer to GET /1/keys/{key}."""
    message = str(body.get("message") or "")
    if status == 200:
        acl = [str(a) for a in body.get("acl") or []]
        if kind == "write":
            missing = [r for r in WRITE_RIGHTS if r not in acl]
            if missing:
                return 1, f"this key cannot {', '.join(missing)}: paste the Write API Key, not the Search-only one"
            return 0, "Write API key accepted"
        if "search" not in acl:
            return 1, "this key cannot search: paste the Search-only API Key"
        writes = [r for r in FORBIDDEN_FOR_SEARCH if r in acl]
        if writes:
            return 1, "this key can also change data (" + ", ".join(writes) + "): paste the Search-only API Key"
        limit = body.get("maxQueriesPerIPPerHour") or 0
        hint = "" if limit else " (no hourly limit on it; see docs/algolia-setup.md, optional step)"
        return 0, "Search-only API key accepted" + hint
    if status in (401, 403, 404) and "invalid" in message.lower():
        return 1, "Algolia does not know this key for this Application ID (check both, and copy the whole key)"
    if kind == "write" and status == 403:
        return 2, "Algolia did not show this key's rights; it will be checked by the first index sync"
    return 2, f"Algolia answered {status}" + (f": {message[:120]}" if message else "")


def ask(app_id: str, key: str) -> tuple[int, dict]:
    url = f"https://{app_id}.algolia.net/1/keys/{urllib.parse.quote(key, safe='')}"
    request = urllib.request.Request(
        url, headers={"X-Algolia-Application-Id": app_id, "X-Algolia-API-Key": key, "Accept": "application/json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:  # noqa: S310 (fixed https host)
            return response.status, json.loads(response.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as error:
        try:
            body = json.loads(error.read().decode("utf-8") or "{}")
        except ValueError:
            body = {}
        return error.code, body if isinstance(body, dict) else {}


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] not in ("write", "search"):
        print("usage: printf '%s' KEY | algolia_keys.py write|search APP_ID", file=sys.stderr)
        return 2
    kind, app_id = argv[1], argv[2].strip().upper()
    key = sys.stdin.read().strip()
    if not app_id.isalnum() or not key.isalnum():
        print("the Application ID and the key are letters and digits only (check what was pasted)")
        return 1
    try:
        status, body = ask(app_id, key)
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as error:
        print(f"could not reach Algolia ({type(error).__name__}); check the Application ID")
        return 2
    code, message = verdict(kind, status, body)
    print(message)
    return code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
