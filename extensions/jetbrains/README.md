# Udara Whitelabel for Android Studio / IntelliJ IDEA

A tool window that lists the whitelabel clients of a Flutter project, shows
their env files, and runs `udara_cli` for you. It is a UI over
[`udara_cli`](https://pub.dev/packages/udara_cli), so results match the
terminal exactly.

## Install

From the JetBrains Marketplace: https://plugins.jetbrains.com/plugin/34541-udara-whitelabel
(or **Settings | Plugins**, search for "Udara Whitelabel").

## Requirements

- Android Studio Ladybug (2024.2) or newer, or IntelliJ IDEA 2024.2+.
- `udara_cli` on your PATH (`dart pub global activate udara_cli`), or set its
  path under **Settings | Tools | Udara Whitelabel**.

## What you get

- **Udara tool window** (right side): a *Clients* tab with one node per
  client (app name, bundle id), expandable to `.env` / `.env_test` and every
  key inside them. Secret-looking values are masked. Double-click a key to
  open the file at that line.
- **Toolbar / right-click actions**: Run Client, Debug Client, Run Client
  with Test Env, Build Client…, Whitelabel Project as Client…, Doctor, Clean,
  Diff Two Clients…, Set Up Clients…. The same actions live under **Tools |
  Udara Whitelabel**, where they prompt for a client.
- **Run Client / Debug Client** create (or update) a normal Flutter run
  configuration for the client, named e.g. `Udara: acme`, and launch it. Its
  *Before launch* step runs `udara_cli whitelabel --client acme --keep`, and it
  passes `--dart-define=CLIENT_ENV=.env`. Everything after that is the Flutter
  plugin's own UI: the device selector, Run / Debug buttons, hot reload and
  hot restart, DevTools and breakpoints. Because the configurations stay in
  the run dropdown, you can also just pick `Udara: acme` there next time.
  Without the Flutter plugin, the app runs in the Run tool window instead
  (type `r`, `R` or `q` and press Enter for reload, restart or quit).
- **Build Client…** opens a dialog for platform, Android build type, an
  optional **app version**, test env and Slack, runs `udara_cli build`, and
  notifies you with a *Reveal Artifact* link. A version like `1.4.0+12` is
  written to `pubspec.yaml` for that build only and restored afterwards (also
  after an IDE restart if the build was interrupted). `1.4.0` without a build
  number keeps the current one.
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

To publish an update to the Marketplace (plugin id 34541), bump `version` in
`build.gradle.kts`, add change notes in `plugin.xml`, then:

```bash
JETBRAINS_MARKETPLACE_TOKEN=<token from plugins.jetbrains.com/author/me/tokens> ./gradlew publishPlugin
```
