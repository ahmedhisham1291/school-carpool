import { createHmac, timingSafeEqual } from "node:crypto";
import { cutText, SYSTEM_USER_ID, type MessageSnapshot } from "./model";

/**
 * The chat service as Cloud Functions use it. Two implementations:
 * - StreamChatServer: Stream's server REST API, signed with the app secret
 *   (never leaves Cloud Functions). No npm package: plain HTTPS with a
 *   server JWT, so nothing new to install and every call is visible here.
 * - FakeChatServer: dev without a Stream app, and CI. Records calls in
 *   memory; refused in prod (createChatServer).
 *
 * Logs from here carry IDs and counts only: never message text or names.
 */

export interface StreamUser {
  id: string;
  /** First name only (spec section 7). */
  name: string;
  parentId: string;
  language: "ar" | "en";
}

/** One of the parent's own messages, for the data export. */
export interface ExportedMessage {
  id: string;
  cid: string;
  text: string;
  createdAt: string;
  attachment: "image" | "location" | "other" | null;
}

export interface ChannelData {
  nameAr: string;
  nameEn: string;
  kind: string;
  refId: string | null;
}

export interface ChatServer {
  readonly kind: "fake" | "stream";
  /** Public key the app connects with ("" for the fake). */
  readonly apiKey: string;
  upsertUser(user: StreamUser): Promise<void>;
  /** A user token: HS256 JWT with user_id, iat and exp. */
  createToken(uid: string, issuedAtSec: number, expiresAtSec: number): string;
  /** Cuts the parent off at once: open connections close and every token stops working. */
  deactivateUser(uid: string): Promise<void>;
  reactivateUser(uid: string): Promise<void>;
  /** Tokens issued before [beforeMs] stop working. */
  revokeTokens(uid: string, beforeMs: number): Promise<void>;
  /** Creates the channel with [members] when missing (created by the system user). */
  ensureChannel(type: string, id: string, data: ChannelData, members: string[]): Promise<void>;
  addMembers(type: string, id: string, uids: string[]): Promise<void>;
  removeMembers(type: string, id: string, uids: string[]): Promise<void>;
  setFrozen(type: string, id: string, frozen: boolean): Promise<void>;
  setMuted(uid: string, cid: string, muted: boolean): Promise<void>;
  /** The message and its neighbours ([before] older, [after] newer); empty when gone. */
  messageWithContext(type: string, id: string, messageId: string, before: number, after: number): Promise<MessageSnapshot[]>;
  deleteMessage(messageId: string): Promise<void>;
  /**
   * Prompt 12 (owner decision: chat kept for the life of the chat + 1
   * year): hard-deletes an ended chat with all its messages.
   */
  deleteChannel(type: string, id: string): Promise<void>;
  /** Prompt 12: hard-deletes the Stream user and their messages (1 year after the account closed). */
  deleteUser(uid: string): Promise<void>;
  /** Prompt 12 (export): the parent's own messages, newest first, at most [limit]. */
  userMessages(uid: string, limit: number): Promise<ExportedMessage[]>;
  /**
   * Prompt 10 (F35): a message from the system user into a group channel
   * (the driver's quick messages in the carpool chat). [messageId] is
   * fixed by the caller, so a retry never posts twice. No push from Stream
   * (our notification sender already told the parents).
   */
  postSystemMessage(type: string, id: string, messageId: string, text: string, extra: Record<string, string>): Promise<void>;
}

// --------------------------------------------------------------------------
// JWT and webhook signature
// --------------------------------------------------------------------------

const b64url = (data: Buffer | string): string => Buffer.from(data).toString("base64url");

/** HS256 JWT, as Stream expects for server and user tokens. */
export function signJwt(payload: Record<string, unknown>, secret: string): string {
  const head = b64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const body = b64url(JSON.stringify(payload));
  const sig = createHmac("sha256", secret).update(`${head}.${body}`).digest("base64url");
  return `${head}.${body}.${sig}`;
}

/**
 * Stream signs every webhook: X-Signature is the hex HMAC-SHA256 of the raw
 * body with the app secret. Compared in constant time; anything else
 * (missing, wrong length, not hex) is refused.
 */
export function verifyWebhookSignature(rawBody: Buffer, signature: string | undefined, secret: string): boolean {
  if (!secret || typeof signature !== "string" || !/^[0-9a-f]{64}$/i.test(signature)) return false;
  const expected = createHmac("sha256", secret).update(rawBody).digest();
  const given = Buffer.from(signature, "hex");
  return given.length === expected.length && timingSafeEqual(given, expected);
}

// --------------------------------------------------------------------------
// Stream (REST)
// --------------------------------------------------------------------------

export type FetchLike = (url: string, init: { method: string; headers: Record<string, string>; body?: string }) => Promise<{
  ok: boolean;
  status: number;
  json(): Promise<unknown>;
}>;

export class ChatServiceError extends Error {
  constructor(
    readonly status: number,
    readonly code: number | null,
  ) {
    super(`stream request failed: ${status}${code === null ? "" : ` (code ${code})`}`);
  }
}

const BASE_URL = "https://chat.stream-io-api.com";

interface RawMessage {
  id?: unknown;
  text?: unknown;
  type?: unknown;
  created_at?: unknown;
  user?: { id?: unknown; name?: unknown; parent_id?: unknown };
  attachments?: Array<{ type?: unknown }>;
}

export function snapshotOf(m: RawMessage, reportedId: string): MessageSnapshot | null {
  if (typeof m.id !== "string") return null;
  const att = Array.isArray(m.attachments) && m.attachments.length > 0 ? m.attachments[0]?.type : null;
  return {
    id: m.id,
    authorUid: typeof m.user?.id === "string" ? m.user.id : "",
    authorName: typeof m.user?.name === "string" ? m.user.name : "",
    authorParentId: typeof m.user?.parent_id === "string" ? m.user.parent_id : "",
    text: cutText(typeof m.text === "string" ? m.text : ""),
    attachment: att === "image" || att === "location" ? att : att ? "other" : null,
    createdAtMs: typeof m.created_at === "string" ? Date.parse(m.created_at) || 0 : 0,
    reported: m.id === reportedId,
  };
}

export class StreamChatServer implements ChatServer {
  readonly kind = "stream" as const;

  constructor(
    readonly apiKey: string,
    private readonly secret: string,
    private readonly fetchFn: FetchLike = fetch as unknown as FetchLike,
    private readonly baseUrl = BASE_URL,
  ) {
    if (!apiKey || !secret) throw new Error("Stream key and secret are required");
  }

  private serverToken(): string {
    return signJwt({ server: true }, this.secret);
  }

  private async call(method: string, path: string, body?: unknown): Promise<Record<string, unknown>> {
    const sep = path.includes("?") ? "&" : "?";
    const response = await this.fetchFn(`${this.baseUrl}${path}${sep}api_key=${encodeURIComponent(this.apiKey)}`, {
      method,
      headers: {
        Authorization: this.serverToken(),
        "stream-auth-type": "jwt",
        "Content-Type": "application/json",
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const json = ((await response.json().catch(() => ({}))) ?? {}) as Record<string, unknown>;
    if (!response.ok) throw new ChatServiceError(response.status, typeof json.code === "number" ? json.code : null);
    return json;
  }

  private static path(type: string, id: string): string {
    return `/channels/${encodeURIComponent(type)}/${encodeURIComponent(id)}`;
  }

  async upsertUser(user: StreamUser): Promise<void> {
    await this.call("POST", "/users", {
      users: { [user.id]: { id: user.id, name: user.name, parent_id: user.parentId, language: user.language, role: "user" } },
    });
  }

  createToken(uid: string, issuedAtSec: number, expiresAtSec: number): string {
    return signJwt({ user_id: uid, iat: issuedAtSec, exp: expiresAtSec }, this.secret);
  }

  async deactivateUser(uid: string): Promise<void> {
    try {
      await this.call("POST", `/users/${encodeURIComponent(uid)}/deactivate`, { mark_messages_deleted: false, created_by_id: SYSTEM_USER_ID });
    } catch (error) {
      // Never connected (Stream answers 404 or 400 "user does not exist"): nothing to cut off.
      if (error instanceof ChatServiceError && (error.status === 404 || error.status === 400)) return;
      throw error;
    }
  }

  async reactivateUser(uid: string): Promise<void> {
    try {
      await this.call("POST", `/users/${encodeURIComponent(uid)}/reactivate`, { restore_messages: false, created_by_id: SYSTEM_USER_ID });
    } catch (error) {
      // Not deactivated (or never created): already fine.
      if (error instanceof ChatServiceError && (error.status === 404 || error.status === 400)) return;
      throw error;
    }
  }

  async revokeTokens(uid: string, beforeMs: number): Promise<void> {
    try {
      await this.call("PATCH", "/users", { users: [{ id: uid, set: { revoke_tokens_issued_before: new Date(beforeMs).toISOString() } }] });
    } catch (error) {
      // A parent who never opened chat has no Stream user, so no token to revoke.
      if (error instanceof ChatServiceError && (error.status === 404 || error.status === 400)) return;
      throw error;
    }
  }

  async ensureChannel(type: string, id: string, data: ChannelData, members: string[]): Promise<void> {
    await this.call("POST", `${StreamChatServer.path(type, id)}/query`, {
      data: {
        created_by_id: SYSTEM_USER_ID,
        members,
        name_ar: data.nameAr,
        name_en: data.nameEn,
        kind: data.kind,
        ref_id: data.refId,
      },
      state: false,
      watch: false,
      presence: false,
    });
  }

  async addMembers(type: string, id: string, uids: string[]): Promise<void> {
    if (uids.length === 0) return;
    for (let i = 0; i < uids.length; i += 100) {
      await this.call("POST", StreamChatServer.path(type, id), { add_members: uids.slice(i, i + 100), hide_history: false });
    }
  }

  async removeMembers(type: string, id: string, uids: string[]): Promise<void> {
    if (uids.length === 0) return;
    for (let i = 0; i < uids.length; i += 100) {
      await this.call("POST", StreamChatServer.path(type, id), { remove_members: uids.slice(i, i + 100) });
    }
  }

  async setFrozen(type: string, id: string, frozen: boolean): Promise<void> {
    await this.call("PATCH", StreamChatServer.path(type, id), { set: { frozen } });
  }

  async setMuted(uid: string, cid: string, muted: boolean): Promise<void> {
    if (muted) {
      await this.call("POST", "/moderation/mute/channel", { channel_cids: [cid], user_id: uid });
    } else {
      await this.call("POST", "/moderation/unmute/channel", { channel_cids: [cid], user_id: uid });
    }
  }

  async messageWithContext(type: string, id: string, messageId: string, before: number, after: number): Promise<MessageSnapshot[]> {
    let json: Record<string, unknown>;
    try {
      json = await this.call("POST", `${StreamChatServer.path(type, id)}/query`, {
        state: true,
        watch: false,
        presence: false,
        messages: { limit: before + after + 1, id_around: messageId },
      });
    } catch (error) {
      if (error instanceof ChatServiceError && error.status === 404) return [];
      throw error;
    }
    const all = (Array.isArray(json.messages) ? json.messages : []) as RawMessage[];
    const index = all.findIndex((m) => m.id === messageId);
    if (index < 0) return [];
    return all
      .slice(Math.max(0, index - before), index + after + 1)
      .filter((m) => m.type !== "deleted" && m.type !== "system")
      .map((m) => snapshotOf(m, messageId))
      .filter((m): m is MessageSnapshot => m !== null);
  }

  async deleteMessage(messageId: string): Promise<void> {
    try {
      await this.call("DELETE", `/messages/${encodeURIComponent(messageId)}?hard=true`);
    } catch (error) {
      if (error instanceof ChatServiceError && error.status === 404) return;
      throw error;
    }
  }

  async deleteChannel(type: string, id: string): Promise<void> {
    try {
      await this.call("DELETE", `${StreamChatServer.path(type, id)}?hard_delete=true`);
    } catch (error) {
      if (error instanceof ChatServiceError && error.status === 404) return;
      throw error;
    }
  }

  async deleteUser(uid: string): Promise<void> {
    try {
      await this.call("DELETE", `/users/${encodeURIComponent(uid)}?mark_messages_deleted=true&hard_delete=true`);
    } catch (error) {
      // Never connected: nothing to delete.
      if (error instanceof ChatServiceError && (error.status === 404 || error.status === 400)) return;
      throw error;
    }
  }

  async userMessages(uid: string, limit: number): Promise<ExportedMessage[]> {
    const out: ExportedMessage[] = [];
    let next: string | null = null;
    while (out.length < limit) {
      const payload: Record<string, unknown> = {
        filter_conditions: { members: { $in: [uid] } },
        message_filter_conditions: { "user.id": uid },
        sort: [{ field: "created_at", direction: -1 }],
        limit: Math.min(100, limit - out.length),
      };
      if (next) payload.next = next;
      let json: Record<string, unknown>;
      try {
        json = await this.call("GET", `/search?payload=${encodeURIComponent(JSON.stringify(payload))}`);
      } catch (error) {
        if (error instanceof ChatServiceError && (error.status === 404 || error.status === 400)) return out;
        throw error;
      }
      const results = Array.isArray(json.results) ? (json.results as Array<{ message?: RawMessage & { cid?: unknown } }>) : [];
      for (const r of results) {
        const m = r.message;
        if (!m || typeof m.id !== "string") continue;
        const att = Array.isArray(m.attachments) && m.attachments.length > 0 ? m.attachments[0]?.type : null;
        out.push({
          id: m.id,
          cid: typeof m.cid === "string" ? m.cid : "",
          text: typeof m.text === "string" ? m.text : "",
          createdAt: typeof m.created_at === "string" ? m.created_at : "",
          attachment: att === "image" || att === "location" ? att : att ? "other" : null,
        });
      }
      next = typeof json.next === "string" && json.next ? json.next : null;
      if (!next || results.length === 0) break;
    }
    return out;
  }

  async postSystemMessage(type: string, id: string, messageId: string, text: string, extra: Record<string, string>): Promise<void> {
    try {
      await this.call("POST", `${StreamChatServer.path(type, id)}/message`, {
        message: { ...extra, id: messageId, text, user_id: SYSTEM_USER_ID },
        skip_push: true,
      });
    } catch (error) {
      // 409 / code 4 with "already exists": the same message was posted before.
      if (error instanceof ChatServiceError && error.status === 409) return;
      throw error;
    }
  }
}

// --------------------------------------------------------------------------
// Fake (dev and CI)
// --------------------------------------------------------------------------

export interface FakeChannel {
  members: Set<string>;
  frozen: boolean;
  data: ChannelData;
}

/** Records every call; tests read its state. Messages are added by tests. */
export class FakeChatServer implements ChatServer {
  readonly kind = "fake" as const;
  readonly apiKey = "";
  users = new Map<string, StreamUser>();
  deactivated = new Set<string>();
  revokedBefore = new Map<string, number>();
  channels = new Map<string, FakeChannel>();
  mutes = new Map<string, boolean>();
  /** cid -> messages, oldest first (test data). */
  messages = new Map<string, RawMessage[]>();
  deleted: string[] = [];
  deletedChannels: string[] = [];
  calls: string[] = [];
  /** Makes the next calls fail (tests of retries and errors). */
  failing = false;

  constructor(private readonly log: (message: string) => void = () => undefined) {}

  private note(call: string): void {
    if (this.failing) throw new ChatServiceError(503, null);
    this.calls.push(call);
    this.log(`[fake chat] ${call}`);
  }

  async upsertUser(user: StreamUser): Promise<void> {
    this.note(`upsertUser ${user.id}`);
    this.users.set(user.id, { ...user });
  }

  createToken(uid: string, issuedAtSec: number, expiresAtSec: number): string {
    return `fake.${uid}.${issuedAtSec}.${expiresAtSec}`;
  }

  async deactivateUser(uid: string): Promise<void> {
    this.note(`deactivate ${uid}`);
    this.deactivated.add(uid);
  }

  async reactivateUser(uid: string): Promise<void> {
    this.note(`reactivate ${uid}`);
    this.deactivated.delete(uid);
  }

  async revokeTokens(uid: string, beforeMs: number): Promise<void> {
    this.note(`revoke ${uid}`);
    this.revokedBefore.set(uid, beforeMs);
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
    if (!c) throw new ChatServiceError(404, 16);
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
    const all = (this.messages.get(`${type}:${id}`) ?? []).filter((m) => !this.deleted.includes(String(m.id)));
    const index = all.findIndex((m) => m.id === messageId);
    if (index < 0) return [];
    return all
      .slice(Math.max(0, index - before), index + after + 1)
      .map((m) => snapshotOf(m, messageId))
      .filter((m): m is MessageSnapshot => m !== null);
  }

  async deleteMessage(messageId: string): Promise<void> {
    this.note(`deleteMessage ${messageId}`);
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
    for (const [cid, list] of this.messages) this.messages.set(cid, list.filter((m) => m.user?.id !== uid));
  }

  async userMessages(uid: string, limit: number): Promise<ExportedMessage[]> {
    this.note(`userMessages ${uid}`);
    const out: ExportedMessage[] = [];
    for (const [cid, list] of this.messages) {
      for (const m of list) {
        if (m.user?.id !== uid || typeof m.id !== "string") continue;
        out.push({ id: m.id, cid, text: typeof m.text === "string" ? m.text : "", createdAt: typeof m.created_at === "string" ? m.created_at : "", attachment: null });
      }
    }
    return out.slice(0, limit);
  }

  /** Prompt 10: system messages posted (cid, id, text, extra); one per ID. */
  systemMessages: Array<{ cid: string; id: string; text: string; extra: Record<string, string> }> = [];

  async postSystemMessage(type: string, id: string, messageId: string, text: string, extra: Record<string, string>): Promise<void> {
    this.note(`systemMessage ${type}:${id}`);
    if (this.systemMessages.some((m) => m.id === messageId)) return;
    this.systemMessages.push({ cid: `${type}:${id}`, id: messageId, text, extra: { ...extra } });
  }
}

/**
 * The configured server. The fake is refused in prod; Stream needs its key
 * and secret.
 */
export function createChatServer(provider: string, appEnv: string, apiKey: string, secret: string, log: (m: string) => void): ChatServer {
  if (provider === "stream") return new StreamChatServer(apiKey, secret);
  if (provider === "fake") {
    if (appEnv === "prod") throw new Error("The fake chat server is not allowed in prod");
    return new FakeChatServer(log);
  }
  throw new Error(`Unknown chat provider: ${provider}`);
}
