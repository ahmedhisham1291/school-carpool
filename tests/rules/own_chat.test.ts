// Rules for our own chat on Firestore (F8, F9, F10, F13; improvement B):
// chats/{cid} with chatMembers, messages and reads, userChats/{uid}/summaries
// and the chat photos in Storage (chatPhotos/{cid}/{uid}/{name}).
//
// What these tests prove:
// - Membership is the member document, read on every request: a member
//   reads the head, the members' first names and the messages; a parent who
//   is not a member, was removed (active false), is cut off (suspended,
//   banned, deleted: cut true), is unverified, signed out, or in a new-phone
//   check reads nothing. An admin of the panel reads nothing either.
// - Messages: the sender creates their own (own uid, server time, the three
//   kinds with exactly their fields, text up to 2000 characters); never as
//   another sender, with a past time, an extra field (a forged name), an
//   oversize text, or a photo path outside their own folder. Photos and the
//   location pin only in private and carpool chats. Nobody edits or deletes
//   a message from the app.
// - A frozen chat (block, closed carpool) and a parent muted for sending too
//   fast (mutedUntil in the future) can read but not write; an old
//   mutedUntil no longer stops them.
// - The app never writes membership, the head or another parent's records.
// - Chat list: a parent reads only their own OPEN rows and may only mark a
//   chat read (unread 0, readAt server time, readSeq a number).
// - Reads (read marks, typing): own document, small chats only.
// - Storage: a member uploads a WebP or JPEG under 3 MB into their own
//   folder once (no replace, no delete) and members read it; a non-member,
//   a removed, cut-off, frozen or muted parent cannot upload; a removed or
//   cut-off parent cannot read; never in a school group.
//
// Runs only against the emulators (Firestore and Storage together: the
// Storage rules read the member document). Written, not run here (no npm
// registry in the build workspace); CI runs it.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { after, before, beforeEach, describe, it } from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
  type RulesTestContext,
  type RulesTestEnvironment,
  type TokenOptions,
} from "@firebase/rules-unit-testing";
import firebase from "firebase/compat/app";
import "firebase/compat/firestore";
import "firebase/compat/storage";

const root = join(__dirname, "..", "..", "..");

let env: RulesTestEnvironment;

const token = { firebase: { sign_in_provider: "custom" as const } };
const verified: TokenOptions = { ...token, verified: true as const };
const unverified: TokenOptions = { ...token };
const adminClaim: TokenOptions = { ...token, verified: true as const, admin: true as const };
const as = (uid: string, claims: TokenOptions = verified): RulesTestContext => env.authenticatedContext(uid, claims);
const signedOut = (): RulesTestContext => env.unauthenticatedContext();
const at = (ms: number) => firebase.firestore.Timestamp.fromMillis(ms);
const now = () => firebase.firestore.FieldValue.serverTimestamp();
const T = Date.UTC(2026, 10, 16, 8);

const CARPOOL = "cp_carpool:c-k1";
const PRIVATE = "cp_private:dm-abc";
const SCHOOL = "cp_school:s-nile";
const FROZEN = "cp_private:dm-frozen";

const member = (uid: string, extra: Record<string, unknown> = {}) => ({
  uid,
  firstName: uid,
  active: true,
  cut: false,
  frozen: false,
  mutedUntil: null,
  joinedAt: at(T),
  updatedAt: at(T),
  ...extra,
});

const summary = (cid: string, extra: Record<string, unknown> = {}) => ({
  cid,
  kind: "carpool",
  nameAr: "مدرسة",
  nameEn: "School",
  otherUid: null,
  otherName: "",
  muted: null,
  frozen: false,
  open: true,
  memberCount: 2,
  unread: 3,
  readSeq: 0,
  readAt: null,
  lastAt: at(T),
  last: { kind: "text", senderUid: "bob", text: "hi" },
  joinedAt: at(T),
  updatedAt: at(T),
  ...extra,
});

const text = (uid: string, value = "hello") => ({ senderUid: uid, kind: "text", text: value, createdAt: now() });

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-school-carpool-ownchat",
    firestore: { rules: readFileSync(join(root, "firestore.rules"), "utf8") },
    storage: { rules: readFileSync(join(root, "storage.rules"), "utf8") },
  });
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.clearStorage();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const head = (kind: string, frozen = false) => ({ kind, nameAr: "مدرسة", nameEn: "School", memberCount: 2, frozen, seq: 1, lastAt: at(T), last: null, lastMessageId: "seedmsg0001" });
    for (const [cid, kind] of [[CARPOOL, "carpool"], [PRIVATE, "private"], [SCHOOL, "school"]] as const) {
      await db.doc(`chats/${cid}`).set(head(kind));
      await db.doc(`chats/${cid}/chatMembers/alice`).set(member("alice"));
      await db.doc(`chats/${cid}/chatMembers/bob`).set(member("bob"));
      await db.doc(`chats/${cid}/messages/seedmsg0001`).set({ senderUid: "bob", kind: "text", text: "seed", createdAt: at(T) });
    }
    // In the carpool chat: removed, cut off (suspended), muted now, muted long ago.
    await db.doc(`chats/${CARPOOL}/chatMembers/removed`).set(member("removed", { active: false }));
    await db.doc(`chats/${CARPOOL}/chatMembers/cut`).set(member("cut", { cut: true }));
    await db.doc(`chats/${CARPOOL}/chatMembers/muted`).set(member("muted", { mutedUntil: at(Date.now() + 10 * 60_000) }));
    await db.doc(`chats/${CARPOOL}/chatMembers/wasmuted`).set(member("wasmuted", { mutedUntil: at(Date.now() - 60_000) }));
    await db.doc(`chats/${CARPOOL}/reads/bob`).set({ readAt: at(T), typingAt: null });
    // A private chat where one parent blocked the other.
    await db.doc(`chats/${FROZEN}`).set(head("private", true));
    await db.doc(`chats/${FROZEN}/chatMembers/alice`).set(member("alice", { frozen: true }));
    await db.doc(`chats/${FROZEN}/chatMembers/bob`).set(member("bob", { frozen: true }));
    await db.doc(`chats/${FROZEN}/messages/seedmsg0001`).set({ senderUid: "bob", kind: "text", text: "before the block", createdAt: at(T) });
    // Chat lists.
    await db.doc(`userChats/alice/summaries/${CARPOOL}`).set(summary(CARPOOL));
    await db.doc(`userChats/alice/summaries/${SCHOOL}`).set(summary(SCHOOL, { kind: "school", open: false }));
    await db.doc(`userChats/bob/summaries/${CARPOOL}`).set(summary(CARPOOL));
    // A parent in a new-phone check (Prompt 12): chats stay closed.
    await db.doc("users/newphone").set({ status: "verified", newDeviceCheck: { required: true } });
    await db.doc(`chats/${CARPOOL}/chatMembers/newphone`).set(member("newphone"));
    await db.doc(`userChats/newphone/summaries/${CARPOOL}`).set(summary(CARPOOL));
  });
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.storage().ref(`chatPhotos/${CARPOOL}/bob/seedphoto001.webp`).putString("fake", "raw", { contentType: "image/webp" }).then(() => undefined);
  });
});

after(async () => {
  await env?.cleanup();
});

/** Who must get nothing, with the uid they would write as. */
const outsiders = (): Array<[string, string, RulesTestContext]> => [
  ["a parent who is not a member", "stranger", as("stranger")],
  ["a removed member", "removed", as("removed")],
  ["a cut-off (suspended) member", "cut", as("cut")],
  ["a member without the verified claim", "alice", as("alice", unverified)],
  ["a member in a new-phone check", "newphone", as("newphone")],
  ["an admin of the panel", "admin1", as("admin1", adminClaim)],
  ["a signed-out user", "nobody", signedOut()],
];

describe("chats: reading needs a current member document", () => {
  it("a member reads the head, the members and the newest messages", async () => {
    const db = as("alice").firestore();
    await assertSucceeds(db.doc(`chats/${CARPOOL}`).get());
    await assertSucceeds(db.doc(`chats/${CARPOOL}/chatMembers/bob`).get());
    await assertSucceeds(db.collection(`chats/${CARPOOL}/chatMembers`).limit(50).get());
    await assertSucceeds(db.doc(`chats/${CARPOOL}/messages/seedmsg0001`).get());
    await assertSucceeds(db.collection(`chats/${CARPOOL}/messages`).orderBy("createdAt", "desc").limit(30).get());
    await assertSucceeds(db.collection(`chats/${SCHOOL}/messages`).orderBy("createdAt", "desc").limit(30).get());
  });
  it("never all messages or all members at once, and never a list of chats", async () => {
    const db = as("alice").firestore();
    await assertFails(db.collection(`chats/${CARPOOL}/messages`).get());
    await assertFails(db.collection(`chats/${CARPOOL}/messages`).limit(51).get());
    await assertFails(db.collection(`chats/${SCHOOL}/chatMembers`).limit(51).get());
    await assertFails(db.collection("chats").limit(10).get());
    await assertFails(db.collectionGroup("messages").where("senderUid", "==", "alice").limit(10).get());
    await assertFails(db.collectionGroup("chatMembers").where("uid", "==", "alice").limit(10).get());
  });
  it("everyone else reads nothing: not a member, removed, cut off, unverified, new phone, admin, signed out", async () => {
    for (const [, , ctx] of outsiders()) {
      const db = ctx.firestore();
      await assertFails(db.doc(`chats/${CARPOOL}`).get());
      await assertFails(db.doc(`chats/${CARPOOL}/chatMembers/bob`).get());
      await assertFails(db.collection(`chats/${CARPOOL}/chatMembers`).limit(50).get());
      await assertFails(db.doc(`chats/${CARPOOL}/messages/seedmsg0001`).get());
      await assertFails(db.collection(`chats/${CARPOOL}/messages`).orderBy("createdAt", "desc").limit(30).get());
      await assertFails(db.collection(`chats/${CARPOOL}/reads`).limit(50).get());
    }
  });
  it("frozen and muted members still read", async () => {
    await assertSucceeds(as("alice").firestore().collection(`chats/${FROZEN}/messages`).orderBy("createdAt", "desc").limit(30).get());
    await assertSucceeds(as("muted").firestore().collection(`chats/${CARPOOL}/messages`).orderBy("createdAt", "desc").limit(30).get());
  });
});

describe("messages: the sender creates their own, under strict rules", () => {
  it("a member sends text; a photo and a location pin in a small chat", async () => {
    const db = as("alice").firestore();
    await assertSucceeds(db.doc(`chats/${CARPOOL}/messages/alicemsg0001`).set(text("alice")));
    await assertSucceeds(db.doc(`chats/${SCHOOL}/messages/alicemsg0001`).set(text("alice")));
    await assertSucceeds(db.doc(`chats/${PRIVATE}/messages/alicemsg0002`).set({ senderUid: "alice", kind: "location", lat: 30.05, lng: 31.25, createdAt: now() }));
    await assertSucceeds(
      db.doc(`chats/${CARPOOL}/messages/alicemsg0003`).set({ senderUid: "alice", kind: "photo", photoPath: `chatPhotos/${CARPOOL}/alice/alicemsg0003.webp`, createdAt: now() }),
    );
    await assertSucceeds(
      db.doc(`chats/${CARPOOL}/messages/alicemsg0004`).set({ senderUid: "alice", kind: "photo", photoPath: `chatPhotos/${CARPOOL}/alice/alicemsg0004.jpg`, createdAt: now() }),
    );
    await assertSucceeds(db.doc(`chats/${CARPOOL}/messages/alicemsg0005`).set(text("alice", "x".repeat(2000))));
  });
  it("everyone who cannot read cannot write either", async () => {
    for (const [, uid, ctx] of outsiders()) {
      await assertFails(ctx.firestore().doc(`chats/${CARPOOL}/messages/othermsg0001`).set(text(uid)));
    }
  });
  it("never as another sender, with another time, an extra field or a missing one", async () => {
    const db = as("alice").firestore();
    await assertFails(db.doc(`chats/${CARPOOL}/messages/badmsg00001`).set(text("bob")));
    await assertFails(db.doc(`chats/${CARPOOL}/messages/badmsg00002`).set({ ...text("alice"), createdAt: at(T) }));
    await assertFails(db.doc(`chats/${CARPOOL}/messages/badmsg00003`).set({ ...text("alice"), authorName: "School admin" }));
    await assertFails(db.doc(`chats/${CARPOOL}/messages/badmsg00004`).set({ ...text("alice"), expiresAt: now() }));
    await assertFails(db.doc(`chats/${CARPOOL}/messages/badmsg00005`).set({ senderUid: "alice", kind: "text", createdAt: now() }));
    await assertFails(db.doc(`chats/${CARPOOL}/messages/badmsg00006`).set({ senderUid: "alice", text: "hi", createdAt: now() }));
    await assertFails(db.doc(`chats/${CARPOOL}/messages/badmsg00007`).set({ senderUid: "alice", kind: "voice", text: "hi", createdAt: now() }));
    await assertFails(db.doc(`chats/${CARPOOL}/messages/badmsg00008`).set({ senderUid: "alice", kind: "text", text: 5, createdAt: now() }));
    // Short or odd message IDs.
    await assertFails(db.doc(`chats/${CARPOOL}/messages/short`).set(text("alice")));
    await assertFails(db.doc(`chats/${CARPOOL}/messages/bad.id.with.dots`).set(text("alice")));
  });
  it("oversize or empty text is refused", async () => {
    const db = as("alice").firestore();
    await assertFails(db.doc(`chats/${CARPOOL}/messages/bigmsg00001`).set(text("alice", "x".repeat(2001))));
    await assertFails(db.doc(`chats/${CARPOOL}/messages/bigmsg00002`).set(text("alice", "")));
  });
  it("a photo path must be the sender's own folder of that chat under the message's ID", async () => {
    const db = as("alice").firestore();
    const photo = (path: string) => ({ senderUid: "alice", kind: "photo", photoPath: path, createdAt: now() });
    await assertFails(db.doc(`chats/${CARPOOL}/messages/photomsg001`).set(photo(`chatPhotos/${CARPOOL}/bob/photomsg001.webp`)));
    await assertFails(db.doc(`chats/${CARPOOL}/messages/photomsg002`).set(photo(`chatPhotos/${PRIVATE}/alice/photomsg002.webp`)));
    await assertFails(db.doc(`chats/${CARPOOL}/messages/photomsg003`).set(photo(`chatPhotos/${CARPOOL}/alice/othername01.webp`)));
    await assertFails(db.doc(`chats/${CARPOOL}/messages/photomsg004`).set(photo("verification/bob/cases/c1/id_front.jpg")));
    await assertFails(db.doc(`chats/${CARPOOL}/messages/photomsg005`).set(photo("https://example.com/x.jpg")));
    await assertFails(db.doc(`chats/${CARPOOL}/messages/photomsg006`).set({ ...photo(`chatPhotos/${CARPOOL}/alice/photomsg006.webp`), text: "caption" }));
  });
  it("a location pin needs real coordinates and nothing else", async () => {
    const db = as("alice").firestore();
    const pin = (lat: unknown, lng: unknown) => ({ senderUid: "alice", kind: "location", lat, lng, createdAt: now() });
    await assertFails(db.doc(`chats/${CARPOOL}/messages/pinmsg00001`).set(pin(91, 31)));
    await assertFails(db.doc(`chats/${CARPOOL}/messages/pinmsg00002`).set(pin(30, 181)));
    await assertFails(db.doc(`chats/${CARPOOL}/messages/pinmsg00003`).set(pin("30", 31)));
    await assertFails(db.doc(`chats/${CARPOOL}/messages/pinmsg00004`).set({ senderUid: "alice", kind: "location", lat: 30, createdAt: now() }));
    await assertFails(db.doc(`chats/${CARPOOL}/messages/pinmsg00005`).set({ ...pin(30, 31), text: "home" }));
  });
  it("no photos and no location pin in school and area groups", async () => {
    const db = as("alice").firestore();
    await assertFails(db.doc(`chats/${SCHOOL}/messages/grpmsg00001`).set({ senderUid: "alice", kind: "location", lat: 30, lng: 31, createdAt: now() }));
    await assertFails(
      db.doc(`chats/${SCHOOL}/messages/grpmsg00002`).set({ senderUid: "alice", kind: "photo", photoPath: `chatPhotos/${SCHOOL}/alice/grpmsg00002.webp`, createdAt: now() }),
    );
  });
  it("a frozen chat takes no new message; a parent muted for sending too fast cannot write until it ends", async () => {
    await assertFails(as("alice").firestore().doc(`chats/${FROZEN}/messages/frozenmsg01`).set(text("alice")));
    await assertFails(as("bob").firestore().doc(`chats/${FROZEN}/messages/frozenmsg02`).set(text("bob")));
    await assertFails(as("muted").firestore().doc(`chats/${CARPOOL}/messages/mutedmsg001`).set(text("muted")));
    await assertSucceeds(as("wasmuted").firestore().doc(`chats/${CARPOOL}/messages/mutedmsg002`).set(text("wasmuted")));
  });
  it("nobody edits or deletes a message, their own included", async () => {
    const db = as("alice").firestore();
    await assertSucceeds(db.doc(`chats/${CARPOOL}/messages/alicemsg0001`).set(text("alice")));
    await assertFails(db.doc(`chats/${CARPOOL}/messages/alicemsg0001`).update({ text: "edited" }));
    await assertFails(db.doc(`chats/${CARPOOL}/messages/alicemsg0001`).set(text("alice", "again")));
    await assertFails(db.doc(`chats/${CARPOOL}/messages/alicemsg0001`).delete());
    await assertFails(as("bob").firestore().doc(`chats/${CARPOOL}/messages/seedmsg0001`).delete());
    await assertFails(db.doc(`chats/${CARPOOL}/messages/seedmsg0001`).update({ text: "forged" }));
  });
});

describe("the app never writes membership or the head", () => {
  it("no member document, head or chat can be created, changed or deleted from the app", async () => {
    for (const ctx of [as("alice"), as("stranger"), as("admin1", adminClaim)]) {
      const db = ctx.firestore();
      await assertFails(db.doc(`chats/${CARPOOL}/chatMembers/stranger`).set(member("stranger")));
      await assertFails(db.doc(`chats/${CARPOOL}/chatMembers/alice`).update({ mutedUntil: null }));
      await assertFails(db.doc(`chats/${FROZEN}/chatMembers/alice`).update({ frozen: false }));
      await assertFails(db.doc(`chats/${CARPOOL}/chatMembers/removed`).update({ active: true }));
      await assertFails(db.doc(`chats/${CARPOOL}/chatMembers/bob`).delete());
      await assertFails(db.doc(`chats/${CARPOOL}`).update({ frozen: false, nameEn: "Mine" }));
      await assertFails(db.doc(`chats/${CARPOOL}`).delete());
      await assertFails(db.doc("chats/cp_private:dm-new").set({ kind: "private" }));
      await assertFails(db.doc("chats/cp_private:dm-new/chatMembers/alice").set(member("alice")));
    }
  });
});

describe("userChats: the parent's own chat list", () => {
  it("the owner reads their open rows, queried with open == true", async () => {
    const db = as("alice").firestore();
    await assertSucceeds(db.doc(`userChats/alice/summaries/${CARPOOL}`).get());
    await assertSucceeds(db.collection("userChats/alice/summaries").where("open", "==", true).limit(100).get());
  });
  it("closed rows (removed or cut off), other parents' rows and unbounded lists are refused", async () => {
    const db = as("alice").firestore();
    await assertFails(db.doc(`userChats/alice/summaries/${SCHOOL}`).get());
    await assertFails(db.collection("userChats/alice/summaries").limit(100).get());
    await assertFails(db.collection("userChats/alice/summaries").where("open", "==", true).get());
    await assertFails(db.collection("userChats/alice/summaries").where("open", "==", true).limit(101).get());
    await assertFails(db.doc(`userChats/bob/summaries/${CARPOOL}`).get());
    await assertFails(db.collection("userChats/bob/summaries").where("open", "==", true).limit(100).get());
    await assertFails(as("alice", unverified).firestore().doc(`userChats/alice/summaries/${CARPOOL}`).get());
    await assertFails(as("newphone").firestore().doc(`userChats/newphone/summaries/${CARPOOL}`).get());
    await assertFails(as("admin1", adminClaim).firestore().doc(`userChats/alice/summaries/${CARPOOL}`).get());
    await assertFails(signedOut().firestore().doc(`userChats/alice/summaries/${CARPOOL}`).get());
    await assertFails(db.doc("userChats/alice").get());
  });
  it("the owner may only mark a chat read", async () => {
    const row = as("alice").firestore().doc(`userChats/alice/summaries/${CARPOOL}`);
    await assertSucceeds(row.update({ unread: 0, readAt: now(), readSeq: 1 }));
    await assertFails(row.update({ unread: 5, readAt: now(), readSeq: 1 }));
    await assertFails(row.update({ unread: 0, readAt: at(T), readSeq: 1 }));
    await assertFails(row.update({ unread: 0, readAt: now(), readSeq: -1 }));
    await assertFails(row.update({ unread: 0, readAt: now(), readSeq: "all" }));
    await assertFails(row.update({ unread: 0, readAt: now(), readSeq: 1, muted: false }));
    await assertFails(row.update({ unread: 0, readAt: now(), readSeq: 1, frozen: false }));
    await assertFails(row.update({ unread: 0, readAt: now(), readSeq: 1, otherName: "Admin" }));
    await assertFails(row.delete());
    await assertFails(as("alice").firestore().doc("userChats/alice/summaries/cp_private:dm-new").set(summary("cp_private:dm-new")));
    await assertFails(as("alice").firestore().doc(`userChats/alice/summaries/${SCHOOL}`).update({ unread: 0, readAt: now(), readSeq: 1, open: true }));
    await assertFails(as("bob").firestore().doc(`userChats/alice/summaries/${CARPOOL}`).update({ unread: 0, readAt: now(), readSeq: 1 }));
  });
});

describe("reads: own read mark and typing time, small chats only", () => {
  it("a member sets and clears their own, and reads the others'", async () => {
    const db = as("alice").firestore();
    await assertSucceeds(db.doc(`chats/${CARPOOL}/reads/alice`).set({ readAt: now() }, { merge: true }));
    await assertSucceeds(db.doc(`chats/${CARPOOL}/reads/alice`).set({ typingAt: now() }, { merge: true }));
    await assertSucceeds(db.doc(`chats/${CARPOOL}/reads/alice`).set({ typingAt: null }, { merge: true }));
    await assertSucceeds(db.collection(`chats/${CARPOOL}/reads`).limit(50).get());
  });
  it("not another parent's, not another time, no other field, not in a school group, not by a non-member", async () => {
    const db = as("alice").firestore();
    await assertFails(db.doc(`chats/${CARPOOL}/reads/bob`).set({ readAt: now() }, { merge: true }));
    await assertFails(db.doc(`chats/${CARPOOL}/reads/alice`).set({ readAt: at(T + 86_400_000 * 3650) }));
    await assertFails(db.doc(`chats/${CARPOOL}/reads/alice`).set({ readAt: now(), note: "x" }));
    await assertFails(db.doc(`chats/${SCHOOL}/reads/alice`).set({ readAt: now() }));
    await assertFails(db.collection(`chats/${SCHOOL}/reads`).limit(50).get());
    await assertFails(db.doc(`chats/${CARPOOL}/reads/alice`).delete());
    await assertFails(as("removed").firestore().doc(`chats/${CARPOOL}/reads/removed`).set({ readAt: now() }));
    await assertFails(as("stranger").firestore().doc(`chats/${CARPOOL}/reads/stranger`).set({ readAt: now() }));
  });
});

describe("storage.rules: chat photos, members of that chat only", () => {
  const webp = { contentType: "image/webp" };
  const jpeg = { contentType: "image/jpeg" };
  const put = (ctx: RulesTestContext, path: string, body = "fake-image", meta: { contentType: string } = webp) =>
    ctx.storage().ref(path).putString(body, "raw", meta).then(() => undefined);

  it("a member uploads into their own folder and members read it", async () => {
    await assertSucceeds(put(as("alice"), `chatPhotos/${CARPOOL}/alice/alicemsg0003.webp`));
    await assertSucceeds(put(as("alice"), `chatPhotos/${PRIVATE}/alice/alicemsg0004.jpg`, "fake-image", jpeg));
    await assertSucceeds(as("alice").storage().ref(`chatPhotos/${CARPOOL}/bob/seedphoto001.webp`).getMetadata());
    await assertSucceeds(as("muted").storage().ref(`chatPhotos/${CARPOOL}/bob/seedphoto001.webp`).getMetadata());
  });
  it("non-members, removed and cut-off parents, unverified, admins and signed-out users neither read nor upload", async () => {
    for (const [, uid, ctx] of outsiders().filter(([, id]) => id !== "newphone")) {
      await assertFails(ctx.storage().ref(`chatPhotos/${CARPOOL}/bob/seedphoto001.webp`).getMetadata());
      await assertFails(ctx.storage().ref(`chatPhotos/${CARPOOL}/bob/seedphoto001.webp`).getDownloadURL());
      await assertFails(put(ctx, `chatPhotos/${CARPOOL}/${uid}/othermsg0001.webp`));
    }
  });
  it("not into another parent's folder, not twice, never deleted, never listed", async () => {
    await assertFails(put(as("alice"), `chatPhotos/${CARPOOL}/bob/alicemsg0003.webp`));
    await assertSucceeds(put(as("alice"), `chatPhotos/${CARPOOL}/alice/alicemsg0003.webp`));
    await assertFails(put(as("alice"), `chatPhotos/${CARPOOL}/alice/alicemsg0003.webp`, "replaced"));
    await assertFails(as("alice").storage().ref(`chatPhotos/${CARPOOL}/alice/alicemsg0003.webp`).delete());
    await assertFails(as("bob").storage().ref(`chatPhotos/${CARPOOL}/bob/seedphoto001.webp`).delete());
    await assertFails(as("alice").storage().ref(`chatPhotos/${CARPOOL}/bob`).listAll());
  });
  it("only WebP or JPEG under 3 MB with a message-ID name", async () => {
    await assertFails(put(as("alice"), `chatPhotos/${CARPOOL}/alice/alicemsg0005.webp`, "x".repeat(3 * 1024 * 1024 + 1)));
    await assertFails(put(as("alice"), `chatPhotos/${CARPOOL}/alice/alicemsg0006.webp`, "fake", { contentType: "image/png" }));
    await assertFails(put(as("alice"), `chatPhotos/${CARPOOL}/alice/alicemsg0007.png`, "fake", { contentType: "image/png" }));
    await assertFails(put(as("alice"), `chatPhotos/${CARPOOL}/alice/alicemsg0008.html`, "<script>", { contentType: "text/html" }));
    await assertFails(put(as("alice"), `chatPhotos/${CARPOOL}/alice/x.webp`));
    await assertFails(put(as("alice"), `chatPhotos/${CARPOOL}/alice/alicemsg0009.webp`, ""));
  });
  it("no photos in a frozen chat, by a muted parent, or in a school group", async () => {
    await assertFails(put(as("alice"), `chatPhotos/${FROZEN}/alice/alicemsg0010.webp`));
    await assertFails(put(as("muted"), `chatPhotos/${CARPOOL}/muted/mutedmsg0001.webp`));
    await assertSucceeds(put(as("wasmuted"), `chatPhotos/${CARPOOL}/wasmuted/mutedmsg0002.webp`));
    await assertFails(put(as("alice"), `chatPhotos/${SCHOOL}/alice/alicemsg0011.webp`));
    await assertFails(as("alice").storage().ref(`chatPhotos/${SCHOOL}/alice/alicemsg0011.webp`).getMetadata());
  });
});
