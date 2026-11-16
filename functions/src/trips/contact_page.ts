import type { ContactStatus } from "./model";

/**
 * R6: the emergency contact's page (/ec/<token>), Arabic first, then
 * English. Shows only the parent's first name and the two choices. Pure;
 * unit-tested (test/trips.test.ts).
 */

function escapeHtml(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

/**
 * An answer is a POST from a button on the page (never a GET link): link
 * previews, mail scanners and browser prefetch only ever GET, so they can
 * never confirm or stop for the contact.
 */
function button(token: string, action: "yes" | "stop", label: string): string {
  return `<form method="post" action="/ec/${token}/${action}"><button type="submit">${label}</button></form>`;
}

/**
 * What a request to /ec/** asks for. GET (and HEAD) only shows the page,
 * whatever the path; POST /ec/<token>/yes or /stop answers. Anything else:
 * null (405).
 */
export function contactRequest(method: string, path: string): { token: string | undefined; answer: "view" | "yes" | "stop" } | null {
  const parts = path.split("/").filter((p) => p.length > 0);
  const at = parts.indexOf("ec");
  const token = at >= 0 ? parts[at + 1] : undefined;
  const action = at >= 0 ? parts[at + 2] : undefined;
  if (method === "GET" || method === "HEAD") return { token, answer: "view" };
  if (method !== "POST") return null;
  return { token, answer: action === "yes" ? "yes" : action === "stop" ? "stop" : "view" };
}

/**
 * A small fixed-window limit kept in the function instance's memory: per
 * client address and for the whole instance (with maxInstances 5 this caps
 * the Firestore reads an attacker can cause). Tokens are 256-bit, so this
 * guards cost, not guessing.
 */
export class WindowLimiter {
  private windowStart = 0;
  private total = 0;
  private readonly perKey = new Map<string, number>();

  constructor(
    private readonly perKeyMax: number,
    private readonly totalMax: number,
    private readonly windowMs = 60_000,
  ) {}

  take(key: string, nowMs: number): boolean {
    if (nowMs - this.windowStart >= this.windowMs) {
      this.windowStart = nowMs;
      this.total = 0;
      this.perKey.clear();
    }
    const used = this.perKey.get(key) ?? 0;
    if (used >= this.perKeyMax || this.total >= this.totalMax) return false;
    this.perKey.set(key, used + 1);
    this.total += 1;
    return true;
  }
}

/** Response headers of the page: no caching, no framing, no referrer (the token is in the URL), nothing loaded from elsewhere. */
export const CONTACT_PAGE_HEADERS: Readonly<Record<string, string>> = {
  "Cache-Control": "no-store",
  "Content-Type": "text/html; charset=utf-8",
  "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
  "X-Robots-Tag": "noindex",
};

export function contactReplyPage(r: { found: boolean; status: ContactStatus; parentFirstName: string }, token: string): string {
  const name = escapeHtml(r.parentFirstName || "ولي أمر");
  const nameEn = escapeHtml(r.parentFirstName || "A parent");
  const safeToken = /^[0-9a-f]{64}$/.test(token) ? token : "";
  let ar: string;
  let en: string;
  if (!r.found || !safeToken) {
    ar = "<p>هذا الرابط غير صالح.</p>";
    en = "<p>This link is not valid.</p>";
  } else if (r.status === "stopped") {
    ar = "<p>تم. لن تصلك رسائل أخرى من «مشوار المدرسة» بخصوص هذا الشخص.</p>";
    en = "<p>Done. You will get no more messages from School Carpool about this person.</p>";
  } else if (r.status === "confirmed") {
    ar = `<p>شكرًا. أنت جهة الطوارئ لـ ${name}. ستصلك رسالة واتساب فقط إذا ضغط زر الطوارئ أثناء مشوار مدرسي.</p>${button(safeToken, "stop", "إيقاف الرسائل")}`;
    en = `<p>Thank you. You are ${nameEn}'s emergency contact. You get a WhatsApp message only if they press the emergency button during a school run.</p>${button(safeToken, "stop", "Stop messages")}`;
  } else {
    ar = `<p>${name} أضافك جهةً للطوارئ في تطبيق «مشوار المدرسة». إذا ضغط زر الطوارئ أثناء مشوار مدرسي تصلك رسالة واتساب باسمه الأول والموقع. لا نستخدم رقمك لأي شيء آخر.</p>${button(safeToken, "yes", "أوافق")}${button(safeToken, "stop", "لا أريد هذه الرسائل")}`;
    en = `<p>${nameEn} added you as their emergency contact in the School Carpool app. If they press the emergency button during a school run, you get a WhatsApp message with their first name and the location. We use your number for nothing else.</p>${button(safeToken, "yes", "I agree")}${button(safeToken, "stop", "I don't want these messages")}`;
  }
  return `<!DOCTYPE html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex"><title>مشوار المدرسة · School Carpool</title><style>body{font-family:system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem;line-height:1.6;color:#1b1f23}form{display:inline-block;margin:0 .5rem .5rem 0}button{font:inherit;font-weight:600;min-height:48px;padding:0 1rem;border-radius:8px;border:1px solid #00695c;background:#fff;color:#00695c;cursor:pointer}section+section{border-top:1px solid #ddd;margin-top:1.5rem;padding-top:1rem}</style></head><body><section>${ar}</section><section dir="ltr" lang="en">${en}</section></body></html>`;
}
