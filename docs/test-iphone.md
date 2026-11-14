# iPhone test script (Prompt 13, staging on TestFlight)

"Done when": you install **School Carpool Stg** from TestFlight and finish
this script with two test accounts. Tick each line; write what went wrong
next to it (screenshot + time) and send the list back. Fake data only
(staging): fake names, fake ID photos (the staging ID check is a fake that
accepts test images), test money.

## Before you start

| What | Account A ("Mona", driver) | Account B ("Hoda", parent) |
| --- | --- | --- |
| Phone | Your iPhone | A second iPhone (best), or the same iPhone after signing out |
| Number | A number with WhatsApp | Another number with WhatsApp |
| Child | "Adam", grade 3, school S | "Laila", grade 2, same school S |

- Staging must be ready: docs/testflight.md (build), SETUP.md 18.4
  (WhatsApp code template approved, or the staging fake sender: then the
  code is in the functions log), staging seeded with schools.
- An admin account for the panel (SETUP.md 13.2) on a laptop, to approve
  verifications.
- iPhone: iOS 16 or later; Settings > Privacy & Security > Location
  Services **on**; Low Power Mode **off** (it is tested on its own below).
- Language: start in **Arabic** (default); section Z repeats a few screens
  in English.

Legend: **Expect** = what must happen. "A" / "B" = which phone.

## 1. Sign-in and account

| # | Feature | Steps | Expect |
| --- | --- | --- | --- |
| 1.1 | F1 | A: install, open, enter number, Send code | WhatsApp code arrives within a minute; code screen with a 60 s resend timer |
| 1.2 | F1 | A: type a wrong code | "Wrong code" with tries left; no sign-in |
| 1.3 | F1 | A: wait 5 minutes, type the old code | "Code expired"; Resend works |
| 1.4 | F1 | A: right code, then email step, confirm email link | Signed in; consents asked once; email shown as confirmed |
| 1.5 | F44 | A: Profile | Parent ID: 8 characters, no 0/O/1/I; Copy button copies it |
| 1.6 | F44 | B: sign up the same way; Profile > copy B's ID; A: look up B's ID (Carpools > invite by parent ID or Wallet > Send > by parent ID) | Only B's first name and Verified badge (after 2.x) appear; never the number |
| 1.7 | F19 | A: Profile > Settings > Language English, then back to Arabic | Every screen flips direction; nothing cut off |

## 2. Verification (needs the admin panel)

| # | Feature | Steps | Expect |
| --- | --- | --- | --- |
| 2.1 | F2 | A: Verify banner > ID front, back, live selfie (follow the head-turn prompt) | Upload progress, then "In review"; screenshots blocked on the ID screens |
| 2.2 | F2, F14 | Admin panel: Queue > A's case > Approve | A gets "Verified" push/notification; Profile shows Verified |
| 2.3 | F2 | B: submit, admin **rejects** with a reason, B resubmits, admin approves | B sees the reason and how to fix it; then Verified |
| 2.4 | F18 | Admin case page | Automated check result shown (fake provider on staging) next to the images |
| 2.5 | F3 | A: Profile > Children > add Adam with school ID photo; edit grade; add a second child and remove it (asks first) | Changes saved; removal asks to confirm |
| 2.6 | F4, F40 | A: child's school: search in Arabic and in English (spelling slip), pick S; also "pick on the map" | One school per child; the school pin shows on A's map |
| 2.7 | F33 (driver details) | A: Profile > Driving: licence, car (plate, model, colour, seats), driver photo; admin approves | Driving details approved; A can be given driving days |

## 3. Maps and nearby

| # | Feature | Steps | Expect |
| --- | --- | --- | --- |
| 3.1 | F21 | A: Home > Home location > "Use my location" (allow While Using) | Pin moves to you; save; others see only an area (3.2) |
| 3.2 | F22 | B: Home > Parents nearby | A shows as a blurred area marker, first name, Verified, Message / Join |
| 3.3 | F24 | A: Profile > Driving schools: pick S | Search and nearby use this list |
| 3.4 | F23 | Admin verifies a third fake parent at school S near A | A gets "new parent nearby" (switch it off in Settings > Alerts and it stops) |

## 4. Carpools and schedule

| # | Feature | Steps | Expect |
| --- | --- | --- | --- |
| 4.1 | F5, F36, F25 | A: Carpools > Create: school S, area, times, days, 3 seats, rules "No smoking", contribution 50 EGP per week | Group created; rules and contribution visible |
| 4.2 | F6, F36 | B: Carpools > Search > A's group > Join (rules and contribution shown before) | A gets the request; Approve; B gets "approved" |
| 4.3 | F31 | A: carpool > Invite > WhatsApp; open the link on B | Link opens the app on the carpool (B must be verified to see it) |
| 4.4 | F32 | A third account with no group: Looking for a carpool | Visible to verified parents of the same school and area |
| 4.5 | F39 | A: create an **activity** carpool (a club) | Targets the place and days instead of a school |
| 4.6 | F26 | B: carpool > Drivers: approve A as a driver for Laila; then withdraw and approve again | Until approved A cannot carry Laila |
| 4.7 | F7 | A (admin of the group): Schedule > plan the week | Fair rotation; each morning and afternoon run has one driver |
| 4.8 | F37 | Schedule > Balance | Runs driven and received per family |
| 4.9 | F30 | A: Schedule > Days off and times: one holiday, one early-dismissal time | Runs on that day removed / moved; reminders follow |
| 4.10 | F28 | A: tomorrow's run > Confirm drive (before the confirm-by time). Leave another run unconfirmed past its time | Confirmed; the unconfirmed one alerts every parent (critical sound) |
| 4.11 | F11 | A: a run > Ask for swap; B takes it | Both told; schedule shows B as the driver |
| 4.12 | F27 | B: mark Laila away for tomorrow | A and the group told; Laila leaves that day's pickup list |
| 4.13 | F12 | A: evening before a driving day; one hour before | "Drive tomorrow" and "Drive soon" pushes (and WhatsApp if switched on) |
| 4.14 | F29 | B: Profile > Handover list: add "Gran" for Laila | A sees "Gran" on Laila's stop during the run |

## 5. Location gate (Prompt 13; A is today's driver)

Set up: a run today with A as the confirmed driver and Laila riding.

| # | Steps | Expect |
| --- | --- | --- |
| L1 | A: Settings > School Carpool > Location **Never**. Open the app > Home | Banner "Location is off" with **Steps**; the rest of the app works (chats, carpools) |
| L2 | A: Settings > School Carpool > Location **Ask Next Time** (so it is "not asked"), open the run > **Start run** | iOS asks location: options show **Allow While Using App** (never "Always"). Choose it. Then the notifications prompt (if never asked) |
| L3 | A: Settings > School Carpool > Location > **Precise Location off**. Start run | Full-screen "Before you drive" with only "Precise Location" and its 3 steps; Open Settings goes to the app's settings page |
| L4 | Turn Precise Location on in Settings, come back to the app | The page closes by itself and the run starts |
| L5 | A: Settings > Privacy & Security > Location Services **off**. Start run | "Location Services" with 4 steps (Settings > Privacy & Security > Location Services > on). Close (X): back on the run screen, no run started |
| L6 | A: Settings > School Carpool > Notifications off. Start run | "Notifications" item with steps; closes when allowed again |
| L7 | Everything on. Start run | Run starts at once; line "Keep the app open — you can lock the phone." on one line |
| L8 | During the run: Settings > Privacy & Security > Location Services off, back to the app | The steps show at once; B gets "Location stopped" within a minute; turn it on again: the steps close, tracking goes on (B's map moves again) |

## 6. The run (A drives, B follows)

| # | Feature | Steps | Expect |
| --- | --- | --- | --- |
| 6.1 | F38 | Start run (several days in a row) | Sometimes a live selfie is asked first; a passing selfie lets the run start |
| 6.2 | F15 | B: Alerts > "Run started" > open | Live map: A's car moving, arrival time for Laila's stop |
| 6.3 | F33 | B: carpool page today | Today's driver card: A's photo, car model, colour, plate |
| 6.4 | F41 | A: at B's home, **Arrived** | B: push with sound ("car outside") and WhatsApp; a second tap repeats it |
| 6.5 | F16 | A: Picked up, then at school Dropped | B gets each step |
| 6.6 | F35 | A: Running late, At the gate, All children in | Each posts to the carpool chat; no typing |
| 6.7 | F34 | Afternoon run: A drops Laila home; B does nothing for 10 minutes | Both get "child not confirmed" (critical). B confirms: the alert stops |
| 6.8 | F20 | A: Emergency (asks first) | Group alerted with location; the saved emergency contact gets WhatsApp |
| 6.9 | F15 | Last drop-off | Tracking stops by itself: "Run done"; the blue indicator disappears; B's map shows the run ended |

## 7. Lock screen, swipe-away and Low Power Mode (Prompt 13)

Use a short real drive (5 to 10 minutes) for each; B watches the map.

| # | Steps | Expect |
| --- | --- | --- |
| T1 | **Lock screen:** start the run, press the side button, drive 3 minutes | The blue location indicator stays (top left pill or arrow when unlocked); B's map keeps moving every few seconds; no "Location stopped" |
| T2 | **Other app:** during the run open Maps or WhatsApp for 3 minutes | Same as T1 |
| T3 | **Waiting:** stand still at a gate for 4 minutes with the app open or locked | B's map stays on the car; no "Location stopped" (a fix a minute is sent while still) |
| T4 | **Swipe the app away:** during the run, swipe School Carpool up in the app switcher | Within about 2 minutes: A gets "Run still on — open the app to continue" (push); B gets "Location stopped". Open the app from the push: the run screen comes back and tracking resumes (B's map moves) |
| T5 | **Low Power Mode:** Settings > Battery > Low Power Mode on, repeat T1 | Tracking continues (points may come a little less often); note the gaps you see on B's map. Write down if B got a "Location stopped" |
| T6 | **No signal:** drive through a garage / airplane mode for 1 minute during the run, then signal back | Points sent after signal returns (no gap on B's map after the run); taps made offline are sent once |
| T7 | Battery: note A's battery % at the start and end of a 20-minute run | Report the numbers (for the paid-plugin decision) |

## 8. Chat, reports, ratings

| # | Feature | Steps | Expect |
| --- | --- | --- | --- |
| 8.1 | F8 | B: A's profile > Message; A answers | Real time; push when the app is closed |
| 8.2 | F9 | A: Chats > school group S; area sub-group | Only verified parents of S; area group created automatically |
| 8.3 | F10 | Carpool chat | Only members; created with the group |
| 8.4 | F13 | B: report a message from A; block A | Report in the admin panel Reports; A cannot message B |
| 8.5 | F17 | After a shared run: Profile > Ratings > rate A | One rating per pair per month; vouch shown on A's summary |

## 9. Wallet (test money)

| # | Feature | Steps | Expect |
| --- | --- | --- | --- |
| 9.1 | F43 | A: Profile > Wallet > open the wallet (terms) > Add money (test) | Balance updates |
| 9.2 | F43, F25 | A: Send to B from the carpool (pay contribution) | B's first name and Verified shown first; Face ID asked; B gets "money received" |
| 9.3 | F43 | A: send more than the per-transfer limit | Refused with the limit |
| 9.4 | F43 | A: Withdraw (test) | Shown as pending, then done |

## 10. Notifications and settings

| # | Feature | Steps | Expect |
| --- | --- | --- | --- |
| 10.1 | F12 | A: Profile > Notifications: switch WhatsApp off for run updates, quiet hours on | Pushes respect them; critical alerts still sound |
| 10.2 | — | Alerts tab | Every notification listed; tapping opens the right screen |
| 10.3 | — | Profile > Settings > App lock on; leave the app 1 minute | Face ID asked when coming back; the app switcher shows a cover |

## 11. Privacy (Prompt 12) and the admin

| # | Feature | Steps | Expect |
| --- | --- | --- | --- |
| 11.1 | — | A: Profile > Privacy > Download my data | A file link; contents in JSON |
| 11.2 | — | A: sign in on a second phone | First phone is signed out; email + push "new phone"; chats, wallet and children closed on the new phone until the selfie check; **admin**: Users > A > Compare and decide > close it (logged) |
| 11.3 | F14 | Admin: suspend B, then unsuspend | B is signed out and cannot use the app while suspended |
| 11.4 | F14 | Admin: Schools > add a school with a map pin; Reports list | Saved; reports from 8.4 visible |
| 11.5 | — | B: Profile > Privacy > Delete account (only with an empty wallet) | Asks twice + Face ID; signed out; B is gone from the carpool, A's past runs show "L." for Laila |

## 12. Website (F42)

| # | Feature | Steps | Expect |
| --- | --- | --- | --- |
| 12.1 | F42 | Open the staging website on a laptop, sign in as B | Carpools, schedule, chat and the live trip map work; Start run is not offered (phone app only). Website work is Stage 2: note problems, not blockers |

## Z. English and dark mode spot check

Switch to English and dark mode (Settings), then open: Home (with the
location banner from L1), Carpools, a carpool, the run screen, the
"Before you drive" page (L3), Wallet, Privacy. **Expect:** left-to-right,
nothing cut off, every button and title on one line; with iPhone Settings >
Display & Brightness > Text Size at the largest, nothing overlaps.

## Done

Send back: the ticked list, the battery numbers (T7), the Low Power Mode
result (T5) and any screenshots. Known gaps are in docs/open-items.md.
