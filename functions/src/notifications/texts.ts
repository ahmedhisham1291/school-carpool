import type { Language } from "../whatsapp/sender";
import { TYPES, type NotificationType } from "./catalog";

/**
 * Push text per type, in Arabic and English (the recipient's language).
 * The only variable part is {when}: a weekday, a date and the run direction
 * ("Sun 16 Nov, to school"). No names, no addresses, no message text
 * (spec section 7). The WhatsApp templates (SETUP.md section 18) carry the
 * same body with {{1}} for {when}.
 */

export interface PushText {
  title: string;
  body: string;
}

type Texts = Record<Exclude<NotificationType, "critical-alarm">, { ar: PushText; en: PushText }>;

const t = (arTitle: string, arBody: string, enTitle: string, enBody: string) => ({
  ar: { title: arTitle, body: arBody },
  en: { title: enTitle, body: enBody },
});

export const TEXTS: Readonly<Texts> = {
  "plan-ready": t("خطة الأسبوع جاهزة", "راجع مشاويرك هذا الأسبوع.", "Week planned", "Check your runs this week."),
  "no-driver": t(
    "لا يوجد سائق مؤكد",
    "لا يوجد سائق لمشوار {when}. يرجى توصيل طفلك بنفسك.",
    "No driver confirmed",
    "No driver for {when}. Please take your own child.",
  ),
  "swap-requested": t("طلب تبديل", "عضو طلب تبديل مشوار {when}.", "Swap request", "A member asked for a swap: {when}."),
  "swap-accepted": t("سائق جديد", "مشوار {when} له سائق جديد.", "New driver", "The {when} run has a new driver."),
  "swap-cancelled": t("أُلغي التبديل", "أُلغي طلب تبديل مشوار {when}.", "Swap cancelled", "The swap for {when} was taken back."),
  "run-taken": t("سائق جديد", "مشوار {when} له سائق الآن.", "New driver", "The {when} run has a driver now."),
  "child-absent": t("غياب طفل", "طفل لن يركب مشوار {when}.", "Child absent", "A child is away for the {when} run."),
  "child-back": t("عودة طفل", "طفل سيركب مشوار {when} مرة أخرى.", "Child back", "A child is back for the {when} run."),
  "driver-unavailable": t("مشوار بلا سائق", "مشوار {when} يحتاج سائقًا.", "Run needs a driver", "The {when} run needs a driver."),
  "schedule-changed": t("تغيّر الجدول", "تغيّرت الإجازات أو المواعيد في مشوارك.", "Schedule changed", "Days off or times changed in your carpool."),
  "time-changed": t("موعد جديد", "مشوار {when} له موعد جديد. راجع الخطة.", "New run time", "The {when} run has a new time. Check the plan."),
  "drive-evening": t("تقود غدًا", "أنت سائق مشوار {when}.", "You drive tomorrow", "You drive the {when} run."),
  "drive-hour": t("مشوارك بعد قليل", "مشوار {when} يبدأ خلال ساعة.", "Run within the hour", "Your {when} run starts within the hour."),
  "confirm-reminder": t("أكّد القيادة", "يرجى تأكيد مشوار {when} قبل الموعد.", "Confirm your drive", "Please confirm the {when} run before the deadline."),
  "join-requested": t("طلب انضمام", "ولي أمر طلب الانضمام إلى مشوارك.", "Join request", "A parent asked to join your carpool."),
  "join-approved": t("تم قبول طلبك", "أصبحت عضوًا في المشوار.", "Request approved", "You are now in the carpool."),
  "join-declined": t("لم يُقبل طلبك", "لم يُقبل طلب انضمامك.", "Request declined", "Your request to join was declined."),
  "verification-approved": t("تمت الموافقة", "تمت الموافقة على مستنداتك.", "Documents approved", "Your documents were approved."),
  "verification-rejected": t("لم تتم الموافقة", "افتح التطبيق لمعرفة ما يلزم تصحيحه.", "Not approved", "Open the app to see what to fix."),
  "new-parent": t("ولي أمر جديد قريب", "ولي أمر موثّق جديد قرب مدرستك.", "New parent nearby", "A new verified parent near your school."),
  "child-not-confirmed": t(
    "لم يُؤكَّد الاستلام",
    "لم يُؤكَّد وصول طفل. يرجى التحقق الآن.",
    "Child not confirmed",
    "A drop-off was not confirmed. Please check now.",
  ),
  "chat-message": t("رسالة جديدة", "لديك رسالة جديدة.", "New message", "You have a new message."),
};

const WEEKDAYS: Record<Language, string[]> = {
  en: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
  ar: ["الأحد", "الاثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت"],
};
const MONTHS: Record<Language, string[]> = {
  en: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
  ar: ["يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو", "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر"],
};
const DIRECTIONS: Record<Language, Record<string, string>> = {
  en: { toSchool: "to school", toHome: "home" },
  ar: { toSchool: "للمدرسة", toHome: "للبيت" },
};

/**
 * "Sun 16 Nov, to school" / "الأحد 16 نوفمبر، للمدرسة". Only a checked
 * date (YYYY-MM-DD) and a known direction get in: nothing else can reach
 * the text. Empty when there is no date.
 */
export function whenText(date: string | null, direction: string | null, language: Language): string {
  const m = date ? /^(\d{4})-(\d{2})-(\d{2})$/.exec(date) : null;
  if (!m) return "";
  const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
  if (Number.isNaN(d.getTime())) return "";
  const day = `${WEEKDAYS[language][d.getUTCDay()]} ${d.getUTCDate()} ${MONTHS[language][d.getUTCMonth()]}`;
  const dir = direction ? DIRECTIONS[language][direction] : undefined;
  if (!dir) return day;
  return language === "ar" ? `${day}، ${dir}` : `${day}, ${dir}`;
}

/** Title and body of [type] for one recipient. */
export function pushText(type: NotificationType, language: Language, when: string): PushText {
  if (type === "critical-alarm") throw new Error("critical-alarm uses the text of the alert it repeats");
  const text = TEXTS[type][language];
  if (!TYPES[type].hasWhen) return { ...text };
  // A run without a date (should not happen) still reads well.
  const fallback = language === "ar" ? "اليوم" : "today";
  return { title: text.title, body: text.body.replace("{when}", when || fallback) };
}
