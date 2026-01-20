## 1.0.3

* **FEAT**: Added full support for client-specific custom fonts via `fonts.yaml`.
* **FIX**: Fixed "unable to locate asset entry" error by synchronizing `pubspec.yaml` font declarations with physical file moves during the build process.
* **IMPROVE**: Enhanced `CleanupService` to ensure project restoration even if a build fails.