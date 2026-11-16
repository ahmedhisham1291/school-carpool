/**
 * The exact texts of the sensitive-data consents (R3), per version and
 * language, as the app shows them (lib/l10n/app_ar.arb, app_en.arb: the
 * keys in CONSENT_TEXT_KEYS, joined by a blank line). The server hashes
 * the text the parent read into the consent record and shows it in the
 * parent's copy. A test (test/signature.test.ts) fails when the ARB files
 * and this file differ: change both, and raise the version.
 */

export const CONSENT_TEXT_KEYS = {
  transferAbroad: ["termsAcceptTransfer", "termsTransferText"],
  id: ["verifyConsentIdLabel", "verifyConsentIdHelper"],
  face: ["verifyConsentFaceLabel", "verifyConsentFaceHelper"],
  childData: ["verifyGuardianLabel", "verifyGuardianHelper"],
} as const;

export type SignedConsentType = keyof typeof CONSENT_TEXT_KEYS;

/** type -> version -> language -> text. */
export const CONSENT_TEXTS: Readonly<Record<string, Readonly<Record<string, { ar: string; en: string }>>>> = {
  transferAbroad: {
    "2026-11-17": {
      ar: "أوافق على التخزين خارج مصر\n\nتُخزَّن بياناتك على خوادم Google Cloud في بلجيكا (الاتحاد الأوروبي). وتعالج الشركات التالية جزءًا منها لحسابنا خارج مصر: Google (‏Firebase والخرائط، وVertex AI لأسماء المدارس العامة فقط)، وMeta (رموز الدخول والتنبيهات عبر واتساب)، ومزوّد المحادثات، وAlgolia (البحث عن المدارس بلا هوية)، وSentry (تقارير الأعطال بعد حذف البيانات الشخصية)، ومزوّد البريد الإلكتروني، وValify (التحقق من الهوية) عند تفعيله. وتلتزم كل منها بحماية بياناتك بمستوى لا يقل عما يتطلبه القانون المصري. ويتم النقل وفق قانون حماية البيانات الشخصية رقم 151 لسنة 2020 وترخيص مركز حماية البيانات الشخصية. لا يعمل التطبيق دون هذه الموافقة، وسحبها يعني حذف حسابك.",
      en: "I agree to storage abroad\n\nYour data is stored on Google Cloud servers in Belgium (European Union). These companies also process some of it for us outside Egypt: Google (Firebase, Maps, and Vertex AI for public school names only), Meta (WhatsApp sign-in codes and alerts), the chat provider, Algolia (school search, no identity), Sentry (error reports with personal data removed), our email provider and, once it is switched on, Valify (the ID check). Each must protect your data at least as well as Egyptian law requires. Transfers follow Egypt's Personal Data Protection Law No. 151 of 2020 and the licence of its Personal Data Protection Centre. The app cannot work without this consent; withdrawing it means deleting your account.",
    },
  },
  id: {
    "2026-11-17": {
      ar: "أوافق على فحص البطاقة\n\nأوافق صراحةً وكتابةً على معالجة بطاقة الرقم القومي (صورتا الوجهين؛ ويُحفظ الرقم رمزًا مشفّرًا فقط مع تاريخ الانتهاء) للتحقق مني. تُحفظ ما دام حسابي مفتوحًا وتُحذف عند حذفه. سحب الموافقة يغلق الحساب.",
      en: "I agree to the ID check\n\nI give my explicit written consent to process my national ID (photos of both sides; the number is kept only as a coded hash, with the expiry date) to verify me. Kept while my account is open and deleted when I delete it. Withdrawing it closes the account.",
    },
  },
  face: {
    "2026-11-17": {
      ar: "أوافق على مطابقة الوجه\n\nأوافق صراحةً وكتابةً على معالجة صور وجهي (بيانات بيومترية): تُقارن صورة السيلفي بصورة البطاقة وتُحفظ مرجعًا لفحص السيلفي قبل المشاوير. تُحفظ ما دام حسابي مفتوحًا وتُحذف عند حذفه. سحب الموافقة يغلق الحساب.",
      en: "I agree to face matching\n\nI give my explicit written consent to process my face images (biometric data): my selfie is compared with my ID photo and kept as the reference for selfie checks before runs. Kept while my account is open and deleted when I delete it. Withdrawing it closes the account.",
    },
  },
  childData: {
    "2026-11-17": {
      ar: "أنا الوالد أو الولي\n\nأقرّ بأنني الوالد أو الولي القانوني للأطفال الذين أضيفهم، وأوافق صراحةً وكتابةً على معالجة بياناتهم (الاسم الأول والسن والصف والمدرسة وصورة كارنيه المدرسة) ومكانهم أثناء المشاوير، فقط لتنظيم مشاويرهم المدرسية وحمايتها. يمكنني سحب ذلك بحذف الأطفال.",
      en: "I am the parent or guardian\n\nI declare that I am the parent or legal guardian of the children I add, and I give my explicit written consent to process their details (first name, age, grade, school, school ID photo) and where they are during runs, only to organise and protect their school runs. I can withdraw this by removing the children.",
    },
  },
};

/** The text of [type] at [version] in [language], or null (an older, unsigned version). */
export function consentText(type: string, version: string, language: "ar" | "en"): string | null {
  return CONSENT_TEXTS[type]?.[version]?.[language] ?? null;
}
