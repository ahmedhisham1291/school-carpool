import { FieldValue, Timestamp, type DocumentData, type Firestore, type QueryDocumentSnapshot, type Transaction, type WriteBatch } from "firebase-admin/firestore";
import { AUDIT_LOG, SCHOOLS, auditDoc } from "../admin_panel/store";
import type { AuditEntry } from "../admin_panel/types";
import { HOMES, PARENT_LOCATIONS } from "../maps/store";
import type { PlaceKind, PlaceRequestItem, PlacesAdminStore, SchoolPlace } from "./admin";
import { PLACE_AREAS, PLACE_DISTRICTS, PLACE_INDEX, PLACE_INDEX_AREAS, PLACE_REQUESTS, buildIndex, type PlaceArea, type PlaceDistrict } from "./catalog";
import { FirestorePlaceLocator, areaFromDoc, districtFromDoc } from "./store";

/**
 * Firestore side of the admin "Places" section (admin.ts). Big moves
 * (schools, addresses) go in batches of BATCH; each batch that changes a
 * place also carries its audit entry only once (the first batch).
 */

const BATCH = 400;

function millis(v: unknown): number {
  const t = v as { toMillis?: () => number } | null | undefined;
  return typeof t?.toMillis === "function" ? t.toMillis() : 0;
}

export class FirestorePlacesAdminStore implements PlacesAdminStore {
  constructor(private readonly db: Firestore) {}

  private col(kind: PlaceKind) {
    return this.db.collection(kind === "area" ? PLACE_AREAS : PLACE_DISTRICTS);
  }

  newId(kind: PlaceKind): string {
    return `adm-${this.col(kind).doc().id}`.slice(0, 64);
  }

  async listAreas(governorate: string): Promise<PlaceArea[]> {
    const snap = await this.db.collection(PLACE_AREAS).where("governorate", "==", governorate).limit(500).get();
    return snap.docs.map((d: QueryDocumentSnapshot) => areaFromDoc(d.id, d.data()));
  }

  async listDistricts(areaId: string): Promise<PlaceDistrict[]> {
    const snap = await this.db.collection(PLACE_DISTRICTS).where("areaId", "==", areaId).limit(500).get();
    return snap.docs.map((d: QueryDocumentSnapshot) => districtFromDoc(d.id, d.data()));
  }

  async area(id: string): Promise<PlaceArea | null> {
    const snap = await this.db.collection(PLACE_AREAS).doc(id).get();
    return snap.exists ? areaFromDoc(id, snap.data() ?? {}) : null;
  }

  async district(id: string): Promise<PlaceDistrict | null> {
    const snap = await this.db.collection(PLACE_DISTRICTS).doc(id).get();
    return snap.exists ? districtFromDoc(id, snap.data() ?? {}) : null;
  }

  /** Updates every document of [query] in batches; [first] adds the audit entry to the first batch. */
  private async updateAll(docs: QueryDocumentSnapshot[], fields: DocumentData, first?: (b: WriteBatch) => void): Promise<void> {
    if (docs.length === 0 && first) {
      const b = this.db.batch();
      first(b);
      await b.commit();
      return;
    }
    for (let i = 0; i < docs.length; i += BATCH) {
      const b = this.db.batch();
      if (i === 0 && first) first(b);
      for (const d of docs.slice(i, i + BATCH)) b.update(d.ref, fields);
      await b.commit();
    }
  }

  async saveArea(area: { id: string; governorate: string; nameAr: string; nameEn: string }, isNew: boolean, audit: AuditEntry): Promise<void> {
    const ref = this.db.collection(PLACE_AREAS).doc(area.id);
    const now = FieldValue.serverTimestamp();
    if (isNew) {
      const b = this.db.batch();
      b.create(ref, {
        governorate: area.governorate, nameAr: area.nameAr, nameEn: area.nameEn, level: 0, source: "admin",
        centre: null, bbox: null, rings: [], schoolCount: 0, addressCount: 0, active: true, mergedInto: null,
        adminEdited: true, createdAt: now, updatedAt: now,
      });
      b.create(this.db.collection(AUDIT_LOG).doc(), auditDoc(audit));
      await b.commit();
      return;
    }
    // A rename: the area's own record, then the names copied on its schools
    // (search shows them; syncSchoolToSearch re-indexes each school).
    const schools = await this.db.collection(SCHOOLS).where("placeAreaId", "==", area.id).get();
    await this.updateAll(
      schools.docs,
      { placeAreaNameAr: area.nameAr, placeAreaNameEn: area.nameEn, updatedAt: now },
      (b) => {
        b.update(ref, { nameAr: area.nameAr, nameEn: area.nameEn, adminEdited: true, updatedAt: now });
        b.create(this.db.collection(AUDIT_LOG).doc(), auditDoc({ ...audit, details: { ...audit.details, schools: schools.size } }));
      },
    );
  }

  async saveDistrict(
    d: { id: string; areaId: string; governorate: string; nameAr: string; nameEn: string; source: string },
    isNew: boolean,
    audit: AuditEntry,
  ): Promise<void> {
    const ref = this.db.collection(PLACE_DISTRICTS).doc(d.id);
    const now = FieldValue.serverTimestamp();
    const b = this.db.batch();
    if (isNew) {
      b.create(ref, {
        areaId: d.areaId, governorate: d.governorate, nameAr: d.nameAr, nameEn: d.nameEn, source: d.source,
        centre: null, bbox: null, rings: [], schoolCount: 0, addressCount: 0, active: true, mergedInto: null,
        adminEdited: true, createdAt: now, updatedAt: now,
      });
    } else {
      b.update(ref, { nameAr: d.nameAr, nameEn: d.nameEn, adminEdited: true, updatedAt: now });
    }
    b.create(this.db.collection(AUDIT_LOG).doc(), auditDoc(audit));
    await b.commit();
  }

  async setActive(kind: PlaceKind, id: string, active: boolean, audit: AuditEntry): Promise<void> {
    const b = this.db.batch();
    b.update(this.col(kind).doc(id), { active, adminEdited: true, updatedAt: FieldValue.serverTimestamp() });
    b.create(this.db.collection(AUDIT_LOG).doc(), auditDoc(audit));
    await b.commit();
    if (kind === "area") await this.rebuildIndex();
  }

  async merge(kind: PlaceKind, fromId: string, intoId: string, audit: AuditEntry): Promise<number> {
    const now = FieldValue.serverTimestamp();
    const [from, into] = await Promise.all([this.col(kind).doc(fromId).get(), this.col(kind).doc(intoId).get()]);
    const schoolField = kind === "area" ? "placeAreaId" : "placeDistrictId";
    const schools = await this.db.collection(SCHOOLS).where(schoolField, "==", fromId).get();
    const homes = await this.db.collection(HOMES).where(`address.${schoolField}`, "==", fromId).get();
    const publics = await this.db.collection(PARENT_LOCATIONS).where(schoolField, "==", fromId).get();
    const schoolFields: DocumentData = { [schoolField]: intoId, updatedAt: now };
    if (kind === "area") {
      schoolFields.placeAreaNameAr = String(into.get("nameAr") ?? "");
      schoolFields.placeAreaNameEn = String(into.get("nameEn") ?? "");
    }
    await this.updateAll(schools.docs, schoolFields, (b) => {
      b.update(from.ref, { active: false, mergedInto: intoId, adminEdited: true, updatedAt: now });
      b.update(into.ref, {
        schoolCount: FieldValue.increment(Number(from.get("schoolCount") ?? 0)),
        addressCount: FieldValue.increment(Number(from.get("addressCount") ?? 0)),
        updatedAt: now,
      });
      b.create(
        this.db.collection(AUDIT_LOG).doc(),
        auditDoc({ ...audit, details: { ...audit.details, schools: schools.size, addresses: homes.size } }),
      );
    });
    await this.updateAll(homes.docs, { [`address.${schoolField}`]: intoId, updatedAtMs: Date.now() });
    await this.updateAll(publics.docs, { [schoolField]: intoId });
    if (kind === "area") {
      const districts = await this.db.collection(PLACE_DISTRICTS).where("areaId", "==", fromId).get();
      await this.updateAll(districts.docs, { areaId: intoId, updatedAt: now });
      await this.rebuildIndex();
    }
    return schools.size;
  }

  async school(id: string): Promise<SchoolPlace | null> {
    const snap = await this.db.collection(SCHOOLS).doc(id).get();
    if (!snap.exists) return null;
    const d = snap.data() ?? {};
    return {
      id,
      status: String(d.status ?? "active"),
      governorate: String(d.governorate ?? ""),
      placeAreaId: typeof d.placeAreaId === "string" ? d.placeAreaId : "",
      placeDistrictId: typeof d.placeDistrictId === "string" ? d.placeDistrictId : null,
    };
  }

  async moveSchool(schoolId: string, from: SchoolPlace, area: PlaceArea, district: PlaceDistrict | null, audit: AuditEntry): Promise<void> {
    const now = FieldValue.serverTimestamp();
    const b = this.db.batch();
    b.update(this.db.collection(SCHOOLS).doc(schoolId), {
      placeAreaId: area.id,
      placeAreaNameAr: area.nameAr,
      placeAreaNameEn: area.nameEn,
      placeDistrictId: district?.id ?? null,
      adminEdited: true,
      updatedAt: now,
    });
    const counted = from.status === "active";
    if (counted && from.placeAreaId !== area.id) {
      if (from.placeAreaId) b.set(this.db.collection(PLACE_AREAS).doc(from.placeAreaId), { schoolCount: FieldValue.increment(-1) }, { merge: true });
      b.update(this.db.collection(PLACE_AREAS).doc(area.id), { schoolCount: FieldValue.increment(1) });
    }
    const newDistrict = district?.id ?? null;
    if (counted && from.placeDistrictId !== newDistrict) {
      if (from.placeDistrictId) b.set(this.db.collection(PLACE_DISTRICTS).doc(from.placeDistrictId), { schoolCount: FieldValue.increment(-1) }, { merge: true });
      if (newDistrict) b.update(this.db.collection(PLACE_DISTRICTS).doc(newDistrict), { schoolCount: FieldValue.increment(1) });
    }
    b.create(this.db.collection(AUDIT_LOG).doc(), auditDoc(audit));
    await b.commit();
  }

  async listRequests(limit: number): Promise<PlaceRequestItem[]> {
    const snap = await this.db.collection(PLACE_REQUESTS).where("status", "==", "open").orderBy("createdAt").limit(limit).get();
    return snap.docs.map((d: QueryDocumentSnapshot) => ({
      id: d.id,
      areaId: String(d.get("areaId") ?? ""),
      governorate: String(d.get("governorate") ?? ""),
      text: String(d.get("text") ?? ""),
      createdAtMs: millis(d.get("createdAt")),
    }));
  }

  async request(id: string): Promise<(PlaceRequestItem & { uid: string; status: string }) | null> {
    const snap = await this.db.collection(PLACE_REQUESTS).doc(id).get();
    if (!snap.exists) return null;
    return {
      id,
      uid: String(snap.get("uid") ?? ""),
      status: String(snap.get("status") ?? "open"),
      areaId: String(snap.get("areaId") ?? ""),
      governorate: String(snap.get("governorate") ?? ""),
      text: String(snap.get("text") ?? ""),
      createdAtMs: millis(snap.get("createdAt")),
    };
  }

  async resolveRequest(id: string, districtId: string | null, audit: AuditEntry): Promise<void> {
    const ref = this.db.collection(PLACE_REQUESTS).doc(id);
    await this.db.runTransaction(async (tx: Transaction) => {
      // Every read before any write (Firestore transactions).
      const snap = await tx.get(ref);
      if (!snap.exists || snap.get("status") !== "open") return;
      const uid = String(snap.get("uid") ?? "");
      const home = uid ? this.db.collection(HOMES).doc(uid) : null;
      const pub = uid ? this.db.collection(PARENT_LOCATIONS).doc(uid) : null;
      const homeSnap = home ? await tx.get(home) : null;
      const pubSnap = pub ? await tx.get(pub) : null;
      tx.update(ref, { status: "done", districtId, resolvedAt: FieldValue.serverTimestamp() });
      // Only while the address still names this request's area and has no district.
      if (
        districtId && home && homeSnap?.exists &&
        homeSnap.get("address.placeAreaId") === snap.get("areaId") && !homeSnap.get("address.placeDistrictId")
      ) {
        tx.update(home, { "address.placeDistrictId": districtId, "address.districtText": "", updatedAtMs: Date.now() });
        tx.update(this.db.collection(PLACE_DISTRICTS).doc(districtId), { addressCount: FieldValue.increment(1) });
        if (pub && pubSnap?.exists) tx.update(pub, { placeDistrictId: districtId });
      }
      tx.create(this.db.collection(AUDIT_LOG).doc(), auditDoc(audit));
    });
  }

  /** placeIndex/areas from every area (after a deactivation or a merge). */
  async rebuildIndex(): Promise<void> {
    const snap = await this.db.collection(PLACE_AREAS).get();
    const areas = snap.docs.map((d: QueryDocumentSnapshot) => areaFromDoc(d.id, d.data()));
    await this.db.collection(PLACE_INDEX).doc(PLACE_INDEX_AREAS).set({ areas: buildIndex(areas), updatedAt: Timestamp.now() });
    FirestorePlaceLocator.forget();
  }
}
