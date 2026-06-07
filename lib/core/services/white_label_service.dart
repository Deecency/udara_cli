import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import '../core.dart';
import 'package:glob/glob.dart';

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
    _ensureUdaraIgnoreFile();
    final sourceDir = Directory(p.join(projectDir, sourcePath));
    if (!sourceDir.existsSync()) {
      throw BuildException('Source assets not found at ${sourceDir.path}');
    }

    final targetDir =
        Directory(p.join(projectDir, 'assets', 'branding', clientName));

    // Clean start: Remove existing branding if it exists
    if (targetDir.existsSync()) {
      await targetDir.delete(recursive: true);
    }
    await targetDir.create(recursive: true);

    print('🚀 Syncing assets: ${p.basename(sourcePath)} -> ${targetDir.path}');
    await _copyDirectory(sourceDir, targetDir);
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
      print('ℹ️ No custom fonts found for this client. Skipping.');
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
      print('✏️ Overwriting pubspec fonts with client configuration...');

      final fontsContent = await fontsConfigFile.readAsString();
      final fontsList = loadYaml(fontsContent);

      if (fontsList is YamlList || fontsList is List) {
        await config.updatePubspecFonts(fontsList);
        print('✅ Client font configuration applied to pubspec.yaml');
      } else {
        print('⚠️ Error: fonts.yaml must be a list of font families.');
      }
    }
  }

  // --------------------------------------------------------------------------
  // PLATFORM SPECIFIC (IOS/ANDROID)
  // --------------------------------------------------------------------------

  /// Handles the iOS LaunchScreen.storyboard renaming to avoid cache issues.
  Future<void> patchIosSplash(String appName) async {
    final storyboardFile = File(
      p.join(
          projectDir, 'ios', 'Runner', 'Base.lproj', 'LaunchScreen.storyboard'),
    );

    if (!storyboardFile.existsSync()) return;

    print('🍎 Patching iOS LaunchScreen for $appName...');
    var content = await storyboardFile.readAsString();

    // Replace default LaunchImage reference with a unique one per client
    content = content.replaceAll('LaunchImage', 'LaunchImage$appName');

    // De-duplicate lines (common issue with splash_master)
    final lines = content.split('\n');
    final uniqueContent = lines.toSet().toList().join('\n');

    await storyboardFile.writeAsString(uniqueContent);
  }

  /// Fixes a specific Android adaptive icon bug.
  Future<void> cleanAndroidIconCache() async {
    final buggyDir = Directory(
      p.join(projectDir, 'android', 'app', 'src', 'main', 'res',
          'mipmap-anydpi-v26'),
    );

    if (buggyDir.existsSync()) {
      print('🤖 Cleaning Android v26 icon cache...');
      await buggyDir.delete(recursive: true);
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
      throw BuildException('Build artifact not found at ${buildFile.path}');
    }

    final newName = '${clientName}_v${version.replaceAll('+', '_')}.$type';
    final destinationPath = p.join(buildFile.parent.path, newName);

    print('📦 Renaming artifact to: $newName');
    return await buildFile.rename(destinationPath);
  }

  // --------------------------------------------------------------------------
  // PRIVATE HELPERS
  // --------------------------------------------------------------------------

  Future<void> _ensureUdaraIgnoreFile() async {
    final file = File(p.join(projectDir, '.udaraignore'));

    if (await file.exists()) {
      // Don't touch existing user config
      return;
    }

    print('🛡️ Creating default .udaraignore file...');

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

    await file.writeAsString(defaultContent.trim());

    print('✅ .udaraignore created');
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
        print('🔒 Skipping $relativePath');
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

    final lines = await ignoreFile.readAsLines();

    final excludes = lines
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .where((e) => !e.startsWith('#'))
        .toList();

    return _BrandingConfig(excludes: excludes);
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
  }) async {
    print('\n🧹 Starting project cleanup...');

    await _restoreYamlFiles();

    await _removeTempFiles();

    if (appNameForCleanup != null) {
      await _revertIosStoryboard(appNameForCleanup);
    }

    if (fontsWereChanged) {
      await _restoreDefaultFonts();
    }

    print('✅ Project restored to original state.');
  }

  // --------------------------------------------------------------------------
  // RESTORATION LOGIC
  // --------------------------------------------------------------------------

  Future<void> _restoreYamlFiles() async {
    final filesToRestore = [
      'pubspec.yaml',
      'flutter_launcher_icons.yaml',
    ];

    for (var fileName in filesToRestore) {
      final file = File(p.join(projectDir, fileName));
      if (File('${file.path}.bak').existsSync()) {
        print('  -> Restoring $fileName...');
        await config.restoreBackup(file);
      }
    }
  }

  Future<void> _removeTempFiles() async {
    // Remove the temporary .env in the root
    final rootEnv = File(p.join(projectDir, '.env'));
    if (rootEnv.existsSync()) {
      print('  -> Removing temporary .env...');
      await rootEnv.delete();
    }

    // Remove the temporary branding assets folder
    final brandingDir = Directory(p.join(projectDir, 'assets', 'branding'));
    if (brandingDir.existsSync()) {
      print('  -> Removing branding assets...');
      await brandingDir.delete(recursive: true);
    }
  }

  Future<void> _revertIosStoryboard(String appName) async {
    final storyboardFile = File(
      p.join(
          projectDir, 'ios', 'Runner', 'Base.lproj', 'LaunchScreen.storyboard'),
    );

    if (storyboardFile.existsSync()) {
      print('  -> Reverting iOS LaunchScreen changes...');
      var content = await storyboardFile.readAsString();
      // Revert the unique client name back to the default identifier
      content = content.replaceAll('LaunchImage$appName', 'LaunchImage');
      await storyboardFile.writeAsString(content);
    }
  }

  Future<void> _restoreDefaultFonts() async {
    final targetFontsDir = Directory(p.join(projectDir, 'assets', 'fonts'));
    final backupFontsDir = Directory('${targetFontsDir.path}.bak');

    if (backupFontsDir.existsSync()) {
      print('  -> Restoring default system fonts...');
      if (targetFontsDir.existsSync()) {
        await targetFontsDir.delete(recursive: true);
      }
      await backupFontsDir.rename(targetFontsDir.path);
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
