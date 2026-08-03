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