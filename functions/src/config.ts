import { defineBoolean, defineInt, defineSecret, defineString } from "firebase-functions/params";

/**
 * Region of every function. Must match kFunctionsRegion in
 * lib/firebase/firebase_setup.dart. Hosting abroad in europe-west1 is
 * confirmed by the lawyer (docs/DECISIONS.md, 14 Nov 2026).
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
export const ENFORCE_APP_CHECK_PARAM = defineBoolean("ENFORCE_APP_CHECK", { default: true });

/**
 * The enforceAppCheck option every callable passes. firebase-functions'
 * onCall resolves an Expression with `.value()` as soon as the function is
 * defined (src/v2/providers/https.ts in firebase/firebase-functions, read
 * 16 Nov 2026), and `.value()` logs three "invoked during function
 * deployment" warnings per callable while `firebase deploy` loads the code
 * (FUNCTIONS_CONTROL_API=true): hundreds of lines in the deploy log.
 * enforceAppCheck is not part of the deploy manifest (it only configures
 * the request handler), so during deploy a plain `true` is passed and
 * nothing is resolved; at runtime the parameter itself, resolved by the
 * library exactly as before.
 */
export function appCheckOption<P>(param: P, env: NodeJS.ProcessEnv = process.env): P | boolean {
  return env.FUNCTIONS_CONTROL_API === "true" ? true : param;
}

export const ENFORCE_APP_CHECK = appCheckOption(ENFORCE_APP_CHECK_PARAM);

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

/**
 * Key for the keyed hash of national ID numbers (Secret Manager). Separate
 * from OTP_HMAC_KEY: the ban list depends on it forever, so it must never
 * be rotated without re-hashing. In the local emulators a fixed dev key is
 * used when functions/.secret.local does not set it.
 */
export const NATIONAL_ID_HMAC_KEY = defineSecret("NATIONAL_ID_HMAC_KEY");

/** "fake" (answer from config/kyc.fakeResult; refused in prod) or "valify". */
export const KYC_PROVIDER = defineString("KYC_PROVIDER", { default: "fake" });

/** Valify stays off until the contract (COST MODE: fake provider until the pilot). */
export const VALIFY_ENABLED = defineBoolean("VALIFY_ENABLED", { default: false });
export const VALIFY_BASE_URL = defineString("VALIFY_BASE_URL", { default: "" });
export const VALIFY_USERNAME = defineString("VALIFY_USERNAME", { default: "" });
export const VALIFY_CLIENT_ID = defineString("VALIFY_CLIENT_ID", { default: "" });
export const VALIFY_BUNDLE_KEY = defineString("VALIFY_BUNDLE_KEY", { default: "" });
/**
 * Valify secrets. Declared but not bound to any function until the
 * contract, so deploys do not need them to exist in Secret Manager.
 */
export const VALIFY_CLIENT_SECRET_NAME = "VALIFY_CLIENT_SECRET";
export const VALIFY_PASSWORD_NAME = "VALIFY_PASSWORD";

/**
 * Codes per IP address per hour. High because Egyptian mobile carriers put
 * many users behind one address; a param so it can change per project.
 */
export const OTP_MAX_SENDS_PER_IP = defineInt("OTP_MAX_SENDS_PER_IP", { default: 60 });

/**
 * Wrong codes for one number per day across all devices before the number
 * is closed for the rest of that day (review 2, N1). Devices where the
 * number signed in before are not closed by it (otp_flow.ts).
 */
export const OTP_MAX_FAILURES_PER_DAY = defineInt("OTP_MAX_FAILURES_PER_DAY", { default: 30 });

/** Which X-Forwarded-For entry is the client, counted from the end (auth/client_ip.ts). */
export const CLIENT_IP_HOP = defineInt("CLIENT_IP_HOP", { default: 1 });

/**
 * Admin panel user searches per admin per 10 minutes (F14). Searches are
 * rate limited so nobody can sweep the user list.
 */
export const ADMIN_SEARCH_LIMIT = defineInt("ADMIN_SEARCH_LIMIT", { default: 30 });

/**
 * School search (F4). "fake" (dev and CI: the app searches the emulator's
 * schools itself, nothing is sent to Algolia) or "algolia". COST MODE:
 * Algolia's free Build plan; see docs/COSTS.md.
 */
export const SCHOOL_SEARCH_PROVIDER = defineString("SCHOOL_SEARCH_PROVIDER", { default: "fake" });
/** Algolia application ID (not a secret). */
export const ALGOLIA_APP_ID = defineString("ALGOLIA_APP_ID", { default: "" });
/** One index per project (schools_dev, schools_staging, schools). */
export const ALGOLIA_INDEX = defineString("ALGOLIA_INDEX", { default: "schools" });
/** Key with addObject and deleteObject on the schools index only (Secret Manager). */
export const ALGOLIA_WRITE_KEY = defineSecret("ALGOLIA_WRITE_KEY");
/**
 * Search-only key limited to the schools index (Secret Manager). Never sent
 * to the app: the app gets a one-hour secured key derived from it.
 */
export const ALGOLIA_SEARCH_KEY = defineSecret("ALGOLIA_SEARCH_KEY");

/**
 * Maps (Prompt 5: F21 to F24). Limits per parent, counted on the server
 * (spec section 7: nobody can sweep the map).
 */
export const MAP_HOME_MOVES_PER_DAY = defineInt("MAP_HOME_MOVES_PER_DAY", { default: 4 });
export const MAP_NEARBY_SEARCHES_PER_HOUR = defineInt("MAP_NEARBY_SEARCHES_PER_HOUR", { default: 30 });
export const MAP_PLACE_SEARCHES_PER_HOUR = defineInt("MAP_PLACE_SEARCHES_PER_HOUR", { default: 60 });
export const MAP_PLACE_DETAILS_PER_HOUR = defineInt("MAP_PLACE_DETAILS_PER_HOUR", { default: 20 });
/** Low on purpose: driving schools decide whose maps a parent can open. */
export const MAP_DRIVING_SCHOOL_CHANGES_PER_DAY = defineInt("MAP_DRIVING_SCHOOL_CHANGES_PER_DAY", { default: 3 });

/**
 * Address search (Places API New). "fake" (dev and CI: a few fixed
 * places, no key, no cost) or "google". COST MODE: docs/COSTS.md.
 */
export const PLACES_PROVIDER = defineString("PLACES_PROVIDER", { default: "fake" });
/**
 * Server key with only "Places API (New)" allowed (Secret Manager). Never
 * sent to the app. The app's map keys are separate (SETUP.md section 15).
 */
export const MAPS_SERVER_KEY = defineSecret("MAPS_SERVER_KEY");

/**
 * Carpools (Prompt 6: F5, F6, F26, F31, F32). Limits per parent, counted on
 * the server in carpoolLimits/{uid}.
 */
export const CARPOOL_CREATES_PER_DAY = defineInt("CARPOOL_CREATES_PER_DAY", { default: 3 });
export const CARPOOL_SEARCHES_PER_HOUR = defineInt("CARPOOL_SEARCHES_PER_HOUR", { default: 30 });
export const CARPOOL_JOIN_REQUESTS_PER_DAY = defineInt("CARPOOL_JOIN_REQUESTS_PER_DAY", { default: 10 });
export const CARPOOL_INVITES_PER_DAY = defineInt("CARPOOL_INVITES_PER_DAY", { default: 20 });
/** Low on purpose: invite codes must not be guessable by trying many. */
export const CARPOOL_INVITE_OPENS_PER_HOUR = defineInt("CARPOOL_INVITE_OPENS_PER_HOUR", { default: 20 });
export const CARPOOL_WANTED_SAVES_PER_DAY = defineInt("CARPOOL_WANTED_SAVES_PER_DAY", { default: 5 });
export const CARPOOL_WANTED_LISTS_PER_HOUR = defineInt("CARPOOL_WANTED_LISTS_PER_HOUR", { default: 30 });
/**
 * Start of invite links (F31), the Hosting site that serves
 * apple-app-site-association, for example https://<project>-links.web.app.
 * Set per project in functions/.env.<alias> (SETUP.md section 16).
 */
export const INVITE_LINK_BASE = defineString("INVITE_LINK_BASE", { default: "https://demo-school-carpool-links.web.app" });

/**
 * Schedule (Prompt 7: F7, F11, F27, F28, F30). Drivers confirm each run by
 * this Cairo time on the evening before (F28); a run planned or released
 * after that gets SCHEDULE_LATE_LEAD_MIN minutes before it starts. With no
 * confirmed driver by then every parent is alerted (spec section 6).
 */
export const SCHEDULE_CONFIRM_BY = defineString("SCHEDULE_CONFIRM_BY", { default: "21:00" });
export const SCHEDULE_LATE_LEAD_MIN = defineInt("SCHEDULE_LATE_LEAD_MIN", { default: 60 });
export const SCHEDULE_PLANS_PER_DAY = defineInt("SCHEDULE_PLANS_PER_DAY", { default: 20 });
export const SCHEDULE_CHANGES_PER_DAY = defineInt("SCHEDULE_CHANGES_PER_DAY", { default: 100 });

/**
 * Notifications (Prompt 8: F12, F23). "fake" (dev and CI: pushes are logged,
 * nothing is sent; refused in prod) or "fcm". FCM is free.
 */
export const PUSH_PROVIDER = defineString("PUSH_PROVIDER", { default: "fake" });
/** A critical alert still unread after this many minutes sounds the alarm (spec section 11). */
export const NOTIFY_ALARM_DELAY_MIN = defineInt("NOTIFY_ALARM_DELAY_MIN", { default: 15 });
/** Cairo time from which drivers get the "you drive tomorrow" reminder. */
export const REMINDER_EVENING_AT = defineString("REMINDER_EVENING_AT", { default: "19:00" });
/** Push token registrations and settings changes per parent per day. */
export const NOTIFY_DEVICE_CHANGES_PER_DAY = defineInt("NOTIFY_DEVICE_CHANGES_PER_DAY", { default: 30 });
export const NOTIFY_SETTINGS_CHANGES_PER_DAY = defineInt("NOTIFY_SETTINGS_CHANGES_PER_DAY", { default: 100 });

/**
 * Chat (Prompt 9: F8, F9, F10, F13) on Stream Chat. "fake" (dev without a
 * Stream app, and CI: nothing leaves Cloud Functions; the app uses its
 * on-phone fake chat; refused in prod) or "stream". COST MODE: Stream's
 * free Build plan, then Maker (docs/COSTS.md). One Stream app for dev and
 * staging with fake users only, a separate one for prod (SETUP.md 19).
 */
export const CHAT_PROVIDER = defineString("CHAT_PROVIDER", { default: "fake" });
/** Stream app key (public: the app needs it to connect). */
export const STREAM_API_KEY = defineString("STREAM_API_KEY", { default: "" });
/**
 * Stream app secret (Secret Manager). Signs chat tokens and server calls
 * and verifies the webhook. Never sent to the app.
 */
export const STREAM_API_SECRET = defineSecret("STREAM_API_SECRET");
/** Chat token lifetime. Short, so a suspended parent's phone is cut off soon even offline. */
export const CHAT_TOKEN_TTL_MIN = defineInt("CHAT_TOKEN_TTL_MIN", { default: 60 });
/** Chat token requests per parent per hour (the app refreshes about once an hour). */
export const CHAT_TOKENS_PER_HOUR = defineInt("CHAT_TOKENS_PER_HOUR", { default: 30 });
/** New private chat requests per parent per day (spec section 5). */
export const CHAT_REQUESTS_PER_DAY = defineInt("CHAT_REQUESTS_PER_DAY", { default: 10 });
/** Reports per parent per day. */
export const CHAT_REPORTS_PER_DAY = defineInt("CHAT_REPORTS_PER_DAY", { default: 20 });
/** Blocks, mutes and settings changes per parent per day. */
export const CHAT_CHANGES_PER_DAY = defineInt("CHAT_CHANGES_PER_DAY", { default: 100 });

/**
 * Trips (Prompt 10: F15, F16, F20, F29, F33, F34, F35, F38, F41).
 * "fake" (dev and CI: straight-line arrival times, no key, no cost; refused
 * in prod) or "google" (Routes API with MAPS_SERVER_KEY, which must also
 * allow "Routes API"). COST MODE: docs/COSTS.md.
 */
export const ROUTES_PROVIDER = defineString("ROUTES_PROVIDER", { default: "fake" });
/** Traffic-aware arrival times (spec section 6). Off uses the cheaper Essentials request. */
export const ROUTES_TRAFFIC = defineBoolean("ROUTES_TRAFFIC", { default: true });
/** No live point for this many seconds: parents and driver get "location stopped". */
export const TRIP_STALE_SEC = defineInt("TRIP_STALE_SEC", { default: 120 });
/** F38: percent of runs that ask the driver for a live selfie first. */
export const TRIP_SELFIE_PERCENT = defineInt("TRIP_SELFIE_PERCENT", { default: 20 });
/** F34: minutes the receiving parent has to confirm an afternoon drop-off. */
export const TRIP_HANDOVER_MIN = defineInt("TRIP_HANDOVER_MIN", { default: 10 });

/**
 * Wallet (Prompt 11B: F43, F44). "fake" (dev and staging: test money in
 * Firestore, refused in prod) or "partner" (the CBE-licensed partner,
 * stubbed until the contract: it refuses every call while
 * WALLET_PARTNER_ENABLED is false). Limits are server settings in
 * config/wallet (wallet/model.ts), not params, so they change without a
 * deploy. COST MODE: fake until the pilot (docs/COSTS.md).
 */
export const WALLET_PROVIDER = defineString("WALLET_PROVIDER", { default: "fake" });
export const WALLET_PARTNER_ENABLED = defineBoolean("WALLET_PARTNER_ENABLED", { default: false });
/**
 * Warm instances for the wallet functions (CLAUDE.md STACK names the
 * wallet). COST MODE: 0 by default; raise in functions/.env.<alias>.
 */
export const MIN_INSTANCES_WALLET = defineInt("MIN_INSTANCES_WALLET", { default: 0 });

/**
 * Trust (Prompt 11, F17, spec sections 3 and 6). Ratings: a parent may rate
 * another parent they shared a finished trip with in the last
 * TRUST_RATE_WINDOW_DAYS, once per pair each month.
 * Yearly check: every school year starts on SCHOOL_YEAR_START ("MM-DD",
 * Cairo); parents confirm their children from YEAR_CHECK_OPEN_DAYS before
 * it until YEAR_CHECK_GRACE_DAYS after it; after that they get no new
 * driving days until they confirm. YEAR_CHECK_FIRST_YEAR is the first
 * school year that is checked (2027 = the 2027-28 year), so parents who
 * verified before the pilot are not blocked at once; set it to the current
 * year to try the check on the emulators. Driving papers: reminders
 * LICENCE_REMINDER_DAYS before the earlier expiry ("30,7,1").
 */
export const TRUST_RATE_WINDOW_DAYS = defineInt("TRUST_RATE_WINDOW_DAYS", { default: 30 });
export const SCHOOL_YEAR_START = defineString("SCHOOL_YEAR_START", { default: "09-01" });
export const YEAR_CHECK_OPEN_DAYS = defineInt("YEAR_CHECK_OPEN_DAYS", { default: 21 });
export const YEAR_CHECK_GRACE_DAYS = defineInt("YEAR_CHECK_GRACE_DAYS", { default: 14 });
export const YEAR_CHECK_FIRST_YEAR = defineInt("YEAR_CHECK_FIRST_YEAR", { default: 2027 });
export const LICENCE_REMINDER_DAYS = defineString("LICENCE_REMINDER_DAYS", { default: "30,7,1" });

/**
 * Settle up by InstaPay (F45, the pilot's payment feature). The app only
 * records payment requests between two parents of one carpool; it never
 * moves, holds or sees money. Limits per parent, counted on the server in
 * settleUpLimits/{uid}. The largest amount of one record is a server
 * setting (config/settleUp.maxAmount in piastres, default EGP 5,000), not
 * a param, so it changes without a deploy.
 */
export const SETTLE_UP_REQUESTS_PER_DAY = defineInt("SETTLE_UP_REQUESTS_PER_DAY", { default: 20 });
/** "I paid", "Received", "Not received", cancel, decline and reports per parent per day. */
export const SETTLE_UP_CHANGES_PER_DAY = defineInt("SETTLE_UP_CHANGES_PER_DAY", { default: 100 });
/** Low on purpose: an InstaPay address rarely changes. */
export const SETTLE_UP_ADDRESS_CHANGES_PER_DAY = defineInt("SETTLE_UP_ADDRESS_CHANGES_PER_DAY", { default: 5 });
/** How often a payer may open payees' addresses per hour (nobody collects addresses). */
export const SETTLE_UP_ADDRESS_VIEWS_PER_HOUR = defineInt("SETTLE_UP_ADDRESS_VIEWS_PER_HOUR", { default: 30 });
/** "Not received" marks after which either side may report the record to the admins. */
export const SETTLE_UP_REPORT_AFTER = defineInt("SETTLE_UP_REPORT_AFTER", { default: 2 });
