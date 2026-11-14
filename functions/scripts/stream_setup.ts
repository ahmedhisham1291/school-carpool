/**
 * Sets up a Stream Chat app for School Carpool (Prompt 9, SETUP.md 19).
 * Run once per Stream app (dev, then prod) and again after changing
 * src/chat/setup_plan.ts. It is safe to run twice.
 *
 *   STREAM_API_KEY=... STREAM_API_SECRET=... WEBHOOK_URL=https://<region>-<project>.cloudfunctions.net/chatWebhook \
 *     npm --prefix functions run chat:setup
 *
 * What it does:
 * 1. checks every permission our grants use exists in this app (refuses
 *    to go on otherwise, so a typo can never open a right by accident);
 * 2. the blocked terms lists (Arabic, English);
 * 3. the four channel types: who may do what (parents create no channel
 *    and add no member), photos and read receipts per kind, Stream push off;
 * 4. the system user that creates every channel;
 * 5. the webhook to our chatWebhook (new messages) and Stream push off;
 * 6. app-level grants: parents cannot update their own Stream user (name,
 *    parent ID) or list users; read back, refuses to finish otherwise;
 * 7. the AI moderation policy for text and images (needs Stream's
 *    moderation product; fails unless --no-moderation is given).
 *
 * The secret comes from the environment only (never a file in the repo).
 * Prints step names and Stream's error codes only.
 */
import { signJwt } from "../src/chat/server";
import { allChannelTypeSettings, APP_GRANTS, appGrantProblems, BLOCKLISTS, FORBIDDEN_FOR_PARENTS, moderationPolicy, SYSTEM_USER } from "../src/chat/setup_plan";

const BASE = "https://chat.stream-io-api.com";
const key = process.env.STREAM_API_KEY ?? "";
const secret = process.env.STREAM_API_SECRET ?? "";
const webhookUrl = process.env.WEBHOOK_URL ?? "";
// Only for a Stream app without the moderation product (dev): moderation off is then accepted.
const noModeration = process.argv.includes("--no-moderation");

function refuse(reason: string): never {
  console.error(`chat:setup: ${reason}`);
  process.exit(1);
}

if (!key || !secret) refuse("set STREAM_API_KEY and STREAM_API_SECRET (from the Stream dashboard)");
if (webhookUrl && !/^https:\/\/[^\s]+\/chatWebhook$/.test(webhookUrl)) refuse("WEBHOOK_URL must be the https URL of the chatWebhook function");

async function call(method: string, path: string, body?: unknown): Promise<{ ok: boolean; status: number; json: Record<string, unknown> }> {
  const sep = path.includes("?") ? "&" : "?";
  const res = await fetch(`${BASE}${path}${sep}api_key=${encodeURIComponent(key)}`, {
    method,
    headers: { Authorization: signJwt({ server: true }, secret), "stream-auth-type": "jwt", "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = ((await res.json().catch(() => ({}))) ?? {}) as Record<string, unknown>;
  return { ok: res.ok, status: res.status, json };
}

function report(step: string, r: { ok: boolean; status: number; json: Record<string, unknown> }): boolean {
  if (r.ok) console.log(`ok    ${step}`);
  else console.error(`FAIL  ${step}: HTTP ${r.status}${typeof r.json.code === "number" ? ` code ${r.json.code}` : ""} ${typeof r.json.message === "string" ? r.json.message : ""}`);
  return r.ok;
}

async function main(): Promise<void> {
  const types = allChannelTypeSettings();

  // 1. Every permission we grant must exist; parents never get a forbidden one.
  const perms = await call("GET", "/permissions");
  if (!report("list permissions", perms)) process.exit(1);
  const known = new Set(((perms.json.permissions as Array<{ id?: string }>) ?? []).map((p) => p.id ?? ""));
  for (const t of types) {
    for (const [role, ids] of Object.entries(t.grants)) {
      for (const id of ids) {
        if (!known.has(id)) refuse(`${t.name}/${role}: unknown permission "${id}"`);
        if ((role === "user" || role === "channel_member") && FORBIDDEN_FOR_PARENTS.includes(id)) refuse(`${t.name}/${role}: "${id}" must not be granted`);
      }
    }
  }

  // 2. Blocked terms.
  for (const b of BLOCKLISTS) {
    const exists = await call("GET", `/blocklists/${b.name}`);
    const r = exists.ok
      ? await call("PUT", `/blocklists/${b.name}`, { words: [...b.words] })
      : await call("POST", "/blocklists", { name: b.name, words: [...b.words], type: "word" });
    if (!report(`blocklist ${b.name} (${b.words.length} terms)`, r)) process.exit(1);
  }

  // 3. Channel types.
  for (const t of types) {
    const exists = await call("GET", `/channeltypes/${t.name}`);
    const { name, ...settings } = t;
    const r = exists.ok ? await call("PUT", `/channeltypes/${name}`, settings) : await call("POST", "/channeltypes", t);
    if (!report(`channel type ${name}`, r)) process.exit(1);
  }

  // 4. System user (creates every channel; no person).
  if (!report("system user", await call("POST", "/users", { users: { [SYSTEM_USER.id]: SYSTEM_USER } }))) process.exit(1);

  // 5. Webhook (new messages) and no Stream push.
  if (webhookUrl) {
    const r = await call("PATCH", "/app", { webhook_url: webhookUrl, webhook_events: ["message.new"], push_config: { version: "v2" } });
    if (!report("webhook", r)) process.exit(1);
  } else {
    console.log("skip  webhook (set WEBHOOK_URL after the first deploy and run again)");
  }

  // 6. App-level grants: parents may not change their own profile (name,
  // parent ID) or list users. Read back and refuse to finish otherwise.
  if (!report("app-level grants", await call("PATCH", "/app", { grants: APP_GRANTS }))) process.exit(1);
  const app = await call("GET", "/app");
  if (!report("read app settings", app)) process.exit(1);
  const appJson = (app.json.app ?? {}) as Record<string, unknown>;
  const problems = appGrantProblems(appJson.grants);
  if (problems.length > 0) refuse(`parents still have app-level rights: ${problems.join(", ")}`);

  // 7. AI moderation for text and images (Stream moderation product).
  const mod = await call("POST", "/api/v2/moderation/config", moderationPolicy());
  if (!report("moderation policy (text and images)", mod)) {
    console.error("      Turn on Moderation for this app in the Stream dashboard and run again (SETUP.md 19.4). The blocklists above already apply.");
    if (!noModeration) refuse("moderation is not on (run with --no-moderation only for a dev app without it)");
  }
  console.log("done");
}

main().catch((error: unknown) => {
  console.error("chat:setup failed:", error instanceof Error ? error.message : "unknown");
  process.exit(1);
});
