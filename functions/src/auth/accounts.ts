import type { Auth } from "firebase-admin/auth";
import { FieldValue, type Firestore } from "firebase-admin/firestore";
import type { Language } from "../whatsapp/sender";
import type { AccountService } from "./otp_flow";
import { pickFreeParentId, type RandomBytes } from "./parent_id";

export const USERS = "users";
/** Reserved parent IDs. Never deleted, so an ID is never reused. */
export const PARENT_IDS = "parentIds";

export type AccountStatus = "unverified" | "pending" | "verified" | "rejected" | "suspended";

/**
 * Fields of a new user record (spec section 9, "User"). The app can only
 * change `language` (firestore.rules); everything else is written here or
 * by later Cloud Functions.
 */
export function newUserRecord(parentId: string, phoneE164: string, language: Language): Record<string, unknown> {
  return {
    parentId,
    status: "unverified" satisfies AccountStatus,
    role: "parent",
    phone: phoneE164,
    email: null,
    emailVerified: false,
    language,
    whatsappOptIn: false,
    termsAcceptedAt: null,
    termsVersion: null,
  };
}

/**
 * Creates the user record and its parent ID in one transaction, unless it
 * exists. The parent ID document is created with `create`, so two
 * transactions can never claim the same ID. Returns the account status.
 */
export async function ensureUserRecord(
  db: Firestore,
  uid: string,
  phoneE164: string,
  language: Language,
  random?: RandomBytes,
): Promise<string> {
  return db.runTransaction(async (tx) => {
    const userRef = db.collection(USERS).doc(uid);
    const existing = await tx.get(userRef);
    if (existing.exists) {
      const status: unknown = existing.get("status");
      return typeof status === "string" ? status : "unverified";
    }
    const parentId = await pickFreeParentId(
      async (id) => (await tx.get(db.collection(PARENT_IDS).doc(id))).exists,
      random,
    );
    tx.create(db.collection(PARENT_IDS).doc(parentId), { uid, createdAt: FieldValue.serverTimestamp() });
    tx.create(userRef, {
      ...newUserRecord(parentId, phoneE164, language),
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    return "unverified";
  });
}

export function errorCode(error: unknown): string | undefined {
  if (typeof error === "object" && error !== null && "code" in error) {
    return String((error as { code: unknown }).code);
  }
  return undefined;
}

export class FirebaseAccountService implements AccountService {
  constructor(
    private readonly auth: Auth,
    private readonly db: Firestore,
  ) {}

  async signInWithPhone(phoneE164: string, language: Language): Promise<{ uid: string; suspended: boolean }> {
    const uid = await this.findOrCreateAuthUser(phoneE164);
    const status = await ensureUserRecord(this.db, uid, phoneE164, language);
    return { uid, suspended: status === "suspended" };
  }

  createToken(uid: string): Promise<string> {
    // No custom claims here: "verified" and "admin" are set by later
    // functions after review.
    return this.auth.createCustomToken(uid);
  }

  private async findOrCreateAuthUser(phoneE164: string): Promise<string> {
    try {
      return (await this.auth.getUserByPhoneNumber(phoneE164)).uid;
    } catch (error) {
      if (errorCode(error) !== "auth/user-not-found") throw error;
    }
    try {
      return (await this.auth.createUser({ phoneNumber: phoneE164 })).uid;
    } catch (error) {
      // Another request created it a moment ago.
      if (errorCode(error) !== "auth/phone-number-already-exists") throw error;
      return (await this.auth.getUserByPhoneNumber(phoneE164)).uid;
    }
  }
}
