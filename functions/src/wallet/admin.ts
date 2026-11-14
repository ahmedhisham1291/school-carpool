import type { AdminCaller } from "../admin_panel/guard";
import type { AuditEntry } from "../admin_panel/types";
import { newEvent } from "../notifications/model";
import {
  isFreezeReason,
  optionalUid,
  PARTNER_TIMEOUT_MS,
  record,
  transferIdField,
  uidField,
  WalletError,
  type AlertRecord,
  type FailReason,
  type FreezeReason,
  type TransferKind,
  type TransferRecord,
  type TransferStatus,
  type WalletStatus,
} from "./model";
import { withTimeout, type ProviderTx, type WalletProvider } from "./provider";
import type { WalletStore } from "./store";

/**
 * Wallet in the admin panel (F14, F43; spec section 7: "Admins can freeze
 * a wallet but cannot move money"). On purpose the admin flows get only the
 * partner's freeze, balance and transaction list: there is no path from
 * here to add, send or withdraw money. Every view and change is in the
 * audit log; notes on transfers are never shown in the log (they are the
 * parents' words).
 */

/** The only partner calls an admin can cause. */
export type AdminWalletPort = Pick<WalletProvider, "freeze" | "balance" | "listTransactions">;

export interface WalletAdminDeps {
  store: WalletStore;
  provider: AdminWalletPort | null;
  now: () => number;
  audit: (entry: AuditEntry) => Promise<void>;
}

export interface AdminTransferItem {
  id: string;
  kind: TransferKind;
  fromUid: string | null;
  toUid: string | null;
  fromFirstName: string;
  toFirstName: string;
  amount: number;
  carpoolId: string | null;
  status: TransferStatus;
  reason: FailReason | null;
  createdAtMs: number;
  settledAtMs: number | null;
}

async function items(store: WalletStore, list: TransferRecord[]): Promise<AdminTransferItem[]> {
  const results = await store.results(list.map((t) => t.id));
  return list.map((t) => {
    const r = results.get(t.id) ?? null;
    return {
      id: t.id,
      kind: t.kind,
      fromUid: t.fromUid,
      toUid: t.toUid,
      fromFirstName: t.fromFirstName,
      toFirstName: t.toFirstName,
      amount: t.amount,
      carpoolId: t.carpoolId,
      status: r?.status ?? "pending",
      reason: r?.reason ?? null,
      createdAtMs: t.createdAtMs,
      settledAtMs: r?.settledAtMs ?? null,
    };
  });
}

/** { uid?, afterId? } -> { transfers, nextAfterId }. Read only. Logged once per opening. */
export async function adminListTransfers(
  deps: WalletAdminDeps,
  caller: AdminCaller,
  data: unknown,
  ip: string | null,
): Promise<{ transfers: AdminTransferItem[]; nextAfterId: string | null }> {
  const raw = data === undefined || data === null ? {} : record(data);
  const uid = optionalUid(raw.uid);
  const afterId = raw.afterId === undefined || raw.afterId === null ? null : transferIdField(raw.afterId);
  if (afterId === null) await deps.audit({ actorUid: caller.uid, action: "wallet.transfers.view", target: uid ? `users/${uid}` : "transfers", ip });
  const limit = 50;
  const list = await deps.store.allTransfers(uid, limit, afterId);
  return { transfers: await items(deps.store, list), nextAfterId: list.length === limit ? list[list.length - 1].id : null };
}

export interface AdminWalletView {
  uid: string;
  opened: boolean;
  status: WalletStatus | "none";
  frozenReason: FreezeReason | null;
  frozenAtMs: number | null;
  /** From the partner; null when it did not answer (then [balanceCopy] is shown, marked as a copy). */
  balance: number | null;
  balanceCopy: number | null;
  partnerTransactions: ProviderTx[];
  transfers: AdminTransferItem[];
  alerts: AlertRecord[];
}

/** { uid } -> the parent's wallet as the partner and our records see it. Logged. */
export async function adminGetWallet(deps: WalletAdminDeps, caller: AdminCaller, data: unknown, ip: string | null): Promise<AdminWalletView> {
  const uid = uidField(record(data).uid);
  await deps.audit({ actorUid: caller.uid, action: "wallet.view", target: `users/${uid}`, ip });
  const w = await deps.store.wallet(uid);
  const transfers = await items(deps.store, await deps.store.allTransfers(uid, 20, null));
  const alerts = [...(await deps.store.alerts("open", 200))].filter((a) => a.uid === uid);
  let balance: number | null = null;
  let partnerTransactions: ProviderTx[] = [];
  if (w && deps.provider) {
    try {
      balance = await withTimeout(deps.provider.balance(w.walletRef), PARTNER_TIMEOUT_MS);
      partnerTransactions = await withTimeout(deps.provider.listTransactions(w.walletRef, 20), PARTNER_TIMEOUT_MS);
    } catch {
      // Shown as "partner did not answer"; the copy stays visible.
    }
  }
  return {
    uid,
    opened: w !== null,
    status: w?.status ?? "none",
    frozenReason: w?.frozenReason ?? null,
    frozenAtMs: w?.frozenAtMs ?? null,
    balance,
    balanceCopy: w?.balanceCopy ?? null,
    partnerTransactions,
    transfers,
    alerts,
  };
}

/**
 * { uid, frozen, reasonCode, note? } -> { status }. Freezes or unfreezes at
 * the partner AND on our side (our side first when freezing, so no money
 * leaves through us even if the partner is slow). The parent is told
 * (push and WhatsApp) without the reason. In the audit log with the reason code.
 */
export async function adminSetWalletFrozen(
  deps: WalletAdminDeps,
  caller: AdminCaller,
  data: unknown,
  ip: string | null,
): Promise<{ status: WalletStatus }> {
  const raw = record(data);
  const uid = uidField(raw.uid);
  if (typeof raw.frozen !== "boolean" || !isFreezeReason(raw.reasonCode)) throw new WalletError("invalid-request");
  const note = typeof raw.note === "string" ? raw.note.trim().slice(0, 300) : "";
  const frozen = raw.frozen;
  const w = await deps.store.wallet(uid);
  if (!w) throw new WalletError("no-wallet");
  const nowMs = deps.now();
  const audit = (): Promise<void> =>
    deps.audit({ actorUid: caller.uid, action: frozen ? "wallet.freeze" : "wallet.unfreeze", target: `users/${uid}`, reasonCode: raw.reasonCode as string, ip });
  if (frozen) {
    // Logged first; then our side: from now on no money leaves or arrives
    // through us, whatever the partner answers. walletReconcile retries the
    // partner until it has the freeze too.
    await audit();
    await deps.store.updateWallet(
      uid,
      { status: "frozen", frozenReason: raw.reasonCode, frozenAtMs: nowMs, frozenBy: caller.uid, partnerSynced: false, updatedAtMs: nowMs },
      note,
    );
    if (deps.provider) {
      try {
        await withTimeout(deps.provider.freeze(w.walletRef, true), PARTNER_TIMEOUT_MS);
        await deps.store.updateWallet(uid, { partnerSynced: true });
      } catch {
        // Retried by walletReconcile (syncPartnerFreezes).
      }
    }
  } else {
    // Unfreezing needs the partner's answer first.
    if (!deps.provider) throw new WalletError("wallet-off");
    try {
      await withTimeout(deps.provider.freeze(w.walletRef, false), PARTNER_TIMEOUT_MS);
    } catch {
      throw new WalletError("wallet-unavailable");
    }
    await audit();
    await deps.store.updateWallet(
      uid,
      { status: "active", frozenReason: null, frozenAtMs: null, frozenBy: null, partnerSynced: true, updatedAtMs: nowMs },
      note,
    );
  }
  await deps.store.addEvents([newEvent(`wallet_${frozen ? "frozen" : "unfrozen"}_${uid}_${nowMs}`, frozen ? "wallet-frozen" : "wallet-updated", [uid], nowMs)]);
  return { status: frozen ? "frozen" : "active" };
}

/** { status? } -> { alerts }: unusual patterns and transfer problem reports. */
export async function adminListWalletAlerts(deps: WalletAdminDeps, _caller: AdminCaller, data: unknown): Promise<{ alerts: AlertRecord[] }> {
  const raw = data === undefined || data === null ? {} : record(data);
  const status = raw.status ?? "open";
  if (status !== "open" && status !== "handled") throw new WalletError("invalid-request");
  return { alerts: await deps.store.alerts(status, 100) };
}

export const ALERT_OUTCOMES = ["noIssue", "frozen", "sentToPartner", "parentContacted", "settledWithPartner"] as const;

/** { alertId, outcome } -> the alert, closed. Logged. */
export async function adminResolveWalletAlert(deps: WalletAdminDeps, caller: AdminCaller, data: unknown, ip: string | null): Promise<AlertRecord> {
  const raw = record(data);
  const id = typeof raw.alertId === "string" && /^[A-Za-z0-9_-]{1,300}$/.test(raw.alertId) ? raw.alertId : null;
  if (!id || !(ALERT_OUTCOMES as readonly unknown[]).includes(raw.outcome)) throw new WalletError("invalid-request");
  const a = await deps.store.alert(id);
  if (!a) throw new WalletError("not-found");
  const closed: AlertRecord = { ...a, status: "handled", outcome: raw.outcome as string, handledBy: caller.uid, handledAtMs: deps.now() };
  // Logged first: a change is never unlogged.
  await deps.audit({ actorUid: caller.uid, action: "wallet.alert.resolve", target: `walletAlerts/${id}`, reasonCode: raw.outcome as string, ip, details: { kind: a.kind } });
  await deps.store.putAlert(closed);
  return closed;
}
