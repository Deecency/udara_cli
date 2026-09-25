# Udara Whitelabel for VS Code

Browse the whitelabel clients of a Flutter project, inspect their env files,
and run or build any client without leaving the editor. The extension is a
thin UI over [`udara_cli`](https://pub.dev/packages/udara_cli); every action
runs the CLI so results match what you get in a terminal.

## Install

From the Marketplace: https://marketplace.visualstudio.com/items?itemName=deecency.udara-whitelabel
(or search "Udara Whitelabel" in the Extensions view).

## Requirements

- `udara_cli` on your PATH (`dart pub global activate udara_cli`), or set
  `udara.cliPath`.
- A Flutter project with a `clients/` folder (run `udara_cli setup --clients …`
  or use **Udara: Set Up Clients…** from the view).

## Features

**Clients view** (activity bar → Udara)
- One node per client showing its app name and bundle id.
- Expand a client to see `.env` / `.env_test`; expand a file to see every key.
  Secret-looking values (`TOKEN`, `SECRET`, `PASSWORD`, `KEY`) are masked;
  use **Copy Value** to grab them. Click a key to jump to its line.
- Inline actions on a client: **Run** and **Build**. Right-click for
  **Run with Test Env**, **Whitelabel**, and **Doctor**.

**Run Client** runs `udara_cli whitelabel --client <name> --keep` as a task,
then starts a normal Flutter debug session through the Flutter extension
(Dart-Code) with `--dart-define=CLIENT_ENV=.env`. You get the usual debug
toolbar, hot reload on save, breakpoints and DevTools, on the device chosen in
the Flutter device selector. Without the Flutter extension, or with
`udara.launchMode` set to `terminal`, it runs `flutter run` in a terminal
instead. The status bar shows which client the project is currently branded
as.

**Build Client…** asks for platform, Android build type, environment and an
optional **app version**, runs `udara_cli build`, and offers to reveal the
renamed artifact when it finishes. A version like `1.4.0+12` is written to
`pubspec.yaml` for that build only and restored afterwards (also on the next
start if VS Code was closed mid-build). `1.4.0` without a build number keeps
the current one.

**Build History view** lists every recorded build from
`.udara_build_history.json` with pass/fail icons, duration, and a tooltip with
the error message. Reveal the artifact or copy the error inline.

Other commands: **Doctor**, **Clean**, **Diff Two Clients…**, **Set Up
Clients…**, **Clear Build History**, **Install udara_cli**.

## Settings

| Setting | Default | Purpose |
| --- | --- | --- |
| `udara.cliPath` | `udara_cli` | Command used to invoke the CLI |
| `udara.launchMode` | `native` | `native`: launch via the Flutter extension; `terminal`: `flutter run` in a terminal |
| `udara.flutterPath` | `flutter` | Command used for `flutter run` in terminal mode |
| `udara.flutterRunArgs` | `[]` | Extra args appended to `flutter run` |
| `udara.defaultBuildType` | `aab` | Pre-selected Android build type |
| `udara.maskSecrets` | `true` | Mask secret-looking env values in the tree |
| `udara.askForDevice` | `true` | Terminal mode only: show a device picker before `flutter run` |

## Development

```bash
cd extensions/vscode
npm install
npm run compile      # or: npm run watch
npm test             # unit tests for the pubspec version helper
npm run package      # produces udara-whitelabel-<version>.vsix
```

Press `F5` in VS Code with this folder open to launch an Extension
Development Host, then open a Flutter project that has a `clients/` folder.
Install a packaged build with `code --install-extension udara-whitelabel-*.vsix`.
