#!/bin/bash
# after_branding hook: configure Firebase for the client being built or run.
#
# udara.yaml:
#   hooks:
#     after_branding:
#       - ./scripts/firebase_configure.sh
#
# Runs only when clients/<client>/service_account.json exists. udara_cli has
# already applied the client's bundle id, so FlutterFire registers the right
# Android/iOS apps. Set UDARA_FIREBASE_FORCE=1 to reconfigure even when the
# existing config already matches.
set -euo pipefail

SERVICE_ACCOUNT="$UDARA_CLIENT_DIR/service_account.json"

if [ ! -f "$SERVICE_ACCOUNT" ]; then
  echo "firebase hook: no service_account.json for '$UDARA_CLIENT', skipping."
  exit 0
fi

PROJECT_ID=$(jq -r '.project_id' "$SERVICE_ACCOUNT")

# Skip when the generated config already belongs to this Firebase project and
# bundle id. Keeps "Run Client" fast when switching back to the same client.
if [ "${UDARA_FIREBASE_FORCE:-0}" != "1" ] \
  && grep -q "projectId: '$PROJECT_ID'" lib/firebase_options.dart 2>/dev/null \
  && grep -q "\"package_name\": \"$UDARA_BUNDLE_ID\"" android/app/google-services.json 2>/dev/null; then
  echo "firebase hook: already configured for $PROJECT_ID ($UDARA_BUNDLE_ID), skipping."
  exit 0
fi

echo "firebase hook: configuring $PROJECT_ID for '$UDARA_CLIENT' ($UDARA_BUNDLE_ID)..."

# Avoid clashing with a personal Firebase CLI session.
firebase logout >/dev/null 2>&1 || true
unset FIREBASE_TOKEN
export GOOGLE_APPLICATION_CREDENTIALS="$SERVICE_ACCOUNT"

if command -v gcloud >/dev/null 2>&1; then
  gcloud auth activate-service-account --key-file="$SERVICE_ACCOUNT" --quiet
  gcloud config set project "$PROJECT_ID" --quiet
fi

flutterfire configure \
  --project="$PROJECT_ID" \
  --platforms=ios,android \
  --yes \
  --overwrite-firebase-options \
  --service-account="$SERVICE_ACCOUNT"

echo "firebase hook: configured $PROJECT_ID for '$UDARA_CLIENT'."
