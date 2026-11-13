/**
 * Which writes change a parent's public map record (parentLocations).
 * The triggers in callables.ts run on every write to users/{uid} and
 * children/{id}; this keeps them from reading anything when nothing that
 * matters changed (most writes, for example the app language).
 */

type Data = Record<string, unknown> | undefined;

const USER_FIELDS = ["status", "firstName", "banned"] as const;
const CHILD_FIELDS = ["status", "schoolId", "ownerUid"] as const;

export function mapRefreshNeeded(kind: "user" | "child", before: Data, after: Data): boolean {
  if (!before || !after) return true; // created or deleted
  const fields = kind === "user" ? USER_FIELDS : CHILD_FIELDS;
  return fields.some((f) => JSON.stringify(before[f] ?? null) !== JSON.stringify(after[f] ?? null));
}
