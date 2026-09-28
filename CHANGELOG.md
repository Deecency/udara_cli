## 1.5.0

* **SECURITY**:

- New **generated app config** (`app_config: mode: generated` in `udara.yaml`): instead of bundling the client's `.env` as a Flutter asset (readable by anyone who unzips the APK/IPA, together with the default client's `.env`), each build generates `lib/udara_config.g.dart` with the client's values as typed constants and restores it afterwards. No config file ships, build-only keys (`DEVELOPMENT_TEAM`, `ASSETS_PATH`, configurable) are left out, and no other client's values are included. The class mirrors flutter_dotenv's API (`env`, `get`, `maybeGet`, `getInt`, `getDouble`, `getBool`, `isEveryDefined`, `isInitialized`) and has the same fields for every client and environment.
- **Allow-list** (`app_config.include`): only the listed keys are compiled in. `migrate-config` fills it with the keys the code reads (literal reads, plus keys detected from string literals when code reads keys by computed name, opt-in with `--include-detected`); `doctor` warns when code reads a key that isn't listed.
- **Native builds keep their root `.env`, only when needed**: in generated mode, `build` writes a root `.env` (the client's `.env` plus its `.secrets`, marked with a header) only when a native build file reads it (e.g. Gradle release signing), never as an app asset, and removes it after the build. `whitelabel` never writes it; `clean` removes a leftover one. `migrate-config` reports native build files that read it.
- `list-clients --json` reports the project's `appConfig` mode, so the IDE extensions (0.3.0) only pass `--dart-define=CLIENT_ENV=.env` in dotenv mode.
- **`.secrets` files**: `clients/<client>/.secrets` (and `.secrets_test`) hold build-time secrets that are never compiled in, bundled, copied into branding assets or listed; hooks get their path as `UDARA_SECRETS_FILE`. `setup` git-ignores them.
- `doctor` warns about secret-looking values that would ship with the app (in either mode), fails when a `.secrets` file isn't git-ignored, and in generated mode checks the generated file, that no `.env` is still an asset and that no `dotenv.load()` is left.

* **MIGRATION** (nothing changes until you opt in):

- Projects without an `app_config` section keep the existing dotenv behaviour exactly; `build` and `doctor` now point out that `.env` is readable in the shipped app.
- New `udara_cli migrate-config` previews, then with `--apply` migrates a project: sets generated mode, generates the class from the default client, rewrites dotenv usages to the generated class, removes `dotenv.load()` calls, the unused `CLIENT_ENV` constant and `.env` assets, and git-ignores `.secrets`. `.env` files are never modified. It refuses to run on a dirty git tree (so `git checkout .` undoes it) and lists anything it can't rewrite safely; items that would break the app block `--apply` unless `--force`.
- `setup` on a new project (no `clients/` yet) starts in generated mode and doesn't install flutter_dotenv.

* **OTHER**:

- `build` now leaves the project exactly as it found it: besides its config files it snapshots and restores everything branding and hooks change (`applicationId`, `AndroidManifest.xml`, `Info.plist`, the Xcode project, Android `res/`, `Assets.xcassets`, `Base.lproj`, and Firebase outputs). Previously the client's bundle id, app name, icons and splash stayed in the project after a build. `whitelabel` still keeps branding applied. Hooks that skip work when their output already matches (like the example Firebase hook) now run on every build.
- Cleanup restores every file a run backed up, instead of a fixed list.
- `clean` regenerates the default client's config after `whitelabel --keep` in generated mode.

* **FIXES**:

- `whitelabel --keep` (the editors' Run Client) now backs up everything it changes (pubspec, launcher icon config, fonts, generated config, native branding) and leaves those backups in `.udara/` instead of restoring them. The next run restores the original project before applying its client, and `clean` restores it too. Previously, running a client without fonts after one with fonts kept the previous client's fonts and pubspec `fonts:` entry, two font clients in a row mixed their fonts, and `clean` restored the font folder but not the pubspec entry.
- Client fonts replace `assets/fonts` from a snapshot instead of parking the originals in `assets/fonts.bak`, so a project that had no `assets/fonts` gets none back. A leftover `assets/fonts.bak` from older versions is still restored.
- `clean` on a project branded by an older version (no backups) repairs the sections udara_cli manages (pubspec `fonts:`, the `assets/branding/` entry, the splash image and the launcher icon path) from the last commit.
- `assets/branding` is snapshotted and restored exactly, so a branding folder a run created (including the default client's) no longer lingers after cleanup, and switching clients leaves no other client's folder behind.
- `doctor` reports a project branded with `--keep` as such instead of as an interrupted run.

## 1.4.0

* **NEW**:

- Batch builds: `--client`, `--platform` and `--type` accept several values (comma-separated or repeated), and `--all-clients` builds every client.
- Parallel builds: batches are split into jobs of one client on one platform and run `--parallel N` at a time (`auto` by default: 1-4 based on RAM and CPU). Each parallel job runs in its own synced copy of the project under `~/.udara_cli/workspaces/`, so builds never touch each other's files or your working copy; the copies keep their build, Gradle and CocoaPods caches. `udara_cli clean --workspaces` deletes them.
- Per-client versions: `--build-version 1.4.0+12` or `--build-version acme=1.4.0+12,beta=2.0.0` sets the version for a build without editing pubspec.yaml (passed to Flutter as `--build-name`/`--build-number`; without `+n` the pubspec build number is kept).
- Live progress: a redrawing terminal view with overall percent, ETA and each running job's step (plain status lines in CI and IDE consoles). ETAs are estimated from the project's build history. `--progress-file <path>` writes a JSON snapshot for tools.
- Per-job logs in `build/udara/logs/`; the summary shows the lines around each failure.
- Cancel with Ctrl+C or a termination/hang-up signal (IDE stop buttons): every worker and every Flutter/Gradle/Xcode process it started is stopped, finished artifacts are kept, and a single build restores the project immediately. Exit code 130.
- `--fail-fast` stops the whole batch at the first failure.
- The IDE extensions (VS Code 0.2.0, Android Studio plugin 0.2.0) add Build Multiple Clients… with per-client versions, parallelism and progress bars on top of this.

* **CHANGES**:

- Artifacts are collected in `build/udara/<client>/<client>_v<version>.<type>` instead of being renamed inside Flutter's output folders, so a later build can't overwrite or clean them up.
- In `after_branding` hooks of a multi-target job, `UDARA_PLATFORM` and `UDARA_BUILD_TYPE` list all targets; `after_build` hooks get the single target.

## 1.3.0

* **NEW**:

- Hooks: declare commands in `udara.yaml` that run at `after_branding` (after the client's native branding is applied, before `flutter build`; also during `whitelabel`, so IDE "Run Client" flows get it) and `after_build` (after a successful build, with `UDARA_ARTIFACT`). Hooks receive `UDARA_CLIENT`, `UDARA_CLIENT_DIR`, `UDARA_BUNDLE_ID`, `UDARA_ENV`, `UDARA_VERSION` and more; a failing hook stops the run and the project is still restored. Unknown hook names fail fast.
- `doctor` validates `udara.yaml` and checks hook scripts exist and are executable.
- `example/hooks/` with ready-made Firebase (FCM) and OneSignal push notification hooks.

* **FIXES**:

- `build` and `whitelabel` now restore the project first when a previous run was interrupted. Previously the stale backups were restored by the new run's cleanup, silently reverting part of the new client's branding (e.g. the iOS bundle id).

## 1.2.0

* **FIXES**:

- `.env` parsing now handles inline `# comments`, single quotes and `export KEY=VALUE`. Previously a value such as `DEVELOPMENT_TEAM="ABCD1234" #comment` (the template `setup` generated) was read as `ABCD1234" #comment` and patched into the Xcode project verbatim.
- An existing root `.env` is backed up before a build stages the client env there, and restored afterwards; when no root `.env` existed the staged copy is removed on cleanup instead of leaving client secrets behind.
- Built-in ignore patterns such as `*.jks` and `*.pem` now also match files in sub-folders of the client assets directory, so nested keystores and keys are no longer copied into the app bundle.
- `clients/default/.env` (the runtime fallback registered by `setup`) is no longer stripped from `flutter.assets` when a client is applied.
- `whitelabel` now stages the env the same way as `build` (root `.env`, registered as an asset), honours `--test` and `DEVELOPMENT_TEAM`, and restores the staged project files afterwards (the iOS project file is left as patched). New `--keep` flag leaves them in place so the app can be run as the client with `flutter run --dart-define=CLIENT_ENV=.env`.
- Unknown options (e.g. `udara_cli build --bogus`) are reported as usage errors with the command's help instead of an "Unexpected Error" asking to file a bug.
- iOS builds record `ipa` as the artifact type (instead of the Android default `aab`) and the built `.ipa` is renamed to `<client>_v<version>.ipa` like Android artifacts.
- The Slack build summary is now actually posted for every build; previously only APK uploads happened and AAB/iOS/failed builds produced no summary message.
- The splash screen image now uses `APP_LOGO_PATH` (falling back to `APP_ICON_PATH`) as documented, instead of always using the app icon.
- Client fonts are looked up in `clients/<client>/fonts` first (what `doctor` validates) and then `<ASSETS_PATH>/fonts`.
- The default client's branding folder is preserved consistently: the pre-sync cleanup no longer deletes it while the post-build cleanup kept it.
- Removed the stray `.udara_build_history.json` from the repository and ignored it.

* **IMPROVEMENTS**:

- Global `--verbose` flag: prints stack traces on failures and enables Slack debug output.
- `doctor` validates icon/logo paths again by resolving them to the client folder, flags images that are still the generated placeholder, checks `fonts.yaml` references against the font files present, validates `BUNDLE_ID` format, warns about leftover `.udara` state from interrupted builds and about `.udara_build_history.json` missing from `.gitignore`.
- `setup --clients` generates valid solid-colour placeholder PNGs (so icon/splash tooling runs before real artwork exists), a per-client `README.md`, a cleaner `.env` template, adds `flutter_dotenv` when missing, and appends `.udara/`, `.udara_build_history.json` and `/.env` to `.gitignore`.
- `build` fails fast with a pointed message when the client folder, its env file, or `flutter_launcher_icons.yaml` is missing (listing the available clients), and prints a build summary with duration and artifact path.
- `list-clients` shows each client's app name, bundle id and whether a `.env_test` exists.
- `history` prints the artifact path of successful builds and rejects a non-numeric `--limit`.
- `clean` restores any files left backed up by an interrupted build before running `flutter clean`.
- Shared step/validation/Slack helpers moved into the base command; dead code removed.
- Added a unit test suite (`dart test`) covering env parsing, pubspec asset editing, backup/restore, asset sync ignore rules and artifact renaming.
- `list-clients --json` and `history --json` emit machine-readable output (human log lines move to stderr) for editor integrations and scripts.
- New IDE extensions under `extensions/`: a VS Code extension and an Android Studio / IntelliJ plugin that list clients and env files and trigger run, build, whitelabel, doctor, clean and diff through the CLI.

## 1.1.3

* **FIXES** (published to pub.dev on 2026-08-06; notes copied from that release):

- Improved `clean` command logging by reporting the project cleanup phase before cleanup completes.
- Added temporary `.env` removal during cleanup so stale environment files do not persist between builds.
- Refined cleanup behavior to ensure project state is restored cleanly after asset refreshes.

## 1.1.2

* **FIXES**:

- Cleaned up the `doctor` command diagnostics and kept the asset-path validation comments aligned with the actual client asset layout.
- Ensured local project metadata is excluded from version control by ignoring `.udara/` workspace artifacts.
- Prepared the package for a clean publish by keeping the repo state release-ready.

## 1.1.1

* **FIXES**:

- Hardened backup/restore behavior by storing backups in a project-local `.udara/backups` directory instead of side-by-side `.bak` files, making restore operations more reliable and less likely to clobber unrelated files.
- Protected managed branding folders from accidental deletion by refusing to remove non-managed asset directories and cleaning up only inactive client branding folders marked by `udara_cli`.
- Improved asset sync validation so builds fail early when no branding assets are copied for the selected client, with clearer remediation guidance.
- Corrected the client `.env` asset path wiring during white-label setup to ensure the proper env file is tracked for each client.

## 1.1.0

* **NEW**:

- `doctor` command: Validates project & client setup before building — checks required project files, pubspec dependencies (including `flutter_dotenv`), and per-client `.env`/`.env_test` presence, required keys, referenced asset paths, and font configuration. Run with `udara_cli doctor` or `udara_cli doctor --client <name>`.
- `history` command: Every build (success or failure) is now recorded to a project-local `.udara_build_history.json`. View recent builds with `udara_cli history`, filter with `--client`/`--limit`, or clear with `--clear`.
- `diff` command: Compare environment configuration between two clients with `udara_cli diff --client-a <NAME> --client-b <NAME>`. Add `--test` to compare `.env_test` files, or `--all` to show every key instead of only the ones that differ.
- Added an `example/` folder demonstrating a full setup → build workflow.

* **IMPROVEMENTS**:

- Colored terminal output: Success, warning, and error messages are now color-coded (green/yellow/red) instead of emoji-only, with automatic fallback to plain text when the terminal doesn't support ANSI escapes (e.g. output piped to a file or CI log).
- Added `topics` and refined metadata in `pubspec.yaml` for improved pub.dev discoverability.
- Expanded dartdoc comments across the public API.

## 1.0.6


* **FIXES**: 

- Dynamic iOS Development Team: Added support for reading client-specific DEVELOPMENT_TEAM IDs from environment variables during iOS builds.
- Centralized Structured Logging: Replaced ad-hoc print() statements with a dedicated Logger class (phase, info, success, warning, error) to produce clean, scannable terminal output.
- Enhanced Exception Tracking: Replaced generic throws with contextual BuildException instances that include actionable remediation suggestions (fix) to easily pinpoint and resolve    failure root causes.
- Built-in default ignore rules to prevent accidental copying of sensitive files such as:
  - `service_account.json`
  - `*.pem`, `*.key`, `*.p12`, `*.jks`, `*.keystore`
- Resilient Pipeline Execution: Improved file I/O checks, pre-flight configuration validation, and build step notifications across all commands.
- Support for user-defined ignore patterns via `.udaraignore` file.