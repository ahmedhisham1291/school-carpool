import { adminDb } from "../admin";
import {
  KYC_PROVIDER,
  VALIFY_BASE_URL,
  VALIFY_BUNDLE_KEY,
  VALIFY_CLIENT_ID,
  VALIFY_CLIENT_SECRET_NAME,
  VALIFY_ENABLED,
  VALIFY_PASSWORD_NAME,
  VALIFY_USERNAME,
} from "../config";
import { createKycProvider, type FaceMatcher, type KycFactoryOptions } from "./kyc";
import { readFakeKycSetting } from "./store";

/** The Valify settings of the project (the same for the ID check and every face match). */
export function valifyOptions(): KycFactoryOptions["valify"] {
  return {
    enabled: VALIFY_ENABLED.value(),
    baseUrl: VALIFY_BASE_URL.value(),
    username: VALIFY_USERNAME.value(),
    clientId: VALIFY_CLIENT_ID.value(),
    clientSecret: process.env[VALIFY_CLIENT_SECRET_NAME] ?? "",
    password: process.env[VALIFY_PASSWORD_NAME] ?? "",
    bundleKey: VALIFY_BUNDLE_KEY.value(),
  };
}

/**
 * The face match behind KycProvider (Prompt 12 review): the project's
 * provider and Valify settings, as for the ID check. Built when a match
 * runs, so a bad setting (e.g. the fake provider in prod) fails that match
 * only; callers treat any failure as "error" and FAIL CLOSED (new phone:
 * the check stays; phone change: refused; random driver check: reviewed).
 */
export function faceMatcher(): FaceMatcher {
  return {
    matchFace: (reference, live) => {
      const kyc = createKycProvider({
        provider: KYC_PROVIDER.value(),
        appEnv: process.env.APP_ENV ?? "dev",
        fakeSetting: () => readFakeKycSetting(adminDb()),
        valify: valifyOptions(),
      }) as unknown as FaceMatcher;
      return kyc.matchFace(reference, live);
    },
  };
}
