import 'package:test/test.dart';
import 'package:udara_cli/core/core.dart';

const _source = '''# Cross River production
APP_NAME_PROD="Cross river mobile"
BANK_NAME="Cross River MFB"
BUNDLE_ID="com.fintellia.crossrivermobile"
ASSETS_PATH="clients/cross_river_mobile/"
APP_ICON_PATH="assets/branding/cross_river_mobile/logo_small.png"
ONBOARDING_IMAGES="assets/branding/cross_river_mobile/teaser_1.png,assets/branding/cross_river_mobile/teaser_2.png"
OTHER_PATH="clients/cross_river_mobile_old/x"
API_BASE_URL=https://api.example.com # shared
TENANT_ID="crossriver"
RELEASE_STORE_PASSWORD=secret

DEVELOPMENT_TEAM="ABCDE12345"
''';

const _branding = '''# LAPO Pay (LAPO Microfinance Bank)

## Branding for `clients/lapo_pay/.env` and `.env_test`

```env
APP_NAME_PROD="LAPO Pay"
BANK_NAME="LAPO Microfinance Bank"
# Confirm the production bundle id:
BUNDLE_ID="com.fintellia.lapopay"
PRIMARY_COLOR="0xFF7C3AED"
```

Add these to both files.
''';

void main() {
  group('brandingFromMarkdown', () {
    test('reads the env block', () {
      expect(ClientEnvCopy.brandingFromMarkdown(_branding), {
        'APP_NAME_PROD': 'LAPO Pay',
        'BANK_NAME': 'LAPO Microfinance Bank',
        'BUNDLE_ID': 'com.fintellia.lapopay',
        'PRIMARY_COLOR': '0xFF7C3AED',
      });
    });

    test('is empty without one', () {
      expect(ClientEnvCopy.brandingFromMarkdown('# Notes\n'), isEmpty);
    });
  });

  group('copy', () {
    final result = ClientEnvCopy.copy(
      source: _source,
      from: 'cross_river_mobile',
      to: 'lapo_pay',
      overrides: ClientEnvCopy.brandingFromMarkdown(_branding),
    );
    final env = ConfigService.parseEnvContent(result.text);

    test('applies BRANDING.md values in place and appends new ones', () {
      expect(env['APP_NAME_PROD'], 'LAPO Pay');
      expect(env['BANK_NAME'], 'LAPO Microfinance Bank');
      expect(env['BUNDLE_ID'], 'com.fintellia.lapopay');
      expect(env['PRIMARY_COLOR'], '0xFF7C3AED');
      expect(result.overridden, ['APP_NAME_PROD', 'BANK_NAME', 'BUNDLE_ID']);
      expect(result.added, ['PRIMARY_COLOR']);
      expect(result.text.trimRight(), endsWith('PRIMARY_COLOR="0xFF7C3AED"'));
    });

    test('points the client\'s paths at the new folder only', () {
      expect(env['ASSETS_PATH'], 'clients/lapo_pay/');
      expect(env['APP_ICON_PATH'], 'assets/branding/lapo_pay/logo_small.png');
      expect(
        env['ONBOARDING_IMAGES'],
        'assets/branding/lapo_pay/teaser_1.png,'
        'assets/branding/lapo_pay/teaser_2.png',
      );
      expect(env['OTHER_PATH'], 'clients/cross_river_mobile_old/x');
      expect(result.pathsRewritten,
          ['ASSETS_PATH', 'APP_ICON_PATH', 'ONBOARDING_IMAGES']);
    });

    test('keeps shared keys, comments and order', () {
      expect(env['API_BASE_URL'], 'https://api.example.com');
      expect(env['TENANT_ID'], 'crossriver');
      expect(env['DEVELOPMENT_TEAM'], 'ABCDE12345');
      expect(result.text, contains('# Cross River production'));
      expect(result.text,
          contains('API_BASE_URL=https://api.example.com # shared'));
      expect(result.text.indexOf('APP_NAME_PROD'),
          lessThan(result.text.indexOf('DEVELOPMENT_TEAM')));
      expect(result.text, startsWith('# Started from "cross_river_mobile"'));
    });

    test('leaves out the source\'s release signing', () {
      expect(env.containsKey('RELEASE_STORE_PASSWORD'), isFalse);
      expect(result.dropped, ['RELEASE_STORE_PASSWORD']);
    });

    test('flags identity keys nothing changed', () {
      expect(result.sameAsSource, isEmpty);
      final bare = ClientEnvCopy.copy(
        source: _source,
        from: 'cross_river_mobile',
        to: 'lapo_pay',
      );
      expect(bare.sameAsSource,
          unorderedEquals(['BUNDLE_ID', 'APP_NAME_PROD', 'BANK_NAME']));
      expect(bare.added, isEmpty);
    });
  });
}
