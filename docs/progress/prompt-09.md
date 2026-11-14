# Prompt 9: Chat (F8, F9, F10, F13) — progress note

Branch: `prompt-09-chat` (from the Prompt 8 notifications branch, which is
still getting analyzer fixes; on top of `main` with Prompts 1 to 7). Date:
14 Nov 2026. The coordinator gave "go" on the owner's behalf.

**Status: code complete. Functions unit tests were run here (434 pass, 57
of them new, Node 22 with stand-in stubs as before). The Flutter code, the
widget, logic, one-line and screenshot tests, the rules tests and the Stream
setup script were written, not run here** (no Flutter SDK, npm registry or
Stream account in this workspace). Expect small analyzer fixes on the first
CI run, most likely in `lib/features/chat/stream_chat_provider.dart` (the
one file that talks to the Stream SDK; checked against its v10.7.0 source).

## Plan that was followed

1. Server (Cloud Functions, `functions/src/chat/`): a `ChatServer`
   interface with a Stream REST implementation (server JWT, no npm package)
   and a fake; token issuance; channel registry and membership sync;
   private requests; blocks, mutes, settings; reports with context; urgent
   reports pause driving (Prompt 7 release); webhook into the Prompt 8
   sender; retention job; admin report actions.
2. Rules and rules tests for the new collections; setup script for the
   Stream apps (channel types, permissions, blocklists, moderation,
   webhook).
3. App: `ChatProvider` interface (Stream SDK and a fake), Chats tab,
   conversation, requests, chat settings, report and block sheets, entry
   points (nearby map "Message", carpool "Group chat"), admin report
   screen.

## Decisions (please confirm)

1. **Stream's Flutter SDK, UI-free layer (`stream_chat_flutter_core`)
   instead of the UI kit (`stream_chat_flutter`).** The prompt named the
   UI kit. Its 10.7.0 source imports the in-SDK `package:flutter/material.dart`
   in 175 files. This app uses `material_ui` (Flutter 3.50), whose types are
   different types: the kit's text fields need a legacy `Material`
   ancestor, legacy theme and legacy localizations, which only the
   deprecated `MaterialUiCompatibilityBridge` provides (an analyzer warning
   in our code, and runtime asserts we cannot test here). The kit also pulls
   about ten native plugins we do not use (voice recording, video, file
   picker, photo manager, gallery saver, share) with their iOS permission
   texts. The core layer is the same SDK (client, channel list controller,
   offline queue) without widgets; the screens are ours, built from the
   design system, so chat looks like the rest of the app, follows RTL, the
   one-line rule and both themes, and is testable without Stream. Switching
   to the kit later only replaces the screens. CLAUDE.md "Chat: Stream Chat
   with its Flutter SDK" still holds.
2. **Stream on the server without an npm package**: plain HTTPS to
   Stream's REST API with an HS256 server token (`chat/server.ts`). No new
   dependency, nothing to install in CI, every call visible and tested.
3. **Channel types per kind** (`cp_private`, `cp_school`, `cp_area`,
   `cp_carpool`): the photo rule and read receipts are enforced by Stream
   too (uploads and read events off for school and area groups), and the
   permissions give parents no right to create channels or add members.
4. **Membership is ours**: `chatChannels/{cid}` lists members; triggers on
   `users`, `parentLocations` and `carpools/{id}/members` keep Stream in
   step; `syncMyChats` lets the app repair a missed change. An admin who
   removes a member puts them on the channel's `excluded` list so the sync
   never adds them back.
5. **Area group** = the area of the child's school whose center is nearest
   the parent's ROUNDED home point, within 6 km (areas come from the admin
   panel, Prompt 4). No home pin: school group only.
6. **Private chat**: request then accept (`chatRequests`). Allowed only
   between parents who share a school (children or driving schools) or a
   carpool, 10 new requests a day, refused when either blocked the other
   or the other turned requests off. Asking someone who already asked you
   accepts their request. One private channel per pair (ID is a hash of
   the two uids).
7. **Block** (F13): the private chat is frozen on Stream (nobody can
   write), pending requests both ways are cancelled, new ones refused; in
   groups the blocker gets no push for the blocked parent's messages and
   the app hides them behind a short line. Unblock unfreezes unless the
   other parent blocked too.
8. **Mute per chat**: stored in `chatMutes` (the webhook reads it) and on
   Stream (so every phone shows it). School and area groups with more than
   50 members start muted (spec section 5).
9. **Chat push through our sender**: Stream's push is off; the webhook
   (signature checked) writes one `chat-message` event per message with the
   recipients (members minus sender, muted, blockers). The push says only
   "New message — You have a new message." and opens that chat. Chat
   pushes keep their delivery record in `users/{uid}/chatPushes` (2-day
   TTL), not in the Notifications tab, so chat never floods the tab or its
   dot (`PUSH_ONLY_PREFIX` in `notifications/catalog.ts`).
10. **Reports** go to the existing `reports` queue (Prompt 4) with the
    reported message, 2 before and 1 after (text cut to 500 characters,
    first names and parent IDs, never photos). Admins never read a chat:
    there is no function that reads a channel's history except at report
    time.
11. **Urgent reports** (child safety, dangerous driving) about a parent
    set `drivingPaused` on their record and release every future run they
    drive (Prompt 7's `releaseRun`): open for the group, or missed with the
    "take your own child" alert when too late; the group is told only that
    the driver is unavailable. A paused driver cannot confirm, take or be
    planned for a run (the schedule reads them as status "paused", so no
    car). An admin lifts the pause on the report screen.
12. **Access cut-off**: suspend, ban, delete or lost verification revokes
    the parent's Stream tokens and deactivates the Stream user at once
    (users trigger, retried for up to 6 hours); tokens live 1 hour and
    every token request re-checks the record.
13. **Retention**: `CHAT_RETENTION_DAYS` = **180 days** until the owner and
    the lawyer choose (spec: "retention period to be decided"). A daily job
    hard-deletes older messages channel by channel (works on the free plan).
14. **Location pin**: a message with a `location` attachment (a point), only
    after the parent confirms; shown as a card with "Open map". No live
    location (that is the run screen, Prompt 13).
15. **Offline**: Stream's offline storage (`stream_chat_persistence`, SQLite)
    keeps chats and queued messages on the phone; the composer works
    offline and the bubble shows "Sending" until it goes. Sign-out
    disconnects and clears the storage. The website keeps chat in memory
    (Stage 2).

## Data model

| Record | Holds | Who reads / writes |
| --- | --- | --- |
| `chatChannels/{cid}` | kind, refId, schoolId, names AR/EN, members, excluded, frozen | Cloud Functions only |
| `chatMemberships/{uid}` | school and area groups the sync put the parent in | Cloud Functions only |
| `chatRequests/{from}_{to}` | uids, first names, status, cid; TTL 30 days after last change | Sender and receiver read; Functions write |
| `chatBlocks/{blocker}_{blocked}` | uids, blocked first name | The blocker reads; Functions write |
| `chatMutes/{uid}_{type~id}` | uid, cid, muted | The parent reads; Functions write |
| `chatSettings/{uid}` | requestsOff | The parent reads; Functions write |
| `chatLimits/{uid}` | counters | Functions only |
| `reports/{id}` (Prompt 4) | + source chat, subjectUid, cid, kind, note, urgent, context, pausedDriving, outcome, handledBy | Functions only (admins via functions) |
| `users/{uid}` | + `drivingPaused`, `drivingPausedAt`, `drivingPauseReportId` | Functions only |
| `users/{uid}/chatPushes/{eventId}` | delivery record of a chat push; TTL 2 days | Functions only |
| `notificationEvents` | + `chatCid` | Functions only |

Stream holds messages, first names and parent IDs (no phones, addresses or
children). Stream user ID = Firebase uid.

## Functions (new)

Callables: `getChatToken`, `syncMyChats`, `sendChatRequest`,
`answerChatRequest`, `cancelChatRequest`, `updateChatSettings`,
`setChatMute`, `blockChatUser`, `unblockChatUser`, `reportChat`; admin:
`adminGetReport`, `adminRemoveChatMessage`, `adminRemoveChatMember`,
`adminResolveReport`, `adminLiftDrivingPause`. Triggers:
`syncChatOnUserWrite`, `syncChatOnLocationWrite`,
`syncChatOnCarpoolMemberWrite`. HTTP: `chatWebhook`. Scheduled:
`chatRetentionDaily`. Script: `npm --prefix functions run chat:setup`.

## Screens and states

| Screen | Layout | Loading | Empty | Error | Offline |
| --- | --- | --- | --- | --- | --- |
| Chats tab (`/chats`, replaces the placeholder) | App bar: requests (badge) and chat settings; "N chat requests" row on top; one row per chat: kind icon, one-line name, preview, time, unread pill, muted mark | Skeleton rows | "No chats yet" | Error view + retry | Offline view + retry; a dropped connection shows a one-line note |
| Conversation (`/chats/<type>/<id>`) | App bar: name, info; bubbles newest at the bottom (author in groups, time, delivery mark: sending, sent, read, failed = tap to retry); typing line; composer (photo only in private and carpool, location, text, send) | Skeleton bubbles | "No messages yet / Say hello" | Error view + retry | Note "Messages send when you're back online"; closed chat: lock note instead of the composer |
| Info sheet | Kind and members, Mute switch, Report chat / parent, Block (private) | — | — | Snackbar | Snackbar |
| Report sheet | Reason chips, urgent note, optional note, Send report | Button spinner | — | Inline message | Inline message |
| Requests (`/chats/requests`) | "Waiting for you" cards (Accept outlined, Decline text), "Sent by you" rows with Cancel | Skeleton rows | "No requests" | Error view | Offline view |
| Chat settings (`/chats/settings`) | "New chat requests" switch; blocked parents with Unblock | Skeleton rows | "You haven't blocked anyone." | Error view | Offline view |
| Admin: Reports (`/reports`) | Urgent first with an Urgent badge, kind of chat; a row opens the report | Skeleton | No open reports | Error | Offline |
| Admin: Report (`/reports/<id>`) | Facts (reason, about, chat, sent, note, driving paused), the kept messages as bubbles (photos never shown), Remove message, Remove parent, No action, Warned, Let them drive, Open parent; each asks first | Skeleton | — | Error, not found | Offline |

New design-system pieces `AppChatBubble`, `AppChatComposer`, `AppCountPill`
are in the gallery under "Chat"; `AppSpacing.chatPhoto` (224) is the photo
size.

## New packages (CLAUDE.md rule 3)

- `stream_chat_flutter_core ^10.7.0` (Stream's official Flutter SDK, UI-free;
  in the STACK). Brings `stream_chat`, `connectivity_plus`,
  `device_info_plus`, `package_info_plus` (the latter two apply their own
  Kotlin fix, so no `KOTLIN_FIX_PLUGINS` entry).
- `stream_chat_persistence ^10.7.0` (Stream's official offline storage,
  drift + `sqlite3_flutter_libs`, Java on Android): the offline send
  queue the prompt asks for.
- `image_picker ^1.2.2` (flutter.dev, Java/Swift): take or choose a chat
  photo. iOS photo library text added to `tool/patch_native.py` and both
  `InfoPlist.strings`. EXIF is removed by the existing
  `flutter_image_compress` path (re-encode, `keepExif` off).
- Server: none.

Versions checked against the GitHub tags (`v10.7.0` is the newest
stream-chat-flutter tag; `image_picker-v1.2.4` the newest image_picker).

## How to test it on the iPhone (the "Done when" check)

1. Stream: SETUP 19.1 to 19.3 for the DEV Stream app (key, secret,
   `chat:setup`). In `functions/.env.local` set `CHAT_PROVIDER=stream` and
   the dev key; put the secret in `functions/.secret.local`.
2. Emulators and seed as in Prompts 6 to 8; dev app on the iPhone with
   `--dart-define=EMULATOR_HOST=<Mac IP>`, signed in as your verified seed
   parent; a second device (simulator) signed in as another verified seed
   parent of the same school (for example Hoda, `seed-map-parent-1`).
3. **Private chat:** on the second device, Home > Parents nearby > tap your
   marker > Message. On the iPhone, Chats shows "1 chat request" > Accept:
   the chat opens. Write on both devices: messages arrive at once; "Read"
   ticks appear; "typing…" shows. Send a photo and a location pin.
4. **Groups:** Chats lists the school group (muted if large) and, with a
   home pin, the area group; a carpool you are in has its chat (also
   Carpools > the carpool > Group chat).
5. **Offline:** airplane mode on the iPhone, write a message: it shows
   "Sending"; airplane mode off: it goes.
6. **Report and remove:** on the second device long-press one of your
   messages > Report message > Harassment > Send. Open the admin panel
   (Prompt 4, `/reports`): the report is there with the message and a
   little context. Open it > Remove message > confirm: it disappears on
   both phones.
7. **Block:** on the iPhone open the private chat > info > Block Hoda >
   Block. On the second device the chat shows "This chat is closed" and a
   new Message request says "You can't chat with this parent."
8. **Unverified gets no token:** sign in as an unverified seed parent: the
   Chats tab is not reachable (Profile only), and calling `getChatToken`
   is refused with `not-verified` (Functions test
   "an unverified account gets no chat token").
9. **Push** (deployed dev project only, as in Prompt 8 step 6): with the
   app in the background, a message from the second device shows "New
   message — You have a new message."; tapping opens that chat.
10. Check Arabic and dark mode.

Without a Stream app (`CHAT_PROVIDER=fake`) the Chats tab shows two fake
chats kept on the phone, enough to check the screens.

## Tests

| Test | Status |
| --- | --- |
| `functions/test/chat.test.ts` (55): channel IDs; **token issuance** (verified only; unverified, pending, suspended, banned, unknown refused; rate limit; JWT shape; fake refused in prod); Stream REST calls (server JWT, api key, secret never sent, paths and bodies, errors without body text); **webhook verification** (valid, wrong, missing, malformed, other secret, unset secret, changed body); **membership sync** (school and nearest area, idempotent, leaving, carpool add/remove, suspended not added, admin exclusion, cut-off on suspend/ban/delete with revoke before deactivate, restore, irrelevant writes ignored, syncMyChats); requests (accept, decline, cancel, reverse accept, daily limit, requests off, no shared school, carpool link, self, unverified); **blocking** (frozen chat, requests both ways, no push to the blocker, unblock both sides); mute and chat push (one event, no text in event or logs, duplicates, muted, large groups, ignored events, route and push text); reports (context only, urgent pauses driving, group, refusals, limit); admin actions (view logged, remove message, remove member never re-added, resolve, lift pause); retention; setup plan (no forbidden grants, photos and read receipts per kind, AR/EN blocked terms) | **Run here: pass** |
| `functions/test/schedule.test.ts` (+2): pause releases the driver's runs with "driver unavailable" only; a paused driver cannot take a run | **Run here: pass** |
| All Functions unit tests | **Run here: 434 pass** (only the known Sentry stub gap in `tsc`) |
| `tests/rules/chat.test.ts`, `deny_all.test.ts` paths | Written, not run here (CI); type-checked against a stub (only the known `TokenOptions` stub gap) |
| `test/chat/chat_logic_test.dart` | Written, not run here |
| `test/chat/chat_screens_test.dart`: list (names, previews, pill, muted), open, requests accept, empty / error / offline, offline note, Arabic RTL; conversation (authors, read, location, send, keystroke, offline queue, retry, photo only where allowed, location confirm, report with reason, urgent note, block, mute, blocked hidden, closed chat, typing, bad route); settings (requests off, unblock, cancel sent); **one line at 320 dp AR/EN x1/x2** | Written, not run here |
| `test/admin/admin_screens_test.dart` (+4), `admin_one_line_test.dart` (report screen), `router_test.dart` (Chats tab), `maps_screens_test.dart` (Message sends a request) | Written, not run here |
| Screenshots `chat_tab`, `chat_carpool_chat`, `chat_requests`, `chat_settings`, `admin_report` (AR/EN, light/dark) | Written, not run here (CI artifact) |

## Review fixes (docs/reviews/prompt-09-review.md)

Blocking:
1. **App-level grants**: `setup_plan.ts` now has `APP_GRANTS` (nothing for
   `user`, `guest`, `anonymous`) and `appGrantProblems`; the script sets
   them, reads them back and refuses to finish while `update-user-owner`,
   `search-user` (or other forbidden app rights) remain. Stream users are
   written only by Cloud Functions; the app connects with its uid only.
   Tests in `chat.test.ts`; manual check on the dev Stream app in SETUP 19.3.
2. **Location pin** only in private and carpool chats
   (`ChatKind.locationPin`), as for photos; Stream refuses attachments in
   groups anyway. Widget tests: groups have neither button, private chats
   have both.

Non-blocking done:
- 1: the chat client follows `chatUidProvider` (uid while verified, via
  `select`), so other writes to the parent's record no longer reconnect and
  wipe the offline queue; unit test with a changing session.
- 6: removing a reported member and excluding them is one transaction.
- 8: `jpegHasExif` refuses any photo that still has an EXIF segment after
  re-encoding; unit test.
- 9: chat requests count toward the daily limit before anything about the
  other parent is revealed; test.
- 10: already so: own messages have no long-press menu (no Report or Block).
- 11: the setup script exits with an error when moderation fails, unless
  `--no-moderation`.
- 12: revoking or deactivating a parent with no Stream user (400 or 404)
  counts as done; test.

Non-blocking left (next prompt or the pilot):
- 2: chat does not open offline at a cold start (a token is needed first).
- 3: retention truncates every channel every night; truncate only channels
  with old messages and pace the calls (check `channel.truncated` on the
  phone).
- 4: urgent report abuse: limit urgent reports per reporter, alert admins
  on repeated pauses from one reporter; `lift` should keep the pause while
  another urgent report is open.
- 5: report and pause are two steps: idempotency key for reports and a
  retrying pause trigger.
- 7: clear the context of handled reports after the retention period.
- 11 (rest): check on the dev app that multi-word blocklist phrases work
  and that typing and read events need no more grants.
- 13: freeze the chat of a closed carpool.

## Learned from earlier reviews

- Every new collection has rules and rules tests (owner, other parent,
  unverified, signed out, admin, writes); Functions-only ones closed and in
  `deny_all`; older tests updated deliberately (router Chats tab, maps
  Message, admin fakes).
- Limits counted on the server; concurrency through transactions
  (`updateChannel`); webhook and events idempotent by ID.
- Analyzer habits: no deprecated APIs (no Material bridge), sinks and
  subscriptions closed, const where possible, sorted imports; widget tests
  use tall views, one ProviderScope shape (`authOverrides` now adds the
  four chat overrides), `ensureVisible` before taps, closed fakes.

## Open questions for the owner

1. **Chat retention**: 180 days for now. Your choice and the lawyer's?
2. **Stream moderation add-on** for AI text and image moderation may be
   paid: turn it on for prod at launch, or blocklists only until the pilot?
3. **Area groups**: nearest area within 6 km of the rounded home. OK, or
   should parents pick their area?
4. **Large groups muted by default** above 50 members. OK?
5. The UI kit vs the core layer (decision 1): OK to keep our own screens?

## Not done / known gaps

- Swap requests as messages in the carpool chat and the quick driver
  buttons (F35) come with trips (Prompt 10/13).
- A full-screen photo viewer (tap on a photo) and message search.
- Account deletion should delete the Stream user and the chat records
  (Prompt 12 list); today deletion deactivates the Stream user.
- The new-device risk check (spec section 7: fresh selfie before chats
  open) is not part of this prompt.
- Website and Android chat platform work (Stage 2 and 3); the website
  keeps chat in memory.
- Not verified here: `flutter analyze`, `flutter test`, the rules tests,
  the iOS build with the new plugins, the Stream setup script against a
  real app.
