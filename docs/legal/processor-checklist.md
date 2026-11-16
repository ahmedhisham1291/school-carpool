# Processor contract checklist (R10)

Recommended change R10 of docs/legal/answers.md (1.5, 1.12, 8.2), approved
by the owner on 16 Nov 2026. Use it for every company that processes
personal data for us. **Not legal advice: the lawyer and the DPO check the
final contracts.** Law No. 151 of 2020, Arts. 4-5 and 14-16; Decree
816/2025 Arts. 4, 5 and 16.

## 1. What every processor contract (DPA) must say

Tick each line per processor in the table in section 3.

| # | Clause | Why |
| --- | --- | --- |
| C1 | Processes our data **only on our documented instructions**, for the purposes we name (sign-in codes, ID check, error reports ...) | Law Art. 5; Regs Art. 4 |
| C2 | **No reuse**: no own purposes, no selling, **no training of models** on our data | Purpose limitation (Law Art. 3) |
| C3 | **Breach notice to us within 24 hours** of becoming aware (we must tell the PDPC within 72 hours), to the DPO's address | Regs Art. 5; answers.md 1.12 |
| C4 | The notice holds the Regs Art. 5 contents: time of awareness, nature of the breach, records and people affected, likely effects, measures taken, a contact; updates as facts come in | Regs Art. 5 |
| C5 | Helps us notify the PDPC and the parents; keeps evidence (logs) | Regs Arts. 4-5 |
| C6 | **Data region** named in the contract (EU preferred); storage abroad counts as a transfer and must be in our PDPC transfer licence | Law Arts. 14-16; Regs Art. 16 |
| C7 | **Sub-processors**: a list, our right to object to new ones, the same duties flowed down | Regs Art. 4 |
| C8 | **Deletion**: deletes or returns our data at the end of the service and after each task where the contract allows (for example ID images after the check result) | Law Art. 3; R12 |
| C9 | Security: encryption in transit and at rest, access control, staff confidentiality | Law Art. 4; Decree 1699/2020 Art. 2 |
| C10 | Audit: answers our questions and gives its certifications (ISO 27001, SOC 2) | Regs Art. 4 |
| C11 | Helps with parents' requests (access, correction, deletion) within our 6 working days | Law Art. 2 |
| C12 | Its own PDPC duties (licence or accredited representative in Egypt where needed, Regs Art. 4(5)) | Regs Arts. 4, 16 |
| C13 | Signed or accepted **by the operating company** (after incorporation), version and date recorded in `records-of-processing.md` | answers.md 7.3 |

Big vendors' standard DPAs (Google, Meta, Algolia, Sentry) say "without
undue delay" instead of 24 hours and cannot be negotiated on a free plan:
**accept them as they are** (answers.md 1.12) and route their security
mail to the DPO (owner action 15). Require 24 hours in contracts we can
negotiate: Valify and the email provider.

## 2. Regions (owner checks in each console)

| Service | Region today | Target | How |
| --- | --- | --- | --- |
| Google Cloud / Firebase | `europe-west1` (Belgium) | keep | already |
| Sentry | check the organisation's data region | **EU (Frankfurt)** if the plan offers it | A new organisation created in the EU region (sentry.io > "Data Storage Location: EU" at sign-up); the region of an existing organisation cannot be changed, so create the EU one before the pilot and change `SENTRY_DSN` |
| Algolia | check the application's cluster | **EU cluster** if the free plan allows choosing it | Algolia dashboard > the application > region; otherwise a new application in the EU, then re-run the school index load (`schools:algolia`) and change `ALGOLIA_APP_ID` |
| Meta (WhatsApp) | Meta's global infrastructure (US/EU) | as is | name the USA in the transfer licence |
| Email provider | provider's region | EU if offered | provider settings |
| Valify | Egypt (to confirm) | Egypt | contract clause C6 |

Every country that stays (for example the USA for Meta and APNs) is named
in the PDPC cross-border licence (owner action 4).

## 3. Status per processor

| Processor | DPA accepted / signed (date, version) | C1-C13 checked | 24 h notice | Region confirmed | Security mail to DPO |
| --- | --- | --- | --- | --- | --- |
| Google Cloud / Firebase | | | "without undue delay" (accepted) | europe-west1 | |
| Meta WhatsApp Business | | | "without undue delay" (accepted) | | |
| Algolia | | | "without undue delay" (accepted) | | |
| Sentry | | | "promptly and without undue delay" (accepted) | | |
| Email provider | | | **require 24 h** | | |
| Valify | | | **require 24 h** | Egypt? | |
| Stream (until our own chat replaces it) | | | | | |
