# Personal data breach: legal runbook (hour 0 to 72 and after)

The **legal timeline** for any leak, hack, loss or unauthorised access to
personal data. The technical side (containment, key rotation, restore) is in
the security runbook (`docs/security/runbook.md` on the security branch,
`SECURITY.md` section 3), **which links here for every legal step**. The
legal basis and sources are in `docs/legal/egypt-legal-review.md`, section
"Breach notification under Law 151". Not legal advice: the DPO and the
lawyer adapt it. Checked 16 Nov 2026.

## The rule in five lines

1. **Who:** the controller (us) and, "as the case may be", the processor
   (Decree 816/2025, Art. 5). In practice we notify; a processor tells us.
2. **PDPC:** within **72 hours of becoming aware**, through the PDPC portal
   or its hotline (Law Art. 7; Decree Art. 5). **Immediately** if national
   security may be involved. **Our rule (safe side): immediately also when
   children's data or face (biometric) data is involved.**
3. **Parents:** within **3 working days of notifying the PDPC**, by the
   channel agreed at sign-up (in-app notice and WhatsApp/email), saying
   what happened and the safeguards taken. **There is no "low risk"
   exception** in the Egyptian text: every breach of personal data counts.
4. **Register:** every notice is recorded in a secure electronic register
   (Decree Art. 5) — ours is the admin panel's **Incidents** page
   (`breachRegister`, audited, closed to every client).
5. **Crimes:** if the breach is a crime (hack, theft), the manager of the
   legal entity must report it to the competent authorities when aware
   (Anti-Cybercrime Law 175/2018, Art. 35) and must not touch the evidence
   (Art. 28).

## Timeline

Hour 0 = the moment **anyone on the team** (or a processor's notice
reaching us) knows that personal data may have been exposed. Do not wait
for certainty: the clock starts at awareness.

| When | Who | What |
| --- | --- | --- |
| 0 h | Whoever finds it | Tell the incident lead (owner) and the DPO by phone. Open the admin panel > **Incidents > Report incident**, choose "When did we find out?". This starts the clock and shows both deadlines. |
| 0-2 h | Technical lead | Contain (security runbook): revoke keys, sessions, disable the function or rule. **Preserve evidence** before changing anything: export Cloud Logging, the `auditLog`, Sentry events, the processor's notice (Law 175 Arts. 6, 28). Record "Contained" on the incident. |
| 0-2 h | DPO | If children's or face data, or national security: **notify the PDPC now** with what is known (template A) and add the rest later. |
| 2-24 h | DPO + technical lead | Assess: data categories, about how many people and records, when it happened, cause, still exposed? Update the incident (note). |
| ≤ 24 h | Incident lead + lawyer | Crime? (hack, insider theft, extortion): report to the competent authority (Public Prosecution / the Ministry of Interior's cybercrime unit; the lawyer chooses) — Law 175 Art. 35. Keep the report number. |
| ≤ 48 h | DPO + lawyer | Draft the PDPC notice (template A) and the parents' notice (template B). |
| **≤ 72 h** | DPO | **Notify the PDPC** (portal or hotline). Record "Centre told" with the reference: this starts the parents' clock. Unknown facts: say so and promise a follow-up. |
| ≤ 3 working days after the PDPC notice | Incident lead | **Tell every affected parent** (template B) in Arabic and English, by in-app notification plus WhatsApp or email. Record "Parents told". |
| Processor breach | DPO | Ask the processor for its written report (its contract promises notice "without undue delay"; see below); keep it with the incident. The 72 hours start when **we** become aware. |
| After | All | Root cause, fix with tests, update `records-of-processing.md`; record "Close". The register entry stays. |

Working days: Sunday to Thursday (Cairo). Count public holidays as working
days (the earlier deadline is the safe one).

## What the PDPC notice must contain (Decree 816/2025, Art. 5)

1. Date and hour we became aware, and the time of this notice.
2. Nature of the breach and when it happened, with an estimate of the
   records affected.
3. Likely effects and expected harm.
4. Urgent measures and corrective actions taken.
5. The DPO's details.
6. Anything else the PDPC asks for.
National security: also the link to national security and the volume of
data with an estimate of the harm.

### Template A — إخطار مركز حماية البيانات الشخصية

> **إلى:** مركز حماية البيانات الشخصية
> **الموضوع:** إخطار بخرق بيانات شخصية وفقًا للمادة 7 من القانون رقم 151 لسنة 2020 والمادة 5 من اللائحة التنفيذية
> **المتحكم:** ‹الاسم القانوني› — رقم الترخيص: ‹›
> **مسؤول حماية البيانات:** ‹الاسم›، كود المسؤول ‹›، الهاتف ‹›، البريد ‹›
>
> 1. **تاريخ وساعة العلم بالخرق:** ‹› — **تاريخ وساعة هذا الإخطار:** ‹›
> 2. **طبيعة الخرق ووقت حدوثه:** ‹دخول غير مصرّح / كشف / فقد / تغيير / تعذّر الوصول› وقع في ‹› تقريبًا. البيانات المتأثرة: ‹الفئات›. العدد التقريبي: ‹› سجلًا لنحو ‹› شخصًا، منهم ‹› طفلًا.
> 3. **الآثار المحتملة والضرر المتوقع:** ‹›
> 4. **الإجراءات العاجلة والتصحيحية:** ‹احتواء، تغيير المفاتيح، إيقاف الخدمة، إبلاغ الجهة المعالجة…›
> 5. **ما لم يُعرف بعد:** ‹› وسنوافيكم به فور معرفته.
> 6. **الأمن القومي:** ‹لا يوجد ما يشير إلى ذلك / يوجد، والبيان كالتالي›.
>
> مرفقات: ‹سجل الحادثة›.

### Template B — رسالة إلى أولياء الأمور (عربي، ثم English)

> **عنوان:** تنبيه مهم بخصوص بياناتك في «مشوار المدرسة»
>
> في ‹التاريخ› علمنا بـ‹وصف بسيط لما حدث›. شمل ذلك ‹البيانات›. لم يشمل ‹ما لم يتأثر›.
> ما فعلناه: ‹الإجراءات›. وقد أبلغنا مركز حماية البيانات الشخصية.
> ما ننصحك به: ‹مثلًا: لا تعطِ رمز الدخول لأي شخص، تجاهل الرسائل التي تطلب الرمز، راجع «هواتفي» في التطبيق›.
> للاستفسار: مسؤول حماية البيانات ‹البريد›.

> **Subject:** Important notice about your data in School Carpool
>
> On ‹date› we learned that ‹plain description›. It affected ‹data›. It did
> not affect ‹what was not affected›. What we did: ‹measures›. We have
> informed Egypt's Personal Data Protection Centre. What we advise:
> ‹advice›. Questions: our data protection officer, ‹email›.

## Breach register format (`breachRegister/{id}`, admin panel > Incidents)

| Field | Meaning |
| --- | --- |
| `awareAtMs` | When we became aware (clock start) |
| `occurredAtMs` | When it happened (if known) |
| `reportedAtMs`, `reportedBy` | When and by which admin it was entered |
| `kind` | unauthorisedAccess, disclosure, loss, alteration, unavailable, other |
| `categories` | account, contact, idImages, biometric, children, location, home, chat, devices, other |
| `sensitive` | children or biometric involved (immediate notice) |
| `source` | us, google, meta, algolia, sentry, valify, email, stream, other |
| `approxRecords`, `approxPeople` | Estimates |
| `nationalSecurity` | true / false |
| `summary`, `effects`, `measures` | Admin's words, **no personal data** |
| `pdpcDueAtMs`, `immediate` | The PDPC deadline |
| `pdpcNotifiedAtMs`, `pdpcReference` | When the PDPC was told, its reference (set once) |
| `subjectsNotifiedAtMs` | When parents were told (set once, after the PDPC) |
| `status` | open, pdpcNotified, subjectsNotified, closed |
| `retainUntilMs` | R7: closing date + 5 years; the entry is kept at least until then |
| `events` | Every step: reported, contained, pdpcNotified, subjectsNotified, note, closed, with time and admin |

Every report and step also writes an `auditLog` entry (`breach.*`) in the
same batch. Nothing is deleted. **Retention (R7, owner decision 16 Nov
2026): each entry is kept 5 years after the incident is closed**
(`BREACH_REGISTER_YEARS`; `retainUntilMs` is set when "Close" is
recorded). Reason (answers.md 1.11): the law sets no period; breach-notice
offences are misdemeanours (3-year limitation from the last act, and an
incident may be found late), PDPC inspections, and the 3-year licence
renewal cycle. It holds no parent's data. No job deletes entries yet; one
may be added after the first 5 years with the owner's go.

## Processors: what they promise us (checked 16 Nov 2026)

| Processor | Their notice to us | Source |
| --- | --- | --- |
| Google Cloud / Firebase | "promptly and without undue delay" (Cloud Data Processing Addendum, "Data Incidents") — page not reachable from the workspace; **owner to confirm** in the console | cloud.google.com/terms/data-processing-addendum |
| Meta (WhatsApp Business) | "without undue delay" after discovery (Business Data Processing Terms §3(e), updated 22 Aug 2025) | [WhatsApp](https://www.whatsapp.com/legal/business-data-processing-terms-20210927?lang=en) |
| Algolia | "without undue delay" (DPA §3.2, updated 12 Jan 2026) | [Algolia DPA](https://www.algolia.com/policies/data-processing-addendum) |
| Sentry | "promptly and without undue delay" to the notification email (DPA §4.2; v4.0.0 seen, current v5.1.0 to check) | [Sentry DPA](https://sentry.io/legal/dpa/4.0.0/in-app/) |
| Valify | Contract not signed yet: **require notice within 24 hours** and cooperation with the PDPC notice | owner action |
| Email provider, Stream | Check their DPA; set the notification email | owner action |

**Owner:** set each service's security/notification email to an address the
DPO reads (Google Cloud Essential Contacts "Security" and "Legal", Sentry
notification email, Meta Business security contact, Algolia). "Without undue
delay" is not a fixed number of hours; our 72 hours run from when we know,
so watch those mailboxes.

## Penalties for getting it wrong

- Failing the breach duty (Law Art. 7): fine EGP 300,000 to 3 million (Art.
  38, per the English translation); doubled for a repeat; the judgment may be
  published (Art. 48).
- Sensitive data handled without the safeguards: up to EGP 5 million and
  prison (Art. 41).
- Not reporting a crime against our system (Law 175/2018 Art. 35): at least
  3 months' prison and/or EGP 30,000 to 100,000; hiding or tampering with
  evidence (Art. 28): at least 6 months and/or EGP 20,000 to 200,000;
  negligent security that exposes the system (Art. 29).
