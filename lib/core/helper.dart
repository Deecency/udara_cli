import 'package:path/path.dart' as p;
import 'package:udara_cli/scripts.dart';
import 'package:yaml/yaml.dart';

import 'core.dart';

class Helper {
  final BuildCommand command;

  Helper(this.command);

  Future<Future<File>> renameApk(String newFileName, String type) async {
    File buildFile;

    if (type == 'apk') {
      buildFile = File('${command.projectDir}/build/app/outputs/apk/release/app-release.apk');
    }
    if (type == 'aab') {
      buildFile = File('${command.projectDir}/build/app/outputs/bundle/release/app-release.aab');
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
    var path = buildFile.path;
    var lastSeparator = path.lastIndexOf(Platform.pathSeparator);
    var newPath = path.substring(0, lastSeparator + 1) + '$newFileName.$type';
    return buildFile.rename(newPath);
  }

  Future<String> getVersionFromPubspec() async {
    final pubspecFile = File('${command.projectDir}/pubspec.yaml');

    if (!pubspecFile.existsSync()) {
      throw BuildException(
        'pubspec.yaml not found at `${pubspecFile.path}`.',
        fix: 'Ensure you are running this command from the Flutter project root.',
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

  Future<void> backupAndModifyPubspec(
    String clientAssetsPath,
    String appIconPath,
  ) async {
    final pubspec = File('${command.projectDir}/pubspec.yaml');

    if (!pubspec.existsSync()) {
      throw BuildException('`pubspec.yaml` not found!');
    }

    command.pubspecBackup = await pubspec.copy('${command.projectDir}/pubspec.yaml.bak');

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

  Future<void> copyClientAssets(String clientAssetsPath) async {
    final sourceDir = Directory('${command.projectDir}/$clientAssetsPath');

    if (!sourceDir.existsSync()) {
      throw BuildException(
        'Client assets directory not found at `${sourceDir.path}`',
      );
    }

    final targetParentDir = Directory('${command.projectDir}/assets/branding');

    await targetParentDir.create(recursive: true);

    final targetDir = Directory(p.join(targetParentDir.path, p.basename(sourceDir.path)));

    if (targetDir.existsSync()) await targetDir.delete(recursive: true);

    await targetDir.create();

    print(
      'Copying client assets from `${sourceDir.path}` to `${targetDir.path}`',
    );

    await command.copyDirectory(sourceDir, targetDir);

    command.copiedAssetsDir = targetDir;
  }

  Future<void> handleClientFonts(String clientAssetsPath) async {
    final clientFontsDir = Directory(p.join(command.projectDir, clientAssetsPath, 'fonts'));

    if (!clientFontsDir.existsSync()) {
      print('📝 No client fonts directory found. Using default fonts.');

      return;
    }

    print('📝 Client fonts directory found. Processing...');

    final targetFontsDir = Directory(p.join(command.projectDir, 'assets', 'fonts'));

    if (targetFontsDir.existsSync()) {
      print('  -> Backing up default fonts...');

      final backupDir = Directory('${targetFontsDir.path}.bak');

      if (backupDir.existsSync()) await backupDir.delete(recursive: true);

      command.defaultFontsBackupDir = await targetFontsDir.rename(backupDir.path);

      print('  -> Default fonts backed up to `${command.defaultFontsBackupDir!.path}`');
    }

    print('  -> Copying client fonts to `${targetFontsDir.path}`...');

    await targetFontsDir.create();

    await command.copyDirectory(clientFontsDir, targetFontsDir);

    command.clientFontsCopied = true;

    final clientFontsConfig = File(p.join(clientFontsDir.path, 'fonts.yaml'));

    if (clientFontsConfig.existsSync()) {
      print('  -> Found client font configuration. Applying to `pubspec.yaml`...');

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

      print('  -> Successfully updated `pubspec.yaml` with client font configuration.');
    } else {
      print(
          '  -> No `fonts.yaml` found in client assets. Manual `pubspec.yaml` update may be needed if font families changed.');
    }
  }

  Future<void> fixAndroidIconBug() async {
    final buggyPath = Directory('${command.projectDir}/android/app/src/main/res/mipmap-anydpi-v26');

    if (buggyPath.existsSync()) {
      print('Found and removing problematic Android v26 icon directory.');

      await buggyPath.delete(recursive: true);
    }
  }

  Future<void> updateIosSplash(String appName) async {
    final assetsDir = Directory(
      p.join(command.projectDir, 'ios', 'Runner', 'Assets.xcassets', 'LaunchImage.imageset'),
    );
    final newAssetsDir = Directory(
      p.join(
          command.projectDir, 'ios', 'Runner', 'Assets.xcassets', 'LaunchImage$appName.imageset'),
    );
    final storyboardFile = File(
      p.join(command.projectDir, 'ios', 'Runner', 'Base.lproj', 'LaunchScreen.storyboard'),
    );

    if (!await assetsDir.exists()) {
      throw BuildException('Default splash asset directory not found after running splash_master.',
          fix: 'Ensure `dart run splash_master:create` ran successfully.');
    }

    print('🔄 Renaming splash asset directory to ${p.basename(newAssetsDir.path)}...');
    await assetsDir.rename(newAssetsDir.path);
    command.renamedSplashAssetsDir = newAssetsDir;

    if (!await storyboardFile.exists()) {
      throw BuildException('LaunchScreen.storyboard not found at ${storyboardFile.path}.');
    }

    print('✏️ Updating LaunchScreen.storyboard...');
    var storyboardContent = await storyboardFile.readAsString();
    storyboardContent = storyboardContent.replaceAll('LaunchImage', 'LaunchImage$appName');
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
        p.join(command.projectDir, 'ios', 'Runner', 'Base.lproj', 'LaunchScreen.storyboard'),
      );
      if (await storyboardFile.exists()) {
        print('✏️ Reverting LaunchScreen.storyboard changes...');
        var content = await storyboardFile.readAsString();
        content = content.replaceAll('LaunchImage${command.appNameForCleanup}', 'LaunchImage');
        await storyboardFile.writeAsString(content);
      }
    }

    if ((command.pubspecBackup?.existsSync() ?? false) && !command.templatesWereAdded) {
      print('Restoring original `pubspec.yaml`...');
      await command.pubspecBackup!.rename('${command.projectDir}/pubspec.yaml');
    }

    if (command.copiedAssetsDir != null && command.copiedAssetsDir!.existsSync()) {
      print('Removing copied client assets...');

      await command.copiedAssetsDir!.delete(recursive: true);
    }

    if (command.rootEnvFile != null && command.rootEnvFile!.existsSync()) {
      print('Removing temporary .env file...');

      await command.rootEnvFile!.delete();
    }

    final targetFontsDir = Directory(p.join(command.projectDir, 'assets', 'fonts'));

    if (command.clientFontsCopied && targetFontsDir.existsSync()) {
      print('Removing copied client fonts...');

      await targetFontsDir.delete(recursive: true);
    }

    if (command.defaultFontsBackupDir != null && command.defaultFontsBackupDir!.existsSync()) {
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

  Future<void> ensureConfig() async {
    print('🔎 Ensuring all necessary configurations are present...');
    final pubspecFile = File(p.join(command.projectDir, 'pubspec.yaml'));
    if (!await pubspecFile.exists()) {
      throw BuildException('Cannot find pubspec.yaml');
    }

    var pubspecYaml = loadYaml(await pubspecFile.readAsString());
    var lines = await pubspecFile.readAsLines();
    var configAdded = false;

    pubspecYaml = await _ensureDependency('rename', pubspecFile, pubspecYaml);
    pubspecYaml = await _ensureDependency('flutter_launcher_icons', pubspecFile, pubspecYaml);
    pubspecYaml = await _ensureDependency('splash_master', pubspecFile, pubspecYaml);

    final flutterIndex = lines.indexWhere((l) => l.trim() == 'flutter:');
    if (flutterIndex == -1) {
      throw BuildException('A `flutter:` section could not be found in your pubspec.yaml.');
    }

    var insertIndex = lines.indexWhere((l) => l.trim().startsWith('uses-material-design:'));
    if (insertIndex == -1) insertIndex = flutterIndex;

    if (pubspecYaml['flutter_launcher_icons'] == null &&
        pubspecYaml['flutter']?['flutter_launcher_icons'] == null) {
      print('⚠️ `flutter_launcher_icons` configuration not found. Adding a template...');
      configAdded = true;
      final template = _dedent('''
        # ------------------ ADDED BY UDARA_CLI ------------------
        # TODO: Please fill in the image_path for your app icon.
        flutter_launcher_icons:
          image_path: "assets/logo/app_icon.png" # <-- IMPORTANT: CHANGE THIS PATH DEFAULT LAUNCHER ICON IMAGE
          android: true
          ios: true
        # ---------------------------------------------------------
        ''');
      lines.insert(insertIndex + 1, template);
    }

    if (pubspecYaml['splash_master'] == null && pubspecYaml['flutter']?['splash_master'] == null) {
      print('⚠️ `splash_master` configuration not found. Adding a template...');
      configAdded = true;
      final template = _dedent('''
        # ------------------ ADDED BY UDARA_CLI ------------------
        # TODO: Please fill in the image path for your splash screen.
        splash_master:
          color: "#FFFFFF"
          image: "assets/logo/splash_icon.png" # <-- IMPORTANT: CHANGE THIS PATH TO DEFAULT APP SPLASH IMAGE
          ios_content_mode: "center"
          android_gravity: "center"
        # ---------------------------------------------------------
        ''');
      lines.insert(insertIndex + 1, template);
    }

    if (configAdded) {
      final finalContent = lines.join('\n').replaceAllMapped(
            RegExp(r'(# --- ADDED BY UDARA_CLI ---[\s\S]*?# ---+)', multiLine: true),
            (match) => match.group(0)!.replaceAllMapped(
                RegExp(r'^.', multiLine: true), (lineMatch) => '  ${lineMatch.group(0)}'),
          );

      await pubspecFile.writeAsString(finalContent);
      command.templatesWereAdded = true;
      throw BuildException(
        'Configuration templates have been added to your pubspec.yaml.',
        fix: 'Please open pubspec.yaml, fill in the required values, and run the build again.',
      );
    }

    print('✅ All necessary configurations are present.');
  }

  Future<YamlMap> _ensureDependency(
      String packageName, File pubspecFile, YamlMap pubspecYaml) async {
    final devDeps = pubspecYaml['dev_dependencies'] as YamlMap?;
    final regularDeps = pubspecYaml['dependencies'] as YamlMap?;

    if (devDeps?[packageName] == null && regularDeps?[packageName] == null) {
      print('⚠️ `$packageName` dependency not found. Adding it now...');

      await command.runShell('flutter pub add --dev $packageName');

      final content = await pubspecFile.readAsString();
      return loadYaml(content) as YamlMap;
    }

    return pubspecYaml;
  }
}

/// Removes common leading whitespace from a multi-line string.
String _dedent(String text) {
  var lines = text.split('\n');
  if (lines.isEmpty) return '';

  if (lines.first.trim().isEmpty) {
    lines.removeAt(0);
  }

  var indent = -1;
  for (final line in lines) {
    if (line.trim().isNotEmpty) {
      final currentIndent = line.indexOf(RegExp(r'[^ ]'));
      if (indent == -1 || currentIndent < indent) {
        indent = currentIndent;
      }
    }
  }

  if (indent <= 0) return text;

  return lines.map((line) {
    if (line.length > indent) {
      return line.substring(indent);
    }
    return line;
  }).join('\n');
}
