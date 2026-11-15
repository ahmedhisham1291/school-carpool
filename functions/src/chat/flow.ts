import type { ChatServer } from "./server";
import type { ChatLimitKind, ChatStore, DrivingPauser } from "./store";
import { newChannel, setMember, syncCarpoolsOf, syncParentGroups, type SyncDeps } from "./sync";
import {
  boolField,
  channelRef,
  ChatError,
  chatEligible,
  cidField,
  cleanNote,
  CONTEXT_AFTER,
  CONTEXT_BEFORE,
  isReportReason,
  isReportTarget,
  messageIdField,
  muteChoice,
  privateChannelId,
  record,
  requestId,
  uidField,
  URGENT_REASONS,
  withMuteChoice,
  type ChannelRecord,
  type ChatAccount,
  type ReportRecord,
  type RequestRecord,
} from "./model";

/**
 * What a parent can do in chat (callables.ts wraps these). Every check is
 * here, on the server: verified and not suspended, membership, blocks,
 * request limits. Logs: kinds and counts only, never names or text.
 */

export interface ChatLimits {
  requestsPerDay: number;
  reportsPerDay: number;
  changesPerDay: number;
  syncsPerHour: number;
}

export const DEFAULT_CHAT_LIMITS: ChatLimits = {
  requestsPerDay: 10,
  reportsPerDay: 20,
  changesPerDay: 100,
  syncsPerHour: 10,
};

export interface ChatDeps extends SyncDeps {
  store: ChatStore;
  server: ChatServer;
  limits: ChatLimits;
  pauser: DrivingPauser;
}

export interface Caller {
  uid: string;
  /** The "verified" custom claim. The record is checked too. */
  verifiedClaim: boolean;
}

const HOUR = 3_600_000;
const DAY = 24 * HOUR;

async function take(deps: ChatDeps, uid: string, kind: ChatLimitKind, windowMs: number, max: number): Promise<void> {
  const r = await deps.store.takeLimit(uid, kind, deps.now(), { windowMs, max });
  if (!r.allowed) throw new ChatError("rate-limited", r.retryAfterMs);
}

/** The caller, verified and not suspended or banned (spec section 5). */
export async function requireChatAccount(deps: ChatDeps, caller: Caller): Promise<ChatAccount> {
  if (!caller.verifiedClaim) throw new ChatError("not-verified");
  const account = await deps.store.account(caller.uid);
  if (!account) throw new ChatError("not-verified");
  if (account.banned || account.status === "suspended") throw new ChatError("suspended");
  if (!chatEligible(account)) throw new ChatError("not-verified");
  return account;
}

async function requireMember(deps: ChatDeps, uid: string, cid: string): Promise<ChannelRecord> {
  const channel = await deps.store.channel(cid);
  if (!channel || !channel.members.includes(uid)) throw new ChatError("not-member");
  return channel;
}

// --------------------------------------------------------------------------
// Joining (F8 to F10)
// --------------------------------------------------------------------------

/** Puts the caller in every chat they belong to (first visit, and after changes the triggers missed). */
export async function syncMyChats(deps: ChatDeps, caller: Caller): Promise<{ groups: number; carpools: number }> {
  await requireChatAccount(deps, caller);
  await take(deps, caller.uid, "syncs", HOUR, deps.limits.syncsPerHour);
  const groups = await syncParentGroups(deps, caller.uid);
  const carpools = await syncCarpoolsOf(deps, caller.uid);
  return { groups: groups.added, carpools };
}

// --------------------------------------------------------------------------
// Private chat requests (F8; spec section 5)
// --------------------------------------------------------------------------

/** True when either parent blocked the other. */
async function blockedEitherWay(store: ChatStore, a: string, b: string): Promise<boolean> {
  const [ab, ba] = await Promise.all([store.block(a, b), store.block(b, a)]);
  return ab !== null || ba !== null;
}

/** Parents may ask each other only when they share a school (children or driving) or a carpool. */
async function shareSomething(store: ChatStore, a: string, b: string): Promise<boolean> {
  const [sa, sb] = await Promise.all([store.allSchoolIds(a), store.allSchoolIds(b)]);
  const schools = new Set(sa);
  if (sb.some((s) => schools.has(s))) return true;
  const [ca, cb] = await Promise.all([store.carpoolIdsOf(a), store.carpoolIdsOf(b)]);
  const carpools = new Set(ca);
  return cb.some((c) => carpools.has(c));
}

export interface RequestView {
  id: string;
  status: RequestRecord["status"];
  cid: string | null;
}

const view = (r: RequestRecord): RequestView => ({ id: r.id, status: r.status, cid: r.cid });

/**
 * { toUid } -> the request. The other parent accepts or declines. A request
 * the other parent already sent is accepted at once. Limited per day
 * (CHAT_REQUESTS_PER_DAY), refused when blocked, when the other parent
 * turned requests off, or when they share no school or carpool.
 */
export async function sendChatRequest(deps: ChatDeps, caller: Caller, data: unknown): Promise<RequestView> {
  const me = await requireChatAccount(deps, caller);
  const toUid = uidField(record(data).toUid);
  if (toUid === caller.uid) throw new ChatError("self");
  // Counted before anything about the other parent is revealed (blocked,
  // requests off, no shared school), so nobody can probe uids freely.
  await take(deps, caller.uid, "requests", DAY, deps.limits.requestsPerDay);
  const other = await deps.store.account(toUid);
  if (!chatEligible(other)) throw new ChatError("not-found");
  if (await blockedEitherWay(deps.store, caller.uid, toUid)) throw new ChatError("blocked");

  const cid = channelRef("private", privateChannelId(caller.uid, toUid)).cid;
  const existing = await deps.store.channel(cid);
  if (existing && existing.members.includes(caller.uid) && existing.members.includes(toUid)) {
    throw new ChatError("already-connected");
  }
  // They already asked me: accept theirs.
  const reverse = await deps.store.request(requestId(toUid, caller.uid));
  if (reverse?.status === "pending") return answer(deps, me, reverse, true);

  const mine = await deps.store.request(requestId(caller.uid, toUid));
  if (mine?.status === "pending") throw new ChatError("already-pending");
  if ((await deps.store.settings(toUid)).requestsOff) throw new ChatError("requests-off");
  if (!(await shareSomething(deps.store, caller.uid, toUid))) throw new ChatError("no-shared-school");

  const nowMs = deps.now();
  const r: RequestRecord = {
    id: requestId(caller.uid, toUid),
    fromUid: caller.uid,
    toUid,
    fromFirstName: me.firstName,
    toFirstName: other.firstName,
    status: "pending",
    cid: null,
    createdAtMs: nowMs,
    updatedAtMs: nowMs,
  };
  await deps.store.putRequest(r);
  return view(r);
}

async function openPrivateChannel(deps: ChatDeps, a: string, b: string): Promise<string> {
  const ref = channelRef("private", privateChannelId(a, b));
  const nowMs = deps.now();
  const init = () => newChannel(ref, null, null, "", "", nowMs);
  await setMember(deps, ref, init, a, true);
  await setMember(deps, ref, init, b, true);
  return ref.cid;
}

async function answer(deps: ChatDeps, me: ChatAccount, r: RequestRecord, accept: boolean): Promise<RequestView> {
  const nowMs = deps.now();
  if (accept) {
    if (await blockedEitherWay(deps.store, r.fromUid, r.toUid)) throw new ChatError("blocked");
    const from = await deps.store.account(r.fromUid);
    if (!chatEligible(from)) throw new ChatError("not-found");
    const cid = await openPrivateChannel(deps, r.fromUid, r.toUid);
    const next: RequestRecord = { ...r, status: "accepted", cid, toFirstName: me.firstName, updatedAtMs: nowMs };
    await deps.store.putRequest(next);
    return view(next);
  }
  const next: RequestRecord = { ...r, status: "declined", updatedAtMs: nowMs };
  await deps.store.putRequest(next);
  return view(next);
}

/** { requestId, accept } -> the request. Only the parent it was sent to answers it. */
export async function answerChatRequest(deps: ChatDeps, caller: Caller, data: unknown): Promise<RequestView> {
  const me = await requireChatAccount(deps, caller);
  const raw = record(data);
  const id = typeof raw.requestId === "string" ? raw.requestId : "";
  const accept = boolField(raw.accept);
  const r = id.length > 0 && id.length < 300 ? await deps.store.request(id) : null;
  if (!r || r.toUid !== caller.uid) throw new ChatError("not-found");
  if (r.status !== "pending") return view(r);
  await take(deps, caller.uid, "changes", DAY, deps.limits.changesPerDay);
  return answer(deps, me, r, accept);
}

/** { requestId } -> the request. The sender takes back a pending request. */
export async function cancelChatRequest(deps: ChatDeps, caller: Caller, data: unknown): Promise<RequestView> {
  await requireChatAccount(deps, caller);
  const id = record(data).requestId;
  const r = typeof id === "string" && id.length < 300 ? await deps.store.request(id) : null;
  if (!r || r.fromUid !== caller.uid) throw new ChatError("not-found");
  if (r.status !== "pending") return view(r);
  const next: RequestRecord = { ...r, status: "cancelled", updatedAtMs: deps.now() };
  await deps.store.putRequest(next);
  return view(next);
}

// --------------------------------------------------------------------------
// Settings, mute, block (F8, F13)
// --------------------------------------------------------------------------

/** { requestsOff } -> the settings. */
export async function updateChatSettings(deps: ChatDeps, caller: Caller, data: unknown): Promise<{ requestsOff: boolean }> {
  await requireChatAccount(deps, caller);
  const requestsOff = boolField(record(data).requestsOff);
  await take(deps, caller.uid, "changes", DAY, deps.limits.changesPerDay);
  await deps.store.putSettings(caller.uid, { requestsOff }, deps.now());
  return { requestsOff };
}

/** { cid, muted } -> { muted }. Mute per chat: no push from it (the message trigger reads this). */
export async function setChatMute(deps: ChatDeps, caller: Caller, data: unknown): Promise<{ muted: boolean }> {
  await requireChatAccount(deps, caller);
  const raw = record(data);
  const ref = cidField(raw.cid);
  const muted = boolField(raw.muted);
  await requireMember(deps, caller.uid, ref.cid);
  await take(deps, caller.uid, "changes", DAY, deps.limits.changesPerDay);
  await deps.store.putMute({ uid: caller.uid, cid: ref.cid, muted, updatedAtMs: deps.now() });
  // On the channel record too: a new message then needs one read, not one
  // per parent who ever chose, to know who gets a push.
  await deps.store.updateChannel(ref.cid, (c) => (c && muteChoice(c, caller.uid) !== muted ? withMuteChoice(c, caller.uid, muted) : null));
  // Also on the parent's chat list row, so every phone shows it.
  await deps.server.setMuted(caller.uid, ref.cid, muted);
  return { muted };
}

/** Freezes or unfreezes the private chat of two parents (if they have one). */
async function freezePrivate(deps: ChatDeps, a: string, b: string, frozen: boolean): Promise<void> {
  const ref = channelRef("private", privateChannelId(a, b));
  const saved = await deps.store.updateChannel(ref.cid, (current) =>
    current && current.frozen !== frozen ? { ...current, frozen, updatedAtMs: deps.now() } : null,
  );
  if (saved) await deps.server.setFrozen(ref.type, ref.id, frozen);
}

/**
 * { uid } -> { blocked: true }. F13: the blocked parent cannot message the
 * blocker: their private chat is frozen (the rules refuse every new
 * message in it), pending requests both ways are cancelled, no new request is
 * accepted, and the blocker gets no push for the blocked parent's
 * messages in groups (the app hides them too).
 */
export async function blockChatUser(deps: ChatDeps, caller: Caller, data: unknown): Promise<{ blocked: boolean }> {
  await requireChatAccount(deps, caller);
  const other = uidField(record(data).uid);
  if (other === caller.uid) throw new ChatError("self");
  const otherAccount = await deps.store.account(other);
  if (!otherAccount) throw new ChatError("not-found");
  await take(deps, caller.uid, "changes", DAY, deps.limits.changesPerDay);
  const nowMs = deps.now();
  if (!(await deps.store.block(caller.uid, other))) {
    await deps.store.putBlock({ blockerUid: caller.uid, blockedUid: other, blockedFirstName: otherAccount.firstName, createdAtMs: nowMs });
  }
  for (const id of [requestId(caller.uid, other), requestId(other, caller.uid)]) {
    const r = await deps.store.request(id);
    if (r?.status === "pending") await deps.store.putRequest({ ...r, status: "cancelled", updatedAtMs: nowMs });
  }
  await freezePrivate(deps, caller.uid, other, true);
  return { blocked: true };
}

/** { uid } -> { blocked: false }. The private chat opens again unless the other parent blocked too. */
export async function unblockChatUser(deps: ChatDeps, caller: Caller, data: unknown): Promise<{ blocked: boolean }> {
  await requireChatAccount(deps, caller);
  const other = uidField(record(data).uid);
  await take(deps, caller.uid, "changes", DAY, deps.limits.changesPerDay);
  await deps.store.deleteBlock(caller.uid, other);
  if (!(await deps.store.block(other, caller.uid))) await freezePrivate(deps, caller.uid, other, false);
  return { blocked: false };
}

// --------------------------------------------------------------------------
// Reports (F13; spec sections 5 and 6)
// --------------------------------------------------------------------------

export interface ReportResult {
  reportId: string;
  urgent: boolean;
}

/**
 * { targetType: message | user | group, cid, messageId?, uid?, reason, note? }
 * -> { reportId, urgent }.
 *
 * The reporter must be a member of the chat. A message report keeps the
 * message with a little context (CONTEXT_BEFORE before, CONTEXT_AFTER
 * after): text cut short, first names and parent IDs, never the photo. An
 * urgent report (child safety, dangerous driving) about a parent pauses
 * that parent's driving days at once (spec section 6).
 */
export async function reportChat(deps: ChatDeps, caller: Caller, data: unknown): Promise<ReportResult> {
  await requireChatAccount(deps, caller);
  const raw = record(data);
  if (!isReportTarget(raw.targetType) || !isReportReason(raw.reason)) throw new ChatError("invalid-request");
  const targetType = raw.targetType;
  const reason = raw.reason;
  const ref = cidField(raw.cid);
  const note = cleanNote(raw.note);
  const channel = await requireMember(deps, caller.uid, ref.cid);
  await take(deps, caller.uid, "reports", DAY, deps.limits.reportsPerDay);

  let targetId: string;
  let subjectUid: string | null = null;
  let context: ReportRecord["context"] = [];
  if (targetType === "message") {
    targetId = messageIdField(raw.messageId);
    context = await deps.server.messageWithContext(ref.type, ref.id, targetId, CONTEXT_BEFORE, CONTEXT_AFTER);
    const reported = context.find((m) => m.reported);
    if (!reported) throw new ChatError("not-found");
    subjectUid = reported.authorUid || null;
  } else if (targetType === "user") {
    targetId = uidField(raw.uid);
    if (!channel.members.includes(targetId) && !channel.excluded.includes(targetId)) throw new ChatError("not-found");
    subjectUid = targetId;
  } else {
    targetId = ref.cid;
  }
  if (subjectUid === caller.uid) throw new ChatError("self");

  const urgent = URGENT_REASONS.includes(reason);
  const nowMs = deps.now();
  const report: ReportRecord = {
    id: deps.store.newReportId(),
    reporterUid: caller.uid,
    targetType,
    targetId,
    subjectUid,
    cid: ref.cid,
    kind: ref.kind,
    reason,
    note,
    urgent,
    status: "open",
    context,
    pausedDriving: false,
    outcome: null,
    handledBy: null,
    createdAtMs: nowMs,
    handledAtMs: null,
  };
  await deps.store.createReport(report);
  if (urgent && subjectUid) {
    const paused = await deps.pauser.pause(subjectUid, report.id);
    await deps.store.putReport({ ...report, pausedDriving: true });
    deps.log("urgent chat report: driving paused", { carpools: paused.carpools, runs: paused.runs });
  }
  deps.log("chat report", { targetType, reason, urgent });
  return { reportId: report.id, urgent };
}
