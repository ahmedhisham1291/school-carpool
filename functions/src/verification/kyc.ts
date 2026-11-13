/**
 * Automated ID check (F18) behind one interface (CLAUDE.md STACK: "ID check:
 * Valify behind one interface"). The result only helps the reviewer: every
 * case still goes to the admin queue, and only an admin decision verifies
 * an account.
 *
 * Providers:
 * - "fake": answers "match" or "no_match" from a test setting
 *   (config/kyc.fakeResult in Firestore, default "match"). Refused in prod.
 * - "valify": stub until the Valify contract. It is never called unless
 *   VALIFY_ENABLED is true, and even then it fails closed (result "error",
 *   so the reviewer checks by hand).
 *
 * Privacy: a provider returns only the outcome. OCR fields from the back of
 * the ID (religion, marital status, job) must never be copied out of the
 * provider response (spec section 3).
 */

export type KycResult = "match" | "no_match" | "error";

export const KYC_RESULTS: readonly KycResult[] = ["match", "no_match", "error"];

export interface KycImages {
  idFront: Buffer;
  idBack: Buffer;
  selfie: Buffer;
  /** Second selfie after the head-turn prompt (liveness evidence). */
  selfieTurn: Buffer;
}

export interface KycOutcome {
  provider: string;
  result: KycResult;
  /** Face match score from 0 to 1, when the provider gives one. */
  score: number | null;
  /** The provider's reference for this check, for support requests. */
  reference: string | null;
}

export interface KycProvider {
  readonly kind: string;
  /** Images are loaded only if the provider needs them. */
  check(images: () => Promise<KycImages>): Promise<KycOutcome>;
}

export class KycNotConfiguredError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "KycNotConfiguredError";
  }
}

export function asKycResult(value: unknown): KycResult {
  return KYC_RESULTS.includes(value as KycResult) ? (value as KycResult) : "match";
}

/** Reads the test setting on each check, so it can be flipped in the emulator UI. */
export class FakeKycProvider implements KycProvider {
  readonly kind = "fake";

  constructor(private readonly setting: () => Promise<KycResult>) {}

  async check(): Promise<KycOutcome> {
    const result = await this.setting();
    return {
      provider: this.kind,
      result,
      score: result === "match" ? 0.99 : result === "no_match" ? 0.12 : null,
      reference: null,
    };
  }
}

export interface ValifyConfig {
  enabled: boolean;
  baseUrl: string;
  username: string;
  clientId: string;
  /** Secret Manager: VALIFY_CLIENT_SECRET. */
  clientSecret: string;
  /** Secret Manager: VALIFY_PASSWORD. */
  password: string;
  bundleKey: string;
}

/**
 * STUB. Planned calls once the contract and API documentation arrive:
 * 1. OAuth token (client credentials) from `${baseUrl}`.
 * 2. Egyptian national ID OCR on the front and back images; keep only
 *    "valid document" and the expiry date, discard every other field.
 * 3. Face match of the selfie against the ID photo; keep the score.
 * 4. Liveness: Valify's SDK runs on the phone (planned with the contract);
 *    the two selfies stay as evidence for the reviewer until then.
 * Requests and responses must never be logged (they hold ID data).
 */
export class ValifyKycProvider implements KycProvider {
  readonly kind = "valify";

  constructor(private readonly config: ValifyConfig) {}

  isConfigured(): boolean {
    const c = this.config;
    return c.enabled && [c.baseUrl, c.username, c.clientId, c.clientSecret, c.password, c.bundleKey].every((v) => v.length > 0);
  }

  async check(): Promise<KycOutcome> {
    if (!this.isConfigured()) {
      throw new KycNotConfiguredError("Valify is not configured (VALIFY_ENABLED and credentials).");
    }
    // Not implemented until the contract: fail closed so a person reviews.
    throw new KycNotConfiguredError("Valify integration is not implemented yet.");
  }
}

export interface KycFactoryOptions {
  provider: string;
  appEnv: string;
  fakeSetting: () => Promise<KycResult>;
  valify: ValifyConfig;
}

export function createKycProvider(options: KycFactoryOptions): KycProvider {
  if (options.provider === "valify") return new ValifyKycProvider(options.valify);
  if (options.provider !== "fake") throw new KycNotConfiguredError(`Unknown KYC provider "${options.provider}".`);
  if (options.appEnv === "prod") throw new KycNotConfiguredError("The fake KYC provider is not allowed in prod.");
  return new FakeKycProvider(options.fakeSetting);
}

/** Runs the check; any failure becomes result "error" (manual review). */
export async function runKyc(
  provider: KycProvider,
  images: () => Promise<KycImages>,
  onError: (error: unknown) => void,
): Promise<KycOutcome> {
  try {
    return await provider.check(images);
  } catch (error) {
    onError(error);
    return { provider: provider.kind, result: "error", score: null, reference: null };
  }
}
