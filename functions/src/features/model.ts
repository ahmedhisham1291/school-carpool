/**
 * Pilot feature switches (owner decision 14 Nov 2026, docs/DECISIONS.md
 * "Improvements, revised"). One server document, config/features, read by
 * signed-in parents and written only by Cloud Functions (super admins
 * change it from the admin panel). A switch that is off:
 * - the server refuses every callable of the feature with reason
 *   "feature-off", and its triggers and scheduled jobs do nothing;
 * - the app hides the entry points and shows "not available yet" on a
 *   deep link.
 * Turning a feature on again needs no app release and no deploy.
 *
 * Core features (sign-in, verification, carpools, schedule, trips and
 * alerts, chat) have no switch. Driver eligibility (verified, licence and
 * car expiry, suspension, driving pauses) is NOT part of
 * ratingsAndVouching or yearlyChecks and always stays on.
 *
 * Pure; unit-tested (test/features.test.ts).
 */

export const FEATURE_KEYS = ["wallet", "ratingsAndVouching", "yearlyChecks", "settleUp", "contributions", "activityCarpools"] as const;
export type FeatureKey = (typeof FEATURE_KEYS)[number];
export type FeatureSwitches = Readonly<Record<FeatureKey, boolean>>;

/**
 * A missing document, or a missing or odd field, reads as these.
 *
 * NO MONEY IN THE APP (owner decision 16 Nov 2026, docs/DECISIONS.md,
 * supersedes "Settle up for the pilot"): rides are free volunteer turns
 * between parents. The wallet, Settle up and the per-child contribution
 * (F25) are OFF in every environment; their code stays. Turning one on is
 * an owner decision that needs the lawyer first (docs/legal/
 * egypt-legal-review.md, Law 87/2018 and insurance).
 */
export const PILOT_DEFAULTS: FeatureSwitches = {
  wallet: false,
  ratingsAndVouching: false,
  yearlyChecks: false,
  settleUp: false,
  contributions: false,
  // R9 (answers.md 2.1, 2.4): activity carpools (F39) stay off in the pilot
  // until the lawyer's written Law 87/2018 opinion covers them.
  activityCarpools: false,
};

/** The switches that carry money or a cost between parents (all off by default). */
export const MONEY_FEATURES: readonly FeatureKey[] = ["wallet", "settleUp", "contributions"];

/** Every switch on (unit tests of the features themselves). */
export const ALL_ON: FeatureSwitches = { wallet: true, ratingsAndVouching: true, yearlyChecks: true, settleUp: true, contributions: true, activityCarpools: true };

export const FEATURES_DOC = "config/features";

/** How long one function instance trusts its copy of the switches. */
export const FEATURE_CACHE_MS = 30_000;

/**
 * FAIL CLOSED: after this many reads in a row have failed, an instance
 * stops trusting its last known copy and uses the pilot defaults until a
 * read works again. So a stale "on" cannot outlive a switch-off for long
 * when Firestore cannot be read: every switch goes back to its default,
 * and every default is off (the money features included).
 */
export const FEATURE_MAX_FAILED_READS = 3;

export function isFeatureKey(value: unknown): value is FeatureKey {
  return typeof value === "string" && (FEATURE_KEYS as readonly string[]).includes(value);
}

/** The switches from the stored document; anything missing or not a boolean is the pilot default. */
export function switchesFrom(doc: Record<string, unknown> | null | undefined): FeatureSwitches {
  const out: Record<FeatureKey, boolean> = { ...PILOT_DEFAULTS };
  if (doc && typeof doc === "object") {
    for (const key of FEATURE_KEYS) {
      if (typeof doc[key] === "boolean") out[key] = doc[key] as boolean;
    }
  }
  return out;
}

/** Thrown by a gated entry point when its feature is off. */
export class FeatureOffError extends Error {
  constructor(readonly feature: FeatureKey) {
    super("feature-off");
    this.name = "FeatureOffError";
  }
}

export type FeatureReader = () => Promise<Record<string, unknown> | null | undefined>;

/**
 * The switches with a short cache, so a busy instance reads config/features
 * about twice a minute, not on every call. A failed read uses the last
 * known value when there is one, else the pilot defaults (never "all on");
 * after FEATURE_MAX_FAILED_READS failures in a row it is the pilot
 * defaults whatever was known (fail closed).
 */
export class FeatureCache {
  private value: FeatureSwitches | null = null;
  private readAtMs = 0;
  private pending: Promise<FeatureSwitches> | null = null;
  private failedReads = 0;

  constructor(
    private readonly read: FeatureReader,
    private readonly now: () => number = () => Date.now(),
    private readonly ttlMs: number = FEATURE_CACHE_MS,
    private readonly onError: (error: unknown) => void = () => undefined,
  ) {}

  async get(): Promise<FeatureSwitches> {
    const nowMs = this.now();
    if (this.value && nowMs - this.readAtMs < this.ttlMs) return this.value;
    // One read at a time per instance.
    this.pending ??= this.load(nowMs).finally(() => {
      this.pending = null;
    });
    return this.pending;
  }

  private async load(nowMs: number): Promise<FeatureSwitches> {
    try {
      this.value = switchesFrom(await this.read());
      this.failedReads = 0;
    } catch (error) {
      this.onError(error);
      this.failedReads += 1;
      if (!this.value || this.failedReads >= FEATURE_MAX_FAILED_READS) this.value = PILOT_DEFAULTS;
    }
    this.readAtMs = nowMs;
    return this.value;
  }

  /** After an admin change on this instance: the next call reads again. */
  clear(): void {
    this.value = null;
    this.readAtMs = 0;
    this.failedReads = 0;
  }

  async isOn(key: FeatureKey): Promise<boolean> {
    return (await this.get())[key];
  }

  async require(key: FeatureKey): Promise<void> {
    if (!(await this.isOn(key))) throw new FeatureOffError(key);
  }
}

/**
 * Every exported function that belongs to a switched feature (the names in
 * src/index.ts). The test checks that each one refuses or does nothing
 * while its switch is off. Functions that serve several things (for
 * example getTrustOverview, trustDaily, adminTrustQueue) are not here:
 * they keep running and leave out the part that is off.
 */
export const GATED_FUNCTIONS: Readonly<Record<FeatureKey, { callables: readonly string[]; jobs: readonly string[] }>> = {
  wallet: {
    callables: [
      "getWallet",
      "openWallet",
      "lookupParentId",
      "walletContacts",
      "sendMoney",
      "addMoney",
      "withdrawMoney",
      "listWalletHistory",
      "getTransfer",
      "reportTransfer",
      "adminListTransfers",
      "adminGetWallet",
      "adminSetWalletFrozen",
      "adminListWalletAlerts",
      "adminResolveWalletAlert",
    ],
    jobs: ["walletReconcile"],
  },
  ratingsAndVouching: {
    callables: ["listRateable", "rateParent", "getTrustSummary", "adminResolveRatingFlag"],
    jobs: [],
  },
  yearlyChecks: {
    callables: ["confirmSchoolYear"],
    jobs: [],
  },
  // F25: the per-child contribution has no callable of its own:
  // createCarpool refuses a contribution and requestToJoinCarpool ignores
  // one while it is off, and searches leave it out (carpools/flow.ts).
  contributions: {
    callables: [],
    jobs: [],
  },
  // R9 (F39): no callable of its own either: createCarpool refuses an
  // activity carpool, searchCarpools an activity search and
  // requestToJoinCarpool a join to one while it is off (carpools/flow.ts).
  activityCarpools: {
    callables: [],
    jobs: [],
  },
  settleUp: {
    callables: [
      "getSettleUpProfile",
      "saveInstaPayAddress",
      "removeInstaPayAddress",
      "settleUpContacts",
      "createSettleUp",
      "settleUpAction",
      "getSettleUpAddress",
      "reportSettleUp",
      "adminListSettleUps",
    ],
    jobs: [],
  },
};

/** Notification types that are not sent while their feature is off. */
export const GATED_NOTIFICATIONS: Readonly<Record<string, FeatureKey>> = {
  "wallet-received": "wallet",
  "wallet-sent": "wallet",
  "wallet-failed": "wallet",
  "wallet-frozen": "wallet",
  "wallet-updated": "wallet",
  "year-check-due": "yearlyChecks",
  "settle-requested": "settleUp",
  "settle-paid": "settleUp",
  "settle-updated": "settleUp",
};

export function notificationFeature(type: string): FeatureKey | null {
  return GATED_NOTIFICATIONS[type] ?? null;
}

/** An admin's change: one switch, a real boolean. */
export function parseFeatureChange(data: unknown): { feature: FeatureKey; on: boolean } | null {
  if (typeof data !== "object" || data === null) return null;
  const raw = data as Record<string, unknown>;
  if (!isFeatureKey(raw.feature) || typeof raw.on !== "boolean") return null;
  return { feature: raw.feature, on: raw.on };
}
