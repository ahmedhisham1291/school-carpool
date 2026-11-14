#!/usr/bin/env bash
# Prompt 12 (CLAUDE.md PRIVACY, DECISIONS.md "Data retention"): encrypt the
# private bucket (ID, selfie, school ID, licence and driver photos, kept
# selfies, thumbnails, route archives) with OUR OWN Cloud KMS key
# (customer-managed encryption key, CMEK). Code cannot create keys; the
# owner runs this once per project. See SETUP.md section 23.2.
#
#   tool/setup_kms.sh <project-id> [bucket]
#
# Cost: one key version about USD 0.06 a month plus 0.03 per 10,000
# operations (docs/COSTS.md). Keep the key: if it is destroyed, every photo
# in the bucket is lost for good. Rotation every 365 days is automatic; old
# versions stay usable for objects they encrypted.
set -euo pipefail

project="${1:?usage: tool/setup_kms.sh <project-id> [bucket]}"
bucket="${2:-${project}.firebasestorage.app}"
location="europe-west1" # same region as the bucket and the functions
ring="school-carpool"
key="private-photos"
key_id="projects/${project}/locations/${location}/keyRings/${ring}/cryptoKeys/${key}"

gcloud services enable cloudkms.googleapis.com --project="${project}"

gcloud kms keyrings describe "${ring}" --location="${location}" --project="${project}" >/dev/null 2>&1 \
  || gcloud kms keyrings create "${ring}" --location="${location}" --project="${project}"

gcloud kms keys describe "${key}" --keyring="${ring}" --location="${location}" --project="${project}" >/dev/null 2>&1 \
  || gcloud kms keys create "${key}" --keyring="${ring}" --location="${location}" --purpose=encryption \
       --rotation-period=365d --next-rotation-time="$(date -u -d '+365 days' +%Y-%m-%dT%H:%M:%SZ)" \
       --protection-level=software --project="${project}"

# Cloud Storage encrypts with the key on our behalf: give ITS service agent
# (not the functions) the encrypter/decrypter role on this key only.
gcloud storage service-agent --project="${project}" --authorize-cmek="${key_id}"

# Every NEW object in the bucket is encrypted with our key. Objects written
# before keep Google's key until they are rewritten (see SETUP 23.2 step 4).
gcloud storage buckets update "gs://${bucket}" --project="${project}" --default-encryption-key="${key_id}"

echo "Bucket gs://${bucket} now encrypts new objects with ${key_id}."
echo "Check: gcloud storage buckets describe gs://${bucket} --format='value(default_kms_key)'"
