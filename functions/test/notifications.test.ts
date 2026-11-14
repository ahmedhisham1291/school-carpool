import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";
import { NOTIFICATION_TYPES, routeFor, TYPES, WHATSAPP_DEFAULTS, WHATSAPP_GROUPS, type NotificationType } from "../src/notifications/catalog";
import { DeviceError, registerDevice, unregisterDevice, updateSettings, type DeviceDeps } from "../src/notifications/devices";
import { dispatchEvent, RetryableDispatchError, type DispatchDeps } from "../src/notifications/dispatch";
import {
  applySettingsChange,
  buildPush,
  buildRecord,
  defaultSettings,
  eventFromDoc,
  inQuietHours,
  MAX_ATTEMPTS,
  newEvent,
  settingsFrom,
  type OutboxEvent,
} from "../src/notifications/model";
import { NOTIFICATION_EVENTS } from "../src/notifications/outbox";
import { newParentEvent, verificationResultEvent } from "../src/notifications/producers";
import { createPushSender, FakePushSender, fcmMessage } from "../src/notifications/push";
import { TEXTS, whenText } from "../src/notifications/texts";
import { alarmEventId, dueReminders, reminderId, runNotificationTick, type RunLite } from "../src/notifications/tick";
import { SCHEDULE_EVENTS } from "../src/schedule/store";
import { cairoToUtcMs } from "../src/schedule/cairo";
import { FakeWhatsAppSender, MetaWhatsAppSender } from "../src/whatsapp/sender";
import { MemoryNotifyStore, RecordingPush, RecordingWhatsApp } from "./helpers/memory_notifications";

// Fake parents, children and places only.
const CHILD_NAMES = ["Adam", "Laila", "آدم", "ليلى"];
const PARENT_NAMES = ["Mona", "Hoda", "منى", "هدى"];
const ADDRESSES = ["Maadi", "Street 9", "المعادي", "شارع 9"];
const FORBIDDEN = [...CHILD_NAMES, ...PARENT_NAMES, ...ADDRESSES];

/** Sunday 15 Nov 2026, 10:00 Cairo (UTC+2 in winter). */
const NOON = cairoToUtcMs("2026-11-15", "10:00");

let store: MemoryNotifyStore;
let push: RecordingPush;
let whatsapp: RecordingWhatsApp;
let clock: { now: number };
let logs: string[];
let deps: DispatchDeps;

beforeEach(() => {
  store = new MemoryNotifyStore();
  push = new RecordingPush();
  whatsapp = new RecordingWhatsApp();
  clock = { now: NOON };
  logs = [];
  deps = { store, push, whatsapp, now: () => clock.now, log: (m, d) => logs.push(`${m} ${JSON.stringify(d ?? {})}`) };
  for (const uid of ["alice", "bob", "cara"]) store.addParent(uid);
});

function scheduleEvent(type: NotificationType, recipients: string[], extra: Partial<OutboxEvent> = {}): OutboxEvent {
  return newEvent(`e-${type}`, type, recipients, clock.now, { carpoolId: "k1", runId: "2026-11-16_am", date: "2026-11-16", direction: "toSchool", ...extra });
}

describe("catalog", () => {
  it("every type has a group, texts in both languages and a route; only no-driver and child-not-confirmed are critical", () => {
    for (const type of NOTIFICATION_TYPES) {
      assert.ok(TYPES[type], type);
      if (type !== "critical-alarm") {
        assert.ok(TEXTS[type].ar.title && TEXTS[type].en.title, type);
        assert.equal(TEXTS[type].en.body.includes("{when}"), TYPES[type].hasWhen, type);
        assert.equal(TEXTS[type].ar.body.includes("{when}"), TYPES[type].hasWhen, type);
      }
      assert.match(routeFor({ type, carpoolId: "k1" }), /^\/[a-z0-9/_-]*$/i);
    }
    const critical = NOTIFICATION_TYPES.filter((t) => TYPES[t].critical && t !== "critical-alarm");
    assert.deepEqual(critical, ["no-driver", "child-not-confirmed"]);
  });

  it("COST MODE: WhatsApp is on by default only for the critical alerts; chat is never WhatsApp", () => {
    const on = WHATSAPP_GROUPS.filter((g) => WHATSAPP_DEFAULTS[g]);
    assert.deepEqual(on, ["noDriver", "childNotConfirmed"]);
    assert.equal(TYPES["chat-message"].template, null);
  });

  it("routes open the right screen and never carry an odd carpool ID", () => {
    assert.equal(routeFor({ type: "swap-requested", carpoolId: "k1" }), "/carpools/k1/schedule");
    assert.equal(routeFor({ type: "join-requested", carpoolId: "k1" }), "/carpools/k1");
    assert.equal(routeFor({ type: "verification-rejected", carpoolId: null }), "/profile");
    assert.equal(routeFor({ type: "new-parent", carpoolId: null }), "/home/nearby");
    assert.equal(routeFor({ type: "swap-requested", carpoolId: "../x?y=1" }), "/notifications");
  });

  it("all producers write to the one outbox the sender listens to", () => {
    assert.equal(SCHEDULE_EVENTS, NOTIFICATION_EVENTS);
    assert.equal(NOTIFICATION_EVENTS, "notificationEvents");
  });
});

describe("dispatcher: routing", () => {
  it("writes one record per recipient, pushes each phone, never tells the actor", async () => {
    const summary = await dispatchEvent(deps, scheduleEvent("swap-requested", ["alice", "bob", "cara"], { actorUid: "alice" }));
    assert.equal(summary.recipients, 2);
    assert.deepEqual(store.recordsOf("alice"), []);
    assert.equal(store.recordsOf("bob").length, 1);
    assert.equal(store.recordsOf("cara").length, 1);
    assert.equal(push.sent.length, 2);
    assert.equal(store.marked.get("e-swap-requested")?.status, "done");
    const r = store.recordsOf("bob")[0];
    assert.equal(r.route, "/carpools/k1/schedule");
    assert.equal(r.readAtMs, null);
  });

  it("skips suspended, banned, missing and unverified parents (except for the verification result)", async () => {
    store.addParent("sam", { status: "suspended" });
    store.addParent("ben", { banned: true });
    store.addParent("una", { status: "pending" });
    await dispatchEvent(deps, scheduleEvent("plan-ready", ["sam", "ben", "una", "ghost", "bob"]));
    assert.deepEqual([...store.records.values()].map((r) => r.uid), ["bob"]);
    await dispatchEvent(deps, verificationResultEvent({ caseId: "c1", uid: "una", status: "rejected" }, clock.now));
    assert.equal(store.recordsOf("una")[0]?.type, "verification-rejected");
    assert.equal(store.recordsOf("una")[0]?.route, "/profile");
  });

  it("a parent with no phone registered still gets the in-app record", async () => {
    store.tokensByKey.delete("key-bob");
    await dispatchEvent(deps, scheduleEvent("plan-ready", ["bob"]));
    const r = store.recordsOf("bob")[0];
    assert.equal(r.push?.state, "skipped");
    assert.equal(r.push?.reason, "no-device");
  });

  it("tokens FCM refuses for good are removed", async () => {
    store.tokensByKey.set("key-bob-old", { uid: "bob", token: "old-token-aaaaaaaaaaaaaaaaaaaa", platform: "ios", updatedAtMs: 0 });
    push.dead.add("key-bob-old");
    await dispatchEvent(deps, scheduleEvent("plan-ready", ["bob"]));
    assert.equal(store.tokensByKey.has("key-bob-old"), false);
    assert.equal(store.tokensByKey.has("key-bob"), true);
    assert.equal(store.recordsOf("bob")[0].push?.state, "sent");
  });

  it("an old event is not sent any more", async () => {
    const e = scheduleEvent("plan-ready", ["bob"]);
    clock.now += 7 * 3_600_000;
    await dispatchEvent(deps, e);
    assert.equal(push.sent.length, 0);
    assert.equal(store.marked.get(e.id)?.status, "failed");
  });

  it("an unknown type in the outbox is dropped, a known one is read back", () => {
    assert.equal(eventFromDoc("x", { type: "launch-rockets" }, 0), null);
    const e = eventFromDoc("x", { type: "no-driver", recipients: ["a", 3, ""], critical: true, carpoolId: "k1" }, 5);
    assert.deepEqual(e?.recipients, ["a"]);
    assert.equal(e?.status, "pending");
    assert.equal(e?.createdAtMs, 5);
  });
});

describe("dispatcher: idempotent delivery", () => {
  it("the same event twice (a retried trigger) makes one record, one push and one WhatsApp per parent", async () => {
    const e = scheduleEvent("no-driver", ["bob", "cara"]);
    await dispatchEvent(deps, e);
    // The trigger fires again with the original (still "pending") snapshot.
    await dispatchEvent(deps, { ...e, status: "pending" });
    assert.equal(store.records.size, 2);
    assert.equal(push.sent.length, 2);
    assert.equal(whatsapp.sent.length, 2);
  });

  it("a push that failed is tried again on retry; the WhatsApp already sent is not", async () => {
    push.failures = 1;
    const e = scheduleEvent("no-driver", ["bob"]);
    await assert.rejects(dispatchEvent(deps, e), RetryableDispatchError);
    assert.equal(store.recordsOf("bob")[0].push?.state, "failed");
    assert.equal(whatsapp.sent.length, 1);
    assert.equal(store.marked.has(e.id), false, "stays pending for the retry");
    await dispatchEvent(deps, e);
    assert.equal(push.sent.length, 1);
    assert.equal(whatsapp.sent.length, 1);
    assert.equal(store.recordsOf("bob")[0].push?.attempts, 2);
    assert.equal(store.marked.get(e.id)?.status, "done");
  });

  it(`a channel is tried at most ${MAX_ATTEMPTS} times`, async () => {
    push.failures = 10;
    const e = scheduleEvent("plan-ready", ["bob"]);
    for (let i = 0; i < MAX_ATTEMPTS; i++) await assert.rejects(dispatchEvent(deps, e));
    await dispatchEvent(deps, e);
    assert.equal(store.recordsOf("bob")[0].push?.attempts, MAX_ATTEMPTS);
    assert.equal(push.failures, 10 - MAX_ATTEMPTS);
  });

  it("a channel claimed but never finished (a crash mid-send) is not sent again", async () => {
    const e = scheduleEvent("plan-ready", ["bob"]);
    await store.ensureRecord(buildRecord(e, "bob", clock.now, 900_000));
    await store.claim("bob", e.id, "push", clock.now, MAX_ATTEMPTS);
    await dispatchEvent(deps, e);
    assert.equal(push.sent.length, 0);
  });
});

describe("dispatcher: WhatsApp per group", () => {
  it("critical alerts go to WhatsApp by default; other types are push only", async () => {
    await dispatchEvent(deps, scheduleEvent("no-driver", ["bob"]));
    await dispatchEvent(deps, scheduleEvent("swap-requested", ["bob"]));
    assert.deepEqual(whatsapp.sent.map((w) => w.template), ["cp_no_driver"]);
    assert.deepEqual(whatsapp.sent[0].params, ["Mon 16 Nov, to school"]);
  });

  it("switching a group on sends its template; switching it off stops it", async () => {
    await store.saveSettings("bob", applySettingsChange(defaultSettings(), { whatsapp: { swaps: true, noDriver: false } }));
    await dispatchEvent(deps, scheduleEvent("swap-requested", ["bob"]));
    await dispatchEvent(deps, scheduleEvent("no-driver", ["bob"]));
    assert.deepEqual(whatsapp.sent.map((w) => w.template), ["cp_swap_requested"]);
    const r = store.recordsOf("bob").find((x) => x.type === "no-driver");
    assert.equal(r?.whatsapp, null);
    assert.equal(r?.push?.state, "sent", "the push still goes");
  });

  it("no WhatsApp without the parent's consent or a phone number; chat is push only even when everything is on", async () => {
    store.addParent("noconsent", { whatsappOptIn: false });
    store.addParent("nophone", { phone: null });
    await dispatchEvent(deps, scheduleEvent("no-driver", ["noconsent", "nophone"]));
    await dispatchEvent(deps, newEvent("chat-1", "chat-message", ["bob"], clock.now));
    assert.equal(whatsapp.sent.length, 0);
    assert.equal(push.sent.length, 3);
  });

  it("the WhatsApp message uses the parent's language", async () => {
    store.addParent("ar1", { language: "ar" });
    await dispatchEvent(deps, scheduleEvent("no-driver", ["ar1"]));
    assert.equal(whatsapp.sent[0].language, "ar");
    assert.deepEqual(whatsapp.sent[0].params, ["الاثنين 16 نوفمبر، للمدرسة"]);
  });
});

describe("dispatcher: quiet hours", () => {
  it("a normal alert at night is a silent push and no WhatsApp; a critical one sounds and goes to WhatsApp", async () => {
    clock.now = cairoToUtcMs("2026-11-15", "23:30");
    await store.saveSettings("bob", applySettingsChange(defaultSettings(), { whatsapp: { swaps: true } }));
    await dispatchEvent(deps, scheduleEvent("swap-requested", ["bob"]));
    await dispatchEvent(deps, scheduleEvent("no-driver", ["bob"]));
    const [quiet, loud] = push.sent.map((p) => p.message);
    assert.equal(quiet.sound, false);
    assert.equal(quiet.level, "passive");
    assert.equal(loud.sound, true);
    assert.equal(loud.level, "time-sensitive");
    assert.deepEqual(whatsapp.sent.map((w) => w.template), ["cp_no_driver"]);
    assert.equal(store.recordsOf("bob").find((r) => r.type === "swap-requested")?.whatsapp?.reason, "quiet");
  });

  it("quiet hours follow Cairo time, cross midnight, and can be switched off", () => {
    const q = { on: true, from: "22:00", to: "06:00" };
    assert.equal(inQuietHours(cairoToUtcMs("2026-11-15", "21:59"), q), false);
    assert.equal(inQuietHours(cairoToUtcMs("2026-11-15", "22:00"), q), true);
    assert.equal(inQuietHours(cairoToUtcMs("2026-11-16", "05:59"), q), true);
    assert.equal(inQuietHours(cairoToUtcMs("2026-11-16", "06:00"), q), false);
    // Summer time (UTC+3).
    assert.equal(inQuietHours(cairoToUtcMs("2026-07-01", "22:30"), q), true);
    assert.equal(inQuietHours(cairoToUtcMs("2026-11-15", "23:00"), { ...q, on: false }), false);
    assert.equal(inQuietHours(cairoToUtcMs("2026-11-15", "13:00"), { on: true, from: "12:00", to: "14:00" }), true);
  });
});

describe("privacy: no names, addresses or message text leave the server", () => {
  it("pushes and WhatsApp payloads for every type contain only generic text, a date and IDs", async () => {
    store.addParent("ar1", { language: "ar" });
    // The outbox could even carry a child ID: it never reaches the text.
    for (const type of NOTIFICATION_TYPES) {
      if (type === "critical-alarm" || type === "new-parent") continue;
      const all = WHATSAPP_GROUPS.reduce((acc, g) => ({ ...acc, [g]: true }), {});
      await store.saveSettings("bob", applySettingsChange(defaultSettings(), { whatsapp: all }));
      await store.saveSettings("ar1", applySettingsChange(defaultSettings(), { whatsapp: all }));
      await dispatchEvent(deps, newEvent(`p-${type}`, type, ["bob", "ar1"], clock.now, {
        carpoolId: "k1",
        runId: "2026-11-16_pm",
        date: "2026-11-16",
        direction: "toHome",
        childId: "child-adam",
        actorUid: "mona",
      }));
    }
    const payloads = JSON.stringify({ push: push.sent, whatsapp: whatsapp.sent });
    for (const word of [...FORBIDDEN, "child-adam", "mona"]) assert.ok(!payloads.includes(word), `payload contains ${word}`);
    for (const p of push.sent) {
      assert.deepEqual(Object.keys(p.message.data).sort(), ["alarm", "alarmAt", "critical", "notificationId", "route", "type"]);
    }
    assert.ok(push.sent.length >= 40);
    assert.ok(whatsapp.sent.length >= 30);
  });

  it("the in-app record holds IDs, a date and a route only", async () => {
    await dispatchEvent(deps, scheduleEvent("child-absent", ["bob"], { childId: "child-adam" }));
    const r = store.recordsOf("bob")[0];
    assert.ok(!JSON.stringify(r).includes("child-adam"));
  });

  it("only a checked date and a known direction get into {when}", () => {
    assert.equal(whenText("2026-11-16", "toSchool", "en"), "Mon 16 Nov, to school");
    assert.equal(whenText("2026-11-16", "Adam's house", "en"), "Mon 16 Nov");
    assert.equal(whenText("Adam", "toSchool", "en"), "");
    assert.equal(whenText(null, null, "ar"), "");
  });

  it("the dev WhatsApp log masks the number and holds no name", async () => {
    const lines: string[] = [];
    await new FakeWhatsAppSender((l) => lines.push(l)).sendTemplate("+201012345678", "cp_no_driver", "en", ["Mon 16 Nov, to school"], "No driver for Mon 16 Nov, to school.");
    assert.equal(lines.length, 1);
    assert.ok(!lines[0].includes("1012345678"));
    assert.match(lines[0], /\+20\*+78/);
    assert.match(lines[0], /cp_no_driver/);
  });

  it("dispatcher logs carry no phone numbers or names", async () => {
    whatsapp.failures = 1;
    await assert.rejects(dispatchEvent(deps, scheduleEvent("no-driver", ["bob"])));
    const all = logs.join("\n");
    assert.ok(!/\+20100/.test(all), all);
    for (const word of FORBIDDEN) assert.ok(!all.includes(word));
  });
});

describe("new parent nearby (F23)", () => {
  const SCHOOL_POINT = { lat: 29.96, lng: 31.25 };
  function located(uid: string, extra: Partial<{ point: { lat: number; lng: number }; radiusKm: number; verified: boolean; notifyNewParents: boolean; showOnMap: boolean; schoolIds: string[] }> = {}) {
    store.addParent(uid);
    store.locations.set(uid, {
      uid,
      point: SCHOOL_POINT,
      radiusKm: 3,
      verified: true,
      notifyNewParents: true,
      showOnMap: true,
      schoolIds: ["nile"],
      ...extra,
    });
  }

  it("tells verified parents of the same school within their own radius, who did not switch it off", async () => {
    located("newbie");
    located("near");
    located("far", { point: { lat: 30.2, lng: 31.25 } });
    located("bigradius", { point: { lat: 30.0, lng: 31.25 }, radiusKm: 10 });
    located("off", { notifyNewParents: false });
    located("unverified", { verified: false });
    located("other", { schoolIds: ["orman"] });
    located("hidden", { showOnMap: false });
    await dispatchEvent(deps, newParentEvent("newbie", ["nile"], SCHOOL_POINT, clock.now));
    const told = [...store.records.values()].map((r) => r.uid).sort();
    assert.deepEqual(told, ["bigradius", "hidden", "near"]);
    assert.ok(!JSON.stringify(push.sent).includes("newbie"));
    assert.equal(whatsapp.sent.length, 0, "push only unless switched on");
  });

  it("nobody is told when the new parent is no longer verified or hid themselves", async () => {
    located("newbie", { showOnMap: false });
    located("near");
    await dispatchEvent(deps, newParentEvent("newbie", ["nile"], SCHOOL_POINT, clock.now));
    assert.equal(store.records.size, 0);
  });

  it("one event per parent ever (fixed ID)", () => {
    assert.equal(newParentEvent("u1", ["nile"], SCHOOL_POINT, 1).id, newParentEvent("u1", ["nile"], SCHOOL_POINT, 2).id);
  });
});

describe("critical alarm (spec section 11)", () => {
  it("a critical record unread after the delay gets one louder push; a read one does not", async () => {
    await dispatchEvent(deps, scheduleEvent("no-driver", ["bob", "cara"]));
    const bobRecord = store.recordsOf("bob")[0];
    assert.equal(bobRecord.alarmState, "waiting");
    assert.equal(bobRecord.alarmAtMs, NOON + 15 * 60_000);
    store.read("cara", bobRecord.id, NOON + 60_000);

    clock.now = NOON + 10 * 60_000;
    assert.deepEqual(await runNotificationTick({ store, now: () => clock.now, eveningAt: "19:00" }), { reminders: 0, alarms: 0 });
    clock.now = NOON + 16 * 60_000;
    assert.deepEqual(await runNotificationTick({ store, now: () => clock.now, eveningAt: "19:00" }), { reminders: 0, alarms: 1 });
    assert.equal(store.recordsOf("cara")[0].alarmState, "cancelled");
    const alarm = store.events.get(alarmEventId("bob", bobRecord.id));
    assert.ok(alarm);
    // A second tick finds nothing more.
    assert.equal((await runNotificationTick({ store, now: () => clock.now, eveningAt: "19:00" })).alarms, 0);

    await dispatchEvent(deps, alarm);
    const last = push.sent.at(-1)?.message;
    assert.equal(last?.data.alarm, "1");
    assert.equal(last?.level, "time-sensitive");
    assert.equal(last?.sound, true);
    assert.match(last?.title ?? "", /^Reminder: /);
    assert.equal(store.recordsOf("bob")[0].alarmState, "sent");
    assert.equal(store.records.size, 2, "the alarm adds no record");
    assert.equal(whatsapp.sent.length, 2, "and no second WhatsApp");
  });

  it("an alarm for a record read in the meantime sends nothing", async () => {
    await dispatchEvent(deps, scheduleEvent("no-driver", ["bob"]));
    const id = store.recordsOf("bob")[0].id;
    const alarm = newEvent(alarmEventId("bob", id), "critical-alarm", ["bob"], clock.now, { refEventId: id });
    store.read("bob", id, clock.now);
    const before = push.sent.length;
    await dispatchEvent(deps, alarm);
    assert.equal(push.sent.length, before);
    assert.equal(store.recordsOf("bob")[0].alarmState, "cancelled");
  });

  it("non-critical records have no alarm", async () => {
    await dispatchEvent(deps, scheduleEvent("swap-requested", ["bob"]));
    assert.equal(store.recordsOf("bob")[0].alarmAtMs, null);
  });

  it("critical pushes wake the app so it can schedule its own alarm", () => {
    const r = buildRecord(scheduleEvent("no-driver", ["bob"]), "bob", NOON, 900_000);
    const m = buildPush(r, "en", { quiet: true, alarm: false });
    assert.equal(m.contentAvailable, true);
    assert.equal(m.sound, true);
    const fcm = fcmMessage("tok", m) as { apns: { payload: { aps: Record<string, unknown> } }; android: { notification: { channelId: string } } };
    assert.equal(fcm.apns.payload.aps["interruption-level"], "time-sensitive");
    assert.equal(fcm.apns.payload.aps.contentAvailable, true);
    assert.equal(fcm.android.notification.channelId, "critical");
    const quiet = fcmMessage("tok", buildPush(buildRecord(scheduleEvent("plan-ready", ["bob"]), "bob", NOON, 0), "en", { quiet: true, alarm: false })) as {
      apns: { headers: Record<string, string>; payload: { aps: Record<string, unknown> } };
    };
    assert.equal(quiet.apns.payload.aps.sound, undefined);
    assert.equal(quiet.apns.headers["apns-priority"], "5");
  });
});

describe("driver reminders (tick)", () => {
  const run = (extra: Partial<RunLite>): RunLite => ({
    carpoolId: "k1",
    runId: "2026-11-16_am",
    date: "2026-11-16",
    direction: "toSchool",
    driverUid: "bob",
    startMs: cairoToUtcMs("2026-11-16", "07:30"),
    confirmByMs: cairoToUtcMs("2026-11-15", "21:00"),
    status: "confirmed",
    ...extra,
  });

  it("the evening before, from 19:00 Cairo, to the confirmed driver only", () => {
    const tomorrow = [run({}), run({ runId: "2026-11-16_pm", driverUid: null })];
    assert.equal(dueReminders(cairoToUtcMs("2026-11-15", "18:59"), "19:00", { tomorrow, soon: [], toConfirm: [] }).length, 0);
    const due = dueReminders(cairoToUtcMs("2026-11-15", "19:00"), "19:00", { tomorrow, soon: [], toConfirm: [] });
    assert.deepEqual(due.map((e) => [e.type, e.recipients]), [["drive-evening", ["bob"]]]);
    assert.equal(due[0].id, reminderId("drive-evening", tomorrow[0], "bob"));
  });

  it("one hour before, to the confirmed driver", () => {
    const r = run({});
    assert.equal(dueReminders(r.startMs - 61 * 60_000, "19:00", { tomorrow: [], soon: [r], toConfirm: [] }).length, 0);
    assert.deepEqual(dueReminders(r.startMs - 55 * 60_000, "19:00", { tomorrow: [], soon: [r], toConfirm: [] }).map((e) => e.type), ["drive-hour"]);
    assert.equal(dueReminders(r.startMs - 55 * 60_000, "19:00", { tomorrow: [], soon: [run({ status: "planned" })], toConfirm: [] }).length, 0);
  });

  it("missing driver confirmation: the proposed driver, within two hours of the confirm-by time", () => {
    const r = run({ status: "planned" });
    assert.equal(dueReminders(r.confirmByMs - 3 * 3_600_000, "19:00", { tomorrow: [], soon: [], toConfirm: [r] }).length, 0);
    assert.deepEqual(dueReminders(r.confirmByMs - 90 * 60_000, "19:00", { tomorrow: [], soon: [], toConfirm: [r] }).map((e) => e.type), ["confirm-reminder"]);
    assert.equal(dueReminders(r.confirmByMs + 60_000, "19:00", { tomorrow: [], soon: [], toConfirm: [r] }).length, 0);
  });

  it("each reminder is written once, however often the tick runs", async () => {
    store.runs = [run({}), run({ runId: "2026-11-16_pm", status: "planned", driverUid: "cara", confirmByMs: cairoToUtcMs("2026-11-15", "21:00"), startMs: cairoToUtcMs("2026-11-16", "14:30") })];
    clock.now = cairoToUtcMs("2026-11-15", "19:30");
    const tick = () => runNotificationTick({ store, now: () => clock.now, eveningAt: "19:00" });
    assert.deepEqual(await tick(), { reminders: 2, alarms: 0 });
    clock.now += 5 * 60_000;
    assert.deepEqual(await tick(), { reminders: 0, alarms: 0 });
    const types = [...store.events.values()].map((e) => `${e.type}:${e.recipients.join()}`).sort();
    assert.deepEqual(types, ["confirm-reminder:cara", "drive-evening:bob"]);
    // Next morning, an hour before the run.
    clock.now = cairoToUtcMs("2026-11-16", "06:40");
    assert.deepEqual(await tick(), { reminders: 1, alarms: 0 });
  });

  it("the reminder push reaches the driver (Done when)", async () => {
    store.runs = [run({})];
    clock.now = cairoToUtcMs("2026-11-16", "06:45");
    await runNotificationTick({ store, now: () => clock.now, eveningAt: "19:00" });
    for (const e of store.events.values()) await dispatchEvent(deps, e);
    assert.deepEqual(push.sent.map((p) => [p.message.data.type, p.message.body]), [["drive-hour", "Your Mon 16 Nov, to school run starts within the hour."]]);
    assert.equal(push.sent[0].tokens[0].key, "key-bob");
  });
});

describe("phones and settings", () => {
  let d: DeviceDeps;
  beforeEach(() => {
    d = { store, now: () => clock.now, limits: { deviceChangesPerDay: 3, settingsChangesPerDay: 2 } };
  });
  const TOKEN = "fcm-token-1234567890abcdefghij";

  it("registers a phone, moves it when another parent signs in on it, removes it on sign-out", async () => {
    await registerDevice(d, "bob", { token: TOKEN, platform: "ios" });
    assert.equal((await store.tokens("bob")).some((t) => t.token === TOKEN), true);
    await registerDevice(d, "cara", { token: TOKEN, platform: "ios" });
    assert.equal((await store.tokens("bob")).some((t) => t.token === TOKEN), false);
    assert.deepEqual(await unregisterDevice(d, "bob", { token: TOKEN }), { removed: false }, "only the owner removes it");
    assert.deepEqual(await unregisterDevice(d, "cara", { token: TOKEN }), { removed: true });
  });

  it("a refreshed token replaces the old one", async () => {
    await registerDevice(d, "bob", { token: TOKEN, platform: "ios" });
    await registerDevice(d, "bob", { token: `${TOKEN}-new`, platform: "ios", previousToken: TOKEN });
    assert.deepEqual((await store.tokens("bob")).map((t) => t.token).filter((t) => t.startsWith("fcm")), [`${TOKEN}-new`]);
  });

  it("refuses bad input and too many changes", async () => {
    for (const bad of [null, {}, { token: "short", platform: "ios" }, { token: TOKEN, platform: "symbian" }, { token: TOKEN, platform: "ios", previousToken: 5 }]) {
      await assert.rejects(registerDevice(d, "bob", bad), (e: unknown) => e instanceof DeviceError && e.reason === "invalid-request");
    }
    for (let i = 0; i < 3; i++) await registerDevice(d, "bob", { token: `${TOKEN}${i}`, platform: "android" });
    await assert.rejects(registerDevice(d, "bob", { token: `${TOKEN}x`, platform: "ios" }), (e: unknown) => e instanceof DeviceError && e.reason === "rate-limited");
    // Signing out is never limited.
    assert.deepEqual(await unregisterDevice(d, "bob", { token: `${TOKEN}0` }), { removed: true });
  });

  it("settings: WhatsApp per group and quiet hours; unknown groups and bad times are refused", async () => {
    const view = await updateSettings(d, "bob", { whatsapp: { swaps: true }, quiet: { on: false } });
    assert.deepEqual((view.whatsapp as Record<string, boolean>).swaps, true);
    assert.deepEqual((view.whatsapp as Record<string, boolean>).noDriver, true);
    assert.equal((view.quiet as { on: boolean }).on, false);
    for (const bad of [{}, { whatsapp: { chat: true } }, { whatsapp: { swaps: "yes" } }, { quiet: { from: "25:00" } }, "x"]) {
      await assert.rejects(updateSettings(d, "bob", bad), (e: unknown) => e instanceof DeviceError && e.reason === "invalid-request");
    }
    await updateSettings(d, "bob", { quiet: { from: "21:30" } });
    await assert.rejects(updateSettings(d, "bob", { quiet: { to: "07:00" } }), (e: unknown) => e instanceof DeviceError && e.reason === "rate-limited");
  });

  it("stored settings with odd values fall back to the defaults", () => {
    const s = settingsFrom({ whatsapp: { swaps: true, noDriver: "no", hack: true }, quiet: { on: "x", from: "9pm" } });
    assert.equal(s.whatsapp.swaps, true);
    assert.equal(s.whatsapp.noDriver, true);
    assert.equal("hack" in s.whatsapp, false);
    assert.deepEqual(s.quiet, { on: true, from: "22:00", to: "06:00" });
  });
});

describe("senders", () => {
  it("the fake push sender is refused in prod; fcm and fake are picked by config", () => {
    assert.throws(() => createPushSender("fake", "prod", () => ({ name: "x" }), () => undefined));
    assert.throws(() => createPushSender("apns", "dev", () => ({ name: "x" }), () => undefined));
    assert.equal(createPushSender("fake", "dev", () => ({ name: "x" }), () => undefined).kind, "fake");
  });

  it("the fake push log has the type and level, never the token", async () => {
    const lines: string[] = [];
    const sender = new FakePushSender((l) => lines.push(l));
    const r = buildRecord(scheduleEvent("plan-ready", ["bob"]), "bob", NOON, 0);
    await sender.send([{ key: "k", token: "secret-token-value" }], buildPush(r, "en", { quiet: false, alarm: false }));
    assert.match(lines[0], /plan-ready \(active, sound\)/);
    assert.ok(!lines[0].includes("secret-token-value"));
  });

  it("Meta template request: body parameter is the date only; no parameters for generic types", () => {
    const meta = new MetaWhatsAppSender({ accessToken: "t", phoneNumberId: "123", apiVersion: "v25.0", templateName: "login_code", templateLanguages: { ar: "ar", en: "en" } });
    const withWhen = JSON.parse(meta.buildTemplateRequest("+201012345678", "cp_no_driver", "ar", ["الاثنين 16 نوفمبر"]).init.body);
    assert.equal(withWhen.to, "201012345678");
    assert.equal(withWhen.template.name, "cp_no_driver");
    assert.deepEqual(withWhen.template.components, [{ type: "body", parameters: [{ type: "text", text: "الاثنين 16 نوفمبر" }] }]);
    const plain = JSON.parse(meta.buildTemplateRequest("+201012345678", "cp_plan_ready", "en", []).init.body);
    assert.deepEqual(plain.template.components, []);
  });
});

describe("schedule event kinds (Prompt 7 fixes)", () => {
  it("every schedule event kind the flows write is a notification type with text and a schedule link", () => {
    const kinds = [
      "plan-ready", "no-driver", "swap-requested", "swap-accepted", "swap-cancelled", "run-taken",
      "child-absent", "child-back", "driver-unavailable", "schedule-changed", "time-changed",
      "join-requested", "join-approved", "join-declined",
    ] as const;
    for (const k of kinds) {
      assert.ok((NOTIFICATION_TYPES as readonly string[]).includes(k), k);
      if (!k.startsWith("join")) assert.equal(routeFor({ type: k, carpoolId: "k1" }), "/carpools/k1/schedule", k);
    }
  });

  it("time-changed: to the driver, with the run; a reconfirm notice is normal, a moved one is critical and goes to WhatsApp", async () => {
    await dispatchEvent(deps, scheduleEvent("time-changed", ["bob"], { critical: false }));
    let r = store.recordsOf("bob")[0];
    assert.equal(r.critical, false);
    assert.equal(r.alarmAtMs, null);
    assert.equal(push.sent[0].message.body, "The Mon 16 Nov, to school run has a new time. Check the plan.");
    assert.equal(whatsapp.sent.length, 0);

    const moved = newEvent("e-moved", "time-changed", ["cara"], clock.now, { carpoolId: "k1", runId: "2026-11-16_am", date: "2026-11-16", direction: "toSchool", critical: true });
    clock.now = cairoToUtcMs("2026-11-15", "23:30");
    moved.createdAtMs = clock.now;
    await dispatchEvent(deps, moved);
    r = store.recordsOf("cara")[0];
    assert.equal(r.critical, true);
    assert.ok(r.alarmAtMs);
    const last = push.sent.at(-1)?.message;
    assert.equal(last?.level, "time-sensitive");
    assert.equal(last?.sound, true, "quiet hours do not silence it");
    assert.deepEqual(whatsapp.sent.map((w) => w.template), ["cp_time_changed"]);
    // Switching the urgent group off stops it.
    await store.saveSettings("bob", applySettingsChange(defaultSettings(), { whatsapp: { noDriver: false } }));
    await dispatchEvent(deps, { ...moved, id: "e-moved-2", recipients: ["bob"] });
    assert.equal(whatsapp.sent.length, 1);
  });
});
