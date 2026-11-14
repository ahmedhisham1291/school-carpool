# Improvement B review: own chat on Firestore (replaces Stream Chat)

Branch `improve-b-firestore-chat`, head `d98ec76`. Reviewed
`git diff main...HEAD` (74 files) against CLAUDE.md, docs/DECISIONS.md
(data retention; "Improvements, revised" item 3), docs/spec.md (F8, F9,
F10, F13), docs/reviews/prompt-09-review.md and docs/progress/improve-b.md.
Date: 14 Nov 2026.

## Verdict: FAIL (two small blockers)

No way was found for a non-member, a removed member, a blocked parent, a
muted parent or a verified parent of another school to read or write a
message or a photo, or to forge a sender or a time, with a **new** request.
The rules, the trigger and the retention code are careful work. Two things
must change before the merge, both small; one behaviour (open listeners
after removal, item V1) can only be proven on the real staging project and
decides whether "removed at once" is true.

## What was run

- CI run 43636722210 on `d98ec76`: green in branch mode (as reported by the
  coordinator; not re-run, no workflow started).
- Here: Cloud Functions unit tests, `node --test lib/test/*.test.js` after
  `tsc`: **641 pass, 0 fail** (the known type-stub errors, files emitted).
- Not run here: Flutter analyze and tests, rules tests (no SDK, no
  emulators). Everything about them below is from reading.
- Checked on the web: the IAM role and the service agent (section
  "Deploy safety").

## Blockers

### B1. The branch does not contain `main`; the green CI run is not for what will be merged

- Where: `git merge-base --is-ancestor main HEAD` is false. `main` is at
  `2631923` (workstream A: feature switches, Settle up F45, 100 files);
  none of it is in this branch.
- Why it matters: A changed `firestore.rules`, `functions/src/index.ts`,
  `functions/.env.staging` and `firestore.indexes.json`, and Settle up
  reads `chatBlocks` (see "F13" below). A trial merge
  (`git merge-tree HEAD main`) gives **one conflict:
  `firestore.indexes.json`** (both sides add entries; keep both). The other
  files merge by themselves, but no test has run on the result (rules
  tests one file at a time, the privacy test that classifies every
  collection, Settle up's "same document ID as the chat feature" test).
- Fix: merge `main`, resolve `firestore.indexes.json` by keeping both
  sides' entries, run CI once in branch mode. No code change expected.

### B2. Any member can list the member documents of a whole school group, with moderation flags

- Where: `firestore.rules:546`
  (`allow list: if inChat(cid) && request.query.limit <= 50;` under
  `chats/{cid}/chatMembers/{uid}`).
- Why: a member of a school group (up to 5,000 parents) can page through
  all member documents 50 at a time with a modified client: every parent's
  uid and first name, and `active`, `cut` (suspended, banned, unverified or
  deleted), `frozen` and `mutedUntil`. That is a list of the school's
  parents plus who was sanctioned. Prompt 9's blocking item 1 ("list every
  user") must stay fixed; this is the same class, limited to one school.
  **The app never lists members** (`chat_backend.dart:164` reads one
  document by ID), so the rule opens something no feature uses. The
  progress file's table says "No listing".
- Fix: `allow list: if false;` on `chatMembers`, and change the rules test
  "a member reads the head, the members and the newest messages" so a
  member's `collection('chatMembers').limit(50).get()` is refused while
  `doc(uid).get()` still works.
- Follow-up (not blocking, see N2): `get` still shows `cut` and
  `mutedUntil` of any member whose uid is known from a message.

## Security and privacy: what holds

Rules (`firestore.rules:461-592`, `storage.rules:82-126`), by reading:

- **Read**: head, members (get), messages and reads need the caller's own
  member document with `active == true` and `cut != true`, read on every
  request, plus `verified` and the session and new-phone checks. No chat
  list (`chats` list is false). Messages and reads list only with
  `limit <= 50`. Collection-group queries on `messages`, `chatMembers`,
  `reads` and `summaries` match no rule (the matches are full paths, there
  is no `{path=**}` rule), so they are refused; the rules test covers
  `messages` and `chatMembers`.
- **Write**: a message is create-only, `senderUid == request.auth.uid`,
  `createdAt == request.time`, exactly the fields of its kind, text 1 to
  2000, the photo path fixed to the sender's own folder and the message
  ID, the pin in range; photos and pins only in private and carpool chats;
  frozen and muted members refused; no update, no delete. Nothing from the
  app writes the head, member documents, the registry, mutes, limits,
  reports or a chat list row except the three read fields (`unread` to 0,
  `readAt` server time, `readSeq`). A failed evaluation (missing claim,
  missing document) denies.
- **Photos**: member-only get, upload only into `{uid}` == own uid, once
  (`resource == null`), WebP or JPEG under 3 MB, message-ID name, no list,
  update or delete. `firestore.exists` and `firestore.get` hit the same
  document, so one billed read per request and one of the two documents a
  Storage rule may read.
- (a) non-member, (e) parent of another school: no member document, all
  refused. (b) removed: `active false`, refused; the row closes. (c)
  blocked: the private chat is frozen for both, no new message, pending
  requests cancelled; in groups the blocker gets no push and the app hides
  the messages (as accepted in Prompt 9). (d) muted: no message, no photo
  upload; read marks still allowed (harmless).
- Rules tests (`tests/rules/own_chat.test.ts`, 22 cases) cover each of
  these, including other sender, other time, extra and missing fields,
  frozen, muted, edit, delete, Storage overwrite and listing. Gaps: N12.

Functions:

- Membership sync, exclusion after admin removal, suspension and ban cut
  (`cut` on every member document, `open false` on every row), restore,
  account deletion (cut at once, initial instead of the first name,
  private chats ended, chat list deleted) are as described and tested.
- **F13 / Settle up dependency: unchanged.** `chatBlocks/{blocker}_{blocked}`
  (`functions/src/chat/model.ts:236-246`,
  `functions/src/chat/firestore_store.ts`, not in the diff). `main`'s
  `functions/src/settle_up/store.ts:43-47` builds the same ID.
- Push: one `chat-message` event with a fixed text; the event carries the
  actor uid, the chat ID and the carpool ID only. Logs carry kind, reason
  and counts; no text, name or coordinate was found in any log or Sentry
  call.
- Reports: context is built from Firestore with names from our own
  records; a photo is only marked `"image"`, its path is never copied.
- Retention: ended chat deleted whole a year later (messages, members,
  reads, rows, the photo folder by prefix with the trailing "/"); a closed
  account's messages and photos a year after closure; export of own
  messages (5,000 newest, marked as cut when full).
- Prod refuses the fake provider (`server.ts:503-510`); callables keep
  `enforceAppCheck`.
- No Stream code, package, secret binding, webhook or script is left.
  Remaining mentions are history or the owner's source documents
  (docs/spec.md, docs/build-prompts.md, old progress and review files).

Prompt 9 findings: forged names cannot come back (a message has no name
field and takes no extra field); the pin and photo are refused in school
and area groups by the rules, the trigger and the app
(`conversation_screen.dart:343-345`); the EXIF check is unchanged.

## Non-blocking findings

Ordered by importance. N1 to N4 should be done before the pilot with real
parents.

**N1. Chat stays in the phone's Firestore cache after sign-out (a step
back from Stream).** `chat_session.dart:60` only cancels listeners; nothing
calls `terminate()` / `clearPersistence()`. The old code flushed Stream's
local store on disconnect. Message text, first names, exact location pins
and photo paths of the last account stay in the app's sandbox. How
serious: **medium**. The stock app does not show them to the next account
(its chat list is `userChats/{its own uid}`, and a conversation without a
row shows an error), and the files are protected by iOS Data Protection.
But the SDK's document cache is not separated by account, so a modified
build, or anyone who can read the sandbox, reads them without the server
ever being asked; a shared family phone makes "next account on the same
phone" a real case. Also: a message queued offline by A is kept and sent
when A signs in again. What to do: on sign-out (and on account switch),
after the chat provider disconnects, `await FirebaseFirestore.instance.terminate()`
then `clearPersistence()`, before the next sign-in touches Firestore; add
a test step in docs/test-iphone.md (airplane mode, sign out, sign in as B).
This also closes the same gap for exact pickup points (D22, STORAGE-1).

**N2. Member documents show sanctions to other members.** After B2, a
member can still `get` `chatMembers/{uid}` for any uid seen on a message
and read `cut`, `frozen`, `mutedUntil`. Split the document: names in
`chatMembers/{uid}` (members read), the access fields in a document only
its owner's requests read through the rules (for example
`chats/{cid}/access/{uid}`, `allow read: if false`), in both rules files
and `firestore_data.ts`.

**N3. Storage rules skip the signed-out and new-phone checks.**
`storage.rules:101-108` checks `verified` and the member document only.
After "sign out my devices" (stolen phone) or a sign-in from a new phone,
Firestore is closed at once but an old token can still fetch chat photos
whose paths it knows (they are in the phone's cache, N1) for up to an
hour, and upload into a chat. The progress file says a second read is not
possible; it is: a Storage rule may read two Firestore documents and uses
one. Add `firestore.get(.../users/$(request.auth.uid))` with the same
`sessionsValidAfter` and `newDeviceCheck` tests as `firestore.rules:36-49`
(one more read per photo request).

**N4. A refused message can stay.** `callables.ts:220-247`: the trigger
has `retry: false` and swallows every error, and it has no warm instance.
A message over the limit or with a blocked term is visible to every member
who has that chat open from the write until the trigger deletes it: one to
three seconds warm, ten or more on a cold start, **and for good if that
run fails** (a transaction conflict, a timeout). It never reaches the chat
list or a push. Fix: split the trigger in two steps: removal (limit,
blocked terms, invalid) may throw and be retried (`retry: true` with the
6-hour age guard used by the other triggers; removal is idempotent), the
counters stay best effort. SETUP 19.4 should say "usually within seconds".

**N5. Photo uploads have no limit and orphans are never purged.**
Any member of one small chat can upload 3 MB files without end
(`storage.rules:117-124`; the name is any 8 to 64 characters and no
message is needed); the sending limit counts messages only. An upload
whose message is then refused or never written also stays. Such files are
deleted only when the whole chat is deleted (`firestore_data.ts:388`);
`deleteMessagesBy` (`firestore_data.ts:368-375`) removes only photos that
a message names, so a closed account's orphan photos outlive "1 year after
closure" in a carpool chat. Fix: a daily sweep in `retentionDaily` over
`chatPhotos/` that deletes files older than a day with no message of that
ID, and in `deleteUser` delete the prefix
`chatPhotos/{type}/{id}/{uid}/` for every chat of `chatsOf(uid)`. Mute the
parent when the sweep finds many orphans.

**N6. Fan-out is not safe against a second delivery in every case.**
`fanout.ts:134-143` recognises a duplicate only while it is still the
head's `lastMessageId`; after another message, a second delivery counts
`seq` and `unread` again. `takeLimit` (`fanout.ts:122`) runs before the
duplicate check, so a duplicate also uses up the sender's limit, and a
duplicate that lands over the limit deletes a message that was already
accepted. Fix: `create()` a marker (the existing `chat_<hash>` event ID, or
`chats/{cid}/fanned/{messageId}` with a TTL) first and return when it
exists.

**N7. The sending limit is the same for every kind of chat and costs a
lot when hit.** 30 a minute lets one parent post 1,700 messages an hour
into a 5,000-parent group without ever being muted. Each over-limit
message runs `chatsOf` (a query) and one write per chat of the sender
(`fanout.ts:125`), even when they are already muted. Fix: skip the patch
when `mutedUntil` is already in the future; add a lower limit for school
and area groups (for example 5 a minute and 60 an hour).

**N8. `addMembers` always writes `cut: false`** (`server.ts:163-168`). Every
caller checks eligibility first, so today this only matters when a
suspension lands between that check and the write; then the suspended
parent keeps that one chat until the next sync. Keep `existing?.cut`, or
take eligibility from the account inside `addMembers`.

**N9. A photo whose upload succeeded but whose answer was lost can never
be sent.** `firestore_chat_provider.dart:546-556`: the retry uploads
again, the rules refuse a second upload under the same name, and the
bubble stays "Not sent". On a failed upload, try the message write when
the file is already there (`getMetadata`), or retry under a new message
ID.

**N10. Listeners are not cancelled when membership is lost while a chat is
open.** The screen shows the error state after the 3-second grace
(`firestore_chat_provider.dart:390-399`) but the conversation's listeners
live until the screen closes. Dispose the conversation when `notMember`
is raised. This is tidiness on the stock app; the server side is V1.

**N11. Marking read: no loop found, one edge.** A mark is made once per
new state, `_marking` blocks a second one in flight, offline it waits in
Firestore's queue. If a mark were refused every time while the row is
still readable, each cache revert would start another attempt; no such
state exists with today's rules. Add a small counter (stop after three
failures until the chat is opened again).

**N12. Rules tests to add:** `collectionGroup('summaries')` and
`collectionGroup('reads')` refused; a token older than
`sessionsValidAfter` refused for messages and (after N3) photos; a member
doc with `mutedUntil` exactly in the past by one second may write; a
parent verified in another school with a member document in a different
chat only.

**N13. Blocked parent's text in the blocker's chat list.** In a carpool
chat the row's `last` preview (80 characters) is written for every member
(`firestore_data.ts:292-303`), the blocker included; the conversation
hides the message but the list shows its start. Skip `last` for members
in `blockersOf(sender)`, or hide the preview in the app.

**N14. Smaller points.**
- `firestore_chat_provider.dart:421-429`: the name lookup is a server read
  per author per session (3 billed reads with the rules' own lookups), not
  "kept in Firestore's cache" as COSTS says.
- `chat_backend.dart:154`: paging by `createdAt` alone skips a message
  that has exactly the page edge's timestamp; page by document snapshot
  or add the ID as a second order.
- `server.ts:226-229`: `setFrozen` walks up to 5,000 members one write at a
  time; fine for private and carpool chats, slow if a school group is ever
  frozen.
- `deleteUser` keeps the member documents (uid and an initial) for the
  life of the chat; say so in docs/app-store-privacy.md if not there.
- A suspended parent stays in a carpool chat's registry and is still a
  push recipient ("You have a new message"); the push sender should skip
  accounts that are not eligible.
- Photos are held in memory only (40); every new session downloads them
  again (Storage download volume and one Firestore read each).

## Cost

Counted from the code for the COSTS.md example parent (5 chats, 6 app
starts, 4 chat opens, 10 sent, 40 received):

| Part | COSTS.md | From the code |
| --- | --- | --- |
| Phone reads | about 300 | 330 to 400: marking read and typing each cost about 2 rule reads per write (COSTS says 0), and each author's name is 3 reads, not a cache hit |
| Phone writes | about 35 | about 35 |
| Server reads for 10 messages | about 60 | about 120 to 150: the push sender's lookups per recipient (devices, settings) are not counted |
| Server writes for 10 messages | about 80 | about 120 to 130: one `chatPushes` record per recipient is not counted |
| **Per active parent per day** | **360 reads, 115 writes** | **about 500 reads, 160 writes** |

So the free quota covers about 100 to 120 parents who chat every day, not
140. Same order of size; correct the table and the "85 parents" trigger
(about 60 to 70).

What grows with group size per message:

1. The head write of a school or area group: one read for every parent
   with the chat list open (documented, D21).
2. `muteChoices(cid)` (`chat/firestore_store.ts:354`): one read per parent
   who ever chose a mute setting in that group, up to 5,000, on every
   message. Keep the unmuted uids on the registry document instead.
3. The registry document with up to 5,000 uids is loaded per message (one
   read, about 150 KB).
4. Push records: one write per recipient who is not muted (all members up
   to 50; in larger groups those who unmuted).
5. Small chats: one row write per member (at most 50), and each row write
   is one read on that member's phone when the list is open.
6. Over-limit messages: N7.

## Deploy safety (staging is already set up)

- **Role and agent: correct.** Google's IAM reference lists
  "Firebase Rules Firestore Service Agent" as
  `roles/firebaserules.firestoreServiceAgent`, with the single permission
  `datastore.entities.get`, for service agents only
  (docs.cloud.google.com/iam/docs/roles-permissions/firebaserules).
  Firebase's service account page gives the Cloud Storage for Firebase
  agent as `service-PROJECT_NUMBER@gcp-sa-firebasestorage.iam.gserviceaccount.com`
  (firebase.google.com/support/guides/service-accounts). Firebase's
  announcement of cross-service rules says the console or the CLI offers
  to add the permission on the first publish, that each lookup is a billed
  Firestore read even when the request is refused, and that a rule may
  read two documents. `tool/cloud_setup.sh:307-312` and SETUP 19.2 match.
  From memory of the CLI's source, not confirmed here: a non-interactive
  deploy skips that offer, so the explicit grant in the script is needed;
  it is there, before the deploy.
- **Removed functions**: `getChatToken` and `chatWebhook` are deleted by
  `firebase deploy --force` (`cloud_setup.sh:613`). A build made before
  this branch calls `getChatToken` and its chat stops: deploy and the new
  TestFlight build belong together.
- **Indexes**: collection group `messages (senderUid, createdAt desc)` and
  the `chatMembers.uid` field override with collection-group scope are in
  the file. Until `chatMembers.uid` is built, `deactivateUser` fails and
  the trigger retries (up to 6 hours): do not test suspension in the first
  minutes after the deploy. Remember the merge conflict in this file (B1).
- **Params**: every non-secret param of `functions/src/config.ts` is in
  `.env.dev`, `.env.staging` and `.env.prod`
  (`CHAT_PROVIDER=firestore`, `CHAT_MESSAGES_PER_MINUTE=30`,
  `CHAT_MUTE_MINUTES=10`); the six missing names are secrets. No function
  binds `STREAM_API_SECRET` any more.
- No TTL change. `tests/rules` now run one file at a time (slower, fine).

## Tests with real time

The three provider tests (group mark, typing line, "not a member") use
600 ms timings and real waits of 1.2 to 2 s. Flakiness risk: **low**. In
each, the provider's timer is created before the test's own longer delay
in the same isolate, so it fires first however slow the runner is; what
follows the timer is microtasks only. Cost: about 4.5 s of real time per
run. They would break only if the fake backend gains real delays.

More robust: `fakeAsync` from `package:fake_async` (already resolved
through `flutter_test`; name it in `dev_dependencies`) with the provider's
`clock` taken from `package:clock`. Inside `fakeAsync`, never `await`:
call `async.flushMicrotasks()` and `async.elapse(...)`, and cancel
subscriptions without awaiting. The earlier hang came from awaiting
`cancel()` under `testWidgets`, not from fake time itself.

## Only on real iPhones or the real staging project

- **V1 (decides "removed at once").** Two phones in one carpool chat, both
  with the conversation open. Remove B (leave the carpool, admin removal,
  suspension) and send from A. The rules tests prove a **new** request by
  B is refused; they do not prove that B's **already open** message
  listener stops. If B still receives new messages, a modified client can
  keep reading until its stream is re-established, and the claim in
  `firestore.rules:464-469` is too strong. Record the result in
  docs/test-iphone.md; if it fails, say so in SECURITY.md and treat N10 as
  required (it does not stop a modified client; the bound is then the
  listener's re-authorisation).
- Photo upload from iOS against the `resource == null` rule (the SDK's
  upload protocol), and photo read with `mutedUntil: null` in the member
  document through the real cross-service lookup (the emulator once failed
  on null fields).
- App Check enforcement on Firestore listeners and Storage downloads in
  staging.
- Trigger delay on a cold start: time from sending a blocked term to its
  disappearance on the second phone (N4).
- Offline: text queued in airplane mode is sent once on return; a photo
  shows "Not sent"; N9 by cutting the connection during an upload.
- Sign-out on a shared phone (N1): airplane mode, sign in as another
  parent, nothing of the first parent's chats is shown.
- The deploy itself on staging: the two functions are deleted, both
  indexes finish building, the role is granted, then test-iphone 8.1 to
  8.14.
- Push text and badge on a locked phone; muted group gives no push.
- Screenshots in Arabic and English, light and dark (CI artifact; not
  looked at here).

## Re-review

After B1 and B2: the merge commit, the one rules line and its test, and
the CI run on the merged head. Nothing else needs a second look unless N1
to N4 are done in the same round.
