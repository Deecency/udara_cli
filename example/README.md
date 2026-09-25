# Example: from an empty Flutter app to two branded builds

This walkthrough takes a fresh Flutter project and produces builds for two
clients, `acme` and `beta`, from one codebase.

## 1. Install and initialise

```bash
dart pub global activate udara_cli
cd my_flutter_app

udara_cli setup                       # adds rename, flutter_launcher_icons,
                                      # splash_master, flutter_dotenv and config files
udara_cli setup --clients acme,beta   # scaffolds clients/acme, clients/beta and clients/default
```

The scaffold for each client looks like this:

```
clients/acme/
├── .env            # APP_NAME_PROD, BUNDLE_ID, ASSETS_PATH, APP_ICON_PATH, APP_LOGO_PATH
├── .env_test       # same keys, used with --test
├── logo_small.png  # placeholder app icon — replace it
├── logo_large.png  # placeholder splash image — replace it
├── fonts/          # optional custom fonts + fonts.yaml
└── README.md
```

## 2. Load the env in the app

```dart
import 'package:flutter_dotenv/flutter_dotenv.dart';

Future<void> main() async {
  const envFile = String.fromEnvironment(
    'CLIENT_ENV',
    defaultValue: 'clients/default/.env', // registered as an asset by setup
  );
  await dotenv.load(fileName: envFile);
  runApp(MyApp(primary: Color(int.parse(dotenv.env['PRIMARY_COLOR'] ?? '0xFF4285F4'))));
}
```

## 3. Brand each client

Edit `clients/acme/.env`:

```env
APP_NAME_PROD="Acme"
BUNDLE_ID="com.acme.app"
ASSETS_PATH="clients/acme/"
APP_ICON_PATH="assets/branding/acme/logo_small.png"
APP_LOGO_PATH="assets/branding/acme/logo_large.png"
DEVELOPMENT_TEAM="ABC123XYZ9"
PRIMARY_COLOR="0xFFE53935"
```

Drop the real `logo_small.png` / `logo_large.png` into `clients/acme/`, then
check everything:

```bash
udara_cli doctor
```

## 4. Build

```bash
udara_cli build --client acme --type apk          # build/app/outputs/apk/release/acme_v1.0.0_1.apk
udara_cli build --client beta                     # AAB
udara_cli build --client acme --platform ios      # build/ios/ipa/acme_v1.0.0_1.ipa
udara_cli build --client beta --test --slack --slack-channel #builds
```

Each run restores the project afterwards and is recorded:

```bash
udara_cli history
udara_cli diff --client-a acme --client-b beta
```

## 5. Run locally as a client

```bash
udara_cli whitelabel --client acme --keep
flutter run --dart-define=CLIENT_ENV=.env
udara_cli clean            # remove the generated branding again
```
