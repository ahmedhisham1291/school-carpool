import { onCall } from "firebase-functions/v2/https";
import { adminDb } from "../admin";
import { ipOf, requireAdminCaller } from "../admin_panel/access";
import { reasonErrorMapper, runCallable } from "../common/callable";
import { appEnv, ENFORCE_APP_CHECK } from "../config";
import { getLaunch, setLaunch, type LaunchDeps } from "./flow";
import { LAUNCH_ERROR_CODES, LaunchError, signUpOpen } from "./model";
import { FirestoreLaunchStore } from "./store";

function deps(): LaunchDeps {
  return { store: new FirestoreLaunchStore(adminDb()), env: appEnv(), now: () => Date.now() };
}

/** Used by verifyCode (auth/callables.ts): new real parents may sign up now. */
export async function signUpOpenNow(): Promise<boolean> {
  const d = deps();
  return signUpOpen(d.env, await d.store.read());
}

function run<T>(name: string, body: () => Promise<T>): Promise<T> {
  return runCallable(name, body, { map: [reasonErrorMapper(LaunchError, LAUNCH_ERROR_CODES)] });
}

const options = { enforceAppCheck: ENFORCE_APP_CHECK };

/** {} -> { pdpcLicensed, env, signUpOpen, updatedBy, updatedAtMs } (any admin). */
export const adminGetLaunch = onCall(options, (request) =>
  run("adminGetLaunch", async () => {
    await requireAdminCaller(request);
    return getLaunch(deps());
  }),
);

/** { pdpcLicensed, licenceRefs } -> view. Super admins with a sign-in < 30 minutes; audited. */
export const adminSetLaunch = onCall(options, (request) =>
  run("adminSetLaunch", async () => {
    const caller = await requireAdminCaller(request, { superAdmin: true, recentSignIn: true });
    return setLaunch(deps(), caller, request.data, ipOf(request));
  }),
);
