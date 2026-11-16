# Remove the remaining App Review risks (branch review-risks, 16 Nov 2026)

Owner instruction (16 Nov 2026): "All risks you're seeing, update the code
and plan to be no risk at all." The coordinator said "go". Base: main
495b1e8. Apple's rules were read again on developer.apple.com on 16 Nov
2026 (guideline numbers are in docs/apple-review/audit.md).

## Plan (one commit per item)

1. Notifications never block a run (4.5.4, 5.1.2(i)): a warning that can
   be skipped. `lib/features/trips/location_gate.dart`, tests.
2. No "Always" location: remove the optional screen, the request in
   `packages/run_recovery`, the purpose string; keep While-Using +
   background mode + recovery by marker.
3. Account deletion (5.1.1(v)): photos, face reference, 1:1 chat
   messages, home address and pin, devices and tokens deleted promptly;
   only minimised records kept. `functions/src/privacy/`, public pages.
4. Usage statistics off until the parent says yes (5.1.1(ii)).
5. A new, unverified account can look around; the ID check is asked only
   where another family is involved, with an explanation and "Later".
6. "This demo account can't do that" instead of the generic error.
7. `review-access -- on` seeds the demo data; a scheduled function keeps
   the demo runs fresh during the window.
8. UIScene life cycle for the iOS Runner; `configure_xcode.rb` safe with
   synchronized folders.
9. Branch `chat-review-safe`: Firestore chat with a word filter, and the
   public pages follow the active chat provider.
10. `tool/check_ios_app.py` stops the prod build for a listed SDK with no
    privacy manifest.
11. Audit, submission kit, open items.

## Progress

Items 1 to 4: commits a17d709, e7b20ac, f8411a0, 5f1af39 (see their
messages). A previous builder stopped while starting item 5; nothing of it
was left uncommitted, so item 5 was done from scratch.

### 5. Look around before the ID check (done)

What was blocked: every place but Profile, Notifications and the
verification screen redirected an unverified, pending or rejected account
to the verification screen (`sessionRedirect`), whose only way out was
"Open my profile". The server already refused everything that involves
another family with "not-verified" (carpools, chat, nearby, runs, schedule,
handover adults, emergency contact, ratings, family, phone change, Settle
up, wallet) and allowed the parent's own things (home, map settings,
driving schools, places, school search, notifications, privacy,
verification). So the line was moved in the app only, to match the server:

- `lib/router/session_redirect.dart`: `needsVerification(location)` (one
  list) and `laterTarget(from)`. Tabs and own pages open; closed places go
  to `/verify-account?from=<place>`.
- `VerifyAccountScreen`: "Why we check every parent" (child safety), "This
  part needs a verified account" when opened from a closed place, "Later"
  back to that tab (was "Open my profile").
- `VerifyPromptCard` on Home, Carpools and Chats (gallery too); the Chats
  tab explains instead of showing an error, and hides requests/settings.
- Server: no rule or function changed; `functions/test/verification_scope.test.ts`
  pins both sides of the line (3 tests).
- ARB: 10 new strings, Arabic and English. DECISIONS.md and spec section 3
  updated (supersedes "Profile only").
- Tests: Functions run here; Flutter tests written, not run here
  (`test/auth/auth_logic_test.dart`, `test/auth/signup_screens_test.dart`,
  `test/onboarding/verify_prompt_card_test.dart`, one-line and screenshot
  entries).

### 6. "This demo account can't do that" (done)

- `lib/features/auth/demo_refusal.dart`: `demoRefusalOf(error)` reads the
  server reasons `demo-account` and `demo-closed`
  (`functions/src/privacy/device_gate.ts`); `demoRefusalText` gives the
  sentence.
- All 13 parent-app failure types (auth, verification, address, trips,
  wallet, chat, notifications, maps, carpools, trust, other school,
  privacy, Settle up) carry an optional `demo` and their `message` asks
  `demoRefusalText` first, so every snackbar and inline error that used
  the generic text now says "This demo account can't do that. It works
  only with the demo school and carpool." / "This demo account has ended.
  You can delete it in Profile > Privacy." (Arabic and English).
- Not covered: full-screen error views that show no message (a list that
  fails to load). Inside the window a demo parent's lists load; after it,
  everything but Delete account is refused on purpose.
- Test: `test/auth/demo_refusal_test.dart` (written, not run here).
