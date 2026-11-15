/**
 * Removes personal data before anything leaves Cloud Functions for an
 * outside service (Sentry today). Mirrors lib/observability/pii_scrubber.dart
 * in the app; keep the two in step.
 *
 * PRIVACY rule: never send phone numbers, national ID numbers, images,
 * coordinates or message text. Errs on the side of removing too much.
 */

export const REDACTED = "[redacted]";

const SENSITIVE_KEYS = new Set<string>([
  // phone numbers
  "phone", "phonenumber", "mobile", "msisdn", "tel", "whatsapp",
  // national ID and documents
  "nationalid", "nid", "idnumber", "nationalidnumber", "ssn", "passport", "licensenumber",
  "plate", "platenumber",
  // coordinates and addresses
  "lat", "lng", "lon", "latitude", "longitude", "coords", "coordinates", "location",
  "geo", "geopoint", "position", "address", "homeaddress", "pickuppoint",
  // InstaPay address (F45)
  "instapayaddress", "ipa",
  // message text
  "text", "message", "messagetext", "body", "content", "note", "comment",
  // contact and names
  "email", "firstname", "lastname", "fullname", "displayname",
  // credentials
  "password", "otp", "code", "token", "idtoken", "accesstoken", "authorization", "cookie",
  "cookies", "headers",
  // images
  "image", "photo", "selfie", "imagedata", "bytes",
]);

// Digits: ASCII, Arabic-Indic and Extended Arabic-Indic.
const D = "[0-9\\u0660-\\u0669\\u06F0-\\u06F9]";
const EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
/** An InstaPay address (F45, "name@instapay"): no dot after the "@", so EMAIL does not catch it. */
const INSTAPAY = /[A-Za-z0-9._-]+@instapay/gi;
const COORDINATE_PAIR = new RegExp(`-?${D}{1,3}[.٫]${D}{2,}\\s*[,،]?\\s*-?${D}{1,3}[.٫]${D}{2,}`, "g");
const PRECISE_DECIMAL = new RegExp(`-?${D}{1,3}[.٫]${D}{4,}`, "g");
const LONG_NUMBER = new RegExp(`(?:\\+|00)?${D}(?:[\\s\\-.]?${D}){6,}`, "g");

export function scrubString(input: string): string {
  if (!input) return input;
  return input
    .replace(EMAIL, REDACTED)
    .replace(INSTAPAY, REDACTED)
    .replace(COORDINATE_PAIR, REDACTED)
    .replace(PRECISE_DECIMAL, REDACTED)
    .replace(LONG_NUMBER, REDACTED);
}

export function isSensitiveKey(key: string): boolean {
  return SENSITIVE_KEYS.has(key.toLowerCase().replace(/[_\-\s]/g, ""));
}

/** Deep-cleans any JSON-like value. Returns a new value; input is untouched. */
export function scrubValue(value: unknown, depth = 0): unknown {
  if (depth > 8) return REDACTED;
  if (value === null || value === undefined) return value;
  if (typeof value === "string") return scrubString(value);
  if (typeof value === "number" || typeof value === "boolean") return value;
  if (value instanceof Uint8Array) return REDACTED; // raw bytes, e.g. an image
  if (Array.isArray(value)) return value.map((item) => scrubValue(item, depth + 1));
  if (typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
      out[key] = isSensitiveKey(key) ? REDACTED : scrubValue(item, depth + 1);
    }
    return out;
  }
  return REDACTED;
}

function scrubMechanism(mechanism: unknown): unknown {
  if (typeof mechanism !== "object" || mechanism === null) return mechanism;
  const m = { ...(mechanism as Record<string, unknown>) };
  if (m.data !== undefined) m.data = scrubValue(m.data, 1);
  if (typeof m.description === "string") m.description = scrubString(m.description);
  return m;
}

function scrubStacktrace(stacktrace: unknown): unknown {
  if (typeof stacktrace !== "object" || stacktrace === null) return stacktrace;
  const st = { ...(stacktrace as Record<string, unknown>) };
  if (Array.isArray(st.frames)) {
    st.frames = st.frames.map((f) => {
      if (typeof f !== "object" || f === null) return f;
      const frame = { ...(f as Record<string, unknown>) };
      // Local variable values never leave (they may be a phone or a message).
      delete frame.vars;
      return frame;
    });
  }
  return st;
}

/**
 * Prompt 12: the feature area of a function, as a Sentry tag, so the owner
 * gets an alert on NEW errors in sign-in, trips and the wallet (Sentry
 * alert rules, SETUP.md 23.6). Function names only; never request data.
 */
export function areaOf(functionName: string): "signin" | "trips" | "wallet" | "privacy" | "other" {
  const n = functionName.toLowerCase().replace(/[^a-z]/g, "");
  if (/^(requestcode|verifycode|confirmemail|acceptconsents|block|touchdevice|confirmnewdevice|signoutdevice|listdevices)/.test(n)) return "signin";
  if (/(trip|handover|selfiecheck|emergency|todaydrivercards|quickmessage|routeonarchive|archiveroute)/.test(n)) return "trips";
  if (/(wallet|money|transfer|lookupparentid)/.test(n)) return "wallet";
  if (/(privacy|exportmydata|deletemyaccount|retention|consent|photo)/.test(n)) return "privacy";
  return "other";
}

/**
 * Cleans a Sentry event or breadcrumb. Keeps Sentry's structural fields
 * (ids, levels, timestamps, stack frames) and drops request data and every
 * user field except the opaque account id.
 */
export function scrubEvent<T extends object>(event: T): T {
  const copy = { ...(event as Record<string, unknown>) };
  const user = copy.user as { id?: unknown } | undefined;
  copy.user = user && user.id !== undefined ? { id: user.id } : undefined;
  delete copy.request;
  delete copy.server_name;

  for (const key of ["message", "transaction", "culprit"]) {
    if (typeof copy[key] === "string") copy[key] = scrubString(copy[key] as string);
  }
  for (const key of ["extra", "tags", "data", "contexts"]) {
    if (copy[key] !== undefined) copy[key] = scrubValue(copy[key], 1);
  }
  // A device or computer name often holds a person's name ("Hoda's iPhone").
  const device = (copy.contexts as Record<string, unknown> | undefined)?.device;
  if (typeof device === "object" && device !== null) delete (device as Record<string, unknown>).name;
  if (Array.isArray(copy.breadcrumbs)) {
    copy.breadcrumbs = copy.breadcrumbs.map((b) => scrubEvent(b as object));
  }
  const exception = copy.exception as { values?: Array<Record<string, unknown>> } | undefined;
  if (exception?.values) {
    copy.exception = {
      ...exception,
      values: exception.values.map((v) => ({
        ...v,
        value: typeof v.value === "string" ? scrubString(v.value) : v.value,
        // Prompt 12 (Prompt 1 item 11): the mechanism's data and the local
        // variables of stack frames can hold request values.
        ...(v.mechanism !== undefined ? { mechanism: scrubMechanism(v.mechanism) } : {}),
        ...(v.stacktrace !== undefined ? { stacktrace: scrubStacktrace(v.stacktrace) } : {}),
      })),
    };
  }
  const logentry = copy.logentry as { message?: unknown; params?: unknown } | undefined;
  if (logentry) {
    copy.logentry = {
      message: typeof logentry.message === "string" ? scrubString(logentry.message) : undefined,
    };
  }
  return copy as T;
}
