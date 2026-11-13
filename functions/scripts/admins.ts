/**
 * Bootstrap for admin panel accounts (F14). After this, super admins
 * create every other admin in the panel (Admins page).
 *
 *   npm --prefix functions run admins:emulator -- create-super-admin <email> "<name>"
 *   ADMIN_PROJECT=<project id> npm --prefix functions run admins:cloud -- enable-totp
 *   ADMIN_PROJECT=<project id> npm --prefix functions run admins:cloud -- create-super-admin <email> "<name>"
 *
 * create-super-admin makes an email account with no phone number and the
 * admin + superAdmin claims, and prints a one-time link where that person
 * sets their own password (cloud), or sets the dev password
 * "dev-only-password" (emulators). At first sign-in the panel asks for the
 * TOTP second factor (cloud only; the Auth emulator has no TOTP).
 *
 * enable-totp turns on TOTP multi-factor for the project (Identity
 * Platform). Run it once per cloud project.
 *
 * For a production project set CONFIRM_PROD=yes as well.
 * Sign in with `gcloud auth application-default login` first.
 */
import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { FieldValue, getFirestore } from "firebase-admin/firestore";

function refuse(reason: string): never {
  console.error(`admins: refusing to run: ${reason}`);
  process.exit(1);
}

const emulatorProject = process.env.GCLOUD_PROJECT ?? "";
const cloudProject = process.env.ADMIN_PROJECT ?? "";
const projectId = cloudProject || emulatorProject;
const onEmulator = !cloudProject;
if (cloudProject) {
  if (/prod/i.test(cloudProject) && process.env.CONFIRM_PROD !== "yes") {
    refuse(`"${cloudProject}" looks like a production project (set CONFIRM_PROD=yes to continue)`);
  }
} else {
  if (!process.env.FIREBASE_AUTH_EMULATOR_HOST) refuse("FIREBASE_AUTH_EMULATOR_HOST is not set (or set ADMIN_PROJECT)");
  if (!emulatorProject.startsWith("demo-")) refuse(`project "${emulatorProject}" is not a demo- project`);
}

initializeApp({ projectId });
const auth = getAuth();
const db = getFirestore();

/** Emulator only. Never used in a cloud project. */
const DEV_PASSWORD = "dev-only-password";

async function createSuperAdmin(email: string, displayName: string): Promise<void> {
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) refuse("give a valid email");
  if (!displayName || displayName.trim().length < 2) refuse('give the name, for example "Mona Admin"');
  const user = await auth.createUser({
    email: email.toLowerCase(),
    emailVerified: true,
    displayName: displayName.trim(),
    ...(onEmulator ? { password: DEV_PASSWORD } : {}),
  });
  await auth.setCustomUserClaims(user.uid, { admin: true, superAdmin: true });
  await db.collection("admins").doc(user.uid).set({
    email: email.toLowerCase(),
    displayName: displayName.trim(),
    role: "superAdmin",
    disabled: false,
    createdBy: "bootstrap-script",
    createdAt: FieldValue.serverTimestamp(),
  });
  await db.collection("auditLog").doc().create({
    actorUid: "bootstrap-script",
    action: "admin.create",
    target: `admins/${user.uid}`,
    reasonCode: null,
    details: { role: "superAdmin" },
    ip: null,
    time: FieldValue.serverTimestamp(),
  });
  if (onEmulator) {
    console.log(`admins: super admin ${user.uid} created; sign in with the password "${DEV_PASSWORD}"`);
  } else {
    const link = await auth.generatePasswordResetLink(email.toLowerCase());
    console.log(`admins: super admin ${user.uid} created. Give this one-time link to them directly (valid 1 hour):`);
    console.log(link);
  }
}

async function enableTotp(): Promise<void> {
  if (onEmulator) refuse("the Auth emulator has no TOTP; run this against a cloud project");
  await auth.projectConfigManager().updateProjectConfig({
    multiFactorConfig: {
      providerConfigs: [{ state: "ENABLED", totpProviderConfig: { adjacentIntervals: 1 } }],
    },
  });
  console.log(`admins: TOTP two-step sign-in is on for ${projectId}`);
}

async function main(): Promise<void> {
  const [command, arg1, ...rest] = process.argv.slice(2);
  switch (command) {
    case "create-super-admin":
      return createSuperAdmin(arg1 ?? "", rest.join(" "));
    case "enable-totp":
      return enableTotp();
    default:
      refuse('commands: create-super-admin <email> "<name>" | enable-totp');
  }
}

main().catch((error: unknown) => {
  console.error("admins:", error instanceof Error ? error.message : error);
  process.exit(1);
});
