# Udara CLI (Private)

A self-contained tool to manage and build Flutter projects for different clients with whitelabel support.

---

## Installation 📦

This is a private repository. To install the CLI, you must have access to this repository and authenticate using SSH (recommended) or a Personal Access Token.

### Using SSH (Recommended)

Make sure you have [added your SSH key to your GitHub account](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account).

```bash
dart pub global activate --source git git@github.com:your-username/udara_cli.git
```

### Using a Personal Access Token (PAT)

[Generate a PAT](https://github.com/settings/tokens/new) with the `repo` scope.

```bash
dart pub global activate --source git https://<YOUR_TOKEN>@github.com/your-username/udara_cli.git
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
│       └── default/
│           ├── default_icon.png
│           ├── default_logo.png
│           └── default_icon_small.png
└── pubspec.yaml
```

---

## Environment Configuration 🔧

Each client must have corresponding environment files in their respective `clients/client_name/` directory with the following structure:

### Required Environment Variables

```env
# App Names for Different Environments
APP_NAME_DEV="Your App Dev"
APP_NAME_STAGING="Your App Staging"
APP_NAME_PROD="Your App"

# Bundle/Package Identifier
BUNDLE_ID="com.yourcompany.yourapp"

# Asset Paths (relative to project root)
ASSETS_PATH="clients/default/"
APP_ICON_PATH="assets/branding/default/default_icon.png"
APP_LOGO_PATH="assets/branding/default/default_logo.png"
APP_LOGO_ICON_PATH="assets/branding/default/default_icon_small.png"
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
```

### Example Environment Files

**`clients/default/.env_default`:**
```env
APP_NAME_DEV="Default App Dev"
APP_NAME_STAGING="Default App Staging"
APP_NAME_PROD="Default App"
BUNDLE_ID="com.company.defaultapp"
ASSETS_PATH="clients/default/"
APP_ICON_PATH="assets/branding/default/default_icon.png"
APP_LOGO_PATH="assets/branding/default/default_logo.png"
APP_LOGO_ICON_PATH="assets/branding/default/default_icon_small.png"
PRIMARY_COLOR="0xFFF26333"
BACKGROUND_COLOR="0XFFF9F9F9"
SECONDARY_COLOR="0xFF81BF42"
SHOW_HOME_TEXT=true
SHOW_SIGN_UP=true
ENABLE_LION=true
```

**`clients/clientA/.env_clientA`:**
```env
APP_NAME_DEV="Client A App Dev"
APP_NAME_STAGING="Client A App Staging"
APP_NAME_PROD="Client A App"
BUNDLE_ID="com.company.clientaapp"
ASSETS_PATH="clients/clientA/"
APP_ICON_PATH="assets/branding/clientA/clientA_icon.png"
APP_LOGO_PATH="assets/branding/clientA/clientA_logo.png"
APP_LOGO_ICON_PATH="assets/branding/clientA/clientA_icon_small.png"
PRIMARY_COLOR="0xFF2196F3"
BACKGROUND_COLOR="0XFFFFFFFF"
SECONDARY_COLOR="0xFF4CAF50"
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

- `--client` or `-c`: **Required** - The name of the client to build for (e.g., `udara`, `clientA`)
- `--platform` or `-p`: Target platform (`android` or `ios`) - defaults to `android`
- `--type` or `-t`: Android build type (`aab` or `apk`) - defaults to `aab`
- `--test`: Build using the test environment (`.env_test`)

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

---

## Prerequisites 📋

- Flutter SDK installed and configured
- Dart SDK (comes with Flutter)
- Access to this private repository
- Proper project structure as outlined above
- Required dependencies in `pubspec.yaml`:
  - `flutter_launcher_icons`
  - `splash_master`
  - `rename`

---

## Troubleshooting 🔧

### Common Issues

1. **Client not found**: Ensure the client directory exists in `clients/` and has the corresponding `.env_clientname` file in that directory
2. **Missing assets**: Check that all required asset paths exist and are correctly specified in the environment file
3. **Build failures**: Ensure all Flutter dependencies are properly installed and the project builds normally before using the CLI

### Getting Help

For issues specific to this CLI tool, please check the repository issues or contact the development team.
