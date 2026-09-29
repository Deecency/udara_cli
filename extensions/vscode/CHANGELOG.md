# Changelog

## 0.3.0

- Projects using udara_cli's generated app config (1.3.1+): Run Client no
  longer passes `--dart-define=CLIENT_ENV=.env`, since the config is compiled
  in. Projects that still bundle `.env` keep the flag.
- Regenerate App Config (Clients view `…` menu and Command Palette):
  refreshes the generated config class after you add or remove `.env` keys
  (`udara_cli generate-config`). Shown for projects in generated mode.

## 0.2.0

Requires udara_cli 1.3.1 or newer (the extension tells you if it's older).

- Build Multiple Clients…: pick several clients, Android and/or iOS, AAB
  and/or APK, and build them in one batch, **in parallel** (Auto, or 1-4 at a
  time). Each client can get its **own app version**, or all share one.
- Live progress for every build: a notification and status bar item with
  percent, ETA and what each running job is doing. Cancel from the
  notification to stop the build and every worker it started.
- Build Client… passes the optional version to the CLI instead of editing
  pubspec.yaml.

## 0.1.1

- Run Client launches through the Flutter extension (Dart-Code) as a normal
  debug session: standard debug toolbar, hot reload on save, breakpoints and
  DevTools. New `udara.launchMode` setting (`native` / `terminal`).
- Build Client… takes an optional app version (e.g. `1.4.0` or `1.4.0+12`),
  applied to pubspec.yaml for that build only and restored afterwards.

## 0.1.0

- Clients view with env file browsing, masked secrets, and jump-to-key.
- Run Client (whitelabel + `flutter run` with device picker), Build Client…,
  Whitelabel, Doctor, Clean, Diff, Set Up Clients….
- Build History view backed by `.udara_build_history.json`.
- Status bar indicator for the currently whitelabeled client.
