# Improvement B: own chat on Firestore (replaces Stream Chat)

Branch `improve-b-firestore-chat` (from `main` at `97c2ace`). Date: 14 Nov
2026. Owner decision: DECISIONS.md "Improvements, revised", item 3. The
coordinator gave "go" on the owner's behalf. **Not merged: the coordinator
merges this only after the first TestFlight build runs on the owner's
iPhone.** `main` has moved since (two commits in `tool/cloud_setup.sh` and
DECISIONS.md); the merge will touch `tool/cloud_setup.sh` near the Storage
agent lines.

**Status: code complete. Cloud Functions unit tests were run here: 641
pass, 0 fail (Node 22, the usual stand-in stubs; `tsc` prints 163 type-stub
errors, 156 known plus 7 of the same kind in the new
`firestore_data.ts`, and still emits). The Flutter code, the Flutter tests,
the rules tests and `firestore_data.ts` against a real Firestore were
written, not run here** (no Flutter SDK, no npm registry, no emulator in
this workspace). Expect small analyzer fixes on the first CI run, most
likely in `lib/features/chat/firestore_chat_provider.dart` and
`chat_backend.dart` (new files that could not be compiled here).

## After the first CI run (43632098644)

The coordinator merged `main`, refreshed the lock files and fixed two
analyzer findings. The Flutter job was cancelled before it finished (result
unknown); the rules tests had 4 failures, all in `own_chat.test.ts`:

1. **"the owner may only mark a chat read": a test bug, the rules were
   right.** The refused write set `frozen: false` on a row whose `frozen`
   was already false, so nothing but the three allowed fields changed and
   the rules correctly let it through. The test now tries real changes
   (`frozen: true`, `memberCount: 99`). No rule was loosened.
2. **Chat photo uploads by members were refused (3 subtests).** Two
   changes, because the emulators cannot be run here to tell the causes
   apart:
   - Most likely cause: the Storage emulator answers `firestore.get()`
     from the project the emulators were started with
     (`demo-school-carpool`), while the test seeded the member documents
     in its own project ID. The test now uses `demo-school-carpool` (no
     other rules test does).
   - Also removed the ":" from Storage paths, as asked for that case:
     photos now live in `chatPhotos/{type}/{id}/{uid}/{messageId}` (the
     chat ID with "/" in place of ":"), in `storage.rules`,
     `firestore.rules` (the `photoPath` check), the app
     (`photoPathFor`), the server (`photoFolder`, `photoPathOk`, the
     ended-chat purge) and every test. The Firestore document ID keeps
     its ":" (those rules tests passed).

Also re-read the new Dart files for the analyzer: subscriptions are now
cancelled by a call the lint can see (not a tear-off), the photo cache is
a plain map literal, one `is Map` got its type arguments.

Functions tests after these changes: 641 pass, 0 fail (run here). Rules
tests and Flutter: still written, not run here.

## After the second CI run (43632599130)

`flutter analyze`: no issues. Functions: 641 pass. The project ID change
fixed the member uploads. The Flutter test step was cancelled again
(result unknown). Rules: 538 pass, 4 fail, fixed as follows:

- **The rules test files ran at the same time and shared state.** The
  Storage emulator is one store for every file (`clearStorage` empties it
  for all), and since the last change `own_chat.test.ts` seeds members in
  the emulators' own project, which the Storage rules read for EVERY file.
  So `deny_all` saw Alice as a member of own_chat's chat, and own_chat's
  seeding raced with other files' resets (failures 1 to 3). Now:
  `tests/rules/package.json` runs one file at a time
  (`--test-concurrency=1`); `deny_all` uses a chat ID nobody seeds;
  `own_chat` clears Firestore and Storage when it ends.
- **A second upload over the same photo name was allowed** (failure 4): a
  real gap in `storage.rules`. `allow create` now also requires
  `resource == null`.
- `storage.rules` checks that the `verified` claim exists before reading
  it, so a token without it is refused without an evaluation error. The
  same error in `firestore.rules` comes from the shared `verifiedParent()`
  helper every feature uses (it still denies); not changed here.

Not run here: the rules tests (no emulators).

## After the third CI run (43632981739)

Analyze clean, functions 641 pass, rules 541 pass / 1 fail, Flutter tests:
2 failures seen before the job was cancelled (more may be behind them).

- **Rules, "not twice":** the first upload was refused because an object of
  that name was still in the Storage emulator from an earlier subtest
  (`clearStorage` did not remove it), which the new `resource == null`
  rule correctly treats as a second upload. The rule stays; every upload
  that must succeed now uses a name that is new per run and per test.
- **Flutter, older page (45 expected, 30 seen): the test, not the
  provider.** The merged list is emitted on the stream a moment after
  `loadOlder()` returns; the test now waits for it.
- **Flutter, mark read called three times: a real provider bug.** After a
  mark finished, the provider looked again while still holding the row
  from before its own write and marked the same state again (each mark is
  a paid write). It now remembers what it marked (the row snapshot in
  small chats, the head's counter in groups) and never marks the same
  state twice; a failed mark is retried on the next change, not in a loop.

Not run here: rules tests and Flutter tests.

## After the fourth CI run (43633558482)

Functions and rules tests all green, analyze clean. Three tests in
`test/chat/firestore_chat_provider_test.dart` hung (school group mark,
typing line, info "not a member").

- **Cause (by reading, not reproduced here):** those three ran under
  `testWidgets` for its fake clock, and awaited a stream subscription's
  `cancel()` there. That future belongs to the real event loop and its
  continuation lands in the fake one, which nobody runs any more: the test
  waits forever. The provider itself has no path that waits forever.
- **Fix:** the provider takes its waiting times as `ChatTimings` (defaults
  unchanged: typing line 6 s, typing write every 4 s, group "read" write
  every 5 s, "not a member" after 3 s). The three tests are plain tests
  again with 600 ms timings and real short waits; no fake clock, no new
  package (`fake_async` is only a transitive dependency). Each has a
  30-second timeout and the two stream groups a 60-second one, so a hang
  fails fast.
- **Mark-read re-check:** read again after the last fix. A mark always
  happens for a new state (first head, a newer counter, a new row); a
  failed mark is tried again on the next change. One real weakness fixed:
  when the group timer fired a moment early by the clock it waited a whole
  second interval; the timer's own call now skips the clock check.

Not run here: Flutter tests.

## Plan that was followed

1. **Server** (`functions/src/chat/`): a `firestore` provider behind the
   existing `ChatServer` interface; the `stream` provider, its REST client,
   token issuance, the webhook and the setup script are gone. It projects
   the channel registry (`chatChannels`, unchanged, Functions only) into
   the documents the phone reads. A trigger on message create does the
   fan-out. `CHAT_PROVIDER` = `fake | firestore` (default `firestore`;
   prod refuses `fake`).
2. **Rules**: `firestore.rules` and `storage.rules` for the new paths, with
   emulator tests; indexes for the server's collection-group queries.
3. **App**: `FirestoreChatProvider` behind the unchanged `ChatProvider`
   interface, written against a small `ChatBackend` so its logic is tested
   without Firebase. The screens did not change (one exception: a chat
   photo is now loaded through the provider, not from a web link).
4. **Privacy and retention**: export, account deletion, the 1-year purge
   and the ended-chat purge work on Firestore and Storage.
5. **Docs and setup**: SETUP 19 (rewritten), COSTS, app-store-privacy,
   testflight, open-items, test-iphone, restore-test, owner-cloud-shell,
   SECURITY, `tool/cloud_setup.sh`, `tool/setup_retention.sh`.

## What was built

### Data model

Kept as before (Cloud Functions only write; rules unchanged):
`chatChannels/{cid}` (the registry: members, excluded, frozen, endedAt),
`chatMemberships`, `chatRequests`, `chatBlocks`, `chatMutes`,
`chatSettings`, `chatLimits`, `reports`, `users/{uid}/chatPushes`.

New (the chat ID `cid` is still "type:id", for example `cp_carpool:c-<id>`;
routes and pushes did not change):

| Document | Holds | Who reads | Who writes |
| --- | --- | --- | --- |
| `chats/{cid}` (the head) | kind, names AR/EN, memberCount, frozen, `seq` (message counter), lastAt, last (kind, sender, text cut to 80), lastMessageId | Current members | Functions |
| `chats/{cid}/chatMembers/{uid}` | uid, firstName, `active`, `cut`, `frozen`, `mutedUntil`, joinedAt | Current members (one, or 50 at a time) | Functions |
| `chats/{cid}/messages/{id}` | senderUid, kind (`text`, `photo`, `location`), text or photoPath or lat/lng, createdAt | Current members (50 per query at most) | The sender creates (strict rules); nobody edits; Functions delete |
| `chats/{cid}/reads/{uid}` | readAt, typingAt (private and carpool chats only) | Current members | The parent, their own only |
| `userChats/{uid}/summaries/{cid}` (a chat list row) | kind, names, otherUid and otherName (private), `muted` (null = no choice), frozen, `open`, memberCount, `unread`, `readSeq`, readAt, lastAt, last | The parent, open rows only | Functions; the parent may only set unread 0, readAt (server time), readSeq |
| Storage `chatPhotos/{type}/{id}/{uid}/{messageId}.webp` or `.jpg` (the chat ID with "/" in place of ":") | A chat photo (WebP or JPEG, under 3 MB, EXIF removed on the phone) | Current members of that chat | The member, into their own folder, once; Functions delete |

Membership as the rules see it is the member document, read on **every**
request: `active` (in the chat), `cut` (account suspended, banned,
unverified or deleted), `frozen` (block, closed carpool: read only),
`mutedUntil` (sent too fast: read only until then). Nothing depends on a
token claim that lasts an hour, except "verified" itself, which every
other rule in the app uses too; the session and new-phone checks
(`deviceChecked`) apply as elsewhere.

### Server (`functions/src/chat/`)

- `data.ts`: the `ChatData` interface (the documents above) and its types.
  `firestore_data.ts`: the Firestore and Storage implementation.
  `test/helpers/memory_chat.ts`: the in-memory one for tests.
- `server.ts`: `ChatServer` (same shape; `createToken`, `revokeTokens`
  and `apiKey` removed; `deleteMessage` now takes the chat) with
  `FirestoreChatServer` and the test `FakeChatServer`. It keeps member
  documents, chat list rows, frozen and muted states and first names in
  step; names in report context come from our records, never from the
  message (the Prompt 9 "forged name" finding cannot come back: a message
  has no name field and the rules refuse any extra field).
- `fanout.ts` + `onChatMessageCreated` (trigger on
  `chats/{cid}/messages/{id}`): re-checks the message, the sending limit
  (`CHAT_MESSAGES_PER_MINUTE`, then `mutedUntil` for `CHAT_MUTE_MINUTES`
  on every member document of the sender), blocked terms
  (`moderation.ts`, the same Arabic and English lists as before), then the
  head, the unread counters and last message of each member's row (small
  chats), and one `chat-message` outbox event for the existing
  notification sender (recipients: members minus sender, muted, blockers;
  the push text stays "You have a new message"). Delivered twice counts
  once. Nothing with message text, names or coordinates is logged.
- `sync.ts`, `flow.ts`, `admin.ts`: unchanged logic (membership sync,
  requests, blocks, mutes, reports, urgent report pauses driving, admin
  remove message / remove member / resolve / lift pause, audit log).
  `getChatToken` and `chatWebhook` are removed; `syncMyChats` stays.
- Privacy (`functions/src/privacy/`): the export reads the parent's own
  messages from Firestore (text, time, chat, their own pin, their own
  photo's path); account deletion cuts chat access at once, replaces the
  first name with an initial in every chat, ends private chats and deletes
  the parent's chat list; the purge step (renamed `chatMessages`, was
  `stream`) deletes the parent's messages, photos and read marks 1 year
  after closure; `retentionDaily` deletes an ended chat with messages,
  members, rows and photos 1 year after it ended.
- Config: `CHAT_PROVIDER=firestore`, new `CHAT_MESSAGES_PER_MINUTE` (30)
  and `CHAT_MUTE_MINUTES` (10) in every `functions/.env.*`; removed
  `STREAM_API_KEY`, `STREAM_API_SECRET`, `CHAT_TOKEN_TTL_MIN`,
  `CHAT_TOKENS_PER_HOUR`, the stale `CHAT_RETENTION_DAYS` line, the
  `chat:setup` script and `scripts/stream_setup.ts`.

### App (`lib/features/chat/`)

- `chat_backend.dart`: `ChatBackend` (narrow reads and writes) and
  `FirestoreChatBackend` (cloud_firestore + firebase_storage).
- `firestore_chat_mapping.dart`: pure mapping from documents to
  `ChatSummary`, `ChatInfo`, `ChatMessage`; the message window merge;
  text splitting; photo paths.
- `firestore_chat_provider.dart`: `FirestoreChatProvider`. One shared
  listener on the chat list rows; one head document per school or area
  group in the list; per open chat the newest 30 messages (older pages
  fetched), read marks in small chats, first names per author once.
  Sending shows at once ("Sending"), works offline through Firestore's
  write queue, and shows "Not sent. Tap to retry." when the rules refuse
  it or a photo upload fails. Marks a chat read while it is open (small
  chats at once; groups at most every 5 seconds). Typing: at most one
  write every 4 seconds, small chats only.
- `chat_session.dart`: the provider is always the Firestore one (dev on
  the emulators too); no token call before connecting, so chat opens
  offline from the cache. `FakeChatProvider` stays for widget tests only;
  the on-phone demo chat is gone.
- Removed: `stream_chat_provider.dart`, `stream_chat_flutter_core`,
  `stream_chat_persistence` (and with them drift, sqlite3,
  connectivity_plus, device_info_plus, package_info_plus as transitive
  packages). **No new package.**

### Rules, indexes, setup

- `firestore.rules` "Own chat" block; `storage.rules` `chatPhotos` block
  (reads the member document with `firestore.get`).
- `firestore.indexes.json`: collection group `messages`
  (`senderUid`, `createdAt` desc) and collection group `chatMembers.uid`.
- TTL: none new. Messages are kept for the life of the chat + 1 year and
  deleted whole by `retentionDaily` (a per-message TTL cannot express
  "1 year after the chat ended"); `chatRequests` and `chatPushes` keep
  their TTLs (`tool/setup_retention.sh`, comment updated).
- `tool/cloud_setup.sh`: no longer creates or needs `STREAM_API_SECRET`
  (an old placeholder may stay); grants Firebase Storage's agent
  `roles/firebaserules.firestoreServiceAgent` for the photo rules.

## Decisions (please confirm)

1. **Unread counters: per member in small chats, from the head in groups.**
   The brief asked for per-member counters everywhere. In a school group
   that is one write per member per message (5,000 writes for one message
   in a large school; the free quota is 20,000 a day). So private and
   carpool chats get a counter on each member's row (as asked); school and
   area groups keep one message counter on the head and each parent's row
   remembers what they read. The chat list is still one listener plus one
   small document per group the parent is in (usually two).
2. **The member document stays (inactive) after a parent leaves**, so old
   messages still show a first name, and the rules refuse them through
   `active`. It goes with the chat.
3. **Messages carry no name.** First names come from the member documents
   (written by Functions), so a parent cannot forge one, and a deleted
   parent's name becomes an initial in one place.
4. **Photos are read through the rules on every load** (bytes through the
   Storage SDK, no shareable link), so a removed member cannot keep
   opening a photo with an old link.
5. **A message over the sending limit or with a blocked term is removed by
   the trigger** a second or two after it was written (the phone's write
   must be instant, so the check cannot be before it). The sender sees it
   disappear; nobody is notified.
6. **Very long text is sent as several messages** of at most 2,000
   characters (no new wording was needed).
7. **`reads` documents and typing are only in private and carpool chats**
   (as read receipts were before).
8. **The purge step name changed** from `stream` to `chatMessages`
   (`closedAccounts` records are per run; no production data exists yet).

## What is NOT built / known gaps

- **No automatic image moderation** (Stream's AI add-on is gone; it was an
  open question in Prompt 9 whether to pay for it). Reports and admin
  removal handle photos. open-items D19.
- **A chat photo cannot be sent offline** (the upload needs a connection):
  it shows "Not sent. Tap to retry." Text and pins queue offline.
- **A sent photo that is waiting is kept in memory only**: if the app is
  closed before the upload ends, that photo is not sent.
- **Firestore's cache on the phone is not cleared on sign-out** (the same
  as for other Firestore data today). open-items D22.
- **Storage rules for chat photos check "verified" and the member
  document, not the new-phone check** (`deviceChecked` needs a second
  Firestore read from Storage rules). The Firestore side, where the
  message that names the photo lives, does check it.
- **Group heads are written on every message** (a busy school group costs
  one read per online parent per message; COSTS "Chat", open-items D21).
- **docs/spec.md (sections 5, 7, 8, 9, 13) and docs/build-prompts.md still
  say "Stream Chat"**: they are the owner's source documents; DECISIONS.md
  and CLAUDE.md already say own chat. Not edited here.
- Not new, still open from Prompt 9's review: limits on urgent reports per
  reporter (item 4), report and pause as one step (item 5), a full-screen
  photo viewer, message search, deleting your own message.
- Website and Android platform work (Stage 2 and 3) as before.

## Security findings of Prompt 9 that must stay fixed

| Finding | Now |
| --- | --- |
| Blocking 1: parents could change their own chat profile or list users | No profile a parent can write: names live in member documents (Functions only; rules test "the app never writes membership or the head"). No listing: `chats` cannot be listed, members only by members of that chat, 50 at a time; collection-group queries are refused (rules test). Messages take no extra field such as a name (rules test). |
| Blocking 2: location pin in school and area groups | Rules refuse `location` and `photo` messages outside private and carpool chats (rules tests); the trigger removes one if it ever appears (Functions test); the app offers neither button there (existing widget test) and the provider refuses (new unit test). |
| EXIF check before upload | Unchanged (`jpegHasExif`, picker with `requestFullMetadata: false`). |
| Member removal and exclusion in one transaction | Unchanged (`admin.ts`); the member document goes inactive right after (Functions test). |
| Request probing counted before answers | Unchanged. |
| Token and webhook items | No token and no webhook exist any more. |

## Tests

| Test | Status |
| --- | --- |
| `functions/test/chat.test.ts` (66 tests): provider choice (fake refused in prod, `stream` unknown); unverified, suspended, banned join nothing; **projection** (head, member documents with first names only, rows, private row names the other parent, removal closes access and keeps the name, suspension cuts and restore reopens, block freezes both member documents, name change, mute on the row, idempotent sync, system messages once); **fan-out** (head, unread, last message, one push event without text, duplicate trigger, preview cut and no coordinates, school groups without per-member writes, photos and pins refused in groups, photo path must be the sender's own, malformed and non-member messages removed, **sending limit and mute in every chat**, **blocked terms**, mutes, blockers, large groups, system message, push text and route); membership sync, requests, blocking as before; **reports and admin removal on Firestore data** (context from Firestore with names from our records, never the photo or its path; remove message deletes the photo and fixes the chat list; remove member is inactive at once and never re-added); **retention, deletion, export** (own messages only, initial at once, messages and photos purged after the year, ended chat deleted whole); blocked-terms matcher | **Run here: pass** |
| `functions/test/privacy.test.ts` (purge step renamed; every collection and subcollection in `firestore.rules` is classified, the new ones included), `trips.test.ts` | **Run here: pass** |
| All Functions unit tests | **Run here: 641 pass, 0 fail** |
| `functions/src/chat/firestore_data.ts` (the Firestore and Storage calls themselves) | Written, not run here (no emulator in the unit tests; type-checked against the stubs) |
| `tests/rules/own_chat.test.ts`: member / not a member / removed / cut off / unverified / new-phone check / admin / signed out for every chat collection; other sender, other time, extra field, missing field, oversize and empty text, bad photo path, bad pin, photos and pins in groups, frozen, muted and was-muted, edit, delete; membership and head never writable; chat list (own open rows only, mark-read only); reads; **Storage** (member, non-member, removed, cut, other folder, replace, delete, list, type, size, name, frozen, muted, school group) | Written, not run here (CI) |
| `tests/rules/deny_all.test.ts` (+ chat paths and chat photos), `chat.test.ts` (header) | Written, not run here (CI) |
| `test/chat/firestore_chat_provider_test.dart`: mapping (rows, heads, previews, messages, window merge, text split, photo paths) and the provider on an in-memory backend (listeners per screen, offline and back, pagination, sending, refused write and retry, photo upload then message, failed upload, pins, groups refuse photos and pins, admin removal, photo cache, mark read in small chats and groups, typing writes and the typing line, info and "not a member", dispose) | Written, not run here (CI) |
| `test/chat/chat_screens_test.dart` (existing list, conversation, settings, one-line at 320 dp AR/EN x1/x2; + a received photo loads through the provider, a missing one shows a mark), `chat_logic_test.dart` (connect without a token) | Written, not run here (CI) |
| Screenshots `chat_tab`, `chat_carpool_chat`, `chat_requests`, `chat_settings`, `admin_report` (AR/EN, light/dark) | Unchanged tests through the interface; not run here (CI artifact) |
| `flutter analyze` | Not run here |

## Screens

No new screen and no new wording. Chats tab, conversation, info sheet,
report sheet, requests, chat settings and the admin report screen are as
in Prompt 9 (docs/progress/prompt-09.md has their layouts and states). The
screenshots come from the CI artifact of the first run on this branch.

## How to test it on the iPhone

docs/test-iphone.md section 8 (8.1 to 8.14): two phones in **staging**,
no chat account needed. Before that, once per project: deploy rules,
indexes, storage rules and functions (SETUP 19.3) and make sure the
Storage agent has its role for chat photos (SETUP 19.2;
`tool/cloud_setup.sh` does both).

On the emulators (Mac): start the emulators and seed as before, run the
dev app on two devices as two verified seed parents of the same school;
chat now works there too (it is Firestore), no `.secret.local` entry.

## Before merging (coordinator)

1. Merge `main` into the branch (conflict expected only in
   `tool/cloud_setup.sh`, the Storage agent line).
2. One CI run on the branch: Flutter analyze and tests, rules tests on
   the emulators, web / admin / Android compile. Fix what the analyzer
   reports in the new Dart files.
3. On staging: deploy (the two old functions `getChatToken` and
   `chatWebhook` are deleted by the deploy), wait for the two new indexes,
   run test-iphone 8.1 to 8.14 and SETUP 19.7.

## Open questions for the owner

1. **Unread counts in school and area groups** come from one counter per
   group, not a counter per parent (decision 1). OK?
2. **Image moderation:** none now. Add Cloud Vision SafeSearch on chat
   photos later (paid per image), or stay with reports for the pilot?
3. **Blocked term or sending limit:** the message disappears for the
   sender without a note. Add a short "message removed" note later?
4. **Spec wording:** update docs/spec.md and docs/build-prompts.md to say
   "own chat on Firestore" instead of Stream Chat?
5. **Old `STREAM_API_SECRET` placeholder in the staging project:** leave
   it, or delete it in Secret Manager?
