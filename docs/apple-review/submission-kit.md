# App Store submission kit (for the owner)

Everything to type or paste into App Store Connect for the first
submission of **School Carpool** (prod app, bundle id
`org.schoolcarpool.app`), and the list of what only you can do. Findings
behind it: docs/apple-review/audit.md. **Never paste a phone number, a
code, a key or a password into a chat, an issue or this repository.**

No checklist can guarantee approval the first time. If Apple rejects the
build, they write which guideline and why in App Store Connect; send that
text to the developer.

## A. Owner checklist (in this order)

1. **Apple Developer account type.** Open
   https://developer.apple.com/account > Membership details. If "Entity
   type" is **Individual**, convert to **Organization** first (Apple
   support, needs your company's legal name and a D-U-N-S number:
   https://developer.apple.com/support/D-U-N-S/). Reason: the app asks
   for national IDs and face photos, and Apple's guideline 5.1.1(ix) wants
   such apps submitted by a legal entity. Start now; it can take 1 to 2
   weeks.
2. **WhatsApp Business** production sender and approved templates
   (docs/meta-whatsapp-setup.md). Not needed for Apple's reviewer, needed
   for every real parent.
3. **Prod Firebase project** (SETUP.md section 3): Blaze, region
   europe-west1, App Check with **App Attest** for the iOS app
   `org.schoolcarpool.app`, APNs key uploaded, functions, rules and
   indexes deployed, then `flutterfire configure` so
   `lib/firebase/firebase_options_prod.dart` is real (commit it).
   `functions/.env.prod`: `APP_ENV=prod`, `WHATSAPP_PROVIDER=meta`,
   `KYC_PROVIDER=valify` (needs the Valify contract before real parents
   can be verified).
4. **Prod services:** Google Maps iOS key restricted to
   `org.schoolcarpool.app` (SETUP.md 15.2), Algolia prod keys
   (docs/algolia-setup.md), Stream prod app then
   `npm --prefix functions run chat:setup` (this installs the word
   filter Apple requires), Sentry prod project.
5. **A support email address you read every day** (for example
   help@your-domain) and **the legal name** that runs the app.
6. **Public pages.** Build and deploy the links site of the prod project
   with them (SETUP.md 16.2):
   ```
   python3 tool/links_site.py --team-id <TEAM ID> --bundle-id org.schoolcarpool.app \
     --support-email <address> --operator-name "<legal name>" --require-legal \
     [--app-store-url https://apps.apple.com/app/id<Apple ID>]
   firebase deploy --only hosting:links --project prod
   ```
   Open `https://<prod project>-links.web.app/privacy`, `/terms`,
   `/support`, `/delete-account` and `/` on your phone. (Staging: add
   `SUPPORT_EMAIL=... OPERATOR_NAME="..."` in front of
   `bash tool/cloud_setup.sh ...`.)
7. **Lawyer:** read the four pages (sources in `hosting/links/`) and the
   three short texts in the app (About > Legal and support). Send the
   developer any wording change; a change raises the document version.
8. **App Store Connect:** Apps > + > New App: iOS, name `School Carpool`,
   primary language Arabic, bundle id `org.schoolcarpool.app`, SKU
   `school-carpool`. Copy the Apple ID number into `codemagic.yaml` >
   `ios-prod` > `APP_STORE_APPLE_ID`. In developer.apple.com > Identifiers
   > `org.schoolcarpool.app` tick Push Notifications and App Attest
   (Associated Domains if you use invite links). Create the distribution
   profile as in docs/testflight.md step 1b, for this bundle id.
   Codemagic: group **`prod_defines`** with `SENTRY_DSN_APP_PROD`,
   `MAPS_API_KEY_IOS`, `LEGAL_SITE_URL` (`https://<prod project>-links.web.app`),
   `SUPPORT_EMAIL`.
9. **Demo accounts** (section B), then use each once on your own iPhone
   and send one chat message from each in the demo carpool.
10. **App icon:** look at `tool/ios/AppIcon/icon_1024.png`. Keep it, or
    replace the file with your designer's icon (1024 x 1024 PNG, no
    transparency, square corners).
11. **Build:** Codemagic > Start new build > branch `main` > **iOS prod to
    App Store Connect (manual)**. It stops with a clear message if step
    3, 6 or 8 is missing.
12. **Test the prod build** from TestFlight with the demo driver account:
    sign in, open the demo carpool, start today's run, lock the phone,
    finish the run; open About > Privacy policy; Profile > Privacy >
    Delete account (do NOT confirm on the demo account).
13. **Record the run video** (docs/app-review-notes.md section 4).
14. **Screenshots** (section G).
15. Fill App Store Connect with sections C to H below, attach the video,
    choose the build, **Submit for Review**.
16. **While in review:** do not sign in with the demo driver number on
    your own phone (Apple's phone would be signed out). Check the admin
    panel's Reports every day. Run the demo `seed` again each Saturday
    evening (it plans the new week).
17. **After approval:** `review-demo -- remove`, delete the two demo
    accounts in the app (Profile > Privacy > Delete account) and
    `review-access -- off`. For every later update that Apple reviews,
    turn them on again first.

## B. Demo accounts for the reviewer

You need two Egyptian mobile numbers used for nothing else (two spare
SIMs; they never receive a message), and two different 6-digit codes that
are not easy to guess. From your Mac, signed in to gcloud as a super admin
of the prod project (the values are typed at hidden prompts, so they do
not stay in your shell history):

```bash
read -s -p "Demo phone 1 (driver): " REVIEW_PHONE; echo
read -s -p "Code 1 (6 digits): " REVIEW_CODE; echo
read -s -p "Demo phone 2 (parent): " REVIEW_PHONE_2; echo
read -s -p "Code 2 (6 digits): " REVIEW_CODE_2; echo
read -s -p "OTP_HMAC_KEY (Secret Manager): " OTP_HMAC_KEY; echo
export REVIEW_PHONE REVIEW_CODE REVIEW_PHONE_2 REVIEW_CODE_2 OTP_HMAC_KEY
GCLOUD_PROJECT=<prod-project-id> npm --prefix functions run review-access -- on 30 <your-super-admin-uid>
GCLOUD_PROJECT=<prod-project-id> npm --prefix functions run review-demo -- seed <your-super-admin-uid>
GCLOUD_PROJECT=<prod-project-id> npm --prefix functions run review-demo -- status <your-super-admin-uid>
unset REVIEW_PHONE REVIEW_CODE REVIEW_PHONE_2 REVIEW_CODE_2 OTP_HMAC_KEY
```

What this does: the two numbers accept their fixed code for 30 days at
most (no WhatsApp message; every sign-in limit still applies; each
sign-in is in the admin audit log; only keyed hashes are stored). The
seed makes two verified demo parents with fake data ("Mona Demo", who
drives, and "Karim Demo"), a "Demo School (App Review)" that real parents
cannot find, one carpool, one child each, a car, and runs for this week
and the next. Because Apple's phone is always "a new phone", the two demo
parents skip the new-phone selfie and the driver's face check until the
30 days end. Real parents are never affected.

In **App Store Connect > App Review Information > Sign-In Information**:
tick "Sign-in required"; **User name** = demo phone 1 (as the app shows
it, for example 010 1234 5678); **Password** = code 1. Put phone 2 and
code 2 in the notes field **only** where section E says "second
account" (the notes are private to App Review).

## C. App information

| Field | Value |
| --- | --- |
| Name (English) | School Carpool |
| Name (Arabic) | مشوار المدرسة |
| Subtitle (English, 30 max) | Parents share the school run |
| Subtitle (Arabic) | تبادل توصيل المدرسة بين الأهالي |
| Primary category | Navigation (or Lifestyle) |
| Secondary category | Lifestyle (or Social Networking) |
| Price | Free. No in-app purchases. |
| Availability | Egypt only (the app accepts Egyptian mobile numbers only) |
| Content rights | "No, it does not contain third-party content" besides open map and school data, credited in About |
| Privacy Policy URL | `https://<prod project>-links.web.app/privacy` |
| Support URL | `https://<prod project>-links.web.app/support` |
| Marketing URL (optional) | `https://<prod project>-links.web.app/` |
| Copyright | `2026 <legal name>` |
| Made for Kids | **No** (the users are adult parents) |

**Promotional text (English, 170 max):**
Take turns driving the school run with verified parents from your child's school and area. See the car on the map and know when it arrives.

**Promotional text (Arabic):**
تناوب على توصيل المدرسة مع أولياء أمور موثَّقين من مدرسة ابنك ومنطقتك. تابع السيارة على الخريطة واعرف وقت وصولها.

**Description (English):**
School Carpool helps parents in Egypt share the school run. Parents of the same school and area form a carpool and take turns driving.

- Verified parents only: every parent passes an identity check before joining a carpool.
- Find or start a carpool for your school and area.
- A clear weekly schedule: who drives each morning and afternoon, with swaps when plans change.
- Live run: when a parent drives, the other parents of that run see the car on a map and get an alert when it is outside and when their child is dropped off.
- Chat with the parents of your carpool, with report and block.
- Settle up: keep a record of shared costs such as fuel between parents. The app does not move money.
- Your privacy: other parents see only your first name and approximate area. See, download or delete your data at any time.

The app is free and non-profit, with no ads and no fees. It is for adult parents. Each parent is responsible for their own driving. The Emergency button alerts the carpool only; in danger call 122 or 123.

**Description (Arabic):**
«مشوار المدرسة» يساعد أولياء الأمور في مصر على تبادل توصيل المدرسة. أولياء أمور المدرسة والمنطقة نفسها يكوّنون مجموعة ويتناوبون القيادة.

- أولياء أمور موثَّقون فقط: كل ولي أمر يمر بتحقق من الهوية قبل الانضمام لأي مجموعة.
- ابحث عن مجموعة لمدرستك ومنطقتك أو أنشئ واحدة.
- جدول أسبوعي واضح: من يقود كل صباح وكل ظهر، مع التبديل عند تغيّر الظروف.
- مشوار مباشر: عندما يقود أحد أولياء الأمور يرى أولياء أمور ذلك المشوار السيارة على الخريطة، ويصلهم تنبيه عند وصولها وعند نزول ابنهم.
- محادثة مع أولياء أمور مجموعتك، مع الإبلاغ والحظر.
- تسوية الحساب: سجّل التكاليف المشتركة مثل الوقود بين أولياء الأمور. التطبيق لا ينقل الأموال.
- خصوصيتك: يرى الآخرون اسمك الأول ومنطقتك التقريبية فقط. اطّلع على بياناتك أو نزّلها أو احذفها في أي وقت.

التطبيق مجاني وغير ربحي، بلا إعلانات وبلا رسوم، وهو لأولياء الأمور البالغين. كل ولي أمر مسؤول عن قيادته. زر الطوارئ ينبّه المجموعة فقط؛ في الخطر اتصل بـ 122 أو 123.

**Keywords (English, 100 characters max, commas, no spaces):**
`carpool,school run,parents,school,ride share,pickup,drop off,Egypt,schedule,students`

**Keywords (Arabic):**
`توصيل,مدرسة,أولياء أمور,مشوار,مشاركة,سيارة,مدارس,مصر,جدول,طلاب`

Do not write "for kids" or "for children" anywhere in the store text or
screenshots (reserved for the Kids Category), no prices, no other
platforms' names, and no "beta" or "test".

**What's New (first version):** leave the default / "First release."

## D. App Privacy ("nutrition label")

Use **docs/app-store-privacy.md** section 2, row by row; it matches the
app's privacy manifest (a test checks that). Short form:

- Collect data? **Yes.** Used to track? **No**, for every type.
- **Linked to the user, purpose App Functionality:** Name, Email Address,
  Phone Number, Physical Address, Other Financial Info (Settle up
  records and InstaPay address), Precise Location, Sensitive Info (face
  images used for matching), Photos or Videos, Other User Content (chat
  messages, reports), Customer Support, User ID, Device ID, Crash Data,
  Other Diagnostic Data, Other Data Types (children's first name, age,
  grade, school; ID number hash; car details).
- **Not linked, purpose Analytics:** Coarse Location, Product
  Interaction; Device ID also has Analytics (the anonymous Analytics
  instance ID).
- **Not linked, purpose App Functionality:** Search History (school and
  address searches).
- Not collected: Health, Fitness, Contacts, Browsing History, Purchases,
  Advertising Data, Emails or Text Messages, Audio, Gameplay.

## E. Notes for App Review (paste into App Review Information > Notes)

> School Carpool is a free, non-profit app for verified parents in Egypt
> who share school runs: parents of the same school and area take turns
> driving each other's children. It is used by adult parents only;
> children do not use the app.
>
> SIGN-IN. Parents sign in with a one-time code sent by WhatsApp to their
> Egyptian mobile number (our own account system; no social or third-party
> login). For review, the demo number in Sign-In Information accepts the
> fixed code given there. No WhatsApp message is needed or sent. Enter the
> number on the first screen, then the code.
>
> DEMO ACCOUNT. It is an already verified demo parent ("Mona Demo", a
> driver) in a demo carpool with a second demo parent ("Karim Demo").
> All data is fake. Please use this account: a new account cannot join a
> carpool until our team has verified the parent's identity document,
> which is the app's core safety rule.
> To see the main feature: Carpools tab > Demo School carpool > Schedule
> > today's run > Start run. Allow location "While Using the App" with
> Precise Location, and notifications, when asked. School runs are
> planned Sunday to Thursday (the school week in Egypt); on a Friday or
> Saturday open the next run in the schedule. The attached video shows a
> full run recorded on an iPhone.
> Second account (optional, to see the other parent's side on another
> device): phone [PHONE 2], code [CODE 2].
>
> BACKGROUND LOCATION. The app uses location in the background ONLY while
> a parent drives a school run they started themselves (Start run).
> During that run the parents of the children in the car see the car on
> a map and get "car outside" and arrival alerts. iOS shows the blue
> location indicator the whole time. Tracking stops by itself at the last
> drop-off, when the driver ends the run, and after 4 hours at the
> latest. Parents who do not drive are never tracked. Without location
> permission a parent can use everything except starting a run.
> "Always" is optional: one screen offers it to drivers so a run resumes
> by itself if iOS closes the app mid-run. Declining changes nothing
> else.
>
> IDENTITY CHECK. Real parents are verified with a photo of their
> national ID and a live selfie before they can join carpools, because
> they will drive other families' children. The images are stored
> encrypted, seen only by our reviewers, and the parent consents on a
> separate screen. The demo account is already verified, so no document
> is needed.
>
> PAYMENTS. The app does not process payments and has no in-app
> purchases. "Settle up" (Profile > Settle up) only records payment
> requests between two parents of the same carpool for shared real-world
> costs such as fuel, and shows the payee's InstaPay address to copy.
> The parent pays in the separate InstaPay app (Egypt's national instant
> payment network). Our app does not move, hold or see money, takes no
> fee, and never asks for a card or bank account. Nothing digital is
> sold. The wallet feature is switched off and not shown.
>
> USER-GENERATED CONTENT. Chats are between verified parents of the same
> carpool. Press and hold a message to report it; the chat menu has
> Report and Block. A word filter blocks objectionable text. The code of
> conduct accepted at sign-up says there is no tolerance for
> objectionable content or abusive users. Our team reviews reports within
> 24 hours, removes the content and suspends the user. Contact: About >
> Contact support.
>
> ACCOUNT DELETION. Profile > Privacy > Delete account (inside the app,
> no email needed). The screen lists what is deleted at once and what is
> kept for one year for child-safety investigations.
>
> EMERGENCY BUTTON. It alerts the parents of the carpool and the driver's
> emergency contact only. It does not contact emergency services; the
> app says so and shows the local emergency numbers.
>
> CAMERA, PHOTOS, FACE ID. Camera: ID photos, the live selfie, and photos
> a parent chooses to send in a chat. Photos: choosing a picture for a
> chat. Face ID: App lock (if the parent turns it on) and confirming
> account deletion.
>
> The app is iPhone only and is offered in Egypt only, in Arabic and
> English.

Replace `[PHONE 2]` and `[CODE 2]` in App Store Connect only. Contact
information on the same page: your name, phone and email.

## F. Other questions App Store Connect asks

- **Export compliance:** the build already says it uses no non-exempt
  encryption (`ITSAppUsesNonExemptEncryption = NO`), so no question
  should appear. If asked: "Does your app use encryption?" Yes, only
  standard encryption (HTTPS/TLS and standard hashing from the operating
  system and standard libraries), which is **exempt**; no documentation
  needed.
- **Advertising identifier (IDFA):** No.
- **Content rights:** see section C.
- **Age rating questionnaire** (App Information > Age Rating). Answer:
  - Violence, sexual content, nudity, profanity, horror, drugs, alcohol,
    gambling, contests, medical or wellness topics: **None / No**.
  - Unrestricted web access: **No**.
  - **User-generated content: Yes.** **Messaging or chat between users:
    Yes.** Advertising: **No.**
  - In-app controls: content reporting **Yes**, blocking users **Yes**;
    parental controls and age assurance **No** (the app is for adults
    and checks identity documents).
  - The wording of the questions may differ a little; answer by these
    facts. Apple then shows a rating. The app is for adult parents and asks
    for an identity document, so if Apple's result is lower, set the
    higher rating **18+** with "set a higher age rating".
  - Kids Category: **No**.
- **Digital Services Act (EU):** not needed while the app is offered in
  Egypt only.
- **Sign in with Apple:** not used and not required (the app has only
  its own phone-number sign-in).

## G. Screenshots

Take them on the prod build with the demo accounts (fake names only).
One set at the 6.9-inch size is enough: **1320 x 2868** (iPhone 16/17 Pro
Max) or 1290 x 2796 (iPhone 15 Pro Max), portrait, PNG or JPEG, no
transparency, 3 to 10 images. A 6.5-inch set (1284 x 2778 or 1242 x 2688)
is only needed if you have no 6.9-inch one. No iPad set (the app is
iPhone only). Make the set twice: phone language Arabic for the Arabic
listing, English for the English listing.

1. Home.
2. Carpool page (the demo carpool with its members and times).
3. Weekly schedule.
4. The run screen for the driver (Start run / the large buttons).
5. The other parent's view: the car on the map (second demo account).
6. Carpool chat.
7. Profile > Privacy (your data and choices).

Show the real screens with no added phone frames of other brands, no
prices, and nothing that suggests the app is for children to use.

## H. If Apple rejects

| Apple says | What to do |
| --- | --- |
| "We were unable to sign in" | `review-demo -- status`; check the review access has days left; confirm the number format in Sign-In Information; make sure nobody used the demo number on another phone. |
| Guideline 2.5.4 / background location | Reply with the BACKGROUND LOCATION note and attach the video again. |
| Guideline 5.1.1 "Always" location | Developer removes the optional "Always" screen (the app works without it). |
| Guideline 4.5.4 / 5.1.2 notifications required | Developer makes notifications optional for starting a run (audit section 2). |
| Guideline 5.1.1(v) data kept after deletion | Reply: kept one year for child-safety investigations, shown before deletion, confirmed by counsel; or decide a shorter period with the lawyer. |
| Guideline 5.1.1(ix) individual account | Checklist step 1. |
| Guideline 1.2 | Reply with the USER-GENERATED CONTENT note; check `chat:setup` ran on prod. |
| Guideline 3.1.1 (payments) | Reply with the PAYMENTS note. |
| ITMS-91053 / 91061 email (privacy manifest) | Send the email to the developer; it names the SDK. |
| App crashes at launch | Send the crash log; check the build used Xcode 26 (codemagic.yaml). |
