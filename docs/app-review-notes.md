# App Review notes (Prompt 13)

Paste section 1 into **App Store Connect > the app > App Review
Information > Notes** (English; Apple reviews in English). Fill the demo
account in **Sign-In Information** (section 2). Attach the run video
(section 4) as a link in the notes or upload it as an attachment.

## 1. Notes for the reviewer (copy from here)

> School Carpool is a free, non-profit app for verified parents in Egypt
> who share school runs: parents of the same school and area take turns
> driving each other's children.
>
> **Background location.** The app uses location in the background ONLY
> while a parent drives a school run they started themselves (Start run on
> the run screen). During that run, the parents of the children in the car
> see the car on a map and get "car outside" and arrival-time updates. To
> start a run the app needs only "While Using the App" with Precise
> Location; tracking keeps going with the phone locked or another app open
> through the location background mode, and iOS shows the blue location
> indicator the whole time. Tracking stops automatically at the last
> drop-off, when the driver ends the run, and after 4 hours at the latest.
> Live points are deleted within 24 hours. Parents who do not drive are
> never tracked. Without Location Services, location permission and
> Precise Location, a parent can still use the whole app except starting a
> run; the run screen shows the steps to turn them on.
>
> **"Always" is optional.** Before a driver's first run, one screen offers
> "Always" so that, if iOS closes the app during a run, the run usually
> resumes by itself within a few minutes after the car moves (significant
> location changes relaunch the app; it then checks the run is still on and
> shows "Tracking resumed"). It is used only for
> drivers during school runs they start, with the blue indicator, and ends
> with the run. Declining changes nothing else: the app works the same and
> asks the driver to keep the app open during the run.
>
> **Sign-in.** Parents sign in with a one-time code sent by WhatsApp (no
> SMS, no password). For review, the demo phone number in Sign-In
> Information accepts the fixed code given there; no WhatsApp message is
> needed. This review code works for that one number only and is switched
> off after the review.
>
> **Demo account.** The demo account is an already verified test parent
> in a test carpool with test children (fake data). To see a run: Carpools
> tab > the test carpool > Schedule > today's run > Start run (allow
> location "While Using the App", Precise Location and notifications when
> asked). The attached video shows a full run recorded on an iPhone.
>
> **Identity check.** Real parents are verified with an ID photo and a
> live selfie before they can join carpools. The demo account is already
> verified, so you do not need to upload any document.
>
> **Wallet.** The wallet in this build is a test wallet with test money
> (no real payments, no in-app purchases). Real money will only be handled
> by a payment partner licensed by the Central Bank of Egypt.
>
> **Camera and photos** are used for the ID check, the live selfie and
> photos a parent chooses to send in a chat. **Face ID** locks the app (if
> the parent turns App lock on) and confirms wallet transfers.

## 2. Demo account (owner fills in App Store Connect, never here)

- **User name:** the demo phone number (an Egyptian mobile number you own
  and use only for the test account, for example a spare SIM). Not
  written in this repository.
- **Password:** the 6-digit review code. Not written in this repository.
- Prepare the account in the project you submit (staging for TestFlight
  external testing; prod for the App Store): verified, in a test carpool
  with one test child, with a run today (create the run the evening
  before review, or use the seed script on staging).
- **New-phone check:** Apple's device is a new phone for this account, so
  signing in there signs your own phones out of it, and for an account
  with a face reference it opens a new-phone selfie check (chats, wallet
  and children closed; Valify's face match is a stub until the contract,
  so it waits for an admin). Either seed the demo account **without** a
  face reference (verified by an admin, no identity selfie), or watch the
  admin panel during the review and close the check: Users > the demo
  parent > **Compare and decide** > "Confirmed another way" (reason
  Review). Do not use the demo account on your own phone during the
  review.

## 3. Review sign-in code (server setting, off by default)

The server accepts a fixed code for ONE allow-listed number while the
setting is on (`functions/src/auth/otp_flow.ts`, `config/reviewAccess`).
Every sign-in limit and lock still applies; nothing is sent by WhatsApp
for that number; only keyed hashes are stored; it switches itself off at
its expiry (at most 30 days).

Turn it on before you submit (from your Mac, signed in to gcloud as a
super admin of that project). The number and code are read from the
environment, so they do not end up in your shell history if you type them
at the prompts:

```bash
read -s -p "Review phone: " REVIEW_PHONE; echo
read -s -p "Review code (6 digits): " REVIEW_CODE; echo
read -s -p "OTP_HMAC_KEY (Secret Manager): " OTP_HMAC_KEY; echo
export REVIEW_PHONE REVIEW_CODE OTP_HMAC_KEY
GCLOUD_PROJECT=<project-id> npm --prefix functions run review-access -- on 14 <your-super-admin-uid>
unset REVIEW_PHONE REVIEW_CODE OTP_HMAC_KEY
```

`OTP_HMAC_KEY`: Google Cloud console > Security > Secret Manager >
`OTP_HMAC_KEY` > latest version > View secret value. Codes like 123456 or
111111 are refused. Turn it off when the review is done:

```bash
GCLOUD_PROJECT=<project-id> npm --prefix functions run review-access -- off <your-super-admin-uid>
```

Both are written to the admin audit log.

## 4. Recording the run video on your iPhone (about 10 minutes)

Apple often asks for a video that shows why background location is
needed. Use the staging TestFlight build and the two test accounts.

1. **Prepare:** phone A (driver, test account 1) and phone B (parent,
   test account 2), both in the same test carpool with a run today, phone
   A's run confirmed. Charge both. Turn on **Do Not Disturb** so personal
   notifications do not appear. Use a route of 2 to 3 minutes near home.
2. **Screen recording on phone A:** Settings > Control Center > add
   **Screen Recording**. Swipe down from the top right corner, long-press
   the record button, keep the microphone off, tap Start Recording.
3. On phone A, show in order (about 10 seconds each):
   1. The run screen and **Start run**.
   2. The location prompt choosing **Allow While Using App** (first time
      only; otherwise show Settings > School Carpool > Location = While
      Using the App, Precise Location on), then the optional "Resume runs
      by itself" screen (show both buttons; choose either).
   3. The running run screen with the line "Keep the app open — you can
      lock the phone."
   4. Press the side button to **lock the phone**, drive about a minute,
      unlock: the **blue location indicator** (pill or arrow at the top)
      is visible while the app is in the background.
   5. Tap **Arrived**, **Picked up**, then **Dropped**: tracking stops by
      itself (the run screen says the run is done, the blue indicator
      goes away).
4. Stop the recording (red pill at the top > Stop). It is in Photos.
5. Optional but helpful: record phone B at the same time showing the car
   moving on the map and the "car outside" notification.
6. Trim the start and end in Photos (Edit), make sure no personal data
   (real names, real home addresses) is visible, and upload it (App
   Review attachment, or an unlisted link in the notes).
