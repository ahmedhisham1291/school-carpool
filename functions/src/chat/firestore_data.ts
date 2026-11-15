import { FieldValue, Timestamp, type DocumentData, type DocumentReference, type Firestore } from "firebase-admin/firestore";
import { USERS } from "../auth/accounts";
import type { Bucket } from "../verification/store";
import {
  CHAT_ACCESS,
  CHAT_FANNED,
  CHAT_MEMBERS,
  CHAT_MESSAGES,
  CHAT_PHOTOS,
  CHAT_READS,
  CHAT_SUMMARIES,
  CHATS,
  FANNED_TTL_DAYS,
  MESSAGE_KINDS,
  photoFolder,
  USER_CHATS,
  type ChatData,
  type ChatHead,
  type ChatMember,
  type ChatProfile,
  type ChatSummary,
  type FanMark,
  type LastMessage,
  type MemberPatch,
  type MessageKind,
  type StoredMessage,
  type StoredPhoto,
  type SummaryPatch,
} from "./data";
import { CHAT_KINDS, type ChatKind } from "./model";

/**
 * The chat documents in Firestore and the chat photos in Storage (data.ts
 * says who reads what). The Admin SDK bypasses the rules. Not unit-tested
 * here (no emulator in the unit tests): the logic above it runs against
 * the in-memory ChatData, and the rules tests cover what the phone may do.
 */

const ts = (ms: number): Timestamp => Timestamp.fromMillis(ms);
const tsOrNull = (ms: number | null): Timestamp | null => (ms === null ? null : ts(ms));

function ms(v: unknown): number {
  const t = v as { toMillis?: () => number } | null | undefined;
  return typeof t?.toMillis === "function" ? t.toMillis() : 0;
}

function text(v: unknown): string {
  return typeof v === "string" ? v : "";
}

function int(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : 0;
}

function isNotFound(error: unknown): boolean {
  const code = (error as { code?: unknown }).code;
  return code === 5 || code === "not-found";
}

function isAlreadyExists(error: unknown): boolean {
  const code = (error as { code?: unknown }).code;
  return code === 6 || code === "already-exists";
}

function lastFromDoc(v: unknown): LastMessage | null {
  const d = v as { kind?: unknown; senderUid?: unknown; text?: unknown } | null | undefined;
  if (!d || typeof d.kind !== "string") return null;
  const kind = d.kind === "deleted" || (MESSAGE_KINDS as readonly string[]).includes(d.kind) ? (d.kind as LastMessage["kind"]) : "text";
  return { kind, senderUid: text(d.senderUid), text: text(d.text) };
}

function kindOf(v: unknown): ChatKind {
  return (CHAT_KINDS as readonly string[]).includes(v as string) ? (v as ChatKind) : "private";
}

export function headToDoc(h: ChatHead): DocumentData {
  return {
    kind: h.kind,
    nameAr: h.nameAr,
    nameEn: h.nameEn,
    refId: h.refId,
    memberCount: h.memberCount,
    frozen: h.frozen,
    seq: h.seq,
    lastAt: tsOrNull(h.lastAtMs),
    last: h.last,
    lastMessageId: h.lastMessageId,
    createdAt: ts(h.createdAtMs),
    updatedAt: ts(h.updatedAtMs),
  };
}

export function headFromDoc(cid: string, d: DocumentData): ChatHead {
  return {
    cid,
    kind: kindOf(d.kind),
    nameAr: text(d.nameAr),
    nameEn: text(d.nameEn),
    refId: text(d.refId) || null,
    memberCount: int(d.memberCount),
    frozen: d.frozen === true,
    seq: int(d.seq),
    lastAtMs: d.lastAt ? ms(d.lastAt) : null,
    last: lastFromDoc(d.last),
    lastMessageId: text(d.lastMessageId) || null,
    createdAtMs: ms(d.createdAt),
    updatedAtMs: ms(d.updatedAt),
  };
}

/** chatMembers/{uid}: what the other members may read (the first name). */
export function memberToDoc(m: ChatMember): DocumentData {
  return { uid: m.uid, firstName: m.firstName, joinedAt: ts(m.joinedAtMs), updatedAt: ts(m.updatedAtMs) };
}

/** chatAccess/{uid}: what only the rules read. */
export function accessToDoc(m: ChatMember): DocumentData {
  return { uid: m.uid, active: m.active, cut: m.cut, frozen: m.frozen, mutedUntil: tsOrNull(m.mutedUntilMs), updatedAt: ts(m.updatedAtMs) };
}

export function memberFromDocs(uid: string, name: DocumentData | undefined, access: DocumentData | undefined): ChatMember {
  const n = name ?? {};
  const a = access ?? {};
  return {
    uid,
    firstName: text(n.firstName),
    active: a.active === true,
    cut: a.cut === true,
    frozen: a.frozen === true,
    mutedUntilMs: a.mutedUntil ? ms(a.mutedUntil) : null,
    joinedAtMs: ms(n.joinedAt),
    updatedAtMs: Math.max(ms(n.updatedAt), ms(a.updatedAt)),
  };
}

export function summaryToDoc(s: ChatSummary): DocumentData {
  return {
    cid: s.cid,
    kind: s.kind,
    nameAr: s.nameAr,
    nameEn: s.nameEn,
    otherUid: s.otherUid,
    otherName: s.otherName,
    muted: s.muted,
    frozen: s.frozen,
    open: s.open,
    memberCount: s.memberCount,
    unread: s.unread,
    readSeq: s.readSeq,
    readAt: null,
    lastAt: tsOrNull(s.lastAtMs),
    last: s.last,
    joinedAt: ts(s.joinedAtMs),
    updatedAt: ts(s.updatedAtMs),
  };
}

export function summaryFromDoc(cid: string, d: DocumentData): ChatSummary {
  return {
    cid,
    kind: kindOf(d.kind),
    nameAr: text(d.nameAr),
    nameEn: text(d.nameEn),
    otherUid: text(d.otherUid) || null,
    otherName: text(d.otherName),
    muted: typeof d.muted === "boolean" ? d.muted : null,
    frozen: d.frozen === true,
    open: d.open === true,
    memberCount: int(d.memberCount),
    unread: int(d.unread),
    readSeq: int(d.readSeq),
    lastAtMs: d.lastAt ? ms(d.lastAt) : null,
    last: lastFromDoc(d.last),
    joinedAtMs: ms(d.joinedAt),
    updatedAtMs: ms(d.updatedAt),
  };
}

export function storedFromDoc(id: string, d: DocumentData): StoredMessage {
  const kind = (MESSAGE_KINDS as readonly string[]).includes(d.kind as string) ? (d.kind as MessageKind) : "text";
  return {
    id,
    senderUid: text(d.senderUid),
    kind,
    text: text(d.text),
    photoPath: text(d.photoPath) || null,
    lat: typeof d.lat === "number" ? d.lat : null,
    lng: typeof d.lng === "number" ? d.lng : null,
    createdAtMs: ms(d.createdAt),
  };
}

/** Only fields that are set: Firestore refuses `undefined`. */
function patchDoc(patch: Record<string, unknown>, nowMs: number): DocumentData {
  const out: DocumentData = { updatedAt: ts(nowMs) };
  for (const [key, value] of Object.entries(patch)) {
    if (value === undefined) continue;
    if (key === "mutedUntilMs") out.mutedUntil = tsOrNull(value as number | null);
    else out[key] = value;
  }
  return out;
}

export class FirestoreChatData implements ChatData {
  constructor(
    private readonly db: Firestore,
    private readonly bucket: () => Bucket,
  ) {}

  private chat(cid: string): DocumentReference {
    return this.db.collection(CHATS).doc(cid);
  }

  private memberRef(cid: string, uid: string): DocumentReference {
    return this.chat(cid).collection(CHAT_MEMBERS).doc(uid);
  }

  private accessRef(cid: string, uid: string): DocumentReference {
    return this.chat(cid).collection(CHAT_ACCESS).doc(uid);
  }

  private fannedRef(cid: string, messageId: string): DocumentReference {
    return this.chat(cid).collection(CHAT_FANNED).doc(messageId);
  }

  private summaryRef(uid: string, cid: string): DocumentReference {
    return this.db.collection(USER_CHATS).doc(uid).collection(CHAT_SUMMARIES).doc(cid);
  }

  private messageRef(cid: string, id: string): DocumentReference {
    return this.chat(cid).collection(CHAT_MESSAGES).doc(id);
  }

  async profile(uid: string): Promise<ChatProfile | null> {
    const snap = await this.db.collection(USERS).doc(uid).get();
    return snap.exists ? { firstName: text(snap.get("firstName")), parentId: text(snap.get("parentId")) } : null;
  }

  async head(cid: string): Promise<ChatHead | null> {
    const snap = await this.chat(cid).get();
    return snap.exists ? headFromDoc(cid, snap.data() ?? {}) : null;
  }

  updateHead(cid: string, change: (current: ChatHead | null) => ChatHead | null): Promise<ChatHead | null> {
    const ref = this.chat(cid);
    return this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const next = change(snap.exists ? headFromDoc(cid, snap.data() ?? {}) : null);
      if (next) tx.set(ref, headToDoc(next));
      return next;
    });
  }

  async claimMessage(cid: string, messageId: string, nowMs: number): Promise<boolean> {
    try {
      // TTL on expiresAt (tool/setup_retention.sh, collection group "fanned").
      await this.fannedRef(cid, messageId).create({ verdict: "ok", counted: false, createdAt: ts(nowMs), expiresAt: ts(nowMs + FANNED_TTL_DAYS * 86_400_000) });
      return true;
    } catch (error) {
      if (isAlreadyExists(error)) return false;
      throw error;
    }
  }

  async fanMark(cid: string, messageId: string): Promise<FanMark | null> {
    const snap = await this.fannedRef(cid, messageId).get();
    return snap.exists ? { verdict: snap.get("verdict") === "over" ? "over" : "ok", counted: snap.get("counted") === true } : null;
  }

  async setVerdict(cid: string, messageId: string, verdict: FanMark["verdict"]): Promise<void> {
    await FirestoreChatData.patch(this.fannedRef(cid, messageId), { verdict });
  }

  countMessage(cid: string, messageId: string, change: (current: ChatHead) => ChatHead): Promise<"counted" | "duplicate" | "no-head"> {
    const headRef = this.chat(cid);
    const markRef = this.fannedRef(cid, messageId);
    return this.db.runTransaction(async (tx) => {
      const [head, mark] = await Promise.all([tx.get(headRef), tx.get(markRef)]);
      if (!head.exists) return "no-head";
      if (mark.exists && mark.get("counted") === true) return "duplicate";
      tx.set(headRef, headToDoc(change(headFromDoc(cid, head.data() ?? {}))));
      // System messages have no marker yet: this creates it, with its TTL.
      tx.set(markRef, { counted: true, expiresAt: ts(Date.now() + FANNED_TTL_DAYS * 86_400_000) }, { merge: true });
      return "counted";
    });
  }

  async member(cid: string, uid: string): Promise<ChatMember | null> {
    const [name, access] = await Promise.all([this.memberRef(cid, uid).get(), this.accessRef(cid, uid).get()]);
    return name.exists || access.exists ? memberFromDocs(uid, name.data(), access.data()) : null;
  }

  async putMember(cid: string, member: ChatMember): Promise<void> {
    const batch = this.db.batch();
    batch.set(this.memberRef(cid, member.uid), memberToDoc(member));
    batch.set(this.accessRef(cid, member.uid), accessToDoc(member));
    await batch.commit();
  }

  private static async patch(ref: DocumentReference, data: DocumentData): Promise<void> {
    try {
      await ref.update(data);
    } catch (error) {
      if (!isNotFound(error)) throw error;
    }
  }

  async patchMember(cid: string, uid: string, patch: MemberPatch, nowMs: number): Promise<void> {
    const { firstName, ...access } = patch;
    if (firstName !== undefined) await FirestoreChatData.patch(this.memberRef(cid, uid), patchDoc({ firstName }, nowMs));
    if (Object.values(access).some((v) => v !== undefined)) await FirestoreChatData.patch(this.accessRef(cid, uid), patchDoc(access, nowMs));
  }

  async members(cid: string, limit: number): Promise<ChatMember[]> {
    const [names, access] = await Promise.all([
      this.chat(cid).collection(CHAT_MEMBERS).limit(limit).get(),
      this.chat(cid).collection(CHAT_ACCESS).limit(limit).get(),
    ]);
    const byUid = new Map<string, DocumentData>();
    for (const d of access.docs) byUid.set(d.id, d.data());
    const out: ChatMember[] = [];
    for (const d of names.docs) out.push(memberFromDocs(d.id, d.data(), byUid.get(d.id)));
    return out;
  }

  async chatsOf(uid: string, limit: number): Promise<string[]> {
    // Collection group index on chatAccess.uid (firestore.indexes.json).
    const snap = await this.db.collectionGroup(CHAT_ACCESS).where("uid", "==", uid).limit(limit).get();
    const out: string[] = [];
    for (const d of snap.docs) {
      const cid = d.ref.parent.parent?.id ?? "";
      if (cid.length > 0) out.push(cid);
    }
    return out;
  }

  async summary(uid: string, cid: string): Promise<ChatSummary | null> {
    const snap = await this.summaryRef(uid, cid).get();
    return snap.exists ? summaryFromDoc(cid, snap.data() ?? {}) : null;
  }

  async putSummary(uid: string, summary: ChatSummary): Promise<void> {
    await this.summaryRef(uid, summary.cid).set(summaryToDoc(summary));
  }

  async patchSummary(uid: string, cid: string, patch: SummaryPatch, nowMs: number): Promise<void> {
    await FirestoreChatData.patch(this.summaryRef(uid, cid), patchDoc(patch, nowMs));
  }

  async deleteSummary(uid: string, cid: string): Promise<void> {
    await this.summaryRef(uid, cid).delete();
    await this.chat(cid).collection(CHAT_READS).doc(uid).delete();
  }

  async noteMessage(cid: string, uids: string[], senderUid: string, last: LastMessage, lastAtMs: number): Promise<void> {
    // update(), not set(): a parent without a row (removed a moment ago) gets none back.
    await Promise.all(
      uids.map((uid) =>
        FirestoreChatData.patch(this.summaryRef(uid, cid), {
          last,
          lastAt: ts(lastAtMs),
          ...(uid === senderUid ? {} : { unread: FieldValue.increment(1) }),
        }),
      ),
    );
  }

  async message(cid: string, id: string): Promise<StoredMessage | null> {
    const snap = await this.messageRef(cid, id).get();
    return snap.exists ? storedFromDoc(id, snap.data() ?? {}) : null;
  }

  async messagesAround(cid: string, id: string, before: number, after: number): Promise<StoredMessage[]> {
    const snap = await this.messageRef(cid, id).get();
    if (!snap.exists) return [];
    const messages = this.chat(cid).collection(CHAT_MESSAGES);
    const [older, newer] = await Promise.all([
      before > 0 ? messages.orderBy("createdAt", "desc").startAfter(snap).limit(before).get() : null,
      after > 0 ? messages.orderBy("createdAt", "asc").startAfter(snap).limit(after).get() : null,
    ]);
    return [
      ...(older?.docs ?? []).map((d) => storedFromDoc(d.id, d.data())).reverse(),
      storedFromDoc(id, snap.data() ?? {}),
      ...(newer?.docs ?? []).map((d) => storedFromDoc(d.id, d.data())),
    ];
  }

  async latestMessage(cid: string): Promise<StoredMessage | null> {
    const snap = await this.chat(cid).collection(CHAT_MESSAGES).orderBy("createdAt", "desc").limit(1).get();
    const d = snap.docs[0];
    return d ? storedFromDoc(d.id, d.data()) : null;
  }

  async createMessage(cid: string, m: StoredMessage): Promise<boolean> {
    try {
      await this.messageRef(cid, m.id).create({
        senderUid: m.senderUid,
        kind: m.kind,
        ...(m.kind === "text" ? { text: m.text } : {}),
        ...(m.kind === "photo" ? { photoPath: m.photoPath } : {}),
        ...(m.kind === "location" ? { lat: m.lat, lng: m.lng } : {}),
        createdAt: ts(m.createdAtMs),
      });
      return true;
    } catch (error) {
      if (isAlreadyExists(error)) return false;
      throw error;
    }
  }

  async deletePhoto(path: string | null): Promise<void> {
    if (path && path.startsWith(`${CHAT_PHOTOS}/`)) await this.bucket().file(path).delete({ ignoreNotFound: true });
  }

  async deletePhotosOf(cid: string, uid: string): Promise<void> {
    const [files] = await this.bucket().getFiles({ prefix: `${photoFolder(cid)}/${uid}/` });
    for (const f of files) await f.delete({ ignoreNotFound: true });
  }

  async photosCreatedBetween(fromMs: number, toMs: number, limit: number): Promise<StoredPhoto[]> {
    // Names and creation times only (a listing, no download).
    const [files] = await this.bucket().getFiles({ prefix: `${CHAT_PHOTOS}/`, maxResults: 20_000 });
    const out: StoredPhoto[] = [];
    for (const f of files) {
      const created = Date.parse(String((f.metadata as { timeCreated?: unknown } | undefined)?.timeCreated ?? ""));
      if (Number.isFinite(created) && created >= fromMs && created < toMs) out.push({ path: f.name, createdAtMs: created });
      if (out.length >= limit) break;
    }
    return out;
  }

  async deleteMessage(cid: string, id: string): Promise<StoredMessage | null> {
    const ref = this.messageRef(cid, id);
    const snap = await ref.get();
    if (!snap.exists) return null;
    const message = storedFromDoc(id, snap.data() ?? {});
    await ref.delete();
    await this.deletePhoto(message.photoPath);
    return message;
  }

  async messagesBy(uid: string, limit: number): Promise<Array<StoredMessage & { cid: string }>> {
    // Collection group index on messages (senderUid, createdAt desc).
    const snap = await this.db.collectionGroup(CHAT_MESSAGES).where("senderUid", "==", uid).orderBy("createdAt", "desc").limit(limit).get();
    return snap.docs.map((d) => ({ ...storedFromDoc(d.id, d.data()), cid: d.ref.parent.parent?.id ?? "" }));
  }

  async deleteMessagesBy(uid: string, limit: number): Promise<number> {
    const snap = await this.db.collectionGroup(CHAT_MESSAGES).where("senderUid", "==", uid).orderBy("createdAt", "desc").limit(limit).get();
    for (const d of snap.docs) {
      await d.ref.delete();
      await this.deletePhoto(text(d.get("photoPath")) || null);
    }
    return snap.size;
  }

  async deleteChat(cid: string): Promise<void> {
    const chat = this.chat(cid);
    // The members' chat list rows first (they live outside the chat's tree).
    for (;;) {
      const page = await chat.collection(CHAT_MEMBERS).limit(300).get();
      if (page.empty) break;
      for (const m of page.docs) {
        await this.summaryRef(m.id, cid).delete();
        await this.accessRef(cid, m.id).delete();
        await m.ref.delete();
      }
    }
    const [files] = await this.bucket().getFiles({ prefix: `${photoFolder(cid)}/` });
    for (const f of files) await f.delete({ ignoreNotFound: true });
    // Messages, reads, markers, any access document left, and the head.
    await this.db.recursiveDelete(chat);
  }
}
