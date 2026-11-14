import { DATA_TYPES, type DataTypeId } from "./retention";

/**
 * "Export my data" (spec section 7, Prompt 12): one JSON file with a
 * section for every data type the app keeps (DATA_TYPES), including the
 * parent's own chat messages held by Stream and the wallet history. The
 * file is written to exports/{uid}/{requestId}.json (Cloud Functions only,
 * deleted after a day) and the app gets a link that works for 1 hour.
 *
 * Not in the export, on purpose: other parents' personal data (a rating
 * received shows in the summary only, so the rater stays private; reports
 * about the parent are counted, never shown), internal keys and hashes
 * (removed by [redact]), and the photos themselves (listed with their
 * dates; a copy is sent on request through the privacy team, so ID images
 * never sit in a downloadable file).
 */

export const EXPORT_FORMAT = 1;
export const EXPORT_LINK_MS = 60 * 60_000;

export interface ExportSource {
  /** One section's data, already limited to what is the parent's own. */
  section(uid: string, id: DataTypeId): Promise<unknown>;
  /** Sections where a list reached its read limit (the file says it is partial). */
  truncated?(): DataTypeId[];
}

export interface ExportFile {
  format: number;
  createdAt: string;
  /** Plain-language note in both languages. */
  note: { ar: string; en: string };
  sections: Record<DataTypeId, unknown>;
  /** Sections that could not be read (the file says so instead of failing). */
  missing: DataTypeId[];
  /** Sections cut at a read limit (the oldest items left out); ask the privacy team for the rest. */
  truncated: DataTypeId[];
}

/** Keys never written to an export (internal keys, hashes and tokens). */
const SECRET_KEY = /^(ip|.*(hash|token|secret|apikey|signature|walletref|customerref|devicekey|installid))$/i;

/** Removes internal keys at any depth; keeps everything else as it is. */
export function redact(value: unknown, depth = 0): unknown {
  if (depth > 12) return null;
  if (Array.isArray(value)) return value.map((v) => redact(v, depth + 1));
  if (value !== null && typeof value === "object") {
    if (value instanceof Date) return value.toISOString();
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      if (SECRET_KEY.test(k)) continue;
      out[k] = redact(v, depth + 1);
    }
    return out;
  }
  return value;
}

export async function buildExport(source: ExportSource, uid: string, nowMs: number, onError: (id: DataTypeId, error: unknown) => void): Promise<ExportFile> {
  const sections = {} as Record<DataTypeId, unknown>;
  const missing: DataTypeId[] = [];
  for (const id of DATA_TYPES) {
    try {
      sections[id] = redact(await source.section(uid, id));
    } catch (error) {
      sections[id] = null;
      missing.push(id);
      onError(id, error);
    }
  }
  return {
    format: EXPORT_FORMAT,
    createdAt: new Date(nowMs).toISOString(),
    note: {
      ar: "هذه نسخة من بياناتك في تطبيق مشاركة التوصيل المدرسي. الصور مذكورة بتواريخها فقط؛ اطلب نسخة منها من شاشة الخصوصية.",
      en: "A copy of your data in the School Carpool app. Photos are listed with their dates only; ask for a copy from the privacy screen.",
    },
    sections,
    missing,
    truncated: source.truncated ? source.truncated() : [],
  };
}

export function exportPath(uid: string, requestId: string): string {
  return `exports/${uid}/${requestId}.json`;
}
