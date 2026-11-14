/**
 * Sends one test notification (Prompt 8) by writing an event to the
 * outbox; the deployed (or emulated) sendNotification trigger sends it.
 * For the owner's iPhone check of a real push, which needs the DEPLOYED
 * dev project: FCM cannot reach a phone from the emulators, because the
 * app on the emulators uses a demo- project with no push sender.
 *
 *   GCLOUD_PROJECT=<dev project id> npm --prefix functions run notify:cloud -- <uid> drive-hour [carpoolId] [YYYY-MM-DD]
 *   npm --prefix functions run notify:emulator -- <uid> swap-requested <carpoolId> 2026-11-16
 *
 * Refuses every project whose ID does not end in "-dev" or start with
 * "demo-" (fake data only; never staging or prod).
 */
import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { isNotificationType } from "../src/notifications/catalog";
import { newEvent } from "../src/notifications/model";
import { FirestoreNotifyStore } from "../src/notifications/store";

function refuse(reason: string): never {
  console.error(`notify: refusing to run: ${reason}`);
  process.exit(1);
}

const projectId = process.env.GCLOUD_PROJECT ?? "";
if (!projectId.startsWith("demo-") && !projectId.endsWith("-dev")) refuse(`project "${projectId}" is not a demo- or -dev project`);

async function main(): Promise<void> {
  const [to, type, carpoolId, date] = process.argv.slice(2);
  if (!to || !isNotificationType(type) || type === "critical-alarm") refuse("usage: <uid> <type> [carpoolId] [YYYY-MM-DD]");
  initializeApp({ projectId });
  const validDate = date && /^\d{4}-\d{2}-\d{2}$/.test(date) ? date : null;
  const e = newEvent(`test_${Date.now()}`, type, [to], Date.now(), {
    carpoolId: carpoolId && /^[A-Za-z0-9_-]+$/.test(carpoolId) ? carpoolId : null,
    date: validDate,
    direction: validDate ? "toSchool" : null,
  });
  await new FirestoreNotifyStore(getFirestore()).createEvent(e);
  console.log(`event ${e.id} (${type}) written to ${projectId}; sendNotification sends it`);
}

main().catch((error: unknown) => {
  console.error("notify failed:", error instanceof Error ? error.message : error);
  process.exit(1);
});
