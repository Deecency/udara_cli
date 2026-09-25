# Udara Whitelabel for Android Studio / IntelliJ IDEA

A tool window that lists the whitelabel clients of a Flutter project, shows
their env files, and runs `udara_cli` for you. It is a UI over
[`udara_cli`](https://pub.dev/packages/udara_cli), so results match the
terminal exactly.

## Requirements

- Android Studio Ladybug (2024.2) or newer, or IntelliJ IDEA 2024.2+.
- `udara_cli` on your PATH (`dart pub global activate udara_cli`), or set its
  path under **Settings | Tools | Udara Whitelabel**.

## What you get

- **Udara tool window** (right side): a *Clients* tab with one node per
  client (app name, bundle id), expandable to `.env` / `.env_test` and every
  key inside them. Secret-looking values are masked. Double-click a key to
  open the file at that line.
- **Toolbar / right-click actions**: Run Client, Run Client with Test Env,
  Build Client…, Whitelabel Project as Client…, Doctor, Clean, Diff Two
  Clients…, Set Up Clients…. The same actions live under **Tools | Udara
  Whitelabel**, where they prompt for a client.
- **Run Client** runs `udara_cli whitelabel --client <name>` in the Run tool
  window, then opens a Terminal tab running
  `flutter run --dart-define=CLIENT_ENV=.env` (with a device picker from
  `flutter devices`) so hot reload works.
- **Build Client…** opens a dialog for platform, Android build type, test env
  and Slack, runs `udara_cli build`, and notifies you with a *Reveal Artifact*
  link.
- **History tab**: every recorded build from `.udara_build_history.json`.
  Double-click a row to reveal the artifact or see the error.

## Building the plugin

```bash
cd extensions/jetbrains
./gradlew buildPlugin        # build/distributions/udara-jetbrains-<version>.zip
./gradlew runIde             # launch a sandbox IDE with the plugin installed
```

Install the zip in Android Studio via **Settings | Plugins | ⚙ | Install
Plugin from Disk…**.
