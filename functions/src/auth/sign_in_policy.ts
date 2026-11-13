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

/** What the blocking function knows about the account signing in. */
export interface SignInAccount {
  phoneNumber?: string | null;
  customClaims?: Record<string, unknown> | null;
  disabled?: boolean;
}

/**
 * Admin accounts (F14) are separate accounts: an email address, no phone
 * number, and the "admin" custom claim, which only a super admin (the
 * createAdmin function) or the bootstrap script sets. A parent account
 * always has a phone number and never the claim, so a parent who sets a
 * password on their own account still cannot sign in with it.
 */
export function isAdminAccount(account: SignInAccount | undefined): boolean {
  if (!account || account.disabled === true) return false;
  if (account.phoneNumber) return false;
  return account.customClaims?.admin === true;
}

/**
 * The full sign-in decision: a password is allowed only for an admin
 * account (the panel then asks for the TOTP second factor); every other
 * method follows signInMethodAllowed.
 */
export function signInAllowed(method: string | undefined, account: SignInAccount | undefined): boolean {
  if (method === "password") return isAdminAccount(account);
  return signInMethodAllowed(method);
}

/**
 * Who may CREATE an account. Every account is made on the server with the
 * Admin SDK: parents by verifyCode (phone number), admins by createAdmin
 * or the bootstrap script (email, no password). So any account a client
 * tries to create (email and password sign-up, email link, SMS, a social
 * provider) is refused. Admin SDK creations carry no client credential
 * (and, like anonymous and custom-token sign-ins, may not reach blocking
 * functions at all), so they are allowed.
 */
export function creationAllowed(method: string | undefined): boolean {
  return method === undefined || method === "custom";
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
