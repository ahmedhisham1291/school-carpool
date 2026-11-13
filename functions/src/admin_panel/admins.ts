import { AdminError, docId, record, text } from "./errors";
import type { AdminCaller, AdminRole } from "./guard";
import type { AdminAccounts, AdminRecord, AdminsStore } from "./types";

/**
 * Admin accounts (F14). Only a super admin creates, lists, disables or
 * enables admins (the callables check the superAdmin claim). A new admin
 * gets an email account with no phone number and no password; the super
 * admin receives a one-time link (shown once, never stored or logged) for
 * the new admin to set their own password. At first sign-in the panel
 * makes them add the TOTP second factor.
 */

export interface AdminsDeps {
  store: AdminsStore;
  accounts: AdminAccounts;
  now: () => number;
}

const EMAIL = /^[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{2,}$/;

export interface NewAdmin {
  email: string;
  displayName: string;
  role: AdminRole;
}

export function parseNewAdmin(data: unknown): NewAdmin {
  const raw = record(data);
  if (!raw) throw new AdminError("invalid-request");
  const email = typeof raw.email === "string" ? raw.email.trim().toLowerCase() : "";
  if (!EMAIL.test(email) || email.length > 254) throw new AdminError("invalid-request", { field: "email" });
  let displayName: string;
  try {
    displayName = text(raw.displayName, 2, 60);
  } catch {
    throw new AdminError("invalid-request", { field: "displayName" });
  }
  const role = raw.role;
  if (role !== "admin" && role !== "superAdmin") throw new AdminError("invalid-request", { field: "role" });
  return { email, displayName, role };
}

export async function createAdmin(
  deps: AdminsDeps,
  caller: AdminCaller,
  data: unknown,
  ip: string | null,
): Promise<{ uid: string; setupLink: string }> {
  const input = parseNewAdmin(data);
  const uid = await deps.accounts.create(input.email, input.displayName);
  await deps.accounts.setRole(uid, input.role);
  const record: AdminRecord = {
    uid,
    email: input.email,
    displayName: input.displayName,
    role: input.role,
    disabled: false,
    createdAtMs: deps.now(),
  };
  await deps.store.saveAdmin(record, caller.uid, {
    actorUid: caller.uid,
    action: "admin.create",
    target: `admins/${uid}`,
    details: { role: input.role },
    ip,
  });
  const setupLink = await deps.accounts.passwordSetupLink(input.email);
  return { uid, setupLink };
}

export async function listAdmins(deps: AdminsDeps): Promise<{ admins: AdminRecord[] }> {
  return { admins: await deps.store.listAdmins() };
}

/** Disables (signs out everywhere) or enables an admin. Not the caller. */
export async function setAdminDisabled(
  deps: AdminsDeps,
  caller: AdminCaller,
  data: unknown,
  ip: string | null,
): Promise<{ disabled: boolean }> {
  const raw = record(data);
  const uid = docId(raw?.uid);
  const disabled = raw?.disabled;
  if (typeof disabled !== "boolean") throw new AdminError("invalid-request");
  if (uid === caller.uid) throw new AdminError("own-account");
  const admin = await deps.store.getAdmin(uid);
  if (!admin) throw new AdminError("not-found");
  await deps.accounts.setDisabled(uid, disabled);
  await deps.store.setDisabled(uid, disabled, {
    actorUid: caller.uid,
    action: disabled ? "admin.disable" : "admin.enable",
    target: `admins/${uid}`,
    ip,
  });
  return { disabled };
}
