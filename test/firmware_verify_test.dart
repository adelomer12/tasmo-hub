import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tasmo_hub/models/device.dart';
import 'package:tasmo_hub/services/firmware_verify.dart';

/// Real release images are checked when FIRMWARE_SAMPLES points at a folder
/// holding tasmota.bin, tasmota.bin.gz, tasmota-minimal.bin.gz,
/// tasmota32.bin, tasmota32c3.bin and tasmota32.factory.bin (CI downloads
/// them; they are too big to commit). Synthetic images run everywhere.
void main() {
  const esp8266 = FwTarget(
      type: FirmwareType.tasmota,
      hardware: 'ESP8266EX',
      version: '15.0.1(release-tasmota)',
      freeSketchKb: 1400);
  const esp32 = FwTarget(
      type: FirmwareType.tasmota,
      hardware: 'ESP32-D0WD-V3',
      version: '15.0.1(release-tasmota32)');
  const esp32c3 = FwTarget(
      type: FirmwareType.tasmota,
      hardware: 'ESP32-C3',
      version: '15.0.1(release-tasmota32c3)');

  List<String> fails(FirmwareReport r) => r.checks
      .where((c) => c.level == CheckLevel.fail)
      .map((c) => c.label)
      .toList();

  group('target parsing', () {
    test('variant, version and chip', () {
      expect(esp32c3.tasmotaVariant, 'tasmota32c3');
      expect(esp32c3.versionNumber, '15.0.1');
      expect(esp32c3.esp32ChipId, 5);
      expect(esp32.esp32ChipId, 0);
      expect(esp8266.isEsp8266, isTrue);
      expect(esp8266.esp32ChipId, isNull);
      const obk = FwTarget(
          type: FirmwareType.openbeken,
          hardware: 'BK7231N',
          version: 'OpenBK7231N_1.18.120');
      expect(obk.obkPlatform, 'OpenBK7231N');
      expect(obk.versionNumber, '1.18.120');
      expect(obkOtaSuffix(obk.obkPlatform), '.rbl');
    });

    test('release file names from the running build', () {
      FwTarget t(String hw, String v) =>
          FwTarget(type: FirmwareType.tasmota, hardware: hw, version: v);
      expect(
          t('ESP8285N08', '15.6.0(release-minimal)').tasmotaVariant, 'tasmota');
      expect(t('ESP8285N08', '15.6.0(release-minimal)').isStepStone, isTrue);
      expect(t('ESP8266EX', '14.2.0(release-sensors)').tasmotaVariant,
          'tasmota-sensors');
      expect(
          t('ESP8266EX', '14.2.0(release-tasmota)').tasmotaVariant, 'tasmota');
      expect(t('ESP32-C3', '15.6.0(release-safeboot)').tasmotaVariant,
          'tasmota32c3');
      expect(t('ESP32-D0WD-V3', '15.6.0(release-bluetooth)').tasmotaVariant,
          'tasmota32-bluetooth');
      expect(t('ESP32-S3', '15.6.0(release-tasmota32s3)').tasmotaVariant,
          'tasmota32s3');
    });

    test('digest normalising', () {
      final h = 'a' * 64;
      expect(normalizeDigest('sha256:$h'), h);
      expect(normalizeDigest(h.toUpperCase()), h);
      expect(normalizeDigest('nope'), isNull);
    });
  });

  group('synthetic ESP8266 image', () {
    Uint8List build() {
      // header + one 32-byte segment + checksum, padded to 16 bytes.
      final b = BytesBuilder();
      b.add([0xE9, 1, 0x02, 0x40, 0, 0, 0x10, 0x40]);
      final data = List<int>.generate(32, (i) => i * 7 & 0xFF);
      b.add([0, 0, 0x10, 0x40, 32, 0, 0, 0]);
      b.add(data);
      var cs = 0xEF;
      for (final x in data) {
        cs ^= x;
      }
      final len = b.length;
      b.add(List.filled((16 - (len + 1) % 16) % 16, 0));
      b.add([cs]);
      b.add(List.filled(2048 - b.length, 0)); // pad past the size floor
      return b.toBytes();
    }

    test('valid image passes and wrong chip fails', () {
      final img = build();
      final r = verifyFirmware(img, 'tasmota.bin', esp8266);
      expect(fails(r), isEmpty, reason: r.checks.join('\n'));
      expect(fails(verifyFirmware(img, 'tasmota.bin', esp32)),
          contains('Wrong chip'));
    });

    test('flipped byte breaks the checksum', () {
      final img = build()..[20] ^= 0x01;
      expect(fails(verifyFirmware(img, 'tasmota.bin', esp8266)),
          contains('Image checksum wrong (file corrupted)'));
    });

    test('gzip round trip and corrupted gzip', () {
      final gz = Uint8List.fromList(gzip.encode(build()));
      expect(fails(verifyFirmware(gz, 'tasmota.bin.gz', esp8266)), isEmpty);
      gz[gz.length - 6] ^= 0xFF; // CRC-32 trailer
      expect(fails(verifyFirmware(gz, 'tasmota.bin.gz', esp8266)),
          contains('Compressed file is damaged'));
    });

    test('pasted SHA-256 must match', () {
      final img = build();
      final good = verifyFirmware(img, 'tasmota.bin', esp8266,
          expectedSha256: sha256Hex(img));
      expect(good.digestVerified, isTrue);
      final bad =
          verifyFirmware(img, 'tasmota.bin', esp8266, expectedSha256: 'b' * 64);
      expect(fails(bad), contains('SHA-256 does not match'));
    });

    test('not firmware at all', () {
      final junk = Uint8List.fromList(List.filled(4096, 0x41));
      expect(fails(verifyFirmware(junk, 'x.bin', esp8266)),
          contains('Not an ESP firmware image'));
    });
  });

  group('OpenBeken files', () {
    const obk = FwTarget(
        type: FirmwareType.openbeken,
        hardware: 'BK7231N',
        version: 'OpenBK7231N_1.18.100');
    Uint8List rbl() =>
        Uint8List.fromList([...'RBL'.codeUnits, 0, ...List.filled(4092, 7)]);

    test('right platform and type', () {
      expect(fails(verifyFirmware(rbl(), 'OpenBK7231N_1.18.120.rbl', obk)),
          isEmpty);
    });
    test('wrong platform, UART image, missing header', () {
      expect(fails(verifyFirmware(rbl(), 'OpenBK7231T_1.18.120.rbl', obk)),
          contains('File is not for OpenBK7231N'));
      expect(fails(verifyFirmware(rbl(), 'OpenBK7231N_QIO_1.18.120.bin', obk)),
          contains('This is a serial-flash image'));
      final noHdr = rbl()..[0] = 0;
      expect(fails(verifyFirmware(noHdr, 'OpenBK7231N_1.18.120.rbl', obk)),
          contains('Missing RBL header'));
    });
  });

  final dir = Platform.environment['FIRMWARE_SAMPLES'];
  group('real Tasmota release images', () {
    Uint8List read(String n) => File('$dir/$n').readAsBytesSync();

    test('ESP8266 bin and gz', () {
      for (final n in ['tasmota.bin', 'tasmota.bin.gz']) {
        final r = verifyFirmware(read(n), n, esp8266);
        expect(fails(r), isEmpty, reason: '$n\n${r.checks.join('\n')}');
        expect(r.checks.map((c) => c.label), contains('Image checksums OK'));
      }
      final m = verifyFirmware(
          read('tasmota-minimal.bin.gz'), 'tasmota-minimal.bin.gz', esp8266);
      expect(fails(m), isEmpty, reason: m.checks.join('\n'));
    });

    test('ESP32 bin: checksum, built-in SHA-256, chip', () {
      final r = verifyFirmware(read('tasmota32.bin'), 'tasmota32.bin', esp32);
      expect(fails(r), isEmpty, reason: r.checks.join('\n'));
      expect(r.checks.map((c) => c.label), contains('Built-in SHA-256 OK'));
      expect(
          fails(
              verifyFirmware(read('tasmota32.bin'), 'tasmota32.bin', esp32c3)),
          contains('Wrong chip'));
      expect(
          fails(
              verifyFirmware(read('tasmota32.bin'), 'tasmota32.bin', esp8266)),
          contains('Wrong chip'));
      final c3 =
          verifyFirmware(read('tasmota32c3.bin'), 'tasmota32c3.bin', esp32c3);
      expect(fails(c3), isEmpty, reason: c3.checks.join('\n'));
    });

    test('ESP32 corrupted byte is caught', () {
      final b = read('tasmota32.bin');
      b[b.length ~/ 2] ^= 0x10;
      final f = fails(verifyFirmware(b, 'tasmota32.bin', esp32));
      expect(f, contains('Image checksum wrong'));
      expect(f, contains('Built-in SHA-256 wrong (file corrupted)'));
    });

    test('ESP32 gz is unpacked for upload', () {
      final gz = Uint8List.fromList(gzip.encode(read('tasmota32.bin')));
      final r = verifyFirmware(gz, 'tasmota32.bin.gz', esp32);
      expect(fails(r), isEmpty);
      expect(r.uploadName, 'tasmota32.bin');
      expect(r.payload[0], 0xE9);
    });

    test('factory image is rejected', () {
      final r = verifyFirmware(
          read('tasmota32.factory.bin'), 'tasmota32.factory.bin', esp32);
      expect(fails(r), contains('This is a factory image'));
    });
  }, skip: dir == null ? 'set FIRMWARE_SAMPLES to run' : false);
}
