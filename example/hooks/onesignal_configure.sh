#!/bin/bash
# after_branding hook: align OneSignal's iOS setup with the client's bundle id.
#
# udara.yaml:
#   hooks:
#     after_branding:
#       - ./scripts/onesignal_configure.sh
#
# The OneSignal app id itself is read at runtime from the client's env file
# (e.g. OneSignal.initialize(dotenv.env['ONESIGNAL_APP_ID']!)), so only the
# native iOS pieces that embed the bundle id need changing per client:
#   - the Notification Service Extension's bundle id must be
#     <app bundle id>.OneSignalNotificationServiceExtension (the rename step
#     sets every target to the app's id, which Xcode rejects for extensions)
#   - the app group group.<app bundle id>.onesignal in both entitlements files
set -euo pipefail

EXTENSION_NAME="${ONESIGNAL_EXTENSION_NAME:-OneSignalNotificationServiceExtension}"
PBXPROJ="ios/Runner.xcodeproj/project.pbxproj"

APP_ID=$(grep -E '^[[:space:]]*(export[[:space:]]+)?ONESIGNAL_APP_ID=' "$UDARA_ENV_FILE" | tail -1 \
  | sed -E 's/^[^=]*=[[:space:]]*//; s/^["'\'']//; s/["'\''][[:space:]]*(#.*)?$//; s/[[:space:]]+#.*$//' || true)
if [ -z "$APP_ID" ]; then
  echo "onesignal hook: WARNING ONESIGNAL_APP_ID is not set in $UDARA_ENV_FILE." >&2
fi

if [ ! -f "$PBXPROJ" ] || ! grep -q "$EXTENSION_NAME" "$PBXPROJ"; then
  echo "onesignal hook: no $EXTENSION_NAME target in the iOS project, skipping iOS setup."
  exit 0
fi

EXTENSION_BUNDLE_ID="$UDARA_BUNDLE_ID.$EXTENSION_NAME"
APP_GROUP="group.$UDARA_BUNDLE_ID.onesignal"

# Set PRODUCT_BUNDLE_IDENTIFIER only inside the extension's build settings
# blocks (identified by its Info.plist / entitlements paths).
python3 - "$PBXPROJ" "$EXTENSION_NAME" "$EXTENSION_BUNDLE_ID" <<'PY'
import re, sys
path, name, bundle = sys.argv[1:4]
src = open(path).read()
count = 0
def fix(block):
    global count
    text = block.group(0)
    if f"{name}/" not in text:
        return text
    count += 1
    return re.sub(r"PRODUCT_BUNDLE_IDENTIFIER = [^;]+;", f"PRODUCT_BUNDLE_IDENTIFIER = {bundle};", text)
out = re.sub(r"buildSettings = \{.*?\n\t\t\t\};", fix, src, flags=re.S)
open(path, "w").write(out)
print(f"onesignal hook: set {name} bundle id to {bundle} in {count} build configuration(s).")
PY

for entitlements in ios/Runner/*.entitlements "ios/$EXTENSION_NAME"/*.entitlements; do
  [ -f "$entitlements" ] || continue
  perl -pi -e "s/group\.[A-Za-z0-9._-]+\.onesignal/$APP_GROUP/g" "$entitlements"
  echo "onesignal hook: app group set to $APP_GROUP in $entitlements"
done
