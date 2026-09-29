# Udara CLI

[![pub package](https://iili.io/Cwteh5x.png)](https://pub.dev/packages/udara_cli)

Build and maintain many branded versions of one Flutter app. Each client gets
its own app name, bundle id, icons, splash, fonts and configuration, and one
command builds any client, or all of them in parallel.

- 🏢 **Multi-client** — one folder per client under `clients/`
- 🎨 **Branding** — bundle id, app name, launcher icons, splash, fonts and iOS team per client
- 🔐 **Compiled config & secrets** — client values compiled into a Dart class instead of a readable `.env`; build-time secrets never ship
- 🚀 **Batch & parallel builds** — several clients and platforms at once, with per-client versions, live progress and ETA
- 🧩 **IDE extensions** — run and build any client from VS Code or Android Studio
- 🪝 **Hooks** — your own per-client scripts (Firebase, OneSignal, uploads) at fixed points of every build
- 🩺 **Doctor, history and diff** — catch problems before a build, review past builds, compare clients
- 📱 **Slack notifications** (optional)

---

## Installation

Requires the Flutter SDK. `udara_cli setup` installs everything else the project needs.

```bash
dart pub global activate udara_cli
udara_cli --version
```

If `udara_cli` isn't found, add the pub cache to your PATH: `export PATH="$PATH:$HOME/.pub-cache/bin"` in `~/.zshrc` / `~/.bashrc` (macOS/Linux), or `%LOCALAPPDATA%\Pub\Cache\bin` on Windows.

## IDE Extensions 🧩

Both extensions list every client with its env files, and run (`whitelabel` + `flutter run`, with the IDE's own debugger and hot reload) or build any client with a click, including multi-client batch builds with per-client versions and progress bars.

- **VS Code**: [Udara Whitelabel on the VS Code Marketplace](https://marketplace.visualstudio.com/items?itemName=deecency.udara-whitelabel) · [source](extensions/vscode/)
- **Android Studio / IntelliJ IDEA**: [Udara Whitelabel on the JetBrains Marketplace](https://plugins.jetbrains.com/plugin/34541-udara-whitelabel) · [source](extensions/jetbrains/)

They use `udara_cli list-clients --json` and `udara_cli history --json`, which are handy for your own scripts too.

## Migrating an Existing Project

Projects set up before 1.3.1 bundle each client's `.env` into the app with
flutter_dotenv, where anyone can read it by unzipping the APK/IPA. They keep
working unchanged until you migrate to [generated config](#app-configuration--secrets-):

```bash
git commit -am "before udara config migration"   # it refuses to run on a dirty tree
udara_cli migrate-config            # preview: shows every change, writes nothing
udara_cli migrate-config --apply    # migrate
flutter analyze && udara_cli doctor
```

The migration:

1. sets `app_config: mode: generated` in `udara.yaml` and generates `lib/udara_config.g.dart` from the default client;
2. writes `app_config.include` with the keys your code reads, so nothing else is compiled in. When code reads keys by computed name (e.g. a `switch` returning `'CONNECTION_STRING_PROD'`), the preview lists the keys it detected from string literals; `--include-detected` uses them once you've checked them;
3. rewrites `dotenv.env[...]`, `dotenv.get(...)`, `maybeGet`, `getInt`, `getDouble`, `getBool`, `isEveryDefined` and `isInitialized` to `UdaraConfig`, removes `await dotenv.load(...)` and the unused `CLIENT_ENV` constant, and fixes imports;
4. removes `.env` entries from `pubspec.yaml` assets and git-ignores `clients/*/.secrets*`;
5. reports native build files (Gradle, Xcode) that read the root `.env`. They keep working; their secrets can move to `.secrets`.

Your `.env` files are never modified. Anything it can't rewrite safely (writes to `dotenv.env`, custom `DotEnv()` instances, prefixed imports, `loadFromString` in tests, ...) is listed instead of touched, and items that would break the app block `--apply` until fixed (or `--force`). It also lists secret-looking keys so you can move them to `.secrets` first.

**To roll back:** `git checkout . && git clean -fd lib`.

---

## Getting Started

```bash
udara_cli setup                                    # dependencies, configs, .gitignore
udara_cli setup --clients default,clientA,clientB  # client folders from templates
udara_cli doctor                                   # check everything
```

`setup` installs `rename`, `flutter_launcher_icons` and `splash_master`, creates `flutter_launcher_icons.yaml` and the `splash_master` config, starts new projects in generated config mode, and git-ignores the CLI's local state (`.udara/`, `.udara_build_history.json`, `/.env`, `clients/*/.secrets*`).

`setup --clients` creates `clients/<name>/` with `.env`, `.env_test`, placeholder `logo_small.png` / `logo_large.png` (replace them; `doctor` warns while they are placeholders), a `fonts/` folder and a README. A `default` client is always created: it is what plain `flutter run` uses.

For Slack notifications: `udara_cli setup --notify` (a bot token `xoxb-…` with `chat:write`, `files:write`, `channels:read`).

## Project Structure

```
your_flutter_project/
├── clients/
│   ├── default/                 # required fallback client
│   │   ├── .env                 # client config (.env_test for --test)
│   │   ├── .secrets             # optional build-time secrets, git-ignored
│   │   ├── logo_small.png       # app icon source
│   │   ├── logo_large.png       # splash screen source
│   │   └── fonts/               # optional custom fonts + fonts.yaml
│   └── clientA/ ...
├── assets/branding/<client>/    # GENERATED during a run, removed afterwards
├── lib/udara_config.g.dart      # GENERATED config (commit the default client's)
├── udara.yaml                   # app_config and hooks
├── .udaraignore                 # patterns never copied into the app
└── flutter_launcher_icons.yaml
```

Everything in a client folder except env/secrets files, `README.md` and `.udaraignore` matches is copied to `assets/branding/<client>/` for that client's run, and registered under `flutter.assets`. Flutter only bundles the top level of a registered asset folder.

### Client `.env`

```env
APP_NAME_PROD="Client A"                                  # required: app name
BUNDLE_ID="com.company.clienta"                           # required: bundle / application id
ASSETS_PATH="clients/clientA/"                            # required: copied to assets/branding/clientA/
APP_ICON_PATH="assets/branding/clientA/logo_small.png"    # required: launcher icon
APP_LOGO_PATH="assets/branding/clientA/logo_large.png"    # optional: splash image (defaults to the icon)
DEVELOPMENT_TEAM="ABC123XYZ9"                             # optional: iOS signing team

# Anything else is yours: theme colours, feature flags, API URLs, fonts...
PRIMARY_COLOR="0xFF2196F3"
SHOW_SIGN_UP=true
FONT_FAMILY="Manrope"
```

`doctor` and `build` fail early when a required key is missing. Files follow the usual dotenv rules (quotes, `export`, `# comments`).

**iOS team:** with `DEVELOPMENT_TEAM` set, iOS builds write it into `ios/Runner.xcodeproj/project.pbxproj` and restore it afterwards; without it, your Xcode signing is left untouched.

---

## App Configuration & Secrets 🔐

| | **Generated** (recommended; default for new projects) | **dotenv** (projects set up before 1.3.1) |
| --- | --- | --- |
| What ships in the app | A compiled Dart class with the client's values | The client's whole `.env` as an asset (plus the default client's) |
| Readable by unzipping the APK/IPA | No | Yes |
| Build-only keys (`DEVELOPMENT_TEAM`, `ASSETS_PATH`) | Left out | Shipped |
| In your code | `UdaraConfig.primaryColor`, `UdaraConfig.get('KEY')` | `dotenv.env['KEY']` |

> **Nothing inside an app is truly secret.** Compiled constants stop casual extraction, not a determined attacker. Keep private values (payment secret keys, admin tokens, signing passwords) out of `.env`: in `.secrets` if only the build needs them, behind your backend if the app does. Firebase-style "API keys" are public by design; protect those services with security rules and [App Check](https://firebase.google.com/docs/app-check).

### Generated config

With `app_config: mode: generated` in `udara.yaml`, every `build` and `whitelabel` writes `lib/udara_config.g.dart` for the client and restores it afterwards. Commit it: the checked-in (default client's) version is what plain `flutter run` uses, with no `--dart-define` needed.

**After adding, renaming or removing a key** in any client's `.env`, run `udara_cli generate-config` (or Regenerate App Config in the extensions) so your code and IDE see the new field, then commit the file. Builds pick up new keys on their own. If your `.gitignore` ignores `*.g.dart` (build_runner), udara_cli adds an exception for this file.

```dart
import 'package:your_app/udara_config.g.dart';

Color(int.parse(UdaraConfig.primaryColor ?? '0xFF4285F4'));   // typed constant
UdaraConfig.getBool('SHOW_SIGN_UP', fallback: false);          // flutter_dotenv-style API
UdaraConfig.env['API_BASE_URL'];
```

- Every key becomes a constant (`PRIMARY_COLOR` → `primaryColor`). All clients and `.env_test` share the same fields; a key missing from any of them is `String?`, so code that compiles for one client compiles for all.
- `env`, `get`, `maybeGet`, `getInt`, `getDouble`, `getBool`, `isEveryDefined` and `isInitialized` behave like flutter_dotenv's; `UdaraConfig.client` and `UdaraConfig.isTestEnvironment` say which build you're in.
- Options:

  ```yaml
  app_config:
    mode: generated                   # or dotenv
    output: lib/udara_config.g.dart   # must be under lib/
    class_name: UdaraConfig
    exclude: [DEVELOPMENT_TEAM, ASSETS_PATH]   # never compiled in
    include: [BANK_NAME, PRIMARY_COLOR]        # optional: ONLY these are compiled in
  ```

  With `include`, nothing else reaches the app even if it's in `.env`. `doctor` warns when code reads a key that isn't listed (it would be null).
- **Root `.env` for native builds:** only when a native build file reads it (e.g. Gradle signing reading `RELEASE_STORE_PASSWORD`), and only during `udara_cli build`, it is written as the client's `.env` plus `.secrets`, never registered as an asset, and removed afterwards. Make release builds with `udara_cli build`.

### Build-time secrets: `.secrets`

`clients/<client>/.secrets` (and `.secrets_test` for `--test`) use the same `KEY=VALUE` format but are **never** compiled in, bundled, copied into branding assets or listed. Hooks get the path as `UDARA_SECRETS_FILE` (`source "$UDARA_SECRETS_FILE"`). `doctor` fails when a `.secrets` file isn't git-ignored, and warns about secret-looking values (`sk_live_…`, `*_SECRET`, `*_PASSWORD`, `*_TOKEN`, private keys) in config that ships.

### dotenv mode

Without an `app_config` section, the client's `.env` is staged as the root `.env`, registered under `flutter.assets` with `clients/default/.env` as the fallback, and `--dart-define=CLIENT_ENV=.env` is passed to Flutter:

```dart
const envFile = String.fromEnvironment('CLIENT_ENV', defaultValue: 'clients/default/.env');
await dotenv.load(fileName: envFile);
```

---

## Custom Fonts

Put the font files and a `fonts.yaml` in `clients/<name>/fonts/` (or `<ASSETS_PATH>/fonts/`). `fonts.yaml` is the list that goes under pubspec's `fonts:`, without the `fonts:` key itself:

```yaml
- family: Manrope
  fonts:
    - asset: assets/fonts/Manrope-Regular.ttf
      weight: 400
    - asset: assets/fonts/Manrope-Bold.ttf
      weight: 700
```

For that client's run, `assets/fonts/` is replaced with the client's fonts and the families go into `pubspec.yaml`; read the family from config (e.g. `UdaraConfig.fontFamily` from `FONT_FAMILY`). The original fonts and pubspec come back exactly afterwards, so a client without fonts always gets the project's own, and two clients' fonts never mix.

---

## Building

```bash
udara_cli build --client clientA                                  # Android App Bundle
udara_cli build --client clientA --platform ios                   # IPA
udara_cli build --client clientA --type apk --test                # APK with .env_test
udara_cli build --client clientA,clientB --platform android,ios --type aab,apk
udara_cli build --all-clients --build-version 2.1.0+45
```

| Option | |
| --- | --- |
| `--client`, `-c` | Client(s), comma-separated or repeated |
| `--all-clients` | Every client in `clients/` |
| `--platform`, `-p` | `android` (default), `ios`, or both |
| `--type`, `-t` | `aab` (default), `apk`, or both. iOS always builds an IPA |
| `--build-version` | For all clients (`1.4.0+12`) or per client (`clientA=1.4.0+12,clientB=2.0.0`); without `+n` the pubspec build number is kept. pubspec.yaml isn't edited |
| `--parallel`, `-j` | Jobs at the same time: `auto` (default, 1-4 from RAM/CPU) or a number |
| `--test` | Use `.env_test` (and `.secrets_test`) |
| `--fail-fast` | Stop at the first failure |
| `--slack`, `--slack-channel` | Slack notifications (default channel `#builds`) |
| `--progress-file` | Keep a JSON progress snapshot in this file |

Artifacts are collected in `build/udara/<client>/<client>_v<version>.<aab|apk|ipa>`, so later builds never overwrite them.

**What a build does:** validates the client → backs up everything it will touch → generates the config, copies branding assets and fonts → sets bundle id and app name, generates icons and splash → runs `after_branding` hooks → `flutter build` → checks the signing → runs `after_build` hooks → **restores the project** (always, even on failure or Ctrl+C) → records history and notifies Slack. Afterwards `git status` is exactly as before: bundle id, app name, `res/`, `Assets.xcassets`, `Info.plist`, the Xcode project and Firebase outputs included.

**Signing check:** when no release keystore is found, Gradle can silently sign a release build with the debug key, which Play rejects. A debug-signed AAB fails the build (kept as `*.debug-signed.aab`, before any `after_build` hook sees it); a debug-signed APK only warns, since those are normal for QA.

### Batch & parallel builds

A batch is split into **jobs of one client on one platform** (AAB and APK share a job and its Gradle caches). With `--parallel` above 1, each job runs in its own copy of the project under `~/.udara_cli/workspaces/`, synced before every job (uncommitted changes included), so builds never touch each other or your working copy. The copies keep their build, Gradle and CocoaPods caches; `udara_cli clean --workspaces` deletes them.

- A live view shows percent, ETA (learned from your build history) and each job's step; CI logs and IDE consoles get one line per event.
- Each job's output is in `build/udara/logs/<client>-<platform>.log`, and the summary shows the lines around any failure.
- A failed build doesn't stop the rest (unless `--fail-fast`); the exit code is non-zero if any failed.
- Ctrl+C or an IDE stop button stops every job and every Flutter/Gradle/Xcode process, and keeps finished artifacts.

> On a fresh machine, run one build first so Gradle and CocoaPods download their caches once, instead of every parallel job waiting on the same download.

## Running a Client Locally (`whitelabel`)

```bash
udara_cli whitelabel --client clientA --keep    # or --test --keep
flutter run                                     # dotenv mode: flutter run --dart-define=CLIENT_ENV=.env
```

`--keep` applies the client's full branding and leaves it in place so you can run the app as that client; this is what the extensions' Run Client does. Everything it changes is backed up in `.udara/`: the next `whitelabel` or `build` restores the original project first, so nothing carries over between clients, and `udara_cli clean` restores it too. `doctor` shows which client the project is branded as.

Without `--keep`, only the native branding (app name, bundle id, icons, splash, iOS team) stays; the staged files are restored straight away.

---

## Hooks 🪝

Run your own scripts at fixed points of `build` and `whitelabel`, for per-client setup the CLI doesn't know about. Declare them in `udara.yaml`:

```yaml
hooks:
  after_branding:
    - ./scripts/firebase_configure.sh
  after_build:
    - ./scripts/upload_to_store.sh
```

| Hook | When it runs |
| --- | --- |
| `after_branding` | After bundle id, app name, icons, splash and iOS team are applied, before `flutter build`. Also in `whitelabel`, so Run Client gets it. |
| `after_build` | After a successful `build`, with `UDARA_ARTIFACT` set to the artifact. |

Commands run in the project root with `UDARA_CLIENT`, `UDARA_CLIENT_DIR`, `UDARA_BUNDLE_ID`, `UDARA_ENV`, `UDARA_SECRETS_FILE`, `UDARA_PLATFORM`, `UDARA_VERSION` and more. A non-zero exit stops the run and the project is restored. [`example/hooks/`](example/hooks/) has ready-made Firebase/FCM and OneSignal hooks and the full variable list.

## Diagnostics

```bash
udara_cli doctor [--client clientA]            # validate the project or one client
udara_cli history [--client clientA] [--limit 25] [--clear]
udara_cli diff --client-a clientA --client-b clientB [--test] [--all]
```

- **`doctor`** checks dependencies, env files and required keys, icon/logo paths and placeholders, `fonts.yaml`, bundle ids, hooks, generated config, secrets and leftover state. It exits non-zero on failure, so it works as a CI gate.
- **`history`** shows recent builds from `.udara_build_history.json` (last 50, successes and failures).
- **`diff`** compares two clients' env files and highlights the keys that differ.

## Command Reference

```bash
udara_cli setup [--clients a,b] [--notify] [--reset]
udara_cli build --client <name> [options]          # see Building
udara_cli whitelabel --client <name> [--test] [--keep]
udara_cli migrate-config [--apply] [--include-detected] [--force]
udara_cli generate-config [--client <name>] [--test]  # refresh lib/udara_config.g.dart
udara_cli clean                                    # restore the project, then flutter clean
udara_cli clean --workspaces                       # delete parallel build workspaces
udara_cli list-clients [--json]
udara_cli doctor | history | diff                  # see Diagnostics
udara_cli <command> --help                         # --verbose for stack traces
```

## Troubleshooting

Run `udara_cli doctor` first; it catches most problems before a build.

- **Command not found:** add the pub cache to your PATH (see [Installation](#installation)).
- **Play rejects the bundle ("signed with the wrong key"):** check `android/key.properties` uses `storeFile`, `storePassword`, `keyAlias`, `keyPassword` (or set `RELEASE_STORE_FILE` and friends in the client's `.env`/`.secrets` if your Gradle reads the root `.env`), and don't let the release `buildType` fall back to `signingConfigs.debug`.
- **Project still branded after a run or crash:** `udara_cli clean`.
- **A client behaves differently:** `udara_cli diff` it against one that works.

Found a bug? [Open an issue](https://github.com/deecency/udara_cli/issues) with the error output (`--verbose`).

## Contributing

Pull requests are welcome.

```bash
dart pub get && dart analyze && dart test
dart run bin/udara_cli.dart --help
```

MIT licensed. See [CHANGELOG.md](CHANGELOG.md) for release notes.
