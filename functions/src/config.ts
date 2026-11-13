import { defineBoolean, defineInt, defineSecret, defineString } from "firebase-functions/params";

/**
 * Region of every function. Must match kFunctionsRegion in
 * lib/firebase/firebase_setup.dart. Open question for the owner and the
 * lawyer (hosting abroad); see docs/progress/prompt-01.md.
 */
export const REGION = "europe-west1";

/**
 * COST MODE: no warm instances by default. Raise per environment in
 * functions/.env.<alias> when cold starts hurt sign-in, alerts or the wallet.
 */
export const MIN_INSTANCES = defineInt("MIN_INSTANCES", { default: 0 });

/** Hard cap so a bug or abuse cannot scale the bill. */
export const MAX_INSTANCES = 10;

/** App Check on callable functions. On in staging and prod. */
export const ENFORCE_APP_CHECK = defineBoolean("ENFORCE_APP_CHECK", { default: true });

/** Allows the debugTestError callable (dev and staging only). */
export const ENABLE_TEST_ERROR = defineBoolean("ENABLE_TEST_ERROR", { default: false });

/**
 * Warm instances for the sign-in functions (requestCode, verifyCode).
 * COST MODE: 0 by default; raise in functions/.env.<alias> if cold starts
 * make sign-in slow (docs/COSTS.md).
 */
export const MIN_INSTANCES_SIGNIN = defineInt("MIN_INSTANCES_SIGNIN", { default: 0 });

/**
 * Key for the keyed hashes of codes, phone numbers, device IDs and IPs
 * (Secret Manager). In the local emulators a fixed dev key is used when
 * functions/.secret.local does not set it (auth/callables.ts).
 */
export const OTP_HMAC_KEY = defineSecret("OTP_HMAC_KEY");

/** WhatsApp Cloud API access token (Secret Manager). Unused with the fake sender. */
export const WHATSAPP_ACCESS_TOKEN = defineSecret("WHATSAPP_ACCESS_TOKEN");

/** "fake" (prints codes to the log; refused in prod) or "meta". */
export const WHATSAPP_PROVIDER = defineString("WHATSAPP_PROVIDER", { default: "fake" });
/** WhatsApp Business phone number ID from Meta (not a secret). */
export const WHATSAPP_PHONE_NUMBER_ID = defineString("WHATSAPP_PHONE_NUMBER_ID", { default: "none" });
export const WHATSAPP_API_VERSION = defineString("WHATSAPP_API_VERSION", { default: "v25.0" });
/** Name of the approved authentication template that carries the code. */
export const WHATSAPP_CODE_TEMPLATE = defineString("WHATSAPP_CODE_TEMPLATE", { default: "login_code" });
export const WHATSAPP_TEMPLATE_LANG_AR = defineString("WHATSAPP_TEMPLATE_LANG_AR", { default: "ar" });
export const WHATSAPP_TEMPLATE_LANG_EN = defineString("WHATSAPP_TEMPLATE_LANG_EN", { default: "en" });
