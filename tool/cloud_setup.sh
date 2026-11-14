#!/usr/bin/env bash
# One-time (and safe to rerun) setup of the STAGING Firebase / Google Cloud
# project, run by the owner in Google Cloud Shell (browser terminal, nothing
# to install). Plain-English guide: docs/owner-cloud-shell.md.
#
#   git clone https://github.com/ahmedhisham1291/school-carpool.git && cd school-carpool
#   bash tool/cloud_setup.sh staging school-carpool-staging <admin-email>
#
# Optional environment:
#   APPLE_TEAM_ID   10-character Apple Team ID (asked for if not set; Enter
#                   skips the invite-links site and App Attest)
#   ADMIN_NAME      name of the first super admin (default "Owner")
#   SKIP_ADMIN_WEB=1  do not download Flutter / build the admin panel
#   FLUTTER_HOME    where to keep the Flutter SDK (default ~/flutter)
#
# What it does, in order (each step checks first and skips what is done):
#   1  checks: Blaze billing, Firestore and Storage in europe-west1; APIs on
#   2  sign-in for the tools (gcloud, Application Default Credentials, firebase)
#   3  Identity Platform: on, Email/Password on, sign-up and delete off, SMS denied
#   4  service-account roles (SETUP 11.2, Eventarc, Storage trigger)
#   5  Maps keys (iOS key, server key)          6  secrets in Secret Manager
#   7  Hosting sites (links, admin)             8  Firebase apps + Dart options file
#   9  App Check (App Attest, reCAPTCHA Enterprise for the admin site)
#   10 authorized domains, Storage CORS, retention (TTL, lifecycle), KMS key
#   11 deploy rules, indexes, storage rules and functions
#   12 sample schools (fake data) into Firestore   13 links site
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
  echo "usage: bash tool/cloud_setup.sh staging <project-id> <admin-email>" >&2
  exit 2
}
[ "$#" -eq 3 ] || usage
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
grant "serviceAccount:${SA}" roles/iam.serviceAccountTokenCreator
grant "serviceAccount:${SA}" roles/secretmanager.secretAccessor
grant "serviceAccount:${SA}" roles/eventarc.eventReceiver
HAS_EDITOR="$(gcloud projects get-iam-policy "${PROJECT}" --flatten='bindings[].members' \
  --filter="bindings.members:serviceAccount:${SA} AND bindings.role:roles/editor" --format='value(bindings.role)' 2>/dev/null || true)"
if [ -z "${HAS_EDITOR}" ]; then
  # Newer projects do not give the default account Editor; it also builds the functions.
  grant "serviceAccount:${SA}" roles/cloudbuild.builds.builder
fi
# The photo trigger (Storage -> Eventarc) needs Storage's agent to publish to Pub/Sub.
GCS_AGENT="$(gcloud storage service-agent --project="${PROJECT}" 2>/dev/null | tail -1 || true)"
[ -n "${GCS_AGENT}" ] && grant "serviceAccount:${GCS_AGENT}" roles/pubsub.publisher
EXTRA_ROLE=""
[ -n "${HAS_EDITOR}" ] || EXTRA_ROLE=", Cloud Build builder"
ok "service account roles: Token Creator, Secret accessor, Eventarc receiver${EXTRA_ROLE}; Storage agent: Pub/Sub publisher"

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
if [ -z "$(find_key "${IOS_KEY_NAME}")" ]; then
  create_key --display-name="${IOS_KEY_NAME}" \
    --allowed-bundle-ids="${BUNDLE_ID}" --api-target=service=maps-ios-backend.googleapis.com
fi
IOS_KEY_RES="$(find_key "${IOS_KEY_NAME}")"
[ -n "${IOS_KEY_RES}" ] || die "could not create the iOS Maps key."
MAPS_IOS_KEY="$(gcloud services api-keys get-key-string "${IOS_KEY_RES}" --format='value(keyString)')"
ok "iOS Maps key: only ${BUNDLE_ID}, only Maps SDK for iOS"
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
  [ -n "$(gcloud secrets versions list "$1" --project="${PROJECT}" --filter='state=ENABLED' --limit=1 --format='value(name)' 2>/dev/null || true)" ]
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
    random) openssl rand -hex 32 | tr -d '\n' | secret_put "${name}"; ok "${name}: new random key" ;;
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
ensure_secret WHATSAPP_ACCESS_TOKEN unused WHATSAPP_PROVIDER
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
python3 - "${WORK}/ios_config.json" "${WORK}/web_config.json" "${OPTIONS_FILE}" "${BUNDLE_ID}" <<'PY'
import base64, json, plistlib, sys
ios_path, web_path, out, bundle = sys.argv[1:5]
ios = plistlib.loads(base64.b64decode(json.load(open(ios_path))["configFileContents"]))
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
deploy_backend() { fb deploy --only firestore:rules,firestore:indexes,storage,functions --force; }
run_step deploy_backend
if [ "${STEP_RC}" -ne 0 ]; then
  echo "  First deploys often fail while Google sets up permissions (Eventarc). Trying again in 60 seconds..."
  sleep 60
  run_step deploy_backend
fi
[ "${STEP_RC}" -eq 0 ] || die "the deploy failed twice. Wait 5 minutes and run this again; if it still fails, send the developer the lines above 'STOPPED'."
ok "rules, indexes, storage rules and all functions deployed to ${REGION}"

# ============================================================== 12. schools
step "12. Sample schools (fake data, staging only)"
SEARCH="$(env_value SCHOOL_SEARCH_PROVIDER fake)"
load_schools() {
  python3 tools/import_schools/import_schools.py --input data/schools/sample
  (cd functions && SCHOOLS_PROJECT="${PROJECT}" npm run --silent schools:load:cloud -- --yes --file ../build/schools/schools.json)
}
run_step load_schools
if [ "${STEP_RC}" -eq 0 ]; then
  ok "sample schools loaded into Firestore 'schools' (hand-written test list; rerun adds no duplicates)"
else
  todo "schools: run 'SCHOOLS_PROJECT=${PROJECT} npm --prefix functions run schools:load:cloud -- --yes' after 'python3 tools/import_schools/import_schools.py --input data/schools/sample'."
fi
if [ "${SEARCH}" = "fake" ]; then
  ok "school search: fake provider over Firestore (SCHOOL_SEARCH_PROVIDER=fake; no Algolia needed)"
else
  todo "school search is '${SEARCH}' in ${ENV_FILE}: Algolia must be set up (SETUP 14.4) or set SCHOOL_SEARCH_PROVIDER=fake."
fi

# ============================================================== 13. links site
step "13. Invite-links site (https://${LINKS_SITE}.web.app)"
deploy_links() {
  python3 tool/links_site.py --team-id "${APPLE_TEAM_ID}" --bundle-id "${BUNDLE_ID}"
  fb deploy --only hosting:links
}
if [ -n "${APPLE_TEAM_ID}" ]; then
  run_step deploy_links
  if [ "${STEP_RC}" -eq 0 ]; then ok "links site deployed (check https://${LINKS_SITE}.web.app/.well-known/apple-app-site-association)"
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
  local flutter_bin
  if command -v flutter >/dev/null 2>&1; then
    flutter_bin="$(command -v flutter)"
  else
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
    flutter_bin="${home}/bin/flutter"
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
CHANGED="$(git status --porcelain -- .firebaserc "${ENV_FILE}" tool/storage_cors.json 2>/dev/null || true)"
if [ -n "${CHANGED}" ]; then
  printf '\nThese repository files also changed here (commit them too):\n'
  git --no-pager diff -- .firebaserc "${ENV_FILE}" tool/storage_cors.json
fi
printf '\nFinished. Safe to run again at any time: done steps are skipped.\n'
