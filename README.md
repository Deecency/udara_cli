# Udara CLI

[![pub package](https://iili.io/Cwteh5x.png)](https://pub.dev/packages/udara_cli)

A powerful CLI tool for managing whitelabel Flutter projects with multi-client support. Build and maintain multiple branded versions of your Flutter app from a single codebase.

---

## Features

- 🏢 **Multi-client support** - Manage unlimited white-label variants
- 🎨 **Asset management** - Client-specific icons, logos, and fonts
- ⚙️ **Environment-based configuration** - Separate configs for dev, staging, and production
- 🚀 **Automated builds** - One command to build for any client
- 📱 **Slack notifications** - Get build status updates in Slack
- 🔧 **Easy setup** - Guided project initialization
- 🩺 **Pre-build validation** - Catch missing config, keys, or assets before a build fails
- 📜 **Build history** - Every build is recorded locally so you can review recent runs
- 🔍 **Client diffing** - Compare env configuration between two clients at a glance
- 🧪 **Persistent whitelabeling** - Apply a client's branding and run it locally with `flutter run`

---

## Installation

### Global Installation

```bash
dart pub global activate udara_cli
```

### Add to PATH

Make sure the pub cache bin directory is in your PATH:

**macOS/Linux:**
```bash
export PATH="$PATH":"$HOME/.pub-cache/bin"
```

Add this to your `~/.bashrc`, `~/.zshrc`, or equivalent shell config file to make it permanent.

**Windows:**
Add `%LOCALAPPDATA%\Pub\Cache\bin` to your PATH environment variable.

### Verify Installation

```bash
udara_cli --version
```

---

## Getting Started

After installing the CLI, you need to initialize your project. The CLI provides a guided setup process:

### 1. Initial Project Setup

Run the setup command to configure your project dependencies and create necessary configuration files:

```bash
udara_cli setup
```

This will:
- Install required dependencies (`rename`, `flutter_launcher_icons`, `splash_master` and `flutter_dotenv`)
- Create `flutter_launcher_icons.yaml` configuration file
- Add `splash_master` configuration to your `pubspec.yaml`
- Add the CLI's local state files (`.udara/`, `.udara_build_history.json`, `/.env`) to `.gitignore`

### 2. Initialize Client Directories

Create your client directories with pre-configured templates:

```bash
# Create one or more clients (comma-separated)
udara_cli setup --clients default,clientA,clientB
```

This will create the complete directory structure for each client, including:
- Client folder in `clients/[name]/`
- Environment files (`.env` and `.env_test`)
- Valid placeholder `logo_small.png` / `logo_large.png` images (replace them with real artwork; `doctor` warns while they are still placeholders)
- Fonts directory
- Client-specific README

**Note**: A `default` client is always created as the runtime fallback, and `clients/default/.env` is registered under `flutter.assets` so plain `flutter run` works.

### 3. Optional: Configure Slack Notifications

If you want build notifications sent to Slack:

```bash
udara_cli setup --notify
```

You'll need:
- A Slack Bot Token (starts with `xoxb-`)
- Bot token scopes: `chat:write`, `files:write`, `channels:read`

### 4. List Available Clients

To see all configured clients:

```bash
udara_cli list-clients
```

### Other Setup Options

```bash
# Reset all CLI configurations
udara_cli setup --reset

# Get detailed help on setup command
udara_cli setup --help
```

---

## Project Structure

Your Flutter project must follow this structure for the CLI to work properly:

```
your_flutter_project/
├── clients/
│   ├── default/                 # required fallback client
│   │   ├── .env
│   │   ├── .env_test
│   │   ├── logo_small.png       # app icon source
│   │   ├── logo_large.png       # splash screen source
│   │   └── fonts/               # optional custom fonts + fonts.yaml
│   ├── clientA/
│   │   └── ... same layout ...
│   └── clientB/
│       └── ... same layout ...
├── assets/
│   └── branding/                # GENERATED: the active client's files are
│       └── <client>/            # copied here at build time and removed again
├── .udaraignore                 # patterns never copied into the app bundle
├── flutter_launcher_icons.yaml
└── pubspec.yaml
```

Everything inside a client folder (except env files, secrets, `README.md` and anything matching `.udaraignore`) is copied to `assets/branding/<client>/` when that client is built, and the folder is registered under `flutter.assets`. Sub-folders are copied too, but note that Flutter only bundles the top level of a registered asset directory.

---

## Environment Configuration

### Important: flutter_dotenv Dependency

**This tool is heavily dependent on environment files and requires the `flutter_dotenv` package.** `udara_cli setup` adds it for you; otherwise make sure it is in your `pubspec.yaml`:

```yaml
dependencies:
  flutter_dotenv: ^5.1.0  # or latest version
```

### Environment File Initialization

You **must** have a default/base client folder and environment file that acts as a fallback. Initialize the environment in your Flutter app as follows:

```dart
import 'package:flutter_dotenv/flutter_dotenv.dart';

// In your main() function or initialization code
const envFile = String.fromEnvironment(
  'CLIENT_ENV',
  defaultValue: 'clients/your_default_client_folder_name/.env',
);

await dotenv.load(fileName: envFile);
```

This ensures that:
- A default environment is always loaded if no client is specified
- Client-specific environments can override the default when building
- Your app has access to all environment variables at runtime

### Client-Specific Variables

Environment files can store client-specific variables for use throughout your application and whitelabel variants. Access these variables in your Flutter code using:

```dart
dotenv.env['VARIABLE_NAME']
```

### How It Works

The whitelabel system operates in two phases:

1. **Build Time**: When you run the CLI with a specific `--client` flag, it swaps out the environment files and configures the build process accordingly. The CLI:
   - Loads the client-specific `.env` (or `.env_test` with `--test`) from `clients/[client_name]/`
   - Stages a copy of it as `.env` in the project root and registers it under `flutter.assets` (an existing root `.env` is backed up and restored afterwards)
   - Copies client-specific assets (icons, logos, fonts) to the appropriate locations
   - Updates the app's bundle ID, app name, and other build configurations
   - Passes `--dart-define=CLIENT_ENV=.env` to Flutter so the app loads the staged file

2. **Runtime**: Once the app is running, `flutter_dotenv` reads the environment variables that were configured at build time. This allows you to:
   - Access build configurations that were set during compilation
   - Store and retrieve client-specific UI variables (feature flags, theme colors, API endpoints)
   - Drive your whitelabel logic dynamically based on these variables
   - Maintain a single codebase that adapts to different client requirements

**Example Use Cases**:
- Feature flags: `SHOW_SIGN_UP=true` to enable/disable signup for specific clients
- API configuration: Different `API_BASE_URL` values per client
- Theme customization: Client-specific `PRIMARY_COLOR` and `SECONDARY_COLOR` values
- Content variations: Different assets, logos, or branding elements per client
- Custom fonts: Client-specific `FONT_FAMILY` for typography customization


## IOS BUILDS: iOS Development Team ID

You can now configure individual **Apple Developer Team IDs** on a per-client basis. During iOS builds, `udara_cli` dynamically patches your Xcode project (`ios/Runner.xcodeproj/project.pbxproj`) with the target client's team ID and automatically reverts it back to default during project cleanup.

---

### Context

1. **Add the Team ID to the Client Environment**:
Open your client's environment file (`clients/<CLIENT_NAME>/.env` or `.env_test`) and define the `DEVELOPMENT_TEAM` key with your 10-character Apple Developer Team ID:
```env
# clients/microsoft/.env
APP_NAME_PROD="Microsoft App"
BUNDLE_ID="com.microsoft.whitelabel"
APP_ICON_PATH="assets/branding/microsoft/logo_small.png"
ASSETS_PATH="clients/microsoft/"

# iOS Signing Configuration
DEVELOPMENT_TEAM="ABC123XYZ9"

```


2. **Run the Build**:
Trigger your iOS build targeting the client:
```bash
udara_cli build --client microsoft --platform ios

```


>  **Note:** If `DEVELOPMENT_TEAM` is omitted from the client's environment file, `udara_cli` will leave your Xcode project's existing signing configuration untouched.

### Required Environment Variables

Each client must have corresponding environment files in their respective `clients/client_name/` directory. The CLI reads these keys:

```env
# Display name applied to the app (also used for .env_test builds)
APP_NAME_PROD="Your App"

# Bundle/Package Identifier
BUNDLE_ID="com.yourcompany.yourapp"

# Folder (inside clients/<name>/) whose contents are copied to assets/branding/<name>/
ASSETS_PATH="clients/default/"

# Launcher icon source, expressed as its synced location
APP_ICON_PATH="assets/branding/default/logo_small.png"

# Optional: splash screen image (falls back to APP_ICON_PATH)
APP_LOGO_PATH="assets/branding/default/logo_large.png"

# Optional: iOS signing team (see below)
DEVELOPMENT_TEAM="ABC123XYZ9"
```

`APP_NAME_PROD`, `BUNDLE_ID`, `ASSETS_PATH` and `APP_ICON_PATH` are mandatory; `doctor` and `build` fail early when one is missing. Every other key is yours to define and read in the app via `dotenv.env['KEY']`.

Env files follow the usual dotenv rules: `KEY=VALUE`, optional single or double quotes, `export KEY=VALUE`, and `# comments` on their own line or after a value.

### Optional Theme Variables

These variables can be used to modify app colors based on the environment:

```env
# Theme Colors (hex format with 0x prefix)
PRIMARY_COLOR="0xFFF26333"
BACKGROUND_COLOR="0XFFF9F9F9"
SECONDARY_COLOR="0xFF81BF42"
TERTIARY_COLOR=""

# Feature Modifications
SHOW_HOME_TEXT=true
SHOW_SIGN_UP=true
ENABLE_LION=true
ONBOARDING_IMAGES=

# Custom Typography
FONT_FAMILY="Manrope"
```

### Client-Specific Custom Fonts

The CLI supports client-specific custom fonts. Fonts are looked up in `clients/<name>/fonts/` first, then `<ASSETS_PATH>/fonts/`. Here's how to set them up:

#### 1. Add Fonts to Client Directory

Place your font files in the client's `fonts/` directory:

```
clients/
└── clientA/
    └── fonts/
        ├── Manrope-Regular.ttf
        ├── Manrope-Bold.ttf
        └── fonts.yaml  <-- Required for auto-configuration
```
Inside the fonts/ directory, create a fonts.yaml file. 
Important: Do not include the top-level fonts: key; start directly with the list of families. 
The format must match Flutter's expected structure:

```
- family: Manrope
  fonts:
    - asset: assets/fonts/Manrope-Regular.ttf
      weight: 400
    - asset: assets/fonts/Manrope-Bold.ttf
      weight: 700
```

#### 2. Configure Font in Environment File

Add the font family name to your client's `.env` file:

```env
FONT_FAMILY="Manrope"
```

#### 3. Use Font in Your Application

Access the font family dynamically in your Flutter app:

```dart
import 'package:flutter_dotenv/flutter_dotenv.dart';

TextStyle(
  fontFamily: dotenv.env['FONT_FAMILY'] ?? 'Roboto', // Fallback to default
  color: context?.textTheme.bodyLarge?.color,
  fontWeight: FontWeight.w800,
  fontFamilyFallback: const ['Roboto', 'Noto Sans', 'Arial'],
)
```

#### How Font Replacement Works

When you run the whitelabel or build command:

1. The CLI checks if the client has a `fonts/` directory
2. If custom fonts exist, it backs up the default fonts (if any)
3. Copies the client's fonts to `assets/fonts/`
4. If a `fonts.yaml` configuration exists in the client's fonts directory, it applies the font families to `pubspec.yaml`
5. During runtime, your app reads the `FONT_FAMILY` environment variable and applies the appropriate font

**Note**: If no custom fonts are provided for a client, the CLI skips the font replacement step and uses the default fonts.

### Example Environment Files

**`clients/default/.env`:**
```env
APP_NAME_DEV="Default App Dev"
APP_NAME_STAGING="Default App Staging"
APP_NAME_PROD="Default App"
BUNDLE_ID="com.company.defaultapp"
# iOS Signing Configuration
DEVELOPMENT_TEAM="ABC123XYZ9"
ASSETS_PATH="clients/default/"
APP_ICON_PATH="assets/branding/default/logo_small.png"
APP_LOGO_PATH="assets/branding/default/logo_large.png"
APP_LOGO_ICON_PATH="assets/branding/default/logo_small.png"
PRIMARY_COLOR="0xFFF26333"
BACKGROUND_COLOR="0XFFF9F9F9"
SECONDARY_COLOR="0xFF81BF42"
FONT_FAMILY="Roboto"
SHOW_HOME_TEXT=true
SHOW_SIGN_UP=true
ENABLE_LION=true
```

**`clients/clientA/.env`:**
```env
APP_NAME_DEV="Client A App Dev"
APP_NAME_STAGING="Client A App Staging"
APP_NAME_PROD="Client A App"
BUNDLE_ID="com.company.clientaapp"
# iOS Signing Configuration
DEVELOPMENT_TEAM="ABC123XYZ9"
ASSETS_PATH="clients/clientA/"
APP_ICON_PATH="assets/branding/clientA/logo_small.png"
APP_LOGO_PATH="assets/branding/clientA/logo_large.png"
APP_LOGO_ICON_PATH="assets/branding/clientA/logo_small.png"
PRIMARY_COLOR="0xFF2196F3"
BACKGROUND_COLOR="0XFFFFFFFF"
SECONDARY_COLOR="0xFF4CAF50"
FONT_FAMILY="Manrope"
SHOW_HOME_TEXT=false
SHOW_SIGN_UP=true
ENABLE_LION=false
```

---

## Usage

### Basic Build Command

```bash
udara_cli build --client clientA --platform android
```

### Build Options

- `--client` or `-c`: **Required** - The name of the client to build for (e.g., `default`, `clientA`)
- `--platform` or `-p`: Target platform (`android` or `ios`) - defaults to `android`
- `--type` or `-t`: Android build type (`aab` or `apk`) - defaults to `aab`
- `--test`: Build using the test environment (`.env_test`)
- `--slack`: Send build notifications to Slack
- `--slack-channel`: Specify Slack channel (e.g., `#builds`)

### Global Options

- `--verbose`: print stack traces on failure and Slack debug output
- `--version` or `-v`: print the CLI version

### Examples

```bash
# Build Android AAB for clientA
udara_cli build --client clientA --platform android --type aab

# Build Android APK for clientB
udara_cli build --client clientB --platform android --type apk

# Build iOS for default client
udara_cli build --client default --platform ios

# Build with test environment
udara_cli build --client clientA --platform android --test

# Build with Slack notifications
udara_cli build --client clientA --platform android --slack --slack-channel #builds
```

---

## Build Process

The CLI performs the following steps:

1. **Validation & Setup**: Checks the project files, that the client and its env file exist, and that the required keys are set
2. **Project Configuration**:
   - Backs up `pubspec.yaml`, `flutter_launcher_icons.yaml` and the iOS project file
   - Stages the client env as root `.env`
   - Handles client-specific fonts and copies client assets
   - Applies `DEVELOPMENT_TEAM` for iOS builds
3. **Build Commands**:
   - Runs `flutter pub get`
   - Sets bundle ID and app name
   - Generates launcher icons
   - Creates splash screens
   - Fixes platform-specific issues
4. **Final Build**: Builds the app and renames the artifact to `<client>_v<version>.<apk|aab|ipa>`
5. **Cleanup**: Restores the original project state (always runs, even on failure)
6. **History**: Records the build (success or failure) to `.udara_build_history.json`
7. **Notifications** (if enabled): Sends a build summary to Slack, and uploads the APK for APK builds

### Persistent Whitelabeling (`whitelabel`)

`build` always restores the project afterwards. `whitelabel` applies the same branding steps without building. Native changes (app name, bundle id, launcher icons, splash, iOS team) always persist; the staged project files (root `.env`, `assets/branding/<client>/`, `pubspec.yaml`, `flutter_launcher_icons.yaml`) are restored afterwards unless you pass `--keep`, which leaves the project runnable as that client:

```bash
udara_cli whitelabel --client clientA                # native branding only
udara_cli whitelabel --client clientA --keep         # or --test --keep
flutter run --dart-define=CLIENT_ENV=.env
```

Run `udara_cli clean` to restore the staged files after a `--keep`. Native files rewritten by `whitelabel` stay as they are, so commit or revert them with git as you see fit.

---

## Diagnostics & Utility Commands 🩺

### Validate Your Setup (`doctor`)

Before running a build, you can check your entire project — or a single client — for common issues: missing dependencies, missing `.env` files, missing required keys, icon/logo paths that don't resolve to real files in the client folder (or are still the generated placeholders), malformed `fonts.yaml` configuration or font files it references that don't exist, invalid bundle ids, and leftover state from an interrupted build.

```bash
# Check the whole project (all clients)
udara_cli doctor

# Check a single client
udara_cli doctor --client clientA
```

Each check reports as a pass, warning, or failure. `doctor` exits with a non-zero status code if anything fails, so it's safe to use as a pre-build gate in CI.

### Build History (`history`)

Every `build` run — whether it succeeds or fails — is automatically recorded to a project-local `.udara_build_history.json` file (kept to the most recent 50 entries). Use `history` to review recent builds without digging through terminal scrollback:

```bash
# Show the 10 most recent builds
udara_cli history

# Show the last 25 builds for a specific client
udara_cli history --client clientA --limit 25

# Clear all recorded history
udara_cli history --clear
```

> **Tip:** `udara_cli setup` adds `.udara_build_history.json` to your `.gitignore` — it's local build state, not something you need in version control.

### Compare Clients (`diff`)

If two clients are behaving differently and you're not sure why, `diff` compares their environment files side by side and highlights exactly which keys differ.

```bash
# Compare production .env for two clients
udara_cli diff --client-a clientA --client-b clientB

# Compare .env_test files instead
udara_cli diff --client-a clientA --client-b clientB --test

# Show every key, not just the ones that differ
udara_cli diff --client-a clientA --client-b clientB --all
```

---

## IDE Extensions 🧩

The repo ships two editor integrations that sit on top of the CLI. Both show
every client with its env files, and let you run (`whitelabel` + `flutter
run`) or build any client from a click:

- **VS Code** — `extensions/vscode/` ([README](extensions/vscode/README.md)).
  `npm install && npm run package` produces a `.vsix`; install it with
  `code --install-extension udara-whitelabel-*.vsix`.
- **Android Studio / IntelliJ IDEA** — [Udara Whitelabel on the JetBrains Marketplace](https://plugins.jetbrains.com/plugin/34541-udara-whitelabel);
  source in `extensions/jetbrains/` ([README](extensions/jetbrains/README.md)).

They call `udara_cli list-clients --json` and `udara_cli history --json`, which
are also handy for your own scripts.

## Commands Reference

### Setup Commands

```bash
# Full project setup
udara_cli setup

# Initialize specific clients
udara_cli setup --clients clientA,clientB,clientC

# Configure Slack notifications
udara_cli setup --notify

# Reset all configurations
udara_cli setup --reset
```

### Build Commands

```bash
# Build for a client (project restored afterwards)
udara_cli build --client <name> [options]

# Apply a client's native branding; add --keep to leave it runnable as that client
udara_cli whitelabel --client <name> [--test] [--keep]

# Restore project state (after an interrupted build or a whitelabel) and run flutter clean
udara_cli clean

# List all available clients with app name and bundle id (add --json for scripts)
udara_cli list-clients
udara_cli list-clients --json

# Show help
udara_cli --help
udara_cli build --help
```

### Diagnostics Commands

```bash
# Validate project & client setup
udara_cli doctor
udara_cli doctor --client <name>

# View recent build history
udara_cli history
udara_cli history --client <name> --limit 25
udara_cli history --clear

# Compare env configuration between two clients
udara_cli diff --client-a <name> --client-b <name>
udara_cli diff --client-a <name> --client-b <name> --test
udara_cli diff --client-a <name> --client-b <name> --all
```

---

## Prerequisites

- Flutter SDK installed and configured
- Dart SDK (comes with Flutter)
- Proper project structure as outlined above
- Required dependencies in `pubspec.yaml`:
  - `flutter_dotenv` (required for environment variable management)
  - `flutter_launcher_icons`
  - `splash_master`
  - `rename`

---

## Troubleshooting

### Common Issues

> Run `udara_cli doctor` first — it catches most of the issues below (missing `.env` files, missing keys, broken asset paths, missing dependencies) before you even attempt a build.

1. **Client not found**: Ensure the client directory exists in `clients/` and has the corresponding `.env` file in that directory
2. **Missing assets**: Check that all required asset paths exist and are correctly specified in the environment file
3. **Build failures**: Ensure all Flutter dependencies are properly installed and the project builds normally before using the CLI
4. **Environment variables not loading**: Verify that `flutter_dotenv` is installed and properly initialized in your app's main function
5. **Command not found**: Make sure the pub cache bin directory is in your PATH
6. **Client behaving differently than expected**: Run `udara_cli diff --client-a <name> --client-b <name>` to compare its configuration against a working client

### Getting Help

- Check the [issues page](https://github.com/deecency/udara_cli/issues) for known issues
- Create a new issue with detailed error messages and steps to reproduce
- Run `udara_cli --help` for command documentation

---

## Contributing 🤝

Contributions are welcome! Please feel free to submit a Pull Request.

```bash
dart pub get
dart analyze
dart test          # unit tests for env parsing, pubspec editing, asset sync, cleanup
dart run bin/udara_cli.dart --help
```

---

## License 📄

This project is licensed under the MIT License - see the LICENSE file for details.

---

## Changelog 📝

See [CHANGELOG.md](CHANGELOG.md) for a list of changes in each version.

---

**Made with ❤️ for the Flutter community**