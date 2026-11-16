# Research answers to the legal questions (Egypt + international)

> **Disclaimer.** This is research by the build agent, acting as a careful
> legal researcher, **not a lawyer. It is not legal advice.** It answers
> every question in section 12 of `docs/legal/egypt-legal-review.md` from
> the sources found on **16 Nov 2026** (law-firm translations and briefings,
> Egyptian press, unofficial English translations; the official Arabic texts
> in the Official Gazette govern, and pdpc.gov.eg could not be opened from
> the workspace). Where the sources conflict or are silent, the **safer
> reading** is chosen and international practice (GDPR, French car-pooling
> law, COPPA, Apple rules) is used only to justify the safe choice. Each
> answer says whether a licensed Egyptian lawyer must still sign it off.
> Nothing here changes an owner decision; recommended changes are listed for
> the coordinator at the end. **Update 16 Nov 2026:** the owner approved all
> fifteen; each is marked DONE with its commit.

Owner instruction (16 Nov 2026): "review Egyptian and international law and
answer the questions yourself from your point of view and research".

**Facts relied on** (all answers): free volunteer parent carpools, no money
anywhere (wallet, Settle up and contributions off); same school (or, for
F39, same activity); ID-verified parents (national ID + selfie face match
via Valify); parents' own private cars; children up to 18; live location
during runs shared only with that run's parents; chat; WhatsApp alert to an
emergency contact; hosting Google Cloud `europe-west1` (Belgium);
processors Google/Firebase, Meta WhatsApp, Algolia, Sentry, an email
provider, Valify, Vertex AI (school names only); run today by an individual.

## Summary table

| Q | Short answer | Confidence | Action |
| --- | --- | --- | --- |
| 1.1 | Need: (a) controller licence, (b) sensitive-data licence (children + biometrics), (c) cross-border licence; a company with ≤100,000 records pays **EGP 0** licence fee (transfer licence = 50% of that = 0); an individual can only get one-year permits (≤25,000 records fee-free). | Medium | Form a company, then file all three on the PDPC portal |
| 1.2 | **No.** Do not put real parents' or children's data in prod until the licences are granted; silence = refusal and there is no transitional rule. | Medium-high | Keep prod closed to real parents; pilot only after licences (or written PDPC/lawyer OK) |
| 1.3 | DPO may be an employee **or a contracted** person (Regs Art. 10), must pass PDPC tests, clean record, registered with a DPO code; PDPC decides in 30 business days. Not the owner himself. | Medium-high | Contract a qualified DPO in writing; register via the portal |
| 1.4 | An electronic consent is allowed ("on paper or electronically", Regs Arts. 14-15), but a bare tick box is weak; use a separate unticked box + typed full name + device re-authentication, stored in a consent register, with a copy to the parent. No certified e-signature needed. | Medium | Strengthen the sensitive-data consent flow (recommended change R3) |
| 1.5 | Belgium/EU should pass the PDPC adequacy criteria; US recipients need the transfer licence naming each country **plus** explicit consent; no PDPC adequacy list yet. Sign each processor's DPA with transfer clauses; prefer EU regions. | Medium | List every country in the transfer licence; switch Sentry/Algolia to EU regions where possible |
| 1.6 | **Yes, keep consent records 3 years after closure** (misdemeanour limitation 3 years; civil claims 3 years; PDPC 3-year proof practice). | Medium-high | Change consents retention 1 → 3 years (R1) |
| 1.7 | Get **both**: the guardian's explicit written consent (already) **and** the 15-18 child's own agreement, until the PDPC issues its mechanism. | Medium | Add a teen-agreement attestation for children 15+ (R4) |
| 1.8 | Basis = the parent's consent + legitimate interest/safety of the child (Law Art. 6(4)); but safest is the contact's own opt-in (also Meta's rule). | Medium | Parent attests the contact agreed; contact confirms via link; first message says how to stop (R6) |
| 1.9 | **Yes**, treat it as tracking of children: allowed only as strictly necessary for run safety, with extra safeguards. | Medium-high | Keep run-only sharing; write a DPIA; consider a shorter route archive (R11) |
| 1.10 | The regulation text says "immediately" only for national security; some briefings add sensitive data — **act as if "immediately" (target 24 h)** for children/biometric data. Crime report: Public Prosecution and the Ministry of Interior's IT-crimes unit. Staging: notify if real testers' data was touched; report crimes either way. | Medium | Keep runbook; add the authorities and the staging rule |
| 1.11 | No period in the law; keep the breach register **5 years after closing** an incident. | Medium | Add a breach-register retention rule (R7) |
| 1.12 | Processors must notify us **within 24 hours** with the Art. 5 contents, help with notices, keep evidence, flow down to sub-processors. Big vendors' "without undue delay" is accepted as-is. | Medium | Processor checklist; 24 h in Valify and email-provider contracts (R10) |
| 2.1 | **Probably outside Law 87/2018** (no fare, no fee, closed groups, own cars, the law regulates licensed transport companies), but the definition has no fare element, so it is not certain. | Medium | Keep all money off; get the lawyer's written opinion |
| 2.2 | **Yes, any money could change the answer; no amount is safe** in Egypt (unlike France, there is no cost-sharing exemption). | High | Keep every money feature off |
| 2.3 | Compulsory insurance covers death/injury of people hurt by the car with no passenger exclusion found; recourse (Art. 56) is unlikely for free personal-use rides, but cover is low (EGP 100,000). | Medium | Tell parents to check their policy and buy optional/passenger cover |
| 2.4 | Yes, it raises the Law 87 risk a little (looks like matching nearby strangers). | Medium | Restrict activity carpools to the same activity venue + parent approval; fix the terms wording (R9) |
| 3.1 | No Egyptian Ministry of Education rule on parent-to-parent carpools was found. Get the pilot school's written no-objection; never imply school endorsement. | Low-medium | Owner asks the school in writing |
| 4.1 | **Likely yes** (broad definition: anyone providing ICT services, incl. storing data for others). | Medium-high | Treat the app as a service provider |
| 4.2 | Keep sign-in logs **180 days from each sign-in, even after account deletion**: user identity, time, IP, device, traffic data; confidential; disclose only on a judicial order. | Medium | Keep a restricted 180-day log store that survives deletion (R2) |
| 5.1 | Treat it as applying. The Arabic-governing text satisfies Art. 5 if a full Arabic version is shown first. | Medium | Keep Arabic first; add operator name/address |
| 5.2 | The current texts are broadly sound; fix the activity-carpool wording, add operator address, an incident section and insurance-notice duty. Final approval stays with the lawyer. | Medium | Edit texts (R8); lawyer approves |
| 6.1 | Yes: any money feature needs a written CBE/lawyer opinion first, plus a fresh Law 87/insurance check. | High | Keep off |
| 7.1 | A **one-person company** (Law 159/1981 as amended by Law 4/2018; EGP 50,000 capital) or LLC; commercial register and tax card are mandatory for any company, even with no revenue. | Medium | Incorporate with a lawyer before the pilot |
| 7.2 | No legal ban on the word "school"/"مدرسة" in an app name found; do not suggest Ministry or school endorsement; check and register the trademark. | Low-medium | Trademark search at the Egyptian IP Authority |
| 7.3 | The operating company, through its legal representative (the manager), accepts/signs every processor agreement. | Medium-high | Re-accept DPAs in the company's name once formed |
| 8.1 | No ban on private parties keeping ID copies in Law 143/1994; the PDPL limits apply (minimisation; biometrics = sensitive). | Medium | Keep hash + expiry; consider shorter image retention (R12) |
| 8.2 | Valify has an FRA licence (digital contracts/e-records); no PDPC licence found yet. The contract must make it our processor under Law 151. | Medium | Ask Valify for its PDPC status; contract checklist |
| 9.1 | Enforceable as written because it carves out fraud, gross negligence and personal injury (Civil Code Art. 217); the real protection is the facts (app does not drive or choose drivers). | Medium-high | Add incident and insurance-notice clauses (R8) |

---

## Sources (opened 16 Nov 2026 unless marked)

| Key | Source |
| --- | --- |
| S1 | Ministerial Decree 816/2025 (PDPL Executive Regulations), English translation: [Consortio](https://consortiolawfirm.com/egypt-data-protection-law-executive-regulations-2025-english/) |
| S2 | Law 151/2020 (PDPL), English translation: [ACC/MBH](https://www.acc.com/sites/default/files/program-materials/upload/Data%20Protection%20Law%20-%20Egypt%20-%20EN%20-%20MBH.PDF) |
| S3 | Consortio, "Cross-Border Data Transfer Egypt", 23 Jun 2026: [link](https://consortiolawfirm.com/cross-border-data-transfer-egypt-pdpl/) |
| S4 | Youm7 on Law 151 Art. 26 (licence categories, fee caps), 24 May 2026: [link](https://www.youm7.com/7425868) |
| S5 | Al Tamimi, Executive Regulations briefing: [link](https://www.tamimi.com/law_update_articles/from-policy-to-practice-egypt-issues-executive-regulations-of-the-personal-data-protection-law/) (cited in the memo) |
| S6 | CMS, 13 Jan 2026: [link](https://cms.law/en/are/legal-updates/egypt-s-pdpl-executive-regulations-issued-one-year-compliance-countdown-begins) (cited in the memo) |
| S7 | Mondaq, "Electronic signatures in Egypt, Law 15 of 2004", 29 Jan 2026: [link](https://www.mondaq.com/contracts-and-commercial-law/1737494/electronic-signatures-in-egypt-%7C-legal-validity-under-law-15-of-2004) |
| S8 | Mondaq/Youssry Saleh, "Digital consent and Art. 147 Civil Code", 23 Jan 2026: [link](https://www.mondaq.com/new-technology/1734924/digital-consent-and-article-147-of-the-civil-code) |
| S9 | Law 87/2018, Arabic text: [link](https://ahmedazimelgamel.blogspot.com/2018/06/87-2018.html) |
| S10 | PM Decree 2180/2019 (Law 87 rules), Arabic: [mohamah.net](https://www.mohamah.net/law/?p=162819) |
| S11 | Traffic Law 66/1973, Arabic: [mohamah.net](https://www.mohamah.net/law/?p=50503) |
| S12 | Law 155/2024 (Unified Insurance), English: [Andersen](https://eg.andersen.com/wp-content/uploads/2026/02/Law-No.-155-of-2024.pdf); Arabic Gazette: [FRA](https://fra.gov.eg/wp-content/uploads/2024/10/alamiria_2024_155.pdf) |
| S13 | France, car-pooling rules (Code des transports L3132-1): [Ministry of Ecological Transition](https://www.ecologie.gouv.fr/politiques-publiques/covoiturage-france-ses-avantages-reglementation-vigueur?lang=en) |
| S14 | Law 175/2018 (Anti-Cybercrime), English: [Andersen](https://eg.andersen.com/wp-content/uploads/2025/06/Law-No.-175-of-2018-Concerning-Information-Technology-Crimes.pdf) |
| S15 | PM Decree 1699/2020 (Law 175 regulations), Arabic: [FRA PDF](https://fra.gov.eg/wp-content/uploads/2025/01/يُعمل-بأحكام-اللائحة-التنفيذية-المرافقة-فى-شأن-قانون-مكافحة-جرائم-تقنية-المعلومات-المشـار-إليـه.pdf) |
| S16 | Law 181/2018 (Consumer Protection), English: [Andersen](https://eg.andersen.com/wp-content/uploads/2025/07/Law-No.-181-of-2018.pdf) |
| S17 | Civil Code Art. 217(3), Arabic: [mohamah.net](https://www.mohamah.net/law/?p=173202). Arts. 163, 172, 178 and 217(1)-(2): standard text of Law 131/1948, **not re-opened here** |
| S18 | Law 143/1994 (Civil Status), English: [Andersen](https://eg.andersen.com/wp-content/uploads/2026/07/Law-No.-143-of-1994.pdf) |
| S19 | One-person company guide, Mondaq/Sadany, 23 Jun 2026: [link](https://www.mondaq.com/corporate-governance/1805424/one-person-company-egypt-2025-%7c-opc-legal-setup-guide) |
| S20 | Valify FRA approval: [Egypt Innovate](https://egyptinnovate.com/en/node/14146) |
| S21 | Baker McKenzie, CBE digital financial identity (eKYC) rules, 2 Sep 2026: [link](https://www.bakermckenzie.com/en/insight/publications/2026/09/egypt-new-digital-financial-identity-system-rules-for-ekyc) |
| S22 | Al Tamimi, Law 163/2023 establishing the Egyptian IP Authority, 17 Aug 2023: [link](https://www.tamimi.com/news/issuance-of-law-establishing-egyptian-intellectual-property-authority) (title seen in search, not opened) |
| S23 | Parlmany, new Criminal Procedure Law postponed to Oct 2027, 30 Sep 2026: [link](https://www.parlmany.com/News/2/616557/التشريعية-تحسم-موقفها-أكتوبر-2027-موعدًا-لتطبيق-قانون-الإجراءات-الجنائية) (title seen in search, not opened). Old Criminal Procedure Code Art. 15 (misdemeanours 3 years): standard text, **not re-opened** |
| S24 | GDPR (EU 2016/679): [EUR-Lex](https://eur-lex.europa.eu/eli/reg/2016/679/oj), standard text, **not re-opened** |
| S25 | US COPPA Rule, 16 CFR 312: [eCFR](https://www.ecfr.gov/current/title-16/chapter-I/subchapter-C/part-312), **not re-opened** |
| S26 | Apple App Review Guidelines 5.1.1: [Apple](https://developer.apple.com/app-store/review/guidelines/), **not re-opened** (already applied in docs/app-review-notes.md) |
| S27 | Baker McKenzie, PDPC portal, 7 Oct 2026 (cited in the memo): [link](https://www.bakermckenzie.com/en/insight/publications/2026/10/egypt-personal-data-protection-law-update) |

---

## 1. Personal data (Law 151/2020 and Decree 816/2025)

### 1.1 Which PDPC licences, cost, small-database exemption?

**(a) Short answer.** Three authorisations: (1) a **controller licence**,
(2) a **sensitive-data licence** (children's data and biometric face
matching), (3) a **cross-border transfer licence** (Belgium plus every
other country a processor uses). For a company with up to **100,000
records** the licence fee is **zero**, and the transfer licence costs 50%
of that (also zero). The exemption is from the **fee only, not from the
licence**. An individual can only get one-year **permits** (fee-free up to
25,000 records).

**(b) Reasoning.**
- Law Art. 26 lists licences/permits for controllers/processors, sensitive
  data and cross-border transfer; fee caps EGP 2 million (licence) and
  EGP 500,000 (permit) [S2, S4].
- Regs Art. 2 First (1) and Art. 3 First (1): whoever collects data "must
  hold a license or permit"; Art. 14(1): sensitive data needs a licence or
  permit "in accordance with the nature of the activity"; Art. 16 First
  (1): transfer needs a licence or permit [S1].
- Regs **Art. 19** (legal persons, controller + processor licence): 1 to
  100,000 records "exempt from license fees"; then EGP 200 per 100,000
  band up to 1 million (EGP 1,000); higher bands rise to EGP 666,666/year
  above 5 million. A **controller-only** licence is **half** the table;
  associations pay a flat EGP 5,000 [S1]. (The translation's second band
  reads "101,000"; probably a typo.)
- Regs **Art. 20** (permits, a specific temporary purpose up to one
  calendar year): 1 to 25,000 records fee-free; Art. 38: natural persons
  get permits, not licences [S1].
- Regs **Art. 27**: transfer licence/permit = 50% of the controller fee
  [S1]. No separate sensitive-data fee appears in the tables [S1].
- What counts as one "record" is not defined in the sources; we read it as
  one data subject. A pilot of a few hundred families is far below 100,000.
- Clyde & Co (cited in the memo) also mentioned a small-database fee
  exemption; this is now confirmed by the Art. 19 table.

**(c) Confidence:** Medium (translation; the portal may classify
differently).

**(d) What we do.** Form the company first (7.1), then file all three on
the PDPC portal (Digital Egypt sign-in [S27]) in the company's name,
declaring the expected record count, every destination country (1.5), the
record of processing, security measures and the DPO. Expect EGP 0 but
budget for the controller-only half-fee bands if the PDPC counts records
differently.

**(e) Lawyer sign-off:** **Essential** for the filing itself (it is an
official act and the fee class must be confirmed on the portal).

### 1.2 Pilot with real parents after filing but before the decision?

**(a) Short answer.** **No.** Do not process real parents', children's or
face data in prod until the licences are **granted** (or the PDPC or the
lawyer confirms in writing that processing may start on filing).

**(b) Reasoning.** Law Art. 12: sensitive data may not be processed
"except by virtue of a license issued from the Center" [S2]; Regs Art. 16
First (1): a transfer licence "must have" been obtained [S1]; Regs Art. 26
and 36(3): decision within 90 business days, **no answer = rejection**
[S1]; the Regulations contain **no transitional or grandfathering rule**
and the one-year grace period ended 1 Nov 2026 [S1, memo section 1].
Penalties for sensitive data without a licence and unlawful transfer: at
least 3 months' prison and/or EGP 500,000 to 5 million (Arts. 41-42)
[memo section 1]. Every feature of our pilot touches children's data, so
a "light" pilot without sensitive data is not possible.
International: under the GDPR no prior licence exists, so this is an
Egypt-specific risk; nothing abroad softens it.

**(c) Confidence:** Medium-high.

**(d) What we do.** Prod stays closed to real parents (TestFlight only
with staff/testers who accept that the app is a test, fake children only)
until the three licence decisions arrive. Use the 90 business days to
finish the company, DPO, contracts and texts. Ask the PDPC (portal or
hotline) whether it issues a provisional acknowledgement; if it does in
writing, the lawyer can reconsider.

**(e) Lawyer sign-off:** Recommended (only to relax this answer; the safe
answer needs no sign-off).

### 1.3 Who must be the DPO; exam/registration steps?

**(a) Short answer.** A qualified person who is either an employee **or
contracted** (external DPO allowed by the Regulations), who passes the
PDPC's tests, has a clean criminal record, is appointed in writing with
independence, and is registered with a PDPC DPO code. Not the owner
himself (conflict with the legal representative role).

**(b) Reasoning.** Law Art. 8 says the legal representative appoints "a
competent employee" [S2], but Regs **Art. 10** allows a DPO from the
"organizational structure or contracted"; Art. 11 lets one DPO serve
several entities with PDPC approval; Art. 7: academic or professional
qualification, practical experience, PDPC-approved tests, no conviction for
dishonesty; Art. 8: documents (ID, photo, qualifications, experience,
criminal record certificate, test results), decision within 30 business
days; Art. 9: electronic registration, DPO code, filed by the legal
representative or the person; Art. 21(5): DPO contract expressly accepts
the role and gives independence; Art. 12: annual report, no conflicting
duties [S1]. Conflict between "employee" (law) and "contracted"
(regulation): the safer path is a written appointment contract that makes
the DPO part of the organisation (part-time employment or a service
contract that names the person). GDPR Art. 37-38 also allow an external
DPO and forbid conflicts (e.g. the CEO) [S24].

**(c) Confidence:** Medium-high.

**(d) What we do.** Contract a qualified individual DPO (or a
PDPC-accredited consultancy's named person), registered before the
licence filing; put the DPO's name and email in the public pages
(`tool/links_site.py --dpo-*`).

**(e) Lawyer sign-off:** Helpful for the contract; not essential.

### 1.4 Is a tick box "explicit written consent"?

**(a) Short answer.** Electronic consent is expressly allowed, so no paper
and no certified e-signature are needed. But a bare tick box is the weak
end; make the sensitive-data consent clearly "written": a **separate,
unticked** box per purpose, **typed full name**, a **fresh device
check** (Face ID / passcode or the WhatsApp code), a stored record (text
version, time, method, device), and a **copy** the parent can open.

**(b) Reasoning.** Law Art. 12: written consent for sensitive data, the
guardian's for children [S2]. Regs **Art. 14(2)** and **Art. 15**: "explicit
written consent (**on paper or electronically**)" [S1]. Regs Art. 2
Second (3)(a): a secure electronic consent register recording the date and
"the form in which it was issued"; Art. 2 First (3): the PDPC approves
consent mechanisms [S1]. Law 15/2004 Arts. 14-15 give e-signatures and
e-documents full evidential force when technical controls (independent
timestamp, attribution to the signer, integrity) are met; a certified
signature is one route, verified authenticity another [S7]. Egyptian
commentators doubt that a reflexive "I agree" click shows real will
[S8]. GDPR Art. 9(2)(a) "explicit consent" is accepted electronically when
it is a clear, separate statement (EDPB practice; e.g. typed confirmation
or two-step) [S24].

**(c) Confidence:** Medium.

**(d) What we do.** Recommended change **R3** (below). Include
screenshots of the flow in the PDPC licence file so the PDPC can approve
the mechanism (Regs Art. 2 First (3)).

**(e) Lawyer sign-off:** Recommended (wording of the consent texts).

### 1.5 Processor locations, adequacy, transfer clauses?

**(a) Short answer.** No PDPC adequacy list exists yet. Belgium/EU (GDPR)
should meet the PDPC criteria; US or other destinations (Meta, Algolia,
Sentry, Google services, email provider) must be **named in the transfer
licence** and covered by the parent's explicit consent (already built).
Sign each processor's DPA (with standard transfer clauses) and use **EU
regions** where the service offers them.

**(b) Reasoning.** Law Art. 14: transfer only to a country with protection
not lower than Egypt's **and** with a PDPC licence; Art. 15: with explicit
consent, transfers may go ahead in listed cases even without that level
[S2]. Regs Art. 16 requires **both** a licence and the data subject's
consent; adequacy criteria: data protection legislation, technical and
security rules, compensation rules; storage abroad is a transfer; new
countries need a licence update; Art. 4(5): a processor outside Egypt with
no local branch appoints an accredited representative in Egypt [S1].
Consortio (23 Jun 2026): the country-by-country list is "still being
rolled out"; cloud storage abroad is a transfer [S3]. GDPR Chapter V (Arts.
44-49): adequacy, standard contractual clauses, derogations such as
explicit consent [S24]. Vertex AI receives only public school names: not
personal data, so not a transfer.

**(c) Confidence:** Medium.

**(d) What we do.** Transfer licence lists: Belgium/EU (Google Cloud),
USA (Meta, Google APNs/FCM, Google Analytics if on, any US-hosted
processor), plus each processor's real region. Move Sentry to its EU data
region and Algolia to an EU cluster if available on the plan (owner
check). Ask the lawyer whether Art. 4(5) (local representative) binds
foreign processors of an Egyptian controller.

**(e) Lawyer sign-off:** Essential for the licence filing; the country
list is our job.

### 1.6 Keep consent records 3 years after closure?

**(a) Short answer.** **Yes: 3 years after closure** (or longer while a
complaint or case is open).

**(b) Reasoning.** Regs Art. 2: the controller must be able to prove
consent through a consent register; no period is set [S1]. PDPL offences
are misdemeanours (prison of at least 3 months and/or fines [memo]); the
public action for misdemeanours lapses after **3 years** (Criminal
Procedure Code Art. 15; the new code is postponed to Oct 2027 [S23]);
tort claims lapse 3 years from knowledge (Civil Code Art. 172 [S17]); the
PDPC checklist keeps marketing consent proof 3 years [memo]. Consent records
hold no name, only type, version and time, so the privacy cost is small.
GDPR Art. 7(1) "be able to demonstrate" consent; EU regulators accept
retention for the limitation period [S24].

**(c) Confidence:** Medium-high.

**(d) What we do.** Recommended change **R1**: consents retention 1 year →
3 years after closure; update `KEPT_AFTER_DELETION`, the privacy policy and
the record of processing.

**(e) Lawyer sign-off:** Not essential (DECISIONS.md asks the lawyer for
longer retention; a one-line confirmation is enough).

### 1.7 Children 15-18: parent's consent enough?

**(a) Short answer.** Not safely. Until the PDPC issues its mechanism, get
**both** the guardian's explicit written consent (already built) **and**
the teenager's own agreement, collected through the parent.

**(b) Reasoning.** Law Art. 1: all data relating to children is sensitive;
Art. 12: the guardian consents [S2]. Regs **Art. 15**: under 15, the
guardian's explicit written consent with its time scope; for children
"between 15 and 18 years of age, the child or their guardian, as the case
may be" consents, under a mechanism the PDPC sets [S1]: ambiguous, and the
mechanism was not found. Egyptians get their national ID at 15 (Law
143/1994 Art. 48 [S18]). Abroad: GDPR Art. 8 lets a child consent alone
from 13-16 depending on the country [S24]; COPPA protects under 13 [S25].
Both point to teens having a say. Getting both satisfies either reading.

**(c) Confidence:** Medium.

**(d) What we do.** Recommended change **R4**: when a child is 15 or
older, the guardian declaration adds a line "My child has been told what
is shared (first name, grade, location during runs) and agrees" and stores
it with the consent.

**(e) Lawyer sign-off:** Recommended (or wait for the PDPC mechanism).

### 1.8 Legal basis for the emergency contact

**(a) Short answer.** Basis: the parent's consent and the **legitimate
interest of a concerned party** (the child's safety), Law Art. 6(4). Safer:
the contact's **own opt-in**, which Meta's WhatsApp policy also expects.

**(b) Reasoning.** Law Art. 2: data is collected with the data subject's
explicit consent "unless another law permits"; Art. 6 lists consent,
contract, legal obligation and the **legitimate interest** of the
controller or a concerned party [S2]; there is no separate "vital
interests" ground as in GDPR Art. 6(1)(d) [S24]. The contact is a data
subject who never agreed. GDPR practice (Art. 14) would also require
telling the contact. The earlier "lawyer confirmed" item (15 Nov) is kept,
but the safe side is low-cost.

**(c) Confidence:** Medium.

**(d) What we do.** Recommended change **R6**: the parent confirms "this
person agreed to be my emergency contact"; the contact gets a link (sent
by the parent from their own phone) to confirm; until confirmed, alerts
still go (safety) but the first message names the parent, says why, and
how to stop; data limited to name and number, deleted with the account.

**(e) Lawyer sign-off:** Recommended, not essential.

### 1.9 Is live location of a car with children "tracking of children"?

**(a) Short answer.** **Yes, treat it as tracking of children**: lawful
only as strictly necessary for the run's safety, run-only, shared with
that run's parents, short retention.

**(b) Reasoning.** A child's location is children's data, so sensitive
(Law Art. 1) [S2]. The Regulations' explicit ban on "classifying,
tracking, or behaviourally monitoring children" sits in Art. 14(5) on games
and competitions [S1], but it shows the regulator's attitude; Law Art. 3
requires purpose limitation and minimum retention [S2]. GDPR Art. 35
requires a DPIA for systematic monitoring and vulnerable data subjects
[S24]. Our design already meets most safeguards (live points 24 h, run-only,
members only). The 1-year route archive is the weakest point.

**(c) Confidence:** Medium-high.

**(d) What we do.** Write a short DPIA (no code); recommended change
**R11**: consider a 90-day route archive unless a report holds a route
(owner and lawyer decide; the 1-year period was lawyer-confirmed).

**(e) Lawyer sign-off:** Not essential; include the DPIA in the licence file.

### 1.10 Breach timing, crime report, staging

**(a) Short answer.** (1) The regulation text sets "immediately" only for
national security; one briefing adds sensitive data — **act as if
immediate**: target within 24 hours for children's or face data, never
later than 72 hours. (2) Crime report: the **Public Prosecution** and/or
the **Ministry of Interior's information-technology crimes unit** (General
Directorate for IT Crimes). (3) Staging/test: no PDPC notice if only fake
data was touched; **but** staging holds real testers' phone numbers, so a
staging incident touching them is notifiable; a crime (hacking) is
reported to the authorities either way.

**(b) Reasoning.** Regs Art. 5: PDPC within 72 hours of awareness,
immediate for national security, data subjects within 3 business days of
the PDPC notice, register of notices [S1]; Al Tamimi reads "immediately"
for sensitive data [S5]; conflict → safer reading. Law 175 Art. 35: the
manager must report crimes against the site/system "to the competent
authorities" [S14] (the law does not name the unit; the Public Prosecution
always has jurisdiction over crimes). Decree 1699/2020 Art. 3 (incident
reporting to the national CERT) applies to critical-infrastructure
operators, not to us [S15]. GDPR Art. 33/34: 72 h with a risk threshold;
Egypt has none [S24, memo].

**(c) Confidence:** Medium (authority name: low-medium).

**(d) What we do.** Keep the runbook; add the authorities' names and the
rule "staging with real tester numbers = personal data".

**(e) Lawyer sign-off:** Recommended for the authority to contact.

### 1.11 How long to keep the breach register?

**(a) Short answer.** No period in the law; keep each entry **5 years after
the incident is closed**.

**(b) Reasoning.** Regs Art. 5 requires the register but sets no period
[S1]. Art. 38 penalties for breach-notice failures are misdemeanours (3-year
limitation, running from the last act; an incident may only be found later)
[S23, memo]; the register mostly holds no personal data. 5 years covers
limitation, PDPC inspection and licence renewals (3-year cycle, Regs Art.
40) [S1]. GDPR Art. 33(5) expects documentation of every breach with no end
date; regulators commonly expect several years [S24].

**(c) Confidence:** Medium.

**(d) What we do.** Recommended change **R7** (documented rule; no
deletion job needed for years).

**(e) Lawyer sign-off:** Not essential.

### 1.12 What must processor contracts say on breaches?

**(a) Short answer.** Notice to us **within 24 hours** of awareness (so we
can meet 72 hours), with the Regs Art. 5 contents (time of awareness,
nature, records, likely effects, measures, contact), updates as facts
emerge, cooperation with PDPC and parents' notices, evidence preservation,
flow-down to sub-processors, and the processor's own PDPC duties.

**(b) Reasoning.** Regs Art. 5 makes controller and processor notify, lists
the notice contents and keeps a register [S1]; Regs Art. 4: processor
duties, incl. a register and restoring data after incidents [S1, memo];
GDPR Art. 28(3)(f) and 33(2): processor notifies "without undue delay"
[S24]. Big vendors' standard DPAs say "without undue delay" (Meta, Algolia,
Sentry) and cannot be negotiated on a free plan [memo 1A].

**(c) Confidence:** Medium.

**(d) What we do.** Accept the big vendors' DPAs as they are and route
their security mail to the DPO; require 24 hours in contracts we can
negotiate (Valify, email provider). Recommended change **R10** (checklist
document).

**(e) Lawyer sign-off:** Recommended for Valify's contract.

## 2. Transport, insurance, traffic

### 2.1 Is a free, closed parent carpool app outside Law 87/2018?

**(a) Short answer.** **Probably yes**, on these facts: no fare, no
contribution, no platform fee, no drivers for hire, closed groups of
verified parents of the same school, parents' own private cars, each parent
also driving their own children. It is not certain, because the definition
of the service contains no fare.

**(b) Reasoning.** Art. 1: the service is "land passenger transport by
private vehicles or collective transport, using information technology";
licensees are "companies licensed to make available or provide" it; Art. 2:
it may be provided under a licence [S9]. Everything around the definition
assumes a commercial operation: licensed **companies**, PM-designated
vehicles, operating cards, **tariffs** that licensees notify and publish
(Decree 2180/2019 Arts. 10(c), 29), licence applications by companies
(Art. 6), fees per vehicle (Art. 26) [S10]. Decree 2180/2019 Art. 1 applies
the licence to "irregular" (non-scheduled) transport services and sends
"regular" transport to governorate licences [S10]; a school rota is
regular, but our runs are not a transport service offered to the public at
all. France's legal definition draws the same line: car-pooling is shared
use of a car for a trip the driver makes for their own purposes, without
payment beyond cost-sharing, and is not a transport service [S13].

**(c) Confidence:** Medium.

**(d) What we do.** Keep every money feature off, keep groups closed to
verified parents of the same school (activity carpools: 2.4), keep the
volunteer acknowledgement and terms wording.

**(e) Lawyer sign-off:** **Essential** (written opinion naming the facts).

### 2.2 Would future cost sharing bring it under Law 87 or Art. 56?

**(a) Short answer.** **Yes, it could; no amount is safe in Egypt.** Unlike
France, Egyptian law has no cost-sharing exemption.

**(b) Reasoning.** Any payment adds a fare-like element to Law 87's
already broad definition [S9]; the private car is licensed "for personal
use" (Traffic Law Art. 4), and use for another purpose leads to licence
cancellation (Art. 32), suspension (Art. 72 bis (5)) and a fine (Art. 74
bis (2)) [S11]; the insurance pool may recover from the insured if the car
was used for purposes not authorised by the licence (Law 155/2024 Art.
56(3)) [S12]. France expressly allows cost-sharing within the car-pooling
definition, tax-free and insurance-neutral, because a statute says so
(L3132-1, ~EUR 0.20/km guidance) [S13]; Egypt has no such text.

**(c) Confidence:** High.

**(d) What we do.** Money stays off. Any change goes to the lawyer first.

**(e) Lawyer sign-off:** Essential before any money feature.

### 2.3 Free carriage of other children: insured? recourse?

**(a) Short answer.** Likely covered: compulsory insurance pays for death
and disabling injury caused by the car, and no passenger exclusion was
found; recourse is unlikely for free personal-use rides. But the cover is
low (EGP 100,000 for death/total disability), so parents need optional cover.

**(b) Reasoning.** Law 155/2024 Art. 40: compulsory civil-liability cover
for death and bodily injury causing disability, plus third-party property,
excluding damage to the insured car; no exclusion of passengers or relatives
in the text found [S12]. Art. 47: EGP 100,000 death/total disability, paid
by the pool within 30 days without a court case; Art. 48: claims above that
go against the liable person; Art. 51: the insured must notify the pool
**within 15 days**; Art. 56: recourse only for false statements,
concealment, or use not authorised by the licence [S12]. Free carriage of
friends' children is ordinary personal use of a private car (Traffic Law
Art. 4) [S11].

**(c) Confidence:** Medium.

**(d) What we do.** Parents' FAQ and terms: valid compulsory insurance,
notify the pool within 15 days of an accident, consider comprehensive and
passenger personal-accident cover (R8). Owner may ask one insurer for a
written confirmation.

**(e) Lawyer sign-off:** Not essential; an insurer's written answer is better.

### 2.4 Do activity carpools change the answer?

**(a) Short answer.** Yes, a little: matching by distance among parents
who do not share a school looks more like matching strangers. Keep them
closed and tied to one activity.

**(b) Reasoning.** The Law 87 analysis (2.1) rests on closed groups that
know each other; distance-based discovery weakens that fact. The terms
today say rides are only for "the same school", which no longer describes
F39 (terms section 1).

**(c) Confidence:** Medium.

**(d) What we do.** Recommended change **R9**: an activity carpool is tied
to one venue/activity, visible only to verified parents who choose that
activity, joining needs approval of every parent (F26 already), no public
"ride offers"; terms say "same school or the same activity"; keep F39 off
in the pilot until the lawyer's 2.1 opinion covers it.

**(e) Lawyer sign-off:** Include F39 in the 2.1 opinion.

## 3. Schools

### 3.1 Ministry of Education or school rules? Pilot school's consent?

**(a) Short answer.** No Egyptian Ministry rule on parents carrying other
pupils in private cars was found (searches return Gulf rules). Get the
pilot school's **written no-objection**, follow its gate rules, and never
suggest the school or the Ministry endorses the app.

**(b) Reasoning.** Absence of evidence [memo section 3; searches 16 Nov
2026]. School transport rules in the region concern school buses run or
contracted by schools; parents' private arrangements are family matters.
Child Law Art. 96 (endangering a child) still applies to how parents drive
[memo]. Using a school's name in a way that suggests endorsement risks
unfair-competition and trademark claims.

**(c) Confidence:** Low-medium.

**(d) What we do.** Owner sends the school a short letter; keep its reply.

**(e) Lawyer sign-off:** Not essential.

## 4. Cybercrime law

### 4.1 Is the app a "service provider" (Law 175 Art. 2)?

**(a) Short answer.** **Likely yes.**

**(b) Reasoning.** Art. 1: a service provider is "any natural or legal
person who provides information and communication technology services to
users, including those who process or store information either directly or
on behalf of others" [S14]. We store and process parents' information. Art.
2 Second: providers publish their name, address, contact and licensing data
[S14]. Decree 1699/2020 Art. 2: IT service providers take technical and
organisational measures incl. encryption, firewalls and **annual
penetration testing** [S15].

**(c) Confidence:** Medium-high.

**(d) What we do.** 4.2 logs; publish the operator's legal name, address
and email (R8); plan an annual penetration test (R13, cost: owner).

**(e) Lawyer sign-off:** Not essential.

### 4.2 Keep sign-in logs 180 days after deletion? Which fields?

**(a) Short answer.** **Yes.** Keep each log line **180 continuous days from
the event, even if the account is deleted**: data identifying the user,
traffic data (time, IP), device data, and what the user did in the system
(sign-in, sign-out). Confidential; disclosed only on a judicial order;
deleted automatically after 180 days.

**(b) Reasoning.** Art. 2 First: retain "information system logs ... for a
continuous period of 180 days", including data identifying the user, data
on the content and nature of the system handled, communications traffic and
terminal devices; keep them confidential and disclose only on an order of
the competent judicial authorities [S14]. Art. 33: EGP 5-10 million [memo].
Deleting them at account deletion can break the 180-day duty. PDPL allows
retention for a legal obligation (Law Art. 6(3)) [S2]; GDPR Art. 17(3)(b)
the same [S24]; Apple 5.1.1(v) allows keeping data the law requires if the
policy says so [S26].

**(c) Confidence:** Medium.

**(d) What we do.** Recommended change **R2** (conflicts with the owner
decision of 16 Nov 2026 to delete sign-in history with the account:
**owner decides**). Also set Cloud Logging retention to 180 days in prod
(owner action 9).

**(e) Lawyer sign-off:** Recommended (exact fields).

## 5. Consumer law and texts

### 5.1 Does Law 181/2018 apply; is Arabic-prevails enough?

**(a) Short answer.** Treat it as applying. Arabic-prevails is enough if
the full Arabic text is shown first and is the one accepted.

**(b) Reasoning.** Art. 1: a consumer is anyone to whom a product
(goods **and services**) is presented for non-professional needs; a
supplier is anyone engaged in a commercial, industrial, professional or
craft activity; no price is required in the definitions [S16]. A company
running the app (7.1) will be a commercial actor even if free. Art. 5:
contracts, including electronic ones, in Arabic; Art. 28: clauses reducing
the supplier's legal duties are void [S16].

**(c) Confidence:** Medium.

**(d) What we do.** Keep Arabic as default and governing; add operator name
and address (R8).

**(e) Lawyer sign-off:** Not essential.

### 5.2 Approve the final Arabic terms, privacy policy, conduct, liability

**(a) Short answer.** The current texts (`hosting/links/terms.html`,
privacy page, in-app ARB) are broadly sound. Fix: (1) "same school" vs
activity carpools; (2) operator legal name and address; (3) an incident
section (what parents do after an accident, the 15-day notice to the
insurance pool, cooperation with authorities, disclosure on lawful
request); (4) consent-register and log-retention lines if R1/R2 are
adopted.

**(b) Reasoning.** Sections 5.1, 9.1, 4.2, 2.3 above.

**(c) Confidence:** Medium.

**(d) What we do.** Recommended change **R8**.

**(e) Lawyer sign-off:** **Essential** for the final texts (they are the
contract with parents).

## 6. Payments

### 6.1 Before any money feature returns

**(a) Short answer.** Yes: a written lawyer/CBE opinion on the exact design
first, plus a fresh Law 87 and insurance check (2.2).

**(b) Reasoning.** CBE Law 194/2020 licenses payment services, e-money and
payment initiation [memo section 6]; the CBE's 2026 digital-identity rules
target banks [S21]. Money also changes the Law 87/insurance answer (2.2).

**(c) Confidence:** High.

**(d) What we do.** Keep wallet, Settle up and contributions off.

**(e) Lawyer sign-off:** Essential (before any change).

## 7. Company and names

### 7.1 Which entity? Register and tax card for a free app?

**(a) Short answer.** A **one-person company** (OPC) or a small LLC.
Commercial register and tax card are part of incorporating any company,
revenue or not.

**(b) Reasoning.** PDPC licences are for legal persons (Regs Art. 19);
individuals only get one-year permits (Arts. 20, 38) [S1]; the DPO is
appointed by a legal person's legal representative (Law Art. 8) [S2];
Apple asks that apps handling sensitive data be submitted by a legal entity
(5.1.1(ix)) [S26]; a company limits personal liability. OPC: Law 4/2018
(amending Law 159/1981), minimum capital **EGP 50,000** paid in, founder's
liability limited to capital unless finances are mixed; steps: name
certificate, notarised articles certified by a lawyer, bank deposit, GAFI,
commercial register, then tax card and social insurance file [S19]. NGO
alternative (Law 149/2019): association pays a flat EGP 5,000 PDPC fee
(Regs Art. 19) vs EGP 0 for a small company, and is slower with
Ministry of Social Solidarity oversight [S1].

**(c) Confidence:** Medium.

**(d) What we do.** Incorporate before the pilot; move Apple/Google
accounts, Firebase billing and DPAs to the company.

**(e) Lawyer sign-off:** **Essential** (incorporation requires a lawyer).

### 7.2 Is the app name or "school" wording restricted?

**(a) Short answer.** No restriction found on "school"/"مدرسة" in an app
or brand name. Avoid wording or logos that suggest Ministry or school
endorsement; search and register the trademark.

**(b) Reasoning.** Trademarks are registered under the IP Law 82/2002, now
administered by the Egyptian Intellectual Property Authority (Law
163/2023) [S22]; the company name needs a non-confusion certificate from
the Commercial Registry [S19]. No source found restricting the word.

**(c) Confidence:** Low-medium.

**(d) What we do.** Trademark search/filing (R14) once the company exists.

**(e) Lawyer sign-off:** Recommended (IP lawyer for the filing).

### 7.3 Who signs the processor agreements?

**(a) Short answer.** The operating company (the controller), through its
legal representative. Until it exists the owner accepts them personally,
then re-accepts/transfers them to the company.

**(b) Reasoning.** The controller is responsible for its processors (Law
Arts. 4-5, Regs Art. 4) [S2, S1]; GDPR Art. 28 [S24].

**(c) Confidence:** Medium-high.

**(d) What we do.** Record each DPA (version, date, region) in
`docs/legal/records-of-processing.md`.

**(e) Lawyer sign-off:** Not essential.

## 8. Identity checks

### 8.1 Limits on collecting national ID images and numbers?

**(a) Short answer.** No ban on private parties keeping ID copies or
numbers in the Civil Status Law. The PDPL limits apply: collect only what
is needed, keep only as long as needed; the face match is sensitive.

**(b) Reasoning.** Law 143/1994 Art. 13: confidentiality of the **civil
registry's** data; Art. 2 bis: service providers obtain beneficiaries'
national number; Art. 50: entities may not refuse the card as proof; Art.
57 even obliges hotels to record card data; no ban on private copies
[S18]. PDPL Art. 3: purpose limitation and minimum retention [S2].

**(c) Confidence:** Medium.

**(d) What we do.** Keep the hash + expiry design; recommended change
**R12**: consider deleting ID images some days after a decision (the
owner chose "while the account is active"; owner/lawyer decide).

**(e) Lawyer sign-off:** Not essential.

### 8.2 Is Valify licensed; what must the contract say?

**(a) Short answer.** Valify holds an **FRA** licence for digital
contracts and secure e-records; no PDPC licence was found (the regime only
began in Nov 2026). Our contract must make Valify our processor.

**(b) Reasoning.** [S20]; the CBE's 2026 digital-identity rules cover banks
via the Haweya platform, not apps like ours [S21]. Processor duties: Law
Art. 5, Regs Art. 4 [S2, S1].

**(c) Confidence:** Medium.

**(d) What we do.** Ask Valify for its PDPC licence/application number.
Contract: process only on our instructions; data stays in Egypt (or named
country); no reuse or model training; delete images after returning the
result; security standard; 24-hour breach notice; sub-processor list;
audit; help with data-subject requests; liability (R10).

**(e) Lawyer sign-off:** Recommended for the contract.

## 9. Liability

### 9.1 Is the liability clause enforceable; what else on incidents?

**(a) Short answer.** Yes as written, because it does not try to exclude
fraud, gross negligence or harm to persons. The real protection is the
facts (the app does not drive or choose drivers; parents approve each
driver). Add an incident section.

**(b) Reasoning.** Civil Code Art. 217: contractual liability may be
limited except for fraud or gross fault; any clause exempting from tort
liability is void (217(3)) [S17]; Art. 163: whoever causes harm by fault
compensates; Art. 178: whoever has custody of things needing special care
or mechanical machines (a car) is liable unless an outside cause is proven
[S17, not re-opened]; Consumer Law Art. 28 [S16]. The driving parent bears
tort liability; the app's exposure is negligent verification or a failed
promised feature.

**(c) Confidence:** Medium-high.

**(d) What we do.** R8: add incident steps (call 122/123, report in the
app, notify the insurance pool within 15 days, the app keeps run records
and gives them to authorities on lawful request); do not market safety
features as guarantees.

**(e) Lawyer sign-off:** Essential as part of 5.2.

---

## Recommended changes (owner approved all on 16 Nov 2026: "implement everything"; status below)

| # | Priority | Change | From | Status |
| --- | --- | --- | --- | --- |
| R5 | P1 | **Keep prod closed to real parents until the three PDPC licences are granted** (ops rule; no code). | 1.2 | DONE (`03cf773`) |
| R1 | P1 | Consent records: retention **1 → 3 years after closure** (`functions/src/privacy/retention.ts` `consents`, `KEPT_AFTER_DELETION` text, privacy pages, record of processing). | 1.6 | DONE (`8a0ac62`) |
| R2 | P1 | Sign-in log kept **180 days from each event, surviving account deletion**, in a restricted store (uid, encrypted phone, time, IP, device, platform, app version; judicial-order disclosure only); privacy and delete-account pages say so. **Conflicts with owner decision 16 Nov: owner decides.** Also fix the stale "90 days" comment in `functions/src/privacy/devices.ts`. | 4.2 | DONE (`6620425`) |
| R3 | P1 | Sensitive-data consents (ID + face, guardian declaration, transfer abroad): separate unticked box + typed full name + device re-auth; record method and text hash; a copy the parent can open. | 1.4 | DONE (`15c20c0`) |
| R4 | P1 | Guardian declaration: extra line for children aged 15+ ("my child was told and agrees"). | 1.7 | DONE (`68a44f7`) |
| R6 | P2 | Emergency contact: parent attests the contact agreed; confirmation link; first message names the parent and how to stop. | 1.8 | DONE (`4ae2111`) |
| R7 | P2 | Breach register retention: 5 years after closing (documented rule). | 1.11 | DONE (`66fd5e4`) |
| R8 | P2 | Terms/privacy wording: "same school or activity"; operator legal name and address; incident section (122/123, report in app, insurance pool within 15 days, lawful disclosure); log and consent retention lines. Lawyer approves. | 2.3, 2.4, 4.1, 5.1, 5.2, 9.1 | DONE (`4f0e30a`) |
| R9 | P2 | Activity carpools: one venue/activity, approval by all parents, no public ride offers; keep F39 off in the pilot until the lawyer's opinion covers it. | 2.4 | DONE (`e161407`) |
| R10 | P2 | Processor contract checklist (24 h breach notice, Art. 5 contents, region, no reuse, deletion, sub-processors); Sentry and Algolia EU regions if available. | 1.5, 1.12, 8.2 | DONE (`ae1ced2`) |
| R11 | P3 | DPIA for live location of children; consider route archive 1 year → 90 days (owner/lawyer). | 1.9 | DONE (`da57c7d`) |
| R12 | P3 | Consider deleting ID images N days after the decision (keep hash, expiry, result). Owner decision conflict. | 8.1 | DONE (`ee7a2c3`) |
| R13 | P3 | Annual penetration test (Decree 1699/2020 Art. 2); cost. | 4.1 | DONE (`899e4b2`) |
| R14 | P3 | Trademark search and filing after incorporation. | 7.2 | DONE (`1e310be`) |
| R15 | P3 | Runbook: name the Public Prosecution / MoI IT-crimes unit; staging with real tester numbers counts as personal data. | 1.10 | DONE (`ee77ebd`) |

Notes on how they were built (branch `legal-changes`,
docs/progress/legal-changes.md): R5 is enforced in code (`config/launch`);
R6 follows 1.8 (alerts still go before the contact confirms; the first
introduces the parent); R11 and R12 were built as the shorter periods
(90-day routes; case images 30 days after the decision), which the lawyer
should confirm because they replace earlier lawyer-confirmed periods;
R10, R13 and R14 are documents and owner actions.

## Still essential for a licensed Egyptian lawyer or an official act

1.1 (PDPC filing), 1.5 (transfer licence), 2.1 (written Law 87 opinion,
incl. F39), 5.2 (final texts incl. 9.1), 6.1 (before any money), 7.1
(incorporation). Recommended but not essential: 1.2 (only to relax it),
1.4, 1.7, 1.8, 1.10, 1.12, 4.2, 7.2, 8.2.
