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
  limits: { ...DEFAULT_CARPOOL_LIMITS, searchesPerHour: 1000, joinRequestsPerDay: 1000, invitesPerDay: 1000 },
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
  if (!command || !uid) refuse("usage: <search|request|approve|consent|invite|mine> ... --as <uid> (see the header)");
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
