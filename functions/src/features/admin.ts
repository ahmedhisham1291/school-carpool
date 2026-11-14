import { AdminError } from "../admin_panel/errors";
import type { AdminCaller } from "../admin_panel/guard";
import type { AuditEntry } from "../admin_panel/types";
import { FEATURE_KEYS, parseFeatureChange, PILOT_DEFAULTS, switchesFrom, type FeatureKey, type FeatureSwitches } from "./model";

/**
 * Admin panel > Settings (pilot feature switches). Every admin sees the
 * switches; only a super admin changes one (the callable requires it), and
 * every change is written to the audit log with the switch and its new
 * value. Pure over [FeatureAdminStore]; unit-tested.
 */

export interface FeatureAdminStore {
  /** config/features as stored (null: no document yet). */
  read(): Promise<Record<string, unknown> | null>;
  /**
   * Sets one switch (merge) with who changed it and when, AND writes the
   * audit entry, in one batch: a change never stands without its log line,
   * and a log line never without its change.
   */
  write(feature: FeatureKey, on: boolean, adminUid: string, nowMs: number, audit: AuditEntry): Promise<void>;
}

export interface FeatureAdminDeps {
  store: FeatureAdminStore;
  now: () => number;
  /** This instance reads the document again on its next call. */
  changed?: () => void;
}

export interface FeaturesView {
  features: FeatureSwitches;
  /** What a missing document or field reads as. */
  defaults: FeatureSwitches;
  keys: readonly FeatureKey[];
}

export async function getFeatures(deps: FeatureAdminDeps): Promise<FeaturesView> {
  return { features: switchesFrom(await deps.store.read()), defaults: PILOT_DEFAULTS, keys: FEATURE_KEYS };
}

/** { feature, on } -> the switches after the change. Super admins only (checked by the callable). */
export async function setFeature(deps: FeatureAdminDeps, caller: AdminCaller, data: unknown, ip: string | null): Promise<FeaturesView> {
  if (caller.role !== "superAdmin") throw new AdminError("invalid-state");
  const change = parseFeatureChange(data);
  if (!change) throw new AdminError("invalid-request");
  const before = switchesFrom(await deps.store.read());
  if (before[change.feature] !== change.on) {
    await deps.store.write(change.feature, change.on, caller.uid, deps.now(), {
      actorUid: caller.uid,
      action: change.on ? "feature.on" : "feature.off",
      target: `config/features#${change.feature}`,
      details: { feature: change.feature, on: change.on },
      ip,
    });
    deps.changed?.();
  }
  return getFeatures(deps);
}
