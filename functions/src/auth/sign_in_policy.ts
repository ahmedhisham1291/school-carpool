/**
 * Who may sign in. Our only way in is the custom token from verifyCode
 * (after a WhatsApp code). The Email/Password provider is on only so the
 * email confirmation link works, so a password, an email link, an SMS code
 * or an anonymous sign-in must never open an account: otherwise whoever
 * controls a parent's inbox could reset a password and sign in without the
 * phone. Enforced by the blocking functions in blocking.ts.
 */
export const BLOCKED_SIGN_IN_METHODS: ReadonlySet<string> = new Set(["password", "emailLink", "phone", "anonymous"]);

/**
 * Unknown methods are allowed on purpose: custom-token sign-in must never be
 * locked out by a value we did not foresee. Everything known to be unsafe
 * is listed above.
 */
export function signInMethodAllowed(method: string | undefined): boolean {
  return method === undefined || !BLOCKED_SIGN_IN_METHODS.has(method);
}

/** Password reset and email sign-in links are never sent. */
export function emailAllowed(emailType: string | undefined): boolean {
  return emailType !== "PASSWORD_RESET" && emailType !== "EMAIL_SIGN_IN";
}

/**
 * Whether confirmEmail is a change: the record does not have this
 * confirmed email yet. Only then does it write and hand out a fresh custom
 * token (a repeat call must not mint tokens).
 */
export function emailConfirmationIsNew(
  record: { email?: unknown; emailVerified?: unknown },
  confirmedEmail: string,
): boolean {
  return record.emailVerified !== true || record.email !== confirmedEmail;
}
