import 'package:udara_cli/core/services/config_service.dart';

/// What [ClientEnvCopy.copy] produced and changed.
class ClientEnvCopyResult {
  ClientEnvCopyResult({
    required this.text,
    required this.overridden,
    required this.added,
    required this.pathsRewritten,
    required this.dropped,
    required this.sameAsSource,
  });

  /// The new env file.
  final String text;

  /// Keys whose value came from the overrides (BRANDING.md).
  final List<String> overridden;

  /// Override keys the source didn't have, appended at the end.
  final List<String> added;

  /// Keys whose `clients/<from>/` or `branding/<from>/` paths now point at
  /// the new client.
  final List<String> pathsRewritten;

  /// Release signing keys left out: they belong to the source client.
  final List<String> dropped;

  /// Identity keys (bundle id, app and bank names) still equal to the
  /// source's, which almost certainly need changing.
  final List<String> sameAsSource;
}

/// Starts a client's `.env` from another client's
/// (`udara_cli setup --clients new --from existing`): same keys, comments
/// and order, with the new client's paths and branding.
class ClientEnvCopy {
  static const identityKeys = {
    'BUNDLE_ID',
    'APP_NAME_PROD',
    'APP_NAME_STAGING',
    'APP_NAME_DEV',
    'BANK_NAME',
  };

  static final _line =
      RegExp(r'^(\s*(?:export\s+)?)([A-Za-z_][A-Za-z0-9_]*)(\s*=)(.*)$');

  /// The `KEY=value` pairs of the first ```env block in a client's
  /// BRANDING.md (written by Udara Onboarding's "Promote to repo").
  static Map<String, String> brandingFromMarkdown(String markdown) {
    final block =
        RegExp(r'```env\s*\n([\s\S]*?)```').firstMatch(markdown)?.group(1);
    if (block == null) return const {};
    return ConfigService.parseEnvContent(block, sourceName: 'BRANDING.md');
  }

  static ClientEnvCopyResult copy({
    required String source,
    required String from,
    required String to,
    Map<String, String> overrides = const {},
  }) {
    final sourceValues = ConfigService.parseEnvContent(source);
    final overridden = <String>[];
    final pathsRewritten = <String>[];
    final dropped = <String>[];
    final values = <String, String>{};
    final out = <String>[
      '# Started from "$from" by udara_cli setup --from. Keys that belong to',
      '# $from (ids, API keys, tenant) were copied as they are: check them.',
      '',
    ];

    for (final line in source.split('\n')) {
      final m = _line.firstMatch(line);
      if (m == null) {
        out.add(line);
        continue;
      }
      final key = m.group(2)!;
      if (key.startsWith('RELEASE_')) {
        dropped.add(key);
        continue;
      }
      if (overrides.containsKey(key)) {
        overridden.add(key);
        values[key] = overrides[key]!;
        out.add('${m.group(1)}$key${m.group(3)}${_quote(overrides[key]!)}');
        continue;
      }
      final raw = m.group(4)!;
      final rewritten = _rewritePaths(raw, from, to);
      if (rewritten != raw) pathsRewritten.add(key);
      values[key] = ConfigService.parseEnvContent('$key=$rewritten')[key] ?? '';
      out.add('${m.group(1)}$key${m.group(3)}$rewritten');
    }

    final added = [
      for (final key in overrides.keys)
        if (!overridden.contains(key) && !key.startsWith('RELEASE_')) key,
    ];
    if (added.isNotEmpty) {
      while (out.isNotEmpty && out.last.trim().isEmpty) {
        out.removeLast();
      }
      out
        ..add('')
        ..add('# From BRANDING.md');
      for (final key in added) {
        values[key] = overrides[key]!;
        out.add('$key=${_quote(overrides[key]!)}');
      }
    }

    var text = out.join('\n');
    if (!text.endsWith('\n')) text += '\n';
    return ClientEnvCopyResult(
      text: text,
      overridden: overridden,
      added: added,
      pathsRewritten: pathsRewritten,
      dropped: dropped,
      sameAsSource: [
        for (final key in identityKeys)
          if (sourceValues.containsKey(key) &&
              values[key] == sourceValues[key] &&
              (values[key] ?? '').isNotEmpty)
            key,
      ],
    );
  }

  /// `clients/<from>/…` and `branding/<from>/…` → the new client's folder.
  static String _rewritePaths(String raw, String from, String to) =>
      raw.replaceAllMapped(
        RegExp('(clients|branding)/${RegExp.escape(from)}(?=/|["\'\\s,]|\$)'),
        (m) => '${m.group(1)}/$to',
      );

  static String _quote(String value) =>
      value.contains('"') ? "'$value'" : '"$value"';
}
