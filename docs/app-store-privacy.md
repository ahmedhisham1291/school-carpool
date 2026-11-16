# App Store privacy answers ("nutrition label")

Final draft for **App Store Connect > your app > App Privacy** (Prompt 13).
Built from what the code really sends and stores, checked against:
`DATA_TYPES` (functions/src/privacy/retention.ts, same list as the in-app
privacy screen), `docs/analytics-events.md`, the Sentry scrubbers
(`lib/observability`, `functions/src/scrub.ts`), Algolia, Maps,
WhatsApp, Valify and wallet code, and SECURITY.md part 2 (who receives
what). The lawyer confirmed the data collected and the retention periods
(DECISIONS.md, 14 Nov 2026). **The owner enters these answers; re-check
them whenever a prompt adds a data type.**

Apple's rule: answer for data collected by us **and** by any third party
whose code or service the app uses (Algolia, Sentry, Google,
Valify, the wallet partner). "Linked to you" = tied to the parent's
account. "Tracking" = combined with other companies' data for ads or
shared with data brokers.

## 1. Short answers

- **Do you or your third-party partners collect data from this app?** Yes.
- **Is any data used to track the user?** **No**, for every type. No
  advertising, no IDFA, no data brokers; Analytics has no user ID and the
  advertising and IDFV keys are off in Info.plist.
- **Privacy policy URL:** `https://<prod project>-links.web.app/privacy`
  (built by `tool/links_site.py`, docs/apple-review/submission-kit.md
  step 6). The same text is reachable in the app: About > Legal and
  support.
- **Privacy manifest:** `tool/ios/PrivacyInfo.xcprivacy` declares the same
  data types as the table below (a test compares them): change both
  together.

## 2. Data types (select these in App Store Connect)

| Apple category | Data type | What the app collects | Who receives it | Linked | Tracking | Purposes |
| --- | --- | --- | --- | --- | --- | --- |
| Contact Info | Name | Parent's first and last name (from the ID); handover adults' and emergency contact's names | Us | Yes | No | App Functionality |
| Contact Info | Email Address | Confirmed email | Us; email provider (new-phone alert) | Yes | No | App Functionality |
| Contact Info | Phone Number | Sign-in number; emergency contact's and handover adults' numbers | Us; WhatsApp (codes, alerts) | Yes | No | App Functionality |
| Contact Info | Physical Address | Home location (exact for the parent, rounded about 500 m for others) and pickup points | Us; Google Maps (address search, arrival times) | Yes | No | App Functionality |
| Health & Fitness | — | Not collected | | | | |
| Financial Info | Other Financial Info | **Settle up (the pilot's payment feature):** the parent's InstaPay address (name@instapay) and the records of payment requests between two parents (amount, reason, short note, dates, state). The app does not process payments: the money moves in the InstaPay app, and no bank account or card number is ever asked for or stored. **Wallet (switched off for the pilot):** wallet history: amounts, the two parents, dates (the money and any card details are held by the licensed partner, never by us) | Us only for Settle up (the InstaPay address is shown to the parent who has an open request from its owner); the wallet partner once the wallet is on | Yes | No | App Functionality |
| Location | Precise Location | The driver's car during a run (While Using + background mode, live points deleted within 24 h; one compressed route kept 1 year, admins only); the home pin from "use my location" | Us; Google Routes (car and stops, for arrival times) | Yes | No | App Functionality |
| Location | Coarse Location | City-level area that Google Analytics derives from the IP address (off when the parent switches Analytics off) | Google Analytics | No | No | Analytics |
| Sensitive Info | Sensitive Info | Face images used for face matching (biometric): identity selfie as the face reference, live selfie checks, new-phone selfies | Us; Valify (when contracted) | Yes | No | App Functionality (identity, fraud prevention, child safety) |
| Contacts | — | Not collected (the address book is never read) | | | | |
| User Content | Emails or Text Messages | — not used (in-app chat is declared below) | | | | |
| User Content | Photos or Videos | ID front/back, selfie, child's school ID, driver's and car licence, driver photo; chat photos | Us; Valify (ID and selfie, when contracted) | Yes | No | App Functionality |
| User Content | Other User Content | Chat messages, ratings, reports, privacy requests | Us | Yes | No | App Functionality |
| User Content | Customer Support | Reports and privacy requests | Us | Yes | No | App Functionality |
| Browsing History | — | Not collected | | | | |
| Search History | Search History | School names typed in the school search; addresses typed in the home search (not stored with the account) | Algolia (school search, no user identity); Google Places | No | No | App Functionality |
| Identifiers | User ID | Parent ID and account ID | Us; Sentry (opaque account ID) | Yes | No | App Functionality |
| Identifiers | Device ID | Random install ID (keyed hash on the server, phones list); push token; Analytics app instance ID (not linked) | Us; Firebase Messaging/APNs; Google Analytics | Yes (install ID, push token) | No | App Functionality; Analytics (instance ID) |
| Purchases | — | Not collected (no in-app purchases) | | | | |
| Usage Data | Product Interaction | Screens (route patterns) and features used, fixed words only; switch in Settings | Google Analytics | No | No | Analytics |
| Usage Data | Advertising Data | Not collected | | | | |
| Diagnostics | Crash Data | Crash reports with personal data removed | Sentry | Yes (opaque account ID) | No | App Functionality |
| Diagnostics | Performance Data | Not collected (Sentry tracing is off) | | | | |
| Diagnostics | Other Diagnostic Data | Non-crash error reports (scrubbed: no phone, ID number, coordinates, images or message text) | Sentry | Yes (opaque account ID) | No | App Functionality |
| Other Data | Other Data Types | Children's first name, age, grade and school; national ID number (stored as a keyed hash plus the expiry date); car plate, model, colour and seats | Us; Valify (ID, when contracted) | Yes | No | App Functionality |

## 3. Third parties, one by one

Chat is our own since improvement B (14 Nov 2026): messages and chat photos
stay in our Firebase project. **Stream Chat no longer receives any data**
and is not in the app. One setting decides what the public pages, the
in-app privacy text and these answers say about chat: `CHAT_PROVIDER` in
`functions/.env.<env>` (`firestore`); `tool/test_links_site.py` fails when
they disagree with it.

| Partner | In the app or the server | What it receives | Not sent |
| --- | --- | --- | --- |
| Firebase (Auth, Firestore, Storage, Functions, Messaging, App Check) | Both | Everything the app stores, chat messages and chat photos included (our processor, europe-west1) | n/a |
| Google Analytics for Firebase | App | Route patterns, fixed event names and words, app instance ID, IP (city) | User ID, names, numbers, IDs, coordinates, message text |
| Algolia | App (search-only key) and server (index) | Typed school searches; the index holds school names and places | Anything about parents or children |
| Sentry | App and server | Scrubbed error and crash reports, opaque account ID, feature tag | Phone, ID numbers, coordinates, images, message text |
| WhatsApp (Meta) | Server only | Phone numbers, sign-in codes, alert texts (date and direction only) | Names of children, amounts, message text |
| Google Maps Platform | App (map tiles) and server (Places, Routes) | Map views, typed address searches, car and stop points during a run | Who the parent is |
| Valify | Server only (fake until the pilot) | ID images, selfie | n/a |
| Wallet partner | Server only (fake until the pilot) | Wallet holder reference, amounts, the two parties | Children's data, chats |
| Vertex AI (Google Cloud) | Owner's import tool only (`tools/import_schools/ai_review.py`), never the app or the functions | Public school names from the school list, to check spelling and duplicates | Anything about parents or children; names a parent types under "Other" (admins review those) |
| Email delivery (Firebase "Trigger Email" extension with the owner's SMTP provider) | Server only | The parent's confirmed email address and the new-phone alert text | Anything else |
| Apple Push (via FCM) | Server | Push token, short alert texts | Phone, coordinates, message text |

## 4. App Store Connect, step by step

1. App Store Connect > Apps > School Carpool (staging uses the same
   answers) > **App Privacy** > Get Started.
2. "Do you or your third-party partners collect data from this app?" **Yes**.
3. Tick every type in the **Data type** column of section 2 that has an
   entry (not the "Not collected" rows).
4. For each type: purposes as listed (tick only those), **Linked to the
   user** as listed, **Used for tracking: No**.
5. Publish. Enter the **Privacy Policy URL** in App Information.
6. Info.plist is already set for this: no IDFA, Analytics ad keys off,
   no tracking prompt (App Tracking Transparency is not needed).
