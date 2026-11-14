# App Store privacy answers (draft)

Draft for App Store Connect > App Privacy (Prompt 12; Prompt 13 finalises it
with the TestFlight build). Built from the data the app really collects
(privacy screen list, `DATA_TYPES` in functions/src/privacy/retention.ts).
The lawyer confirmed the data collected and the retention periods
(docs/DECISIONS.md, 14 Nov 2026); **the owner checks these answers against
the build before submission.**

"Linked to you" = stored with the parent's account. "Tracking" = No for
every type (no advertising, no data brokers, no IDFA).

| Apple category | Data type | What we collect | Linked to user | Used for tracking | Purposes |
| --- | --- | --- | --- | --- | --- |
| Contact Info | Name | First and last name (from the ID), children's first names, handover adults' and emergency contact's names | Yes | No | App functionality |
| Contact Info | Email Address | Confirmed email | Yes | No | App functionality (account, security alerts) |
| Contact Info | Phone Number | Mobile number (sign-in), emergency contact's number, handover adults' numbers | Yes | No | App functionality |
| Contact Info | Physical Address | Home location (exact for the parent; rounded for others) and pickup points | Yes | No | App functionality |
| Health and Fitness | — | Not collected | | | |
| Financial Info | Payment Info / Other Financial Info | Wallet transfer history (amounts, parties); the money is held by the licensed partner | Yes | No | App functionality |
| Location | Precise Location | Car location during a run (deleted within 24 hours) and one compressed route per run (kept 1 year, admins only) | Yes | No | App functionality (safety) |
| Location | Coarse Location | Approximate area derived from the IP address by Google Analytics (city level); can be switched off with Analytics | No | No | Analytics |
| Sensitive Info | Sensitive Info | National ID number (stored as a keyed hash plus the expiry date), face images | Yes | No | App functionality (verification, fraud prevention) |
| Contacts | — | Not collected (the address book is never read) | | | |
| User Content | Photos or Videos | ID, selfie, school ID, licence and driver photos; live selfie checks; chat photos | Yes | No | App functionality (verification, safety) |
| User Content | Other User Content | Chat messages, ratings, reports | Yes | No | App functionality |
| User Content | Customer Support | Privacy requests | Yes | No | App functionality |
| Identifiers | User ID | Parent ID and account ID | Yes | No | App functionality |
| Identifiers | Device ID | Random app install ID (keyed hash on the server), push token; the Analytics app instance ID (not linked to the account) | Yes (install ID, push token) / No (app instance ID) | No | App functionality, security (phones list), Analytics |
| Usage Data | Product Interaction | Screens and features used (no names, numbers or places); can be switched off | No (no user ID is sent to Analytics) | No | Analytics |
| Diagnostics | Crash Data | Error reports with personal data removed | Yes (opaque account ID) | No | App functionality |
| Other Data | Children's data | Children's first name, age, grade, school, school ID photo | Yes | No | App functionality |

Third parties that receive data are listed in SECURITY.md part 2. Apple
also asks whether data is used for tracking: **No** for all.
