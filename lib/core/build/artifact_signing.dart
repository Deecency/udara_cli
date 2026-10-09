import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Reads the signing certificate of an APK or AAB, without external tools,
/// to catch release builds signed with the Android debug key (which Gradle
/// silently falls back to when no release keystore is configured).
class ArtifactSigning {
  /// The debug certificate's subject is `CN=Android Debug, O=Android, C=US`.
  static final _debugName = ascii.encode('Android Debug');

  static const _eocdSignature = 0x06054b50;
  static const _centralSignature = 0x02014b50;
  static const _apkSigBlockMagic = 'APK Sig Block 42';

  /// True when [artifact] is signed with the debug key, false when it is
  /// signed with another key, and null when no signature could be read.
  ///
  /// Looks at the APK Signature Scheme v2+ block (APKs) and the JAR
  /// signature files in `META-INF/` (AABs and older APKs).
  static bool? isDebugSigned(File artifact) {
    RandomAccessFile? file;
    try {
      file = artifact.openSync();
      final length = file.lengthSync();
      final central = _findCentralDirectory(file, length);
      if (central == null) return null;

      final apkBlock = _apkSigningBlock(file, central.offset);
      final signatures = <List<int>>[
        if (apkBlock != null) apkBlock,
        ..._jarSignatureBlocks(file, central),
      ];
      if (signatures.isEmpty) return null;
      return signatures.any((s) => _contains(s, _debugName));
    } catch (_) {
      return null;
    } finally {
      file?.closeSync();
    }
  }

  static _CentralDirectory? _findCentralDirectory(
      RandomAccessFile file, int length) {
    // The end-of-central-directory record is at the end, before a comment
    // of at most 64 KiB.
    final tailLength = length < 65557 ? length : 65557;
    final tail = _read(file, length - tailLength, tailLength);
    final data = ByteData.sublistView(tail);
    for (var i = tail.length - 22; i >= 0; i--) {
      if (data.getUint32(i, Endian.little) != _eocdSignature) continue;
      final size = data.getUint32(i + 12, Endian.little);
      final offset = data.getUint32(i + 16, Endian.little);
      if (offset == 0xFFFFFFFF || offset + size > length) return null; // zip64
      return _CentralDirectory(offset, size);
    }
    return null;
  }

  static Uint8List? _apkSigningBlock(RandomAccessFile file, int centralOffset) {
    if (centralOffset < 32) return null;
    final footer = _read(file, centralOffset - 24, 24);
    if (ascii.decode(footer.sublist(8), allowInvalid: true) !=
        _apkSigBlockMagic) {
      return null;
    }
    final size = ByteData.sublistView(footer).getUint64(0, Endian.little);
    final start = centralOffset - size - 8;
    if (start < 0 || size > 64 * 1024 * 1024) return null;
    return _read(file, start, centralOffset - 24 - start);
  }

  static Iterable<List<int>> _jarSignatureBlocks(
      RandomAccessFile file, _CentralDirectory central) sync* {
    final entries = _read(file, central.offset, central.size);
    final data = ByteData.sublistView(entries);
    var i = 0;
    while (i + 46 <= entries.length &&
        data.getUint32(i, Endian.little) == _centralSignature) {
      final method = data.getUint16(i + 10, Endian.little);
      final compressedSize = data.getUint32(i + 20, Endian.little);
      final nameLength = data.getUint16(i + 28, Endian.little);
      final extraLength = data.getUint16(i + 30, Endian.little);
      final commentLength = data.getUint16(i + 32, Endian.little);
      final localOffset = data.getUint32(i + 42, Endian.little);
      final name = utf8.decode(entries.sublist(i + 46, i + 46 + nameLength),
          allowMalformed: true);
      i += 46 + nameLength + extraLength + commentLength;

      final upper = name.toUpperCase();
      if (!upper.startsWith('META-INF/') ||
          !(upper.endsWith('.RSA') ||
              upper.endsWith('.DSA') ||
              upper.endsWith('.EC'))) {
        continue;
      }
      final local = ByteData.sublistView(_read(file, localOffset, 30));
      final dataStart = localOffset +
          30 +
          local.getUint16(26, Endian.little) +
          local.getUint16(28, Endian.little);
      final raw = _read(file, dataStart, compressedSize);
      if (method == 0) {
        yield raw;
      } else if (method == 8) {
        yield ZLibDecoder(raw: true).convert(raw);
      }
    }
  }

  static Uint8List _read(RandomAccessFile file, int position, int length) {
    file.setPositionSync(position);
    return file.readSync(length);
  }

  static bool _contains(List<int> haystack, List<int> needle) {
    outer:
    for (var i = 0; i <= haystack.length - needle.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return true;
    }
    return false;
  }
}

class _CentralDirectory {
  _CentralDirectory(this.offset, this.size);
  final int offset;
  final int size;
}
