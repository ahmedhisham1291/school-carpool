#!/usr/bin/env bash
# One-time (and safe to rerun) setup of the STAGING Firebase / Google Cloud
# project, run by the owner in Google Cloud Shell (browser terminal, nothing
# to install). Plain-English guide: docs/owner-cloud-shell.md.
#
#   git clone https://github.com/ahmedhisham1291/school-carpool.git && cd school-carpool
#   bash tool/cloud_setup.sh staging school-carpool-staging <admin-email>
#
# Optional flag:
#   --replace-algolia  ask for the Algolia keys again even if real ones are
#                      stored (otherwise only the placeholder 'unused' is
#                      replaced; docs/algolia-setup.md)
#
# Optional environment:
#   APPLE_TEAM_ID   10-character Apple Team ID (asked for if not set; Enter
#                   skips the invite-links site and App Attest)
#   ADMIN_NAME      name of the first super admin (default "Owner")
#   SKIP_ADMIN_WEB=1  do not download Flutter / build the admin panel
#   FLUTTER_HOME    where to keep the Flutter SDK (default ~/flutter)
#   WIKIDATA_CONTACT  email or web page put in the User-Agent of the Wikidata
#                   download (Wikimedia's User-Agent policy asks for one;
#                   default: the <admin-email> argument)
#   SKIP_SCHOOLS_FETCH=1  do not download the OpenStreetMap and Wikidata schools lists
#                   (the last download, if any, is used; a download newer
#                   than 7 days is never repeated)
#
# What it does, in order (each step checks first and skips what is done):
#   1  checks: Blaze billing, Firestore and Storage in europe-west1; APIs on
#   2  sign-in for the tools (gcloud, Application Default Credentials, firebase)
#   3  Identity Platform: on, Email/Password on, sign-up and delete off, SMS denied
#   4  service-account roles (SETUP 11.2, Eventarc, Storage trigger)
#   5  Maps keys (iOS key, server key)          6  secrets in Secret Manager,
#                                                  Algolia keys (asked once)
#   7  Hosting sites (links, admin)             8  Firebase apps + Dart options file
#   9  App Check (App Attest, reCAPTCHA Enterprise for the admin site)
#   10 authorized domains, Storage CORS, retention (TTL, lifecycle), KMS key
#   11 deploy rules, indexes, storage rules and functions
#   12 schools: OpenStreetMap download, import, load, Algolia index
#                                                13 links site
#   14 admin panel: TOTP, Flutter web build, deploy  15 first super admin
#   16 budget USD 20 (5 / 25 / 100 percent)        17 checklist of what is left
#
# Never prints a secret, except the iOS Maps key (for Codemagic) and the
# one-time admin link (open it yourself, at once).
set -Eeuo pipefail

FIREBASE_TOOLS="firebase-tools@15"   # same major as CI (.github/workflows/checks.yml)
REGION="europe-west1"
BUNDLE_ID="org.schoolcarpool.app.stg"
IOS_APP_NAME="School Carpool Stg"
WEB_APP_NAME="School Carpool Stg Web"

# ---------------------------------------------------------------- arguments
usage() {
  echo "usage: bash tool/cloud_setup.sh staging <project-id> <admin-email> [--replace-algolia]" >&2
  exit 2
}
REPLACE_ALGOLIA=""
POSITIONAL=()
for arg in "$@"; do
  case "${arg}" in
    --replace-algolia) REPLACE_ALGOLIA=1 ;;
    --*) usage ;;
    *) POSITIONAL+=("${arg}") ;;
  esac
done
[ "${#POSITIONAL[@]}" -eq 3 ] || usage
set -- "${POSITIONAL[@]}"
ENV_NAME="$1"
PROJECT="$2"
ADMIN_EMAIL="$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')"
ADMIN_NAME="${ADMIN_NAME:-Owner}"
[ "${ENV_NAME}" = "staging" ] || { echo "Only 'staging' is supported by this script." >&2; exit 2; }
[[ "${PROJECT}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || { echo "'${PROJECT}' is not a valid project id." >&2; exit 2; }
[[ "${ADMIN_EMAIL}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { echo "'$3' is not a valid email." >&2; exit 2; }
case "${PROJECT}" in *prod*) echo "This looks like a production project; this script is for staging only." >&2; exit 2 ;; esac

cd "$(dirname "$0")/.."
if [ ! -f firebase.json ] || [ ! -f functions/package.json ]; then echo "Run this from the school-carpool repository." >&2; exit 2; fi

# The repository records the staging project id in .firebaserc: they must match.
COMMITTED="$(python3 -c 'import json;print(json.load(open(".firebaserc"))["projects"].get("staging",""))')"
if [ -n "${COMMITTED}" ] && [[ "${COMMITTED}" != REPLACE-* ]] && [ "${COMMITTED}" != "${PROJECT}" ]; then
  echo "The repository's staging project is '${COMMITTED}', not '${PROJECT}'. Check the id (Firebase console > Project settings)." >&2
  exit 2
fi

LINKS_SITE="${PROJECT}-links"
ADMIN_SITE="${PROJECT}-admin"
ENV_FILE="functions/.env.staging"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ------------------------------------------------------------------ helpers
DONE=()
TODO=()
step() { printf '\n==== %s ====\n' "$*"; }
ok() { DONE+=("$1"); printf '  [done] %s\n' "$1"; }
todo() { TODO+=("$1"); printf '  [to do] %s\n' "$1"; }
die() { printf '\nSTOPPED: %s\n' "$1" >&2; printf 'Fix that, then run the same command again (finished steps are skipped).\n' >&2; exit 1; }
on_error() {
  [ "${BASH_SUBSHELL}" -eq 0 ] || return 0
  printf '\nSTOPPED: a command failed at line %s of tool/cloud_setup.sh (see the message above).\nRun the same command again; finished steps are skipped. If it fails again, copy the message (not any key) to the developer.\n' "$1" >&2
}
trap 'on_error $LINENO' ERR

# Runs a function in a subshell with errexit ON; the result is in STEP_RC.
# (Calling a function inside `if` would silently switch errexit off.)
STEP_RC=0
run_step() {
  trap - ERR; set +e
  ( set -e; "$@" )
  STEP_RC=$?
  set -e; trap 'on_error $LINENO' ERR
}

env_value() { # KEY DEFAULT: value from functions/.env.staging
  local v
  v="$(grep -E "^$1=" "${ENV_FILE}" | tail -1 | cut -d= -f2- || true)"
  printf '%s' "${v:-$2}"
}

set_env() { # KEY VALUE: in functions/.env.staging (non-secret values only)
  if grep -qE "^$1=" "${ENV_FILE}"; then
    sed -i "s#^$1=.*#$1=$2#" "${ENV_FILE}"
  else
    printf '%s=%s\n' "$1" "$2" >>"${ENV_FILE}"
  fi
}

fb() { npx --yes "${FIREBASE_TOOLS}" "$@" --project staging --non-interactive; }

# api METHOD URL [JSON]: response body in ${WORK}/api.json, HTTP code in API_CODE.
API_OUT="${WORK}/api.json"
API_CODE=000
api() {
  local args=(-sS -o "${API_OUT}" -w '%{http_code}' -X "$1"
    -H "Authorization: Bearer $(gcloud auth print-access-token)"
    -H "x-goog-user-project: ${PROJECT}" -H "Content-Type: application/json")
  [ -n "${3:-}" ] && args+=(--data "$3")
  API_CODE="$(curl "${args[@]}" "$2" 2>/dev/null || echo 000)"
  [[ "${API_CODE}" == 2* ]]
}
# jq-free JSON read: jget 'python expression over d' (d = last API response)
jget() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($1)" "${API_OUT}" 2>/dev/null || true; }
api_error() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('error',{}).get('message','')[:300])" "${API_OUT}" 2>/dev/null || true; }

CONSOLE="https://console.firebase.google.com/project/${PROJECT}"
GCP="https://console.cloud.google.com"
IDTK="https://identitytoolkit.googleapis.com/admin/v2/projects/${PROJECT}/config"

# Apple Team ID (not secret): needed for the invite-links site and App Attest.
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
if [ -z "${APPLE_TEAM_ID}" ] && [ -t 0 ]; then
  echo "Apple Team ID (developer.apple.com > Account > Membership details, 10 letters/digits)."
  read -r -p "Type it and press Enter, or just press Enter to skip: " APPLE_TEAM_ID || true
fi
APPLE_TEAM_ID="$(printf '%s' "${APPLE_TEAM_ID}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
if [ -n "${APPLE_TEAM_ID}" ] && ! [[ "${APPLE_TEAM_ID}" =~ ^[A-Z0-9]{10}$ ]]; then
  die "the Apple Team ID must be 10 letters or digits (got '${APPLE_TEAM_ID}')."
fi

# ============================================================== 1. checks
step "1. Project, billing, Firestore, Storage, APIs"
for tool in gcloud git node npm npx openssl python3 curl; do
  command -v "${tool}" >/dev/null 2>&1 || die "'${tool}' is missing. Run this in Google Cloud Shell."
done
ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"
[ -n "${ACCOUNT}" ] || die "gcloud is not signed in. In Cloud Shell run: gcloud auth login"
gcloud config set project "${PROJECT}" --quiet >/dev/null 2>&1
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT}" --format='value(projectNumber)' 2>/dev/null || true)"
[ -n "${PROJECT_NUMBER}" ] || die "project '${PROJECT}' not found, or ${ACCOUNT} is not an owner of it."
ok "project ${PROJECT} (number ${PROJECT_NUMBER}), signed in as ${ACCOUNT}"

gcloud services enable cloudbilling.googleapis.com serviceusage.googleapis.com \
  cloudresourcemanager.googleapis.com --project="${PROJECT}" --quiet
BILLING_ENABLED="$(gcloud billing projects describe "${PROJECT}" --format='value(billingEnabled)' 2>/dev/null || true)"
BILLING_ACCOUNT="$(gcloud billing projects describe "${PROJECT}" --format='value(billingAccountName)' 2>/dev/null || true)"
if [ "${BILLING_ENABLED}" != "True" ]; then
  die "the project is not on the Blaze plan. Open ${CONSOLE}/usage/details > Modify plan > Blaze (pay as you go), pick your billing account, then run this again."
fi
ok "Blaze billing on (${BILLING_ACCOUNT#billingAccounts/})"

APIS=(
  firebase.googleapis.com firestore.googleapis.com firebaserules.googleapis.com
  storage.googleapis.com firebasestorage.googleapis.com cloudfunctions.googleapis.com
  cloudbuild.googleapis.com artifactregistry.googleapis.com run.googleapis.com
  eventarc.googleapis.com pubsub.googleapis.com secretmanager.googleapis.com
  cloudscheduler.googleapis.com identitytoolkit.googleapis.com securetoken.googleapis.com
  fcm.googleapis.com fcmregistrations.googleapis.com firebaseinstallations.googleapis.com
  firebaseappcheck.googleapis.com firebasehosting.googleapis.com
  cloudkms.googleapis.com iamcredentials.googleapis.com iam.googleapis.com
  compute.googleapis.com logging.googleapis.com
  maps-ios-backend.googleapis.com places.googleapis.com routes.googleapis.com
  apikeys.googleapis.com recaptchaenterprise.googleapis.com billingbudgets.googleapis.com
  aiplatform.googleapis.com
)
# gcloud takes at most 20 services per call.
gcloud services enable "${APIS[@]:0:20}" --project="${PROJECT}" --quiet
gcloud services enable "${APIS[@]:20}" --project="${PROJECT}" --quiet
ok "APIs on (${#APIS[@]}: Firebase, Functions, Maps SDK for iOS, Places API (New), Routes, KMS, ...)"

DB_LOCATION="$(gcloud firestore databases describe --database='(default)' --project="${PROJECT}" --format='value(locationId)' 2>/dev/null || true)"
if [ -z "${DB_LOCATION}" ]; then
  die "Firestore is not created yet. Open ${CONSOLE}/firestore > Create database > Standard edition > location europe-west1 (Belgium) > Production mode > Create. Then run this again."
fi
[ "${DB_LOCATION}" = "${REGION}" ] || die "Firestore is in '${DB_LOCATION}', not ${REGION}. This cannot be changed; the project must be recreated (SETUP.md 3.3)."
ok "Firestore (default) in ${REGION}"

BUCKET=""
for b in "${PROJECT}.firebasestorage.app" "${PROJECT}.appspot.com"; do
  if gcloud storage buckets describe "gs://${b}" --format='value(name)' >/dev/null 2>&1; then BUCKET="${b}"; break; fi
done
[ -n "${BUCKET}" ] || die "Storage is not set up yet. Open ${CONSOLE}/storage > Get started > Production mode > location europe-west1 > Done. Then run this again."
BUCKET_LOCATION="$(gcloud storage buckets describe "gs://${BUCKET}" --format='value(location)' | tr '[:upper:]' '[:lower:]')"
if [ "${BUCKET_LOCATION}" = "${REGION}" ]; then
  ok "Storage bucket gs://${BUCKET} in ${REGION}"
else
  die "the bucket gs://${BUCKET} is in '${BUCKET_LOCATION}', not ${REGION}; the photo trigger needs both in ${REGION} (SETUP.md 23.1). Ask the developer."
fi

# ============================================================== 2. tool sign-in
step "2. Credentials for the tools"
export GOOGLE_CLOUD_QUOTA_PROJECT="${PROJECT}"
if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  echo "  The Node tools need Application Default Credentials. Follow the link, sign in as ${ACCOUNT}, paste the code back here:"
  gcloud auth application-default login --no-launch-browser
fi
if [ -f "${HOME}/.config/gcloud/application_default_credentials.json" ]; then
  gcloud auth application-default set-quota-project "${PROJECT}" >/dev/null 2>&1 || true
fi
ok "Application Default Credentials"

# .firebaserc must name the project before any firebase command (no-op when
# the repository already has it).
python3 - "${PROJECT}" "${ADMIN_SITE}" "${LINKS_SITE}" <<'PY'
import json, sys
project, admin, links = sys.argv[1:4]
with open(".firebaserc") as f:
    d = json.load(f)
before = json.dumps(d, sort_keys=True)
d.setdefault("projects", {})["staging"] = project
d.setdefault("targets", {}).setdefault(project, {}).setdefault("hosting", {})
d["targets"][project]["hosting"]["admin"] = [admin]
d["targets"][project]["hosting"]["links"] = [links]
if json.dumps(d, sort_keys=True) != before:
    with open(".firebaserc", "w") as f:
        f.write(json.dumps(d, indent=2) + "\n")
PY
if grep -q '^INVITE_LINK_BASE=' "${ENV_FILE}"; then
  sed -i "s#^INVITE_LINK_BASE=.*#INVITE_LINK_BASE=https://${LINKS_SITE}.web.app#" "${ENV_FILE}"
else
  printf 'INVITE_LINK_BASE=https://%s.web.app\n' "${LINKS_SITE}" >>"${ENV_FILE}"
fi
ok ".firebaserc (staging -> ${PROJECT}, sites) and INVITE_LINK_BASE"

echo "  Fetching ${FIREBASE_TOOLS} (first time takes a minute)..."
if ! fb apps:list >/dev/null 2>&1; then
  echo "  The firebase tool cannot use your Cloud Shell sign-in. Sign it in once:"
  npx --yes "${FIREBASE_TOOLS}" login --no-localhost
  fb apps:list >/dev/null || die "the firebase tool still cannot reach ${PROJECT}."
fi
ok "firebase tool (${FIREBASE_TOOLS}) can reach ${PROJECT}"

# ============================================================== 3. Identity Platform
step "3. Authentication (Identity Platform)"
api GET "${IDTK}" || true
if [ "$(jget 'd.get("subtype","")')" != "IDENTITY_PLATFORM" ]; then
  api POST "https://identitytoolkit.googleapis.com/v2/projects/${PROJECT}/identityPlatform:initializeAuth" '{}' || true
  sleep 5
  api GET "${IDTK}" || true
fi
if [ "$(jget 'd.get("subtype","")')" != "IDENTITY_PLATFORM" ]; then
  die "Authentication is not on the Identity Platform tier. Open ${CONSOLE}/authentication > Get started (if shown) > Settings > Upgrade (Identity Platform, free tier). Then run this again."
fi
ok "Identity Platform tier"

if [ "$(jget 'd.get("signIn",{}).get("email",{}).get("enabled",False) and d["signIn"]["email"].get("passwordRequired",False)')" = "True" ]; then
  ok "Email/Password provider on (needed for the email link and the admins)"
elif api PATCH "${IDTK}?updateMask=signIn.email.enabled,signIn.email.passwordRequired" '{"signIn":{"email":{"enabled":true,"passwordRequired":true}}}'; then
  ok "Email/Password provider switched on"
else
  todo "Email/Password: ${CONSOLE}/authentication/providers > Add new provider > Email/Password > Enable (leave Email link off) > Save. ($(api_error))"
fi
api GET "${IDTK}" || true
if [ "$(jget 'd.get("client",{}).get("permissions",{}).get("disabledUserSignup",False) and d["client"]["permissions"].get("disabledUserDeletion",False)')" = "True" ]; then
  ok "client sign-up and delete are off (SETUP 11.3)"
elif api PATCH "${IDTK}?updateMask=client.permissions.disabledUserSignup,client.permissions.disabledUserDeletion" '{"client":{"permissions":{"disabledUserSignup":true,"disabledUserDeletion":true}}}'; then
  ok "client sign-up and delete switched off (SETUP 11.3)"
else
  todo "Sign-up/delete: ${CONSOLE}/authentication/settings > User actions > untick 'Enable create (sign-up)' and 'Enable delete' > Save."
fi
api GET "${IDTK}" || true
if [ "$(jget '"allowlistOnly" in d.get("smsRegionConfig",{}) and not d["smsRegionConfig"]["allowlistOnly"].get("allowedRegions")')" = "True" ]; then
  ok "SMS denied in every region"
elif api PATCH "${IDTK}?updateMask=smsRegionConfig" '{"smsRegionConfig":{"allowlistOnly":{}}}'; then
  ok "SMS denied in every region (no SMS bills)"
else
  todo "SMS: ${CONSOLE}/authentication/settings > SMS region policy > Deny all regions > Save."
fi

# ============================================================== 4. IAM
step "4. Roles for the functions' service account"
SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  gcloud iam service-accounts describe "${SA}" --project="${PROJECT}" >/dev/null 2>&1 && break
  echo "  waiting for ${SA} to appear..."; sleep 10
done
gcloud iam service-accounts describe "${SA}" --project="${PROJECT}" >/dev/null 2>&1 \
  || die "the default compute service account ${SA} does not exist yet; wait a few minutes and run again."
grant() { # member role
  gcloud projects add-iam-policy-binding "${PROJECT}" --member="$1" --role="$2" --condition=None --quiet >/dev/null
}
# SETUP 11.2: custom tokens (verifyCode) and signed links (admins, exports).
# Security review (16 Nov 2026): Token Creator ONLY on the account itself
# (it signs as itself). Granted on the whole project it could mint tokens
# for every service account there, including any with more rights.
gcloud iam service-accounts add-iam-policy-binding "${SA}" --project="${PROJECT}" \
  --member="serviceAccount:${SA}" --role=roles/iam.serviceAccountTokenCreator --condition=None --quiet >/dev/null
if gcloud projects get-iam-policy "${PROJECT}" --flatten='bindings[].members' \
     --filter="bindings.members:serviceAccount:${SA} AND bindings.role:roles/iam.serviceAccountTokenCreator" \
     --format='value(bindings.role)' 2>/dev/null | grep -q .; then
  # An earlier run of this script granted it project-wide: take that back.
  gcloud projects remove-iam-policy-binding "${PROJECT}" --member="serviceAccount:${SA}" \
    --role=roles/iam.serviceAccountTokenCreator --condition=None --quiet >/dev/null 2>&1 \
    || todo "IAM: ${GCP}/iam-admin/iam?project=${PROJECT} > ${SA} > remove 'Service Account Token Creator' at project level (it stays on the account itself)."
fi
grant "serviceAccount:${SA}" roles/secretmanager.secretAccessor
grant "serviceAccount:${SA}" roles/eventarc.eventReceiver
HAS_EDITOR="$(gcloud projects get-iam-policy "${PROJECT}" --flatten='bindings[].members' \
  --filter="bindings.members:serviceAccount:${SA} AND bindings.role:roles/editor" --format='value(bindings.role)' 2>/dev/null || true)"
if [ -z "${HAS_EDITOR}" ]; then
  # Newer projects do not give the default account Editor; it also builds the functions.
  grant "serviceAccount:${SA}" roles/cloudbuild.builds.builder
fi
# The photo trigger (Storage -> Eventarc) needs Storage's agent to publish to Pub/Sub.
GCS_AGENT="$(gcloud storage service-agent --project="${PROJECT}" 2>/dev/null | tail -1 | tr -d '[:space:]' || true)"
# A new project's Storage agent can take a few minutes to exist after the
# first lookup creates it: retry, and never stop the whole setup for it.
if [ -n "${GCS_AGENT}" ]; then
  GCS_OK=""
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if grant "serviceAccount:${GCS_AGENT}" roles/pubsub.publisher 2>/dev/null; then GCS_OK=1; break; fi
    echo "  waiting for the Storage service agent to appear..."; sleep 15
  done
  [ -n "${GCS_OK}" ] || todo "Storage agent not ready yet: run the same command again in 10 minutes (it grants ${GCS_AGENT} the Pub/Sub publisher role)."
fi
EXTRA_ROLE=""
[ -n "${HAS_EDITOR}" ] || EXTRA_ROLE=", Cloud Build builder"
ok "service account roles: Token Creator (on itself only), Secret accessor, Eventarc receiver${EXTRA_ROLE}; Storage agent: Pub/Sub publisher"

# ============================================================== 5. Maps keys
step "5. Google Maps keys"
# Key creation output contains the key itself: keep it off the screen, show errors only.
create_key() {
  gcloud services api-keys create --project="${PROJECT}" --quiet "$@" >/dev/null 2>"${WORK}/key.err" \
    || grep -iE 'error|denied|invalid' "${WORK}/key.err" | grep -v keyString | head -3 || true
}
find_key() { gcloud services api-keys list --project="${PROJECT}" --filter="displayName=\"$1\"" --format='value(name)' 2>/dev/null | head -1; }
IOS_KEY_NAME="Maps iOS (${BUNDLE_ID})"
SERVER_KEY_NAME="Maps server (Places, Routes) for Cloud Functions"
# Two iPhone keys. Firebase adopts any key restricted to the app's bundle id as
# the iOS app's own API key, and a Maps-only key would then refuse sign-in,
# the database and push (API_KEY_SERVICE_BLOCKED). Google also refuses to
# widen that key afterwards (APIKEYS_RESTRICTION_INCOMPATIBLE_WITH_USAGE). So
# the Maps key stays Maps-only and the app's Firebase options use a second
# key that allows only the Firebase APIs the app calls.
FB_IOS_KEY_NAME="Firebase iOS (${BUNDLE_ID})"
FB_IOS_TARGETS=(
  --api-target=service=identitytoolkit.googleapis.com
  --api-target=service=securetoken.googleapis.com
  --api-target=service=firestore.googleapis.com
  --api-target=service=firebasestorage.googleapis.com
  --api-target=service=firebaseinstallations.googleapis.com
  --api-target=service=fcmregistrations.googleapis.com
  --api-target=service=firebaseappcheck.googleapis.com
  --api-target=service=firebase.googleapis.com
)
if [ -z "$(find_key "${IOS_KEY_NAME}")" ]; then
  create_key --display-name="${IOS_KEY_NAME}" --allowed-bundle-ids="${BUNDLE_ID}" \
    --api-target=service=maps-ios-backend.googleapis.com
fi
IOS_KEY_RES="$(find_key "${IOS_KEY_NAME}")"
[ -n "${IOS_KEY_RES}" ] || die "could not create the iOS Maps key."
ok "iOS Maps key: only ${BUNDLE_ID}, only Maps SDK for iOS"
if [ -z "$(find_key "${FB_IOS_KEY_NAME}")" ]; then
  create_key --display-name="${FB_IOS_KEY_NAME}" --allowed-bundle-ids="${BUNDLE_ID}" "${FB_IOS_TARGETS[@]}"
fi
if [ -z "$(find_key "${FB_IOS_KEY_NAME}")" ]; then
  # Without the bundle lock: still limited to the Firebase APIs, and App
  # Check and the rules protect the backend.
  create_key --display-name="${FB_IOS_KEY_NAME}" "${FB_IOS_TARGETS[@]}"
fi
FB_IOS_KEY_RES="$(find_key "${FB_IOS_KEY_NAME}")"
FB_IOS_KEY=""
if [ -n "${FB_IOS_KEY_RES}" ]; then
  FB_IOS_KEY="$(gcloud services api-keys get-key-string "${FB_IOS_KEY_RES}" --format='value(keyString)')"
  ok "Firebase iOS key: only the Firebase APIs the app uses (goes into the app's Firebase options)"
else
  todo "Firebase iOS key: ${GCP}/apis/credentials?project=${PROJECT} > Create credentials > API key > name '${FB_IOS_KEY_NAME}' > API restrictions: Identity Toolkit, Token Service, Cloud Firestore, Cloud Storage for Firebase, Firebase Installations, FCM Registration, Firebase App Check, Firebase Management > Save, then run this again. Without it the iPhone app cannot sign in."
fi
MAPS_IOS_KEY="$(gcloud services api-keys get-key-string "${IOS_KEY_RES}" --format='value(keyString)')"
if [ -z "$(find_key "${SERVER_KEY_NAME}")" ]; then
  # No application restriction is possible for Cloud Functions (SETUP 15.2).
  create_key --display-name="${SERVER_KEY_NAME}" \
    --api-target=service=places.googleapis.com --api-target=service=routes.googleapis.com
fi
SERVER_KEY_RES="$(find_key "${SERVER_KEY_NAME}")"
[ -n "${SERVER_KEY_RES}" ] || die "could not create the server Maps key."
ok "server Maps key: only Places API (New) and Routes API"
todo "Maps daily caps (gcloud cannot set them reliably): ${GCP}/apis/api/places.googleapis.com/quotas?project=${PROJECT} > each 'per day' row > Edit > 300 > Submit; same on ${GCP}/apis/api/routes.googleapis.com/quotas?project=${PROJECT} with 150 (SETUP 15.4, 20.1)."

# ============================================================== 6. secrets
step "6. Secrets (Secret Manager; existing values are never replaced)"
secret_exists() { gcloud secrets describe "$1" --project="${PROJECT}" >/dev/null 2>&1; }
secret_has_value() {
  [ -n "$(gcloud secrets versions list "$1" --project="${PROJECT}" --filter='state:ENABLED' --limit=1 --format='value(name)' 2>/dev/null || true)" ]
}
secret_has_any_version() { # enabled, disabled or destroyed
  [ -n "$(gcloud secrets versions list "$1" --project="${PROJECT}" --limit=1 --format='value(name)' 2>/dev/null || true)" ]
}
secret_put() { # name; value on stdin (never echoed)
  if secret_exists "$1"; then
    gcloud secrets versions add "$1" --project="${PROJECT}" --data-file=- --quiet >/dev/null
  else
    gcloud secrets create "$1" --project="${PROJECT}" --replication-policy=automatic \
      --labels=firebase-managed=true --data-file=- --quiet >/dev/null
  fi
}
MISSING_REAL=()
ensure_secret() { # name random|unused provider-key fake-default
  local name="$1" kind="$2"
  if secret_has_value "${name}"; then ok "${name}: already set (kept)"; return; fi
  case "${kind}" in
    random)
      # Never give an HMAC key a second value: a new value would orphan every
      # stored hash (national ID duplicates, pending codes). Only a secret
      # with no version at all gets one.
      if secret_has_any_version "${name}"; then
        todo "${name}: has versions but none enabled; re-enable the right one in ${GCP}/security/secret-manager?project=${PROJECT} (not replaced)."
        return
      fi
      openssl rand -hex 32 | tr -d '\n' | secret_put "${name}"; ok "${name}: new random key" ;;
    unused)
      local provider; provider="$(env_value "$3" fake)"
      if [ "${provider}" = "fake" ]; then
        printf 'unused' | secret_put "${name}"; ok "${name}: placeholder 'unused' ($3=fake in staging)"
      else
        MISSING_REAL+=("${name} ($3=${provider} needs the real value)")
      fi ;;
  esac
}
ensure_secret OTP_HMAC_KEY random
ensure_secret NATIONAL_ID_HMAC_KEY random
# R2: encrypts the number and IP in the Anti-Cybercrime sign-in log; never rotate.
ensure_secret SIGNIN_LOG_KEY random
ensure_secret WHATSAPP_ACCESS_TOKEN unused WHATSAPP_PROVIDER

# --- Algolia (school search over the whole list; docs/algolia-setup.md) ---
# The keys go only into Secret Manager (typed hidden, never printed, never
# in the repository). The Application ID and index name are not secret and
# go into functions/.env.staging before the deploy in step 11.
ALGOLIA_INDEX_NAME="schools_staging"
ALGOLIA_ON=""
secret_value() { gcloud secrets versions access latest --secret="$1" --project="${PROJECT}" 2>/dev/null || true; }
is_real_key() { [ -n "$1" ] && [ "$1" != "unused" ]; }
algolia_check() { # write|search APP_ID; key on stdin. Prints the verdict; returns 0 ok, 1 refused, 2 unknown
  local rc=0
  python3 tool/algolia_keys.py "$1" "$2" || rc=$?
  return "${rc}"
}
ALG_W="$(secret_value ALGOLIA_WRITE_KEY)"
ALG_S="$(secret_value ALGOLIA_SEARCH_KEY)"
ALG_APP="$(env_value ALGOLIA_APP_ID "")"
ALG_HAVE_KEYS=""
if is_real_key "${ALG_W}" && is_real_key "${ALG_S}"; then ALG_HAVE_KEYS=1; fi
ALG_W=""; ALG_S=""
if [ -n "${ALG_HAVE_KEYS}" ] && [ -n "${ALG_APP}" ] && { [ -z "${REPLACE_ALGOLIA}" ] || ! [ -t 0 ]; }; then
  ALGOLIA_ON=1
  if [ -n "${REPLACE_ALGOLIA}" ]; then
    todo "Algolia: --replace-algolia needs an interactive Cloud Shell to type the keys; the stored keys were kept."
  else
    ok "Algolia keys already in Secret Manager (kept; --replace-algolia to change them)"
  fi
elif [ -t 0 ]; then
  echo
  echo "  ALGOLIA (school search over every school). Guide: docs/algolia-setup.md"
  echo "  Without it, search can only cover 200 schools, so the app will say search is unavailable."
  if [ -n "${ALG_HAVE_KEYS}" ] && [ -z "${REPLACE_ALGOLIA}" ]; then
    echo "  The keys are stored; only the Application ID is missing."
  fi
  read -r -p "  Algolia Application ID (Enter to skip): " NEW_APP || NEW_APP=""
  NEW_APP="$(printf '%s' "${NEW_APP}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
  if [ -z "${NEW_APP}" ]; then
    if [ -n "${ALG_HAVE_KEYS}" ] && [ -n "${ALG_APP}" ]; then
      ALGOLIA_ON=1; ok "Algolia: kept the stored keys"
    else
      todo "Algolia skipped: school search covers only 200 schools (the app says 'unavailable' with the real list). Set it up: docs/algolia-setup.md, then run this script again."
    fi
  elif ! [[ "${NEW_APP}" =~ ^[A-Z0-9]{6,32}$ ]]; then
    todo "Algolia: '${NEW_APP}' is not an Application ID (letters and digits). Run this script again."
  elif [ -n "${ALG_HAVE_KEYS}" ] && [ -z "${REPLACE_ALGOLIA}" ]; then
    set_env ALGOLIA_APP_ID "${NEW_APP}"; ALGOLIA_ON=1
    ok "Algolia Application ID ${NEW_APP} (stored keys kept)"
  else
    read -r -s -p "  Algolia Write API Key (hidden; paste, then Enter): " NEW_W || NEW_W=""; echo
    read -r -s -p "  Algolia Search-only API Key (hidden; paste, then Enter): " NEW_S || NEW_S=""; echo
    NEW_W="$(printf '%s' "${NEW_W}" | tr -d '[:space:]')"
    NEW_S="$(printf '%s' "${NEW_S}" | tr -d '[:space:]')"
    W_RC=0; S_RC=0; W_MSG=""; S_MSG=""; W_EMPTY=0; S_EMPTY=0; SAME_KEY=0
    [ -n "${NEW_W}" ] || W_EMPTY=1
    [ -n "${NEW_S}" ] || S_EMPTY=1
    [ "${W_EMPTY}${S_EMPTY}" != "00" ] || [ "${NEW_W}" != "${NEW_S}" ] || SAME_KEY=1
    # The verdicts never contain a key (tool/algolia_keys.py); empty keys are not sent.
    if [ "${W_EMPTY}" = 0 ]; then W_MSG="$(printf '%s' "${NEW_W}" | algolia_check write "${NEW_APP}")" || W_RC=$?; echo "  Write key: ${W_MSG}"; fi
    if [ "${S_EMPTY}" = 0 ]; then S_MSG="$(printf '%s' "${NEW_S}" | algolia_check search "${NEW_APP}")" || S_RC=$?; echo "  Search key: ${S_MSG}"; fi
    DECIDE_RC=0
    DECISION="$(python3 tool/algolia_keys.py decide "${W_EMPTY}" "${S_EMPTY}" "${SAME_KEY}" "${W_RC}" "${S_RC}" "${W_MSG}" "${S_MSG}")" || DECIDE_RC=$?
    if [ "${DECIDE_RC}" -ne 0 ]; then
      todo "Algolia keys not stored: $(printf '%s' "${DECISION}" | paste -sd ';' - | sed 's/;/; /g'). Run this script again; it asks again."
    else
      printf '%s' "${NEW_W}" | secret_put ALGOLIA_WRITE_KEY
      printf '%s' "${NEW_S}" | secret_put ALGOLIA_SEARCH_KEY
      set_env ALGOLIA_APP_ID "${NEW_APP}"; ALGOLIA_ON=1
      ok "Algolia keys stored in Secret Manager (new versions); Application ID ${NEW_APP}"
      while IFS= read -r line; do [ -z "${line}" ] || todo "Algolia: ${line}"; done <<<"${DECISION}"
    fi
    NEW_W=""; NEW_S=""
  fi
elif [ -n "${ALG_HAVE_KEYS}" ]; then
  todo "Algolia: the keys are stored but ALGOLIA_APP_ID is empty in ${ENV_FILE}; run this script in Cloud Shell (it asks for the ID) or commit the ID there."
else
  todo "Algolia: run this script in Cloud Shell (interactive) to type the keys; until then search covers only 200 schools."
fi
if [ -n "${ALGOLIA_ON}" ]; then
  set_env SCHOOL_SEARCH_PROVIDER algolia
  set_env ALGOLIA_INDEX "${ALGOLIA_INDEX_NAME}"
  ok "school search: Algolia, index ${ALGOLIA_INDEX_NAME} (${ENV_FILE})"
elif [ "$(env_value SCHOOL_SEARCH_PROVIDER fake)" = "algolia" ]; then
  # No usable keys: deploying 'algolia' would break search; use the
  # Firestore list (complete only for the sample) until Algolia is set up.
  set_env SCHOOL_SEARCH_PROVIDER fake
  todo "SCHOOL_SEARCH_PROVIDER set back to fake in ${ENV_FILE} for this deploy (no Algolia keys yet)."
fi
ensure_secret ALGOLIA_WRITE_KEY unused SCHOOL_SEARCH_PROVIDER
ensure_secret ALGOLIA_SEARCH_KEY unused SCHOOL_SEARCH_PROVIDER
ensure_secret STREAM_API_SECRET unused CHAT_PROVIDER
# MAPS_SERVER_KEY: the real server key (a placeholder 'unused' is replaced).
CURRENT_MAPS=""
secret_has_value MAPS_SERVER_KEY && CURRENT_MAPS="$(gcloud secrets versions access latest --secret=MAPS_SERVER_KEY --project="${PROJECT}" 2>/dev/null || true)"
if [ -z "${CURRENT_MAPS}" ] || [ "${CURRENT_MAPS}" = "unused" ]; then
  gcloud services api-keys get-key-string "${SERVER_KEY_RES}" --format='value(keyString)' | tr -d '\n' | secret_put MAPS_SERVER_KEY
  ok "MAPS_SERVER_KEY: the server Maps key"
else
  ok "MAPS_SERVER_KEY: already set (kept)"
fi
CURRENT_MAPS=""
if [ "${#MISSING_REAL[@]}" -gt 0 ]; then
  die "these secrets need real values before the deploy: ${MISSING_REAL[*]}. Set each with: gcloud secrets create <NAME> --data-file=- (paste, then Ctrl-D)."
fi

# ============================================================== 7. Hosting sites
step "7. Hosting sites"
ensure_site() {
  if api GET "https://firebasehosting.googleapis.com/v1beta1/projects/${PROJECT}/sites/$1"; then
    ok "Hosting site $1 exists"
  elif api POST "https://firebasehosting.googleapis.com/v1beta1/projects/${PROJECT}/sites?siteId=$1" '{}'; then
    ok "Hosting site $1 created (https://$1.web.app)"
  else
    die "could not create Hosting site $1 ($(api_error)). Site names are global; if it is taken, tell the developer."
  fi
}
ensure_site "${LINKS_SITE}"
ensure_site "${ADMIN_SITE}"

# ============================================================== 8. apps + options
step "8. Firebase apps and lib/firebase/firebase_options_staging.dart"
FBM="https://firebase.googleapis.com/v1beta1/projects/${PROJECT}"
find_ios_app() { api GET "${FBM}/iosApps?pageSize=100" && jget "next((a['appId'] for a in d.get('apps',[]) if a.get('bundleId')=='${BUNDLE_ID}'),'')"; }
find_web_app() { api GET "${FBM}/webApps?pageSize=100" && jget "next((a['appId'] for a in d.get('apps',[]) if a.get('displayName')=='${WEB_APP_NAME}'),'')"; }
IOS_APP_ID="$(find_ios_app || true)"
if [ -z "${IOS_APP_ID}" ]; then
  fb apps:create IOS "${IOS_APP_NAME}" --bundle-id "${BUNDLE_ID}" >/dev/null
  IOS_APP_ID="$(find_ios_app || true)"
fi
[ -n "${IOS_APP_ID}" ] || die "could not register the iOS app ${BUNDLE_ID} in Firebase."
ok "iOS app ${BUNDLE_ID} (${IOS_APP_ID})"
WEB_APP_ID="$(find_web_app || true)"
if [ -z "${WEB_APP_ID}" ]; then
  fb apps:create WEB "${WEB_APP_NAME}" >/dev/null
  WEB_APP_ID="$(find_web_app || true)"
fi
[ -n "${WEB_APP_ID}" ] || die "could not register the web app in Firebase."
ok "web app '${WEB_APP_NAME}' (${WEB_APP_ID})"
if [ -n "${APPLE_TEAM_ID}" ]; then
  if api PATCH "${FBM}/iosApps/${IOS_APP_ID}?updateMask=teamId" "{\"teamId\":\"${APPLE_TEAM_ID}\"}"; then
    ok "iOS app Team ID set"
  else
    todo "Team ID: ${CONSOLE}/settings/general > the iOS app > Team ID > ${APPLE_TEAM_ID}."
  fi
fi

api GET "${FBM}/iosApps/${IOS_APP_ID}/config" || die "could not read the iOS app config ($(api_error))."
cp "${API_OUT}" "${WORK}/ios_config.json"
api GET "${FBM}/webApps/${WEB_APP_ID}/config" || die "could not read the web app config ($(api_error))."
cp "${API_OUT}" "${WORK}/web_config.json"
OPTIONS_FILE="lib/firebase/firebase_options_staging.dart"
python3 - "${WORK}/ios_config.json" "${WORK}/web_config.json" "${OPTIONS_FILE}" "${BUNDLE_ID}" "${FB_IOS_KEY}" <<'PY'
import base64, json, plistlib, sys
ios_path, web_path, out, bundle, fb_ios_key = sys.argv[1:6]
ios = plistlib.loads(base64.b64decode(json.load(open(ios_path))["configFileContents"]))
# The key Firebase attached to the iOS app may be the Maps-only key: use ours.
if fb_ios_key:
    ios["API_KEY"] = fb_ios_key
web = json.load(open(web_path))

def q(v):
    v = str(v)
    if "'" in v or "\\" in v or "$" in v or "\n" in v:
        raise SystemExit(f"unexpected character in Firebase config value {v!r}")
    return f"'{v}'"

def block(name, fields):
    lines = [f"  static const FirebaseOptions {name} = FirebaseOptions("]
    lines += [f"    {k}: {q(v)}," for k, v in fields if v]
    lines.append("  );")
    return "\n".join(lines)

ios_fields = [
    ("apiKey", ios["API_KEY"]), ("appId", ios["GOOGLE_APP_ID"]),
    ("messagingSenderId", ios["GCM_SENDER_ID"]), ("projectId", ios["PROJECT_ID"]),
    ("storageBucket", ios.get("STORAGE_BUCKET", "")), ("iosBundleId", ios.get("BUNDLE_ID", bundle)),
]
web_fields = [
    ("apiKey", web["apiKey"]), ("appId", web["appId"]),
    ("messagingSenderId", web["messagingSenderId"]), ("projectId", web["projectId"]),
    ("authDomain", web.get("authDomain", "")), ("storageBucket", web.get("storageBucket", "")),
]
text = f"""// Firebase options for the STAGING flavor (project {ios['PROJECT_ID']}).
// Generated by tool/cloud_setup.sh from the Firebase apps of the project
// (iOS {bundle} and the web app used by the admin panel). Run the script
// again to regenerate. Not secret: App Check and the rules protect the
// backend (SETUP.md 3 step 9). Android comes in Stage 3.

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

// ignore_for_file: avoid_classes_with_only_static_members

class DefaultFirebaseOptions {{
  static FirebaseOptions get currentPlatform {{
    if (kIsWeb) return web;
    if (defaultTargetPlatform == TargetPlatform.iOS) return ios;
    throw UnsupportedError(
      'Firebase is not configured for the "staging" flavor on this platform yet '
      '(Android comes in Stage 3; SETUP.md 3 step 9).',
    );
  }}

{block("ios", ios_fields)}

{block("web", web_fields)}
}}
"""
with open(out, "w") as f:
    f.write(text)
PY
ok "${OPTIONS_FILE} written (printed at the end for the developer)"

# ============================================================== 9. App Check
step "9. App Check (registration only; enforcement stays off in the console)"
APPCHECK="https://firebaseappcheck.googleapis.com/v1/projects/${PROJECT_NUMBER}/apps"
if [ -n "${APPLE_TEAM_ID}" ]; then
  if api PATCH "${APPCHECK}/${IOS_APP_ID}/appAttestConfig?updateMask=tokenTtl" '{"tokenTtl":"3600s"}'; then
    ok "App Check: iOS app registered with App Attest"
  else
    todo "App Attest: ${CONSOLE}/appcheck/apps > ${IOS_APP_NAME} > App Attest > Team ID ${APPLE_TEAM_ID} > Save. ($(api_error))"
  fi
else
  todo "App Attest: ${CONSOLE}/appcheck/apps > ${IOS_APP_NAME} > App Attest > your Team ID > Save (or rerun this script with the Team ID)."
fi
todo "Optional DeviceCheck fallback: Apple > Keys > + > DeviceCheck, download the .p8, then ${CONSOLE}/appcheck/apps > ${IOS_APP_NAME} > DeviceCheck > upload it with its Key ID."

RECAPTCHA_NAME="Admin panel (${ADMIN_SITE})"
RECAPTCHA_KEY="$(gcloud recaptcha keys list --project="${PROJECT}" --filter="displayName=\"${RECAPTCHA_NAME}\"" --format='value(name)' 2>/dev/null | head -1 || true)"
if [ -z "${RECAPTCHA_KEY}" ]; then
  RECAPTCHA_KEY="$(gcloud recaptcha keys create --project="${PROJECT}" --display-name="${RECAPTCHA_NAME}" \
    --web --integration-type=score --domains="${ADMIN_SITE}.web.app,${ADMIN_SITE}.firebaseapp.com" \
    --format='value(name)' 2>/dev/null || true)"
fi
RECAPTCHA_KEY="${RECAPTCHA_KEY##*/}"
if [ -n "${RECAPTCHA_KEY}" ]; then
  ok "reCAPTCHA Enterprise key for the admin site (${RECAPTCHA_KEY}; public site key)"
  api GET "${APPCHECK}/${WEB_APP_ID}/recaptchaEnterpriseConfig" || true
  if [ "$(jget 'd.get("siteKey","")')" = "${RECAPTCHA_KEY}" ]; then
    ok "App Check: web app uses that reCAPTCHA Enterprise key"
  elif api PATCH "${APPCHECK}/${WEB_APP_ID}/recaptchaEnterpriseConfig?updateMask=siteKey" "{\"siteKey\":\"${RECAPTCHA_KEY}\"}"; then
    ok "App Check: web app registered with reCAPTCHA Enterprise"
  else
    todo "App Check web: ${CONSOLE}/appcheck/apps > ${WEB_APP_NAME} > reCAPTCHA Enterprise > site key ${RECAPTCHA_KEY} > Save. ($(api_error))"
  fi
else
  todo "reCAPTCHA: ${GCP}/security/recaptcha?project=${PROJECT} > Create key > Website, score-based, domains ${ADMIN_SITE}.web.app and ${ADMIN_SITE}.firebaseapp.com; then ${CONSOLE}/appcheck/apps > ${WEB_APP_NAME} > reCAPTCHA Enterprise > that key; then run this script again (the admin panel is built with it)."
fi

# ============================================================== 10. domains, storage
step "10. Authorized domains, Storage CORS, retention, encryption key"
api GET "${IDTK}" || true
DOMAINS_JSON="$(python3 - "${API_OUT}" "${ADMIN_SITE}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); site = sys.argv[2]
have = d.get("authorizedDomains", [])
want = have + [x for x in (f"{site}.web.app", f"{site}.firebaseapp.com") if x not in have]
print("" if want == have else json.dumps({"authorizedDomains": want}))
PY
)"
if [ -z "${DOMAINS_JSON}" ]; then
  ok "authorized domains include ${ADMIN_SITE}.web.app and .firebaseapp.com"
elif api PATCH "${IDTK}?updateMask=authorizedDomains" "${DOMAINS_JSON}"; then
  ok "authorized domains: added ${ADMIN_SITE}.web.app and .firebaseapp.com"
else
  todo "Authorized domains: ${CONSOLE}/authentication/settings > Authorized domains > Add ${ADMIN_SITE}.web.app and ${ADMIN_SITE}.firebaseapp.com."
fi

python3 - "${ADMIN_SITE}" "${WORK}/cors.json" <<'PY'
import json, sys
site, out = sys.argv[1:3]
rules = json.load(open("tool/storage_cors.json"))
for r in rules:
    r["origin"] = [f"https://{site}.web.app", f"https://{site}.firebaseapp.com"]
json.dump(rules, open(out, "w"), indent=2)
PY
gcloud storage buckets update "gs://${BUCKET}" --project="${PROJECT}" --cors-file="${WORK}/cors.json" --quiet >/dev/null
ok "Storage CORS: GET from the admin site only (SETUP 13.3.6)"

run_step bash tool/setup_retention.sh "${PROJECT}" "${BUCKET}"
if [ "${STEP_RC}" -eq 0 ]; then ok "lifecycle rules, 7-day soft delete and every Firestore TTL policy (SETUP 23.3)"
else todo "retention: run 'bash tool/setup_retention.sh ${PROJECT} ${BUCKET}' again and send the developer the error."; fi
run_step bash tool/setup_kms.sh "${PROJECT}" "${BUCKET}"
if [ "${STEP_RC}" -eq 0 ]; then ok "KMS key school-carpool/private-photos is the bucket's default key (SETUP 23.2)"
else todo "encryption key: run 'bash tool/setup_kms.sh ${PROJECT} ${BUCKET}' again and send the developer the error."; fi

# ============================================================== 11. deploy
step "11. Deploy Firestore rules and indexes, Storage rules and Cloud Functions"
if [ -f functions/package-lock.json ]; then
  npm --prefix functions ci --no-audit --no-fund
else
  npm --prefix functions install --no-audit --no-fund
fi
DEPLOY_LOG="$(mktemp)"
deploy_backend() {
  fb deploy --only firestore:rules,firestore:indexes,storage,functions --force 2>&1 | tee "${DEPLOY_LOG}"
  return "${PIPESTATUS[0]}"
}
# A function half-created by an earlier failed deploy can have the wrong
# kind (HTTPS vs event); Firebase then refuses to update it. Staging only:
# delete exactly those functions so the next deploy creates them afresh.
fix_wrong_kind() {
  local names
  names="$(grep -oE '\[[A-Za-z0-9_]+\([a-z0-9-]+\)\] Changing from an? [A-Za-z ]+ function to an? [A-Za-z ]+ function is not allowed' "${DEPLOY_LOG}" \
    | sed -E 's/^\[([A-Za-z0-9_]+)\(.*/\1/' | sort -u || true)"
  [ -n "${names}" ] || return 1
  local n
  for n in ${names}; do
    echo "  ${n} was left half-created by an earlier run: deleting it so it is created again."
    fb functions:delete "${n}" --region "${REGION}" --force || true
  done
  return 0
}
run_step deploy_backend
if [ "${STEP_RC}" -ne 0 ] && fix_wrong_kind; then
  run_step deploy_backend
fi
if [ "${STEP_RC}" -ne 0 ]; then
  echo "  First deploys often fail while Google sets up permissions (Eventarc). Trying again in 60 seconds..."
  sleep 60
  run_step deploy_backend
fi
[ "${STEP_RC}" -eq 0 ] || die "the deploy failed twice. Wait 5 minutes and run this again; if it still fails, send the developer the lines above 'STOPPED'."
ok "rules, indexes, storage rules and all functions deployed to ${REGION}"

# ============================================================== 12. schools
step "12. Schools: OpenStreetMap, Wikidata and Overture lists, import, load, search index"
# Every school, kindergarten and nursery in Egypt from OpenStreetMap,
# Wikidata and Overture Maps Places (owner decisions 15 and 16 Nov 2026),
# plus any owner CSV lists in data/schools; SETUP.md 14. What counts:
# data/schools/categories.json.
# Safe to rerun: a download newer than 7 days (Overture: 30 days) is reused,
# and so is each governorate's OpenStreetMap part; the loader writes
# only new or changed schools, the index sync sends the same records again.
# A failure here never stops the rest of the setup (to-do lines instead).
SEARCH="$(env_value SCHOOL_SEARCH_PROVIDER fake)"
SCHOOLS_OUT="${WORK}/schools"
mkdir -p "${SCHOOLS_OUT}"
if [ "${SKIP_SCHOOLS_FETCH:-}" = "1" ]; then
  ok "OpenStreetMap download skipped (SKIP_SCHOOLS_FETCH=1); the last download is used if there is one"
else
  run_step python3 tools/import_schools/fetch_osm_schools.py --max-age-days 7
  if [ "${STEP_RC}" -eq 0 ]; then
    ok "OpenStreetMap schools downloaded $(sed -n 's/^- Downloaded: //p' data/schools/osm/fetch_report.md 2>/dev/null | head -1); boundaries: $(sed -n 's/^- Governorate boundaries: //p' data/schools/osm/fetch_report.md 2>/dev/null | head -1)"
    ok "OpenStreetMap per governorate: $(sed -n 's/^Summary: //p' data/schools/osm/fetch_report.md 2>/dev/null | head -1)"
    if grep -q 'NO data' data/schools/osm/fetch_report.md 2>/dev/null; then
      todo "OpenStreetMap: some governorates have no data yet ($(grep 'NO data' data/schools/osm/fetch_report.md | sed 's/^- \([A-Z-]*\) .*/\1/' | paste -sd, -)); run this script again later (only those are asked again)."
    fi
  else
    todo "OpenStreetMap download failed (servers busy?). Run this script again later; the last download, if any, is used meanwhile."
  fi
  # City -> Area -> District (F4 grouping, F46 addresses): boundaries below
  # the governorate and named neighbourhoods, from the Overpass server that
  # just answered.
  OSM_SERVER="$(sed -n 's/^- Server: \(https:[^ ,]*\).*/\1/p' data/schools/osm/fetch_report.md 2>/dev/null | head -1)"
  run_step python3 tools/import_schools/fetch_osm_places.py --max-age-days 7 ${OSM_SERVER:+--prefer "${OSM_SERVER}"}
  if [ "${STEP_RC}" -eq 0 ]; then
    ok "OpenStreetMap places: $(sed -n 's/^- Boundaries per admin_level: //p' data/schools/places/fetch_report.md 2>/dev/null | head -1)"
    ok "OpenStreetMap places per governorate: $(sed -n 's/^Summary: //p' data/schools/places/fetch_report.md 2>/dev/null | head -1)"
  else
    todo "OpenStreetMap places download failed (servers busy?). Schools get no area until it works; run this script again later."
  fi
  # Areas: Egypt's ADM2 units (qism / markaz / new city) from the OCHA
  # COD-AB boundaries on HDX (geoBoundaries as a fallback): OpenStreetMap
  # has almost no boundaries below the governorate in Egypt.
  run_step python3 tools/import_schools/fetch_adm2.py --max-age-days 30
  if [ "${STEP_RC}" -eq 0 ]; then
    ok "ADM2 areas: $(sed -n 's/^- Units written: //p' data/schools/places/adm2_report.md 2>/dev/null | head -1); $(sed -n 's/^- Source: //p' data/schools/places/adm2_report.md 2>/dev/null | head -1)"
  else
    todo "ADM2 areas: download failed (see above). Download the Egypt COD-AB boundaries (HDX cod-ab-egy) by hand, then: python3 tools/import_schools/fetch_adm2.py --file <zip>"
  fi
  # Wikimedia's User-Agent policy asks for a contact: the admin email
  # argument unless WIKIDATA_CONTACT is set (sent only in the header).
  run_step env WIKIDATA_CONTACT="${WIKIDATA_CONTACT:-${ADMIN_EMAIL}}" \
    python3 tools/import_schools/fetch_wikidata_schools.py --max-age-days 7
  if [ "${STEP_RC}" -eq 0 ]; then
    ok "Wikidata schools: $(sed -n 's/^- Result rows: //p' data/schools/wikidata/fetch_report.md 2>/dev/null | head -1)"
  else
    todo "Wikidata download failed (see above). Run this script again later; the import goes on without it."
  fi
  # Overture Maps Places (CDLA Permissive 2.0 / Apache 2.0): read with
  # DuckDB straight from Overture's public S3 bucket, Egypt's box only.
  overture_fetch() {
    if ! python3 -c 'import duckdb' 2>/dev/null; then
      echo "  installing the duckdb Python package (pip install --user duckdb)..."
      python3 -m pip install --user --quiet duckdb || return 3
    fi
    python3 tools/import_schools/fetch_overture_schools.py --max-age-days 30
  }
  run_step overture_fetch
  if [ "${STEP_RC}" -eq 0 ]; then
    ok "$(sed -n 's/^- Rows from the query/Overture places: rows/p' data/schools/overture/fetch_report.md 2>/dev/null | head -1); $(sed -n 's/^- Written for the import \(([^)]*)\)[^:]*: /written \1: /p' data/schools/overture/fetch_report.md 2>/dev/null | head -1)"
  elif [ "${STEP_RC}" -eq 3 ]; then
    todo "Overture skipped: the duckdb Python package could not be installed. Run 'python3 -m pip install --user duckdb', then this script again."
  else
    todo "Overture download failed (see above). Run this script again later; the import goes on without it."
  fi
fi
shopt -s nullglob
REAL_INPUTS=()
for f in data/schools/osm/*.geojson data/schools/wikidata/*.geojson data/schools/overture/*.geojson data/schools/*.csv data/schools/*.geojson data/schools/*.json data/schools/*.zip; do
  [ "${f}" = "data/schools/categories.json" ] || REAL_INPUTS+=("${f}")
done
shopt -u nullglob
import_schools() {
  python3 tools/import_schools/import_schools.py >"${SCHOOLS_OUT}/import.txt"
  # The hand-written sample's keys, to take its fake schools out of search.
  python3 tools/import_schools/import_schools.py --input data/schools/sample --out build/schools-sample >/dev/null
}
import_sample() {
  python3 tools/import_schools/import_schools.py --input data/schools/sample >"${SCHOOLS_OUT}/import.txt"
}
load_schools() {
  (cd functions && SCHOOLS_PROJECT="${PROJECT}" npm run --silent schools:load:cloud -- --yes --file ../build/schools/schools.json "$@") \
    | tee "${SCHOOLS_OUT}/load.txt"
}
# Admin search (admin-schools-search branch): fill the server-only
# adminSearchGrams on the loaded schools. Idempotent; only when that npm
# script exists.
admin_grams() {
  (cd functions && SCHOOLS_PROJECT="${PROJECT}" npm run --silent schools:admin-grams -- --yes) | tee "${SCHOOLS_OUT}/admin-grams.txt"
}
admin_grams_fill() {
  if grep -q '"schools:admin-grams"' functions/package.json 2>/dev/null; then
    run_step admin_grams
    if [ "${STEP_RC}" -eq 0 ]; then
      ok "admin school search: $(tail -1 "${SCHOOLS_OUT}/admin-grams.txt")"
    else
      todo "admin school search terms not filled (see above); run this script again (it fills only what is missing or changed)."
    fi
  fi
}
SCHOOLS_LOADED=""
if [ "${#REAL_INPUTS[@]}" -gt 0 ]; then
  run_step import_schools
  # Automatic AI review of every kept name (owner decision 16 Nov 2026):
  # Vertex AI in this project, applied at confidence >= 0.8, then the import
  # runs again with its decisions (manual decisions win). Off with SCHOOLS_AI=off.
  if [ "${STEP_RC}" -eq 0 ] && [ "${SCHOOLS_AI:-on}" != "off" ]; then
    ai_review() {
      python3 tools/import_schools/ai_review.py --project "${PROJECT}" | tee "${SCHOOLS_OUT}/ai_review.txt"
    }
    run_step ai_review
    AI_RC="${STEP_RC}"
    import_with_ai() {
      python3 tools/import_schools/import_schools.py --ai-decisions build/schools/ai_decisions.csv >"${SCHOOLS_OUT}/import.txt"
    }
    if [ "${AI_RC}" -eq 0 ] && [ -f build/schools/ai_decisions.csv ]; then
      ok "$(sed -n 's/^AI review: \(ok .*\)/AI name review: \1/p' "${SCHOOLS_OUT}/ai_review.txt" | tail -1) (all verdicts: build/schools/ai_review.csv)"
      if grep -q 'call limit' "${SCHOOLS_OUT}/ai_review.txt"; then
        todo "AI name review stopped at its call limit (SCHOOLS_AI_MAX_CALLS); run this script again to review the rest."
      fi
      if grep -q '^AI review: incomplete' "${SCHOOLS_OUT}/ai_review.txt"; then
        todo "AI name review stopped part-way (Vertex AI not reachable, model not enabled, or no access; see above). Earlier verdicts are applied; run this script again for the rest."
      fi
      if grep -q 'suspicious batches' "${SCHOOLS_OUT}/ai_review.txt"; then
        todo "AI name review: some batches dropped too many schools and were NOT applied (look for 'suspicious' in build/schools/ai_review.csv); run this script again, or decide those names in data/schools/review/decisions.csv."
      fi
      run_step import_with_ai
    elif [ -f build/schools/ai_decisions.csv ]; then
      todo "AI name review did not run (no token or the schoolReview cache could not be read; see above). The previous run's AI decisions are applied again; run this script again later."
      run_step import_with_ai
    else
      todo "AI name review did not run (Vertex AI not reachable, model not available, or no access; see above). The list loads without it; run this script again later."
      STEP_RC=0
    fi
  fi
  if [ "${STEP_RC}" -eq 0 ]; then
    ok "import: $(sed -n 's/^Kept /kept /p' "${SCHOOLS_OUT}/import.txt" | head -1) (full report: build/schools/report.md)"
    ok "per source: $(sed -n 's/^Per source (read \/ dropped \/ kept as main entry \/ schools with an entry from it): //p' "${SCHOOLS_OUT}/import.txt" | head -1) (read / dropped / kept as main / schools with an entry)"
    ok "$(sed -n 's/^Auto-merged duplicates: /auto-merged duplicates: /p' "${SCHOOLS_OUT}/import.txt" | head -1) (one row each: build/schools/merged.csv)"
    ok "$(sed -n 's/^Left apart on purpose/left apart on purpose/p' "${SCHOOLS_OUT}/import.txt" | head -1)"
    ok "dropped names per reason: build/schools/dropped_<reason>.csv"
    run_step load_schools --hide-sample ../build/schools-sample/schools.json
    if [ "${STEP_RC}" -eq 0 ]; then
      SCHOOLS_LOADED=1
      ok "Firestore 'schools': $(sed -n 's/^load_schools: done\. //p' "${SCHOOLS_OUT}/load.txt" | tail -1) (sample schools kept as documents, out of search)"
      if grep -q '^load_places: done' "${SCHOOLS_OUT}/load.txt"; then
        ok "Firestore places: $(sed -n 's/^load_places: done\. //p' "${SCHOOLS_OUT}/load.txt" | tail -1)"
      fi
      admin_grams_fill
    else
      todo "schools load stopped (see above). Run this script again: what was written is kept and not written twice."
    fi
  else
    todo "schools import failed (see above); send the developer the error. Nothing was loaded."
  fi
else
  run_step import_sample
  [ "${STEP_RC}" -ne 0 ] || run_step load_schools
  if [ "${STEP_RC}" -eq 0 ]; then
    SCHOOLS_LOADED=1
    ok "no real list yet: the hand-written SAMPLE schools are loaded (rerun adds no duplicates)"
    admin_grams_fill
  else
    todo "sample schools: run this script again; if it fails, send the developer the error."
  fi
fi
algolia_sync() {
  local key app index
  key="$(gcloud secrets versions access latest --secret=ALGOLIA_WRITE_KEY --project="${PROJECT}")"
  app="$(env_value ALGOLIA_APP_ID "")"
  index="$(env_value ALGOLIA_INDEX "")"
  (cd functions && ALGOLIA_APP_ID="${app}" ALGOLIA_INDEX="${index}" ALGOLIA_WRITE_KEY="${key}" \
    SCHOOLS_PROJECT="${PROJECT}" npm run --silent schools:algolia -- sync) | tee "${SCHOOLS_OUT}/algolia.txt"
}
if [ "${SEARCH}" = "algolia" ]; then
  if [ -n "${SCHOOLS_LOADED}" ]; then
    run_step algolia_sync
    if [ "${STEP_RC}" -eq 0 ]; then
      ok "Algolia: $(sed -n 's/^algolia_schools: \(indexed .*\)/\1/p' "${SCHOOLS_OUT}/algolia.txt" | tail -1)"
      if grep -q '^algolia_schools: warning: ' "${SCHOOLS_OUT}/algolia.txt"; then
        todo "Algolia: $(sed -n 's/^algolia_schools: warning: //p' "${SCHOOLS_OUT}/algolia.txt" | tail -1)"
      fi
    else
      todo "Algolia index sync failed (see above; 403 means the Write API key was refused: run again with --replace-algolia). Otherwise run this script again."
    fi
  else
    todo "Algolia index not synced (the schools load did not finish); run this script again."
  fi
else
  todo "school search: Algolia is off, so search covers only 200 schools; with the real list the app says 'search unavailable'. Set it up: docs/algolia-setup.md, then run this script again."
fi
if [ -s "${SCHOOLS_OUT}/import.txt" ]; then
  printf '\n  Schools import summary (per source, kept, dropped and why, per city, places and top areas):\n'
  sed 's/^/    /' "${SCHOOLS_OUT}/import.txt"
fi
# Owner's list of schools to look for (one name per line): why each one
# is or is not in the list (tools/import_schools/why_missing.py).
if [ -f data/schools/check_names.txt ] && [ "${#REAL_INPUTS[@]}" -gt 0 ]; then
  why_missing() {
    python3 tools/import_schools/why_missing.py --file data/schools/check_names.txt --summary-only >"${SCHOOLS_OUT}/check_names.txt"
  }
  run_step why_missing
  if [ "${STEP_RC}" -eq 0 ]; then
    ok "$(tail -1 "${SCHOOLS_OUT}/check_names.txt")"
    printf '\n  Names not in the list, and why (all names: python3 tools/import_schools/why_missing.py --file data/schools/check_names.txt):\n'
    sed '$d; s/^/    /' "${SCHOOLS_OUT}/check_names.txt"
  else
    todo "names check failed (see above); send the developer the error."
  fi
fi

# ============================================================== 13. links site
step "13. Invite-links site (https://${LINKS_SITE}.web.app)"
deploy_links() {
  # Legal and support pages (App Store Connect needs public URLs): built
  # when SUPPORT_EMAIL and OPERATOR_NAME are given (docs/apple-review/submission-kit.md).
  local legal=()
  if [ -n "${SUPPORT_EMAIL:-}" ] && [ -n "${OPERATOR_NAME:-}" ]; then
    legal=(--support-email "${SUPPORT_EMAIL}" --operator-name "${OPERATOR_NAME}" --require-legal)
    # Data protection officer on the privacy policy (Law 151/2020; docs/legal/owner-actions.md).
    if [ -n "${DPO_EMAIL:-}" ]; then legal+=(--dpo-email "${DPO_EMAIL}"); fi
    if [ -n "${DPO_NAME:-}" ]; then legal+=(--dpo-name "${DPO_NAME}"); fi
  fi
  python3 tool/links_site.py --team-id "${APPLE_TEAM_ID}" --bundle-id "${BUNDLE_ID}" "${legal[@]}"
  fb deploy --only hosting:links
}
if [ -n "${APPLE_TEAM_ID}" ]; then
  run_step deploy_links
  if [ "${STEP_RC}" -eq 0 ]; then ok "links site deployed (check https://${LINKS_SITE}.web.app/.well-known/apple-app-site-association)"
    if [ -z "${SUPPORT_EMAIL:-}" ] || [ -z "${OPERATOR_NAME:-}" ]; then
      todo "privacy, terms and support pages: run this script again with SUPPORT_EMAIL=<address you read> OPERATOR_NAME=\"<your legal name>\" in front (App Store needs https://${LINKS_SITE}.web.app/privacy)."
    fi
  else todo "links site: run this script again; if it fails, send the developer the error."; fi
else
  todo "links site: run this script again with your Apple Team ID (APPLE_TEAM_ID=XXXXXXXXXX bash tool/cloud_setup.sh ...)."
fi

# ============================================================== 14. admin panel
step "14. Admin panel: two-step sign-in, build, deploy (https://${ADMIN_SITE}.web.app)"
admins() { (cd functions && ADMIN_PROJECT="${PROJECT}" npm run --silent admins:cloud -- "$@"); }
run_step admins check-totp
if [ "${STEP_RC}" -ne 0 ]; then
  run_step admins enable-totp
  run_step admins check-totp
fi
if [ "${STEP_RC}" -eq 0 ]; then ok "TOTP two-step sign-in on (SMS second factor off)"
else todo "TOTP: ${CONSOLE}/authentication/settings > Multi-factor authentication > enable, tick TOTP only (not SMS) > Save."; fi

FLUTTER_VERSION="$(sed -n 's/^ *FLUTTER_VERSION: *"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}.*/\1/p' .github/workflows/checks.yml | head -1)"
build_admin() {
  local flutter_bin="" path_ver=""
  # Cloud Shell ships its own Flutter (another version, and git refuses its
  # folder): use it only if it is exactly the version CI uses.
  if command -v flutter >/dev/null 2>&1; then
    path_ver="$(flutter --version 2>/dev/null | awk 'NR==1 {print $2}' || true)"
    [ "${path_ver}" = "${FLUTTER_VERSION}" ] && flutter_bin="$(command -v flutter)"
  fi
  if [ -z "${flutter_bin}" ]; then
    local home="${FLUTTER_HOME:-${HOME}/flutter}"
    if [ ! -x "${home}/bin/flutter" ] && [ -z "${FLUTTER_HOME:-}" ]; then
      # Flutter and its packages need about 3.5 GB; Cloud Shell's home has 5 GB.
      local free_kb; free_kb="$(df -Pk "${HOME}" | awk 'NR==2 {print $4}')"
      if [ "${free_kb}" -lt 3670016 ]; then
        echo "  Not enough room in your home folder; Flutter goes to /tmp (downloaded again next session)."
        home="/tmp/flutter"; export PUB_CACHE="/tmp/pub-cache"
      fi
    fi
    if [ ! -x "${home}/bin/flutter" ]; then
      echo "  Downloading Flutter ${FLUTTER_VERSION} (same as CI; a few minutes)..."
      git clone --depth 1 --branch "${FLUTTER_VERSION}" https://github.com/flutter/flutter.git "${home}"
    fi
    git config --global --add safe.directory "${home}" 2>/dev/null || true
    flutter_bin="${home}/bin/flutter"
    export PATH="${home}/bin:${PATH}"
  fi
  "${flutter_bin}" config --no-analytics >/dev/null 2>&1 || true
  local have; have="$("${flutter_bin}" --version 2>/dev/null | awk 'NR==1 {print $2}' || true)"
  [ "${have}" = "${FLUTTER_VERSION}" ] || echo "  Note: Flutter ${have} here, CI uses ${FLUTTER_VERSION}."
  FLAVOR=staging FLUTTER="${flutter_bin}" bash tool/bootstrap.sh
  "${flutter_bin}" build web --release -t lib/admin/main_admin_staging.dart \
    --dart-define=USE_EMULATORS=false --dart-define=RECAPTCHA_SITE_KEY="${RECAPTCHA_KEY}"
  rm -rf build/admin_web && mv build/web build/admin_web
  fb deploy --only hosting:admin
}
if [ "${SKIP_ADMIN_WEB:-}" = "1" ]; then
  todo "admin panel not built (SKIP_ADMIN_WEB=1). Run the script again without it."
else
  run_step build_admin
  if [ "${STEP_RC}" -eq 0 ]; then ok "admin panel built and deployed: https://${ADMIN_SITE}.web.app"
  else todo "admin panel build or deploy failed (see the messages above). Run the script again; send the developer the error if it repeats."; fi
fi

# ============================================================== 15. super admin
step "15. First super admin (${ADMIN_EMAIL})"
ADMIN_LINK=""
api POST "https://identitytoolkit.googleapis.com/v1/projects/${PROJECT}/accounts:lookup" "{\"email\":[\"${ADMIN_EMAIL}\"]}" || true
ADMIN_STATE="$(jget '"none" if not d.get("users") else ("password" if d["users"][0].get("passwordUpdatedAt") else "nopassword")')"
admin_cmd=""
case "${ADMIN_STATE}" in
  password) ok "super admin ${ADMIN_EMAIL} exists and has a password" ;;
  nopassword) admin_cmd="password-link" ;;
  *) admin_cmd="create-super-admin" ;;
esac
if [ -n "${admin_cmd}" ]; then
  rc=0
  if [ "${admin_cmd}" = "create-super-admin" ]; then
    ADMIN_OUT="$(admins create-super-admin "${ADMIN_EMAIL}" "${ADMIN_NAME}" 2>&1)" || rc=$?
  else
    ADMIN_OUT="$(admins password-link "${ADMIN_EMAIL}" 2>&1)" || rc=$?
  fi
  ADMIN_LINK="$(printf '%s\n' "${ADMIN_OUT}" | grep -E '^https://' | tail -1 || true)"
  if [ "${rc}" -eq 0 ] && [ -n "${ADMIN_LINK}" ]; then
    ok "super admin ${ADMIN_EMAIL} ready; set-password link below (valid 1 hour)"
  else
    printf '%s\n' "${ADMIN_OUT}" | grep -v '^https://' | tail -5
    todo "super admin: run the script again (it retries ${admin_cmd})."
  fi
fi

# ============================================================== 16. budget
step "16. Budget alert (USD 20; 5, 25 and 100 percent)"
BUDGET_NAME="${PROJECT} monthly"
BA_ID="${BILLING_ACCOUNT#billingAccounts/}"
if gcloud billing budgets list --billing-account="${BA_ID}" --billing-project="${PROJECT}" \
     --format='value(displayName)' 2>/dev/null | grep -Fxq "${BUDGET_NAME}"; then
  ok "budget '${BUDGET_NAME}' exists"
elif gcloud billing budgets create --billing-account="${BA_ID}" --billing-project="${PROJECT}" \
     --display-name="${BUDGET_NAME}" --budget-amount=20USD \
     --threshold-rule=percent=0.05 --threshold-rule=percent=0.25 --threshold-rule=percent=1.0 \
     --filter-projects="projects/${PROJECT}" --quiet >/dev/null 2>&1; then
  ok "budget '${BUDGET_NAME}': USD 20, emails at USD 1, 5 and 20 to the billing admins"
else
  todo "budget: ${GCP}/billing/${BA_ID}/budgets > Create budget > Projects: ${PROJECT} > Amount 20 (USD, or your account's currency) > thresholds 5%, 25%, 100% > Finish."
fi

# ============================================================== 17. checklist
step "17. Result"
printf '\nDONE\n'
for d in "${DONE[@]}"; do printf '  [x] %s\n' "${d}"; done

TODO+=("APNs key (push to the iPhone): ${CONSOLE}/settings/cloudmessaging > Apple app configuration > ${IOS_APP_NAME} > APNs Authentication Key > Upload: the .p8 from Apple, its Key ID and your Team ID (SETUP 3.7, 18.1).")
TODO+=("Check blocking functions: ${CONSOLE}/authentication/settings > Blocking functions: 'Before account creation' = blockClientSignUps, 'Before sign in' = blockNonCodeSignIn, 'Before email sent' = blockSignInEmails. If empty, pick them there and Save.")
TODO+=("App Check: do NOT press Enforce yet. After the first TestFlight build works, ${CONSOLE}/appcheck/products shows 'verified requests'; then enforce Firestore, Storage and Cloud Functions (SETUP 3.8).")
TODO+=("Codemagic > staging_defines: add MAPS_API_KEY_IOS (Secret ticked) with the key printed below; INVITE_LINK_DOMAIN=${LINKS_SITE}.web.app only after Associated Domains is ticked on the App ID.")
printf '\nSTILL TO DO (console)\n'
for t in "${TODO[@]}"; do printf '  [ ] %s\n' "${t}"; done

printf '\nWHERE THE SIGN-IN CODES ARE (staging uses the fake WhatsApp sender)\n'
printf '  %s/logs/query;query=%%22fake%%20WhatsApp%%22?project=%s\n' "${GCP}" "${PROJECT}"
printf '  (Logs Explorer, filter "fake WhatsApp"; set the time range to the last hour.)\n'

printf '\nADMIN PANEL\n  https://%s.web.app  (sign in as %s, then add the authenticator app)\n' "${ADMIN_SITE}" "${ADMIN_EMAIL}"
if [ -n "${ADMIN_LINK}" ]; then
  printf '\n---- ONE-TIME SET-PASSWORD LINK for %s: open it NOW yourself (valid 1 hour). Do not paste it in chat or share it. ----\n' "${ADMIN_EMAIL}"
  printf '%s\n' "${ADMIN_LINK}"
  printf -- '---- end of link ----\n'
fi

printf '\n---- paste into Codemagic MAPS_API_KEY_IOS (Secret). Do NOT paste it in chat. ----\n'
printf '%s\n' "${MAPS_IOS_KEY}"
printf -- '---- end of key ----\n'

printf '\nFOR THE DEVELOPER (safe to copy into chat: not secret)\n'
printf '===== BEGIN %s =====\n' "${OPTIONS_FILE}"
cat "${OPTIONS_FILE}"
printf '===== END %s =====\n' "${OPTIONS_FILE}"
if [ -n "${ALGOLIA_ON}" ]; then
  printf '\nNON-SECRET SEARCH SETTINGS (commit these lines in %s; the keys stay in Secret Manager)\n' "${ENV_FILE}"
  grep -E '^(SCHOOL_SEARCH_PROVIDER|ALGOLIA_APP_ID|ALGOLIA_INDEX)=' "${ENV_FILE}" | sed 's/^/  /'
fi
CHANGED="$(git status --porcelain -- .firebaserc "${ENV_FILE}" tool/storage_cors.json 2>/dev/null || true)"
if [ -n "${CHANGED}" ]; then
  printf '\nThese repository files also changed here (commit them too):\n'
  git --no-pager diff -- .firebaserc "${ENV_FILE}" tool/storage_cors.json
fi
printf '\nFinished. Safe to run again at any time: done steps are skipped.\n'
