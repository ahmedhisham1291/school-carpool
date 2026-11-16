# Legal review Egypt (branch legal-egypt), 16 Nov 2026

Task: "act as a lawyer, analyze the Egyptian law and be on the safe side"
(owner via the coordinator), plus the owner's confirmations of 16 Nov 2026
(service is free and non-commercial; no money in the app).

## Plan (done)

1. Research current law (PDPL 151/2020 + Decree 816/2025, Law 87/2018,
   Child Law, Cybercrime 175/2018, Telecom 10/2003, Consumer 181/2018, CBE
   194/2020, Insurance 155/2024, civil liability) -> docs/legal/egypt-legal-review.md.
2. No money in the app (own commit): `contributions` switch; every money
   switch off by default; server refusals; no money UI; volunteer box.
3. Consents and requests (own commit): `transferAbroad`, guardian
   declaration, versions 2026-11-16, 6-working-day deadline + admin queue,
   sign-in history 180 days.
4. Merge origin/main (review-risks).
5. Public pages + links_site DPO option + docs (memo, owner actions,
   record of processing, breach runbook, request procedure).

## Tests

- Functions: 890 pass (run here, Node 22, workspace type stubs).
- Python tool tests (`tool/test_links_site.py`, `tool/test_patch_native_review.py`): pass (run here).
- Flutter widget/golden tests: written, not run here (D41).
- Rules: no rules change.

## Open questions

See docs/legal/egypt-legal-review.md section 12 and open items B5, B14, B15, D41, D42.
