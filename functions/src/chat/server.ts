import { parsePhotoPath, type ChatData, type ChatHead, type ChatMember, type ChatSummary, type LastMessage, type StoredMessage } from "./data";
import { cutText, isSmallChat, MAX_GROUP_MEMBERS, parseCid, PREVIEW_TEXT_MAX, SMALL_CHAT_MAX, SYSTEM_USER_ID, type ChatKind, type MessageSnapshot } from "./model";

/**
 * The chat service as Cloud Functions use it. Two implementations:
 * - FirestoreChatServer: our own chat. It keeps the documents the phone
 *   reads (data.ts) in step with the channel registry: members, the
 *   parent's chat list, frozen and muted states, names.
 * - FakeChatServer: records calls in memory (unit tests; refused in prod).
 *
 * Membership is decided by the callers (sync.ts, flow.ts, admin.ts); this
 * only writes it where the rules and the phone read it. Logs from here
 * carry IDs and counts only: never message text or names.
 */

export interface ChatUser {
  id: string;
  /** First name only (spec section 6). */
  name: string;
}

/** One of the parent's own messages, for the data export. */
export interface ExportedMessage {
  id: string;
  cid: string;
  text: string;
  createdAt: string;
  attachment: "image" | "location" | null;
  /** The parent's own photo: its path in our private bucket (ask the privacy team for a copy). */
  photoPath: string | null;
  /** The parent's own location pin. */
  location: { lat: number; lng: number } | null;
}

export interface ChannelData {
  nameAr: string;
  nameEn: string;
  kind: string;
  refId: string | null;
}

export interface ChatServer {
  readonly kind: "fake" | "firestore";
  /** The parent's first name wherever chat shows it (member documents, private chat rows). */
  upsertUser(user: ChatUser): Promise<void>;
  /** Cuts the parent off at once: every chat closes for them in the rules. */
  deactivateUser(uid: string): Promise<void>;
  reactivateUser(uid: string): Promise<void>;
  /** Creates the chat with [members] when missing. */
  ensureChannel(type: string, id: string, data: ChannelData, members: string[]): Promise<void>;
  addMembers(type: string, id: string, uids: string[]): Promise<void>;
  removeMembers(type: string, id: string, uids: string[]): Promise<void>;
  setFrozen(type: string, id: string, frozen: boolean): Promise<void>;
  setMuted(uid: string, cid: string, muted: boolean): Promise<void>;
  /** The message and its neighbours ([before] older, [after] newer); empty when gone. */
  messageWithContext(type: string, id: string, messageId: string, before: number, after: number): Promise<MessageSnapshot[]>;
  deleteMessage(type: string, id: string, messageId: string): Promise<void>;
  /**
   * Owner decision: chat kept for the life of the chat + 1 year. Deletes an
   * ended chat with all its messages and photos.
   */
  deleteChannel(type: string, id: string): Promise<void>;
  /** Deletes the parent's messages, photos and chat list (1 year after the account closed). */
  deleteUser(uid: string): Promise<void>;
  /** Export: the parent's own messages, newest first, at most [limit]. */
  userMessages(uid: string, limit: number): Promise<ExportedMessage[]>;
  /**
   * F35: a message from the system sender into a group chat (the driver's
   * quick messages in the carpool chat). [messageId] is fixed by the
   * caller, so a retry never posts twice. No push (our notification
   * sender already told the parents).
   */
  postSystemMessage(type: string, id: string, messageId: string, text: string, extra: Record<string, string>): Promise<void>;
  /**
   * Deletes chat photos uploaded between 1 and 3 days ago that no message
   * names (an upload whose message was refused or never written), and
   * stops a parent with many of them from writing for a day. Returns the
   * number deleted.
   */
  sweepOrphanPhotos(nowMs: number): Promise<number>;
}

/** Orphans by one parent in one night that stop them from writing for a day. */
export const ORPHAN_PHOTOS_MUTE = 20;
const DAY_MS = 86_400_000;

// --------------------------------------------------------------------------
// Firestore
// --------------------------------------------------------------------------

const CHATS_PER_PARENT = 500;
const PURGE_PAGE = 300;
const PURGE_ROUNDS = 100;

function isKind(v: string): v is ChatKind {
  return v === "private" || v === "school" || v === "area" || v === "carpool";
}

export function previewOf(m: StoredMessage): LastMessage {
  return { kind: m.kind, senderUid: m.senderUid, text: m.kind === "text" ? cutText(m.text, PREVIEW_TEXT_MAX) : "" };
}

export class FirestoreChatServer implements ChatServer {
  readonly kind = "firestore" as const;

  constructor(
    private readonly data: ChatData,
    private readonly now: () => number = () => Date.now(),
  ) {}

  private static cid(type: string, id: string): string {
    return `${type}:${id}`;
  }

  async ensureChannel(type: string, id: string, data: ChannelData, members: string[]): Promise<void> {
    const cid = FirestoreChatServer.cid(type, id);
    const nowMs = this.now();
    const kind: ChatKind = isKind(data.kind) ? data.kind : (parseCid(cid)?.kind ?? "private");
    await this.data.updateHead(cid, (current) => {
      if (current === null) {
        return {
          cid,
          kind,
          nameAr: data.nameAr,
          nameEn: data.nameEn,
          refId: data.refId,
          memberCount: 0,
          frozen: false,
          seq: 0,
          lastAtMs: null,
          last: null,
          lastMessageId: null,
          createdAtMs: nowMs,
          updatedAtMs: nowMs,
        };
      }
      if (current.nameAr === data.nameAr && current.nameEn === data.nameEn) return null;
      return { ...current, nameAr: data.nameAr, nameEn: data.nameEn, updatedAtMs: nowMs };
    });
    if (members.length > 0) await this.addMembers(type, id, members);
  }

  private newSummary(head: ChatHead, nowMs: number): ChatSummary {
    return {
      cid: head.cid,
      kind: head.kind,
      nameAr: head.nameAr,
      nameEn: head.nameEn,
      otherUid: null,
      otherName: "",
      muted: null,
      frozen: head.frozen,
      open: true,
      memberCount: head.memberCount,
      unread: 0,
      // Joined now: nothing before this counts as unread.
      readSeq: head.seq,
      lastAtMs: null,
      last: null,
      joinedAtMs: nowMs,
      updatedAtMs: nowMs,
    };
  }

  async addMembers(type: string, id: string, uids: string[]): Promise<void> {
    const cid = FirestoreChatServer.cid(type, id);
    const nowMs = this.now();
    const head = await this.data.head(cid);
    if (!head) throw new Error("chat not found");
    let added = 0;
    for (const uid of uids) {
      const [existing, profile] = await Promise.all([this.data.member(cid, uid), this.data.profile(uid)]);
      if (!existing?.active) added += 1;
      const member: ChatMember = {
        uid,
        firstName: profile?.firstName ?? existing?.firstName ?? "",
        active: true,
        // A suspension that landed a moment ago stays (only reactivateUser lifts it).
        cut: existing?.cut ?? false,
        frozen: head.frozen,
        mutedUntilMs: existing?.mutedUntilMs ?? null,
        joinedAtMs: existing?.active ? existing.joinedAtMs : nowMs,
        updatedAtMs: nowMs,
      };
      await this.data.putMember(cid, member);
      const summary = await this.data.summary(uid, cid);
      if (!summary || !summary.open) {
        // Back in the chat: the mute choice stays, the counters start again.
        await this.data.putSummary(uid, { ...this.newSummary(head, nowMs), muted: summary?.muted ?? null });
      }
    }
    const saved = added === 0 ? head : await this.count(cid, added);
    if (isSmallChat(head.kind)) await this.refreshSmall(saved ?? head);
  }

  private count(cid: string, delta: number): Promise<ChatHead | null> {
    return this.data.updateHead(cid, (c) => (c ? { ...c, memberCount: Math.max(0, c.memberCount + delta), updatedAtMs: this.now() } : null));
  }

  /** Small chats: every member's row gets the member count and, in a private chat, the other parent. */
  private async refreshSmall(head: ChatHead): Promise<void> {
    const nowMs = this.now();
    const all = await this.data.members(head.cid, SMALL_CHAT_MAX * 2);
    for (const m of all) {
      if (!m.active) continue;
      const other = head.kind === "private" ? all.find((o) => o.uid !== m.uid) : undefined;
      await this.data.patchSummary(
        m.uid,
        head.cid,
        { nameAr: head.nameAr, nameEn: head.nameEn, memberCount: head.memberCount, frozen: head.frozen, otherUid: other?.uid ?? null, otherName: other?.firstName ?? "" },
        nowMs,
      );
    }
  }

  async removeMembers(type: string, id: string, uids: string[]): Promise<void> {
    const cid = FirestoreChatServer.cid(type, id);
    const nowMs = this.now();
    let removed = 0;
    for (const uid of uids) {
      const existing = await this.data.member(cid, uid);
      if (existing?.active) removed += 1;
      // The member document stays (inactive): the rules refuse them from now
      // on, and their old messages still show a first name.
      await this.data.patchMember(cid, uid, { active: false }, nowMs);
      await this.data.patchSummary(uid, cid, { open: false, last: null }, nowMs);
    }
    if (removed === 0) return;
    const head = await this.count(cid, -removed);
    if (head && isSmallChat(head.kind)) await this.refreshSmall(head);
  }

  async setFrozen(type: string, id: string, frozen: boolean): Promise<void> {
    const cid = FirestoreChatServer.cid(type, id);
    const nowMs = this.now();
    await this.data.updateHead(cid, (c) => (c && c.frozen !== frozen ? { ...c, frozen, updatedAtMs: nowMs } : null));
    // The rules read `frozen` on the member document (one read per message).
    for (const m of await this.data.members(cid, MAX_GROUP_MEMBERS)) {
      if (m.frozen !== frozen) await this.data.patchMember(cid, m.uid, { frozen }, nowMs);
      await this.data.patchSummary(m.uid, cid, { frozen }, nowMs);
    }
  }

  async setMuted(uid: string, cid: string, muted: boolean): Promise<void> {
    await this.data.patchSummary(uid, cid, { muted }, this.now());
  }

  async upsertUser(user: ChatUser): Promise<void> {
    const nowMs = this.now();
    for (const cid of await this.data.chatsOf(user.id, CHATS_PER_PARENT)) {
      const member = await this.data.member(cid, user.id);
      if (!member || member.firstName === user.name) continue;
      await this.data.patchMember(cid, user.id, { firstName: user.name }, nowMs);
      if (parseCid(cid)?.kind !== "private") continue;
      for (const other of await this.data.members(cid, 4)) {
        if (other.uid !== user.id) await this.data.patchSummary(other.uid, cid, { otherName: user.name }, nowMs);
      }
    }
  }

  async deactivateUser(uid: string): Promise<void> {
    const nowMs = this.now();
    for (const cid of await this.data.chatsOf(uid, CHATS_PER_PARENT)) {
      await this.data.patchMember(cid, uid, { cut: true }, nowMs);
      await this.data.patchSummary(uid, cid, { open: false }, nowMs);
    }
  }

  async reactivateUser(uid: string): Promise<void> {
    const nowMs = this.now();
    for (const cid of await this.data.chatsOf(uid, CHATS_PER_PARENT)) {
      const member = await this.data.member(cid, uid);
      if (!member) continue;
      await this.data.patchMember(cid, uid, { cut: false }, nowMs);
      if (member.active) await this.data.patchSummary(uid, cid, { open: true }, nowMs);
    }
  }

  async messageWithContext(type: string, id: string, messageId: string, before: number, after: number): Promise<MessageSnapshot[]> {
    const cid = FirestoreChatServer.cid(type, id);
    const messages = await this.data.messagesAround(cid, messageId, before, after);
    const authors = new Map<string, { name: string; parentId: string }>();
    for (const m of messages) {
      if (authors.has(m.senderUid) || m.senderUid === SYSTEM_USER_ID) continue;
      // Names come from our records, never from the message: nobody can forge one.
      const profile = await this.data.profile(m.senderUid);
      const member = profile ? null : await this.data.member(cid, m.senderUid);
      authors.set(m.senderUid, { name: profile?.firstName ?? member?.firstName ?? "", parentId: profile?.parentId ?? "" });
    }
    return messages.map((m) => ({
      id: m.id,
      authorUid: m.senderUid,
      authorName: authors.get(m.senderUid)?.name ?? "",
      authorParentId: authors.get(m.senderUid)?.parentId ?? "",
      text: cutText(m.text),
      // The photo itself is never copied into a report.
      attachment: m.kind === "photo" ? "image" : m.kind === "location" ? "location" : null,
      createdAtMs: m.createdAtMs,
      reported: m.id === messageId,
    }));
  }

  async deleteMessage(type: string, id: string, messageId: string): Promise<void> {
    const cid = FirestoreChatServer.cid(type, id);
    const deleted = await this.data.deleteMessage(cid, messageId);
    if (!deleted) return;
    const nowMs = this.now();
    const last: LastMessage = { kind: "deleted", senderUid: deleted.senderUid, text: "" };
    // The chat list must not keep showing the removed text.
    const head = await this.data.updateHead(cid, (c) => (c && c.lastMessageId === messageId ? { ...c, last, updatedAtMs: nowMs } : null));
    if (!head || !isSmallChat(head.kind)) return;
    for (const m of await this.data.members(cid, SMALL_CHAT_MAX * 2)) {
      if (m.active) await this.data.patchSummary(m.uid, cid, { last }, nowMs);
    }
  }

  async deleteChannel(type: string, id: string): Promise<void> {
    await this.data.deleteChat(FirestoreChatServer.cid(type, id));
  }

  async deleteUser(uid: string): Promise<void> {
    for (let round = 0; round < PURGE_ROUNDS; round += 1) {
      if ((await this.data.deleteMessagesBy(uid, PURGE_PAGE)) < PURGE_PAGE) break;
      if (round === PURGE_ROUNDS - 1) throw new Error("messages left; retried tomorrow");
    }
    for (const cid of await this.data.chatsOf(uid, CHATS_PER_PARENT)) {
      await this.data.deleteSummary(uid, cid);
      // Uploads no message names (so the loop above did not reach them).
      await this.data.deletePhotosOf(cid, uid);
    }
  }

  async sweepOrphanPhotos(nowMs: number): Promise<number> {
    // A day's grace: an upload whose message is still on its way (offline)
    // is not an orphan yet. Each photo is looked at on two nights at most.
    const photos = await this.data.photosCreatedBetween(nowMs - 3 * DAY_MS, nowMs - DAY_MS, 5_000);
    const perUid = new Map<string, string[]>();
    let deleted = 0;
    for (const photo of photos) {
      const parts = parsePhotoPath(photo.path);
      if (parts) {
        const message = await this.data.message(parts.cid, parts.messageId);
        if (message && message.photoPath === photo.path) continue;
        perUid.set(parts.uid, [...(perUid.get(parts.uid) ?? []), parts.cid]);
      }
      await this.data.deletePhoto(photo.path);
      deleted += 1;
    }
    for (const [uid, cids] of perUid) {
      if (cids.length < ORPHAN_PHOTOS_MUTE) continue;
      for (const cid of await this.data.chatsOf(uid, CHATS_PER_PARENT)) await this.data.patchMember(cid, uid, { mutedUntilMs: nowMs + DAY_MS }, nowMs);
    }
    return deleted;
  }

  async userMessages(uid: string, limit: number): Promise<ExportedMessage[]> {
    return (await this.data.messagesBy(uid, limit)).map((m) => ({
      id: m.id,
      cid: m.cid,
      text: m.text,
      createdAt: new Date(m.createdAtMs).toISOString(),
      attachment: m.kind === "photo" ? "image" : m.kind === "location" ? "location" : null,
      photoPath: m.photoPath,
      location: m.kind === "location" && m.lat !== null && m.lng !== null ? { lat: m.lat, lng: m.lng } : null,
    }));
  }

  async postSystemMessage(type: string, id: string, messageId: string, text: string, _extra: Record<string, string>): Promise<void> {
    // The message trigger (fanout.ts) updates the chat list; it sends no push
    // for the system sender.
    await this.data.createMessage(FirestoreChatServer.cid(type, id), {
      id: messageId,
      senderUid: SYSTEM_USER_ID,
      kind: "text",
      text,
      photoPath: null,
      lat: null,
      lng: null,
      createdAtMs: this.now(),
    });
  }
}

// --------------------------------------------------------------------------
// Fake (unit tests)
// --------------------------------------------------------------------------

export interface FakeChannel {
  members: Set<string>;
  frozen: boolean;
  data: ChannelData;
}

export interface FakeMessage {
  id: string;
  uid: string;
  name?: string;
  parentId?: string;
  text?: string;
  attachment?: "image" | "location";
  createdAtMs?: number;
}

/** Records every call; tests read its state. Messages are added by tests. */
export class FakeChatServer implements ChatServer {
  readonly kind = "fake" as const;
  users = new Map<string, ChatUser>();
  deactivated = new Set<string>();
  channels = new Map<string, FakeChannel>();
  mutes = new Map<string, boolean>();
  /** cid -> messages, oldest first (test data). */
  messages = new Map<string, FakeMessage[]>();
  deleted: string[] = [];
  deletedChannels: string[] = [];
  calls: string[] = [];
  /** Makes the next calls fail (tests of retries and errors). */
  failing = false;

  constructor(private readonly log: (message: string) => void = () => undefined) {}

  private note(call: string): void {
    if (this.failing) throw new Error("chat service down");
    this.calls.push(call);
    this.log(`[fake chat] ${call}`);
  }

  async upsertUser(user: ChatUser): Promise<void> {
    this.note(`upsertUser ${user.id}`);
    this.users.set(user.id, { ...user });
  }

  async deactivateUser(uid: string): Promise<void> {
    this.note(`deactivate ${uid}`);
    this.deactivated.add(uid);
  }

  async reactivateUser(uid: string): Promise<void> {
    this.note(`reactivate ${uid}`);
    this.deactivated.delete(uid);
  }

  async ensureChannel(type: string, id: string, data: ChannelData, members: string[]): Promise<void> {
    this.note(`ensureChannel ${type}:${id}`);
    const cid = `${type}:${id}`;
    const existing = this.channels.get(cid);
    if (existing) {
      existing.data = { ...data };
      return;
    }
    this.channels.set(cid, { members: new Set(members), frozen: false, data: { ...data } });
  }

  private channel(type: string, id: string): FakeChannel {
    const c = this.channels.get(`${type}:${id}`);
    if (!c) throw new Error("chat not found");
    return c;
  }

  async addMembers(type: string, id: string, uids: string[]): Promise<void> {
    this.note(`addMembers ${type}:${id} ${uids.length}`);
    const c = this.channel(type, id);
    for (const u of uids) c.members.add(u);
  }

  async removeMembers(type: string, id: string, uids: string[]): Promise<void> {
    this.note(`removeMembers ${type}:${id} ${uids.length}`);
    const c = this.channel(type, id);
    for (const u of uids) c.members.delete(u);
  }

  async setFrozen(type: string, id: string, frozen: boolean): Promise<void> {
    this.note(`setFrozen ${type}:${id} ${frozen}`);
    this.channel(type, id).frozen = frozen;
  }

  async setMuted(uid: string, cid: string, muted: boolean): Promise<void> {
    this.note(`setMuted ${uid} ${cid} ${muted}`);
    this.mutes.set(`${uid}|${cid}`, muted);
  }

  async messageWithContext(type: string, id: string, messageId: string, before: number, after: number): Promise<MessageSnapshot[]> {
    this.note(`context ${type}:${id}`);
    const all = (this.messages.get(`${type}:${id}`) ?? []).filter((m) => !this.deleted.includes(m.id));
    const index = all.findIndex((m) => m.id === messageId);
    if (index < 0) return [];
    return all.slice(Math.max(0, index - before), index + after + 1).map((m) => ({
      id: m.id,
      authorUid: m.uid,
      authorName: m.name ?? "",
      authorParentId: m.parentId ?? "",
      text: cutText(m.text ?? ""),
      attachment: m.attachment ?? null,
      createdAtMs: m.createdAtMs ?? 0,
      reported: m.id === messageId,
    }));
  }

  async deleteMessage(type: string, id: string, messageId: string): Promise<void> {
    this.note(`deleteMessage ${type}:${id} ${messageId}`);
    this.deleted.push(messageId);
  }

  async deleteChannel(type: string, id: string): Promise<void> {
    this.note(`deleteChannel ${type}:${id}`);
    this.channels.delete(`${type}:${id}`);
    this.messages.delete(`${type}:${id}`);
    this.deletedChannels.push(`${type}:${id}`);
  }

  async deleteUser(uid: string): Promise<void> {
    this.note(`deleteUser ${uid}`);
    this.users.delete(uid);
    for (const [cid, list] of this.messages) this.messages.set(cid, list.filter((m) => m.uid !== uid));
  }

  async userMessages(uid: string, limit: number): Promise<ExportedMessage[]> {
    this.note(`userMessages ${uid}`);
    const out: ExportedMessage[] = [];
    for (const [cid, list] of this.messages) {
      for (const m of list) {
        if (m.uid !== uid) continue;
        out.push({ id: m.id, cid, text: m.text ?? "", createdAt: new Date(m.createdAtMs ?? 0).toISOString(), attachment: m.attachment ?? null, photoPath: null, location: null });
      }
    }
    return out.slice(0, limit);
  }

  async sweepOrphanPhotos(nowMs: number): Promise<number> {
    this.note(`sweepOrphanPhotos ${nowMs}`);
    return 0;
  }

  /** System messages posted (cid, id, text, extra); one per ID. */
  systemMessages: Array<{ cid: string; id: string; text: string; extra: Record<string, string> }> = [];

  async postSystemMessage(type: string, id: string, messageId: string, text: string, extra: Record<string, string>): Promise<void> {
    this.note(`systemMessage ${type}:${id}`);
    if (this.systemMessages.some((m) => m.id === messageId)) return;
    this.systemMessages.push({ cid: `${type}:${id}`, id: messageId, text, extra: { ...extra } });
  }
}

/**
 * The configured server: "firestore" (dev on the emulators, staging and
 * prod) or "fake" (unit tests; refused in prod).
 */
export function createChatServer(provider: string, appEnv: string, data: () => ChatData, log: (m: string) => void): ChatServer {
  if (provider === "firestore") return new FirestoreChatServer(data());
  if (provider === "fake") {
    if (appEnv === "prod") throw new Error("The fake chat server is not allowed in prod");
    return new FakeChatServer(log);
  }
  throw new Error(`Unknown chat provider: ${provider}`);
}
