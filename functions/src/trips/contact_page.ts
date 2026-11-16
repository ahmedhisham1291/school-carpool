import type { ContactStatus } from "./model";

/**
 * R6: the emergency contact's page (/ec/<token>), Arabic first, then
 * English. Shows only the parent's first name and the two choices. Pure;
 * unit-tested (test/trips.test.ts).
 */

function escapeHtml(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

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
    ar = `<p>شكرًا. أنت جهة الطوارئ لـ ${name}. ستصلك رسالة واتساب فقط إذا ضغط زر الطوارئ أثناء مشوار مدرسي.</p><p><a href="/ec/${safeToken}/stop">إيقاف الرسائل</a></p>`;
    en = `<p>Thank you. You are ${nameEn}'s emergency contact. You get a WhatsApp message only if they press the emergency button during a school run.</p><p><a href="/ec/${safeToken}/stop">Stop messages</a></p>`;
  } else {
    ar = `<p>${name} أضافك جهةً للطوارئ في تطبيق «مشوار المدرسة». إذا ضغط زر الطوارئ أثناء مشوار مدرسي تصلك رسالة واتساب باسمه الأول والموقع. لا نستخدم رقمك لأي شيء آخر.</p><p><a href="/ec/${safeToken}/yes">أوافق</a> · <a href="/ec/${safeToken}/stop">لا أريد هذه الرسائل</a></p>`;
    en = `<p>${nameEn} added you as their emergency contact in the School Carpool app. If they press the emergency button during a school run, you get a WhatsApp message with their first name and the location. We use your number for nothing else.</p><p><a href="/ec/${safeToken}/yes">I agree</a> · <a href="/ec/${safeToken}/stop">I don't want these messages</a></p>`;
  }
  return `<!DOCTYPE html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex"><title>مشوار المدرسة · School Carpool</title><style>body{font-family:system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem;line-height:1.6;color:#1b1f23}a{color:#00695c;font-weight:600}section+section{border-top:1px solid #ddd;margin-top:1.5rem;padding-top:1rem}</style></head><body><section>${ar}</section><section dir="ltr" lang="en">${en}</section></body></html>`;
}
