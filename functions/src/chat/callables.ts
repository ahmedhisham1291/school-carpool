import * as logger from "firebase-functions/logger";
import { onDocumentCreated, onDocumentWritten } from "firebase-functions/v2/firestore";
import { HttpsError, type CallableRequest, type FunctionsErrorCode } from "firebase-functions/v2/https";
import { adminDb, adminStorage } from "../admin";
import { deps as carpoolDeps } from "../carpools/callables";
import {
  CHAT_CHANGES_PER_DAY,
  CHAT_MESSAGES_PER_MINUTE,
  CHAT_MUTE_MINUTES,
  CHAT_PROVIDER,
  CHAT_REPORTS_PER_DAY,
  CHAT_REQUESTS_PER_DAY,
  ENFORCE_APP_CHECK,
  REGION,
} from "../config";
import { reportError } from "../sentry";
import { onMessageCreated } from "./fanout";
import { FirestoreChatData } from "./firestore_data";
import { FirestoreChatStore, FirestoreDrivingPauser } from "./firestore_store";
import {
  answerChatRequest as answerFlow,
  blockChatUser as blockFlow,
  cancelChatRequest as cancelFlow,
  DEFAULT_CHAT_LIMITS,
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
import { createChatServer, type ChatServer } from "./server";
import { accountFromDoc, syncAccess, syncCarpoolMember, syncParentGroups, type SyncDeps } from "./sync";
import { noteAbuse } from "../privacy/abuse_hook";
import { gatedCall } from "../privacy/device_gate";

/**
 * Chat functions (F8, F9, F10, F13): our own chat on Firestore. No outside
 * service and no secret. Logs: kinds, counts and error messages only.
 */

export function chatData(): FirestoreChatData {
  return new FirestoreChatData(adminDb(), () => adminStorage().bucket());
}

export function server(): ChatServer {
  return createChatServer(CHAT_PROVIDER.value(), process.env.APP_ENV ?? "dev", chatData, (m) => logger.info(m));
}

const log = (message: string, data?: Record<string, unknown>) => logger.info(message, data ?? {});

function syncDeps(): SyncDeps {
  return { store: new FirestoreChatStore(adminDb()), server: server(), now: () => Date.now(), log };
}

export function chatDeps(): ChatDeps {
  return {
    ...syncDeps(),
    limits: {
      ...DEFAULT_CHAT_LIMITS,
      requestsPerDay: CHAT_REQUESTS_PER_DAY.value(),
      reportsPerDay: CHAT_REPORTS_PER_DAY.value(),
      changesPerDay: CHAT_CHANGES_PER_DAY.value(),
    },
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

const opts = { enforceAppCheck: ENFORCE_APP_CHECK };

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
 * (the rules read the member documents this marks). Verified again: restored.
 * Retried on failure: being cut off must not depend on one call.
 */
export const syncChatOnUserWrite = onDocumentWritten(
  { document: "users/{uid}", region: REGION, retry: true },
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
  { document: "parentLocations/{uid}", region: REGION, retry: false },
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
  { document: "carpools/{carpoolId}/members/{uid}", region: REGION, retry: true },
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
// New messages
// --------------------------------------------------------------------------

function limitOr(value: number, fallback: number, min: number, max: number): number {
  return Number.isInteger(value) && value >= min && value <= max ? value : fallback;
}

/**
 * A parent's phone wrote a message (firestore.rules let only a current
 * member do that). Limits, blocked terms, the chat list (last message,
 * unread counters) and the push through OUR sender: fanout.ts. Not
 * retried: a failed run costs one push or one counter, never a message.
 */
export const onChatMessageCreated = onDocumentCreated(
  { document: "chats/{cid}/messages/{messageId}", region: REGION, retry: false, maxInstances: 20 },
  async (event) => {
    const params = event.params as Record<string, string>;
    try {
      await onMessageCreated(
        {
          store: new FirestoreChatStore(adminDb()),
          data: chatData(),
          server: server(),
          limits: {
            messagesPerMinute: limitOr(CHAT_MESSAGES_PER_MINUTE.value(), 30, 1, 600),
            muteMinutes: limitOr(CHAT_MUTE_MINUTES.value(), 10, 1, 1440),
          },
          now: () => Date.now(),
          log,
        },
        params.cid,
        params.messageId,
        event.data?.data(),
      );
    } catch (error) {
      // Never the message: the error text of our own code and Firestore only.
      logger.error("chat message fan-out failed", { message: error instanceof Error ? error.message : "unknown" });
      await reportError(error);
    }
  },
);

// Chat retention is in retentionDaily (privacy/jobs.ts): a chat is kept for
// its life + 1 year (owner decision), then deleted with its messages and
// photos.
