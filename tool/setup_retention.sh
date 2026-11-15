#!/usr/bin/env bash
# Prompt 12: storage optimisation and retention settings for ONE Firebase
# project (dev, staging or prod). Safe to run again. Needs gcloud signed in
# as an owner of the project. Nothing here can be done from the app or the
# functions; see SETUP.md section 23.
#
#   tool/setup_retention.sh <project-id> [bucket]
#
# 1. Cloud Storage lifecycle (tool/storage_lifecycle.json): kept photos go
#    to Nearline after 30 days and Coldline after 180 days; route archives
#    are Coldline at once and deleted after 400 days (retentionDaily deletes
#    them at 365); exports and live selfies older than 2 days are deleted.
# 2. Soft delete: 7 days (Google's default) stays on, so a deleted object
#    can be restored for a week after a mistake; the privacy policy says
#    "deleted, and gone from backups within 7 days".
# 3. Firestore TTL policies, one per collection that carries an expiry
#    field (Firestore deletes expired documents within about 24 hours, free).
set -euo pipefail

#   tool/setup_retention.sh <prod-id> --prod   also switches on point-in-time
#                                              recovery (owner decision: on in prod)
project="${1:?usage: tool/setup_retention.sh <project-id> [bucket|--prod]}"
prod=false
bucket="${project}.firebasestorage.app"
if [ "${2:-}" = "--prod" ]; then prod=true; elif [ -n "${2:-}" ]; then bucket="$2"; fi
here="$(cd "$(dirname "$0")" && pwd)"

echo "== Cloud Storage lifecycle on gs://${bucket}"
gcloud storage buckets update "gs://${bucket}" --project="${project}" --lifecycle-file="${here}/storage_lifecycle.json"
gcloud storage buckets update "gs://${bucket}" --project="${project}" --soft-delete-duration=7d

echo "== Firestore TTL policies"
# field  collection-group
# A policy that is already on (ACTIVE) or being built (CREATING) is left
# alone, so the script is safe to run again (tool/cloud_setup.sh calls it).
ttl() {
  local state
  # (`gcloud firestore fields` has only the `ttls` group; the field's
  # ttlConfig is read with `gcloud firestore indexes fields describe`.)
  state="$(gcloud firestore indexes fields describe "$1" --collection-group="$2" --project="${project}" \
    --format='value(ttlConfig.state)' 2>/dev/null || true)"
  case "${state}" in
    ACTIVE|CREATING) echo "  $2.$1: already ${state}"; return 0 ;;
  esac
  gcloud firestore fields ttls update "$1" --collection-group="$2" --enable-ttl --project="${project}" --async --quiet
}
# Sign-in (Prompt 2)
ttl expireAt otpCodes
ttl expireAt otpLimits
# Maps (Prompt 5), carpools (Prompt 6), schedule (Prompt 7)
ttl expiresAt placeCache
ttl expiresAt carpoolInvites
ttl expiresAt carpoolWanted
ttl expiresAt scheduleEvents
# Notifications (Prompt 8)
ttl expiresAt notificationEvents
ttl expiresAt notifications
# Chat: requests and push records. Messages have NO TTL: a chat is kept for
# its life + 1 year and then deleted whole by retentionDaily (docs/DECISIONS.md).
ttl expiresAt chatRequests
ttl expiresAt chatPushes
# The message trigger's per-message markers (2 days)
ttl expiresAt fanned
# Trips (Prompt 10): live points within 24 hours
ttl expiresAt points
ttl expiresAt eta
ttl expiresAt emergencies
ttl expiresAt tripStops
ttl expiresAt tripChecks
# Privacy (Prompt 12)
ttl expiresAt privacyRequests
ttl expiresAt abuseCounters
ttl expiresAt logins
ttl expiresAt devices
ttl expiresAt mail
ttl expiresAt retentionRuns
ttl expiresAt walletDaily

if [ "${prod}" = true ]; then
  echo "== Point-in-time recovery (prod)"
  gcloud firestore databases update --database='(default)' --enable-pitr --project="${project}"
fi

echo "Done. Check: Firestore > TTL policies (each one 'Serving' after a few minutes),"
echo "and Cloud Storage > ${bucket} > Lifecycle."
