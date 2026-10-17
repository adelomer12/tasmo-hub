import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tasmo_hub/models/device.dart';
import 'package:tasmo_hub/services/ota_service.dart';

/// A tiny stand-in for Tasmota's and OpenBeken's upgrade endpoints.
class FakeDevice {
  late HttpServer server;
  final log = <String>[];
  Uint8List? received;
  String? receivedName;
  String? auth;
  final referers = <String?>[];
  int u4Calls = 0;

  /// Answers for /u4 in order; the last one repeats.
  List<String> u4Answers = ['none'];
  bool failUpload = false;
  bool garbleReply = false;
  bool minimal = false;
  String? rootHtml;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  String get host => '127.0.0.1:${server.port}';

  Future<void> _handle(HttpRequest req) async {
    log.add('${req.method} ${req.uri}');
    auth = req.headers.value('authorization');
    referers.add(req.headers.value('referer'));
    final res = req.response;
    switch (req.uri.path) {
      case '/u4':
        final a = u4Answers[u4Calls.clamp(0, u4Answers.length - 1)];
        u4Calls++;
        res.write(a);
      case '/up':
        res.write('<html>upgrade</html>');
      case '/u2':
        final ct = ContentType.parse(req.headers.value('content-type')!);
        final boundary = ct.parameters['boundary']!;
        final body =
            await req.fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d));
        final parts = await MimeLite.parse(body.toBytes(), boundary);
        received = parts.$2;
        receivedName = parts.$1;
        if (garbleReply) {
          // Like the ESP8266 web server: broken framing, then it restarts.
          final s = await req.response.detachSocket(writeHeaders: false);
          s.add(latin1.encode('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked'
              '\r\n\r\n5\r\nbad chunk sizes'));
          await s.close();
          return;
        }
        res.write(failUpload
            ? '<b>Upload <font>Failed</font></b><br><br>Not enough space'
            : '<b>Upload <font>Successful</font></b>');
      case '/cm':
        res.headers.contentType = ContentType.json;
        res.write(minimal
            ? '{}'
            : '{"StatusFWR":{"Version":"15.6.0(release-tasmota)","Hardware":"ESP8285N08"}}');
      case '/':
        res.headers.contentType = ContentType.html;
        res.write(rootHtml ??
            '<div>MINIMAL firmware</div><a>Tasmota 15.6.0 (release-minimal) by Theo Arends</a>');
      case '/api/ota':
        received =
            (await req.fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d)))
                .toBytes();
        res.write('OK');
      case '/api/reboot':
        res.write('{"reboot":1}');
      default:
        res.statusCode = 404;
    }
    await res.close();
  }
}

/// Just enough multipart parsing for one file field.
class MimeLite {
  static Future<(String, Uint8List)> parse(
      Uint8List body, String boundary) async {
    final text = latin1.decode(body);
    final start = text.indexOf('\r\n\r\n') + 4;
    final end = text.lastIndexOf('\r\n--$boundary');
    final head = text.substring(0, start);
    final name = RegExp(r'filename="([^"]+)"').firstMatch(head)!.group(1)!;
    return (name, Uint8List.fromList(body.sublist(start, end)));
  }
}

void main() {
  late FakeDevice dev;
  final payload =
      Uint8List.fromList([0xE9, ...List.generate(5000, (i) => i & 0xFF)]);

  setUp(() async {
    dev = FakeDevice();
    await dev.start();
  });
  tearDown(() => dev.server.close(force: true));

  test('Tasmota ESP8266: /up then multipart /u2 with exact bytes', () async {
    final d = Device(id: 'x', host: dev.host, name: 'Plug');
    await OtaService()
        .flashTasmota(d, 'secret', payload, 'tasmota.bin', esp32: false);
    expect(dev.log.first, 'GET /up');
    expect(dev.log[1], 'POST /u2?fsz=${payload.length}');
    expect(dev.received, payload);
    expect(dev.receivedName, 'tasmota.bin');
    expect(dev.auth, 'Basic ${base64Encode(utf8.encode('admin:secret'))}');
  });

  test('Tasmota ESP32 safeboot: waits for u4 "true" before upload', () async {
    dev.u4Answers = ['false', 'true'];
    final d = Device(id: 'x', host: dev.host, name: 'Plug');
    final steps = <String>[];
    await OtaService().flashTasmota(d, null, payload, 'tasmota32.bin',
        esp32: true, onStep: steps.add);
    expect(dev.u4Calls, 2);
    expect(steps, contains('Restarting into safeboot mode…'));
    expect(dev.received, payload);
    expect(dev.auth, isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('ESP32 safeboot page counts when /u4 never says "true"', () async {
    // Like the POWR320D: after the restart, /u4 answers with the main page.
    dev.u4Answers = ['false', '<html>page</html>'];
    dev.rootHtml = "<span style='text-align:center;color:#ff5661;'>"
        '<h3>SAFEBOOT</h3></span><h3>Sonoff POWR320D</h3>';
    final d = Device(id: 'x', host: dev.host, name: 'Plug');
    final steps = <String>[];
    await OtaService().flashTasmota(d, null, payload, 'tasmota32.bin',
        esp32: true, onStep: steps.add);
    expect(steps, contains('Safeboot page found'));
    expect(dev.received, payload);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('safeboot page detection', () {
    expect(isSafebootPage('<span><h3>SAFEBOOT</h3></span>'), isTrue);
    expect(isSafebootPage('Tasmota 13.2.0 (release-safeboot)'), isTrue);
    expect(isSafebootPage('<h3>Sonoff POWR320D</h3><h2>Waleed</h2>'), isFalse);
  });

  test('Tasmota requests carry a same-device Referer', () async {
    dev.u4Answers = ['true'];
    final d = Device(id: 'x', host: dev.host, name: 'Plug');
    await OtaService()
        .flashTasmota(d, 'pw', payload, 'tasmota32.bin', esp32: true);
    await OtaService().restart(d, 'pw');
    expect(dev.log.map((l) => l.split('?').first).toList(),
        ['GET /u4', 'GET /up', 'POST /u2', 'GET /cm']);
    // Tasmota checks that the Referer starts with http://<its address>.
    expect(dev.referers, everyElement('http://${dev.host}/up'));
    expect(dev.log.last, contains('Restart'));
  });

  test('Tasmota failure page becomes an error', () async {
    dev.failUpload = true;
    final d = Device(id: 'x', host: dev.host, name: 'Plug');
    await expectLater(
        OtaService()
            .flashTasmota(d, null, payload, 'tasmota.bin', esp32: false),
        throwsA(isA<OtaException>().having(
            (e) => e.message, 'message', contains('Not enough space'))));
  });

  test('unreadable reply after a full upload is not an error', () async {
    dev.garbleReply = true;
    final d = Device(id: 'x', host: dev.host, name: 'Plug');
    final steps = <String>[];
    await OtaService().flashTasmota(d, null, payload, 'tasmota-minimal.bin.gz',
        esp32: false, onStep: steps.add);
    expect(dev.received, payload);
    expect(steps.last, 'Upload sent; waiting for the device…');
  });

  test('minimal build: version from the web page, chip from the hint',
      () async {
    dev.minimal = true;
    final d = Device(id: 'x', host: dev.host, name: 'Plug');
    final t =
        await OtaService().readTarget(d, null, hardwareHint: 'ESP8285N08');
    expect(t.version, '15.6.0(release-minimal)');
    expect(t.isStepStone, isTrue);
    expect(t.isEsp8266, isTrue);
    expect(t.tasmotaVariant, 'tasmota');
  });

  test('full build: version from Status 2', () async {
    final d = Device(id: 'x', host: dev.host, name: 'Plug');
    final t = await OtaService().readTarget(d, null);
    expect(t.version, '15.6.0(release-tasmota)');
    expect(t.hardware, 'ESP8285N08');
  });

  test('OpenBeken: raw body to /api/ota then reboot', () async {
    final d = Device(
        id: 'x', host: dev.host, name: 'Bulb', type: FirmwareType.openbeken);
    await OtaService().flashObk(d, null, payload);
    expect(dev.log, ['POST /api/ota', 'POST /api/reboot']);
    expect(dev.received, payload);
  });
}
