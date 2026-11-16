# Legal checklist for the owner (Egypt)

Plain steps, in order. Why each step matters is in
docs/legal/egypt-legal-review.md. **This is not legal advice: take steps 1 to
5 to a licensed Egyptian lawyer.** Checked 16 Nov 2026.

## Before any real parent uses the app (pilot or App Store)

1. **Choose and register the operating entity.** Ask the lawyer (question
   7.1) whether a small company (for example a single-member LLC) or a
   foundation/NGO should run the app. It will be: the data controller, the
   PDPC licence holder, the employer of the DPO, the owner of the Apple and
   Google developer accounts (Apple's Organization account needs a legal
   entity and a D-U-N-S number), and the party in the processor contracts.
   Get the commercial register / tax card if the lawyer says so.
2. **Book the lawyer** and send them `docs/legal/egypt-legal-review.md`
   section 12 (the numbered questions). Ask for **written** answers and keep
   them with the company records. Ask especially for a written opinion on
   Law 87/2018 (question 2.1).
3. **Appoint a Data Protection Officer** (DPO). The law asks the legal
   representative to appoint a competent employee and register them with
   the Personal Data Protection Centre (PDPC); the PDPC sets
   qualifications and an assessment. Ask the lawyer whether an external DPO
   is allowed.
4. **Apply for the PDPC licences on the PDPC portal.**
   - Website: pdpc.gov.eg (portal opened early Oct 2026); sign in with your
     **Digital Egypt** account (digital.gov.eg).
   - Apply for: (a) the controller licence (processing personal data);
     (b) the sensitive-data licence/permit (children's data and
     biometric face matching); (c) the cross-border transfer
     licence/permit (Google Cloud Belgium and the processors in
     `docs/legal/records-of-processing.md`).
   - Attach: the record of processing, the security measures (KMS
     encryption, private bucket, admin access log, App Check), the
     retention table, the DPO.
   - The PDPC decides within 90 working days of a complete file; no answer
     means refused. Keep the application numbers.
   - **Prod stays closed to new real parents until all three licences are
     granted (R5, owner decision 16 Nov 2026).** The app enforces it:
     `config/launch.pdpcLicensed` is off by default; a new number in prod
     sees "Opening soon". When the three licence decisions arrive, a super
     admin opens Admin panel > Settings > Launch, switches "PDPC licences
     granted" on and types the three licence numbers (audited). Staging
     and TestFlight with testers and fake children work meanwhile.
5. **Insurance.** Every driving parent must have a valid driving licence,
   a private car licence and the car's compulsory insurance (it covers
   death and injury up to EGP 100,000 under Law 155/2024). Advise parents
   (in the welcome message or the pilot briefing) to consider optional
   comprehensive cover and a passenger personal-accident policy. The app
   never sells insurance and never takes a referral fee. Ask the lawyer
   question 2.3.
6. **The pilot school.** Tell the school about the pilot and ask whether it
   has rules on parents carrying other pupils (question 3.1); keep its
   answer.

## Settings and deploys

7. **Money stays off.** In each Firebase project (staging, prod), open the
   Admin panel > Settings and check that **Wallet, Settle up and Cost per
   child are off**. A project with no `config/features` document already
   reads them as off. Do not turn any of them on without the lawyer.
8. **Public pages with the DPO.** When you build the links site, add the
   DPO address (and name when appointed):
   ```
   python3 tool/links_site.py --team-id <TEAM ID> --bundle-id org.schoolcarpool.app \
     --support-email <address> --operator-name "<legal name>" \
     --operator-address "<registered address>" --require-address \
     --dpo-email <dpo address> --dpo-name "<DPO name>" --require-legal
   ```
   (R8: the registered address is required for prod: Law 175/2018 Art. 2
   asks a service provider to publish its name and address.)
   (Cloud Shell: put `OPERATOR_ADDRESS="..." DPO_EMAIL=... DPO_NAME="..."` in front of
   `bash tool/cloud_setup.sh ...`.) Ask the lawyer to approve the Arabic
   texts of the privacy policy and terms (question 5.2); the Arabic text is
   the governing one.
9. **Logs for 180 days** (Anti-Cybercrime Law, question 4.1): if the lawyer
   says the app is a "service provider", set the retention of the Cloud
   Logging `_Default` bucket to 180 days in each project (Logging > Logs
   storage; this has a cost above the free allowance) and confirm with the
   lawyer what must survive account deletion (question 4.2).
10. **Processor contracts.** Accept or sign the data processing terms of
    Google Cloud/Firebase, Meta (WhatsApp Business), Algolia, Sentry, the
    email provider and Valify; note each one's data region in
    `docs/legal/records-of-processing.md`. Go through
    `docs/legal/processor-checklist.md` (R10) for each one: 24-hour breach
    notice in the contracts we can negotiate (Valify, email provider), and
    **move Sentry and Algolia to their EU regions** before the pilot if
    the plans allow it (steps in that file).
11. **Existing testers.** The terms, privacy policy and ID consents changed
    (version 2026-11-16) and a new "Storage abroad" consent was added.
    Recommended (safe side): ask every existing account to accept again
    (open item B2) before the pilot.

## Every year

16. **Penetration test (R13).** Book an outside tester for the app, the
    admin panel, the functions and the rules: once before the pilot, then
    every 12 months and after any big change (PM Decree 1699/2020 Art. 2
    asks IT service providers for an annual test). Give them SECURITY.md
    and docs/security/threat-model.md; keep the report and the fixes with
    the company records. Costs: docs/COSTS.md.

## Running the app

12. **Privacy requests:** someone checks the admin queue every working day;
    nothing may be overdue (6 working days). See `docs/legal/dsr-procedure.md`.
13. **Breaches:** record it at once in the admin panel > **Incidents >
    Report incident** (starts the 72-hour clock) and follow
    `docs/legal/breach-runbook.md` (PDPC within 72 hours, immediately for
    children's or face data; parents within 3 working days after; report
    a crime to the authorities; keep the evidence). Keep the DPO's and the
    lawyer's numbers at hand.
15. **Processor security contacts:** set the security / notification email
    of Google Cloud (Essential Contacts: Security, Legal), Sentry, Meta
    Business, Algolia and the email provider to an address the DPO reads;
    ask Valify for a 24-hour breach notice in its contract.
14. **Every new data type, new country or new money feature** goes back to
    the lawyer and the DPO first (and updates the PDPC licence if a new
    country is added).
