import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:udara_cli/core/core.dart';

/// Stand-ins for the DER certificates: what matters is the subject name.
final _debugCert =
    utf8.encode('0\x82..1\x100\x0e..CN=Android Debug, O=Android');
final _releaseCert = utf8.encode('0\x82..1\x100\x0e..CN=Fintellia Release');

List<int> _u16(int v) =>
    (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();
List<int> _u32(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
List<int> _u64(int v) =>
    (ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List();

/// A minimal zip, optionally with an APK Signing Block before the central
/// directory.
Uint8List _zip(Map<String, List<int>> entries,
    {bool deflate = false, List<int>? apkSignature}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  entries.forEach((name, data) {
    final nameBytes = utf8.encode(name);
    final stored = deflate ? ZLibEncoder(raw: true).convert(data) : data;
    final offset = out.length;
    out
      ..add(_u32(0x04034b50))
      ..add(_u16(20))
      ..add(_u16(0))
      ..add(_u16(deflate ? 8 : 0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u32(0))
      ..add(_u32(stored.length))
      ..add(_u32(data.length))
      ..add(_u16(nameBytes.length))
      ..add(_u16(0))
      ..add(nameBytes)
      ..add(stored);
    central
      ..add(_u32(0x02014b50))
      ..add(_u16(20))
      ..add(_u16(20))
      ..add(_u16(0))
      ..add(_u16(deflate ? 8 : 0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u32(0))
      ..add(_u32(stored.length))
      ..add(_u32(data.length))
      ..add(_u16(nameBytes.length))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u32(0))
      ..add(_u32(offset))
      ..add(nameBytes);
  });
  if (apkSignature != null) {
    // size, id-value pair, size, magic
    final pair = [
      ..._u64(apkSignature.length + 4),
      ..._u32(0x7109871a),
      ...apkSignature
    ];
    final size = pair.length + 8 + 16;
    out
      ..add(_u64(size))
      ..add(pair)
      ..add(_u64(size))
      ..add(ascii.encode('APK Sig Block 42'));
  }
  final centralOffset = out.length;
  final centralBytes = central.takeBytes();
  out
    ..add(centralBytes)
    ..add(_u32(0x06054b50))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(entries.length))
    ..add(_u16(entries.length))
    ..add(_u32(centralBytes.length))
    ..add(_u32(centralOffset))
    ..add(_u16(0));
  return out.takeBytes();
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('udara_sign_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File write(String name, List<int> bytes) =>
      File(p.join(tmp.path, name))..writeAsBytesSync(bytes);

  final manifest = {'BundleConfig.pb': utf8.encode('config')};

  test('an AAB signed with the debug key is detected (stored and deflated)',
      () {
    for (final deflate in [false, true]) {
      final aab = write(
          'debug.aab',
          _zip({...manifest, 'META-INF/ANDROIDD.RSA': _debugCert},
              deflate: deflate));
      expect(ArtifactSigning.isDebugSigned(aab), isTrue,
          reason: 'deflate=$deflate');
    }
  });

  test('an AAB signed with a release key passes', () {
    final aab = write(
        'release.aab',
        _zip({...manifest, 'META-INF/UDARA360.RSA': _releaseCert},
            deflate: true));
    expect(ArtifactSigning.isDebugSigned(aab), isFalse);
  });

  test('APK Signature Scheme v2 blocks are read', () {
    final debug = write(
        'debug.apk',
        _zip({
          'classes.dex': [1, 2, 3]
        }, apkSignature: _debugCert));
    final release = write(
        'release.apk',
        _zip({
          'classes.dex': [1, 2, 3]
        }, apkSignature: _releaseCert));
    expect(ArtifactSigning.isDebugSigned(debug), isTrue);
    expect(ArtifactSigning.isDebugSigned(release), isFalse);
  });

  test('unsigned or unreadable files give no verdict', () {
    expect(ArtifactSigning.isDebugSigned(write('unsigned.aab', _zip(manifest))),
        isNull);
    expect(ArtifactSigning.isDebugSigned(write('junk.aab', [1, 2, 3])), isNull);
    expect(ArtifactSigning.isDebugSigned(File(p.join(tmp.path, 'missing.aab'))),
        isNull);
  });
}
