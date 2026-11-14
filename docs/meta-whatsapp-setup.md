# Meta and WhatsApp setup: owner guide

For the owner, no coding needed. Written 14 Nov 2026; every fact taken from
Meta's pages has a link in section 13 with the date it was read. Meta
changes its screens often: if a button has a different name, look for the
closest one and tell the developer so this guide can be corrected.

> **DO THIS FIRST (business verification is the slowest item of the whole launch)**
> 1. Today: create the Meta Business portfolio in the legal name of the operating entity (step A).
> 2. Today: scan the entity's registration and tax documents, and one document showing its address or phone (step B.2).
> 3. Today: press **Start verification** and upload them (step B). Meta's answer can take from a few days to about two weeks, longer if they ask for more.
> 4. While you wait: get the phone number (step D.1) and do steps C to G; almost nothing else needs the verification to be finished.
> 5. Never put the access token in a chat, an email or the repository. It goes only into Secret Manager (step I).

## 1. What this is for

The app sends two kinds of WhatsApp messages, both from Cloud Functions:

- the **sign-in code** (template `login_code`), to every parent, every sign-in;
- a few **urgent alerts** (no driver, drop-off not confirmed, car outside,
  location stopped, emergency). All other notifications are push only unless
  a parent switches WhatsApp on for them (cost rule).

Until this guide is finished, staging and dev use a fake sender that sends
nothing, and **prod cannot send a sign-in code at all** (the fake sender is
refused in prod). So the pilot waits for steps A to I.

## 2. What you end with, and where each value goes

| Value | What it looks like | Where it goes | Secret? |
| --- | --- | --- | --- |
| Access token of the system user | a very long text starting with `EAA...` | Google **Secret Manager**, secret name `WHATSAPP_ACCESS_TOKEN`, in the **prod** Firebase project (step I). Nowhere else | **Yes** |
| Phone number ID | a number of about 15 digits (this is NOT the phone number) | `functions/.env.prod`, key `WHATSAPP_PHONE_NUMBER_ID` (the developer commits it) | No |
| WhatsApp Business Account ID | a number of about 15 digits | Keep it in your notes; the code does not use it | No |
| Template names and languages | `login_code`, `cp_...`; Arabic `ar`, English `en` | Already in the code. `functions/.env.prod` has `WHATSAPP_CODE_TEMPLATE=login_code`, `WHATSAPP_TEMPLATE_LANG_AR=ar`, `WHATSAPP_TEMPLATE_LANG_EN=en`. Change them only if you had to pick other names or languages at Meta | No |
| Provider switch | `WHATSAPP_PROVIDER=meta` | Already set in `functions/.env.prod`. Staging stays `fake` unless you want real messages there | No |
| API version | `WHATSAPP_API_VERSION=v25.0` | Already set. The developer raises it when Meta retires a version | No |

You may send the developer the **phone number ID** and the **WhatsApp
Business Account ID** by chat. **Never the token.**

## 3. Have these ready

1. A Facebook account in your own real name, with two-factor authentication
   on (Meta asks for it on business accounts).
2. The operating entity's legal papers (step B.2). The name on them is the
   name you type everywhere below, letter for letter.
3. A website or a public page that shows the entity's name and what the app
   does (a one-page site is enough). Reviewers compare it with the display
   name and the documents.
4. A business email on that website's domain if possible
   (for example `info@your-domain`), not a Gmail address.
5. A phone number that has **never been opened in WhatsApp or WhatsApp
   Business**, able to receive an SMS or a voice call (step D.1).
6. A bank card that works for international online payments in US dollars
   (step E).

## A. Create the Business portfolio (10 minutes)

1. Open **business.facebook.com** and sign in with your Facebook account.
2. Click **Create a business portfolio** (older screens say "Create
   account").
3. **Business portfolio name:** the legal name of the operating entity,
   exactly as on its registration document.
4. Your name and the business email. Click **Create**, then confirm the
   email Meta sends.
5. Click the **gear (Settings)** > **Business info** (older screens:
   "Business details"). Fill in the legal name, the address and phone
   **exactly as on the documents**, and the website. Country: **Egypt**.
   Save.
6. Settings > **People**: add a second person you trust as an admin with
   full control. If your own Facebook account is ever locked, this is the
   only way back in.

## B. Business verification (start today; Meta's part takes days to weeks)

### B.1 Start

1. In the portfolio: **Settings** > **Security Centre** (US spelling:
   Security Center).
2. Under **Business verification** click **Start verification**. If the
   button is grey, Meta wants something first; the usual reasons are that
   no app is linked to the portfolio yet (do step C, then come back) or
   that the business details in A.5 are incomplete.
3. Choose the country (Egypt), then pick your organisation from Meta's list
   if it appears, or choose that it is not listed and type the details by
   hand, exactly as in A.5.
4. Upload the documents (B.2).
5. Choose how Meta confirms that you can be reached: a code to the business
   email, a code by phone, or domain verification. Use the email on your
   own domain when you have one.
6. Submit. The status in Security Centre changes to "In review".

### B.2 Documents

Meta asks for documents that prove two things: the **legal name**, and the
**address or phone number**. According to Meta's list as summarised by a
third party (we could not open Meta's own help page from the build
workspace; see section 12), the accepted kinds are:

| Proves | Kind of document Meta accepts | The usual Egyptian document (our reading, confirm on Meta's page) |
| --- | --- | --- |
| Legal name | Business registration or licence | Commercial register extract (مستخرج السجل التجاري), recent |
| Legal name | Certificate or articles of incorporation | Company contract / articles (عقد الشركة) as published |
| Legal name | Government-issued business tax document (not one you filed yourself) | Tax card (البطاقة الضريبية) or VAT registration certificate |
| Legal name | Business bank statement | Statement of the entity's bank account |
| Address or phone only | Utility bill | Electricity, landline or internet bill in the entity's name |

Rules that decide most rejections:

- The name and address typed in A.5 must match the documents **exactly**.
- Documents must be current (not expired) and issued by an authority.
- One clear scan per document, all four corners visible, nothing cut off.
- Meta accepts documents in a list of languages. We could not confirm from
  here that Arabic is on that list. If the upload screen does not offer
  Arabic, attach a certified English translation (translation office stamp).
- The entity must be a registered business. A personal ID alone is not
  accepted for this verification.

### B.3 Waiting, and if it is refused

- **Typical time:** a few working days when everything matches; the figure
  quoted for Meta's review is **up to 14 working days**, and each request
  for more documents starts the wait again. Plan for **2 to 4 weeks** in
  total. (Timing is from a third-party summary and from experience
  reports, not from a Meta page we could open.)
- Meta emails the result and shows it in Security Centre.
- **Refused:** read the reason in Security Centre, correct the details in
  A.5 or upload a different document, and submit again. Do not create a
  second portfolio: that slows things down.
- **Stuck for more than two weeks with no message:** open a case from
  business.facebook.com/business/help (Contact support), and tell the
  coordinator, because the fallback for sign-in codes (SMS) is on hold and
  would need an owner decision (docs/DECISIONS.md, "Improvements,
  revised", item 6).

### B.4 What works before verification is finished

From Meta's developer pages (section 13): a new portfolio can register
**2 phone numbers**, keep **250 templates**, and message **250 different
people in any 24 hours**. That is enough to do steps C to I and to test
with real phones. Verification is what lifts the 250-people limit (step 10).

## C. Create the Meta app with WhatsApp (15 minutes)

1. Open **developers.facebook.com** > **My Apps** > **Create App**. (The
   first time, Meta asks you to register as a developer: accept.)
2. App name: for example `School Carpool`. Contact email: the business
   email.
3. Use case: **Connect with customers through WhatsApp** > **Next**.
4. Business portfolio: choose the one from step A > **Next** > **Create
   app**.
5. You land on **Connect on WhatsApp > Quickstart**. Click **Start using
   the API**. The **API Setup** page opens.
6. On API Setup, under the account drop-down: choose the existing WhatsApp
   Business Account, or click **Create a WhatsApp Business Account** and
   follow the screens.
7. Write down the **WhatsApp Business Account ID** shown on this page.

Meta gives you a test phone number here. Ignore it for the app: it can
only message a few numbers you type in by hand.

## D. The phone number and the display name

### D.1 Choose the number

Meta's rules for the number (section 13): you own it, it has a country and
area code (no short codes), it can receive an SMS or a voice call, and it
is **not in use on WhatsApp**. A number that was ever opened in the WhatsApp
or WhatsApp Business app must have that WhatsApp account deleted first
(in the app: Settings > Account > Delete account), and after registration
it can no longer be used in the WhatsApp app on a phone.

Practical advice: buy a **new SIM or a landline in the entity's name** and
never install WhatsApp with it. Keep the SIM active (top it up), because
losing the number means losing the sender.

### D.2 Add it

1. developers.facebook.com > your app > **WhatsApp > API Setup** > in the
   **From** drop-down click **Add phone number**. (Same thing from
   business.facebook.com > **WhatsApp Manager** > **Account tools** >
   **Phone numbers** > **Add phone number**.)
2. **Display name:** the name parents will see at the top of the chat. Use
   the app or entity name exactly as on your website, for example
   `School Carpool`. No slogans, no "Egypt", no all capitals, no extra
   punctuation. Category: pick the closest (for example "Other" or
   "Education"). Meta reviews the name; a name that does not match the
   website or the portfolio is refused.
3. Enter the phone number, choose **SMS** or **Phone call**, and type the
   6-digit code you receive.
4. Meta asks you to set a **6-digit two-step verification PIN** for the
   number. Write it down with the company records: it is needed to change
   or remove the number later. It is not used by the app.
5. Back on API Setup, choose the new number in **From** and copy the
   **Phone number ID** underneath it. Send it to the developer (it is not a
   secret) for `functions/.env.prod`.
6. In WhatsApp Manager > Phone numbers, the number must show **Connected**
   and the display name **Approved**. Name review usually takes from
   minutes to a couple of days (not confirmed on a Meta page).

## E. Payment method

Template messages from a real number are billed, so Meta needs a card.

1. business.facebook.com > **Settings** > **Billing and payments** (or
   WhatsApp Manager > **Overview** > **Add payment method**).
2. Choose the WhatsApp Business Account > **Add payment method** > card.
   Currency **USD**, country Egypt. As far as we know the currency of a
   WhatsApp Business Account cannot be changed later, so choose with care.
3. Meta charges the card each month for delivered messages (prices in
   section 11).

## F. The sign-in template `login_code`

The code sends an **Authentication** template with a **Copy code**
button. The name must be exactly `login_code`.

1. business.facebook.com > **WhatsApp Manager** > **Account tools** >
   **Message templates** > **Create template**.
2. Category: **Authentication**. Type: one-time passcode with the **Copy
   code** button (not "One-tap autofill", not "Zero-tap": those need an
   Android app set up for them).
3. Name: `login_code`.
4. Languages: add **Arabic** and **English**. Choose plain "English" (code
   `en`) and "Arabic" (code `ar`). If the list only offers "English (US)",
   pick it and tell the developer, who then sets
   `WHATSAPP_TEMPLATE_LANG_EN=en_US`; in that case use the same English for
   **every** template below, because the code has one English setting for
   all of them.
5. The message text of an authentication template is fixed by Meta and you
   cannot edit it. In English it reads "123456 is your verification
   code."; Meta supplies the Arabic wording itself. For each language:
   - tick **Add security recommendation** ("For your security, do not
     share this code.");
   - tick **Add expiry time** and enter **5** minutes (our codes last 5
     minutes);
   - button: **Copy code**; leave the button text as Meta proposes.
6. **Submit** both languages. Status goes to "In review", then **Active**.
   Meta's page says a decision can take up to 24 hours; it is often
   minutes.

## G. The alert templates

All of these are category **Utility**, each in **Arabic** and **English**
under the same name. Names, variables and wording below are copied from
the code (`functions/src/notifications/catalog.ts` and `texts.ts`) and
SETUP.md 18.4, 20.3, 22.3.

For each template: WhatsApp Manager > **Message templates** > **Create
template** > Category **Utility** > Name exactly as in the table > add
both languages > Header: none > **Body**: paste the text > Buttons: none >
**Submit**.

- **Variable:** where the body has `{{1}}`, the app puts the day and the
  run, for example `Mon 16 Nov, to school`. When Meta asks for a sample
  value, type `Mon 16 Nov, to school` (English) and
  `الاثنين 16 نوفمبر، للمدرسة` (Arabic).
- **Footer (optional):** SETUP.md 18.4 suggests the footer "Open the app
  for details." (Arabic, as the app already says it: "افتح التطبيق
  للتفاصيل."). The code does not depend on it. Leave it out for bodies
  that already end with "Open the app", and if Meta refuses a template as
  a duplicate.
- Never add names, addresses, amounts or links. The app sends none.

### G.1 Create these first (the app sends them to every parent)

| Template name | Variable | English body (language: English, `en`) | Arabic body (language: Arabic, `ar`) |
| --- | --- | --- | --- |
| `cp_no_driver` | `{{1}}` | No driver for {{1}}. Please take your own child. | لا يوجد سائق لمشوار {{1}}. يرجى توصيل طفلك بنفسك. |
| `cp_child_not_confirmed` | none | A drop-off was not confirmed. Please check now. | لم يُؤكَّد وصول طفل. يرجى التحقق الآن. |
| `cp_time_changed` | `{{1}}` | The {{1}} run has a new time. Check the plan. | مشوار {{1}} له موعد جديد. راجع الخطة. |
| `cp_driver_arrived` | `{{1}}` | The car is outside for the {{1}} run. Send your child now. | السيارة بالخارج لمشوار {{1}}. أرسل طفلك الآن. |
| `cp_child_not_coming` | `{{1}}` | Your child was marked not coming for the {{1}} run. | سُجّل طفلك غير قادم لمشوار {{1}}. |
| `cp_location_stopped` | `{{1}}` | The car's location stopped during the {{1}} run. | توقف موقع السيارة في مشوار {{1}}. |
| `cp_run_still_on` | `{{1}}` | No location from you for 2 minutes on the {{1}} run. Open the app to continue. | لم يصل موقعك منذ دقيقتين في مشوار {{1}}. افتح التطبيق للمتابعة. |
| `cp_emergency` | `{{1}}` | The driver pressed Emergency on the {{1}} run. Open the app. | ضغط السائق زر الطوارئ في مشوار {{1}}. افتح التطبيق. |

`cp_time_changed` is sent by WhatsApp only when a run moved with no time
left to confirm; otherwise it is push only.

One more goes to a person who is **not** an app user, the emergency
contact a driver saved:

| Template name | Variables | English body | Arabic body |
| --- | --- | --- | --- |
| `cp_emergency_contact` | `{{1}}` the driver's first name, `{{2}}` a map link or "unknown" | {{1}} pressed the emergency button during a school run. Location: {{2}} | ضغط {{1}} زر الطوارئ أثناء مشوار المدرسة. الموقع: {{2}} |

Samples: `{{1}}` = `Ahmed` / `أحمد`; `{{2}}` =
`https://maps.google.com/?q=30.0444,31.2357`.

**Two warnings about `cp_emergency_contact` (tell the developer what Meta
answers):**

1. Meta's review page lists as a rejection reason: "The message template
   cannot start or end with a parameter". This body ends with `{{2}}` in
   both languages and starts with `{{1}}` in English. If Meta refuses it,
   do not invent new wording yourself: the developer must change the text
   in SETUP.md 20.3 and the code comment together.
2. Meta requires that people agree to receive your messages before you
   send them templates. This contact agreed only through the driver. Ask
   the lawyer whether that is enough, or whether the app should send this
   one by another route.

### G.2 Create these next (sent only to parents who switch WhatsApp on)

Not needed on the first day. A parent who switches a group on before its
templates are approved still gets the push; only the WhatsApp copy fails.

**Reminders** (settings group `reminders`)

| Template name | Variable | English body (language: English, `en`) | Arabic body (language: Arabic, `ar`) |
| --- | --- | --- | --- |
| `cp_drive_tomorrow` | `{{1}}` | You drive the {{1}} run. | أنت سائق مشوار {{1}}. |
| `cp_drive_soon` | `{{1}}` | Your {{1}} run starts within the hour. | مشوار {{1}} يبدأ خلال ساعة. |
| `cp_confirm_drive` | `{{1}}` | Please confirm the {{1}} run before the deadline. | يرجى تأكيد مشوار {{1}} قبل الموعد. |

**Swaps** (settings group `swaps`)

| Template name | Variable | English body (language: English, `en`) | Arabic body (language: Arabic, `ar`) |
| --- | --- | --- | --- |
| `cp_swap_requested` | `{{1}}` | A member asked for a swap: {{1}}. | عضو طلب تبديل مشوار {{1}}. |
| `cp_new_driver` | `{{1}}` | The {{1}} run has a driver now. | مشوار {{1}} له سائق الآن. |
| `cp_swap_cancelled` | `{{1}}` | The swap for {{1}} was taken back. | أُلغي طلب تبديل مشوار {{1}}. |
| `cp_needs_driver` | `{{1}}` | The {{1}} run needs a driver. | مشوار {{1}} يحتاج سائقًا. |

**Absences** (settings group `absences`)

| Template name | Variable | English body (language: English, `en`) | Arabic body (language: Arabic, `ar`) |
| --- | --- | --- | --- |
| `cp_child_absent` | `{{1}}` | A child is away for the {{1}} run. | طفل لن يركب مشوار {{1}}. |
| `cp_child_back` | `{{1}}` | A child is back for the {{1}} run. | طفل سيركب مشوار {{1}} مرة أخرى. |

**Schedule** (settings group `schedule`)

| Template name | Variable | English body (language: English, `en`) | Arabic body (language: Arabic, `ar`) |
| --- | --- | --- | --- |
| `cp_plan_ready` | none | Check your runs this week. | راجع مشاويرك هذا الأسبوع. |
| `cp_schedule_changed` | none | Days off or times changed in your carpool. | تغيّرت الإجازات أو المواعيد في مشوارك. |

**Join requests** (settings group `joins`)

| Template name | Variable | English body (language: English, `en`) | Arabic body (language: Arabic, `ar`) |
| --- | --- | --- | --- |
| `cp_join_requested` | none | A parent asked to join your carpool. | ولي أمر طلب الانضمام إلى مشوارك. |
| `cp_join_approved` | none | You are now in the carpool. | أصبحت عضوًا في المشوار. |
| `cp_join_declined` | none | Your request to join was declined. | لم يُقبل طلب انضمامك. |

**Verification** (settings group `verification`)

| Template name | Variable | English body (language: English, `en`) | Arabic body (language: Arabic, `ar`) |
| --- | --- | --- | --- |
| `cp_review_approved` | none | Your documents were approved. | تمت الموافقة على مستنداتك. |
| `cp_review_rejected` | none | Open the app to see what to fix. | افتح التطبيق لمعرفة ما يلزم تصحيحه. |

**New parents** (settings group `newParents`)

| Template name | Variable | English body (language: English, `en`) | Arabic body (language: Arabic, `ar`) |
| --- | --- | --- | --- |
| `cp_new_parent` | none | A new verified parent near your school. | ولي أمر موثّق جديد قرب مدرستك. |

**Run updates** (settings group `trips`)

| Template name | Variable | English body (language: English, `en`) | Arabic body (language: Arabic, `ar`) |
| --- | --- | --- | --- |
| `cp_trip_started` | `{{1}}` | The car is on its way: {{1}}. | السيارة في الطريق: مشوار {{1}}. |
| `cp_child_picked_up` | `{{1}}` | Your child got in for the {{1}} run. | ركب طفلك في مشوار {{1}}. |
| `cp_child_dropped` | `{{1}}` | Your child was dropped off: {{1}}. | نزل طفلك من مشوار {{1}}. |
| `cp_driver_late` | `{{1}}` | The driver is running late: {{1}}. | السائق متأخر قليلًا في مشوار {{1}}. |
| `cp_driver_at_gate` | `{{1}}` | The driver is at the school gate: {{1}}. | السائق عند بوابة المدرسة: مشوار {{1}}. |
| `cp_all_children_in` | `{{1}}` | All children are in the car: {{1}}. | كل الأطفال في السيارة: مشوار {{1}}. |

**Papers and family** (settings group `trust`)

| Template name | Variable | English body (language: English, `en`) | Arabic body (language: Arabic, `ar`) |
| --- | --- | --- | --- |
| `cp_licence_expiring` | `{{1}}` | Your licence or car licence expires on {{1}}. Renew it and update your driving details. | تنتهي رخصتك أو رخصة السيارة يوم {{1}}. جدّدها وحدّث بيانات القيادة. |
| `cp_licence_expired` | none | You get no new driving days until you update your driving details. | لن تحصل على أيام قيادة جديدة حتى تحدّث بيانات القيادة. |
| `cp_year_check` | none | Confirm your children, grades and schools for the new year. | أكّد أطفالك وصفوفهم ومدارسهم للعام الجديد. |
| `cp_guardian_requested` | none | Another parent asked to link to your children. Open the app to answer. | طلب ولي أمر آخر الربط بأطفالك. افتح التطبيق للرد. |
| `cp_guardian_linked` | none | Your account is now linked to the other parent's children. | تم ربط حسابك بأطفال ولي الأمر الآخر. |
| `cp_guardian_declined` | none | You were not linked to the children. Open the app for details. | لم يتم ربطك بالأطفال. افتح التطبيق للتفاصيل. |
| `cp_phone_changed` | none | Your account's phone number changed. If it wasn't you, contact us at once. | تغيّر رقم هاتف حسابك. إن لم تفعل ذلك تواصل معنا فورًا. |
| `cp_new_device` | none | Someone signed in to your account on a new phone, so we signed out the others. If it wasn't you, contact us at once. | دخل أحدهم إلى حسابك من هاتف جديد، فأخرجنا الهواتف الأخرى. إن لم تكن أنت فتواصل معنا فورًا. |

`cp_licence_expiring`: here `{{1}}` is a date only; sample `Mon 16 Nov` /
`الاثنين 16 نوفمبر`.

`cp_new_parent` tells a parent about someone new nearby. Meta may decide
that this is **Marketing**, not Utility (marketing costs about 18 times
more per message at the rates in section 11). If Meta approves it as Marketing, tell the
developer; the safe choice is then to keep it push only.

### G.3 Do not create yet: wallet templates

`cp_wallet_received`, `cp_wallet_sent`, `cp_wallet_failed`, `cp_wallet_frozen`, `cp_wallet_updated` belong to the wallet, which is switched off
for the pilot (docs/DECISIONS.md). Three of them have English wording in
SETUP.md 18.4 that differs from the text in the code, and no settled
Arabic template wording. The developer fixes that when the wallet is
turned on.

### G.4 If a template is refused

Open it in Message templates, read the reason, correct it and submit
again (Meta answers an appeal within about 24 hours). Common reasons on
Meta's page: curly braces typed wrongly (`{1}` instead of `{{1}}`), a
variable at the very start or end, special characters such as # $ % in a
variable, or text identical to another template. Keep the **name**
unchanged; only the developer can change names, because the code uses
them.

## H. The permanent token (system user)

The token Meta shows on the API Setup page is temporary (it stops
working within about a day). The app
needs one that does not expire, owned by a "system user" (a robot account
inside your portfolio).

1. business.facebook.com > **Settings** (gear) > **Users** > **System
   users**.
2. Click **Add** > name `school-carpool-functions` > role **Admin** >
   **Create system user**.
3. Select the new system user > **Assign assets**:
   - **Apps** > your app > switch on **Manage app** (full control);
   - **WhatsApp accounts** > your WhatsApp Business Account > switch on
     **Manage WhatsApp Business Accounts** (full control);
   - **Assign assets** (older screens: Save changes).
4. Reload the page after a minute, select the system user again and click
   **Generate token**.
5. App: your app. Token expiry: **Never**. Permissions: tick
   - `whatsapp_business_messaging` (sends the messages),
   - `whatsapp_business_management` (reads templates and numbers),
   - `business_management` if the screen offers it (Meta's token guide
     lists all three).
6. Click **Generate token**. Meta shows the token **once**. Do not paste
   it into a chat, a note app or an email. Keep the window open and go
   straight to step I.

If the token is ever exposed: come back here, **Revoke tokens**, generate a
new one and repeat step I.

## I. Put the values in place and test

1. **Token into Secret Manager** (prod project). Open Google Cloud Shell
   (docs/owner-cloud-shell.md) in the repository folder and run:

   ```sh
   firebase functions:secrets:set WHATSAPP_ACCESS_TOKEN --project prod
   ```

   The command asks for the value: paste the token there and press Enter.
   Nothing appears on screen, and the token is not written into the shell
   history this way. (Without Cloud Shell: Google Cloud console > the prod
   project > **Security > Secret Manager** > `WHATSAPP_ACCESS_TOKEN` >
   **New version** > paste > **Add new version**.)
2. **Phone number ID:** send it to the developer, who sets
   `WHATSAPP_PHONE_NUMBER_ID=<the ID>` in `functions/.env.prod` and
   commits it. `WHATSAPP_PROVIDER=meta` is already there.
3. The developer **deploys the functions** to prod (a new secret version
   is only read after a deploy).
4. **Test:** in the prod app, ask for a sign-in code with your own number.
   A WhatsApp message from your display name arrives with the code and a
   **Copy code** button, in the app's language. Try both languages.
5. If nothing arrives, the developer looks at the `requestCode` log in
   Google Cloud > Logging: Meta's error number is there (never the phone
   number). The usual causes: template not approved yet or named
   differently, language code mismatch (`en` against `en_US`), no payment
   method, token without `whatsapp_business_messaging`, wrong phone number
   ID.

**Real messages on staging (optional):** the same token works. Set the
secret in the staging project too, and ask the developer to set
`WHATSAPP_PROVIDER=meta` and `WHATSAPP_PHONE_NUMBER_ID` in
`functions/.env.staging`. Every staging code is then billed like a real
one.

## 10. Messaging limits (tiers)

From Meta's "Messaging limits" page (section 13):

- The limit counts **different people** you start messaging with templates
  in a moving 24 hours, for the whole portfolio (all its numbers together).
  Ten messages to one parent count once.
- A new portfolio starts at **250** people per 24 hours.
- It rises to **2,000** when one of these is done and Meta is satisfied
  with message quality: the business is verified (step B), or 2,000
  delivered template messages to different people within 30 days with
  high quality.
- From 2,000 it rises by itself to **10,000**, then **100,000**, then
  **unlimited**: one step up within 6 hours whenever quality is high and
  you used at least half of the current limit in the last 7 days.
- See it in WhatsApp Manager > **Account tools** > **Messaging limits**.

What it means for us: the sign-in code counts, so before verification at
most 250 different parents can receive anything in a day. Fine for a
pilot of one or two schools; not for a public launch.

Quality: parents can block or report the sender. Many blocks lower the
quality rating, pause the template, and stop the limit from rising. This
is one more reason the app sends only urgent alerts by WhatsApp unless the
parent asks for more.

## 11. Prices for Egypt

How Meta bills (from Meta's pricing page, read 14 Nov 2026):

- **Per delivered template message** since 1 July 2025 (no longer per
  24-hour conversation). The price depends on the template's category and
  the **recipient's country** (Egypt, by the +20 number).
- Messages that are sent but not delivered are not charged. Messages
  parents send to us are not charged.
- Since **1 October 2026** utility templates are charged even when sent
  inside an open 24-hour customer service window (they were free there
  before), and free-form service replies are charged after 1,000 free ones
  a month per number. The app sends no free-form replies.
- Prices can change on 1 January, 1 April, 1 July and 1 October, with at
  least one month's notice.
- Volume discounts exist for utility and authentication messages, by
  monthly volume per country. At pilot size we are in the first tier.

Egypt rates in US dollars, rate card effective 1 October 2026:

| Category | Used for | Price per delivered message | 1,000 messages |
| --- | --- | --- | --- |
| Authentication | `login_code` | USD 0.0036 | USD 3.60 |
| Utility | every `cp_...` alert | USD 0.0036 | USD 3.60 |
| Marketing | nothing we send (unless Meta re-labels a template) | USD 0.0644 | USD 64.40 |
| Authentication-international | does not apply to us (see below) | USD 0.0650 | USD 65.00 |

**These four numbers are not confirmed from Meta's own file.** Meta's
pricing page links to the rate cards as CSV/PDF downloads, which the build
workspace could not open. The numbers come from a third-party page that
says it copies Meta's USD rate card effective 1 October 2026
(chatmaxima.com), and a second provider's table (Gallabox) shows the same
figures plus 15 percent. Before you budget: open Meta's pricing page,
**Rate cards** > **USD**, and read the Egypt row. Egyptian VAT or card
fees may be added on top.

**Authentication-international:** Egypt is one of the countries where
Meta charges a much higher rate for sign-in codes sent by businesses
based **outside** that country, and only for businesses sending more than
750,000 such messages in 30 days. Our entity is in Egypt, so the normal
rate applies. Make sure the portfolio's country is Egypt (step A.5) so
this never becomes a question.

A rough monthly bill at the unconfirmed rate: 500 parents, each signing in
4 times and getting 20 urgent alerts by WhatsApp, is 12,000 messages, about
**USD 43**. The app's own limits on codes (5 per number per hour and the
other caps in docs/COSTS.md) keep abuse from running this up.

## 12. What we could not confirm

| Item | Why | What to do |
| --- | --- | --- |
| The exact buttons of business verification, the accepted documents and the review time | Meta's Business Help Centre pages refuse automated reading; the list in B.2 and "up to 14 working days" come from a third-party summary of them | Read the two help pages in section 13 before uploading |
| Whether Arabic documents are accepted without translation | Same | The upload screen says which languages it takes |
| Which Egyptian document Meta's reviewers prefer | Meta lists kinds of documents, not Egyptian names | Upload the commercial register extract and the tax card together |
| The Egypt prices | Meta's rate card files could not be downloaded here | Section 11: check the USD rate card |
| Display name rules and review time | The help page could not be read | Section 13 link; keep the name equal to the website |
| Exact names of the choices in the token dialog ("Never") and whether `business_management` is offered | Meta's token guide lists the three permissions but not the expiry choices | Tell the developer what the screen shows |
| Whether `cp_emergency_contact` passes review | It starts/ends with a variable (G.1) | Submit it; report Meta's answer |
| Payment screens for an Egyptian card | Not documented by Meta for Egypt specifically | If the card is refused, try another bank's card; tell the coordinator |

Not in SETUP.md but in the code, so it was added here from the code:
`cp_child_not_coming` (group "Car outside, location", on by default).

## 13. Sources (all read 14 Nov 2026 unless marked)

Meta, official:

- Cloud API get started (app, WhatsApp Business Account, system user):
  https://developers.facebook.com/documentation/business-messaging/whatsapp/get-started
- Access tokens (system users, the three permissions):
  https://developers.facebook.com/documentation/business-messaging/whatsapp/access-tokens/
- Business phone numbers (requirements, 2-number cap, PIN, display name
  status):
  https://developers.facebook.com/documentation/business-messaging/whatsapp/business-phone-numbers/phone-numbers
- Copy code authentication templates:
  https://developers.facebook.com/documentation/business-messaging/whatsapp/templates/authentication-templates/copy-code-button-authentication-templates
- Template fundamentals (names, 250 / 6,000 template limits, statuses):
  https://developers.facebook.com/documentation/business-messaging/whatsapp/templates/overview
- Template categories (utility against marketing):
  https://developers.facebook.com/documentation/business-messaging/whatsapp/templates/template-categorization
- Template review (24 hours, rejection reasons):
  https://developers.facebook.com/documentation/business-messaging/whatsapp/templates/template-review/
- Messaging limits:
  https://developers.facebook.com/documentation/business-messaging/whatsapp/messaging-limits
- Pricing (model, dates, rate card downloads):
  https://developers.facebook.com/documentation/business-messaging/whatsapp/pricing
- Authentication-international rates (Egypt since 1 Feb 2025):
  https://developers.facebook.com/documentation/business-messaging/whatsapp/pricing/authentication-international-rates/
- About the platform (opt-in before templates, test number):
  https://developers.facebook.com/documentation/business-messaging/whatsapp/about-the-platform
- Business verification for apps (who can do it):
  https://developers.facebook.com/documentation/development/release/business-verification

Meta, official, **not readable from the build workspace** (open them in a
browser):

- Verify your business: https://www.facebook.com/business/help/2058515294227817
- Why a business cannot be verified: https://www.facebook.com/business/help/2342133782492969
- About the WhatsApp Business display name: https://www.facebook.com/business/help/338047025165344

Third party (used only where marked above):

- Accepted documents and review time, summarising Meta's help pages:
  https://tofuads.com/resources/meta-business-verification-documents
- Egypt rates: https://chatmaxima.com/whatsapp-api-pricing/egypt/ and
  https://docs.gallabox.com/pricing-and-billing/whatsapp-pricing/rate-card.md
