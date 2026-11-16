# Branch chat-review-safe (review-risks item 9, 16 Nov 2026)

Owner instruction (16 Nov 2026): remove every remaining App Store review
risk. Coordinator said "go". This branch is `improve-b-firestore-chat`
(our own chat on Firestore) with `main` (495b1e8) merged, plus:

1. **Merge** (82ecb6f): three conflicts, resolved as the commit message
   says. The chat branch's open items are now D41 to D45 (main already used
   D24 to D28).
2. **Word filter (guideline 1.2):** `functions/src/chat/moderation.ts`
   (list from `config/chatModeration`, built-in defaults, one read a
   minute per instance, a failed read keeps the last list),
   `moderation_admin.ts` and `moderation_callables.ts`
   (`adminGetChatModeration`, `adminSetChatModeration`, super admins,
   audited with counts), `fanout.ts` (applied to every text message when
   it is sent). Admin panel: Settings > Chat word filter (edit dialog, one
   word per line, checked as typed). ARB strings Arabic and English.
   No rules change (`config/` stays closed to the app except `features`).
3. **Report and block verified:** `reportChat`, `blockChatUser`,
   `unblockChatUser` and their tests in `functions/test/chat.test.ts`; UI
   in `lib/features/chat/chat_sheets.dart` and chat settings.
4. **One chat-provider setting:** `tool/links_site.py --env` reads
   `CHAT_PROVIDER` from `functions/.env.<env>` and keeps only the matching
   `<!-- chat:<provider> -->` block of `hosting/links/privacy.html`;
   `tool/test_links_site.py` checks all projects use one provider, the page
   names Stream only for `stream`, and the in-app text (`dataChatBody`) and
   `docs/app-store-privacy.md` match. `tool/cloud_setup.sh` passes `--env`.
5. Docs: audit (filter, report, block, chat move: FIXED here), submission
   kit (no `chat:setup`, `--env prod`), SETUP, open items, DECISIONS.

Tests: Functions run here (see the commit); tool tests run here; Flutter
(admin settings widget tests) and rules tests written or unchanged, not run
here. Not merged with `review-risks` (that branch merges into main first;
then main into this one: expect conflicts in hosting/links/privacy.html,
docs/open-items.md, docs/apple-review/*.md and the ARB files).
