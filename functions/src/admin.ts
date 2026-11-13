import { getApps, initializeApp, type App } from "firebase-admin/app";
import { getAuth, type Auth } from "firebase-admin/auth";
import { getFirestore, type Firestore } from "firebase-admin/firestore";

/** The Admin SDK app, created on first use (no work at import time). */
export function adminApp(): App {
  return getApps()[0] ?? initializeApp();
}

export function adminAuth(): Auth {
  return getAuth(adminApp());
}

export function adminDb(): Firestore {
  return getFirestore(adminApp());
}
