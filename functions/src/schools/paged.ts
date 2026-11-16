import { FieldPath, type Firestore, type QueryDocumentSnapshot, type QuerySnapshot } from "firebase-admin/firestore";

/**
 * Reads a whole collection in pages ordered by document ID (500 per page by
 * default), each page retried a few times, so no single answer is large or
 * slow: one query for 7,000+ schools ran into Firestore's 300 s deadline
 * from Cloud Shell (16 Nov 2026). [select] limits the fields read. [onPage]
 * gets each page as it arrives (scripts handle it, then read the next one,
 * so a stopped run keeps what it did).
 */
export async function forEachPage(
  db: Firestore,
  collection: string,
  onPage: (docs: QueryDocumentSnapshot[]) => Promise<void> | void,
  options: { pageSize?: number; select?: readonly string[]; retries?: number; sleep?: (ms: number) => Promise<void> } = {},
): Promise<number> {
  const pageSize = options.pageSize ?? 500;
  const retries = options.retries ?? 4;
  const pause = options.sleep ?? ((ms: number) => new Promise<void>((done) => setTimeout(done, ms)));
  let last: QueryDocumentSnapshot | undefined;
  let total = 0;
  for (;;) {
    let query = db.collection(collection).orderBy(FieldPath.documentId()).limit(pageSize);
    if (options.select && options.select.length > 0) query = query.select(...options.select);
    if (last) query = query.startAfter(last);
    const page: QuerySnapshot = await withRetries<QuerySnapshot>(() => query.get(), retries, pause);
    total += page.docs.length;
    await onPage(page.docs);
    if (page.docs.length < pageSize) return total;
    last = page.docs[page.docs.length - 1];
  }
}

/** Every document of [collection], read with forEachPage. */
export async function readAll(
  db: Firestore,
  collection: string,
  options: { pageSize?: number; select?: readonly string[] } = {},
): Promise<QueryDocumentSnapshot[]> {
  const out: QueryDocumentSnapshot[] = [];
  await forEachPage(db, collection, (docs) => {
    out.push(...docs);
  }, options);
  return out;
}

/** Runs [call]; on an error tries again up to [retries] times, waiting 5 s, 10 s, ... */
export async function withRetries<T>(call: () => Promise<T>, retries = 4, pause: (ms: number) => Promise<void> = (ms) => new Promise((d) => setTimeout(d, ms))): Promise<T> {
  for (let attempt = 1; ; attempt++) {
    try {
      return await call();
    } catch (error) {
      if (attempt > retries) throw error;
      await pause(attempt * 5000);
    }
  }
}
