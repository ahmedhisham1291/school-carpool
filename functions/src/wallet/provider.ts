import { randomUUID } from "node:crypto";
import type { FailReason, TransferKind } from "./model";

/**
 * The ONE door to the wallet partner (CLAUDE.md STACK: "a payment partner
 * licensed by the Central Bank of Egypt behind one interface"). Nothing
 * else in the app or in Cloud Functions talks to the partner: the flows in
 * flow.ts and admin.ts get a WalletProvider and nothing more.
 *
 * Two implementations:
 * - FakeWalletProvider: test money kept in a ledger (Firestore
 *   fakeWalletLedger/* in dev and staging, memory in unit tests). Refused in
 *   prod. Its "mode" (config/walletFake) can make it time out or go down, so
 *   the pending and reconciliation paths can be tried on a phone.
 * - PartnerWalletProvider: the stub for the licensed partner. Until the
 *   contract is signed and WALLET_PARTNER_ENABLED is true it refuses every
 *   call (fails closed): no money can move by accident.
 *
 * Amounts are whole piastres. Every money call carries our transfer ID as
 * the partner's idempotency key: the same ID never moves money twice.
 * The partner gets opaque references only (our uid as the customer
 * reference), never notes, phone numbers or names beyond what its own
 * identity check needs (open question for the contract).
 */

export interface ProviderOp {
  /** done: money moved; failed: it did not; pending: the partner is still working (or waits for the parent, for example a card page). */
  status: "done" | "failed" | "pending";
  partnerRef: string | null;
  reason: FailReason | null;
  /** Top-up only: the partner's page where the parent pays (real partner). */
  checkoutUrl: string | null;
}

export interface ProviderTx {
  requestId: string;
  kind: TransferKind;
  /** Positive: money in; negative: money out. */
  signedAmount: number;
  status: ProviderOp["status"];
  atMs: number;
}

export type ProviderErrorKind = "timeout" | "unavailable" | "not-configured" | "declined";

/**
 * A call that failed. `timeout` and `unavailable` mean the outcome of a
 * money call is UNKNOWN: the transfer stays pending and is reconciled by
 * asking the partner (findOperation) before anything is tried again.
 */
export class WalletProviderError extends Error {
  constructor(readonly kind: ProviderErrorKind) {
    super(`wallet provider: ${kind}`);
    this.name = "WalletProviderError";
  }

  get outcomeUnknown(): boolean {
    return this.kind === "timeout" || this.kind === "unavailable";
  }
}

export interface WalletProvider {
  readonly kind: "fake" | "partner";
  /** Opens the parent's wallet; idempotent per customer reference. */
  openWallet(input: { customerRef: string; requestId: string }): Promise<{ walletRef: string }>;
  /** The available balance, in piastres. */
  balance(walletRef: string): Promise<number>;
  addMoney(input: { walletRef: string; amount: number; requestId: string }): Promise<ProviderOp>;
  send(input: { fromRef: string; toRef: string; amount: number; requestId: string }): Promise<ProviderOp>;
  withdraw(input: { walletRef: string; amount: number; requestId: string }): Promise<ProviderOp>;
  /** The partner's record of a money call by our request ID, or null when it never arrived. */
  findOperation(requestId: string): Promise<ProviderOp | null>;
  listTransactions(walletRef: string, limit: number): Promise<ProviderTx[]>;
  /** A frozen wallet can neither pay nor be paid at the partner either. */
  freeze(walletRef: string, frozen: boolean): Promise<void>;
}

// --------------------------------------------------------------------------
// Fake provider (test money)
// --------------------------------------------------------------------------

export interface FakeAccount {
  walletRef: string;
  customerRef: string;
  balance: number;
  frozen: boolean;
}

export interface FakeOp {
  requestId: string;
  kind: TransferKind;
  fromRef: string | null;
  toRef: string | null;
  amount: number;
  status: "done" | "failed";
  reason: FailReason | null;
  partnerRef: string;
  atMs: number;
}

/** What the fake partner keeps. Each `apply` runs in one transaction. */
export interface FakeLedger {
  account(walletRef: string): Promise<FakeAccount | null>;
  accountOfCustomer(customerRef: string): Promise<FakeAccount | null>;
  op(requestId: string): Promise<FakeOp | null>;
  opsOf(walletRef: string, limit: number): Promise<FakeOp[]>;
  /**
   * Reads the accounts named in [refs] and the op [requestId], lets
   * [change] decide, and saves the accounts and op it returns, atomically.
   */
  apply(
    requestId: string,
    refs: string[],
    change: (accounts: Map<string, FakeAccount>, existing: FakeOp | null) => { accounts: FakeAccount[]; op: FakeOp | null },
  ): Promise<FakeOp | null>;
  putAccount(a: FakeAccount): Promise<void>;
}

/**
 * ok: everything works. timeout: money calls DO move the money but answer
 * with a timeout (the "unknown outcome" case). lost: money calls time out
 * and never arrive at the partner. down: every call fails as unavailable.
 */
export type FakeMode = "ok" | "timeout" | "lost" | "down";

/** Test money every new fake wallet starts with: 0 (add money first, as on the real partner). */
export const FAKE_START_BALANCE = 0;

export class FakeWalletProvider implements WalletProvider {
  readonly kind = "fake";

  constructor(
    private readonly ledger: FakeLedger,
    private readonly mode: () => Promise<FakeMode>,
    private readonly now: () => number,
    private readonly newRef: () => string = () => randomUUID(),
  ) {}

  private async guard(): Promise<FakeMode> {
    const mode = await this.mode();
    if (mode === "down") throw new WalletProviderError("unavailable");
    return mode;
  }

  /** Runs a money call through the mode: "timeout" applies it then throws; "lost" throws first. */
  private async money(run: () => Promise<FakeOp | null>): Promise<ProviderOp> {
    const mode = await this.guard();
    if (mode === "lost") throw new WalletProviderError("timeout");
    const op = await run();
    if (mode === "timeout") throw new WalletProviderError("timeout");
    return toProviderOp(op);
  }

  async openWallet(input: { customerRef: string; requestId: string }): Promise<{ walletRef: string }> {
    await this.guard();
    const existing = await this.ledger.accountOfCustomer(input.customerRef);
    if (existing) return { walletRef: existing.walletRef };
    const walletRef = `fw_${this.newRef()}`;
    await this.ledger.putAccount({ walletRef, customerRef: input.customerRef, balance: FAKE_START_BALANCE, frozen: false });
    return { walletRef };
  }

  async balance(walletRef: string): Promise<number> {
    await this.guard();
    const a = await this.ledger.account(walletRef);
    if (!a) throw new WalletProviderError("declined");
    return a.balance;
  }

  private op(base: Omit<FakeOp, "partnerRef" | "atMs">): FakeOp {
    return { ...base, partnerRef: `fp_${this.newRef()}`, atMs: this.now() };
  }

  addMoney(input: { walletRef: string; amount: number; requestId: string }): Promise<ProviderOp> {
    return this.money(() =>
      this.ledger.apply(input.requestId, [input.walletRef], (accounts, existing) => {
        if (existing) return { accounts: [], op: existing };
        const a = accounts.get(input.walletRef);
        const base = { requestId: input.requestId, kind: "topup" as const, fromRef: null, toRef: input.walletRef, amount: input.amount };
        if (!a || a.frozen) return { accounts: [], op: this.op({ ...base, status: "failed", reason: "sender-frozen" }) };
        return { accounts: [{ ...a, balance: a.balance + input.amount }], op: this.op({ ...base, status: "done", reason: null }) };
      }),
    );
  }

  send(input: { fromRef: string; toRef: string; amount: number; requestId: string }): Promise<ProviderOp> {
    return this.money(() =>
      this.ledger.apply(input.requestId, [input.fromRef, input.toRef], (accounts, existing) => {
        if (existing) return { accounts: [], op: existing };
        const from = accounts.get(input.fromRef);
        const to = accounts.get(input.toRef);
        const base = { requestId: input.requestId, kind: "transfer" as const, fromRef: input.fromRef, toRef: input.toRef, amount: input.amount };
        const fail = (reason: FailReason) => ({ accounts: [], op: this.op({ ...base, status: "failed", reason }) });
        if (!from || from.frozen) return fail("sender-frozen");
        if (!to || to.frozen) return fail("receiver-frozen");
        if (from.balance < input.amount) return fail("insufficient-funds");
        return {
          accounts: [
            { ...from, balance: from.balance - input.amount },
            { ...to, balance: to.balance + input.amount },
          ],
          op: this.op({ ...base, status: "done", reason: null }),
        };
      }),
    );
  }

  withdraw(input: { walletRef: string; amount: number; requestId: string }): Promise<ProviderOp> {
    return this.money(() =>
      this.ledger.apply(input.requestId, [input.walletRef], (accounts, existing) => {
        if (existing) return { accounts: [], op: existing };
        const a = accounts.get(input.walletRef);
        const base = { requestId: input.requestId, kind: "withdraw" as const, fromRef: input.walletRef, toRef: null, amount: input.amount };
        if (!a || a.frozen) return { accounts: [], op: this.op({ ...base, status: "failed", reason: "sender-frozen" }) };
        if (a.balance < input.amount) return { accounts: [], op: this.op({ ...base, status: "failed", reason: "insufficient-funds" }) };
        return { accounts: [{ ...a, balance: a.balance - input.amount }], op: this.op({ ...base, status: "done", reason: null }) };
      }),
    );
  }

  async findOperation(requestId: string): Promise<ProviderOp | null> {
    await this.guard();
    const op = await this.ledger.op(requestId);
    return op ? toProviderOp(op) : null;
  }

  async listTransactions(walletRef: string, limit: number): Promise<ProviderTx[]> {
    await this.guard();
    const ops = await this.ledger.opsOf(walletRef, limit);
    return ops.map((o) => ({
      requestId: o.requestId,
      kind: o.kind,
      signedAmount: o.toRef === walletRef ? o.amount : -o.amount,
      status: o.status,
      atMs: o.atMs,
    }));
  }

  async freeze(walletRef: string, frozen: boolean): Promise<void> {
    await this.guard();
    const a = await this.ledger.account(walletRef);
    if (!a) throw new WalletProviderError("declined");
    await this.ledger.putAccount({ ...a, frozen });
  }
}

function toProviderOp(op: FakeOp | null): ProviderOp {
  if (!op) return { status: "failed", partnerRef: null, reason: "partner-error", checkoutUrl: null };
  return { status: op.status, partnerRef: op.partnerRef, reason: op.reason, checkoutUrl: null };
}

// --------------------------------------------------------------------------
// The licensed partner (stub until the contract)
// --------------------------------------------------------------------------

/**
 * Placeholder for the CBE-licensed partner's API. The partner is not chosen
 * yet (spec section 13); its API, authentication and webhooks come with the
 * contract. Every call fails closed with "not-configured", so turning the
 * provider on by mistake cannot move money and the app shows "The wallet is
 * not open yet".
 */
export class PartnerWalletProvider implements WalletProvider {
  readonly kind = "partner";

  private refuse(): never {
    throw new WalletProviderError("not-configured");
  }

  async openWallet(): Promise<{ walletRef: string }> {
    return this.refuse();
  }
  async balance(): Promise<number> {
    return this.refuse();
  }
  async addMoney(): Promise<ProviderOp> {
    return this.refuse();
  }
  async send(): Promise<ProviderOp> {
    return this.refuse();
  }
  async withdraw(): Promise<ProviderOp> {
    return this.refuse();
  }
  async findOperation(): Promise<ProviderOp | null> {
    return this.refuse();
  }
  async listTransactions(): Promise<ProviderTx[]> {
    return this.refuse();
  }
  async freeze(): Promise<void> {
    return this.refuse();
  }
}

export interface WalletProviderOptions {
  provider: string;
  appEnv: string;
  partnerEnabled: boolean;
  fake: () => FakeWalletProvider;
}

/** A setting that would break the money rules, or null (checked at start and on every call). */
export function walletConfigProblem(provider: string, appEnv: string): string | null {
  if (provider !== "fake" && provider !== "partner") return `WALLET_PROVIDER "${provider}" is unknown (use fake or partner).`;
  if (provider === "fake" && appEnv === "prod") return "WALLET_PROVIDER=fake is not allowed in prod.";
  return null;
}

/**
 * The provider for this environment. The fake is refused in prod (test
 * money must never mix with real money); the partner is refused unless it
 * was switched on after the contract.
 */
export function createWalletProvider(o: WalletProviderOptions): WalletProvider {
  if (walletConfigProblem(o.provider, o.appEnv)) throw new WalletProviderError("not-configured");
  if (o.provider === "fake") return o.fake();
  if (!o.partnerEnabled) throw new WalletProviderError("not-configured");
  return new PartnerWalletProvider();
}

/** Runs a partner call with a time limit; past it the outcome counts as unknown. */
export async function withTimeout<T>(call: Promise<T>, ms: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const limit = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new WalletProviderError("timeout")), ms);
  });
  try {
    return await Promise.race([call, limit]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}
