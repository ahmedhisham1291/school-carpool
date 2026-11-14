import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { TEXTS } from "../src/notifications/texts";
import { deleteAccount, DeletionError, type DeletionRunner, type WalletLock } from "../src/privacy/account_deletion";
import { TYPES } from "../src/notifications/catalog";
import * as walletAdmin from "../src/wallet/admin";
import { adminGetWallet, adminListTransfers, adminResolveWalletAlert, adminSetWalletFrozen, type WalletAdminDeps } from "../src/wallet/admin";
import {
  addMoney,
  detectPatterns,
  getTransfer,
  getWallet,
  listHistory,
  lookupParent,
  openWallet,
  reconcile,
  reconcileAll,
  settleStuckTransfer,
  reportTransfer,
  syncPartnerFreezes,
  sendTransfer,
  walletContacts,
  withdraw,
  type Caller,
  type WalletDeps,
} from "../src/wallet/flow";
import {
  amountField,
  cairoDay,
  cleanNote,
  DEFAULT_WALLET_LIMITS,
  formatPiastres,
  GIVE_UP_AFTER_MS,
  limitsFrom,
  normalizeParentId,
  transferId,
  WALLET_TERMS_VERSION,
  WalletError,
  type TransferRecord,
} from "../src/wallet/model";
import { createWalletProvider, FakeWalletProvider, PartnerWalletProvider, walletConfigProblem, WalletProviderError, type FakeMode, type WalletProvider } from "../src/wallet/provider";
import { MemoryLedger, MemoryWalletStore } from "./helpers/memory_wallet";

// Fake data only. Times: Monday 16 Nov 2026, 10:00 Cairo (08:00 UTC).
const T0 = Date.UTC(2026, 10, 16, 8);

interface World {
  store: MemoryWalletStore;
  ledger: MemoryLedger;
  provider: FakeWalletProvider;
  deps: WalletDeps;
  clock: { now: number };
  mode: { value: FakeMode };
  logs: Array<{ message: string; data?: Record<string, unknown> }>;
}

function world(): World {
  const store = new MemoryWalletStore();
  const ledger = new MemoryLedger();
  const clock = { now: T0 };
  const mode = { value: "ok" as FakeMode };
  let n = 0;
  const provider = new FakeWalletProvider(ledger, async () => mode.value, () => clock.now, () => `r${++n}`);
  const logs: World["logs"] = [];
  const deps: WalletDeps = { store, provider, now: () => clock.now, log: (message, data) => logs.push({ message, data }), timeoutMs: 1000 };
  return { store, ledger, provider, deps, clock, mode, logs };
}

const me: Caller = { uid: "ali", verifiedClaim: true };
const hoda: Caller = { uid: "hoda", verifiedClaim: true };

/** Two verified parents with open wallets; Ali has 500 EGP of test money. */
async function twoParents(w: World, money = 50_000): Promise<void> {
  w.store.addParent("ali", "ALYZ2345", { firstName: "Ali" });
  w.store.addParent("hoda", "HUDA2345", { firstName: "Hoda" });
  await openWallet(w.deps, me, { acceptTerms: WALLET_TERMS_VERSION });
  await openWallet(w.deps, hoda, { acceptTerms: WALLET_TERMS_VERSION });
  if (money > 0) await addMoney(w.deps, me, { requestId: "topup-0000000000001", amount: money });
}

async function refuses(p: Promise<unknown>, reason: string): Promise<void> {
  await assert.rejects(p, (e: unknown) => e instanceof WalletError && e.reason === reason);
}

const balanceOf = async (w: World, uid: string) => (await getWallet(w.deps, { uid, verifiedClaim: true })).balance;

describe("wallet model", () => {
  it("amounts are whole piastres: floats, strings, zero and negatives are refused", () => {
    assert.equal(amountField(1250), 1250);
    for (const bad of [12.5, 0.1 + 0.2, "1250", 0, -100, Number.NaN, Infinity, 2 ** 60, null]) {
      assert.throws(() => amountField(bad), WalletError, String(bad));
    }
  });

  it("formats piastres without floating point", () => {
    assert.equal(formatPiastres(1250), "12.50");
    assert.equal(formatPiastres(5), "0.05");
    assert.equal(formatPiastres(100_000_00), "100000.00");
  });

  it("parent IDs: normalized, confusable letters refused", () => {
    assert.equal(normalizeParentId(" ab cd-2345 "), "ABCD2345");
    for (const bad of ["ABCD0345", "ABCDO345", "ABCD1345", "ABCDI345", "ABC", 12345678, null]) assert.equal(normalizeParentId(bad), null);
  });

  it("notes: one line, no bidi or control characters, cut to 80", () => {
    assert.equal(cleanNote("  week\n‮one  "), "week one");
    assert.equal([...cleanNote("x".repeat(200))].length, 80);
    assert.throws(() => cleanNote(5), WalletError);
  });

  it("the transfer ID follows the parent and the request ID", () => {
    assert.equal(transferId("ali", "req-0000000000000001"), transferId("ali", "req-0000000000000001"));
    assert.notEqual(transferId("ali", "req-0000000000000001"), transferId("hoda", "req-0000000000000001"));
    assert.match(transferId("ali", "x"), /^t_[a-f0-9]{40}$/);
  });

  it("daily limits follow the Cairo day", () => {
    assert.equal(cairoDay(Date.UTC(2026, 10, 16, 21, 30)), "2026-11-16");
    assert.equal(cairoDay(Date.UTC(2026, 10, 16, 22, 30)), "2026-11-17");
  });

  it("server settings: odd or too-high values fall back to the defaults", () => {
    const l = limitsFrom({ perTransferMax: 1_000, perDayMax: "big", topUpMax: 99_999_999_999, minAmount: 5_000 });
    assert.equal(l.perTransferMax, 1_000);
    assert.equal(l.perDayMax, DEFAULT_WALLET_LIMITS.perDayMax);
    assert.equal(l.topUpMax, DEFAULT_WALLET_LIMITS.topUpMax);
    assert.equal(l.minAmount, DEFAULT_WALLET_LIMITS.minAmount, "min above the max is ignored");
  });
});

describe("provider", () => {
  it("the fake is refused in prod; the partner fails closed until switched on", async () => {
    const fake = () => new FakeWalletProvider(new MemoryLedger(), async () => "ok", () => T0);
    assert.equal(createWalletProvider({ provider: "fake", appEnv: "dev", partnerEnabled: false, fake }).kind, "fake");
    assert.throws(() => createWalletProvider({ provider: "fake", appEnv: "prod", partnerEnabled: false, fake }), WalletProviderError);
    assert.throws(() => createWalletProvider({ provider: "partner", appEnv: "prod", partnerEnabled: false, fake }), WalletProviderError);
    assert.throws(() => createWalletProvider({ provider: "paypal", appEnv: "dev", partnerEnabled: true, fake }), WalletProviderError);
    assert.match(walletConfigProblem("fake", "prod") ?? "", /not allowed/);
    const partner = new PartnerWalletProvider();
    await assert.rejects(partner.send(), (e: unknown) => e instanceof WalletProviderError && e.kind === "not-configured");
    await assert.rejects(partner.balance(), WalletProviderError);
  });

  it("the fake partner moves a request ID once", async () => {
    const ledger = new MemoryLedger();
    const p = new FakeWalletProvider(ledger, async () => "ok", () => T0);
    const a = await p.openWallet({ customerRef: "a", requestId: "o1" });
    const b = await p.openWallet({ customerRef: "b", requestId: "o2" });
    await p.addMoney({ walletRef: a.walletRef, amount: 1000, requestId: "t1" });
    await p.send({ fromRef: a.walletRef, toRef: b.walletRef, amount: 400, requestId: "s1" });
    await p.send({ fromRef: a.walletRef, toRef: b.walletRef, amount: 400, requestId: "s1" });
    assert.equal(await p.balance(a.walletRef), 600);
    assert.equal(await p.balance(b.walletRef), 400);
    assert.equal((await p.openWallet({ customerRef: "a", requestId: "o3" })).walletRef, a.walletRef);
  });
});

describe("opening the wallet", () => {
  it("only after verification and the partner's terms; the consent is recorded", async () => {
    const w = world();
    w.store.addParent("ali", "ALYZ2345");
    w.store.addParent("newbie", "NEWB2345", { status: "pending" });
    const before = await getWallet(w.deps, me);
    assert.equal(before.opened, false);
    assert.equal(before.available, true);
    await refuses(openWallet(w.deps, me, {}), "terms-required");
    await refuses(openWallet(w.deps, me, { acceptTerms: "2020-01-01" }), "terms-required");
    await refuses(openWallet(w.deps, { uid: "newbie", verifiedClaim: false }, { acceptTerms: WALLET_TERMS_VERSION }), "not-verified");
    await refuses(openWallet(w.deps, { uid: "newbie", verifiedClaim: true }, { acceptTerms: WALLET_TERMS_VERSION }), "not-verified");
    const opened = await openWallet(w.deps, me, { acceptTerms: WALLET_TERMS_VERSION });
    assert.equal(opened.opened, true);
    assert.equal(opened.balance, 0);
    assert.deepEqual(w.store.consents.map((c) => [c.uid, c.type, c.version]), [["ali", "walletTerms", WALLET_TERMS_VERSION]]);
    await openWallet(w.deps, me, { acceptTerms: WALLET_TERMS_VERSION });
    assert.equal(w.store.consents.length, 1, "opening twice keeps one wallet and one consent");
  });

  it("suspended and banned parents are refused", async () => {
    const w = world();
    w.store.addParent("ali", "ALYZ2345", { status: "suspended" });
    await refuses(getWallet(w.deps, me), "suspended");
    w.store.addParent("ali", "ALYZ2345", { banned: true });
    await refuses(getWallet(w.deps, me), "suspended");
  });

  it("switched off (no provider): the app is told, nothing opens", async () => {
    const w = world();
    w.store.addParent("ali", "ALYZ2345");
    const off: WalletDeps = { ...w.deps, provider: null };
    assert.equal((await getWallet(off, me)).available, false);
    await refuses(openWallet(off, me, { acceptTerms: WALLET_TERMS_VERSION }), "wallet-off");
  });

  it("the balance always comes from the partner; a partner outage is an error, never a stale copy", async () => {
    const w = world();
    await twoParents(w);
    assert.equal(await balanceOf(w, "ali"), 50_000);
    // The copy is changed behind our back: the partner still wins.
    await w.store.updateWallet("ali", { balanceCopy: 1 });
    assert.equal(await balanceOf(w, "ali"), 50_000);
    w.mode.value = "down";
    await refuses(getWallet(w.deps, me), "wallet-unavailable");
  });
});

describe("parent ID lookup", () => {
  it("returns the first name and the badge only", async () => {
    const w = world();
    await twoParents(w, 0);
    const r = await lookupParent(w.deps, me, { parentId: "huda-2345" });
    assert.deepEqual(r, { firstName: "Hoda", verified: true });
    await refuses(lookupParent(w.deps, me, { parentId: "ALYZ2345" }), "self");
    await refuses(lookupParent(w.deps, me, { parentId: "ZZZZ2345" }), "receiver-not-found");
    await refuses(lookupParent(w.deps, me, { parentId: "bad" }), "receiver-not-found");
    // Suspended or banned: not shown at all (no first name).
    w.store.accounts.set("hoda", { ...w.store.accounts.get("hoda")!, status: "suspended" });
    await refuses(lookupParent(w.deps, me, { parentId: "HUDA2345" }), "receiver-not-found");
    w.store.accounts.set("hoda", { ...w.store.accounts.get("hoda")!, status: "verified", banned: true });
    await refuses(lookupParent(w.deps, me, { parentId: "HUDA2345" }), "receiver-not-found");
  });

  it("is rate limited before anything is looked up, so IDs cannot be guessed in bulk", async () => {
    const w = world();
    await twoParents(w, 0);
    w.store.config.lookupsPerHour = 3;
    for (let i = 0; i < 3; i++) await refuses(lookupParent(w.deps, me, { parentId: `ZZZ${i + 2}2345` }), "receiver-not-found");
    await refuses(lookupParent(w.deps, me, { parentId: "HUDA2345" }), "rate-limited");
    w.clock.now += 3_600_000;
    assert.equal((await lookupParent(w.deps, me, { parentId: "HUDA2345" })).firstName, "Hoda");
  });
});

describe("sending", () => {
  it("by parent ID: both histories match and the balances move once", async () => {
    const w = world();
    await twoParents(w);
    const r = await sendTransfer(w.deps, me, { requestId: "send-000000000000001", amount: 12_550, toParentId: "HUDA2345", note: "Week 1" });
    assert.equal(r.transfer.status, "done");
    assert.equal(r.transfer.otherName, "Hoda");
    assert.equal(await balanceOf(w, "ali"), 50_000 - 12_550);
    assert.equal(await balanceOf(w, "hoda"), 12_550);
    const mine = (await listHistory(w.deps, me, {})).transfers.find((t) => t.kind === "transfer");
    const hers = (await listHistory(w.deps, hoda, {})).transfers;
    assert.equal(hers.length, 1);
    assert.equal(mine?.id, hers[0].id);
    assert.deepEqual([mine?.direction, hers[0].direction], ["out", "in"]);
    assert.deepEqual([mine?.amount, hers[0].amount], [12_550, 12_550]);
    assert.deepEqual([mine?.otherName, hers[0].otherName], ["Hoda", "Ali"]);
    assert.equal(hers[0].note, "Week 1");
    assert.equal(hers[0].status, "done");
  });

  it("from a carpool (contribution): only members of that carpool", async () => {
    const w = world();
    await twoParents(w);
    w.store.addParent("sami", "SAMY2345", { firstName: "Sami" });
    await openWallet(w.deps, { uid: "sami", verifiedClaim: true }, { acceptTerms: WALLET_TERMS_VERSION });
    w.store.link("ali", "hoda", "k1", "hoda");
    const contacts = (await walletContacts(w.deps, me, { carpoolId: "k1" })).contacts;
    assert.deepEqual(contacts.map((c) => [c.uid, c.firstName, c.isAdmin]), [["hoda", "Hoda", true]]);
    const r = await sendTransfer(w.deps, me, { requestId: "send-000000000000002", amount: 30_000, toUid: "hoda", carpoolId: "k1" });
    assert.equal(r.transfer.status, "done");
    assert.equal(r.transfer.carpoolId, "k1");
    // A uid outside my carpools, or a carpool we do not share, is refused.
    await refuses(sendTransfer(w.deps, me, { requestId: "send-000000000000003", amount: 100, toUid: "sami" }), "not-in-carpool");
    await refuses(sendTransfer(w.deps, me, { requestId: "send-000000000000004", amount: 100, toUid: "hoda", carpoolId: "k9" }), "not-in-carpool");
    await refuses(sendTransfer(w.deps, me, { requestId: "send-000000000000005", amount: 100, toParentId: "SAMY2345", carpoolId: "k1" }), "not-in-carpool");
  });

  it("a double tap or a retry with the same request ID sends once", async () => {
    const w = world();
    await twoParents(w);
    const body = { requestId: "send-000000000000010", amount: 1_000, toParentId: "HUDA2345" };
    const [a, b] = await Promise.all([sendTransfer(w.deps, me, body), sendTransfer(w.deps, me, body)]);
    const c = await sendTransfer(w.deps, me, body);
    assert.equal(a.transfer.id, b.transfer.id);
    assert.equal(a.transfer.id, c.transfer.id);
    assert.equal(await balanceOf(w, "hoda"), 1_000);
    assert.equal([...w.store.transfers.values()].filter((t) => t.kind === "transfer").length, 1);
    // The same request ID with another amount, receiver or note is refused,
    // never answered with the earlier transfer.
    await refuses(sendTransfer(w.deps, me, { ...body, amount: 2_000 }), "request-reused");
    w.store.addParent("sami", "SAMY2345", { firstName: "Sami" });
    await openWallet(w.deps, { uid: "sami", verifiedClaim: true }, { acceptTerms: WALLET_TERMS_VERSION });
    await refuses(sendTransfer(w.deps, me, { ...body, toParentId: "SAMY2345" }), "request-reused");
    await refuses(sendTransfer(w.deps, me, { ...body, note: "other" }), "request-reused");
    await refuses(withdraw(w.deps, me, { requestId: body.requestId, amount: 1_000 }), "request-reused");
  });

  it("a freeze that lands between the checks and the transaction still stops the transfer", async () => {
    const w = world();
    await twoParents(w);
    w.store.beforeStart = () => void w.store.wallets.set("ali", { ...w.store.wallets.get("ali")!, status: "frozen" });
    await refuses(sendTransfer(w.deps, me, { requestId: "race-000000000000001", amount: 1_000, toParentId: "HUDA2345" }), "frozen");
    w.store.beforeStart = () => void w.store.wallets.set("hoda", { ...w.store.wallets.get("hoda")!, status: "frozen" });
    w.store.wallets.set("ali", { ...w.store.wallets.get("ali")!, status: "active" });
    await refuses(sendTransfer(w.deps, me, { requestId: "race-000000000000002", amount: 1_000, toParentId: "HUDA2345" }), "receiver-cannot-receive");
    assert.equal([...w.store.transfers.values()].filter((t) => t.kind === "transfer").length, 0);
    assert.equal(await w.provider.findOperation(transferId("ali", "race-000000000000002")), null);
  });

  it("a failed transfer is shown to the sender only", async () => {
    const w = world();
    await twoParents(w, 1_000);
    const r = await sendTransfer(w.deps, me, { requestId: "hid-0000000000000001", amount: 5_000, toParentId: "HUDA2345" });
    assert.equal(r.transfer.status, "failed");
    assert.equal((await listHistory(w.deps, me, {})).transfers.some((t) => t.id === r.transfer.id), true);
    assert.equal((await listHistory(w.deps, hoda, {})).transfers.length, 0);
  });

  it("limits per transfer and per day come from the server settings", async () => {
    const w = world();
    await twoParents(w, 400_000);
    w.store.config = { ...w.store.config, perTransferMax: 100_000, perDayMax: 150_000, perDayCount: 3, minAmount: 500 };
    await refuses(sendTransfer(w.deps, me, { requestId: "lim-0000000000000001", amount: 100_001, toParentId: "HUDA2345" }), "over-transfer-limit");
    await refuses(sendTransfer(w.deps, me, { requestId: "lim-0000000000000002", amount: 499, toParentId: "HUDA2345" }), "amount-too-small");
    await sendTransfer(w.deps, me, { requestId: "lim-0000000000000003", amount: 100_000, toParentId: "HUDA2345" });
    await assert.rejects(
      sendTransfer(w.deps, me, { requestId: "lim-0000000000000004", amount: 60_000, toParentId: "HUDA2345" }),
      (e: unknown) => e instanceof WalletError && e.reason === "over-daily-limit" && e.details.left === 50_000,
    );
    await sendTransfer(w.deps, me, { requestId: "lim-0000000000000005", amount: 1_000, toParentId: "HUDA2345" });
    await sendTransfer(w.deps, me, { requestId: "lim-0000000000000006", amount: 1_000, toParentId: "HUDA2345" });
    await refuses(sendTransfer(w.deps, me, { requestId: "lim-0000000000000007", amount: 1_000, toParentId: "HUDA2345" }), "too-many-today");
    // Withdrawals count in the same day.
    await refuses(withdraw(w.deps, me, { requestId: "lim-0000000000000008", amount: 1_000 }), "too-many-today");
    // Next Cairo day: allowed again.
    w.clock.now += 24 * 3_600_000;
    assert.equal((await sendTransfer(w.deps, me, { requestId: "lim-0000000000000009", amount: 1_000, toParentId: "HUDA2345" })).transfer.status, "done");
    assert.equal(await balanceOf(w, "hoda"), 103_000);
  });

  it("a failed transfer gives its amount back to the day and moves no money", async () => {
    const w = world();
    await twoParents(w, 1_000);
    w.store.config.perDayMax = 5_000;
    const r = await sendTransfer(w.deps, me, { requestId: "fail-000000000000001", amount: 4_000, toParentId: "HUDA2345" });
    assert.equal(r.transfer.status, "failed");
    assert.equal(r.transfer.reason, "insufficient-funds");
    assert.equal(await balanceOf(w, "ali"), 1_000);
    assert.equal(await balanceOf(w, "hoda"), 0);
    // The 4,000 did not use up the day.
    await addMoney(w.deps, me, { requestId: "topup-0000000000002", amount: 10_000 });
    assert.equal((await sendTransfer(w.deps, me, { requestId: "fail-000000000000002", amount: 5_000, toParentId: "HUDA2345" })).transfer.status, "done");
  });

  it("a frozen wallet cannot send, and a frozen receiver cannot be paid", async () => {
    const w = world();
    await twoParents(w);
    await w.store.updateWallet("ali", { status: "frozen" });
    await refuses(sendTransfer(w.deps, me, { requestId: "frz-0000000000000001", amount: 1_000, toParentId: "HUDA2345" }), "frozen");
    await refuses(withdraw(w.deps, me, { requestId: "frz-0000000000000002", amount: 1_000 }), "frozen");
    await w.store.updateWallet("ali", { status: "active" });
    await w.store.updateWallet("hoda", { status: "frozen" });
    await refuses(sendTransfer(w.deps, me, { requestId: "frz-0000000000000003", amount: 1_000, toParentId: "HUDA2345" }), "receiver-cannot-receive");
    assert.equal(await balanceOf(w, "ali"), 50_000);
  });

  it("both parents must be verified and not suspended", async () => {
    const w = world();
    await twoParents(w);
    w.store.accounts.set("hoda", { ...w.store.accounts.get("hoda")!, status: "suspended" });
    await refuses(sendTransfer(w.deps, me, { requestId: "ver-0000000000000001", amount: 1_000, toParentId: "HUDA2345" }), "receiver-cannot-receive");
    await refuses(sendTransfer(w.deps, { uid: "ali", verifiedClaim: false }, { requestId: "ver-0000000000000002", amount: 1_000, toParentId: "HUDA2345" }), "not-verified");
    await refuses(sendTransfer(w.deps, me, { requestId: "ver-0000000000000003", amount: 1_000, toParentId: "ALYZ2345" }), "self");
    w.store.addParent("nowallet", "NWLT2345");
    await refuses(sendTransfer(w.deps, me, { requestId: "ver-0000000000000004", amount: 1_000, toParentId: "NWLT2345" }), "receiver-cannot-receive");
  });

  it("no fee and no commission: the receiver gets exactly what was sent", async () => {
    const w = world();
    await twoParents(w);
    await sendTransfer(w.deps, me, { requestId: "fee-0000000000000001", amount: 3_333, toParentId: "HUDA2345" });
    const total = [...w.ledger.accounts.values()].reduce((s, a) => s + a.balance, 0);
    assert.equal(total, 50_000, "no money appears or disappears");
    assert.equal(await balanceOf(w, "hoda"), 3_333);
  });

  it("records are append-only: a transfer is created once and its outcome once", async () => {
    const w = world();
    await twoParents(w);
    const r = await sendTransfer(w.deps, me, { requestId: "app-0000000000000001", amount: 1_000, toParentId: "HUDA2345" });
    await getTransfer(w.deps, me, { transferId: r.transfer.id });
    await sendTransfer(w.deps, me, { requestId: "app-0000000000000001", amount: 1_000, toParentId: "HUDA2345" });
    const writes = w.store.writes.filter((x) => x.endsWith(r.transfer.id));
    assert.deepEqual(writes, [`transfer:create:${r.transfer.id}`, `result:create:${r.transfer.id}`]);
  });
});

describe("timeouts, retries and reconciliation never lose or double money", () => {
  it("unknown outcome (the partner moved it but the answer was lost): pending, then done from the partner's record", async () => {
    const w = world();
    await twoParents(w);
    w.mode.value = "timeout";
    const body = { requestId: "rec-0000000000000001", amount: 2_000, toParentId: "HUDA2345" };
    const first = await sendTransfer(w.deps, me, body);
    assert.equal(first.transfer.status, "pending");
    // The app retries right away: still the same pending transfer, nothing sent again.
    w.mode.value = "ok";
    assert.equal((await sendTransfer(w.deps, me, body)).transfer.status, "pending");
    assert.equal(w.ledger.ops.size, 2, "top-up and one send at the partner");
    // Later the partner is asked BEFORE anything is retried.
    w.clock.now += 60_000;
    const later = await sendTransfer(w.deps, me, body);
    assert.equal(later.transfer.status, "done");
    assert.equal(await balanceOf(w, "ali"), 48_000);
    assert.equal(await balanceOf(w, "hoda"), 2_000);
    assert.equal(w.ledger.ops.size, 2);
  });

  it("lost on the way (the partner never got it): sent again with the same ID once the partner says it has no record", async () => {
    const w = world();
    await twoParents(w);
    w.mode.value = "lost";
    const r = await sendTransfer(w.deps, me, { requestId: "rec-0000000000000002", amount: 2_000, toParentId: "HUDA2345" });
    assert.equal(r.transfer.status, "pending");
    w.mode.value = "ok";
    assert.equal(await w.provider.findOperation(r.transfer.id), null);
    w.clock.now += 60_000;
    const job = await reconcileAll(w.deps);
    assert.deepEqual(job, { checked: 1, settled: 1 });
    assert.equal((await getTransfer(w.deps, me, { transferId: r.transfer.id })).status, "done");
    assert.equal(await balanceOf(w, "hoda"), 2_000);
    // Running the job again changes nothing.
    assert.deepEqual(await reconcileAll(w.deps), { checked: 0, settled: 0 });
    assert.equal(await balanceOf(w, "hoda"), 2_000);
  });

  it("a partner that keeps failing leaves it pending; after a day without any partner record it fails and no money moved", async () => {
    const w = world();
    await twoParents(w);
    w.mode.value = "lost";
    const r = await sendTransfer(w.deps, me, { requestId: "rec-0000000000000003", amount: 2_000, toParentId: "HUDA2345" });
    for (let i = 0; i < 5; i++) {
      w.clock.now += 60_000;
      await reconcileAll(w.deps);
    }
    assert.equal((await getTransfer(w.deps, me, { transferId: r.transfer.id })).status, "pending");
    w.mode.value = "down";
    w.clock.now = T0 + GIVE_UP_AFTER_MS + 1;
    await reconcileAll(w.deps);
    assert.equal((await w.store.result(r.transfer.id)), null, "the partner did not answer: still pending");
    w.mode.value = "ok";
    w.clock.now += 120_000;
    // Older than a day and unknown to the partner: it is CANCELLED at the
    // partner first, then recorded as failed; nothing moved.
    await reconcileAll(w.deps);
    const view = await getTransfer(w.deps, me, { transferId: r.transfer.id });
    assert.equal(view.status, "failed");
    assert.equal(view.reason, "not-received");
    assert.equal(await balanceOf(w, "ali"), 50_000);
    assert.equal(await balanceOf(w, "hoda"), 0);
    assert.ok(w.store.events.has(`wallet_${r.transfer.id}_failed`), "the sender is told");
  });

  it("a wallet frozen while a transfer was lost: it is not sent again", async () => {
    const w = world();
    await twoParents(w);
    w.mode.value = "lost";
    const r = await sendTransfer(w.deps, me, { requestId: "rec-0000000000000004", amount: 2_000, toParentId: "HUDA2345" });
    w.mode.value = "ok";
    await w.store.updateWallet("ali", { status: "frozen" });
    w.clock.now += 60_000;
    await reconcileAll(w.deps);
    // Cancelled at the partner before it is recorded as failed: a late
    // arrival of the lost request can no longer move money.
    assert.equal((await w.store.result(r.transfer.id))?.status, "failed");
    assert.equal((await w.provider.findOperation(r.transfer.id))?.status, "failed");
    const late = await w.provider.send({ fromRef: (await w.store.wallet("ali"))!.walletRef, toRef: (await w.store.wallet("hoda"))!.walletRef, amount: 2_000, requestId: r.transfer.id });
    assert.equal(late.status, "failed");
    assert.equal(await balanceOf(w, "hoda"), 0);
  });

  it("the partner cannot confirm or cancel: never recorded as failed; it stays pending and an admin is alerted", async () => {
    const w = world();
    await twoParents(w);
    w.mode.value = "lost";
    const r = await sendTransfer(w.deps, me, { requestId: "rec-0000000000000006", amount: 2_000, toParentId: "HUDA2345" });
    await w.store.updateWallet("ali", { status: "frozen" });
    // "lost": findOperation answers "not found", cancel times out.
    w.clock.now += 60_000;
    await reconcileAll(w.deps);
    assert.equal(await w.store.result(r.transfer.id), null);
    assert.equal(w.store.alertsMap.get(`stuck_${r.transfer.id}`)?.kind, "stuck");
    // Prompt 12: the partner confirms in writing that it never ran; a super
    // admin records that once. The alert closes as settledWithPartner.
    const settled = await settleStuckTransfer(w.deps, r.transfer.id, { status: "failed", partnerRef: null }, "super1");
    assert.equal(settled.status, "failed");
    assert.equal(w.store.alertsMap.get(`stuck_${r.transfer.id}`)?.outcome, "settledWithPartner");
    await assert.rejects(settleStuckTransfer(w.deps, r.transfer.id, { status: "done", partnerRef: "x" }, "super1"), (e: unknown) => e instanceof WalletError && e.reason === "invalid-state");
    await assert.rejects(settleStuckTransfer(w.deps, "nope", { status: "done", partnerRef: null }, "super1"), (e: unknown) => e instanceof WalletError && e.reason === "not-found");
  });

  it("two reconciles of one transfer never run at once (lease)", async () => {
    const w = world();
    await twoParents(w);
    w.mode.value = "lost";
    const r = await sendTransfer(w.deps, me, { requestId: "rec-0000000000000007", amount: 2_000, toParentId: "HUDA2345" });
    w.mode.value = "ok";
    w.clock.now += 60_000;
    const leased = await w.store.leasePending(r.transfer.id, w.clock.now, 60_000);
    assert.ok(leased);
    assert.equal(await reconcile(w.deps, (await w.store.transfer(r.transfer.id))!), null, "another reconcile holds the lease");
    assert.equal(await w.provider.findOperation(r.transfer.id), null, "nothing sent meanwhile");
    w.clock.now += 61_000;
    assert.equal((await reconcile(w.deps, (await w.store.transfer(r.transfer.id))!))?.status, "done");
    assert.equal(await balanceOf(w, "hoda"), 2_000);
  });

  it("opening the wallet settles the parent's own stale pending transfers", async () => {
    const w = world();
    await twoParents(w);
    w.mode.value = "timeout";
    const r = await sendTransfer(w.deps, me, { requestId: "rec-0000000000000005", amount: 2_000, toParentId: "HUDA2345" });
    w.mode.value = "ok";
    w.clock.now += 60_000;
    const view = await getWallet(w.deps, me);
    assert.equal(view.balance, 48_000);
    assert.equal((await w.store.result(r.transfer.id))?.status, "done");
  });
});

describe("add money and withdraw", () => {
  it("top-up and withdrawal limits; history shows both", async () => {
    const w = world();
    await twoParents(w, 0);
    w.store.config = { ...w.store.config, topUpMax: 20_000, topUpPerDayMax: 30_000 };
    await refuses(addMoney(w.deps, me, { requestId: "add-0000000000000001", amount: 20_001 }), "over-transfer-limit");
    await addMoney(w.deps, me, { requestId: "add-0000000000000002", amount: 20_000 });
    w.clock.now += 1_000;
    await refuses(addMoney(w.deps, me, { requestId: "add-0000000000000003", amount: 10_001 }), "over-daily-limit");
    const out = await withdraw(w.deps, me, { requestId: "wd-00000000000000001", amount: 5_000 });
    assert.equal(out.transfer.status, "done");
    w.clock.now += 1_000;
    const fail = await withdraw(w.deps, me, { requestId: "wd-00000000000000002", amount: 50_000 });
    assert.equal(fail.transfer.reason, "insufficient-funds");
    assert.equal(await balanceOf(w, "ali"), 15_000);
    const h = (await listHistory(w.deps, me, {})).transfers;
    assert.deepEqual(h.map((t) => [t.kind, t.direction, t.status]), [
      ["withdraw", "out", "failed"],
      ["withdraw", "out", "done"],
      ["topup", "in", "done"],
    ]);
  });
});

describe("notifications", () => {
  it("sender and receiver are told; the text has no amount, name or note", async () => {
    const w = world();
    await twoParents(w);
    const r = await sendTransfer(w.deps, me, { requestId: "ntf-0000000000000001", amount: 7_777, toParentId: "HUDA2345", note: "Secret note" });
    const inEvent = w.store.events.get(`wallet_${r.transfer.id}_in`);
    const outEvent = w.store.events.get(`wallet_${r.transfer.id}_out`);
    assert.deepEqual(inEvent?.recipients, ["hoda"]);
    assert.equal(inEvent?.type, "wallet-received");
    assert.deepEqual(outEvent?.recipients, ["ali"]);
    assert.equal(inEvent?.actorUid, null, "the sender is not skipped as the actor");
    const raw = JSON.stringify([inEvent, outEvent]);
    for (const leak of ["7777", "77.77", "Secret", "Hoda", "Ali"]) assert.ok(!raw.includes(leak), leak);
    for (const type of ["wallet-received", "wallet-sent", "wallet-failed", "wallet-frozen", "wallet-updated"] as const) {
      const all = JSON.stringify(TEXTS[type]);
      assert.ok(!/\d/.test(all), `${type}: no numbers`);
      assert.ok(!all.includes("{when}"));
      assert.equal(TYPES[type].group, "wallet");
      assert.ok(TYPES[type].template, "goes to WhatsApp too");
    }
  });

  it("logs never carry amounts, names or notes", async () => {
    const w = world();
    await twoParents(w);
    w.mode.value = "timeout";
    await sendTransfer(w.deps, me, { requestId: "log-0000000000000001", amount: 4_321, toParentId: "HUDA2345", note: "Private words" });
    const raw = JSON.stringify(w.logs);
    for (const leak of ["4321", "Private", "Hoda", "HUDA2345"]) assert.ok(!raw.includes(leak), leak);
  });
});

describe("reports and unusual patterns", () => {
  it("report a transfer problem; 'someone else sent it' freezes the sender's own wallet", async () => {
    const w = world();
    await twoParents(w);
    const r = await sendTransfer(w.deps, me, { requestId: "rep-0000000000000001", amount: 1_000, toParentId: "HUDA2345" });
    const fromHoda = await reportTransfer(w.deps, hoda, { transferId: r.transfer.id, reason: "wrongAmount", note: "Expected 20" });
    assert.equal(fromHoda.frozen, false);
    const audit: string[] = [];
    const mine = await reportTransfer({ ...w.deps, audit: async (e) => void audit.push(e.action) }, me, { transferId: r.transfer.id, reason: "unauthorized" });
    assert.equal(mine.frozen, true);
    assert.deepEqual(audit, ["wallet.freeze.self"]);
    assert.ok([...w.store.events.values()].some((e) => e.type === "wallet-frozen" && e.recipients[0] === "ali"));
    assert.equal((await w.store.wallet("ali"))?.status, "frozen");
    assert.equal(w.ledger.accounts.get((await w.store.wallet("ali"))!.walletRef)?.frozen, true);
    await refuses(sendTransfer(w.deps, me, { requestId: "rep-0000000000000002", amount: 1_000, toParentId: "HUDA2345" }), "frozen");
    assert.equal([...w.store.alertsMap.values()].filter((a) => a.kind === "report").length, 2);
    // Not a party: not found.
    w.store.addParent("sami", "SAMY2345");
    await refuses(reportTransfer(w.deps, { uid: "sami", verifiedClaim: true }, { transferId: r.transfer.id, reason: "other" }), "not-found");
  });

  it("detects many first-time receivers or many transfers within an hour", () => {
    const t = (to: string): TransferRecord =>
      ({ id: `t_${to}`, kind: "transfer", toUid: to, uid: "ali" }) as TransferRecord;
    const limits = { alertNewReceivers: 3, alertTransfersPerHour: 4 };
    assert.deepEqual(detectPatterns([t("a"), t("b")], () => true, limits).alerts, []);
    assert.deepEqual(detectPatterns([t("a"), t("b"), t("c")], () => true, limits).alerts, ["new-receivers"]);
    assert.deepEqual(detectPatterns([t("a"), t("b"), t("c")], (u) => u !== "c", limits).alerts, []);
    assert.deepEqual(detectPatterns([t("a"), t("a"), t("a"), t("a")], () => false, limits).alerts, ["many-transfers"]);
  });

  it("raises one admin alert when a parent pays several new receivers quickly", async () => {
    const w = world();
    await twoParents(w);
    for (const [uid, pid] of [
      ["p1", "PPPA2345"],
      ["p2", "PPPB2345"],
      ["p3", "PPPC2345"],
      ["p4", "PPPD2345"],
    ]) {
      w.store.addParent(uid, pid);
      await openWallet(w.deps, { uid, verifiedClaim: true }, { acceptTerms: WALLET_TERMS_VERSION });
    }
    let i = 0;
    for (const pid of ["PPPA2345", "PPPB2345", "PPPC2345", "PPPD2345"]) {
      await sendTransfer(w.deps, me, { requestId: `pat-000000000000000${++i}`, amount: 1_000, toParentId: pid });
      w.clock.now += 60_000;
    }
    const alerts = [...w.store.alertsMap.values()].filter((a) => a.kind === "new-receivers");
    assert.equal(alerts.length, 1);
    assert.equal(alerts[0].uid, "ali");
    // Nothing was blocked: alerts are for admins to look at.
    assert.equal(await balanceOf(w, "ali"), 46_000);
  });
});

describe("admin panel", () => {
  const admin = { uid: "admin1", role: "admin" as const };

  function adminWorld(w: World) {
    const audit: Array<Record<string, unknown>> = [];
    const deps: WalletAdminDeps = { store: w.store, provider: w.provider, now: () => w.clock.now, audit: async (e) => void audit.push({ ...e }) };
    return { deps, audit };
  }

  it("read-only transfer log, logged; notes are not in it", async () => {
    const w = world();
    await twoParents(w);
    await sendTransfer(w.deps, me, { requestId: "adm-0000000000000001", amount: 1_000, toParentId: "HUDA2345", note: "Private" });
    const { deps, audit } = adminWorld(w);
    const log = await adminListTransfers(deps, admin, {}, "1.2.3.4");
    assert.equal(log.transfers.length, 2);
    assert.ok(!JSON.stringify(log).includes("Private"));
    assert.equal(audit[0].action, "wallet.transfers.view");
    const one = await adminGetWallet(deps, admin, { uid: "ali" }, null);
    assert.equal(one.balance, 49_000);
    assert.equal(one.partnerTransactions.length, 2);
    assert.equal(audit[1].action, "wallet.view");
  });

  it("freeze and unfreeze with a reason (audit log, the parent is told); a frozen wallet cannot send", async () => {
    const w = world();
    await twoParents(w);
    const { deps, audit } = adminWorld(w);
    await assert.rejects(adminSetWalletFrozen(deps, admin, { uid: "ali", frozen: true }, null), WalletError);
    assert.deepEqual(await adminSetWalletFrozen(deps, admin, { uid: "ali", frozen: true, reasonCode: "fraudSuspected", note: "Check" }, null), { status: "frozen" });
    assert.equal(audit.at(-1)?.action, "wallet.freeze");
    assert.equal(audit.at(-1)?.reasonCode, "fraudSuspected");
    assert.ok(!JSON.stringify(audit).includes("Check"), "the note stays out of the audit details");
    await refuses(sendTransfer(w.deps, me, { requestId: "adm-0000000000000002", amount: 1_000, toParentId: "HUDA2345" }), "frozen");
    assert.ok([...w.store.events.values()].some((e) => e.type === "wallet-frozen" && e.recipients[0] === "ali"));
    await adminSetWalletFrozen(deps, admin, { uid: "ali", frozen: false, reasonCode: "other" }, null);
    assert.equal(audit.at(-1)?.action, "wallet.unfreeze");
    assert.equal((await sendTransfer(w.deps, me, { requestId: "adm-0000000000000003", amount: 1_000, toParentId: "HUDA2345" })).transfer.status, "done");
  });

  it("admins cannot move money: the admin module has no money path and never calls send, add or withdraw", async () => {
    const w = world();
    await twoParents(w);
    const calls: string[] = [];
    const spy = new Proxy(w.provider as WalletProvider, {
      get(target, prop) {
        const v = Reflect.get(target, prop);
        return typeof v === "function" ? (...a: unknown[]) => (calls.push(String(prop)), v.apply(target, a)) : v;
      },
    });
    const { deps } = adminWorld(w);
    const spied = { ...deps, provider: spy };
    await adminListTransfers(spied, admin, {}, null);
    await adminGetWallet(spied, admin, { uid: "hoda" }, null);
    await adminSetWalletFrozen(spied, admin, { uid: "hoda", frozen: true, reasonCode: "dispute" }, null);
    await adminSetWalletFrozen(spied, admin, { uid: "hoda", frozen: false, reasonCode: "dispute" }, null);
    assert.ok(calls.every((c) => ["balance", "listTransactions", "freeze"].includes(c)), calls.join());
    const exported = Object.keys(walletAdmin).filter((k) => typeof (walletAdmin as Record<string, unknown>)[k] === "function");
    assert.deepEqual(exported.sort(), ["adminGetWallet", "adminListTransfers", "adminListWalletAlerts", "adminResolveWalletAlert", "adminSetWalletFrozen"]);
  });

  it("a freeze the partner missed is applied again by the reconcile job", async () => {
    const w = world();
    await twoParents(w);
    const { deps } = adminWorld(w);
    w.mode.value = "down";
    await adminSetWalletFrozen(deps, admin, { uid: "ali", frozen: true, reasonCode: "fraudSuspected" }, null);
    const ref = (await w.store.wallet("ali"))!.walletRef;
    assert.equal((await w.store.wallet("ali"))?.partnerSynced, false);
    assert.equal(w.ledger.accounts.get(ref)?.frozen, false, "the partner missed it");
    assert.equal(await syncPartnerFreezes(w.deps), 0, "still down");
    w.mode.value = "ok";
    assert.equal(await syncPartnerFreezes(w.deps), 1);
    assert.equal(w.ledger.accounts.get(ref)?.frozen, true);
    assert.equal((await w.store.wallet("ali"))?.partnerSynced, true);
  });

  it("the audit entry is written before the change", async () => {
    const w = world();
    await twoParents(w);
    const order: string[] = [];
    const store = w.store;
    const update = store.updateWallet.bind(store);
    store.updateWallet = async (...a: Parameters<typeof update>) => {
      order.push("change");
      return update(...a);
    };
    const deps: WalletAdminDeps = { store, provider: w.provider, now: () => w.clock.now, audit: async () => void order.push("audit") };
    await adminSetWalletFrozen(deps, admin, { uid: "ali", frozen: true, reasonCode: "dispute" }, null);
    assert.equal(order[0], "audit");
  });

  it("freezing works even when the partner is off (our side is enough); unfreezing needs the partner", async () => {
    const w = world();
    await twoParents(w);
    const { deps, audit } = adminWorld(w);
    const off = { ...deps, provider: null };
    await adminSetWalletFrozen(off, admin, { uid: "ali", frozen: true, reasonCode: "stolenPhone" }, null);
    assert.equal((await w.store.wallet("ali"))?.status, "frozen");
    assert.equal(audit.at(-1)?.action, "wallet.freeze");
    await assert.rejects(adminSetWalletFrozen(off, admin, { uid: "ali", frozen: false, reasonCode: "other" }, null), (e: unknown) => e instanceof WalletError && e.reason === "wallet-off");
    assert.equal((await w.store.wallet("ali"))?.status, "frozen");
  });

  it("resolves an alert, logged", async () => {
    const w = world();
    await twoParents(w);
    const r = await sendTransfer(w.deps, me, { requestId: "adm-0000000000000004", amount: 1_000, toParentId: "HUDA2345" });
    const { alertId } = await reportTransfer(w.deps, hoda, { transferId: r.transfer.id, reason: "notReceived" });
    const { deps, audit } = adminWorld(w);
    const closed = await adminResolveWalletAlert(deps, admin, { alertId, outcome: "sentToPartner" }, null);
    assert.equal(closed.status, "handled");
    assert.equal(audit.at(-1)?.action, "wallet.alert.resolve");
    await assert.rejects(adminResolveWalletAlert(deps, admin, { alertId, outcome: "refund" }, null), WalletError);
  });
});

// --------------------------------------------------------------------------
// Account deletion locks the wallet first (Prompt 12 review, item 2)
// --------------------------------------------------------------------------

/**
 * The deletion runner's wallet steps over the wallet test world (the
 * Firestore runner does the same with a transaction on wallets/{uid}).
 */
function deletionOver(w: World, onLocked: () => Promise<void> = async () => undefined): DeletionRunner & { ran: string[] } {
  const ran: string[] = [];
  return {
    ran,
    facts: async () => ({ exists: true, drivingNow: false, parentId: "ALYZ2345", banned: false }),
    lockWallet: async (uid, nowMs) => {
      const wal = await w.store.wallet(uid);
      if (!wal) return null;
      const lock: WalletLock = { status: wal.status, frozenReason: wal.frozenReason, frozenAtMs: wal.frozenAtMs, frozenBy: wal.frozenBy };
      await w.store.updateWallet(uid, { status: "frozen", frozenReason: null, frozenAtMs: nowMs, frozenBy: "deletion" });
      try {
        await w.provider.freeze(wal.walletRef, true);
      } catch (error) {
        await w.store.updateWallet(uid, { status: wal.status, frozenAtMs: wal.frozenAtMs, frozenBy: wal.frozenBy });
        throw error;
      }
      ran.push("lock");
      await onLocked();
      return lock;
    },
    walletFacts: async (uid) => {
      const wal = await w.store.wallet(uid);
      const open = [...w.store.transfers.values()].filter((t) => t.parties.includes(uid) && !w.store.results_.has(t.id));
      return { balance: await w.provider.balance(wal!.walletRef), pending: open.length };
    },
    unlockWallet: async (uid, lock) => {
      const wal = await w.store.wallet(uid);
      if (lock.status === "active") await w.provider.freeze(wal!.walletRef, false);
      await w.store.updateWallet(uid, { status: lock.status === "active" ? "active" : "frozen", frozenReason: null, frozenAtMs: lock.frozenAtMs, frozenBy: lock.frozenBy });
      ran.push("unlock");
    },
    saveClosed: async () => void ran.push("saveClosed"),
    closed: async () => null,
    runFlowStep: async (_uid, step) => void ran.push(`flow:${step}`),
    runTarget: async () => 1,
    runPurgeStep: async () => undefined,
  };
}

describe("account deletion and the wallet", () => {
  it("an INCOMING pending transfer refuses the deletion, and the wallet is open again", async () => {
    const w = world();
    await twoParents(w, 0);
    await addMoney(w.deps, hoda, { requestId: "topup-hoda-000000001", amount: 5_000 });
    w.mode.value = "timeout";
    const r = await sendTransfer(w.deps, hoda, { requestId: "send-to-ali-00000001", amount: 2_000, toParentId: "ALYZ2345" });
    assert.equal(r.transfer.status, "pending");
    w.mode.value = "ok";
    const runner = deletionOver(w);
    await assert.rejects(deleteAccount(runner, "ali", T0, () => undefined), (e: unknown) => e instanceof DeletionError && e.reason === "wallet-pending");
    assert.deepEqual(runner.ran, ["lock", "unlock"], "nothing deleted");
    assert.equal((await w.store.wallet("ali"))?.status, "active");
  });

  it("a transfer arriving mid-deletion is refused (the wallet is locked before the check)", async () => {
    const w = world();
    await twoParents(w, 0);
    await addMoney(w.deps, hoda, { requestId: "topup-hoda-000000002", amount: 5_000 });
    let arriving: Promise<unknown> | null = null;
    const runner = deletionOver(w, async () => {
      arriving = sendTransfer(w.deps, hoda, { requestId: "send-to-ali-00000002", amount: 2_000, toParentId: "ALYZ2345" });
      await refuses(arriving, "receiver-cannot-receive");
    });
    const res = await deleteAccount(runner, "ali", T0, () => undefined);
    assert.equal(res.closed, true);
    assert.ok(arriving, "a transfer was tried while deleting");
    assert.equal(await balanceOf(w, "hoda"), 5_000, "nothing left Hoda's wallet");
    assert.equal(w.store.transfers.size, 1, "only Hoda's top-up exists");
  });

  it("a transfer that passed its checks just before the lock is refused in its transaction", async () => {
    const w = world();
    await twoParents(w, 0);
    await addMoney(w.deps, hoda, { requestId: "topup-hoda-000000003", amount: 5_000 });
    const runner = deletionOver(w);
    w.store.beforeStart = () => {
      w.store.beforeStart = null;
      // Deletion locks Ali's wallet between Hoda's checks and her transaction.
      const wal = w.store.wallets.get("ali")!;
      w.store.wallets.set("ali", { ...wal, status: "frozen", frozenBy: "deletion" });
    };
    await refuses(sendTransfer(w.deps, hoda, { requestId: "send-to-ali-00000003", amount: 2_000, toParentId: "ALYZ2345" }), "receiver-cannot-receive");
    assert.equal((await deleteAccount(runner, "ali", T0, () => undefined)).closed, true);
    assert.equal(await balanceOf(w, "hoda"), 5_000);
  });

  it("money in the wallet refuses the deletion after the lock; an admin cannot reopen a closed wallet", async () => {
    const w = world();
    await twoParents(w, 1_000);
    const runner = deletionOver(w);
    await assert.rejects(deleteAccount(runner, "ali", T0, () => undefined), (e: unknown) => e instanceof DeletionError && e.reason === "wallet-not-empty");
    assert.equal((await w.store.wallet("ali"))?.status, "active");
    // A wallet locked by deletion stays shut whatever an admin taps.
    await w.store.updateWallet("hoda", { status: "frozen", frozenBy: "deletion" });
    const deps: WalletAdminDeps = { store: w.store, provider: w.provider, now: () => w.clock.now, audit: async () => undefined };
    await assert.rejects(adminSetWalletFrozen(deps, { uid: "admin1" } as never, { uid: "hoda", frozen: false, reasonCode: "other" }, null), (e: unknown) => e instanceof WalletError && e.reason === "invalid-state");
  });

  it("the partner cannot be told: nothing is deleted, the wallet stays as it was", async () => {
    const w = world();
    await twoParents(w, 0);
    w.mode.value = "down";
    const runner = deletionOver(w);
    await assert.rejects(deleteAccount(runner, "ali", T0, () => undefined), (e: unknown) => e instanceof DeletionError && e.reason === "wallet-unavailable");
    assert.ok(!runner.ran.includes("saveClosed"));
    assert.equal((await w.store.wallet("ali"))?.status, "active");
  });
});
