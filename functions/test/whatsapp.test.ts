// WhatsApp senders (fake and Meta Cloud API). Run: npm test.
import { strict as assert } from "node:assert";
import { describe, it } from "node:test";
import { FakeWhatsAppSender, MetaWhatsAppSender, createWhatsAppSender, type MetaConfig } from "../src/whatsapp/sender";

const meta: MetaConfig = {
  accessToken: "token-123",
  phoneNumberId: "555000",
  apiVersion: "v25.0",
  templateName: "login_code",
  templateLanguages: { ar: "ar", en: "en_US" },
};

describe("FakeWhatsAppSender", () => {
  it("logs the code with the phone number masked", async () => {
    const lines: string[] = [];
    await new FakeWhatsAppSender((line) => lines.push(line)).sendCode("+201012345678", "482913", "ar");
    assert.equal(lines.length, 1);
    assert.ok(lines[0].includes("482913"));
    assert.ok(!lines[0].includes("1012345678"), lines[0]);
    assert.ok(!/\d{5,}/.test(lines[0].replace("482913", "")), lines[0]);
  });
});

describe("MetaWhatsAppSender", () => {
  it("builds an authentication template message with the code in body and button", () => {
    const { url, init } = new MetaWhatsAppSender(meta).buildRequest("+201012345678", "482913", "en");
    assert.equal(url, "https://graph.facebook.com/v25.0/555000/messages");
    assert.equal(init.headers.Authorization, "Bearer token-123");
    const body = JSON.parse(init.body);
    assert.equal(body.to, "201012345678");
    assert.equal(body.type, "template");
    assert.equal(body.template.name, "login_code");
    assert.equal(body.template.language.code, "en_US");
    assert.deepEqual(body.template.components[0], { type: "body", parameters: [{ type: "text", text: "482913" }] });
    assert.deepEqual(body.template.components[1], {
      type: "button",
      sub_type: "url",
      index: "0",
      parameters: [{ type: "text", text: "482913" }],
    });
  });

  it("throws on an error answer without echoing the number", async () => {
    const fakeFetch = (async () =>
      new Response(JSON.stringify({ error: { code: 131026, message: "to +201012345678" } }), { status: 400 })) as typeof fetch;
    await assert.rejects(new MetaWhatsAppSender(meta, fakeFetch).sendCode("+201012345678", "1", "ar"), (error: Error) => {
      assert.ok(error.message.includes("HTTP 400"));
      assert.ok(error.message.includes("131026"));
      assert.ok(!error.message.includes("1012345678"));
      return true;
    });
  });

  it("resolves on a 200 answer", async () => {
    const fakeFetch = (async () => new Response("{}", { status: 200 })) as typeof fetch;
    await new MetaWhatsAppSender(meta, fakeFetch).sendCode("+201012345678", "1", "ar");
  });
});

describe("MetaWhatsAppSender timeout", () => {
  it("gives up when the Graph API does not answer in time", async () => {
    const hangingFetch = ((_url: string, init?: { signal?: AbortSignal }) =>
      new Promise<Response>((_resolve, reject) => {
        // AbortSignal.timeout does not keep Node alive; this timer does.
        const keepAlive = setTimeout(() => reject(new Error("no abort")), 5000);
        init?.signal?.addEventListener("abort", () => {
          clearTimeout(keepAlive);
          reject(new Error("aborted"));
        });
      })) as unknown as typeof fetch;
    await assert.rejects(new MetaWhatsAppSender(meta, hangingFetch, 20).sendCode("+201012345678", "1", "ar"), /aborted/);
  });
});

describe("createWhatsAppSender", () => {
  const log = () => undefined;
  it("returns the fake sender in dev and staging", () => {
    assert.equal(createWhatsAppSender({ provider: "fake", appEnv: "dev", meta }, log).kind, "fake");
    assert.equal(createWhatsAppSender({ provider: "fake", appEnv: "staging", meta }, log).kind, "fake");
  });
  it("refuses the fake sender in prod", () => {
    assert.throws(() => createWhatsAppSender({ provider: "fake", appEnv: "prod", meta }, log), /not allowed in prod/);
  });
  it("needs a token and phone number ID for Meta", () => {
    assert.equal(createWhatsAppSender({ provider: "meta", appEnv: "prod", meta }, log).kind, "meta");
    assert.throws(() => createWhatsAppSender({ provider: "meta", appEnv: "prod", meta: { ...meta, accessToken: "" } }, log));
  });
  it("refuses an unknown provider", () => {
    assert.throws(() => createWhatsAppSender({ provider: "sms", appEnv: "dev", meta }, log), /Unknown/);
  });
});
