import * as logger from "firebase-functions/logger";
import { HttpsError, onCall, type CallableRequest, type FunctionsErrorCode } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { adminDb } from "../admin";
import { ipOf, requireAdminCaller } from "../admin_panel/access";
import type { AdminCaller } from "../admin_panel/guard";
import { FirestoreListsStore } from "../admin_panel/store";
import { appEnv as configAppEnv, ENFORCE_APP_CHECK, MIN_INSTANCES_WALLET, WALLET_PARTNER_ENABLED, WALLET_PROVIDER } from "../config";
import { CAIRO_TZ } from "../schedule/cairo";
import { reportError } from "../sentry";
import {
  adminGetWallet as adminGetFlow,
  adminListTransfers as adminListFlow,
  adminListWalletAlerts as adminAlertsFlow,
  adminResolveWalletAlert as adminResolveFlow,
  adminSetWalletFrozen as adminFreezeFlow,
  type WalletAdminDeps,
} from "./admin";
import { fakeMode, FirestoreFakeLedger, FirestoreWalletStore } from "./firestore_store";
import {
  addMoney as addFlow,
  getTransfer as transferFlow,
  getWallet as getFlow,
  listHistory as historyFlow,
  lookupParent as lookupFlow,
  openWallet as openFlow,
  reconcileAll,
  syncPartnerFreezes,
  reportTransfer as reportFlow,
  sendTransfer as sendFlow,
  walletContacts as contactsFlow,
  withdraw as withdrawFlow,
  type Caller,
  type WalletDeps,
} from "./flow";
import { WALLET_ERROR_CODES, WalletError } from "./model";
import { createWalletProvider, FakeWalletProvider, walletConfigProblem, type WalletProvider } from "./provider";
import { noteAbuse } from "../privacy/abuse_hook";
import { featureGatedCall, featureSessionCall, requireFeature, skipWhenOff } from "../features/gate";

/**
 * Wallet functions (Prompt 11B: F43, F44). The ONLY place the wallet
 * partner is called from (through WalletProvider). Errors carry
 * details.reason for the app. Logs: kinds and IDs only.
 *
 * Pilot (owner decision 14 Nov 2026): the wallet is behind the "wallet"
 * feature switch (features/model.ts), off by default. While it is off
 * every callable here refuses with reason "feature-off" before anything
 * else, and walletReconcile does nothing.
 */

const appEnv = (): string => configAppEnv();

/** The provider, or null when the wallet is switched off here (the app says "not open yet"). */
export function walletProvider(): WalletProvider | null {
  const problem = walletConfigProblem(WALLET_PROVIDER.value(), appEnv());
  if (problem) {
    logger.error("wallet provider setting refused", { problem });
    return null;
  }
  try {
    return createWalletProvider({
      provider: WALLET_PROVIDER.value(),
      appEnv: appEnv(),
      partnerEnabled: WALLET_PARTNER_ENABLED.value(),
      fake: () => new FakeWalletProvider(new FirestoreFakeLedger(adminDb()), () => fakeMode(adminDb()), () => Date.now()),
    });
  } catch {
    return null;
  }
}

const log = (message: string, data?: Record<string, unknown>) => logger.info(message, data ?? {});

function deps(): WalletDeps {
  const lists = new FirestoreListsStore(adminDb());
  return { store: new FirestoreWalletStore(adminDb()), provider: walletProvider(), now: () => Date.now(), log, audit: (entry) => lists.audit(entry) };
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
    if (error instanceof WalletError) {
      throw new HttpsError(WALLET_ERROR_CODES[error.reason] as FunctionsErrorCode, error.reason, { reason: error.reason, ...error.details });
    }
    // Never the request data: it holds amounts, names and notes.
    logger.error(`${name} failed`, { message: error instanceof Error ? error.message : "unknown" });
    await reportError(error);
    throw new HttpsError("unavailable", "wallet-unavailable", { reason: "wallet-unavailable" });
  }
}

const opts = { enforceAppCheck: ENFORCE_APP_CHECK, minInstances: MIN_INSTANCES_WALLET, timeoutSeconds: 60 };

/** {} -> the wallet (balance from the partner) or { opened: false }. */
export const getWallet = featureGatedCall("wallet", opts, (r) =>
  run("getWallet", async () => {
    return getFlow(deps(), caller(r));
  }),
);

/** { acceptTerms } -> the wallet: opens it after the partner's terms (consent record). */
export const openWallet = featureGatedCall("wallet", opts, (r) => run("openWallet", () => openFlow(deps(), caller(r), r.data)));

/** { parentId } -> { firstName, verified } only. Rate limited. */
export const lookupParentId = featureGatedCall("wallet", opts, (r) =>
  run("lookupParentId", async () => {
    // Prompt 12: many lookups in an hour alert the admins (scraping).
    await noteAbuse(caller(r).uid, "parentIdLookups", abuseKey(r.data, "parentId"));
    return lookupFlow(deps(), caller(r), r.data);
  }),
);
/** Prompt 12: the scraping counter's target (hashed by noteActivity before it is stored). */
function abuseKey(data: unknown, ...fields: string[]): string {
  const raw = typeof data === "object" && data !== null ? (data as Record<string, unknown>) : {};
  return fields.map((f) => String(raw[f] ?? "")).join("|").slice(0, 64);
}


/** { carpoolId? } -> { contacts }: parents of my carpools. */
export const walletContacts = featureGatedCall("wallet", opts, (r) =>
  run("walletContacts", async () => {
    return contactsFlow(deps(), caller(r), r.data);
  }),
);

/** { requestId, amount, toParentId | toUid, note?, carpoolId? } -> { transfer } */
export const sendMoney = featureGatedCall("wallet", opts, (r) =>
  run("sendMoney", async () => {
    return sendFlow(deps(), caller(r), r.data);
  }),
);

/** { requestId, amount } -> { transfer, checkoutUrl } */
export const addMoney = featureGatedCall("wallet", opts, (r) =>
  run("addMoney", async () => {
    return addFlow(deps(), caller(r), r.data);
  }),
);

/** { requestId, amount } -> { transfer } */
export const withdrawMoney = featureGatedCall("wallet", opts, (r) =>
  run("withdrawMoney", async () => {
    return withdrawFlow(deps(), caller(r), r.data);
  }),
);

/** { afterId? } -> { transfers, nextAfterId } */
export const listWalletHistory = featureGatedCall("wallet", opts, (r) =>
  run("listWalletHistory", async () => {
    return historyFlow(deps(), caller(r), r.data);
  }),
);

/** { transferId } -> the transfer (a pending one is checked with the partner). */
export const getTransfer = featureGatedCall("wallet", opts, (r) =>
  run("getTransfer", async () => {
    return transferFlow(deps(), caller(r), r.data);
  }),
);

/** { transferId, reason, note? } -> { alertId, frozen } */
export const reportTransfer = featureSessionCall("wallet", opts, (r) => run("reportTransfer", () => reportFlow(deps(), caller(r), r.data)));

/**
 * Every 5 minutes: pending transfers are settled by asking the partner
 * (never by guessing), so a lost answer never leaves money unaccounted for;
 * freezes the partner missed are applied again.
 */
export const walletReconcile = onSchedule(
  { schedule: "every 5 minutes", timeZone: CAIRO_TZ, retryCount: 0, timeoutSeconds: 300, minInstances: 0 },
  async () => {
    if (await skipWhenOff("wallet", "walletReconcile")) return;
    const d = deps();
    if (!d.provider) return;
    try {
      const result = await reconcileAll(d);
      const frozen = await syncPartnerFreezes(d);
      if (result.checked > 0 || frozen > 0) logger.info("wallet reconcile", { ...result, partnerFreezes: frozen });
    } catch (error) {
      logger.error("wallet reconcile failed", { message: error instanceof Error ? error.message : "unknown" });
      await reportError(error);
    }
  },
);

// --------------------------------------------------------------------------
// Admin panel: read-only log, freeze, alerts. No money movement.
// --------------------------------------------------------------------------

function adminDeps(): WalletAdminDeps {
  const lists = new FirestoreListsStore(adminDb());
  return { store: new FirestoreWalletStore(adminDb()), provider: walletProvider(), now: () => Date.now(), audit: (entry) => lists.audit(entry) };
}

function adminCall<T>(name: string, body: (c: AdminCaller, r: CallableRequest) => Promise<T>) {
  return onCall({ enforceAppCheck: ENFORCE_APP_CHECK }, (r) =>
    run(name, async () => {
      await requireFeature("wallet");
      return body(await requireAdminCaller(r), r);
    }),
  );
}

/** { uid?, afterId? } -> { transfers, nextAfterId } */
export const adminListTransfers = adminCall("adminListTransfers", (c, r) => adminListFlow(adminDeps(), c, r.data, ipOf(r)));

/** { uid } -> the wallet, the partner's view and recent transfers. */
export const adminGetWallet = adminCall("adminGetWallet", (c, r) => adminGetFlow(adminDeps(), c, r.data, ipOf(r)));

/** { uid, frozen, reasonCode, note? } -> { status } */
export const adminSetWalletFrozen = adminCall("adminSetWalletFrozen", (c, r) => adminFreezeFlow(adminDeps(), c, r.data, ipOf(r)));

/** { status? } -> { alerts } */
export const adminListWalletAlerts = adminCall("adminListWalletAlerts", (c, r) => adminAlertsFlow(adminDeps(), c, r.data));

/** { alertId, outcome } -> the alert */
export const adminResolveWalletAlert = adminCall("adminResolveWalletAlert", (c, r) => adminResolveFlow(adminDeps(), c, r.data, ipOf(r)));
