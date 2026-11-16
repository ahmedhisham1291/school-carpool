import * as logger from "firebase-functions/logger";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { HttpsError, onRequest, type CallableRequest, type FunctionsErrorCode } from "firebase-functions/v2/https";
import { adminDb } from "../admin";
import { deps as carpoolDeps } from "../carpools/callables";
import {
  CHAT_CHANGES_PER_DAY,
  CHAT_PROVIDER,
  CHAT_REPORTS_PER_DAY,
  CHAT_REQUESTS_PER_DAY,
  CHAT_TOKEN_TTL_MIN,
  CHAT_TOKENS_PER_HOUR,
  ENFORCE_APP_CHECK,
  MIN_INSTANCES,
  REGION,
  STREAM_API_KEY,
  STREAM_API_SECRET,
  appEnv,
} from "../config";
import { reportError } from "../sentry";
import { FirestoreChatStore, FirestoreDrivingPauser } from "./firestore_store";
import {
  answerChatRequest as answerFlow,
  blockChatUser as blockFlow,
  cancelChatRequest as cancelFlow,
  DEFAULT_CHAT_LIMITS,
  getChatToken as tokenFlow,
  reportChat as reportFlow,
  sendChatRequest as sendFlow,
  setChatMute as muteFlow,
  syncMyChats as syncMineFlow,
  unblockChatUser as unblockFlow,
  updateChatSettings as settingsFlow,
  type Caller,
  type ChatDeps,
} from "./flow";
import { CHAT_ERROR_CODES, ChatError } from "./model";
import { createChatServer, verifyWebhookSignature, type ChatServer } from "./server";
import { accountFromDoc, syncAccess, syncCarpoolMember, syncParentGroups, type SyncDeps } from "./sync";
import { handleWebhook } from "./webhook";
import { noteAbuse } from "../privacy/abuse_hook";
import { gatedCall } from "../privacy/device_gate";

/**
 * Chat functions (Prompt 9: F8, F9, F10, F13). The Stream secret is bound
 * only to these functions (Secret Manager) and never leaves them.
 * Logs: kinds, counts and error messages only.
 */

const secrets = [STREAM_API_SECRET];

function secretValue(): string {
  try {
    return STREAM_API_SECRET.value();
  } catch {
    // The emulators without functions/.secret.local: the fake server needs none.
    return "";
  }
}

export function server(): ChatServer {
  return createChatServer(CHAT_PROVIDER.value(), appEnv(), STREAM_API_KEY.value(), secretValue(), (m) => logger.info(m));
}

const log = (message: string, data?: Record<string, unknown>) => logger.info(message, data ?? {});

function syncDeps(): SyncDeps {
  return { store: new FirestoreChatStore(adminDb()), server: server(), now: () => Date.now(), log };
}

export function chatDeps(): ChatDeps {
  const ttlMin = CHAT_TOKEN_TTL_MIN.value();
  return {
    ...syncDeps(),
    limits: {
      ...DEFAULT_CHAT_LIMITS,
      tokensPerHour: CHAT_TOKENS_PER_HOUR.value(),
      requestsPerDay: CHAT_REQUESTS_PER_DAY.value(),
      reportsPerDay: CHAT_REPORTS_PER_DAY.value(),
      changesPerDay: CHAT_CHANGES_PER_DAY.value(),
    },
    // 15 minutes to 24 hours; one hour by default.
    tokenTtlSec: (Number.isInteger(ttlMin) && ttlMin >= 15 && ttlMin <= 1440 ? ttlMin : 60) * 60,
    pauser: new FirestoreDrivingPauser(adminDb(), carpoolDeps),
  };
}

function caller(request: CallableRequest): Caller {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
  return { uid, verifiedClaim: request.auth?.token.verified === true };
}

async function run<T>(name: string, body: () => Promise<T>): Promise<T> {
  try {
    return await body();
  } catch (error) {
    if (error instanceof HttpsError) throw error;
    if (error instanceof ChatError) {
      throw new HttpsError(CHAT_ERROR_CODES[error.reason] as FunctionsErrorCode, error.reason, {
        reason: error.reason,
        retryAfterSeconds: Math.ceil(error.retryAfterMs / 1000),
      });
    }
    logger.error(`${name} failed`, { message: error instanceof Error ? error.message : "unknown" });
    await reportError(error);
    throw new HttpsError("unavailable", "chat-unavailable", { reason: "chat-unavailable" });
  }
}

const opts = { enforceAppCheck: ENFORCE_APP_CHECK, secrets };

/** {} -> { provider, apiKey, userId, token, expiresAtMs }: verified, non-suspended parents only. */
export const getChatToken = gatedCall(opts, (r) =>
  run("getChatToken", async () => {
    return tokenFlow(chatDeps(), caller(r));
  }),
);

/** {} -> { groups, carpools }: joins the caller's school, area and carpool chats. */
export const syncMyChats = gatedCall(opts, (r) => run("syncMyChats", () => syncMineFlow(chatDeps(), caller(r))));

/** { toUid } -> { id, status, cid } */
export const sendChatRequest = gatedCall(opts, (r) =>
  run("sendChatRequest", async () => {
    // Prompt 12: many chat requests in an hour alert the admins.
    const to = typeof r.data === "object" && r.data !== null ? (r.data as { toUid?: unknown; uid?: unknown }) : {};
    await noteAbuse(caller(r).uid, "chatRequests", String(to.toUid ?? to.uid ?? "").slice(0, 64));
    return sendFlow(chatDeps(), caller(r), r.data);
  }),
);

/** { requestId, accept } -> { id, status, cid } */
export const answerChatRequest = gatedCall(opts, (r) => run("answerChatRequest", () => answerFlow(chatDeps(), caller(r), r.data)));

/** { requestId } -> { id, status, cid } */
export const cancelChatRequest = gatedCall(opts, (r) => run("cancelChatRequest", () => cancelFlow(chatDeps(), caller(r), r.data)));

/** { requestsOff } -> { requestsOff } */
export const updateChatSettings = gatedCall(opts, (r) => run("updateChatSettings", () => settingsFlow(chatDeps(), caller(r), r.data)));

/** { cid, muted } -> { muted } */
export const setChatMute = gatedCall(opts, (r) => run("setChatMute", () => muteFlow(chatDeps(), caller(r), r.data)));

/** { uid } -> { blocked: true } */
export const blockChatUser = gatedCall(opts, (r) => run("blockChatUser", () => blockFlow(chatDeps(), caller(r), r.data)));

/** { uid } -> { blocked: false } */
export const unblockChatUser = gatedCall(opts, (r) => run("unblockChatUser", () => unblockFlow(chatDeps(), caller(r), r.data)));

/** { targetType, cid, messageId?, uid?, reason, note? } -> { reportId, urgent } */
export const reportChat = gatedCall(opts, (r) => run("reportChat", () => reportFlow(chatDeps(), caller(r), r.data)));

// --------------------------------------------------------------------------
// Triggers: access and membership follow the records at once
// --------------------------------------------------------------------------

/** Stops retrying a trigger that keeps failing for longer than this. */
const MAX_TRIGGER_AGE_MS = 6 * 3_600_000;

function tooOld(time: string | undefined): boolean {
  const t = time ? Date.parse(time) : NaN;
  return Number.isFinite(t) && Date.now() - t > MAX_TRIGGER_AGE_MS;
}

/**
 * Suspend, ban, delete or lost verification: chat access ends at once
 * (Stream user deactivated, tokens revoked). Verified again: restored.
 * Retried on failure: being cut off must not depend on one call.
 */
export const syncChatOnUserWrite = onDocumentWritten(
  { document: "users/{uid}", region: REGION, retry: true, secrets },
  async (event) => {
    if (tooOld((event as { time?: string }).time)) {
      logger.error("chat access sync gave up after retries");
      return;
    }
    const uid = (event.params as Record<string, string>).uid;
    const change = {
      before: accountFromDoc(uid, event.data?.before?.data()),
      after: accountFromDoc(uid, event.data?.after?.data()),
    };
    try {
      const result = await syncAccess(syncDeps(), uid, change);
      if (result !== "none") logger.info("chat access", { result });
    } catch (error) {
      logger.error("chat access sync failed", { message: error instanceof Error ? error.message : "unknown" });
      await reportError(error);
      throw error;
    }
  },
);

/** Children's schools and the rounded home decide the school and area groups (F9). */
export const syncChatOnLocationWrite = onDocumentWritten(
  { document: "parentLocations/{uid}", region: REGION, retry: false, secrets },
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    const key = (d: Record<string, unknown> | undefined) =>
      JSON.stringify([d?.verified ?? null, d?.childSchoolIds ?? null, (d?.point as { latitude?: number } | undefined)?.latitude ?? null, (d?.point as { longitude?: number } | undefined)?.longitude ?? null]);
    if (key(before) === key(after)) return;
    try {
      await syncParentGroups(syncDeps(), (event.params as Record<string, string>).uid);
    } catch (error) {
      logger.error("chat group sync failed", { message: error instanceof Error ? error.message : "unknown" });
      await reportError(error);
    }
  },
);

/** Carpool chat (F10): follows the carpool's approved members (Prompt 6). */
export const syncChatOnCarpoolMemberWrite = onDocumentWritten(
  { document: "carpools/{carpoolId}/members/{uid}", region: REGION, retry: true, secrets },
  async (event) => {
    if (tooOld((event as { time?: string }).time)) return;
    const params = event.params as Record<string, string>;
    const member = event.data?.after?.exists === true;
    try {
      await syncCarpoolMember(syncDeps(), params.carpoolId, params.uid, member);
    } catch (error) {
      logger.error("carpool chat sync failed", { message: error instanceof Error ? error.message : "unknown" });
      await reportError(error);
      throw error;
    }
  },
);

// --------------------------------------------------------------------------
// Webhook and retention
// --------------------------------------------------------------------------

/**
 * Stream's webhook (SETUP.md 19.5): new messages become push-only
 * "chat-message" events for OUR sender. Anything without a valid
 * X-Signature is refused with 401 and nothing is read.
 */
export const chatWebhook = onRequest(
  { region: REGION, secrets, invoker: "public", minInstances: MIN_INSTANCES, maxInstances: 10, timeoutSeconds: 30 },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).send("");
      return;
    }
    const raw: Buffer = req.rawBody ?? Buffer.from("");
    if (!verifyWebhookSignature(raw, req.get("X-Signature") ?? undefined, secretValue())) {
      logger.warn("chat webhook with a bad signature refused");
      res.status(401).send("");
      return;
    }
    let body: unknown;
    try {
      body = JSON.parse(raw.toString("utf8"));
    } catch {
      res.status(400).send("");
      return;
    }
    try {
      await handleWebhook({ store: new FirestoreChatStore(adminDb()), now: () => Date.now(), log }, body);
      res.status(200).send("");
    } catch (error) {
      logger.error("chat webhook failed", { message: error instanceof Error ? error.message : "unknown" });
      await reportError(error);
      // Stream retries on 5xx.
      res.status(500).send("");
    }
  },
);

// Prompt 12: chat retention moved to retentionDaily (privacy/jobs.ts): a
// chat is kept for its life + 1 year (owner decision), so nothing is
// truncated nightly any more (Prompt 9 review item 3).
