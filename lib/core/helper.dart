import 'package:path/path.dart' as p;
import 'package:udara_cli/scripts.dart';
import 'package:yaml/yaml.dart';

import 'core.dart';

/// A helper class containing methods to perform various tasks related to the
/// build process, such as file manipulation, configuration updates, and cleanup.
///
/// This class encapsulates the logic for preparing the project for a client-specific
/// build, executing build steps, and reverting changes afterward.
class Helper {
  final BuildCommand command;

  Helper(this.command);

  /// Renames the generated build file (APK or AAB) to a more descriptive name.
  ///
  /// @param newFileName The new name for the file, without the extension.
  /// @param type The type of build file, either "apk" or "aab".
  /// @returns A [Future<File>] representing the renamed file.
  /// @throws [BuildException] if the build file is not found or if the rename fails.
  Future<File> renameApk(String newFileName, String type) async {
    File buildFile;

    if (type == 'apk') {
      buildFile = File(
          '${command.projectDir}/build/app/outputs/apk/release/app-release.apk');
    } else if (type == 'aab') {
      buildFile = File(
          '${command.projectDir}/build/app/outputs/bundle/release/app-release.aab');
    } else {
      throw BuildException(
        'Invalid build type: $type. Expected "apk" or "aab".',
        fix: 'Please specify a valid build type.',
      );
    }

    if (!buildFile.existsSync()) {
      throw BuildException(
        'Apk file not found at `${buildFile.path}`.',
        fix: 'Rerun the build script and Ensure the build was successful.',
      );
    }
    try {
      var path = buildFile.path;
      var lastSeparator = path.lastIndexOf(Platform.pathSeparator);
      var newPath = path.substring(0, lastSeparator + 1) + '$newFileName.$type';
      return buildFile.rename(newPath);
    } catch (e) {
      throw BuildException(
        'Failed to rename the build file: $e',
        fix: 'Ensure you have write permissions in the build directory.',
      );
    }
  }

  /// Retrieves the version string from the project's `pubspec.yaml` file.
  ///
  /// @returns A [Future<String>] containing the version (e.g., "1.0.0+1").
  /// @throws [BuildException] if `pubspec.yaml` or the version field is not found.
  Future<String> getVersionFromPubspec() async {
    final pubspecFile = File('${command.projectDir}/pubspec.yaml');

    if (!pubspecFile.existsSync()) {
      throw BuildException(
        'pubspec.yaml not found at `${pubspecFile.path}`.',
        fix:
            'Ensure you are running this command from the Flutter project root.',
      );
    }

    final pubspecContent = await pubspecFile.readAsString();
    final pubspecYaml = loadYaml(pubspecContent);

    final version = pubspecYaml['version'] as String?;
    if (version == null) {
      throw BuildException(
        'Version not found in pubspec.yaml.',
        fix: 'Ensure your pubspec.yaml contains a version field.',
      );
    }

    return version;
  }

  /// Sets up the build environment by copying a client-specific `.env` file
  /// to the project root and parsing its variables.
  ///
  /// @param client The name of the client whose environment should be used.
  /// @param isTest A boolean indicating whether to use the test environment (`.env_test`).
  /// @returns A [Future<Map<String, String>>] of the parsed environment variables.
  /// @throws [BuildException] if the environment file or required keys are missing.
  Future<Map<String, String>> setupEnvironment(
    String client,
    bool isTest,
  ) async {
    final envFileName = isTest ? '.env_test' : '.env';

    final envFile = File('${command.projectDir}/clients/$client/$envFileName');

    if (!envFile.existsSync()) {
      throw BuildException(
        'Environment file not found.',
        fix:
            'Ensure the file exists at `${envFile.path}`. Create [.env] for prod build or [.env_test] for test builds',
      );
    }

    command.rootEnvFile = await envFile.copy('${command.projectDir}/.env');

    print('Copied `${envFile.path}` to project root for the build.');

    final envVars = <String, String>{};

    final lines = await envFile.readAsLines();

    for (final line in lines) {
      if (line.trim().isNotEmpty && !line.startsWith('#')) {
        final parts = line.split('=');

        if (parts.length >= 2) {
          final value = parts.sublist(1).join('=').trim();

          envVars[parts.first.trim()] = value.replaceAll(RegExp(r'^"|"$'), '');
        }
      }
    }

    const requiredKeys = [
      'BUNDLE_ID',
      'APP_NAME_PROD',
      'APP_ICON_PATH',
      'ASSETS_PATH',
    ];

    for (final key in requiredKeys) {
      if (!envVars.containsKey(key) || envVars[key]!.isEmpty) {
        throw BuildException(
          'Required variable `$key` is missing from `${envFile.path}`.',
          fix: 'Please add a value for `$key` in your environment file.',
        );
      }
    }

    return envVars;
  }

  /// Creates a backup of `pubspec.yaml` and modifies the original to include
  /// client-specific asset paths and update app icon configurations.
  ///
  /// @param clientAssetsPath The path to the client's asset directory.
  /// @param appIconPath The path to the client's app icon image.
  Future<void> backupAndModifyPubspec(
    String clientAssetsPath,
    String appIconPath,
  ) async {
    final pubspec = File('${command.projectDir}/pubspec.yaml');

    if (!pubspec.existsSync()) {
      throw BuildException('`pubspec.yaml` not found!');
    }

    command.pubspecBackup =
        await pubspec.copy('${command.projectDir}/pubspec.yaml.bak');

    print('Backed up `pubspec.yaml` to `pubspec.yaml.bak`.');

    var lines = await pubspec.readAsLines();

    final assetsIndex = lines.indexWhere((line) => line.trim() == 'assets:');
    if (assetsIndex == -1) {
      throw BuildException('Could not find `assets:` section in pubspec.yaml');
    }
    final clientAssetDirName = p.basename(clientAssetsPath);
    final newAssetEntry = '    - assets/branding/$clientAssetDirName/';
    const newAssetEntry2 = '    - .env';
    const lineToRemove = '    - clients/default/.env';
    final indexToReplace = lines.indexOf(lineToRemove);

    if (indexToReplace != -1) {
      lines[indexToReplace] = newAssetEntry2;
      print('Replaced asset path: `$lineToRemove` with `$newAssetEntry2`');
    } else {
      print('Asset path to remove not found: `$lineToRemove`');
    }
    if (!lines.any((line) => line.trim() == newAssetEntry.trim())) {
      lines.insert(assetsIndex + 1, newAssetEntry);
      print('Added asset path: `$newAssetEntry`');
    }

    final iconPathRegex = RegExp(r'(\s*image_path:\s*").*(".*)');
    final splashPathRegex = RegExp(r'(\s*image:\s*").*(".*)');

    lines = lines.map((line) {
      if (line.contains('image_path:')) {
        return line.replaceAllMapped(
          iconPathRegex,
          (match) => '${match.group(1)}$appIconPath${match.group(2)}',
        );
      } else if (line.contains('image:')) {
        return line.replaceAllMapped(
          splashPathRegex,
          (match) => '${match.group(1)}$appIconPath${match.group(2)}',
        );
      }
      return line;
    }).toList();

    print('Updated `flutter_launcher_icons` image_path to `$appIconPath`');
    print('Updated `splash_master` image to `$appIconPath`');

    await pubspec.writeAsString(lines.join('\n'));
  }

  /// Copies the client-specific assets (e.g., images, branding files) to the
  /// project's main `assets/branding` directory for the build.
  ///
  /// @param clientAssetsPath The path to the source client asset directory.
  Future<void> copyClientAssets(String clientAssetsPath) async {
    final sourceDir = Directory('${command.projectDir}/$clientAssetsPath');

    if (!sourceDir.existsSync()) {
      throw BuildException(
        'Client assets directory not found at `${sourceDir.path}`',
      );
    }

    final targetParentDir = Directory('${command.projectDir}/assets/branding');

    await targetParentDir.create(recursive: true);

    final targetDir =
        Directory(p.join(targetParentDir.path, p.basename(sourceDir.path)));

    if (targetDir.existsSync()) await targetDir.delete(recursive: true);

    await targetDir.create();

    print(
      'Copying client assets from `${sourceDir.path}` to `${targetDir.path}`',
    );

    await command.copyDirectory(sourceDir, targetDir);

    command.copiedAssetsDir = targetDir;
  }

  /// Manages client-specific fonts by backing up default fonts, copying the
  /// client's fonts, and updating `pubspec.yaml` with the new font configuration.
  ///
  /// @param clientAssetsPath The path to the client's asset directory, which may contain a `fonts` subdirectory.
  Future<void> handleClientFonts(String clientAssetsPath) async {
    final clientFontsDir =
        Directory(p.join(command.projectDir, clientAssetsPath, 'fonts'));

    if (!clientFontsDir.existsSync()) {
      print('📝 No client fonts directory found. Using default fonts.');

      return;
    }

    print('📝 Client fonts directory found. Processing...');

    final targetFontsDir =
        Directory(p.join(command.projectDir, 'assets', 'fonts'));

    if (targetFontsDir.existsSync()) {
      print('  -> Backing up default fonts...');

      final backupDir = Directory('${targetFontsDir.path}.bak');

      if (backupDir.existsSync()) await backupDir.delete(recursive: true);

      command.defaultFontsBackupDir =
          await targetFontsDir.rename(backupDir.path);

      print(
          '  -> Default fonts backed up to `${command.defaultFontsBackupDir!.path}`');
    }

    print('  -> Copying client fonts to `${targetFontsDir.path}`...');

    await targetFontsDir.create();

    await command.copyDirectory(clientFontsDir, targetFontsDir);

    command.clientFontsCopied = true;

    final clientFontsConfig = File(p.join(clientFontsDir.path, 'fonts.yaml'));

    if (clientFontsConfig.existsSync()) {
      print(
          '  -> Found client font configuration. Applying to `pubspec.yaml`...');

      final pubspecFile = File('${command.projectDir}/pubspec.yaml');

      var lines = await pubspecFile.readAsLines();

      final fontsSectionIndex = lines.indexWhere((l) => l.trim() == 'fonts:');

      if (fontsSectionIndex != -1) {
        lines.removeRange(fontsSectionIndex, lines.length);
      }

      final fontConfigContent = await clientFontsConfig.readAsString();

      lines.add('  fonts:');

      for (final line in fontConfigContent.split('\n')) {
        lines.add('    $line');
      }

      await pubspecFile.writeAsString(lines.join('\n'));

      print(
          '  -> Successfully updated `pubspec.yaml` with client font configuration.');
    } else {
      print(
          '  -> No `fonts.yaml` found in client assets. Manual `pubspec.yaml` update may be needed if font families changed.');
    }
  }

  /// Fixes a common bug with Android adaptive icons by removing the problematic
  /// `mipmap-anydpi-v26` directory before icon generation.
  Future<void> fixAndroidIconBug() async {
    final buggyPath = Directory(
        '${command.projectDir}/android/app/src/main/res/mipmap-anydpi-v26');

    if (buggyPath.existsSync()) {
      print('Found and removing problematic Android v26 icon directory.');

      await buggyPath.delete(recursive: true);
    }
  }

  /// Updates iOS-specific splash screen configurations by renaming asset directories
  /// and modifying the `LaunchScreen.storyboard` file.
  ///
  /// @param appName The name of the app, used to create a unique asset name.
  /// @throws [BuildException] if required asset directories or files are not found.
  Future<void> updateIosSplash(String appName) async {
    final assetsDir = Directory(
      p.join(command.projectDir, 'ios', 'Runner', 'Assets.xcassets',
          'LaunchImage.imageset'),
    );
    final newAssetsDir = Directory(
      p.join(command.projectDir, 'ios', 'Runner', 'Assets.xcassets',
          'LaunchImage$appName.imageset'),
    );
    final storyboardFile = File(
      p.join(command.projectDir, 'ios', 'Runner', 'Base.lproj',
          'LaunchScreen.storyboard'),
    );

    if (!await assetsDir.exists()) {
      throw BuildException(
        'Default splash asset directory not found after running splash_master.',
        fix: 'Ensure `dart run splash_master:create` ran successfully.',
      );
    }

    print(
        '🔄 Renaming splash asset directory to ${p.basename(newAssetsDir.path)}...');
    await assetsDir.rename(newAssetsDir.path);
    command.renamedSplashAssetsDir = newAssetsDir;

    if (!await storyboardFile.exists()) {
      throw BuildException(
          'LaunchScreen.storyboard not found at ${storyboardFile.path}.');
    }

    print('✏️ Updating LaunchScreen.storyboard...');
    var storyboardContent = await storyboardFile.readAsString();
    storyboardContent =
        storyboardContent.replaceAll('LaunchImage', 'LaunchImage$appName');
    await storyboardFile.writeAsString(storyboardContent);

    print('🛠️ Fixing duplicate lines in LaunchScreen.storyboard...');
    final lines = await storyboardFile.readAsLines();
    final uniqueLines = <String>{};
    final newLines = <String>[];
    for (final line in lines) {
      if (uniqueLines.add(line)) {
        newLines.add(line);
      }
    }
    await storyboardFile.writeAsString(newLines.join('\n'));
  }

  /// Reverts all changes made during the build process to restore the project
  /// to its original state. This includes restoring backups and deleting temporary files.
  Future<void> cleanup() async {
    if (command.renamedSplashAssetsDir?.existsSync() ?? false) {
      print('🔄 Reverting iOS splash asset directory...');
      final originalPath = p.join(
        command.projectDir,
        'ios',
        'Runner',
        'Assets.xcassets',
        'LaunchImage.imageset',
      );
      await command.renamedSplashAssetsDir!.rename(originalPath);
    }
    if (command.appNameForCleanup != null) {
      final storyboardFile = File(
        p.join(command.projectDir, 'ios', 'Runner', 'Base.lproj',
            'LaunchScreen.storyboard'),
      );
      if (await storyboardFile.exists()) {
        print('✏️ Reverting LaunchScreen.storyboard changes...');
        var content = await storyboardFile.readAsString();
        content = content.replaceAll(
            'LaunchImage${command.appNameForCleanup}', 'LaunchImage');
        await storyboardFile.writeAsString(content);
      }
    }

    if ((command.pubspecBackup?.existsSync() ?? false) &&
        !command.templatesWereAdded) {
      print('Restoring original `pubspec.yaml`...');
      await command.pubspecBackup!.rename('${command.projectDir}/pubspec.yaml');
    }

    if (command.copiedAssetsDir != null &&
        command.copiedAssetsDir!.existsSync()) {
      print('Removing copied client assets...');

      await command.copiedAssetsDir!.delete(recursive: true);
    }

    if (command.rootEnvFile != null && command.rootEnvFile!.existsSync()) {
      print('Removing temporary .env file...');

      await command.rootEnvFile!.delete();
    }

    final targetFontsDir =
        Directory(p.join(command.projectDir, 'assets', 'fonts'));

    if (command.clientFontsCopied && targetFontsDir.existsSync()) {
      print('Removing copied client fonts...');

      await targetFontsDir.delete(recursive: true);
    }

    if (command.defaultFontsBackupDir != null &&
        command.defaultFontsBackupDir!.existsSync()) {
      print('Restoring default fonts...');

      await command.defaultFontsBackupDir!.rename(targetFontsDir.path);
    }

    if (command.iconsGenerated) {
      print(
        'Note: App icons were generated. You may need to manage changes in git.',
      );
    }

    print('✅ Cleanup complete.');
  }

  /// Ensures that all necessary dependencies and configuration files for app icons
  /// and splash screens are present, adding them if they are missing.
  ///
  /// @throws [BuildException] if essential configuration files are generated and require user input.
  Future<void> ensureConfig() async {
    print('🔎 Ensuring all necessary configurations are present...');
    final pubspecFile = File(p.join(command.projectDir, 'pubspec.yaml'));
    if (!await pubspecFile.exists()) {
      throw BuildException('Cannot find pubspec.yaml');
    }

    var pubspecYaml = loadYaml(await pubspecFile.readAsString());
    var lines = await pubspecFile.readAsLines();
    var configModified = false;
    var needsRegeneration = false;

    // Ensure dependencies are present
    pubspecYaml =
        await _ensureDependency('rename', pubspecFile, pubspecYaml, command);
    pubspecYaml = await _ensureDependency(
        'flutter_launcher_icons', pubspecFile, pubspecYaml, command);
    pubspecYaml = await _ensureDependency(
        'splash_master', pubspecFile, pubspecYaml, command);

    // Clean up existing flutter_launcher_icons configuration from pubspec.yaml
    final cleanupResult = await _cleanupOldConfigurations(pubspecFile, lines);
    if (cleanupResult.modified) {
      configModified = true;
      lines = cleanupResult.lines;
      print(
          '🧹 Removed old flutter_launcher_icons configuration from pubspec.yaml');
    }

    // Generate flutter_launcher_icons.yaml if it doesn't exist
    final iconsConfigResult = await _ensureFlutterLauncherIconsConfig();
    if (iconsConfigResult.created) {
      needsRegeneration = true;
      print('📄 Created flutter_launcher_icons.yaml configuration file');
    }

    // Ensure splash_master configuration in pubspec.yaml (since it doesn't have a generator)
    final splashResult =
        await _ensureSplashMasterConfig(pubspecFile, lines, pubspecYaml);
    if (splashResult.modified) {
      configModified = true;
      lines = splashResult.lines;
    }

    // Write changes to pubspec.yaml if modified
    if (configModified) {
      await pubspecFile.writeAsString(lines.join('\n'));
      command.templatesWereAdded = true;
    }

    // If we need regeneration, stop here and ask user to configure
    if (needsRegeneration) {
      throw BuildException(
        'Configuration files have been generated for flutter_launcher_icons.',
        fix: 'Please:\n'
            '1. Open flutter_launcher_icons.yaml and configure your app icon path\n'
            '2. Open pubspec.yaml and configure splash_master settings\n'
            '3. Run the build command again',
      );
    }

    print('✅ All necessary configurations are present.');
  }

  /// Clean up old flutter_launcher_icons configuration from pubspec.yaml
  Future<ConfigCleanupResult> _cleanupOldConfigurations(
      File pubspecFile, List<String> lines) async {
    var modified = false;
    var cleanedLines = <String>[];
    var skipSection = false;
    var inUdaraSection = false;
    var sectionIndentLevel = 0;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmedLine = line.trim();

      // Check if we're entering a flutter_launcher_icons section
      if (trimmedLine.startsWith('flutter_launcher_icons:')) {
        skipSection = true;
        modified = true;
        sectionIndentLevel = _getIndentLevel(line);

        // Check if this is within a Udara CLI section
        if (i > 0 && lines[i - 1].trim().contains('ADDED BY UDARA_CLI')) {
          inUdaraSection = true;
        }

        print(
            '🗑️  Removing flutter_launcher_icons configuration (line ${i + 1})');
        continue;
      }

      // If we're skipping a section, check if we should stop
      if (skipSection) {
        final currentIndent = _getIndentLevel(line);

        // Stop skipping if we've reached a line with equal or lesser indentation
        // (unless it's empty or a comment)
        if (trimmedLine.isNotEmpty &&
            !trimmedLine.startsWith('#') &&
            currentIndent <= sectionIndentLevel) {
          skipSection = false;
          inUdaraSection = false;

          // Don't skip this line, process it normally
          cleanedLines.add(line);
        }
        // Skip lines within the section, including Udara CLI markers
        continue;
      }

      // Remove Udara CLI section markers if they're now empty
      if (inUdaraSection && trimmedLine.contains('ADDED BY UDARA_CLI')) {
        continue;
      }

      cleanedLines.add(line);
    }

    return ConfigCleanupResult(cleanedLines, modified);
  }

  /// Get the indentation level of a line
  int _getIndentLevel(String line) {
    var indent = 0;
    for (var char in line.runes) {
      if (char == 32) {
        // space
        indent++;
      } else if (char == 9) {
        // tab
        indent += 2; // treat tab as 2 spaces
      } else {
        break;
      }
    }
    return indent;
  }

  /// Ensure flutter_launcher_icons.yaml exists with proper configuration
  Future<ConfigCreationResult> _ensureFlutterLauncherIconsConfig() async {
    final configFile =
        File(p.join(command.projectDir, 'flutter_launcher_icons.yaml'));

    if (await configFile.exists()) {
      print('✅ flutter_launcher_icons.yaml already exists');
      return ConfigCreationResult(false);
    }

    final template = '''# Flutter Launcher Icons Configuration
# Generated by Udara CLI
#
# This file configures app icons for your Flutter project.
# For more options, see: https://pub.dev/packages/flutter_launcher_icons

flutter_launcher_icons:
  # IMPORTANT: Update this path to your actual app icon
  image_path: "assets/logo/app_icon.png"

  # Platform-specific settings
  android: true
  ios: true

  # Optional: Custom icon paths for different platforms
  # android_icon_path: "assets/android_icon.png"
  # ios_icon_path: "assets/ios_icon.png"

  # Optional: Adaptive icons for Android (API 26+)
  # adaptive_icon_background: "#FFFFFF"
  # adaptive_icon_foreground: "assets/logo/app_icon_foreground.png"

  # Optional: Custom sizes
  # min_sdk_android: 21

  # Optional: Remove the old launcher icon
  # remove_alpha_ios: true

# Additional configuration options:
# - background_color_ios: Set iOS icon background color
# - theme_color: Set theme color for adaptive icons
# - web: Configure web app icons
# - windows: Configure Windows app icons
# - macos: Configure macOS app icons
# - linux: Configure Linux app icons

# To generate icons after configuration:
# Run: dart run flutter_launcher_icons:generate
''';

    await configFile.writeAsString(template);
    return ConfigCreationResult(true);
  }

  /// Ensure splash_master configuration exists in pubspec.yaml
  Future<SplashConfigResult> _ensureSplashMasterConfig(
      File pubspecFile, List<String> lines, YamlMap pubspecYaml) async {
    // Check if splash_master configuration already exists
    if (pubspecYaml['splash_master'] != null ||
        pubspecYaml['flutter']?['splash_master'] != null) {
      print('✅ splash_master configuration already exists');
      return SplashConfigResult(lines, false);
    }

    print('⚠️ splash_master configuration not found. Adding template...');

    // Find the flutter section
    final flutterIndex = lines.indexWhere((l) => l.trim() == 'flutter:');
    if (flutterIndex == -1) {
      throw BuildException(
          'A `flutter:` section could not be found in your pubspec.yaml.');
    }

    // Find insertion point (after uses-material-design or at flutter section)
    var insertIndex =
        lines.indexWhere((l) => l.trim().startsWith('uses-material-design:'));
    if (insertIndex == -1) insertIndex = flutterIndex;

    final template = '''
# ------------------ ADDED BY UDARA_CLI ------------------
# Splash screen configuration
# For more options, see: https://pub.dev/packages/splash_master
splash_master:
  # IMPORTANT: Update this path to your actual splash screen image
  image: "assets/logo/splash_icon.png"

  # Background color (hex format)
  color: "#FFFFFF"

  # Platform-specific settings
  ios_content_mode: "center"
  android_gravity: "center"

  # Optional: Additional customization
  # android_fullscreen: true
  # ios_hide_status_bar: true
  # web_image_mode: "center"
# ---------------------------------------------------------''';

    // Insert the template
    final templateLines = template.split('\n');
    lines.insertAll(insertIndex + 1, templateLines);

    return SplashConfigResult(lines, true);
  }

  /// Generates app icons by running the `flutter_launcher_icons` package command.
  Future<void> generateFlutterLauncherIcons() async {
    print('🎨 Generating app icons using flutter_launcher_icons...');

    // Use the new generator command
    await command.runShell('dart run flutter_launcher_icons:generate');

    print('✅ App icons generated successfully');
  }
}

/// Checks if a dependency exists in `pubspec.yaml` and adds it as a dev
/// dependency if it's missing.
Future<YamlMap> _ensureDependency(String packageName, File pubspecFile,
    YamlMap pubspecYaml, BuildCommand command) async {
  final devDeps = pubspecYaml['dev_dependencies'] as YamlMap?;
  final regularDeps = pubspecYaml['dependencies'] as YamlMap?;

  if (devDeps?[packageName] == null && regularDeps?[packageName] == null) {
    print('⚠️ `$packageName` dependency not found. Adding it now...');
    await command.runShell('flutter pub add --dev $packageName');

    // Reload the pubspec after adding dependency
    final content = await pubspecFile.readAsString();
    return loadYaml(content) as YamlMap;
  }

  return pubspecYaml;
}

/// A helper class to hold the result of a configuration cleanup operation.
class ConfigCleanupResult {
  final List<String> lines;
  final bool modified;

  ConfigCleanupResult(this.lines, this.modified);
}

/// A helper class to hold the result of a configuration file creation operation.
class ConfigCreationResult {
  final bool created;

  ConfigCreationResult(this.created);
}

/// A helper class to hold the result of updating splash screen configuration.
class SplashConfigResult {
  final List<String> lines;
  final bool modified;

  SplashConfigResult(this.lines, this.modified);
}
