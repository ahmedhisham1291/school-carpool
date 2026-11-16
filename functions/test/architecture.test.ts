// Architecture rules for Cloud Functions (docs/architecture/overview.md).
// Static checks over the source files; no Firebase needed. Run: npm test.
import { strict as assert } from "node:assert";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { describe, it } from "node:test";

// Compiled to lib/test/, so the sources are two folders up from __dirname.
const ROOT = join(__dirname, "..", "..");
const SRC = join(ROOT, "src");

function tsFiles(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) out.push(...tsFiles(path));
    else if (name.endsWith(".ts")) out.push(path);
  }
  return out.sort();
}

const files = tsFiles(SRC).map((path) => ({ path, rel: relative(SRC, path).replace(/\\/g, "/"), text: readFileSync(path, "utf8") }));

/** The callable factories: onCall and the gates of privacy/device_gate.ts and features/gate.ts. */
const FACTORIES = ["onCall", "gatedCall", "gatedCallAlsoClosedDemo", "realParentCall", "sessionCall", "realParentSessionCall"];
const FEATURE_FACTORIES = ["featureGatedCall", "featureSessionCall"];
/** Files that define a factory: their `options` parameter is checked at every call site instead. */
const FACTORY_FILES = new Set(["privacy/device_gate.ts", "features/gate.ts"]);

/** The argument text at [start] up to the next top-level comma or closing parenthesis. */
function argumentAt(text: string, start: number): string {
  let depth = 0;
  for (let i = start; i < text.length; i++) {
    const c = text[i];
    if (c === "(" || c === "{" || c === "[") depth++;
    else if (c === ")" || c === "}" || c === "]") {
      if (depth === 0) return text.slice(start, i).trim();
      depth--;
    } else if (c === "," && depth === 0) return text.slice(start, i).trim();
  }
  return text.slice(start).trim();
}

/** True when the options expression [arg] in [text] sets enforceAppCheck (directly, by a const or by a spread). */
function setsAppCheck(arg: string, text: string, seen = new Set<string>()): boolean {
  if (arg.startsWith("{")) {
    if (/\benforceAppCheck\b/.test(arg)) return true;
    return [...arg.matchAll(/\.\.\.(\w+)/g)].some((m) => setsAppCheck(m[1], text, seen));
  }
  const ident = /^\w+$/.exec(arg)?.[0];
  if (!ident || seen.has(ident)) return false;
  seen.add(ident);
  const decl = new RegExp(`(?:const|let) ${ident}(?:\\s*:\\s*[^=]+)? = `).exec(text);
  if (!decl) {
    // Imported from a sibling module (schedule/callables.ts uses the carpool options).
    const from = new RegExp(`import \\{[^}]*\\b${ident}\\b[^}]*\\} from "\\.\\./([\\w/]+)"`).exec(text);
    const source = from ? files.find((f) => f.rel === `${from[1]}.ts`) : undefined;
    return source ? setsAppCheck(ident, source.text, new Set()) : false;
  }
  return setsAppCheck(argumentAt(text, decl.index + decl[0].length), text, seen);
}

describe("architecture: callables", () => {
  it("every callable sets enforceAppCheck (CLAUDE.md, SECURITY)", () => {
    const missing: string[] = [];
    let checked = 0;
    for (const f of files) {
      const names = [...FACTORIES, ...FEATURE_FACTORIES].join("|");
      for (const m of f.text.matchAll(new RegExp(`(?<![\\w.])(${names})(?:<[^>(]*>)?\\(`, "g"))) {
        // Skip the definitions ("function gatedCall<T>(options: ...").
        const before = f.text.slice(Math.max(0, m.index - 9), m.index);
        if (before.endsWith("function ")) continue;
        let start = m.index + m[0].length;
        if (FEATURE_FACTORIES.includes(m[1])) {
          const key = argumentAt(f.text, start);
          start = f.text.indexOf(",", start + key.length) + 1;
        }
        const arg = argumentAt(f.text, start);
        if (FACTORY_FILES.has(f.rel) && arg === "options") continue;
        checked++;
        if (!setsAppCheck(arg, f.text)) {
          const line = f.text.slice(0, m.index).split("\n").length;
          missing.push(`${f.rel}:${line} ${m[1]}(${arg.slice(0, 40)})`);
        }
      }
    }
    assert.ok(checked > 100, `found only ${checked} callables; the scan is broken`);
    assert.deepEqual(missing, [], "callables without enforceAppCheck");
  });

  // chat/callables.ts is rewritten by the chat-review-safe branch (Firestore chat);
  // it moves to runCallable there or right after that merge.
  const OWN_RUN_ALLOWED = new Set(["chat/callables.ts"]);

  it("handlers map errors with common/callable.ts runCallable, not their own try/catch", () => {
    const own = files
      .filter((f) => f.rel !== "common/callable.ts" && !OWN_RUN_ALLOWED.has(f.rel))
      .filter((f) => /async function run<T>\(name: string, body: \(\) => Promise<T>\)/.test(f.text))
      .map((f) => f.rel);
    assert.deepEqual(own, []);
  });

  it("flows and models stay free of Firebase (testable with in-memory stores)", () => {
    const bad = files
      .filter((f) => /(^|\/)(flow|model)\.ts$/.test(f.rel))
      .filter((f) => /from "(firebase-admin[^"]*|firebase-functions[^"]*|\.\.?\/admin)"/.test(f.text))
      .map((f) => f.rel);
    assert.deepEqual(bad, []);
  });
});

describe("architecture: collection names", () => {
  // Ratchet: string literals in .collection("...") calls. New code uses the
  // named constant of the owning store (for example USERS in auth/accounts.ts).
  // Lower a number when you replace literals; never raise one.
  const LITERAL_BUDGET: Record<string, number> = {
    "auth/blocking.ts": 2,
    "auth/callables.ts": 1,
    "auth/consents.ts": 1,
    "auth/review_demo_job.ts": 1,
    "notifications/store.ts": 1,
    "privacy/callables.ts": 10,
    "privacy/device_gate.ts": 1,
    "privacy/firestore_store.ts": 62,
    "verification/store.ts": 2,
    "wallet/firestore_store.ts": 1,
  };

  it("no new collection-name literals", () => {
    const over: string[] = [];
    for (const f of files) {
      const count = [...f.text.matchAll(/\b(?:collection|collectionGroup)\("[A-Za-z_]+"\)/g)].length;
      const budget = LITERAL_BUDGET[f.rel] ?? 0;
      if (count > budget) over.push(`${f.rel}: ${count} literals (budget ${budget})`);
    }
    assert.deepEqual(over, []);
  });

  it("every top-level collection in firestore.rules is named somewhere in the code", () => {
    const rules = readFileSync(join(ROOT, "..", "firestore.rules"), "utf8");
    const topLevel = [...rules.matchAll(/^ {4}match \/([A-Za-z_]+)\//gm)].map((m) => m[1]);
    const code = files.map((f) => f.text).join("\n");
    // Closed to everyone and written by no Cloud Function: schoolReview is the
    // AI review cache of tools/import_schools/ai_review.py; scheduleEvents is
    // Prompt 7's old alert queue, kept closed (firestore.rules).
    const notInFunctions = new Set(["schoolReview", "scheduleEvents"]);
    const unknown = [...new Set(topLevel)].filter((name) => !notInFunctions.has(name) && !code.includes(`"${name}"`));
    assert.deepEqual(unknown, [], "rules for collections the code never names (a typo or dead rule?)");
  });

  it("every name in the app's lib/firebase/collections.dart has a rule in firestore.rules", () => {
    const rules = readFileSync(join(ROOT, "..", "firestore.rules"), "utf8");
    const dart = readFileSync(join(ROOT, "..", "lib", "firebase", "collections.dart"), "utf8");
    const collections = dart.slice(dart.indexOf("class Collections"), dart.indexOf("class Docs"));
    const names = [...collections.matchAll(/static const String \w+ = '([A-Za-z_]+)';/g)].map((m) => m[1]);
    assert.ok(names.length > 20, "collections.dart was not read");
    const missing = names.filter((name) => !new RegExp(`match /${name}/`).test(rules));
    assert.deepEqual(missing, [], "the app names a collection that firestore.rules does not open (or a typo)");
  });
});
