# Re-review: Prompt 12 (privacy and security hardening), review round

Branch `prompt-12-hardening`, head `d2aeac5`. That is `b67a360` with main
merged in. Scope: the fixes since the first review
(`docs/reviews/prompt-12-review.md`, commit `047ac05`), which are
`git diff 047ac05..d2aeac5`.

## Verdict: PASS

All three blockers are fixed and tested. CI is green on the exact head.
The items left over need owner decisions or operational setup before the
pilot. None of them blocks the merge.

## CI

Run 43588727772 (manual, `headSha d2aeac5`): **completed, success**.

| Job | Result |
| --- | --- |
| Flutter analyze, tests and screenshots | `No issues found!`; `+693 ~344: All tests passed!` (the 344 skipped are the screenshot goldens: `full=false`) |
| Cloud Functions tests and rules tests (emulators) | Functions `# tests 612 # pass 612 # fail 0`; `# tests 6 # pass 6`; rules `# tests 493 # pass 493 # fail 0` |
| Web, admin panel and Android compile | skipped by design |

## Blockers from the first review

1. **New-phone gate on the server: fixed.**
   - `firestore.rules` has new `sessionValid()` and `deviceChecked()` checks
     that read `users/{uid}`. `deviceChecked()` now applies to:
     - children, homes and emergency contacts
     - members, requests (including the admin path), driverConsents and
       pickupPoints
     - schedule, swaps, exceptions, balances and emergencies
     - trips, which also covers points and eta (`tripViewer`) and
       tripChecks
     - handoverAdults
     - notifications
     - chat requests, blocks, mutes and settings

     `sessionValid()` alone covers the user record, consents, vehicles and
     memberships.
   - `functions/src/privacy/device_gate.ts` adds `gatedCall` and
     `sessionCall`. Every carpool, schedule, trip, trust, chat, wallet,
     maps, verification and privacy callable now goes through
     `gatedCall`. That includes `exportMyData` (`privacy/callables.ts:332`)
     and `deleteMyAccount` (`:369`).
     - `confirmNewDevice` and `reportTransfer` use `sessionCall`, so they
       still work while the check is open. That is intended.
     - The admin callables keep `requireAdminCaller`.
   - Signed-out phones now lose access at once. `revokeSessions` writes
     `sessionsValidAfter` from `tokensValidAfterTime`, rounded down to the
     second. The rules and the callables refuse a token whose `auth_time`
     is older.
   - The new-phone path now fails closed in two places.
     - `afterSignIn` (`:180-196`): if the sign-in record cannot be written,
       a verified parent is treated as on a new phone.
     - `confirmNewDevice`: a face-check error keeps the data closed and
       files an urgent report.
   - The face matcher is now built lazily (`verification/face_match.ts`),
     from the project's own KycProvider settings.
   - Tests: rules tests for the SIM swap and for a phone signed out from the
     list (`tests/rules/privacy.test.ts`), plus the functions tests.
     SECURITY.md AUTH-2 is now accurate.

2. **Wallet before deletion: fixed.**
   - `deleteAccount` now does these steps in order:
     1. Run the non-wallet checks.
     2. Lock the wallet (`account_deletion.ts:305-336`): a transaction sets
        `frozen/accountClosing`, then the wallet is frozen at the partner.
        If the partner cannot be told, our copy is put back and the
        deletion is refused with `wallet-unavailable`.
     3. Read the wallet facts in both directions
        (`firestore_store.ts:326-350`): `walletPending` by `parties` and
        by `uid`, plus any transfer from the last 30 days with no result.
     4. Read the balance from the partner. If the partner cannot be asked,
        use our copy, and treat it as 1 rather than 0.
     5. On a refusal, unlock the wallet. If unlocking fails, it stays
        frozen, which is the safe side.
   - `startTransfer` reads both wallets inside its transaction.
     `walletFromDoc` now treats any status other than active as frozen, so
     no transfer can start once the lock is set. `walletPending` now stores
     `parties`.
   - Tests: 5 new cases in `functions/test/wallet.test.ts`.
     - an incoming pending transfer
     - a transfer arriving mid-deletion
     - a transfer that passed its checks just before the lock
     - money still in the wallet
     - the partner cannot be told

3. **Personal data left with other parents: fixed.**
   - The new `anonymise` step (`privacy/anonymise.ts`; it runs after the
     carpools step and before records) reduces names to an initial and
     replaces IDs with `deleted`. It covers:
     - other drivers' trip stops (child ID, first name, handover); the
       parent also leaves `viewerUids` and `childIds`
     - trips the parent drove (driver's name)
     - past runs (riders, absent, driver, swapBy)
     - swaps and term balances
     - the carpool card's creator
   - `purgeClosedCarpoolsBefore` (`firestore_store.ts:576`, run by
     `retentionDaily` 1 year after a carpool closes) deletes:
     - the card and all its subcollections (`recursiveDelete`)
     - its trips, including their points
     - its memberships and invites
   - `walletDaily` now has `expiresAt` (35 days) and a TTL line in
     `tool/setup_retention.sh`.
   - The new `SUBCOLLECTIONS` table is checked by a test.
   - `mail` is now deleted with the account.

## Non-blocking items from the first review

| # | Item | State |
| --- | --- | --- |
| 1 | New-phone selfie fails open in prod | Fixed (fails closed). See open item 1 below. |
| 2 | Signed-out phones keep access for up to 1 hour | Fixed for Firebase. Stream tokens: open item 2. |
| 3 | Export gaps | Fixed: pickup points, requests, consents, chat requests and blocks, family requests, privacy requests, vouches, image links, and sections cut short by a limit are now marked. |
| 4 | Thumbnails | Fixed. The thumb follows the original's generation; `dropPhotoThumbnail` removes it on delete; a backfill script exists; a full image is now logged as full (`callables.ts:560`). |
| 5 | `setup_kms.sh` on macOS, and the rewrite prefixes | Fixed (GNU date, then BSD date, then python3 as a fallback). |
| 6 | Stale lawyer wording, transfer-record period | Wording fixed. The period is a 5-year PLACEHOLDER (`retention.ts` `TRANSFER_RECORD_YEARS`). |
| 7 | App Store answers | Fixed (Coarse Location, the Analytics instance ID, handover adults' numbers). |
| 8 | APNs in SECURITY.md | Fixed. |
| 9 | Chats of closed carpools never ended | Fixed (looks back 30 days, skips chats already ended). |
| 10 | Scraping counter keys | Fixed (stored as `keyHash`, SHA-256, 16 hex). |
| 11 | Route-archive trigger cost | Open (builder deferred it). |
| 12 | Mail outbox | Fixed (deleted with the account). |
| 13 | Restore resurrects deleted accounts | Fixed (`restore-test.md` step and `deletions:reapply` script). |
| 14 | Offline queue across accounts | Fixed (cleared when the uid changes). |
| 15 | App lock re-prompt | Fixed (`ValueKey(lock.locked)`). |
| 16 | Android analytics manifest flag | Open (Stage 3). |
| 17 | Screenshots of the new screens | Open: still not produced (`full=false`). Run the full workflow at merge. |

## Open items (for the owner or later prompts, not blocking)

1. **No admin button to clear a new-phone check.** In prod, Valify's
   `matchFace` is still a stub that always answers "error" (`kyc.ts:132`).
   Because the gate now fails closed, every verified parent who signs in on
   a new phone stays locked out of children, carpools, trips, chat and the
   wallet until an admin calls `adminClearDeviceCheck`. The panel has no
   button for it yet (builder's "not done"). Add the button before any prod
   or TestFlight use with real parents, or record the owner's acceptance.
2. **Stream tokens survive a sign-out.** `revokeSessions` does not call
   `chat.revokeTokens`, so a signed-out phone keeps its Stream chat
   connection until the token expires (`CHAT_TOKEN_TTL_MIN`, 60 minutes by
   default). SECURITY.md states this honestly. Calling
   `chatServer().revokeTokens(uid, now)` in `revokeSessions` would close the
   gap.
3. **Closed-carpool purge deletes trip history.** The purge deletes the
   carpool's trips 1 year after it closes. For a parent who is still
   active, DECISIONS keeps trip history "while the account is active + 1
   year", so this is shorter. Ask the owner to confirm, or keep the trips
   with the names reduced to initials. The close time is read from
   `updatedAt`, so a later write to the card only delays the purge.
4. **Anonymising stops silently at its read limits.** It reads at most
   2,000 trips per query and 500 memberships (`firestore_store.ts:457-461`)
   and does not report a cut. Throw when a page is full so the step is
   recorded as failed and retried.
5. **Transfer records: 5-year placeholder.** The lawyer confirmed a period
   but the owner has not given it. Nothing deletes transfer records yet,
   which is consistent with the append-only rule.
6. **Builder's other "not done" items.** Route-archive trigger cost,
   Android analytics flag, screenshots.
