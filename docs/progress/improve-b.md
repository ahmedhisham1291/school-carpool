# Improvement B: own chat on Firestore (replaces Stream Chat)

Branch `improve-b-firestore-chat` (from `main`). Date: 14 Nov 2026. Owner
decision: DECISIONS.md "Improvements, revised", item 3. The coordinator gave
"go" on the owner's behalf. **Not merged: the coordinator merges this only
after the first TestFlight build runs on the owner's iPhone.**

## Plan

1. **Server** (`functions/src/chat/`): a `firestore` provider behind the
   existing `ChatServer` interface (the `stream` provider and its REST
   client go). It projects the channel registry (`chatChannels`, unchanged,
   Functions only) into the tree the phone reads: `chats/{cid}` with
   `members`, `messages`, `reads`, and `userChats/{uid}/chats/{cid}`. A
   trigger on message create does the fan-out (limits, blocked terms,
   last-message summary, unread counters, push through the Prompt 8 sender).
   `CHAT_PROVIDER` = `fake | firestore`; prod refuses `fake`. Token
   issuance, the webhook, the setup script and the Stream params and secret
   are removed.
2. **Rules**: `firestore.rules` and `storage.rules` for the new paths
   (current membership read from the member document on every request),
   with emulator tests; indexes for the collection-group queries the
   server needs.
3. **App**: `FirestoreChatProvider` behind the existing `ChatProvider`
   interface, written against a small `ChatBackend` so its logic is tested
   without Firebase; the Stream provider and both Stream packages go. The
   screens do not change.
4. **Privacy and retention**: export, account deletion, the 1-year purge and
   the closed-chat purge read and delete Firestore and Storage instead of
   Stream.
5. **Docs and setup**: SETUP section 19, COSTS, app-store-privacy,
   testflight, open-items, test-iphone, `tool/cloud_setup.sh`,
   `tool/setup_retention.sh`, CLAUDE.md STACK lines.

Files touched, data model, decisions, open questions and the honest test
status are filled in below when the work is done.
