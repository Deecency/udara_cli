# Udara CLI

[![pub package](https://img.shields.io/pub/v/udara_cli.svg)](https://pub.dev/packages/udara_cli)

A powerful CLI tool for managing whitelabel Flutter projects with multi-client support. Build and maintain multiple branded versions of your Flutter app from a single codebase.

---

## Features ✨

- 🏢 **Multi-client support** - Manage unlimited white-label variants
- 🎨 **Asset management** - Client-specific icons, logos, and fonts
- ⚙️ **Environment-based configuration** - Separate configs for dev, staging, and production
- 🚀 **Automated builds** - One command to build for any client
- 📱 **Slack notifications** - Get build status updates in Slack
- 🔧 **Easy setup** - Guided project initialization

---

## Installation 📦

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

## Getting Started 🎯

After installing the CLI, you need to initialize your project. The CLI provides a guided setup process:

### 1. Initial Project Setup

Run the setup command to configure your project dependencies and create necessary configuration files:

```bash
udara_cli setup
```

This will:
- Install required dependencies (`rename`, `flutter_launcher_icons`, `splash_master`)
- Create `flutter_launcher_icons.yaml` configuration file
- Add `splash_master` configuration to your `pubspec.yaml`
- Set up the basic project structure

### 2. Initialize Client Directories

Create your client directories with pre-configured templates:

```bash
# Create one or more clients (comma-separated)
udara_cli setup --clients default,clientA,clientB
```

This will create the complete directory structure for each client, including:
- Client folder in `clients/[name]/`
- Environment files (`.env` and `.env_test`)
- Placeholder logo files
- Fonts directory
- Client-specific README

**Note**: Always include a `default` client as a fallback configuration.

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

## Project Structure 📁

Your Flutter project must follow this structure for the CLI to work properly:

```
your_flutter_project/
├── clients/
│   ├── default/
│   │   ├── assets/
│   │   ├── fonts/ (optional)
│   │   └── .env
│   │
│   ├── clientA/
│   │   ├── assets/
│   │   ├── fonts/ (optional)
│   │   ├── .env
│   │   └── .env_test
│   └── clientB/
│       ├── assets/
│       ├── fonts/ (optional)
│       ├── .env
│       └── .env_test
├── assets/
│   └── branding/
│       ├── default/
│       │   ├── logo_small.png
│       │   └── logo_large.png
│       ├── clientA/
│       │   ├── logo_small.png
│       │   └── logo_large.png
│       └── clientB/
│           ├── logo_small.png
│           └── logo_large.png
└── pubspec.yaml
```

---

## Environment Configuration 🔧

### Important: flutter_dotenv Dependency

**This tool is heavily dependent on environment files and requires the `flutter_dotenv` package.** Make sure to add it to your `pubspec.yaml`:

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
   - Loads the client-specific `.env` file from `clients/[client_name]/.env`
   - Copies client-specific assets (icons, logos, fonts) to the appropriate locations
   - Updates the app's bundle ID, app name, and other build configurations
   - Passes the environment file path to Flutter via the `CLIENT_ENV` compile-time constant

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


> 💡 **Note:** If `DEVELOPMENT_TEAM` is omitted from the client's environment file, `udara_cli` will leave your Xcode project's existing signing configuration untouched.

### Required Environment Variables

Each client must have corresponding environment files in their respective `clients/client_name/` directory with the following structure:

```env
# App Names for Different Environments
APP_NAME_DEV="Your App Dev"
APP_NAME_STAGING="Your App Staging"
APP_NAME_PROD="Your App"

# Bundle/Package Identifier
BUNDLE_ID="com.yourcompany.yourapp"

# Asset Paths (relative to project root)
ASSETS_PATH="clients/default/"
APP_ICON_PATH="assets/branding/default/logo_small.png"
APP_LOGO_PATH="assets/branding/default/logo_large.png"
APP_LOGO_ICON_PATH="assets/branding/default/logo_small.png"
```

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

The CLI supports client-specific custom fonts. Here's how to set them up:

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

## Usage 🚀

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

## Build Process 🔄

The CLI performs the following steps:

1. **Validation & Setup**: Validates client exists and loads environment variables
2. **Project Configuration**:
   - Backs up and modifies `pubspec.yaml`
   - Handles client-specific fonts
   - Copies client assets
3. **Build Commands**:
   - Runs `flutter pub get`
   - Sets bundle ID and app name
   - Generates launcher icons
   - Creates splash screens
   - Fixes platform-specific issues
4. **Final Build**: Builds the app with client-specific configuration
5. **Cleanup**: Restores original project state
6. **Notifications** (if enabled): Sends build status to Slack

---

## Commands Reference 📚

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
# Build for a client
udara_cli build --client <name> [options]

# List all available clients
udara_cli list-clients

# Show help
udara_cli --help
udara_cli build --help
```

---

## Prerequisites 📋

- Flutter SDK installed and configured
- Dart SDK (comes with Flutter)
- Proper project structure as outlined above
- Required dependencies in `pubspec.yaml`:
  - `flutter_dotenv` (required for environment variable management)
  - `flutter_launcher_icons`
  - `splash_master`
  - `rename`

---

## Troubleshooting 🔧

### Common Issues

1. **Client not found**: Ensure the client directory exists in `clients/` and has the corresponding `.env` file in that directory
2. **Missing assets**: Check that all required asset paths exist and are correctly specified in the environment file
3. **Build failures**: Ensure all Flutter dependencies are properly installed and the project builds normally before using the CLI
4. **Environment variables not loading**: Verify that `flutter_dotenv` is installed and properly initialized in your app's main function
5. **Command not found**: Make sure the pub cache bin directory is in your PATH

### Getting Help

- Check the [issues page](https://github.com/deecency/udara_cli/issues) for known issues
- Create a new issue with detailed error messages and steps to reproduce
- Run `udara_cli --help` for command documentation

---

## Contributing 🤝

Contributions are welcome! Please feel free to submit a Pull Request.

---

## License 📄

This project is licensed under the MIT License - see the LICENSE file for details.

---

## Changelog 📝

See [CHANGELOG.md](CHANGELOG.md) for a list of changes in each version.

---

**Made with ❤️ for the Flutter community**


