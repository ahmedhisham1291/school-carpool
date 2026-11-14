import type { OutboxEvent } from "../notifications/model";
import type { BlockRecord, ChannelRecord, ChatAccount, ChatSettings, MuteRecord, ReportRecord, RequestRecord } from "./model";

/**
 * What chat reads and writes in Firestore (FirestoreChatStore in
 * firestore_store.ts; an in-memory one in the tests).
 */

export interface LatLng {
  lat: number;
  lng: number;
}

export interface SchoolName {
  id: string;
  nameAr: string;
  nameEn: string;
}

export interface AreaInfo {
  id: string;
  schoolId: string;
  nameAr: string;
  nameEn: string;
  center: LatLng | null;
}

export interface CarpoolInfo {
  id: string;
  nameAr: string;
  nameEn: string;
  active: boolean;
}

export type ChatLimitKind = "messages" | "requests" | "reports" | "changes" | "syncs";

export interface ChatStore {
  account(uid: string): Promise<ChatAccount | null>;
  /** Schools of the parent's approved children. */
  childSchoolIds(uid: string): Promise<string[]>;
  /** Children's schools plus driving schools (parentLocations.schoolIds). */
  allSchoolIds(uid: string): Promise<string[]>;
  /** The parent's ROUNDED point (parentLocations), or null without a home pin. */
  roundedPoint(uid: string): Promise<LatLng | null>;
  school(id: string): Promise<SchoolName | null>;
  areasOfSchool(schoolId: string): Promise<AreaInfo[]>;
  carpool(id: string): Promise<CarpoolInfo | null>;
  /** Approved members of the carpool. */
  carpoolMemberUids(carpoolId: string): Promise<string[]>;
  /** Carpools where the parent is an approved member. */
  carpoolIdsOf(uid: string): Promise<string[]>;

  channel(cid: string): Promise<ChannelRecord | null>;
  /**
   * Reads the channel, applies [change] and saves its answer, in one
   * transaction. null from [change] leaves the record as it was.
   */
  updateChannel(cid: string, change: (current: ChannelRecord | null) => ChannelRecord | null): Promise<ChannelRecord | null>;
  /** Every registered channel after [afterCid], by cid (retention job). */
  channelsPage(afterCid: string | null, limit: number): Promise<ChannelRecord[]>;

  /** chatMemberships/{uid}: the school and area groups the sync put the parent in. */
  groupsOf(uid: string): Promise<string[]>;
  putGroupsOf(uid: string, cids: string[], nowMs: number): Promise<void>;

  request(id: string): Promise<RequestRecord | null>;
  putRequest(r: RequestRecord): Promise<void>;

  block(blockerUid: string, blockedUid: string): Promise<BlockRecord | null>;
  putBlock(b: BlockRecord): Promise<void>;
  deleteBlock(blockerUid: string, blockedUid: string): Promise<void>;
  /** Parents who blocked [uid]. */
  blockersOf(uid: string): Promise<string[]>;

  mute(uid: string, cid: string): Promise<boolean | null>;
  putMute(m: MuteRecord): Promise<void>;
  /** Every parent's own mute choice in [cid]: uid -> muted. */
  muteChoices(cid: string): Promise<Map<string, boolean>>;

  settings(uid: string): Promise<ChatSettings>;
  putSettings(uid: string, s: ChatSettings, nowMs: number): Promise<void>;

  takeLimit(uid: string, kind: ChatLimitKind, nowMs: number, rule: { windowMs: number; max: number }): Promise<{ allowed: boolean; retryAfterMs: number }>;

  createReport(r: ReportRecord): Promise<void>;
  report(id: string): Promise<ReportRecord | null>;
  putReport(r: ReportRecord): Promise<void>;
  newReportId(): string;

  /** Notification outbox (Prompt 8). false when the event already exists. */
  createEvent(e: OutboxEvent): Promise<boolean>;
}

/**
 * Urgent reports (spec section 6): the reported driver's driving days pause
 * at once (Prompt 7's release: their runs become open for the group, who
 * are told only that the driver is unavailable).
 */
export interface DrivingPauser {
  pause(uid: string, reportId: string): Promise<{ carpools: number; runs: number }>;
  lift(uid: string): Promise<void>;
}
