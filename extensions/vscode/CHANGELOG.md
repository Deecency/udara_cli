# Changelog

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
