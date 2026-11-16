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
