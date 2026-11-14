# Prompt 9 review: Chat (F8, F9, F10, F13)

Branch `prompt-09-chat`, head `db99b83` (includes `main` with Prompts 1 to 8
and the follow-ups). I reviewed `git diff origin/main...HEAD` (81 files)
against CLAUDE.md, docs/spec.md (section 5, Flow E, F8, F9, F10, F13,
sections 6 and 7), docs/build-prompts.md "Prompt 9" and its "Done when",
DECISIONS.md, DESIGN.md, WORKFLOW.md and docs/progress/prompt-09.md.

## Verdict: CHANGES NEEDED

There are two blocking items, both on the Stream side. The emulator tests
and the fake chat provider cannot catch either one.

## CI

Run 43559089980 on `db99b83`: **all green**.

| Job | Result |
| --- | --- |
| Cloud Functions tests and rules tests (emulators) | success |
| Flutter analyze, tests and screenshots | success |
| Web, admin panel and Android compile (staging) | success |

I ran no compiler or tests here, because this workspace has no Flutter SDK.
I did not look at the screenshots. Nothing ran against a real Stream app:
not the setup script, the REST calls or the permissions. Everything about
Stream's behaviour below comes from reading the code and Stream's
permission reference.

## Blocking

1. **App-level Stream grants are never restricted, so parents can change
   their own Stream profile and list every user.**
   - Where: `functions/scripts/stream_setup.ts:283` and
     `functions/src/chat/setup_plan.ts:56`.
   - Problem: the script sets grants only per channel type. Stream's
     app-level (`.app`) scope keeps its defaults, and for role `user` those
     are `update-user-owner`, `search-user`, `flag-user` and `mute-user`
     ([Stream permissions reference](https://getstream.io/chat/docs/node/permissions_reference/)).
   - Effect of `update-user-owner`: a parent can call
     `partialUpdateUser`/`upsertUser` from a modified client and rename
     themselves (another parent's name, or "School admin"). They can also
     set `parent_id` to someone else's ID.
     - That forged data appears in every chat. It also lands in report
       context (`snapshotOf` reads `user.name` and `user.parent_id` from
       the message, `server.ts:111`), so admins see it in reports.
     - It can also put phone numbers or other text into Stream user data.
       That breaks "Stream gets first names and parent IDs only".
   - Effect of `search-user`: client-side `queryUsers` lists every Stream
     user (first name, parent ID, uid, last active).
     - That gets around the rate-limited parent-ID lookup (spec section 7).
     - It goes against "minimal exposure" (spec section 6).
   - Fix:
     - In step 5 of the script, also `PATCH /app` with
       `grants: { user: [], guest: [], anonymous: [] }`, keeping
       `flag-user`/`mute-user` only if you want them.
     - Add the app-scope grants to `setup_plan.ts` as data, with a test
       that `update-user-owner` and `search-user` are never granted.
     - Have the script read the grants back and refuse to finish if
       either is still there.
     - Add a SETUP step to check on the dev Stream app that a client
       `partialUpdateUser` and `queryUsers` are refused.

2. **The location pin is offered in school and area groups, but Stream will
   refuse it there.**
   - Where: `lib/features/chat/conversation_screen.dart:337`, where
     `onLocation` is always set.
   - Problem: a location pin is a message attachment, and sending one
     needs `create-attachment`. `memberGrants` (`setup_plan.ts:67-71`)
     gives that only to private and carpool chats.
   - Effect: on a real Stream app the pin fails in school and area groups
     every time. Only the fake provider works, which is why the tests pass.
   - Privacy: the pin also posts an exact current location to a group of
     up to 5,000 parents. Spec section 6 shows other parents only an
     approximate (about 500 m) location.
   - Fix (choose one):
     - Recommended: offer the pin only where `kind.photos` is true
       (private and carpool chats), and add a widget test that groups
       have no location button.
     - Or grant `create-attachment` in groups and have the server reject
       image attachments there.

## What I checked (holds)

- **Token** (`flow.ts:104`):
  - Both the `verified` claim and the record are checked, and banned or
    suspended accounts are refused.
  - Requests are rate-limited (30 per hour).
  - The Stream user ID is the Firebase uid, and the profile holds the
    first name and parent ID only.
  - The token is HS256 with `iat`/`exp` and lives 1 hour by default
    (15 minutes to 24 hours).
  - The secret is in Secret Manager and bound only to the chat and
    admin-chat functions. In prod the fake provider is refused.
- **Cut-off** (`sync.ts:235`, `callables.ts:161`):
  - Suspend, ban, delete and lost verification each lead to `revoke_tokens_issued_before`, then `deactivate`, then removal from the school and area groups.
  - The trigger retries for up to 6 hours. Re-verification reactivates the account.
- **Channels and membership are server-only:**
  - Channels are created by the `carpool-system` admin user.
  - Channel-type grants give `user` only three `-owner` permissions and
    no `create-channel`. `channel_member` gets no update-channel,
    update-members, freeze, truncate or leave rights, and no
    `read-channel` without membership.
  - The script refuses an unknown or forbidden permission.
  - Carpool chat follows `carpools/{id}/members/{uid}`, which Prompt 6
    sets on join and deletes on leave or removal.
  - Members an admin removes are excluded for good.
  - `syncMyChats` repairs missed changes.
- **Private requests:**
  - Parents must share a school or a carpool, and can't request
    themselves.
  - Refused when either parent blocked the other or requests are off;
    there are 10 requests a day; asking back accepts the existing request.
  - Request IDs are hashed per pair.
- **Blocking:**
  - The private channel is frozen on Stream, so the blocked parent cannot
    write. Pending requests both ways are cancelled and new ones refused.
  - In groups the blocker gets no push and the app hides the blocked
    parent's messages. That fits F13 and the Done-when line.
- **Photos:**
  - Uploads are off on Stream for school and area groups, and the app
    hides the photo button there.
  - EXIF is removed by re-encoding (`flutter_image_compress` with
    `keepExif` off), and `requestFullMetadata: false` is set.
- **Moderation:**
  - Text and image AI policy, plus blocklists of 15 Arabic and 13 English
    terms with `block` behaviour.
- **Reports:**
  - Context is the reported message plus 2 before and 1 after, with text
    cut to 500 characters, first names and parent IDs, and no photos.
  - There is no function that browses a chat.
  - Admin views and actions are written to the audit log.
  - An urgent report sets `drivingPaused` and releases future runs
    through Prompt 7's `releaseRun` ("driver unavailable" only). The
    paused driver reads as status "paused" in carpool transactions.
- **Webhook:**
  - HMAC-SHA256 of `req.rawBody` is compared with `timingSafeEqual` after
    a hex/length check. A missing secret is refused with 401.
  - It is idempotent through `create()` on `chat_<messageId>`, and the
    sender must be a member in our registry.
- **Push:**
  - It goes through the Prompt 8 sender. The fixed text is "New message —
    You have a new message." and the route is `/chats/<type>/<id>`.
  - Chat pushes are kept out of the Notifications tab and expire after
    2 days. Mutes are respected, and large groups (over 50) start muted.
- **Retention:**
  - A daily truncate with `hard_delete` removes messages older than
    `CHAT_RETENTION_DAYS` (180, clamped to 30 to 730).
- **Rules:**
  - All new collections deny by default. Parents read only their own
    requests, blocks, mutes and settings, with limits on list queries.
  - The registry, memberships and limits are closed, and rules tests
    were added.
- **Packages:**
  - `stream_chat_flutter_core`/`stream_chat_persistence` ^10.7.0 and
    `image_picker` ^1.2.2 resolved in CI, and no server package was
    added.
  - iOS photo-library text is in Arabic and English, and `patch_native.py`
    was updated.
- **ARB:** 1,259 keys in both files, and the placeholders match.
- **Design:**
  - The new components are in the gallery, and DESIGN.md was updated.
  - Labels use `OneLineText`, and the one-line test runs at 320 dp in
    Arabic and English at x1 and x2.
  - Every screen has loading, empty, error and offline states.
- **Core SDK instead of the UI kit:** accepted.
  - The reason is technical (the kit's legacy Material types and about
    ten unused native plugins), not cost. So it does not break the
    "best option" rule, and it is still Stream's official Flutter SDK.
  - What's covered: typing, read receipts in small chats, the offline
    send queue with sending/failed/retry, photos, the location pin,
    mute, report and block.
  - Missing compared with the kit: a full-screen photo viewer, upload
    progress, deleting your own message, and search. That's enough for
    the MVP; the owner still has to confirm (open question 5).

## Non-blocking

1. **The chat client is rebuilt on every `users/{uid}` snapshot.**
   - `chatClientProvider` watches all of `sessionProvider`, and
     `SessionSignedIn` has no `==`.
   - So each write to the record calls `disconnectUser(flushChatPersistence: true)`. That deletes the offline queue and local chats, and spends a token request.
   - Fix: watch only `(uid, status)` with `select`.
2. **Chat does not open offline at a cold start**, because a token from
   Cloud Functions is needed first. Either cache the token until it
   expires, or document this.
3. **The retention job truncates every channel every night**, even ones
   with nothing old.
   - Stream emits `channel.truncated` events, and the Dart SDK clears its
     local state and persistence for that channel when one arrives.
     Check this on the dev app.
   - Also, there is no backoff for Stream's rate limits.
   - Fix: truncate only channels whose oldest message is older than the
     cutoff (keep a `lastTruncatedAt`), and pace the calls.
4. **Abuse of urgent reports:**
   - Any group member can pause any member's driving at once, up to 20
     reports a day.
   - Fix: limit urgent reports per reporter, and alert admins when
     several pauses come from one reporter.
   - Also: `lift` clears the pause even when a second urgent report is
     still open.
5. **The report and the pause are not one step** (`flow.ts:394-397`).
   - If `pause` fails, the report is saved without a pause, and the
     client's retry creates a duplicate report.
   - Fix: give reports an idempotency key, and retry the pause from a
     trigger.
6. **`removeReportedMember` uses two transactions**, one to remove the
   member and one to exclude them. A sync running in between can add them
   back. Do both in one `updateChannel`.
7. **Handled reports keep their message context forever.** Clear
   `context` after the retention period (spec section 7, "chat after the
   chosen period").
8. **No check that EXIF was removed.** Add a pure-Dart guard that refuses
   any JPEG that still has an APP1 `Exif` segment before upload, with a
   unit test that uses a JPEG carrying GPS data.
9. **The request flow reveals facts about any uid without a limit.**
   - `sendChatRequest` answers `not-found`, `requests-off`,
     `no-shared-school` or `blocked` before the daily limit is counted.
   - Fix: count the attempt first, or return one generic refusal.
10. **The message actions sheet offers Report and Block on your own
    messages**, which the server refuses with `self`. Hide both when
    `authorId == me`.
11. **Setup script:**
    - When the moderation policy fails, the script still prints "done"
      and exits 0, so moderation can be silently off. Make it exit
      non-zero unless a `--no-moderation` flag is given.
    - Check that the `word` blocklists accept multi-word phrases (such
      as "كس امك" and "kill yourself").
    - Check that `send-custom-event` really enables typing events, and
      `read-channel` mark-read, on the dev app.
12. **Leftover Stream user for older accounts.** A parent who was verified
    before this release and never opened chat has no Stream user. If they
    are suspended, `revokeTokens` may get a 400 rather than a 404, and the
    trigger then retries for 6 hours. Treat "user not found" as done.
13. **A closed carpool keeps its chat**, because its member docs stay.
    Freeze the chat when the carpool closes.

## Done-when coverage

- Two fake parents chatting on the iPhone and a second device: covered by
  progress steps 1 to 6 and by tests.
- Reporting a message, seeing it in the admin panel and removing it:
  covered by the Functions and admin tests.
- A blocked parent cannot message the blocker: holds through the frozen
  private chat.
- An unverified account gets no token: covered by a Functions test.

All of this needs the dev Stream app set up with the corrected script
(blocking item 1) before the iPhone check.

## Re-review (head `bb98a92`)

Commits reviewed: `b501884` (review fixes) and `bb98a92` (chat client
retry).

### Verdict: PASS

### CI

Run 43562933059 on `bb98a92`: **all green**.

| Job | Result |
| --- | --- |
| Flutter analyze, tests and screenshots | success |
| Cloud Functions tests and rules tests (emulators) | success |
| Web, admin panel and Android compile (staging) | success |

I ran nothing here.

### Blocking items

1. **App-level grants: fixed.**
   - `setup_plan.ts` now has `APP_GRANTS`, which gives `user`, `guest`
     and `anonymous` nothing at app level.
   - `stream_setup.ts` sends them with `PATCH /app`, then reads them back
     with `GET /app`. `appGrantProblems` refuses to finish if
     `update-user-owner`, `search-user` or another forbidden right is
     still granted.
   - Tests cover this, and SETUP.md has a manual check on the dev app.
2. **Location pin: fixed.**
   - `ChatKind.locationPin` is true only for private and carpool chats,
     and `conversation_screen.dart:337` passes `null` for groups.
   - A widget test was updated.

### Non-blocking items fixed

- **Reconnect:** chat reconnects only when the uid or verification
  changes (`chatUidProvider` with `select`).
- **Member removal:** the admin "remove member" now removes and excludes
  in one transaction.
- **EXIF:** `jpegHasExif` refuses to upload a JPEG that still has an APP1
  Exif segment. Unit tests cover it.
- **Request probing:** the request limit is now counted before anything
  about the other parent is revealed.
- **Parents without a Stream user:** a 400 on revoke or deactivate is
  treated as done.
- **Moderation:** the setup script fails unless `--no-moderation` is
  given.
- **Retry (`bb98a92`):** an unverified or suspended parent gets the error
  at once instead of a screen that keeps loading. Other failures retry up
  to 3 times with backoff.

### Still open (non-blocking, from the first review)

1. **Missing grants list counts as safe.** If `GET /app` returns no
   `grants`, `appGrantProblems` reports no problems and the script passes.
   Treat a missing grants list as a failure.
2. Item 2: chat does not open offline at a cold start.
3. Item 3: the retention job truncates every channel every night.
4. Item 4: abuse of urgent reports, and lifting one pause while another
   urgent report is open.
5. Item 5: the report and the pause are not one step.
6. Item 7: handled reports keep their message context forever.
7. Item 11: the setup script's blocklist phrases and typing/read-receipt
   permissions are not yet checked on a real Stream app.
8. Item 13: a closed carpool keeps its chat.
