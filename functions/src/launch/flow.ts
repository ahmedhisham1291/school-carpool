import type { AdminCaller } from "../admin_panel/guard";
import type { AuditEntry } from "../admin_panel/types";
import { parseLaunchChange, signUpOpen, type LaunchSettings } from "./model";

/**
 * Admin panel > Settings > Launch (R5). Any admin reads the gate; only a
 * super admin with a sign-in less than 30 minutes old changes it (the
 * callable checks both), and the change and its audit entry are written
 * together. Opening records the licence references.
 */

export interface LaunchStore {
  read(): Promise<LaunchSettings>;
  /** The setting and its audit entry together, or neither. */
  write(pdpcLicensed: boolean, adminUid: string, nowMs: number, audit: AuditEntry): Promise<void>;
}

export interface LaunchDeps {
  store: LaunchStore;
  env: string;
  now: () => number;
}

export interface LaunchView extends LaunchSettings {
  env: string;
  /** New real parents can sign up right now. */
  signUpOpen: boolean;
}

export async function getLaunch(deps: LaunchDeps): Promise<LaunchView> {
  const s = await deps.store.read();
  return { ...s, env: deps.env, signUpOpen: signUpOpen(deps.env, s) };
}

export async function setLaunch(deps: LaunchDeps, caller: AdminCaller, data: unknown, ip: string | null): Promise<LaunchView> {
  const change = parseLaunchChange(data);
  await deps.store.write(change.pdpcLicensed, caller.uid, deps.now(), {
    actorUid: caller.uid,
    action: change.pdpcLicensed ? "launch.open" : "launch.close",
    target: "config/launch",
    reasonCode: change.pdpcLicensed ? "pdpcLicensed" : "pdpcNotLicensed",
    details: change.pdpcLicensed ? { licenceRefs: change.licenceRefs } : {},
    ip,
  });
  return getLaunch(deps);
}

/**
 * The sign-in check (auth/otp_flow.ts verifyCode): may this number come in?
 * Existing accounts and App Review demo phones always; a new number only
 * while sign-up is open.
 */
export function mayEnter(open: boolean, hasAccount: boolean, reviewPhone: boolean): boolean {
  return open || hasAccount || reviewPhone;
}
