import { maskPhone } from "../auth/phone";

/**
 * WhatsApp is called only from Cloud Functions, through this interface
 * (CLAUDE.md STACK). Two implementations:
 * - FakeWhatsAppSender (dev, emulators, staging): sends nothing and prints the
 *   code in the function log with the phone number masked.
 * - MetaWhatsAppSender: the WhatsApp Business Platform (Cloud API), using an
 *   approved "authentication" template with a copy-code button.
 *
 * COST MODE: every template message is paid, so only codes and critical
 * alerts go through WhatsApp by default.
 */
export type Language = "ar" | "en";

export function asLanguage(value: unknown): Language {
  return value === "en" ? "en" : "ar";
}

export interface WhatsAppSender {
  readonly kind: "fake" | "meta";
  /** Sends a sign-in code. Throws when the message was not accepted. */
  sendCode(toE164: string, code: string, language: Language): Promise<void>;
}

export class FakeWhatsAppSender implements WhatsAppSender {
  readonly kind = "fake";

  constructor(private readonly log: (message: string) => void) {}

  async sendCode(toE164: string, code: string, language: Language): Promise<void> {
    // The code is printed on purpose (dev only, Prompt 2). The number is not.
    this.log(`[fake WhatsApp] sign-in code ${code} for ${maskPhone(toE164)} (${language}). Nothing was sent.`);
  }
}

export interface MetaConfig {
  /** System-user access token, from Secret Manager (WHATSAPP_ACCESS_TOKEN). */
  accessToken: string;
  /** WhatsApp Business phone number ID (not the phone number itself). */
  phoneNumberId: string;
  /** Graph API version, for example v25.0. */
  apiVersion: string;
  /** Name of the approved authentication template. */
  templateName: string;
  /** Template language code per app language, for example ar and en. */
  templateLanguages: Record<Language, string>;
}

export interface OutgoingRequest {
  url: string;
  init: { method: "POST"; headers: Record<string, string>; body: string };
}

export class MetaWhatsAppSender implements WhatsAppSender {
  readonly kind = "meta";

  constructor(
    private readonly config: MetaConfig,
    private readonly fetchFn: typeof fetch = fetch,
  ) {}

  /**
   * Request for an authentication template with a copy-code button: the
   * code goes in the body parameter and in the button parameter (Meta docs,
   * "Copy code authentication templates", Graph API v25.0).
   */
  buildRequest(toE164: string, code: string, language: Language): OutgoingRequest {
    const { apiVersion, phoneNumberId, templateName, templateLanguages, accessToken } = this.config;
    const body = {
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: toE164.replace(/^\+/, ""),
      type: "template",
      template: {
        name: templateName,
        language: { code: templateLanguages[language] },
        components: [
          { type: "body", parameters: [{ type: "text", text: code }] },
          { type: "button", sub_type: "url", index: "0", parameters: [{ type: "text", text: code }] },
        ],
      },
    };
    return {
      url: `https://graph.facebook.com/${apiVersion}/${encodeURIComponent(phoneNumberId)}/messages`,
      init: {
        method: "POST",
        headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
        body: JSON.stringify(body),
      },
    };
  }

  async sendCode(toE164: string, code: string, language: Language): Promise<void> {
    const { url, init } = this.buildRequest(toE164, code, language);
    const response = await this.fetchFn(url, init);
    if (response.ok) return;
    // Only Meta's numeric error codes go into the message: never the body,
    // which could echo the recipient.
    let detail = "";
    try {
      const parsed = (await response.json()) as { error?: { code?: unknown; error_subcode?: unknown } };
      detail = ` (error ${String(parsed.error?.code ?? "?")}/${String(parsed.error?.error_subcode ?? "-")})`;
    } catch {
      // Not JSON: keep the status only.
    }
    throw new Error(`WhatsApp Cloud API refused the message: HTTP ${response.status}${detail}`);
  }
}

export interface SenderSettings {
  /** WHATSAPP_PROVIDER: "fake" or "meta". */
  provider: string;
  /** APP_ENV: dev, staging or prod. */
  appEnv: string;
  meta: MetaConfig;
}

/** Picks the sender from config. The fake sender is refused in prod. */
export function createWhatsAppSender(settings: SenderSettings, log: (message: string) => void): WhatsAppSender {
  if (settings.provider === "fake") {
    if (settings.appEnv === "prod") {
      throw new Error("The fake WhatsApp sender is not allowed in prod (set WHATSAPP_PROVIDER=meta)");
    }
    return new FakeWhatsAppSender(log);
  }
  if (settings.provider === "meta") {
    if (!settings.meta.accessToken || !settings.meta.phoneNumberId) {
      throw new Error("WhatsApp is not configured: access token or phone number ID missing");
    }
    return new MetaWhatsAppSender(settings.meta);
  }
  throw new Error(`Unknown WHATSAPP_PROVIDER "${settings.provider}"`);
}
