import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import '../core.dart';

class WhiteLabelService {
  final String projectDir;
  final ConfigService config;

  WhiteLabelService({required this.projectDir, required this.config});

  // --------------------------------------------------------------------------
  // ASSET MANAGEMENT
  // --------------------------------------------------------------------------

  /// Copies client-specific branding images into the active assets folder.
  Future<void> syncBrandingAssets(String clientName, String sourcePath) async {
    await _ensureUdaraIgnoreFile();

    await _cleanupOtherClientBrandingFolders(clientName);

    final sourceDir = Directory(p.join(projectDir, sourcePath));

    if (!sourceDir.existsSync()) {
      throw BuildException(
        'Source assets directory not found at "${sourceDir.path}"',
        fix:
            'Verify $clientName environment variables (ASSETS_PATH) and check if the directory exists.',
      );
    }

    final clientRoot = Directory(p.join(projectDir, 'clients', clientName));
    final relativeSourcePath = p.relative(
      sourceDir.absolute.path,
      from: clientRoot.absolute.path,
    );
    if (relativeSourcePath == '..' ||
        relativeSourcePath.startsWith('../') ||
        p.isAbsolute(relativeSourcePath)) {
      throw BuildException(
        'Client assets path must be inside "${clientRoot.path}".',
        fix:
            'Set ASSETS_PATH in the client environment to a directory under clients/$clientName.',
      );
    }

    final targetDir = Directory(
      p.join(projectDir, 'assets', 'branding', clientName),
    );

    try {
      if (targetDir.existsSync()) {
        final markerFile = File(p.join(targetDir.path, managedMarkerFile));

        if (await markerFile.exists()) {
          await targetDir.delete(recursive: true);
        } else {
          throw BuildException(
            'Refusing to delete unmanaged branding folder at "${targetDir.path}".',
            fix:
                'Remove the folder manually or add the $managedMarkerFile marker if it is managed by udara_cli.',
          );
        }
      }

      await targetDir.create(recursive: true);

      await File(
        p.join(targetDir.path, managedMarkerFile),
      ).writeAsString('managed=true');

      Logger.info(
        'Syncing assets: ${p.basename(sourcePath)} ➔ ${targetDir.path}',
      );

      await _copyDirectory(sourceDir, targetDir);

      final copiedFiles = targetDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => p.basename(f.path) != managedMarkerFile)
          .toList();

      if (copiedFiles.isEmpty) {
        throw BuildException(
          'No branding assets were copied for client "$clientName".',
          fix: 'Check ASSETS_PATH and ensure it contains image assets.',
        );
      }
      Logger.debug('Copied ${copiedFiles.length} asset file(s).');
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

  /// Locates the client's fonts directory. `clients/<client>/fonts` wins,
  /// then `<ASSETS_PATH>/fonts`, matching what `doctor` validates.
  Directory? findClientFontsDir(String clientName, String clientAssetsPath) {
    final candidates = [
      Directory(p.join(projectDir, 'clients', clientName, 'fonts')),
      Directory(p.join(projectDir, clientAssetsPath, 'fonts')),
    ];
    for (final dir in candidates) {
      if (dir.existsSync()) return dir;
    }
    return null;
  }

  /// Swaps system fonts for client fonts and updates pubspec configuration.
  /// Returns true when fonts were changed and need restoring on cleanup.
  Future<bool> applyClientFonts(
      String clientName, String clientAssetsPath) async {
    final clientFontsDir = findClientFontsDir(clientName, clientAssetsPath);
    final targetFontsDir = Directory(p.join(projectDir, 'assets', 'fonts'));

    if (clientFontsDir == null) {
      Logger.info('No custom fonts found for this client. Skipping.');
      return false;
    }

    final hasFontFiles = clientFontsDir
        .listSync()
        .whereType<File>()
        .any((f) => !p.basename(f.path).startsWith('.'));
    if (!hasFontFiles) {
      Logger.info('Client fonts directory is empty. Skipping.');
      return false;
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
    } else {
      Logger.warning(
          'Fonts copied but no fonts.yaml found in "${clientFontsDir.path}"; '
          'pubspec font families were not updated.');
    }
    return true;
  }

  // --------------------------------------------------------------------------
  // PLATFORM SPECIFIC (IOS/ANDROID)
  // --------------------------------------------------------------------------

  /// Fixes a specific Android adaptive icon bug.
  Future<void> cleanAndroidIconCache() async {
    final buggyDir = Directory(
      p.join(
        projectDir,
        'android',
        'app',
        'src',
        'main',
        'res',
        'mipmap-anydpi-v26',
      ),
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

  /// Renames the final .apk, .aab or .ipa to include client name and version.
  Future<File> renameOutput({
    required String clientName,
    required String version,
    required String type, // 'apk', 'aab' or 'ipa'
  }) async {
    final buildFile = _locateBuildArtifact(type);

    if (buildFile == null) {
      throw BuildException(
        'Build artifact (.$type) not found under "${p.join(projectDir, 'build')}"',
        fix:
            'Verify the Flutter build succeeded and created the expected output.',
      );
    }

    final safeVersion = version.replaceAll('+', '_');
    final newName = '${clientName}_v$safeVersion.$type';
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

  File? _locateBuildArtifact(String type) {
    switch (type) {
      case 'apk':
        return _existing(p.join(projectDir, 'build', 'app', 'outputs', 'apk',
            'release', 'app-release.apk'));
      case 'aab':
        return _existing(p.join(projectDir, 'build', 'app', 'outputs', 'bundle',
            'release', 'app-release.aab'));
      case 'ipa':
        final ipaDir = Directory(p.join(projectDir, 'build', 'ios', 'ipa'));
        if (!ipaDir.existsSync()) return null;
        final ipas = ipaDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.ipa'))
            .toList()
          ..sort(
              (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
        return ipas.isEmpty ? null : ipas.first;
      default:
        return null;
    }
  }

  File? _existing(String path) {
    final file = File(path);
    return file.existsSync() ? file : null;
  }

  // --------------------------------------------------------------------------
  // PRIVATE HELPERS
  // --------------------------------------------------------------------------

  /// Marker written into branding folders the CLI owns, so cleanup never
  /// deletes a folder a developer created by hand.
  static const managedMarkerFile = '.udara_managed';

  /// The client whose branding and env act as the fallback for plain
  /// `flutter run`; its branding folder is never removed by cleanup.
  static const defaultClientName = 'default';

  Future<void> _cleanupOtherClientBrandingFolders(String activeClient) async {
    final clientsDir = Directory(p.join(projectDir, 'clients'));
    final brandingRoot = Directory(p.join(projectDir, 'assets', 'branding'));

    if (!await clientsDir.exists() || !await brandingRoot.exists()) {
      return;
    }

    final clientNames = <String>{};

    await for (final entity in clientsDir.list()) {
      if (entity is Directory) {
        clientNames.add(p.basename(entity.path));
      }
    }

    for (final client in clientNames) {
      if (client == activeClient || client == defaultClientName) continue;

      final clientBrandingDir = Directory(p.join(brandingRoot.path, client));

      final markerFile = File(
        p.join(clientBrandingDir.path, managedMarkerFile),
      );

      if (await clientBrandingDir.exists() && await markerFile.exists()) {
        Logger.info(
          'Removing inactive managed branding folder: ${clientBrandingDir.path}',
        );

        await clientBrandingDir.delete(recursive: true);
      }
    }
  }

  Future<void> _ensureUdaraIgnoreFile() async {
    final file = File(p.join(projectDir, '.udaraignore'));

    if (await file.exists()) {
      return;
    }

    Logger.info('Creating default .udaraignore file...');

    const defaultContent = '''
# Udara CLI ignore file
# Glob patterns (relative to the client assets folder) that must never be
# copied into the app bundle. Auto-generated - you can edit freely.

service_account.json
*.pem
*.key
*.p12
*.jks
*.keystore

# Environment files
.env
.env.*
''';

    try {
      await file.writeAsString(defaultContent.trim());
      Logger.success('.udaraignore created');
    } catch (e) {
      Logger.warning('Could not create default .udaraignore file: $e');
    }
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    final brandingConfig = await _loadBrandingConfig();

    final patterns = [..._defaultExcludedPatterns, ...brandingConfig.excludes];

    final globs = patterns.map(Glob.new).toList();

    await _copyDirectoryInternal(source, destination, source, globs);
  }

  Future<void> _copyDirectoryInternal(
    Directory source,
    Directory destination,
    Directory root,
    List<Glob> globs,
  ) async {
    await for (final entity in source.list(recursive: false)) {
      final relativePath = p.relative(entity.path, from: root.path);
      final baseName = p.basename(entity.path);

      // Patterns match the path relative to the assets root, or the bare
      // file name, so `*.jks` also catches `keys/upload.jks`.
      final shouldSkip = globs
          .any((glob) => glob.matches(relativePath) || glob.matches(baseName));

      if (shouldSkip) {
        Logger.debug('Skipping ignored asset: $relativePath');
        continue;
      }

      if (entity is Directory) {
        final newDirectory = Directory(
          p.join(destination.path, p.basename(entity.path)),
        );

        await newDirectory.create(recursive: true);

        await _copyDirectoryInternal(entity, newDirectory, root, globs);
      } else if (entity is File) {
        await entity.copy(p.join(destination.path, p.basename(entity.path)));
      }
    }
  }

  Future<_BrandingConfig> _loadBrandingConfig() async {
    final ignoreFile = File(p.join(projectDir, '.udaraignore'));

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

  CleanupService({required this.projectDir, required this.config});

  /// Reverts all temporary changes made during the build process:
  /// restores backed-up files, removes files the CLI generated, deletes
  /// managed branding folders and puts the original fonts back.
  Future<void> performFullCleanup() async {
    Logger.info('Starting project cleanup...');

    try {
      await _restoreBackedUpFiles();
      await config.removeCreatedFiles();
      await _removeTempFiles();
      await _restoreDefaultFonts();

      Logger.success('Project restored to original state.');
    } finally {
      // Backups are disposable build state and must not survive cleanup.
      await config.clearBackups();
    }
  }

  // --------------------------------------------------------------------------
  // RESTORATION LOGIC
  // --------------------------------------------------------------------------

  Future<void> _restoreBackedUpFiles() async {
    final filesToRestore = [
      'pubspec.yaml',
      'flutter_launcher_icons.yaml',
      '.env',
      p.join('ios', 'Runner.xcodeproj', 'project.pbxproj'),
    ];

    for (final fileName in filesToRestore) {
      final file = File(p.join(projectDir, fileName));
      if (!config.hasBackup(file)) continue;

      Logger.info('Restoring $fileName...');

      try {
        await config.restoreBackup(file);
      } catch (e) {
        Logger.warning('Failed to restore backup for $fileName: $e');
      }
    }
  }

  Future<void> _removeTempFiles() async {
    final brandingRoot = Directory(p.join(projectDir, 'assets', 'branding'));

    if (await brandingRoot.exists()) {
      await for (final entity in brandingRoot.list()) {
        if (entity is! Directory) continue;

        // The default client's branding is the fallback for plain
        // `flutter run`, so it is left in place.
        if (p.basename(entity.path) == WhiteLabelService.defaultClientName) {
          continue;
        }

        final marker =
            File(p.join(entity.path, WhiteLabelService.managedMarkerFile));

        if (await marker.exists()) {
          Logger.info('Removing temporary branding folder: ${entity.path}');
          await entity.delete(recursive: true);
        }
      }
    }
  }

  Future<void> _restoreDefaultFonts() async {
    final targetFontsDir = Directory(p.join(projectDir, 'assets', 'fonts'));
    final backupFontsDir = Directory('${targetFontsDir.path}.bak');

    if (backupFontsDir.existsSync()) {
      Logger.info('Restoring default fonts...');
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

  const _BrandingConfig({this.excludes = const []});
}

const _defaultExcludedPatterns = [
  '.udara',
  '**/.udara',
  '.git',
  '**/.git',
  '.dart_tool',
  '**/.dart_tool',
  'build',
  '**/build',
  'android',
  'ios',
  'lib',
  'test',
  'web',
  'macos',
  'windows',
  'linux',
  'pubspec.yaml',
  'pubspec.lock',
  'service_account.json',
  '.udara_build_history.json',
  '.DS_Store',
  '**/.DS_Store',
  'README.md',
  '.env',
  '.env_test',
  '.env.*',
  '**/.env',
  '**/.env_test',
  '**/.env.*',
  '*.pem',
  '*.key',
  '*.p12',
  '*.jks',
  '*.keystore',
];
