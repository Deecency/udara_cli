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