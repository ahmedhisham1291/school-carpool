/**
 * Reviewer tool for testing verification before the admin panel (Prompt 4).
 * Uses the same decision code as the decideVerification function, so an
 * approval sets the "verified" status and custom claim exactly like the panel will.
 *
 *   npm --prefix functions run review:emulator -- queue
 *   npm --prefix functions run review:emulator -- approve <caseId> [match|birth_certificate]
 *   npm --prefix functions run review:emulator -- reject <caseId> <reason> [note]
 *   npm --prefix functions run review:emulator -- kyc <match|no_match|error>
 *   npm --prefix functions run review:emulator -- grant-admin <uid>
 *
 * Reasons: photo_unclear, id_mismatch, selfie_mismatch, liveness_failed,
 * id_expired, school_id_unclear, child_name_mismatch, license_invalid, other
 * (other needs a note).
 *
 * Runs against the emulators (demo- project). For the cloud dev project set
 * REVIEW_PROJECT=<dev project id> and sign in with
 * `gcloud auth application-default login`; prod projects are refused.
 */
import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { decideVerification, type VerificationDeps } from "../src/verification/flow";
import { CloudStorageFiles, CONFIG, FirebaseClaimsService, FirestoreVerificationStore } from "../src/verification/store";
import { VerificationError } from "../src/verification/submission";

const REVIEWER = "review-script";

function refuse(reason: string): never {
  console.error(`review: refusing to run: ${reason}`);
  process.exit(1);
}

const emulatorProject = process.env.GCLOUD_PROJECT ?? "";
const cloudProject = process.env.REVIEW_PROJECT ?? "";
const projectId = cloudProject || emulatorProject;
if (cloudProject) {
  if (/prod/i.test(cloudProject)) refuse(`"${cloudProject}" looks like a production project`);
} else {
  if (!process.env.FIRESTORE_EMULATOR_HOST) refuse("FIRESTORE_EMULATOR_HOST is not set (or set REVIEW_PROJECT)");
  if (!emulatorProject.startsWith("demo-")) refuse(`project "${emulatorProject}" is not a demo- project`);
}

initializeApp({ projectId, storageBucket: process.env.STORAGE_BUCKET ?? `${projectId}.appspot.com` });
const db = getFirestore();

const deps: VerificationDeps = {
  store: new FirestoreVerificationStore(db),
  files: new CloudStorageFiles(getStorage().bucket()),
  kyc: { kind: "none", check: () => Promise.reject(new Error("unused")) },
  claims: new FirebaseClaimsService(getAuth()),
  nationalIdKey: "",
  now: () => Date.now(),
  reportError: (error) => console.error(error instanceof Error ? error.message : "error"),
};

async function main(): Promise<void> {
  const [command, arg1, arg2, ...rest] = process.argv.slice(2);
  switch (command) {
    case "queue": {
      const cases = await deps.store.queue(50);
      if (cases.length === 0) console.log("review: the queue is empty");
      for (const c of cases) {
        const when = new Date(c.submittedAtMs).toISOString();
        console.log(`${c.caseId}  ${c.scope}  submitted ${when}  kyc=${c.kycResult}  children=${c.children}  driver=${c.driver}`);
      }
      return;
    }
    case "approve":
      // arg2: how the parent and child name check passed (match | birth_certificate).
      console.log(await decideVerification(deps, REVIEWER, { caseId: arg1, decision: "approve", nameCheck: arg2 ?? "match" }));
      return;
    case "reject": {
      const note = rest.join(" ").trim();
      console.log(
        await decideVerification(deps, REVIEWER, { caseId: arg1, decision: "reject", reasonCode: arg2, note: note || null }),
      );
      return;
    }
    case "kyc":
      if (!["match", "no_match", "error"].includes(arg1)) refuse("use kyc match | no_match | error");
      await db.collection(CONFIG).doc("kyc").set({ fakeResult: arg1 }, { merge: true });
      console.log(`review: the fake ID check now answers "${arg1}"`);
      return;
    case "grant-admin": {
      if (!arg1) refuse("give the uid");
      const auth = getAuth();
      const user = await auth.getUser(arg1);
      await auth.setCustomUserClaims(arg1, { ...(user.customClaims ?? {}), admin: true });
      console.log(`review: ${arg1} is an admin (sign in again to refresh the token)`);
      return;
    }
    default:
      refuse("commands: queue | approve <caseId> | reject <caseId> <reason> [note] | kyc <result> | grant-admin <uid>");
  }
}

main().catch((error: unknown) => {
  console.error(error instanceof VerificationError ? `review: ${error.reason}` : error);
  process.exit(1);
});
