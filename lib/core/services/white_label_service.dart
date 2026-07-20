import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import '../core.dart';

class WhiteLabelService {
  final String projectDir;
  final ConfigService config;

  WhiteLabelService({
    required this.projectDir,
    required this.config,
  });

  // --------------------------------------------------------------------------
  // ASSET MANAGEMENT
  // --------------------------------------------------------------------------

  /// Moves client-specific branding images into the active assets folder.
  Future<void> syncBrandingAssets(String clientName, String sourcePath) async {
    await _ensureUdaraIgnoreFile();
    final sourceDir = Directory(p.join(projectDir, sourcePath));

    if (!sourceDir.existsSync()) {
      throw BuildException(
        'Source assets directory not found at "${sourceDir.path}"',
        fix:
            'Verify $clientName environment variables (ASSETS_PATH) and check if the directory exists.',
      );
    }

    final targetDir =
        Directory(p.join(projectDir, 'assets', 'branding', clientName));

    try {
      if (targetDir.existsSync()) {
        await targetDir.delete(recursive: true);
      }
      await targetDir.create(recursive: true);

      Logger.info(
          'Syncing assets: ${p.basename(sourcePath)} ➔ ${targetDir.path}');
      await _copyDirectory(sourceDir, targetDir);
    } catch (e, s) {
      if (e is BuildException) rethrow;
      throw BuildException(
        'Failed to sync branding assets for client "$clientName"',
        fix:
            'Ensure the source directory "${sourceDir.path}" is accessible and has read permissions.',
        originalStackTrace: s,
      );
    }
  }

  // --------------------------------------------------------------------------
  // FONT MANAGEMENT
  // --------------------------------------------------------------------------

  /// Swaps system fonts for client fonts and updates pubspec configuration.
  Future<void> applyClientFonts(String clientAssetsPath) async {
    final clientFontsDir =
        Directory(p.join(projectDir, clientAssetsPath, 'fonts'));
    final targetFontsDir = Directory(p.join(projectDir, 'assets', 'fonts'));

    if (!clientFontsDir.existsSync()) {
      Logger.info('No custom fonts found for this client. Skipping.');
      return;
    }

    final backupDir = Directory('${targetFontsDir.path}.bak');
    if (targetFontsDir.existsSync() && !backupDir.existsSync()) {
      await targetFontsDir.rename(backupDir.path);
    }

    await targetFontsDir.create(recursive: true);
    await _copyDirectory(clientFontsDir, targetFontsDir);

    final fontsConfigFile = File(p.join(clientFontsDir.path, 'fonts.yaml'));
    if (fontsConfigFile.existsSync()) {
      Logger.info('Applying client font configuration to pubspec...');

      try {
        final fontsContent = await fontsConfigFile.readAsString();
        final fontsList = loadYaml(fontsContent);

        if (fontsList is YamlList || fontsList is List) {
          await config.updatePubspecFonts(fontsList);
          Logger.success('Client font configuration applied to pubspec.yaml');
        } else {
          throw BuildException(
            'Invalid format in fonts.yaml: must be a YAML list of font configurations.',
            fix:
                'Check "${fontsConfigFile.path}" and ensure it is structured as a YAML list.',
          );
        }
      } on BuildException {
        rethrow;
      } catch (e, s) {
        throw BuildException(
          'Failed to parse or apply font configuration from "${fontsConfigFile.path}"',
          fix: 'Check fonts.yaml syntax for formatting errors.',
          originalStackTrace: s,
        );
      }
    }
  }

  // --------------------------------------------------------------------------
  // PLATFORM SPECIFIC (IOS/ANDROID)
  // --------------------------------------------------------------------------

  /*   Future<void> patchIosSplash(String appName) async {
    final storyboardFile = File(
      p.join(
          projectDir, 'ios', 'Runner', 'Base.lproj', 'LaunchScreen.storyboard'),
    );

    if (!storyboardFile.existsSync()) return;

    Logger.info('Patching iOS LaunchScreen for $appName...');
    try {
      var content = await storyboardFile.readAsString();

      content = content.replaceAll('LaunchImage', 'LaunchImage$appName');

      // De-duplicate lines (common issue with splash_master)
      final lines = content.split('\n');
      final uniqueContent = lines.toSet().toList().join('\n');

      await storyboardFile.writeAsString(uniqueContent);
    } catch (e, s) {
      throw BuildException(
        'Failed to patch iOS LaunchScreen storyboard.',
        fix: 'Check write permissions for "${storyboardFile.path}".',
        originalStackTrace: s,
      );
    }
  } */

  /// Fixes a specific Android adaptive icon bug.
  Future<void> cleanAndroidIconCache() async {
    final buggyDir = Directory(
      p.join(projectDir, 'android', 'app', 'src', 'main', 'res',
          'mipmap-anydpi-v26'),
    );

    if (buggyDir.existsSync()) {
      Logger.info('Cleaning Android v26 icon cache...');
      try {
        await buggyDir.delete(recursive: true);
      } catch (e) {
        Logger.warning('Failed to clean Android icon cache: $e');
      }
    }
  }

  // --------------------------------------------------------------------------
  // BUILD ARTIFACTS
  // --------------------------------------------------------------------------

  /// Renames the final .apk or .aab to include client name and version.
  Future<File> renameOutput({
    required String clientName,
    required String version,
    required String type, // 'apk' or 'aab'
  }) async {
    final subPath = type == 'apk'
        ? 'app/outputs/apk/release/app-release.apk'
        : 'app/outputs/bundle/release/app-release.aab';

    final buildFile = File(p.join(projectDir, 'build', subPath));

    if (!buildFile.existsSync()) {
      throw BuildException(
        'Build artifact not found at "${buildFile.path}"',
        fix:
            'Verify the Flutter build succeeded and created the expected output.',
      );
    }

    final newName = '${clientName}_v${version.replaceAll('+', '_')}.$type';
    final destinationPath = p.join(buildFile.parent.path, newName);

    Logger.info('Renaming build artifact to: $newName');
    try {
      return await buildFile.rename(destinationPath);
    } catch (e, s) {
      throw BuildException(
        'Failed to rename artifact from "${buildFile.path}" to "$destinationPath"',
        fix:
            'Check if the file is locked by another process or missing write permissions.',
        originalStackTrace: s,
      );
    }
  }

  // --------------------------------------------------------------------------
  // PRIVATE HELPERS
  // --------------------------------------------------------------------------

  Future<void> _ensureUdaraIgnoreFile() async {
    final file = File(p.join(projectDir, '.udaraignore'));

    if (await file.exists()) {
      return;
    }

    Logger.info('Creating default .udaraignore file...');

    const defaultContent = '''
# Udara CLI ignore file
# Auto-generated - you can edit freely

service_account.json
*.pem
*.key
*.p12
*.jks
*.keystore
''';

    try {
      await file.writeAsString(defaultContent.trim());
      Logger.success('.udaraignore created');
    } catch (e) {
      Logger.warning('Could not create default .udaraignore file: $e');
    }
  }

  Future<void> _copyDirectory(
    Directory source,
    Directory destination,
  ) async {
    final brandingConfig = await _loadBrandingConfig();

    final patterns = [
      ..._defaultExcludedPatterns,
      ...brandingConfig.excludes,
    ];

    final globs = patterns.map(Glob.new).toList();

    await _copyDirectoryInternal(
      source,
      destination,
      source,
      globs,
    );
  }

  Future<void> _copyDirectoryInternal(
    Directory source,
    Directory destination,
    Directory root,
    List<Glob> globs,
  ) async {
    await for (final entity in source.list(recursive: false)) {
      final relativePath = p.relative(
        entity.path,
        from: root.path,
      );

      final shouldSkip = globs.any(
        (glob) => glob.matches(relativePath),
      );

      if (shouldSkip) {
        Logger.info('Skipping ignored asset: $relativePath');
        continue;
      }

      if (entity is Directory) {
        final newDirectory = Directory(
          p.join(
            destination.path,
            p.basename(entity.path),
          ),
        );

        await newDirectory.create(recursive: true);

        await _copyDirectoryInternal(
          entity,
          newDirectory,
          root,
          globs,
        );
      } else if (entity is File) {
        await entity.copy(
          p.join(
            destination.path,
            p.basename(entity.path),
          ),
        );
      }
    }
  }

  Future<_BrandingConfig> _loadBrandingConfig() async {
    final ignoreFile = File(
      p.join(projectDir, '.udaraignore'),
    );

    if (!ignoreFile.existsSync()) {
      return const _BrandingConfig();
    }

    try {
      final lines = await ignoreFile.readAsLines();

      final excludes = lines
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .where((e) => !e.startsWith('#'))
          .toList();

      return _BrandingConfig(excludes: excludes);
    } catch (e) {
      Logger.warning('Failed to read .udaraignore file: $e');
      return const _BrandingConfig();
    }
  }
}

class CleanupService {
  final String projectDir;
  final ConfigService config;

  CleanupService({
    required this.projectDir,
    required this.config,
  });

  /// Reverts all temporary changes made during the build process.
  Future<void> performFullCleanup({
    String? appNameForCleanup,
    bool fontsWereChanged = false,
    bool isWhiteLabel = false,
  }) async {
    Logger.info('Starting project cleanup...');

    await _restoreBackedUpFiles(!isWhiteLabel);
    await _removeTempFiles();

    if (fontsWereChanged) {
      await _restoreDefaultFonts();
    }

    Logger.success('Project restored to original state.');
  }

  // --------------------------------------------------------------------------
  // RESTORATION LOGIC
  // --------------------------------------------------------------------------

  Future<void> _restoreBackedUpFiles(bool restorePbxproj) async {
    final filesToRestore = [
      'pubspec.yaml',
      'flutter_launcher_icons.yaml',
      if (restorePbxproj) p.join('ios', 'Runner.xcodeproj', 'project.pbxproj'),
    ];

    for (var fileName in filesToRestore) {
      final file = File(p.join(projectDir, fileName));
      final backupFile = File('${file.path}.bak');

      if (backupFile.existsSync()) {
        Logger.info('Restoring $fileName...');
        try {
          await config.restoreBackup(file);
        } catch (e) {
          Logger.warning('Failed to restore backup for $fileName: $e');
        }
      }
    }
  }

  Future<void> _removeTempFiles() async {
    final rootEnv = File(p.join(projectDir, '.env'));
    if (rootEnv.existsSync()) {
      Logger.info('Removing temporary .env');
      try {
        await rootEnv.delete();
      } catch (e) {
        Logger.warning('Failed to delete temporary .env file: $e');
      }
    }

    final brandingDir = Directory(p.join(projectDir, 'assets', 'branding'));
    if (brandingDir.existsSync()) {
      Logger.info('Removing branding assets');
      try {
        await brandingDir.delete(recursive: true);
      } catch (e) {
        Logger.warning('Failed to delete branding assets directory: $e');
      }
    }
  }

  /*   Future<void> _revertIosStoryboard(String appName) async {
    final storyboardFile = File(
      p.join(
          projectDir, 'ios', 'Runner', 'Base.lproj', 'LaunchScreen.storyboard'),
    );

    if (storyboardFile.existsSync()) {
      Logger.info('Reverting iOS LaunchScreen changes...');
      try {
        var content = await storyboardFile.readAsString();
        content = content.replaceAll('LaunchImage$appName', 'LaunchImage');
        await storyboardFile.writeAsString(content);
      } catch (e) {
        Logger.warning('Failed to revert iOS LaunchScreen storyboard: $e');
      }
    }
  } */

  Future<void> _restoreDefaultFonts() async {
    final targetFontsDir = Directory(p.join(projectDir, 'assets', 'fonts'));
    final backupFontsDir = Directory('${targetFontsDir.path}.bak');

    if (backupFontsDir.existsSync()) {
      Logger.info('Restoring default system fonts...');
      try {
        if (targetFontsDir.existsSync()) {
          await targetFontsDir.delete(recursive: true);
        }
        await backupFontsDir.rename(targetFontsDir.path);
      } catch (e) {
        Logger.warning('Failed to restore default fonts: $e');
      }
    }
  }
}

class _BrandingConfig {
  final List<String> excludes;

  const _BrandingConfig({
    this.excludes = const [],
  });
}

const _defaultExcludedPatterns = [
  'service_account.json',
  '*.pem',
  '*.key',
  '*.p12',
  '*.jks',
  '*.keystore',
];
