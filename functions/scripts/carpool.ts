/**
 * Plays a second fake parent on the LOCAL EMULATORS (Prompt 6), so the
 * owner can test carpools with one iPhone. Uses the same flows as the Cloud
 * Functions, acting as the parent given with --as (the seed's fake parents,
 * for example seed-map-parent-1 "Hoda", who has a car and a child at
 * "Nile International School (test)").
 *
 *   npm --prefix functions run carpool:emulator -- search --as seed-map-parent-1
 *   npm --prefix functions run carpool:emulator -- request <carpoolId> --as seed-map-parent-1
 *   npm --prefix functions run carpool:emulator -- approve <carpoolId> <uid> --as <admin uid>
 *   npm --prefix functions run carpool:emulator -- consent <carpoolId> <driverUid> --as seed-map-parent-1 [--withdraw]
 *   npm --prefix functions run carpool:emulator -- invite <carpoolId> --as seed-map-parent-1
 *   npm --prefix functions run carpool:emulator -- mine --as seed-map-parent-1
 *
 * Schedule (Prompt 7):
 *   ... -- days <carpoolId> sun,mon,tue --as seed-map-parent-1        (her driving days)
 *   ... -- runs <carpoolId> [--week YYYY-MM-DD] --as seed-map-parent-1 (the week's runs)
 *   ... -- confirm <carpoolId> <runId> --as seed-map-parent-1          (runId like 2026-11-15_am)
 *   ... -- swap <carpoolId> <runId> --as seed-map-parent-1             (ask for a swap)
 *   ... -- take <carpoolId> <runId> --as seed-map-parent-1             (accept a swap / take an open run)
 *   ... -- absent <carpoolId> <date> <childId> [--back] --as seed-map-parent-1
 *   ... -- plan <carpoolId> [--week YYYY-MM-DD] --as <admin uid>
 *   ... -- tick --as any                                              (cut-offs and balance now;
 *       the emulators do not run scheduled functions by themselves)
 *
 * Notifications (Prompt 8; the functions emulator's sendNotification
 * trigger sends what these write, and its log shows the masked WhatsApp):
 *   ... -- remind --as any                       (reminders and critical alarms now: the notification tick)
 *   ... -- notify <uid> <type> [carpoolId] [date] --as any
 *       (one test event, for example: notify <your uid> drive-hour <carpoolId> 2026-11-16)
 *
 * Emulators and demo- projects only (fake data only).
 */
import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { newInviteCode } from "../src/carpools/callables";
import {
  createInvite,
  decideJoinRequest,
  DEFAULT_CARPOOL_LIMITS,
  requestToJoin,
  searchCarpools,
  setDriverConsent,
  type CarpoolDeps,
} from "../src/carpools/flow";
import { CarpoolError } from "../src/carpools/model";
import { FirestoreCarpoolStore } from "../src/carpools/store";
import { cairoDate } from "../src/carpools/model";
import { addDays, weekStartOf } from "../src/schedule/cairo";
import { isNotificationType } from "../src/notifications/catalog";
import { newEvent } from "../src/notifications/model";
import { FirestoreNotifyStore } from "../src/notifications/store";
import { runNotificationTick } from "../src/notifications/tick";
import { confirmRun, planWeek, requestSwap, runScheduleTick, setChildAbsent, setDrivingDays, takeRun } from "../src/schedule/flow";

function refuse(reason: string): never {
  console.error(`carpool: refusing to run: ${reason}`);
  process.exit(1);
}

const projectId = process.env.GCLOUD_PROJECT ?? "";
if (!process.env.FIRESTORE_EMULATOR_HOST) refuse("FIRESTORE_EMULATOR_HOST is not set");
if (!projectId.startsWith("demo-")) refuse(`project "${projectId}" is not a demo- project`);

initializeApp({ projectId });
const db = getFirestore();
const store = new FirestoreCarpoolStore(db);
const deps: CarpoolDeps = {
  store,
  now: () => Date.now(),
  // Generous limits for testing by hand.
  limits: { ...DEFAULT_CARPOOL_LIMITS, searchesPerHour: 1000, joinRequestsPerDay: 1000, invitesPerDay: 1000, plansPerDay: 1000, scheduleChangesPerDay: 1000 },
  newCode: newInviteCode,
  linkBase: process.env.INVITE_LINK_BASE ?? "https://demo-school-carpool-links.web.app",
};

function option(args: string[], name: string): string | undefined {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const command = args[0];
  const uid = option(args, "--as");
  if (!command || !uid) refuse("usage: <search|request|approve|consent|invite|mine|days|plan|runs|confirm|swap|take|absent|tick|remind|notify> ... --as <uid> (see the header)");
  const caller = { uid, verifiedClaim: true };
  switch (command) {
    case "search": {
      const children = await store.approvedChildren(uid);
      const schoolId = option(args, "--school") ?? children[0]?.schoolId;
      if (!schoolId) refuse("the parent has no approved child; pass --school <id>");
      const { carpools } = await searchCarpools(deps, caller, { kind: "school", schoolId });
      for (const c of carpools) {
        console.log(`${c.id}  ${c.schoolNameEn} ${c.areaNameEn}  in ${c.morning ?? "-"} out ${c.afternoon ?? "-"}  ${c.seatsLeft}/${c.seats} free  by ${c.creatorFirstName}`);
      }
      if (carpools.length === 0) console.log("no carpools with free seats");
      return;
    }
    case "request": {
      const carpoolId = args[1];
      const carpool = (await store.carpoolsById([carpoolId]))[0];
      if (!carpool) refuse(`no carpool ${carpoolId}`);
      const childIds = option(args, "--children")?.split(",") ??
        (await store.approvedChildren(uid)).filter((c) => carpool.kind === "activity" || c.schoolId === carpool.schoolId).map((c) => c.id);
      console.log(await requestToJoin(deps, caller, { carpoolId, childIds, acceptRules: true, acceptContribution: true }));
      return;
    }
    case "approve":
      console.log(await decideJoinRequest(deps, caller, { carpoolId: args[1], uid: args[2], approve: !args.includes("--decline") }));
      return;
    case "consent":
      console.log(await setDriverConsent(deps, caller, { carpoolId: args[1], driverUid: args[2], accept: !args.includes("--withdraw") }));
      return;
    case "invite":
      console.log((await createInvite(deps, caller, { carpoolId: args[1] })).url);
      return;
    case "days":
      console.log(await setDrivingDays(deps, caller, { carpoolId: args[1], days: (args[2] ?? "").split(",").filter((d) => d.length > 0) }));
      return;
    case "plan":
      console.log(await planWeek(deps, caller, { carpoolId: args[1], weekStart: option(args, "--week") ?? weekStartOf(cairoDate(Date.now())) }));
      return;
    case "runs": {
      const week = option(args, "--week") ?? weekStartOf(cairoDate(Date.now()));
      const runs = await store.transact((tx) => tx.runs(args[1], week, addDays(week, 6)));
      for (const r of runs) {
        console.log(`${r.id}  ${r.time}  ${r.status.padEnd(9)}  driver ${r.driverUid ?? "-"}  riders ${r.riders.map((x) => x.id).join(",")}  absent ${r.absent.map((x) => x.id).join(",") || "-"}`);
      }
      if (runs.length === 0) console.log("no runs planned for this week");
      return;
    }
    case "confirm":
      console.log((await confirmRun(deps, caller, { carpoolId: args[1], runId: args[2] })).status);
      return;
    case "swap":
      console.log((await requestSwap(deps, caller, { carpoolId: args[1], runId: args[2] })).status);
      return;
    case "take":
      console.log((await takeRun(deps, caller, { carpoolId: args[1], runId: args[2] })).status);
      return;
    case "absent":
      console.log(await setChildAbsent(deps, caller, { carpoolId: args[1], date: args[2], childId: args[3], absent: !args.includes("--back") }));
      return;
    case "tick":
      console.log(await runScheduleTick(deps));
      return;
    case "remind":
      console.log(await runNotificationTick({ store: new FirestoreNotifyStore(db), now: () => Date.now(), eveningAt: process.env.REMINDER_EVENING_AT ?? "19:00" }));
      return;
    case "notify": {
      const [, to, type, carpoolId, date] = args;
      if (!to || !isNotificationType(type) || type === "critical-alarm") refuse("usage: notify <uid> <type> [carpoolId] [date] --as any");
      const e = newEvent(`test_${Date.now()}`, type, [to], Date.now(), {
        carpoolId: carpoolId && !carpoolId.startsWith("--") ? carpoolId : null,
        date: date && /^\d{4}-\d{2}-\d{2}$/.test(date) ? date : null,
        direction: date ? "toSchool" : null,
      });
      await new FirestoreNotifyStore(db).createEvent(e);
      console.log(`event ${e.id} written; the emulator's sendNotification sends it`);
      return;
    }
    case "mine":
      for (const m of await store.membershipsOf(uid)) console.log(`${m.carpoolId}  ${m.status}  ${m.role}`);
      return;
    default:
      refuse(`unknown command ${command}`);
  }
}

main().catch((error: unknown) => {
  console.error("carpool failed:", error instanceof CarpoolError ? error.reason : error instanceof Error ? error.message : error);
  process.exit(1);
});
