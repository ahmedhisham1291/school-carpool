import { GeoPoint, Timestamp, type DocumentData } from "firebase-admin/firestore";
import { EVENT_TTL_DAYS, type OutboxEvent } from "./model";

/** The notification outbox (Prompt 8). Cloud Functions only (firestore.rules). */
export const NOTIFICATION_EVENTS = "notificationEvents";

const DAY = 86_400_000;
const ts = (ms: number): Timestamp => Timestamp.fromMillis(ms);

/** The outbox document of [e] (any producer). */
export function outboxDoc(e: OutboxEvent): DocumentData {
  return {
    type: e.type,
    recipients: e.recipients,
    carpoolId: e.carpoolId,
    runId: e.runId,
    date: e.date,
    direction: e.direction,
    actorUid: e.actorUid,
    childId: e.childId,
    subjectUid: e.subjectUid,
    schoolIds: e.schoolIds,
    point: e.point ? new GeoPoint(e.point.lat, e.point.lng) : null,
    refEventId: e.refEventId,
    critical: e.critical,
    status: e.status,
    createdAt: ts(e.createdAtMs),
    // Firestore TTL field (SETUP.md section 18).
    expiresAt: ts(e.createdAtMs + EVENT_TTL_DAYS * DAY),
  };
}

