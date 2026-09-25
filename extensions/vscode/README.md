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

**Run Client** runs `udara_cli whitelabel --client <name>` as a task, then
starts `flutter run --dart-define=CLIENT_ENV=.env` in an interactive terminal
(hot reload works). A device picker is shown when `flutter devices` reports
more than the default. The status bar shows which client the project is
currently branded as.

**Build Client…** asks for platform, Android build type and environment, runs
`udara_cli build`, and offers to reveal the renamed artifact when it finishes.

**Build History view** lists every recorded build from
`.udara_build_history.json` with pass/fail icons, duration, and a tooltip with
the error message. Reveal the artifact or copy the error inline.

Other commands: **Doctor**, **Clean**, **Diff Two Clients…**, **Set Up
Clients…**, **Clear Build History**, **Install udara_cli**.

## Settings

| Setting | Default | Purpose |
| --- | --- | --- |
| `udara.cliPath` | `udara_cli` | Command used to invoke the CLI |
| `udara.flutterPath` | `flutter` | Command used for `flutter run` |
| `udara.flutterRunArgs` | `[]` | Extra args appended to `flutter run` |
| `udara.defaultBuildType` | `aab` | Pre-selected Android build type |
| `udara.maskSecrets` | `true` | Mask secret-looking env values in the tree |
| `udara.askForDevice` | `true` | Show a device picker before `flutter run` |

## Development

```bash
cd extensions/vscode
npm install
npm run compile      # or: npm run watch
npm run package      # produces udara-whitelabel-<version>.vsix
```

Press `F5` in VS Code with this folder open to launch an Extension
Development Host, then open a Flutter project that has a `clients/` folder.
Install a packaged build with `code --install-extension udara-whitelabel-*.vsix`.
