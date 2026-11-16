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
  search  must have the "search" right and no other (no writes, no logs,
          analytics or browse): the app's one-hour keys are made from it and
          inherit its rights.

Exit codes: 0 fits, 1 does not fit (reason printed), 2 could not check
(network, or a write key without the "search" right: then the first index
sync in step 12 is the check).

    python3 tool/algolia_keys.py decide W_EMPTY S_EMPTY SAME W_RC S_RC W_MSG S_MSG

says whether cloud_setup.sh stores the pair, with the real reason(s) when
it does not (empty key, same key twice, write key refused, search key
refused) and a warning for a key that could not be checked (stored).
It gets only flags and the verdict messages, never a key.
"""

from __future__ import annotations

import json
import sys
import urllib.error
import urllib.parse
import urllib.request

WRITE_RIGHTS = ("addObject", "deleteObject", "editSettings")
# The search key may hold only these rights: the app's one-hour keys inherit
# every right of it, and rights such as "logs" (other people's queries and
# IP addresses), "analytics", "usage" or "browse" do not belong on a phone.
ALLOWED_FOR_SEARCH = ("search",)


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
        extra = [r for r in acl if r not in ALLOWED_FOR_SEARCH]
        if extra:
            return 1, "this key can do more than search (" + ", ".join(extra) + "): paste the Search-only API Key, or make a key with only the search right (docs/algolia-setup.md, section 4)"
        limit = body.get("maxQueriesPerIPPerHour") or 0
        hint = "" if limit else " (no hourly limit on it; see docs/algolia-setup.md, optional step)"
        return 0, "Search-only API key accepted" + hint
    if status in (401, 403, 404) and "invalid" in message.lower():
        return 1, "Algolia does not know this key for this Application ID (check both, and copy the whole key)"
    if kind == "write" and status == 403:
        return 2, "Algolia did not show this key's rights; it will be checked by the first index sync"
    return 2, f"Algolia answered {status}" + (f": {message[:120]}" if message else "")


def store_decision(
    write_empty: bool, search_empty: bool, same_key: bool, write_rc: int, search_rc: int, write_msg: str, search_msg: str
) -> tuple[bool, list[str]]:
    """Whether cloud_setup.sh stores the two keys, and the reason lines it
    prints (a to-do when not stored, warnings when stored unchecked). Takes
    only facts about the keys and the verdict messages, never a key.
    Exit code 2 ("could not check") does not block either key: the first
    index sync (write key) and the app's first search (search key) are the
    check then."""
    reasons: list[str] = []
    if write_empty:
        reasons.append("the Write API Key was empty (nothing pasted)")
    if search_empty:
        reasons.append("the Search-only API Key was empty (nothing pasted)")
    if not write_empty and not search_empty and same_key:
        reasons.append("the same key was pasted twice: the Write API Key and the Search-only API Key are different keys")
    if not write_empty and write_rc == 1:
        reasons.append(f"Write key refused: {write_msg}")
    if not search_empty and search_rc == 1:
        reasons.append(f"Search key refused: {search_msg}")
    if reasons:
        return False, reasons
    warnings: list[str] = []
    if write_rc == 2:
        warnings.append(f"Write key stored unchecked ({write_msg}); the first index sync in step 12 is the check")
    if search_rc == 2:
        warnings.append(
            f"Search key stored unchecked ({search_msg}); the app's first school search is the check, and make sure "
            "in the Algolia dashboard that it has only the search right (docs/algolia-setup.md, section 4)"
        )
    return True, warnings


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


def decide_main(argv: list[str]) -> int:
    """decide W_EMPTY S_EMPTY SAME W_RC S_RC W_MSG S_MSG (0/1 flags): prints
    one reason per line; exit 0 store, 1 do not store."""
    try:
        w_empty, s_empty, same = (a == "1" for a in argv[2:5])
        w_rc, s_rc = int(argv[5]), int(argv[6])
        w_msg, s_msg = argv[7], argv[8]
    except (IndexError, ValueError):
        print("usage: algolia_keys.py decide W_EMPTY S_EMPTY SAME W_RC S_RC W_MSG S_MSG", file=sys.stderr)
        return 2
    store, lines = store_decision(w_empty, s_empty, same, w_rc, s_rc, w_msg, s_msg)
    for line in lines:
        print(line)
    return 0 if store else 1


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1] == "decide":
        return decide_main(argv)
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
