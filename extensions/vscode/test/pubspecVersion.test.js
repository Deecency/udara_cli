const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const v = require('../out/pubspecVersion');

test('accepts Flutter version formats', () => {
  for (const ok of ['1.0.0', '1.4.0+12', '2.0.0-beta.1', '2.0.0-beta.1+3']) {
    assert.ok(v.VERSION_PATTERN.test(ok), ok);
  }
  for (const bad of ['1.0', 'v1.0.0', '1.0.0+', '1.0.0+abc', 'latest']) {
    assert.ok(!v.VERSION_PATTERN.test(bad), bad);
  }
});

test('resolveVersion keeps the current build number when none is given', () => {
  assert.strictEqual(v.resolveVersion('1.4.0', '1.3.9+41'), '1.4.0+41');
  assert.strictEqual(v.resolveVersion('1.4.0+50', '1.3.9+41'), '1.4.0+50');
  assert.strictEqual(v.resolveVersion('1.4.0', '1.3.9'), '1.4.0');
  assert.strictEqual(v.resolveVersion('  ', '1.3.9+41'), undefined);
});

test('replaceVersionInContent only touches the version value', () => {
  const src = 'name: app\nversion: "1.0.0+1" # release\nenvironment:\n  sdk: ">=3.0.0"\n';
  const out = v.replaceVersionInContent(src, '2.1.0+7');
  assert.strictEqual(out, 'name: app\nversion: "2.1.0+7" # release\nenvironment:\n  sdk: ">=3.0.0"\n');
  assert.strictEqual(
    v.replaceVersionInContent('version: 1.0.0+1\n', '1.0.1+2'),
    'version: 1.0.1+2\n',
  );
});

test('does not match nested version keys and fails without a version line', () => {
  const src = 'name: app\ndependencies:\n  foo:\n    version: 1.2.3\n';
  assert.throws(() => v.replaceVersionInContent(src, '9.9.9'));
});

test('write then read round-trips on disk', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'udara-ver-'));
  fs.writeFileSync(path.join(dir, 'pubspec.yaml'), 'name: app\nversion: 1.0.0+1\n');
  assert.strictEqual(v.readPubspecVersion(dir), '1.0.0+1');
  v.writePubspecVersion(dir, '3.2.1+9');
  assert.strictEqual(v.readPubspecVersion(dir), '3.2.1+9');
  fs.rmSync(dir, { recursive: true });
});
