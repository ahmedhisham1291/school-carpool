// KycProvider (F18): fake answers from the test setting, Valify stub stays closed. Run: npm test.
import { strict as assert } from "node:assert";
import { describe, it } from "node:test";
import {
  asKycResult,
  createKycProvider,
  FakeKycProvider,
  KycNotConfiguredError,
  runKyc,
  ValifyKycProvider,
  type KycImages,
  type KycResult,
  type ValifyConfig,
} from "../src/verification/kyc";

const valifyOff: ValifyConfig = {
  enabled: false,
  baseUrl: "",
  username: "",
  clientId: "",
  clientSecret: "",
  password: "",
  bundleKey: "",
};

const noImages = async (): Promise<KycImages> => {
  throw new Error("images must not be loaded by the fake");
};

describe("FakeKycProvider", () => {
  for (const result of ["match", "no_match", "error"] as KycResult[]) {
    it(`answers ${result} from the test setting without loading images`, async () => {
      const provider = new FakeKycProvider(async () => result);
      const outcome = await provider.check();
      assert.equal(outcome.result, result);
      assert.equal(outcome.provider, "fake");
      assert.equal((await runKyc(provider, noImages, () => assert.fail("no error"))).result, result);
    });
  }

  it("unknown or missing settings mean match", () => {
    assert.equal(asKycResult(undefined), "match");
    assert.equal(asKycResult("maybe"), "match");
    assert.equal(asKycResult("no_match"), "no_match");
  });
});

describe("createKycProvider", () => {
  it("gives the fake in dev and refuses it in prod", () => {
    const options = { provider: "fake", appEnv: "dev", fakeSetting: async () => "match" as const, valify: valifyOff };
    assert.equal(createKycProvider(options).kind, "fake");
    assert.throws(() => createKycProvider({ ...options, appEnv: "prod" }), KycNotConfiguredError);
    assert.throws(() => createKycProvider({ ...options, provider: "other" }), KycNotConfiguredError);
  });

  it("Valify is a closed stub: the check fails and runKyc turns it into error for manual review", async () => {
    const provider = createKycProvider({ provider: "valify", appEnv: "prod", fakeSetting: async () => "match", valify: valifyOff });
    assert.ok(provider instanceof ValifyKycProvider);
    assert.equal((provider as ValifyKycProvider).isConfigured(), false);
    const errors: unknown[] = [];
    const outcome = await runKyc(provider, noImages, (e) => errors.push(e));
    assert.equal(outcome.result, "error");
    assert.equal(errors.length, 1);
    assert.ok(errors[0] instanceof KycNotConfiguredError);
  });
});
