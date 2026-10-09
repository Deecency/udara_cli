/// Flags `.env` entries that look like secrets, so they can be moved to
/// `.secrets` before they are compiled into (or bundled with) the app.
class SecretDetector {
  const SecretDetector._();

  static final _keyPattern = RegExp(
    r'(SECRET|PASSWORD|PASSWD|PRIVATE|TOKEN|CREDENTIAL|_PWD$|^PWD$|SIGNING_KEY|SERVICE_ACCOUNT)',
    caseSensitive: false,
  );

  static final _valuePatterns = <String, RegExp>{
    'a private key': RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----'),
    'a Stripe secret key': RegExp(r'\b(sk|rk)_(live|test)_[0-9A-Za-z]{10,}'),
    'a Slack token': RegExp(r'\bxox[abprs]-[0-9A-Za-z-]{10,}'),
    'an AWS access key': RegExp(r'\bAKIA[0-9A-Z]{16}\b'),
    'a GitHub token': RegExp(r'\bgh[pousr]_[0-9A-Za-z]{30,}'),
    'a Google service account': RegExp(r'"type"\s*:\s*"service_account"'),
  };

  /// Returns why [key]/[value] looks secret, or null.
  static String? reason(String key, String value) {
    for (final entry in _valuePatterns.entries) {
      if (entry.value.hasMatch(value)) return 'value looks like ${entry.key}';
    }
    if (value.isNotEmpty && _keyPattern.hasMatch(key))
      return 'name suggests a secret';
    return null;
  }
}
