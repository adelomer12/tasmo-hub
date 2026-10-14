import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../models/device.dart';

/// Offline checks run on a firmware file before it is sent to a device.
///
/// What is verified depends on the format:
/// * ESP8266 (Tasmota): gzip CRC-32, the boot stub and app image headers and
///   their XOR checksums, and the flash size in the header.
/// * ESP32 (Tasmota): image header, chip ID against the device's chip, the
///   ESP-IDF app descriptor (rejects factory/bootloader images), the XOR
///   checksum and the SHA-256 the build tool appends to the image.
/// * OpenBeken: file type for the device's platform (RBL header for BK72xx).
/// * Any file: SHA-256 against a published digest or one the user pasted.

enum CheckLevel { ok, warn, fail }

class FwCheck {
  const FwCheck(this.level, this.label, [this.detail = '']);
  final CheckLevel level;
  final String label;
  final String detail;

  @override
  String toString() =>
      '${level.name}: $label${detail.isEmpty ? '' : ' ($detail)'}';
}

/// What the device is, as far as the update is concerned.
class FwTarget {
  const FwTarget({
    required this.type,
    this.hardware = '',
    this.version = '',
    this.freeSketchKb,
  });

  final FirmwareType type;

  /// StatusFWR.Hardware, e.g. "ESP8266EX", "ESP32-C3", "BK7231N".
  final String hardware;

  /// StatusFWR.Version, e.g. "15.0.1(release-tasmota32)" or
  /// "OpenBK7231N_1.18.12".
  final String version;

  /// StatusMEM.Free (KB of free program space), Tasmota only.
  final int? freeSketchKb;

  bool get isEsp8266 {
    final h = hardware.toUpperCase();
    return h.startsWith('ESP8266') || h.startsWith('ESP8285');
  }

  bool get isEsp32 => !isEsp8266 && hardware.toUpperCase().startsWith('ESP32');

  /// ESP-IDF image chip ID for the device's chip, or null if unknown.
  int? get esp32ChipId {
    if (!isEsp32) return null;
    final h = hardware.toUpperCase();
    for (final e in _chipIds.entries) {
      if (e.key.isNotEmpty && h.contains(e.key)) return e.value;
    }
    return 0; // plain ESP32 (D0WD, PICO, U4WDH...)
  }

  /// Tasmota build variant from the version, e.g. "tasmota32c3".
  String get tasmotaVariant {
    final m = RegExp(r'\(([^)]+)\)').firstMatch(version);
    if (m == null) return isEsp32 ? 'tasmota32' : 'tasmota';
    return m[1]!.replaceFirst('release-', '');
  }

  /// Tasmota version number without the variant, e.g. "15.0.1".
  String get versionNumber {
    if (type == FirmwareType.openbeken) {
      final i = version.lastIndexOf('_');
      return i < 0 ? version : version.substring(i + 1);
    }
    final i = version.indexOf('(');
    return (i < 0 ? version : version.substring(0, i)).trim();
  }

  /// OpenBeken platform prefix, e.g. "OpenBK7231N".
  String get obkPlatform {
    final i = version.lastIndexOf('_');
    return i < 0 ? '' : version.substring(0, i);
  }
}

const _chipIds = {
  '-S2': 2,
  '-C3': 5,
  '-S3': 9,
  '-C2': 12,
  '-C6': 13,
  '-H2': 16,
  '-P4': 18,
  '-C61': 20,
  '-C5': 23,
};

String chipName(int id) => switch (id) {
      0 => 'ESP32',
      2 => 'ESP32-S2',
      5 => 'ESP32-C3',
      9 => 'ESP32-S3',
      12 => 'ESP32-C2',
      13 => 'ESP32-C6',
      16 => 'ESP32-H2',
      18 => 'ESP32-P4',
      20 => 'ESP32-C61',
      23 => 'ESP32-C5',
      _ => 'chip $id',
    };

class FirmwareReport {
  FirmwareReport({
    required this.fileName,
    required this.sha256,
    required this.size,
    required this.payload,
    required this.uploadName,
  });

  final String fileName;
  final String sha256;
  final int size;

  /// Bytes to send to the device (gzip is unpacked for ESP32).
  final Uint8List payload;
  final String uploadName;
  final List<FwCheck> checks = [];

  /// True when the SHA-256 matched a published or pasted digest.
  bool digestVerified = false;

  bool get ok => !checks.any((c) => c.level == CheckLevel.fail);
  bool get hasWarnings => checks.any((c) => c.level == CheckLevel.warn);

  void add(CheckLevel l, String label, [String detail = '']) =>
      checks.add(FwCheck(l, label, detail));
}

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// Accepts "sha256:abc...", "ABC..." or text with the hash inside.
String? normalizeDigest(String? s) {
  if (s == null) return null;
  final m = RegExp(r'[0-9a-fA-F]{64}').firstMatch(s);
  return m?.group(0)?.toLowerCase();
}

FirmwareReport verifyFirmware(
  Uint8List bytes,
  String fileName,
  FwTarget target, {
  String? expectedSha256,
}) {
  final hash = sha256Hex(bytes);
  final lower = fileName.toLowerCase();
  final isGz = bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;

  var payload = bytes;
  var uploadName = fileName;
  Uint8List image = bytes;
  final r0 = FirmwareReport(
      fileName: fileName,
      sha256: hash,
      size: bytes.length,
      payload: payload,
      uploadName: uploadName);

  if (isGz) {
    try {
      // dart:io's zlib checks the gzip CRC-32 and length trailer.
      image = Uint8List.fromList(gzip.decode(bytes));
    } catch (e) {
      r0.add(CheckLevel.fail, 'Compressed file is damaged',
          'gzip CRC or data error');
      return r0;
    }
  }
  if (image.length < 1024) {
    r0.add(CheckLevel.fail, 'File too small', '${image.length} bytes');
    return r0;
  }

  late final FirmwareReport r;
  if (target.type == FirmwareType.openbeken) {
    r = r0;
    _checkObk(r, bytes, lower, target);
  } else {
    if (isGz && target.isEsp32) {
      // Tasmota for ESP32 cannot flash gzip; send the unpacked image.
      payload = image;
      uploadName = fileName.replaceFirst(RegExp(r'\.gz$'), '');
    }
    r = FirmwareReport(
        fileName: fileName,
        sha256: hash,
        size: bytes.length,
        payload: payload,
        uploadName: uploadName);
    if (isGz) r.add(CheckLevel.ok, 'Compressed data intact', 'gzip CRC-32');
    _checkTasmota(r, image, isGz ? bytes.length : image.length, target);
  }

  final want = normalizeDigest(expectedSha256);
  if (want != null) {
    if (want == hash) {
      r.digestVerified = true;
      r.add(CheckLevel.ok, 'SHA-256 matches the published digest');
    } else {
      r.add(CheckLevel.fail, 'SHA-256 does not match',
          'expected ${want.substring(0, 12)}…, file ${hash.substring(0, 12)}…');
    }
  }
  return r;
}

// ---- ESP images ----------------------------------------------------------

class EspImage {
  EspImage(this.start, this.end, this.segments, this.checksumOk,
      {this.chipId, this.hashAppended = false, this.hashOk, this.appDesc});

  final int start;
  final int end;
  final int segments;
  final bool checksumOk;
  final int? chipId;
  final bool hashAppended;
  final bool? hashOk;
  final EspAppDesc? appDesc;
}

class EspAppDesc {
  EspAppDesc(this.version, this.project, this.idfVersion);
  final String version;
  final String project;
  final String idfVersion;
}

int _u32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

String _cstr(Uint8List b, int o, int len) {
  final end = (o + len).clamp(0, b.length);
  var i = o;
  while (i < end && b[i] != 0) {
    i++;
  }
  return String.fromCharCodes(b.sublist(o, i)).trim();
}

/// Parses one ESP image at [start]. [esp32] selects the 24-byte header
/// (with extended header) instead of the 8-byte ESP8266 header.
EspImage? parseEspImage(Uint8List b, int start, {required bool esp32}) {
  if (start + 24 > b.length || b[start] != 0xE9) return null;
  final segs = b[start + 1];
  if (segs == 0 || segs > 16) return null;
  var p = start + (esp32 ? 24 : 8);
  var cs = 0xEF;
  EspAppDesc? desc;
  for (var i = 0; i < segs; i++) {
    if (p + 8 > b.length) return null;
    final len = _u32(b, p + 4);
    p += 8;
    if (len < 0 || p + len > b.length) return null;
    if (esp32 && i == 0 && len >= 256 && _u32(b, p) == 0xABCD5432) {
      desc = EspAppDesc(
          _cstr(b, p + 16, 32), _cstr(b, p + 48, 32), _cstr(b, p + 112, 32));
    }
    for (var j = p; j < p + len; j++) {
      cs ^= b[j];
    }
    p += len;
  }
  // Checksum byte sits at the end of the 16-byte-aligned block.
  p += (16 - (p + 1) % 16) % 16;
  if (p >= b.length) return null;
  final checksumOk = b[p] == cs;
  p++;
  if (!esp32) return EspImage(start, p, segs, checksumOk);

  final chipId = b[start + 12] | (b[start + 13] << 8);
  final hashAppended = b[start + 23] == 1;
  bool? hashOk;
  if (hashAppended) {
    if (p + 32 > b.length) {
      hashOk = false;
    } else {
      final digest = sha256.convert(b.sublist(start, p)).bytes;
      hashOk = true;
      for (var i = 0; i < 32; i++) {
        if (digest[i] != b[p + i]) hashOk = false;
      }
      p += 32;
    }
  }
  return EspImage(start, p, segs, checksumOk,
      chipId: chipId,
      hashAppended: hashAppended,
      hashOk: hashOk,
      appDesc: desc);
}

/// ESP8266 header byte 3 high nibble -> flash size in KB.
const _esp8266Flash = {
  0: 512,
  1: 256,
  2: 1024,
  3: 2048,
  4: 4096,
  8: 8192,
  9: 16384
};

void _checkTasmota(
    FirmwareReport r, Uint8List img, int uploadSize, FwTarget t) {
  if (img.isEmpty || img[0] != 0xE9) {
    if (img.length > 0x8002 && img[0x8000] == 0xAA && img[0x8001] == 0x50 ||
        img[0] == 0xFF) {
      r.add(CheckLevel.fail, 'This is a factory image',
          'factory.bin is for serial flashing; use the .bin without "factory"');
    } else {
      r.add(CheckLevel.fail, 'Not an ESP firmware image',
          'first byte is not 0xE9');
    }
    return;
  }
  if (img.length > 0x8002 && img[0x8000] == 0xAA && img[0x8001] == 0x50) {
    r.add(CheckLevel.fail, 'This is a factory image',
        'it contains a bootloader and partition table; use the OTA .bin');
    return;
  }

  // The ESP32 extended header carries 0xEE (WP pin disabled) at byte 8 and a
  // chip ID; ESP8266 images start the first segment there instead.
  final as32 = parseEspImage(img, 0, esp32: true);
  final looksEsp32 = img[8] == 0xEE || as32?.appDesc != null;

  if (looksEsp32) {
    final im = as32;
    if (im == null) {
      r.add(CheckLevel.fail, 'Image header unreadable');
      return;
    }
    if (im.appDesc == null) {
      r.add(CheckLevel.fail, 'Not an app image',
          'no ESP-IDF app descriptor (bootloader or other image)');
      return;
    }
    r.add(CheckLevel.ok, 'ESP32 app image', '${im.segments} segments');
    if (t.isEsp8266) {
      r.add(CheckLevel.fail, 'Wrong chip',
          'file is for ${chipName(im.chipId ?? 0)}, device is ${t.hardware}');
    } else if (t.esp32ChipId != null && im.chipId != t.esp32ChipId) {
      r.add(CheckLevel.fail, 'Wrong chip',
          'file is for ${chipName(im.chipId ?? 0)}, device is ${t.hardware}');
    } else {
      r.add(CheckLevel.ok, 'Chip matches', chipName(im.chipId ?? 0));
    }
    r.add(im.checksumOk ? CheckLevel.ok : CheckLevel.fail,
        im.checksumOk ? 'Image checksum OK' : 'Image checksum wrong');
    if (im.hashAppended) {
      r.add(
          im.hashOk == true ? CheckLevel.ok : CheckLevel.fail,
          im.hashOk == true
              ? 'Built-in SHA-256 OK'
              : 'Built-in SHA-256 wrong (file corrupted)');
    } else {
      r.add(CheckLevel.warn, 'No built-in SHA-256 in this image');
    }
    final d = im.appDesc!;
    if (d.idfVersion.isNotEmpty) {
      r.add(CheckLevel.ok, 'App descriptor found', 'ESP-IDF ${d.idfVersion}');
    }
    if (im.end != img.length) {
      r.add(CheckLevel.warn, 'Extra data after the image',
          '${img.length - im.end} bytes');
    }
  } else {
    final boot = parseEspImage(img, 0, esp32: false);
    final app = boot != null && boot.end <= 0x1000
        ? parseEspImage(img, 0x1000, esp32: false)
        : null;
    if (boot == null) {
      r.add(CheckLevel.fail, 'Image header unreadable');
      return;
    }
    r.add(CheckLevel.ok, 'ESP8266 image');
    if (t.isEsp32) {
      r.add(CheckLevel.fail, 'Wrong chip',
          'file is for ESP8266, device is ${t.hardware}');
    }
    final allOk = boot.checksumOk && (app?.checksumOk ?? true);
    r.add(
        allOk ? CheckLevel.ok : CheckLevel.fail,
        allOk ? 'Image checksums OK' : 'Image checksum wrong (file corrupted)',
        app == null ? 'single image' : 'boot stub + app');
    final end = app?.end ?? boot.end;
    if (end > img.length) {
      r.add(CheckLevel.fail, 'Image is truncated');
    } else if (end < img.length - 16) {
      r.add(CheckLevel.warn, 'Extra data after the image',
          '${img.length - end} bytes');
    }
    final flashKb = _esp8266Flash[(img[3] & 0xF0) >> 4];
    if (flashKb != null) {
      r.add(CheckLevel.ok, 'Flash size in header', '$flashKb KB');
    }
    final free = t.freeSketchKb;
    if (free != null && t.isEsp8266) {
      // Tasmota begins the update with (free - 4 KB), rounded to 4 KB.
      final room = ((free * 1024 - 0x1000) & ~0xFFF);
      if (uploadSize > room) {
        r.add(
            CheckLevel.warn,
            'Does not fit next to the running firmware',
            '${(uploadSize / 1024).ceil()} KB needed, ${room ~/ 1024} KB free: '
                'the minimal firmware is flashed first');
      } else {
        r.add(CheckLevel.ok, 'Fits in free program space',
            '${(uploadSize / 1024).ceil()} of ${room ~/ 1024} KB');
      }
    }
  }

  final name = r.fileName.toLowerCase();
  final variant = t.tasmotaVariant.toLowerCase();
  final fileVariant =
      name.split('/').last.replaceFirst(RegExp(r'\.bin(\.gz)?$'), '');
  if (fileVariant.startsWith('tasmota') &&
      fileVariant != variant &&
      !fileVariant.contains('minimal')) {
    r.add(CheckLevel.warn, 'Different build variant',
        'device runs $variant, file is $fileVariant');
  }
}

// ---- OpenBeken ------------------------------------------------------------

/// OTA file suffix OpenBeken's web app uses for each platform.
String? obkOtaSuffix(String platform) {
  final p = platform.toUpperCase();
  if (p.startsWith('OPENBK72') || p.startsWith('OPENBK7238')) return '.rbl';
  if (p.startsWith('OPENBL602')) return '_OTA.bin.xz.ota';
  if (p.startsWith('OPENW800')) return '_ota.img';
  if (p.startsWith('OPENW600')) return '_gz.img';
  if (p.startsWith('OPENLN882')) return '_OTA.bin';
  if (p.startsWith('OPENESP')) return '.img';
  return null;
}

void _checkObk(FirmwareReport r, Uint8List b, String lower, FwTarget t) {
  final platform = t.obkPlatform;
  final suffix = obkOtaSuffix(platform);
  final base = lower.split('/').last;
  if (platform.isNotEmpty) {
    if (base.startsWith('${platform.toLowerCase()}_')) {
      r.add(CheckLevel.ok, 'Built for $platform');
    } else {
      r.add(CheckLevel.fail, 'File is not for $platform',
          'OpenBeken files start with the platform name');
    }
  }
  if (base.contains('_qio_') ||
      base.contains('_ua_') ||
      base.contains('_ug_') ||
      base.endsWith('.factory.bin')) {
    r.add(CheckLevel.fail, 'This is a serial-flash image',
        'pick the OTA file instead');
    return;
  }
  if (suffix != null) {
    if (base.endsWith(suffix.toLowerCase())) {
      r.add(CheckLevel.ok, 'OTA file type', suffix);
    } else {
      r.add(CheckLevel.fail, 'Wrong file type', 'OTA file must end in $suffix');
    }
  }
  if (suffix == '.rbl') {
    final magic = String.fromCharCodes(b.sublist(0, 3));
    r.add(magic == 'RBL' ? CheckLevel.ok : CheckLevel.fail,
        magic == 'RBL' ? 'RBL header found' : 'Missing RBL header');
  }
  // Deeper content checks for OBK formats happen in the device bootloader,
  // which keeps the old firmware if the new image fails its CRC.
}
