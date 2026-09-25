# Example hooks

Hooks let `udara_cli` run your own scripts at fixed points of `build` and
`whitelabel`, so per-client setup that the CLI doesn't know about (push
notifications, analytics, signing, uploads) happens automatically, including
when you run or build from the VS Code and Android Studio extensions.

## Use them

1. Copy the scripts you need into your Flutter project, e.g. `scripts/`, and
   make them executable:

   ```bash
   mkdir -p scripts
   cp firebase_configure.sh onesignal_configure.sh /path/to/app/scripts/
   chmod +x /path/to/app/scripts/*.sh
   ```

2. Copy [`udara.yaml`](udara.yaml) to the project root and keep the hooks you
   use.
3. Run `udara_cli doctor`. It checks hook names and that each script exists
   and is executable.

## Included

| Script | Hook | What it does |
| --- | --- | --- |
| [`firebase_configure.sh`](firebase_configure.sh) | `after_branding` | Firebase / FCM push notifications. If `clients/<client>/service_account.json` exists, runs `flutterfire configure` for that project with the client's bundle id already applied. Skips when `lib/firebase_options.dart` and `google-services.json` already match (set `UDARA_FIREBASE_FORCE=1` to force). Needs `jq`, the Firebase CLI and FlutterFire CLI. |
| [`onesignal_configure.sh`](onesignal_configure.sh) | `after_branding` | OneSignal push notifications. Sets the iOS Notification Service Extension's bundle id to `<bundle id>.OneSignalNotificationServiceExtension` and the app group to `group.<bundle id>.onesignal` in both entitlements files. Warns if `ONESIGNAL_APP_ID` is missing from the client's env file. Set `ONESIGNAL_EXTENSION_NAME` if your extension target has another name. |

Keep per-client secrets such as `service_account.json` inside
`clients/<client>/`. They are never copied into the app bundle (see
`.udaraignore`), but do add them to `.gitignore` if the repo is shared.

## Variables available to every hook

| Variable | Example |
| --- | --- |
| `UDARA_HOOK` | `after_branding` |
| `UDARA_COMMAND` | `build` or `whitelabel` |
| `UDARA_CLIENT` | `acme` |
| `UDARA_CLIENT_DIR` | `/path/to/app/clients/acme` |
| `UDARA_PROJECT_DIR` | `/path/to/app` (also the working directory) |
| `UDARA_ENV` | `prod` or `test` |
| `UDARA_ENV_FILE` | `/path/to/app/clients/acme/.env_test` |
| `UDARA_BUNDLE_ID` | `com.acme.app` |
| `UDARA_APP_NAME` | `Acme` |
| `UDARA_VERSION` | `1.4.0+12` |
| `UDARA_PLATFORM` | `android` or `ios` (empty for `whitelabel`) |
| `UDARA_BUILD_TYPE` | `apk`, `aab` or `ipa` (empty for `whitelabel`) |
| `UDARA_ARTIFACT` | `/path/to/app/build/.../acme_v1.4.0_12.apk` (`after_build` only) |

A hook that exits with a non-zero status stops the run; the project is still
restored as usual.
