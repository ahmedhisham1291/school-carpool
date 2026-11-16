# Security review (branch `security`, 16 Nov 2026)

Owner request: "check the security part of the application and admin
panel, check all threats and how we can protect ourselves. Fix all of
this." The coordinator said "go".

## Plan (done in this order, one commit per topic)

1. Money features default off on the server (owner decision: money OFF).
2. Admin: TOTP-only second factor (functions + rules); step-up sign-in
   (< 30 min) for photos, routes, device-check clearing, moderation,
   admin accounts, feature switches.
3. Sign-in: a stranger cannot spend a parent's hourly codes for their
   known phone.
4. APP_ENV fails closed (missing = prod in the cloud).
5. Scrubbers cut long text (regex backtracking).
6. Hosting headers (HSTS, COOP, Permissions-Policy, CSP; full admin CSP
   report-only first).
7. CI: checkout token not persisted, npm audit, Dependabot, CI rules test.
8. Setup script: Token Creator only on the functions' own account.
9. Rules abuse-case tests (no rules change).
10. Suspended/banned parents lose rules access at once.
11. Docs: docs/security/threat-model.md, runbook.md, owner-actions.md;
    SECURITY.md links them.

## Tests

- Run here: Cloud Functions unit tests (`tsc` + `node --test`): 894 pass,
  0 fail (the TypeScript type errors from the workspace's stub
  node_modules are the same 164 as on main). Python tool tests for the
  Hosting headers and CI rules: pass.
- Written, not run here (CI runs them): rules tests
  (`tests/rules/admin.test.ts`, `tests/rules/security_review.test.ts`),
  Dart tests (`test/admin/admin_logic_test.dart`,
  `test/observability/pii_scrubber_test.dart`), flutter analyze.

## Open questions / not done

- Dedicated least-privilege service account for Cloud Functions
  (owner-actions item 10): a deploy-affecting change, best done as its own
  prompt and tried on staging.
- The app's own pilot default still shows Settle up when
  `config/features` is missing (`lib/features/feature_switches`); changing
  it touches many widget tests that cannot run here. The server refuses
  either way; owner-actions item 21 writes the switch.
- Enforcing the full admin CSP after the owner checks the console
  (owner-actions item 20).
- Phone-number change does not sign the other phones out (low).
- A stranger's code request replaces the parent's pending code (low).
- `npx firebase-tools@15` is pinned to the major version only.
- Full line-by-line review of every callable: left to the external
  penetration test.
- Legal notification wording: docs/legal/breach-runbook.md (legal-egypt
  branch); runbook.md links to it.
