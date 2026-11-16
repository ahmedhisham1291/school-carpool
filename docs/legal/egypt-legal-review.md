# Egypt legal review (safe-side memo)

**Checked:** 16 Nov 2026. **Written by:** the build agent as a careful
risk analyst, **not a lawyer**. **This is not legal advice.** It sorts the
rules that seem to apply, says what the app does today and what we changed
to stay on the safe side, and lists the questions a **licensed Egyptian
lawyer** must answer (section 12). Where this memo and an earlier
"lawyer confirmed" item in docs/DECISIONS.md disagree, the conflict is
flagged in section 11. **No earlier decision was changed silently.**

Sources are law-firm briefings, Egyptian press and unofficial English
translations found on 16 Nov 2026. The PDPC website (pdpc.gov.eg) could not be
opened from the build workspace; the official Arabic texts in the Official
Gazette (الجريدة الرسمية) govern and the lawyer should check them.

---

## ملخّص بالعربية

هذه مذكرة تحليل مخاطر وليست استشارة قانونية، وتحتاج إلى مراجعة محامٍ مصري مرخّص.

1. **حماية البيانات (القانون 151 لسنة 2020):** صدرت اللائحة التنفيذية بالقرار 816 لسنة 2025 في 1 نوفمبر 2025، وانتهت مهلة توفيق الأوضاع (سنة) في 31 أكتوبر / 1 نوفمبر 2026، وبدأ مركز حماية البيانات الشخصية الرقابة. يلزم **ترخيص** من المركز قبل معالجة البيانات، و**ترخيص للبيانات الحساسة** (بيانات الأطفال، والبيومترية مثل مطابقة الوجه)، و**ترخيص/تصريح للنقل خارج مصر** (Google Cloud في بلجيكا وغيرها)، و**تعيين مسؤول حماية بيانات** مسجّل لدى المركز. الإبلاغ عن الاختراق خلال 72 ساعة للمركز ثم خلال 3 أيام عمل لصاحب البيانات. الرد على طلبات أصحاب البيانات خلال 6 أيام عمل. الغرامات تصل إلى 5 ملايين جنيه مع الحبس في بعض الجرائم. **الخطر: مرتفع حتى يتم الترخيص وتعيين المسؤول.**
1أ. **الإبلاغ عن اختراق أو تسريب البيانات:** يلتزم المتحكم والمعالج بإخطار مركز حماية البيانات خلال 72 ساعة من العلم (وفورًا إذا تعلق بالأمن القومي، ونحن نعامل بيانات الأطفال والوجه بالمثل احتياطًا)، ثم إخطار أصحاب البيانات خلال 3 أيام عمل من إخطار المركز، دون استثناء للمخاطر المنخفضة، مع تسجيل كل إخطار في سجل إلكتروني آمن. وإذا كان الاختراق جريمة يجب إبلاغ السلطات المختصة (المادة 35 من القانون 175 لسنة 2018) والحفاظ على الأدلة. أضفنا سجل الحوادث وشاشة «تسجيل حادثة» في لوحة الإدارة ودليل الإجراءات بنماذج عربية.
2. **قانون النقل البري باستخدام تكنولوجيا المعلومات (87 لسنة 2018):** تعريف «الخدمة» لا يشترط الأجر، والتشغيل دون ترخيص غرامته 200 ألف إلى 5 ملايين جنيه. أفضل حماية هي ما قرره المالك: **التوصيل تطوعي ومجاني تمامًا** بين أهالي المدرسة نفسها، بلا أي أجرة أو مساهمة أو رسوم. أوقفنا المحفظة و«تسوية الحساب» والمساهمة لكل طفل في كل البيئات، وأضفنا إقرار «تناوب مجاني بلا مقابل». **الخطر: متوسط، ويجب أن يؤكده المحامي.**
3. **التأمين والمرور:** التأمين الإجباري (قانون التأمين الموحد 155 لسنة 2024) يغطي الوفاة والإصابة حتى 100 ألف جنيه، ويحق لشركة التأمين الرجوع على المؤمَّن له إذا استُخدمت السيارة في غير الغرض المرخّص به، واستخدام السيارة الملاكي في غير غرضها قد يؤدي لسحب الرخصة. لذلك يجب ألا يتقاضى أحد أي مقابل. ننصح كل ولي أمر بتأمين شامل اختياري وتأمين حوادث شخصية للركاب.
4. **الطفل:** قانون الطفل (المادة 96) يعاقب على تعريض الطفل للخطر؛ الالتزام بأحزمة الأمان ومقاعد الأطفال وعدد المقاعد مهم.
5. **الجرائم الإلكترونية (175 لسنة 2018):** قد يُعد التطبيق «مقدّم خدمة» يلزمه حفظ سجلات الدخول 180 يومًا؛ رفعنا مدة سجل الدخول إلى 180 يومًا.
6. **حماية المستهلك (181 لسنة 2018):** العقود الإلكترونية يجب أن تكون بالعربية، والشروط التي تعفي المورد من التزاماته باطلة. جعلنا النص العربي هو المعتمد وصححنا بند حدود المسؤولية.
7. **البنك المركزي (194 لسنة 2020):** لا أموال في التطبيق الآن، فالخطر منخفض.
8. **ما فعلناه في الكود:** موافقات منفصلة ومسجّلة (التخزين خارج مصر، البطاقة وصور الوجه، إقرار الولي لبيانات الأطفال)، مهلة 6 أيام عمل للطلبات مع قائمة للمشرفين، سجل دخول 180 يومًا، صفحات الخصوصية والشروط محدّثة مع مسؤول حماية البيانات، وسجل أنشطة المعالجة وخطة الاستجابة للاختراق.
9. **على المالك:** تسجيل كيان قانوني، طلب تراخيص المركز عبر بوابته (من خلال منصة مصر الرقمية)، تعيين مسؤول حماية بيانات، وعرض الأسئلة في القسم 12 على المحامي (docs/legal/owner-actions.md).

---

## Top risks at a glance

| # | Area | Risk now | Main safe-side action | Who |
| --- | --- | --- | --- | --- |
| 1 | PDPC licences (controller, sensitive data, transfer abroad) and DPO, Law 151/2020 + Decree 816/2025; grace period ended 31 Oct / 1 Nov 2026 | **High** until applied for | Apply on the PDPC portal; appoint and register a DPO; do not open to real parents (pilot, prod) before the applications are filed and the lawyer agrees | Owner + lawyer |
| 1A | Breach notification (Law 151 Art. 7, Decree 816/2025 Art. 5) + crime reporting (Law 175 Art. 35) | **Medium** | Breach register + admin "Report incident" + legal runbook (done); DPO; processor notice emails | Owner |
| 2 | Transfer abroad (Google Cloud Belgium, Meta, Algolia, Sentry, Google US services) | **High** until licensed | Separate explicit consent built; transfer licence/permit; processor agreements | Owner + lawyer |
| 3 | Sensitive data: children's data, biometric face matching | **High** until licensed | Separate explicit consents built (ID + face; guardian declaration); sensitive-data licence | Owner + lawyer |
| 4 | Law 87/2018 (ride-hailing law) | **Medium** (was high with contributions) | No money in the app (done); volunteer acknowledgement (done); closed school groups; lawyer opinion | Lawyer |
| 5 | Insurance recourse / traffic licence misuse if anyone is paid | **Medium** | No payment for rides (done); terms say so; parents told about insurance | Owner (parents' FAQ) |
| 6 | Operating as an individual (DPO duty, licences, Apple Organization account, liability) | **Medium** | Register a company (or confirm the right form with the lawyer) | Owner |
| 7 | Cybercrime law log retention (180 days) | **Medium** | Sign-in history 180 days (done); ask lawyer about keeping logs after account deletion | Lawyer |
| 8 | Breach notification 72 h / 3 working days (section 1A) | Medium until a DPO and processor contacts are in place | Legal runbook, breach register and admin "Report incident" (done); DPO, processor notification emails | Owner |
| 9 | Data subject requests in 6 working days | Low | Deadline + admin queue (done); admin screen still to build (D13) | Developer |
| 10 | Terms enforceability (Arabic, liability clauses) | Low after changes | Arabic prevails; no exclusion for gross negligence/injury (done); lawyer approves wording | Lawyer |
| 11 | Payments (CBE Law 194/2020) | **Low** (all money off) | Keep off; lawyer before any money feature | Owner |

---

## 1. Personal Data Protection Law No. 151 of 2020 and its Executive Regulations

### The rule

- **Status.** The Executive Regulations were issued by Ministerial Decree
  No. 816 of 2025 on 1 Nov 2025, made public on 25 Dec 2025, with a
  one-year compliance period ending 31 Oct / 1 Nov 2026 ([CMS, 13 Jan 2026](https://cms.law/en/are/legal-updates/egypt-s-pdpl-executive-regulations-issued-one-year-compliance-countdown-begins);
  [Al Tamimi, 4 Feb 2026](https://www.tamimi.com/law_update_articles/from-policy-to-practice-egypt-issues-executive-regulations-of-the-personal-data-protection-law/);
  [Clyde & Co, 21 Jan 2026](https://www.clydeco.com/en/insights/2026/01/egypt-regulatory-update-on-data-privacy);
  [Baker McKenzie, 7 Oct 2026](https://www.bakermckenzie.com/en/insight/publications/2026/10/egypt-personal-data-protection-law-update)).
  The PDPC's acting CEO said the Centre starts supervision after the
  transition ends on 1 Nov 2026, prioritising complaints and breach reports
  ([Al Mal News, 26 Oct 2026](https://almalnews.com/2143437/%D8%B3%D9%88%D8%B2%D8%A7%D9%86-%D8%A7%D9%84%D8%B9%D9%82%D8%A8%D8%A7%D9%88%D9%8A-%D9%85%D8%B1%D9%83%D8%B2-%D8%AD%D9%85%D8%A7%D9%8A%D8%A9-%D8%A7%D9%84%D8%A8%D9%8A%D8%A7%D9%86%D8%A7%D8%AA-%D8%A7%D9%84%D8%B4%D8%AE%D8%B5%D9%8A%D8%A9-%D9%8A%D8%A8%D8%AF%D8%A3/)).
  **As of 16 Nov 2026 the regulations are in force and the grace period has
  ended.** No extension was found.
- **Licences and registration.** A licence/permit from the PDPC is needed
  before collecting or processing personal data; separate licences/permits
  for sensitive data, cross-border transfer, direct electronic marketing and
  CCTV; decision within 90 (working) days of a complete file, silence = refusal;
  fees by number of records, capped by the law at EGP 2 million
  (Law Art. 26; Regulations; [Al Tamimi](https://www.tamimi.com/law_update_articles/from-policy-to-practice-egypt-issues-executive-regulations-of-the-personal-data-protection-law/);
  [Youm7 on Arts. 27-28, 13 Nov 2026](https://www.youm7.com/story/2026/11/13/%D9%82%D8%A7%D9%86%D9%88%D9%86-%D8%AD%D9%85%D8%A7%D9%8A%D8%A9-%D8%A7%D9%84%D8%A8%D9%8A%D8%A7%D9%86%D8%A7%D8%AA-%D8%A7%D9%84%D8%B4%D8%AE%D8%B5%D9%8A%D8%A9-%D8%AA%D9%81%D8%A7%D8%B5%D9%8A%D9%84-%D8%A5%D8%AC%D8%B1%D8%A7%D8%A1%D8%A7%D8%AA-%D9%88%D8%B4%D8%B1%D9%88%D8%B7-%D8%A7%D9%84%D8%AA%D8%B1%D8%A7%D8%AE%D9%8A%D8%B5-%D8%A7%D9%84%D8%AE%D8%A7%D8%B5%D8%A9-%D8%A8%D9%85%D8%B9%D8%A7%D9%84%D8%AC%D8%A9/7604419)).
  The PDPC portal opened in early October 2026; applicants sign in through
  **Digital Egypt** ([Baker McKenzie, 7 Oct 2026](https://www.bakermckenzie.com/en/insight/publications/2026/10/egypt-personal-data-protection-law-update)).
  Clyde & Co mention that small databases may be exempt from fees; the
  thresholds were not found.
- **DPO.** The legal representative of a legal person appoints a competent
  employee as data protection officer, registered with the PDPC (Law Arts.
  8-9; DPO register, qualification/exam, unique code, annual reports:
  [CMS](https://cms.law/en/are/legal-updates/egypt-s-pdpl-executive-regulations-issued-one-year-compliance-countdown-begins)).
- **Sensitive data.** Includes biometric data and "in all cases, data
  relating to children" (Law Art. 1). Processing needs a PDPC licence and
  the data subject's **explicit written consent**, the guardian's for
  children (Art. 12). Regulations: under-15s need the guardian's explicit
  written consent; 15-18 per PDPC mechanisms; profiling/tracking of
  children only where strictly necessary ([Al Tamimi](https://www.tamimi.com/law_update_articles/from-policy-to-practice-egypt-issues-executive-regulations-of-the-personal-data-protection-law/)).
  National ID numbers and location are not listed as sensitive by
  themselves, but **a child's location is children's data**.
- **Consent** must be explicit, informed, specific, granular, freely given,
  logged, and easy to withdraw; consents in **Arabic** ([CMS](https://cms.law/en/are/legal-updates/egypt-s-pdpl-executive-regulations-issued-one-year-compliance-countdown-begins)).
  Whether a tick box is "written" consent is not settled
  ([Mondaq, 23 Jan 2026](https://www.mondaq.com/new-technology/1734924/digital-consent-and-article-147-of-the-civil-code)).
- **Cross-border transfer** needs a PDPC licence/permit and a level of
  protection not lower than Egypt's (Arts. 14, 16); explicit consent of the
  data subject is an exception (Art. 15); Regulations add contract,
  legal-obligation, vital-interest and legal-claims exceptions; new
  destination countries require a licence update ([Kennedys 2026](https://www.kennedyslaw.com/en/thought-leadership/article/2026/egypt-s-personal-data-protection-law-the-compliance-countdown-has-begun/);
  [Al Tamimi](https://www.tamimi.com/law_update_articles/from-policy-to-practice-egypt-issues-executive-regulations-of-the-personal-data-protection-law/)).
- **Breach:** PDPC within **72 hours** (immediately for national security
  or, per the Regulations, sensitive data); data subjects within **3 working
  days** of notifying the PDPC; processors tell the controller without
  delay (Law Art. 7; [Kennedys](https://www.kennedyslaw.com/en/thought-leadership/article/2026/egypt-s-personal-data-protection-law-the-compliance-countdown-has-begun/)).
- **Data subject rights** (access, rectification, erasure, restriction,
  objection, withdrawal); the controller replies within **six working days**
  (English translation of the law, [ACC/MBH PDF](https://www.acc.com/sites/default/files/program-materials/upload/Data%20Protection%20Law%20-%20Egypt%20-%20EN%20-%20MBH.PDF);
  PDPC checklist: acknowledgement within 6 working days, [PPC Land, 23 Sep 2026](https://ppc.land/email-marketers-in-egypt-face-3-year-consent-proof-rule-pdpc-checklist-shows/)).
- **Retention:** no longer than the purpose needs (Art. 3); retention per
  activity in the record of processing (15 elements for a controller,
  per the PDPC checklist).
- **Marketing:** direct electronic marketing needs prior consent, opt-out
  and a permit; proof of consent 3 years (Art. 17; PDPC checklist).
- **Penalties** (Law Arts. 35-49, translation): sensitive data without
  consent/licence and unlawful transfer abroad: prison of at least 3 months
  and/or EGP 500,000 to 5 million (Arts. 41, 42); licence violations EGP
  500,000 to 5 million (Art. 45); DPO duties EGP 200,000 to 2 million (Art.
  40); Arts. 4, 5, 7 (incl. breach notice) EGP 300,000 to 3 million (Art.
  38); doubled for repeat; published judgments; settlement possible (Art. 49).

### What the app does today

- Data inventory and retention: `functions/src/privacy/retention.ts`
  (`DATA_TYPES`, `RETENTION`); deletion with the account
  (`functions/src/privacy/account_deletion.ts`, DECISIONS.md "Data after
  account deletion").
- Consents (versioned, append-only, withdrawable):
  `functions/src/auth/consents.ts`, `functions/src/verification/submission.ts`,
  `functions/src/privacy/requests.ts`, `lib/features/auth/legal_documents.dart`.
- Hosting: Firebase / Google Cloud `europe-west1`; processors listed in
  `docs/app-store-privacy.md` section 3 and `hosting/links/privacy.html`.
- Analytics: opt-in (main, review-risks). No marketing messages.

### Changes made in this branch (safe side)

- **Separate explicit consent to storage abroad** (`transferAbroad`,
  required at sign-up, own line and notice; withdrawable = deletion).
- **ID + face (biometric) consent** reworded as explicit; **separate
  guardian declaration** for children's data incl. their location during
  runs, at verification and again when a child is added later
  (`lib/features/verification/verification_flow_screen.dart`,
  `children_screen.dart`).
- **6-working-day deadline** for every privacy request, stored `dueAt`,
  admin queue sorted by urgency with overdue count
  (`functions/src/privacy/requests.ts`, `adminListPrivacyRequests`);
  procedure in `docs/legal/dsr-procedure.md`.
- **Breach runbook** (`docs/legal/breach-runbook.md`), **record of
  processing** (`docs/legal/records-of-processing.md`).
- **Public privacy policy:** legal basis per consent, transfer section with
  countries and Arts. 14-16, DPO contact (`--dpo-email`, `--dpo-name` in
  `tool/links_site.py`), 72 h / 3 working days breach promise, 6 working
  days for requests, sign-in history 180 days.

**Risk: HIGH until the PDPC licences are applied for and a DPO is
appointed** (none of this can be done in code).

## 1A. Breach notification under Law 151 (leak, hack, loss)

### The rule (verified 16 Nov 2026; in force)

- **Status.** Law 151/2020 Art. 7 has applied since the law took effect
  (Oct 2020); the detail is in the Executive Regulations, Ministerial
  Decree No. 816 of 2025, published in the Official Gazette on 1 Nov 2025
  (Issue 244 bis A) and in force from 2 Nov 2025; the one-year
  compliance period ended 31 Oct / 1 Nov 2026 ([Consortio translation of
  the Regulations](https://consortiolawfirm.com/egypt-data-protection-law-executive-regulations-2025-english/);
  [Shehata & Partners translation, Jan 2026](https://shehatalaw.com/wp-content/uploads/2026/01/Shehata-Partners-Publications-Data-Protection-Executive-Regulations-English.pdf);
  [Al Mal News, 26 Oct 2026](https://almalnews.com/2143437/%D8%B3%D9%88%D8%B2%D8%A7%D9%86-%D8%A7%D9%84%D8%B9%D9%82%D8%A8%D8%A7%D9%88%D9%8A-%D9%85%D8%B1%D9%83%D8%B2-%D8%AD%D9%85%D8%A7%D9%8A%D8%A9-%D8%A7%D9%84%D8%A8%D9%8A%D8%A7%D9%86%D8%A7%D8%AA-%D8%A7%D9%84%D8%B4%D8%AE%D8%B5%D9%8A%D8%A9-%D9%8A%D8%A8%D8%AF%D8%A3/)).
- **Who notifies:** the controller and the processor "as the case may be"
  (Decree Art. 5). The law also obliges both to notify (Art. 7). Our
  contracts make each processor notify us; we notify the PDPC and parents.
- **To the PDPC:** within **72 hours of becoming aware**, through the
  PDPC's electronic portal or designated hotline; **immediately** where
  national security is involved (Art. 7; Decree Art. 5). Some briefings
  read the Regulations as also requiring immediate notice for sensitive
  data ([Al Tamimi](https://www.tamimi.com/law_update_articles/from-policy-to-practice-egypt-issues-executive-regulations-of-the-personal-data-protection-law/));
  the translations we read do not say so — **we treat children's and
  biometric data as "immediately" (safe side)**.
- **Contents of the PDPC notice** (Decree Art. 5): date and hour of
  awareness and of the notice; nature of the breach and when it happened,
  with an estimate of the records; likely effects and expected harm;
  urgent measures and corrective actions; the DPO's details; anything else
  the PDPC asks. National security: also the link to it and the volume and
  estimated harm.
- **To data subjects:** within **3 working days of notifying the PDPC**,
  describing the breach and the safeguards taken, by the contact method
  the data subject gave at consent (Decree Art. 5; the law says "three
  days", [ACC/MBH translation](https://www.acc.com/sites/default/files/program-materials/upload/Data%20Protection%20Law%20-%20Egypt%20-%20EN%20-%20MBH.PDF);
  [Kennedys](https://www.kennedyslaw.com/en/thought-leadership/article/2026/egypt-s-personal-data-protection-law-the-compliance-countdown-has-begun/)).
  **No risk threshold:** unlike the GDPR, every breach is notified
  ([Kennedys](https://www.kennedyslaw.com/en/thought-leadership/article/2026/egypt-s-personal-data-protection-law-the-compliance-countdown-has-begun/)).
- **Record:** every notice is logged in a secure electronic register
  created for this purpose (Decree Art. 5); controllers and processors
  must also be able to restore and contain data after an incident (Decree
  Art. 3 Second (4), Art. 4 Second (2)).
- **Processor to controller:** the Regulations put the duty on the
  processor directly and set no separate processor-to-controller deadline.
  Processor contracts (checked 16 Nov 2026): Meta WhatsApp "without undue
  delay" (§3(e), 22 Aug 2025, [WhatsApp](https://www.whatsapp.com/legal/business-data-processing-terms-20210927?lang=en));
  Algolia "without undue delay" (§3.2, 12 Jan 2026, [Algolia](https://www.algolia.com/policies/data-processing-addendum));
  Sentry "promptly and without undue delay" (§4.2, [Sentry DPA](https://sentry.io/legal/dpa/4.0.0/in-app/), v4.0.0; current
  v5.1.0 to check); Google Cloud's Data Processing Addendum (not reachable
  from the workspace; owner to confirm); Valify: not signed (ask for 24
  hours).
- **Penalties:** breach of Art. 7 (with Arts. 4, 5): EGP 300,000 to 3
  million (Art. 38, translation); doubled on repeat; publication of the
  judgment (Art. 48); settlement possible before trial (Art. 49).
- **Anti-Cybercrime Law 175/2018 interplay** ([Andersen translation](https://eg.andersen.com/wp-content/uploads/2025/06/Law-No.-175-of-2018-Concerning-Information-Technology-Crimes.pdf)):
  the person who actually manages a legal entity must **report a crime
  committed against its site, account or information system to the
  competent authorities on becoming aware** (Art. 35: at least 3 months
  and/or EGP 30,000-100,000); tampering with or hiding digital evidence to
  obstruct the authorities is a crime (Art. 28); a manager whose negligent
  security exposes the system is punishable (Art. 29); investigators may
  order data preserved and handed over (Art. 6; refusal Art. 32); service
  providers keep logs 180 days and disclose only on a judicial order (Art.
  2). So: report to the PDPC **and**, if it is a crime, to the authorities;
  preserve logs before cleaning up.

### What the app does today (this branch)

- **Breach register:** `breachRegister/{id}`, written only by audited
  admin callables `adminReportIncident`, `adminUpdateIncident`,
  `adminListIncidents` (`functions/src/privacy/breaches.ts`,
  `breach_callables.ts`; tests `functions/test/breaches.test.ts`); rules
  deny every client, admins included (`firestore.rules`, test in
  `tests/rules/admin.test.ts`). Each step is append-only; notice times are
  set once; parents only after the PDPC; closing only after both.
- **Admin panel > Incidents:** "Report incident" starts the clock (choose
  when we found out), shows "Tell the Centre by" (or "Immediately") and
  "Tell parents by" with On time / Due soon / Late / Now badges
  (`lib/admin/screens/incidents_screen.dart`).
- **Legal runbook** with the hour-0-to-72 timeline, Arabic PDPC and parent
  templates and the register format: `docs/legal/breach-runbook.md`;
  `SECURITY.md` section 3 links to it (the security branch's
  `docs/security/runbook.md` already does).
- Public privacy policy promises PDPC within 72 hours and parents within 3
  working days.

**Risk: MEDIUM** until the DPO is named and each processor's security
notice goes to a mailbox the DPO reads (owner actions 3 and 10). Lawyer
questions 1.10-1.12.

## 2. Law No. 87 of 2018 (land passenger transport using IT) and traffic/insurance

### The rule

- Art. 1 defines the **service** as "land passenger transport by private
  vehicles or collective transport means, using information technology";
  **no fare or consideration appears in the definition**; vehicles are
  those the Prime Minister designates. Art. 2: making the service available
  or providing it needs a licence; the PM sets fare controls. Art. 10:
  licensees keep data 180 days and give it to authorities. Art. 15:
  providing the service without a licence, permit or card: EGP 200,000 to
  5 million; Art. 16 drivers EGP 5,000 to 20,000 (text: [Law 87/2018](https://ahmedazimelgamel.blogspot.com/2018/06/87-2018.html);
  [Manshurat](https://manshurat.org/node/26579); Executive Regulations by
  PM decree, issued 18 Sep 2019, [Manshurat](https://manshurat.org/content/lqwd-wljrt-llzm-lttbyq-hkm-qnwn-tnzym-khdmt-lnql-lbry-llrkb-bstkhdm-tknwlwjy-lmlwmt-rqm-87)
  — the regulation text itself was not readable here).
- **Where the line is (analysis, not a ruling):** the law targets companies
  that "make available or provide" passenger transport through an app
  (Uber/Careem model). A literal reading could reach any app that matches
  riders and private cars, even without a fare. The factors that point
  away from it: no payment of any kind, no platform fee, no driver for
  hire, closed groups of parents of the same school who know each other,
  no rides for strangers or adults, the parent drives their own children
  too. Any compensation (fare, per-child amount, fuel per run or km, a
  platform cut) moves the app toward the law.
- **Traffic:** a vehicle used for a purpose other than the one on its
  licence can have its licence cancelled (30 days, longer if repeated)
  ([Parlmany, 3 Dec 2025](https://www.parlmany.com/News/7/592090/12-%D8%AD%D8%A7%D9%84%D8%A9-%D9%84%D9%85%D8%AE%D8%A7%D9%84%D9%81%D8%A7%D8%AA-%D9%85%D8%B1%D9%88%D8%B1%D9%8A%D8%A9-%D8%AA%D8%B3%D8%AD%D8%A8-%D9%81%D9%8A%D9%87%D8%A7-%D8%A7%D9%84%D8%B1%D8%AE%D8%B5%D8%A9-%D9%85%D9%86-%D8%A7%D9%84%D8%B3%D8%A7%D8%A6%D9%82-%D8%AA%D8%B9%D8%B1%D9%81)).
  The traffic-law amendments were withdrawn on 3 Feb 2026 for a new
  comprehensive bill ([Ahram Online](https://english.ahram.org.eg/News/561676.aspx)).
- **Insurance:** the Unified Insurance Law No. 155 of 2024 repealed Law
  72/2007; compulsory motor cover is civil liability for death and bodily
  injury (EGP 100,000 for death or permanent total disability; property
  EGP 20,000; Arts. 40, 47), and the insurer may **recover from the insured
  if the vehicle was used for purposes not authorised by the licence**
  (Art. 56) ([Law 155/2024, Andersen translation](https://eg.andersen.com/wp-content/uploads/2026/02/Law-No.-155-of-2024.pdf)).
  Paid rides in a private car risk both.

### What the app does today (after this branch)

- **No money in the app** (owner decision 16 Nov 2026, DECISIONS.md): the
  wallet, Settle up and the per-child contribution are switched off in
  every environment (`functions/src/features/model.ts` `PILOT_DEFAULTS`,
  `lib/features/feature_switches/feature_switches.dart`); the server refuses
  them; the app shows no money UI.
- **Volunteer acknowledgement** at create/join (`VOLUNTEER_TERMS_VERSION`
  in `functions/src/carpools/model.ts`, ARB `volunteerAccept*`).
- Carpools are per school (school carpools tie children to the school);
  verified parents only; **activity carpools** (F39) are found by
  distance, not school — see question 2.4.
- Terms: "not a passenger transport service within the meaning of Law No.
  87 of 2018", no paid rides, no non-members, compulsory insurance and
  optional cover advice (`hosting/links/terms.html`, ARB `termsTermsText`).

**Risk: MEDIUM.** Keep every money feature off. Before turning anything on,
get the lawyer's written opinion.

## 3. Child protection

- **Child Law No. 12 of 1996 (amended by Law 126 of 2008), Art. 96**: a
  child is "at risk" when their safety is endangered, incl. at school or in
  care; exposing a child to such risk: at least 6 months' prison and/or EGP
  2,000-5,000 ([Masrawy, 29 Jul 2026](https://www.masrawy.com/news/news_egypt/details/2026/7/29/3024876/15-%D8%AD%D8%A7%D9%84%D8%A9-%D8%A7%D8%B9%D8%B1%D9%81-%D8%A7%D9%84%D8%B9%D9%82%D9%88%D8%A8%D8%A9-%D8%A7%D9%84%D9%82%D8%A7%D9%86%D9%88%D9%86%D9%8A%D8%A9-%D9%84%D8%AA%D8%B9%D8%B1%D9%8A%D8%B6-%D8%B7%D9%81%D9%84-%D9%84%D9%84%D8%AE%D8%B7%D8%B1)).
- **Ministry of Education school-transport rules:** no Egyptian rule on
  parents carrying other parents' children in private cars was found
  (searches returned Gulf rules only). Ask the lawyer and the pilot school
  (question 3.1).
- App today: ID-verified parents, driver licence and car checks, seat
  limits, seat-belt rule in the conduct text, live location for the
  children's parents, emergency button (not a 122/123 replacement),
  reports and suspension. **Risk: LOW-MEDIUM** (depends on parents' real
  behaviour; terms now also mention child seats and seat limits).

## 4. Anti-Cybercrime Law No. 175 of 2018; Telecom Law No. 10 of 2003

- **Law 175/2018:** a "service provider" is any natural or legal person
  providing ICT services to users, incl. processing or storing data for
  them; Art. 2 obliges it to keep information-system logs (user identity,
  traffic data, device) for **180 continuous days**, keep them confidential
  and disclose only on a judicial order; Art. 33: EGP 5-10 million. Arts.
  25-26 punish privacy violations and misuse of others' personal data in
  content ([Andersen translation](https://eg.andersen.com/wp-content/uploads/2025/06/Law-No.-175-of-2018-Concerning-Information-Technology-Crimes.pdf)).
- **App today / change:** sign-in history (`users/{uid}/logins`: device,
  platform, time) now kept **180 days** (`LOGIN_HISTORY_DAYS`), but it is
  still **deleted with the account** (owner decision 16 Nov 2026) — question
  4.2. Cloud Functions/Cloud Logging default retention is 30 days (Google
  default; check) — owner action 9. Chat moderation (reports, removal) helps
  with Arts. 25-26. **Risk: MEDIUM** (scope unclear).
- **Law 10/2003:** licences are for telecom networks/services; Art. 73
  covers people working in telecoms ([NTRA](https://tra.gov.eg/rules/law-no-10-of-2003)).
  The app is not a telecom operator; WhatsApp is Meta's licensed channel;
  there is no SMS. **Risk: LOW.** NTRA rules on A2P messaging through local
  operators would matter only if the on-hold SMS backup is revived.

## 5. Consumer Protection Law No. 181 of 2018; terms and Arabic

- Art. 5: documents, invoices and **contracts, incl. electronic ones, must
  be in Arabic**; other languages allowed in addition. Art. 28: a clause
  that reduces or exempts the supplier's legal obligations is void.
  Chapter 3 (Arts. 36-41) covers distance contracts. The definitions do not
  require a price ([Andersen translation](https://eg.andersen.com/wp-content/uploads/2025/07/Law-No.-181-of-2018.pdf)).
  Whether a free, non-profit app is a "supplier" is unclear (question 5.1).
- **Civil law on liability:** tort liability is public policy and cannot be
  waived in advance; contractual liability can be limited except for fraud
  or gross negligence ([Mondaq](https://www.mondaq.com/contracts-and-commercial-law/980060/liability-under-egyptian-law)).
- **Changes:** the Arabic text of terms and privacy policy is the governing
  text; the liability clause no longer tries to exclude fraud, gross
  negligence or harm to persons; the in-app terms say the same.
  **Risk: LOW** after the lawyer approves the wording.

## 6. Payments: CBE Law No. 194 of 2020

- Payment services, e-money and payment initiation / account information
  are licensed by the CBE under Law 194/2020 and the June 2025 licensing
  rules ([Andersen, Mar 2026](https://eg.andersen.com/electronic-money-institution-licensing-egypt/);
  [Baker McKenzie](https://insightplus.bakermckenzie.com/bm/banking-finance_1/egypt-new-regulation-on-payment-solutions)).
- **Today:** all money features are off; the earlier lawyer view that Settle
  up (records + showing an InstaPay address) needs no CBE licence is
  recorded (DECISIONS.md 14 Nov 17:28) but is now moot. Crossing the line:
  holding or moving money, initiating payments, a wallet, collecting money
  for others, or reading bank accounts. **Risk: LOW** while off.

## 7. Tax, company, operating entity

- The PDPL puts the DPO duty on the **legal representative of a legal
  person**, and licence applications go through an identified applicant on
  Digital Egypt (section 1). Apple's Organization account needs a legal
  entity (D-U-N-S number; check on developer.apple.com). A free app with no
  revenue may not create a tax event, but a company must still register
  for tax. No authoritative source on "free app run by an individual" was
  found. **Risk: MEDIUM.** Recommendation: a small company (e.g. a
  single-member LLC, or an NGO/foundation if the non-profit model stays) as
  controller, owner of the Apple and Google accounts, PDPC licensee and
  employer of the DPO (questions 7.1-7.3).

## 8. ID verification (national ID images, number, selfie)

- No rule found that forbids a private controller from collecting an ID
  copy with consent; Civil Status Law No. 143 of 1994 protects the civil
  registry's own data ([Andersen](https://eg.andersen.com/translation-of-law-no-143-of-1994/)).
  The selfie used for face matching is **biometric = sensitive** (Law
  151 Art. 1). Valify is a processor: a written processing agreement and,
  if it is the PDPC-licensed party for e-KYC, its licence details.
- **Today:** ID number stored only as a keyed hash + expiry; images in a
  private KMS-encrypted bucket, admin access with a logged reason, deleted
  with the account; explicit consent (now biometric wording). **Risk:
  MEDIUM** (sensitive-data licence pending).

## 9. Emergencies and liability for incidents

- The emergency button only alerts the carpool and the emergency contact,
  and the terms say to call 122/123. Parents drive their own cars; the app
  does not choose drivers. Liability: the parent driving is liable in tort;
  the app's exposure is mainly negligent verification or a failure of a
  promised safety feature. The terms no longer try to exclude what Egyptian
  law does not allow. **Risk: MEDIUM** (cannot be removed by terms).
- Safe side: do not market safety features as guarantees; keep the "does
  not replace 122/123" text; keep records of checks; recommend
  passenger personal-accident cover to parents.

## 10. Retention reconciliation

| Data | Our rule (retention.ts / DECISIONS) | Legal pull | Status |
| --- | --- | --- | --- |
| Sign-in history | 180 days, deleted with the account | Law 175 Art. 2: 180 days | **Lawyer question 4.2** |
| Consent records | 1 year after closure | Proof of consent; criminal limitation for misdemeanours is usually 3 years; PDPC checklist keeps marketing consent 3 years | **Lawyer question 1.6** (longer retention needs the lawyer per DECISIONS.md) |
| Privacy requests | 3 years | Proof of answer | OK |
| Live location | 24 h; route archive up to 1 year (deleted with the driver's account) | Purpose limitation | OK, lawyer confirmed periods |
| Photos | While open; deleted with the account (30-day safety hold) | Purpose limitation | OK |
| Law 87 Art. 10 (180-day trip data) | Not applicable unless the app is a licensee | — | OK |

## 11. Conflicts with earlier decisions (flagged, NOT changed)

1. **DECISIONS.md "Legal (14 Nov 2026)" item 2 ("operating entity and
   licence")** and item 3 ("hosting abroad"): the confirmations predate or
   do not mention the PDPC licence regime that became enforceable on
   1 Nov 2026 (controller licence, sensitive-data licence, transfer licence,
   DPO). Open item B5 still says "DPO and PDPC licence: owner with the
   lawyer". **Ask the lawyer to confirm in writing which licences are
   needed and that the app may run before the PDPC decides** (90 working
   days).
2. **Item 4 (IDs and children's data with the consent screens):** the law
   asks for explicit **written** consent and a licence for sensitive data;
   we added separate consents, but whether a tick box counts as written
   consent is for the lawyer (question 1.4).
3. **Emergency-contact WhatsApp without that person's opt-in (15 Nov
   2026):** under the PDPL the contact is a data subject too; a likely
   basis is the parent's consent plus vital interests. Decision kept;
   lawyer to confirm the basis in writing (question 1.8).
4. **Deletion of sign-in history with the account (16 Nov 2026)** vs.
   Cybercrime Law Art. 2 (180 days): kept as decided; question 4.2.
5. **Settle up "no CBE licence" (14 Nov 2026):** still recorded, now moot
   because the owner switched every money feature off (16 Nov 2026).

## 12. Questions for the owner's lawyer

1.1 Which PDPC licences/permits does the controller need (controller,
sensitive data: children + biometrics, cross-border transfer), what does
each cost for our expected number of records, and can a small database be
exempt?
1.2 May we run the pilot with real parents after filing but before the
PDPC decides (90 working days, silence = refusal)?
1.3 Who must be the DPO (employee of the company? external?), and what
are the PDPC exam/registration steps?
1.4 Is an in-app tick box with a stored version and time "explicit written
consent" for sensitive data (Art. 12), or do we need an electronic
signature (Law 15/2004) or a different flow?
1.5 Are our processors' locations acceptable (Google Cloud Belgium; Meta,
Algolia, Sentry, Google services possibly in the US)? Which countries
does the PDPC treat as adequate? Do we need transfer clauses with each?
1.6 May we keep consent records 3 years after account closure as proof
(we keep 1 year now)?
1.7 For children aged 15-18 (secondary school), is the parent's consent
enough, or must the child also consent?
1.8 Confirm the legal basis for the emergency contact's phone number and
WhatsApp alert without their opt-in.
1.9 Is the live location of a car carrying children "tracking of
children" that needs extra safeguards under the Regulations?
1.10 Breaches: does the PDPC require immediate notice for sensitive data
(children, biometrics), as some briefings say? Which authority receives a
crime report under Law 175 Art. 35 (Public Prosecution, the Ministry of
Interior's unit)? Do both duties apply to a test/staging incident with
fake data only?
1.11 How long must the breach register be kept?
1.12 What must our processor contracts say about breach notice (hours,
content, cooperation) to satisfy Decree 816/2025 Art. 5?
2.1 Does a free, closed parent carpool app fall outside Law 87/2018? Please
give a written opinion that names the facts relied on (no money, same
school, verified parents, own cars, no platform fee).
2.2 Would any future cost sharing (e.g. fuel) bring it under Law 87 or
the insurance recourse in Law 155/2024 Art. 56? Is there any amount that is
safe?
2.3 Is carrying other parents' children free of charge in a private car
covered by the compulsory insurance, and could the insurer claim recourse?
2.4 Do activity carpools (by distance, not school) change the answer?
3.1 Are there Ministry of Education or school rules about parents
transporting other pupils? Should we get the pilot school's written
consent?
4.1 Is the app a "service provider" under Law 175/2018 Art. 2?
4.2 If yes: must we keep sign-in logs 180 days **after** an account is
deleted (we delete them with the account), and which fields exactly?
5.1 Does Consumer Protection Law 181/2018 apply to a free, non-profit
app? Is our Arabic-prevails clause enough for Art. 5?
5.2 Approve the final Arabic terms, privacy policy, code of conduct and
liability clause.
6.1 Before any money feature returns: written CBE opinion on the exact
design.
7.1 Which entity should run the app (LLC, sole proprietorship, NGO /
foundation)? Commercial register and tax card needed for a free app?
7.2 Is the app's name or "school" wording restricted in any way?
7.3 Who signs the processor agreements (Google, Meta, Valify, Algolia,
Sentry, email provider)?
8.1 Any limit on collecting national ID images and numbers from private
apps (Civil Status Law 143/1994)?
8.2 Valify: is it licensed by the PDPC (and the CBE/NTRA for e-KYC), and
what must our contract with it say?
9.1 Is our liability clause enforceable as now written? What else should
the terms say about incidents during a run?

## 13. What was not done or not checked

- The official Arabic texts (Official Gazette) and pdpc.gov.eg were not
  opened (not reachable from the workspace); sources are briefings and
  translations.
- No Ministry of Education school-transport rule was found.
- No authoritative source on tax/company duties of a free app.
- The admin panel screen for the privacy queue is not built (open item
  D13); the server queue exists.
- Existing parents who accepted older documents are not forced to accept
  the new transfer consent (open item B2) — recommended: ask them once.
