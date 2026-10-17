import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/device.dart';
import 'firmware_verify.dart';
import 'tasmota_api.dart';

/// A firmware file from an official source.
class FirmwareSource {
  FirmwareSource({
    required this.fileName,
    required this.urls,
    required this.origin,
    this.version = '',
    this.publishedSha256,
  });

  final String fileName;

  /// Tried in order; all HTTPS.
  final List<Uri> urls;

  /// Human label: "GitHub release v15.0.1", "ota.tasmota.com"...
  final String origin;

  /// Release version without a leading "v", when known.
  final String version;

  /// SHA-256 published by the release (GitHub asset digest), when known.
  final String? publishedSha256;
}

class OtaException implements Exception {
  OtaException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Finds, downloads and flashes firmware. All firmware downloads are
/// HTTPS-only with a size cap; the upload to the device is plain HTTP
/// because Tasmota and OpenBeken have no TLS on their web server.
class OtaService {
  OtaService({http.Client? client, TasmotaApi? api})
      : _client = client ?? http.Client(),
        api = api ?? TasmotaApi();

  final http.Client _client;
  final TasmotaApi api;

  static const maxFirmwareBytes = 8 * 1024 * 1024;
  static const _tasmotaRepo = 'arendst/Tasmota';
  static const _obkRepo = 'openshwprojects/OpenBK7231T_App';

  // ---- device info --------------------------------------------------------

  /// Reads Status 2 (firmware) and, on Tasmota, Status 4 (free space).
  ///
  /// Tasmota's minimal build answers /cm with an empty `{}` (it builds the
  /// reply from its log, which minimal keeps quiet), so the version then
  /// comes from the footer of its web page instead. [hardwareHint] fills the
  /// chip name the minimal build cannot report.
  Future<FwTarget> readTarget(Device d, String? password,
      {String hardwareHint = ''}) async {
    final s2 = await api.send(d.host, 'Status 2',
        username: d.username, password: password);
    final fwr = s2['StatusFWR'] is Map
        ? Map<String, dynamic>.from(s2['StatusFWR'] as Map)
        : <String, dynamic>{};
    var version = '${fwr['Version'] ?? ''}';
    var hardware = '${fwr['Hardware'] ?? ''}';
    if (version.isEmpty && d.type != FirmwareType.openbeken) {
      version = await _versionFromWebPage(d, password) ?? '';
    }
    if (hardware.isEmpty) hardware = hardwareHint;
    int? free;
    if (d.type != FirmwareType.openbeken) {
      try {
        final s4 = await api.send(d.host, 'Status 4',
            username: d.username, password: password);
        final mem = s4['StatusMEM'];
        if (mem is Map && mem['Free'] is num) {
          free = (mem['Free'] as num).toInt();
        }
      } catch (_) {}
    }
    return FwTarget(
      type: d.type,
      hardware: hardware,
      version: version,
      freeSketchKb: free,
    );
  }

  /// "Tasmota 15.6.0 (release-minimal) by Theo Arends" -> "15.6.0(release-minimal)".
  Future<String?> _versionFromWebPage(Device d, String? password) async {
    try {
      final res = await _client
          .get(_url(d, '/'), headers: _auth(d, password))
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      return parseTasmotaFooter(res.body);
    } catch (_) {
      return null;
    }
  }

  static String? parseTasmotaFooter(String html) {
    final m = RegExp(r'Tasmota\s+(\d+\.\d+\.\d+(?:\.\d+)?)\s*\(([^)]+)\)')
        .firstMatch(html);
    return m == null ? null : '${m[1]}(${m[2]})';
  }

  // ---- official sources ---------------------------------------------------

  Future<Map<String, dynamic>?> _latestRelease(String repo) async {
    try {
      final res = await _client.get(
          Uri.https('api.github.com', '/repos/$repo/releases/latest'),
          headers: {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'TasmoHub',
          }).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body);
      return j is Map ? Map<String, dynamic>.from(j) : null;
    } catch (_) {
      return null;
    }
  }

  static (Uri, String?)? _asset(Map<String, dynamic>? rel, String name) {
    for (final a in (rel?['assets'] as List? ?? const [])) {
      if (a is Map && a['name'] == name) {
        final url = Uri.tryParse('${a['browser_download_url']}');
        if (url == null || url.scheme != 'https') return null;
        return (url, normalizeDigest(a['digest'] as String?));
      }
    }
    return null;
  }

  static String _tag(Map<String, dynamic>? rel) =>
      '${rel?['tag_name'] ?? ''}'.replaceFirst(RegExp(r'^v'), '');

  /// The latest release build matching the device's chip and variant.
  Future<FirmwareSource> officialFirmware(FwTarget t, {String? variant}) async {
    if (t.type == FirmwareType.openbeken) return _officialObk(t);
    final v = variant ?? t.tasmotaVariant;
    final esp32 = t.isEsp32;
    final file = esp32 ? '$v.bin' : '$v.bin.gz';
    final rel = await _latestRelease(_tasmotaRepo);
    final version = _tag(rel);
    final asset = _asset(rel, file);
    final dir = esp32 ? 'tasmota32' : 'tasmota';
    final fallback = [
      Uri.https('ota.tasmota.com', '/$dir/release/$file'),
      Uri.https('raw.githubusercontent.com',
          '/arendst/Tasmota-firmware/firmware/release-firmware/$dir/$file'),
    ];
    if (asset != null) {
      return FirmwareSource(
        fileName: file,
        urls: [asset.$1, ...fallback],
        origin: 'GitHub release v$version',
        version: version,
        publishedSha256: asset.$2,
      );
    }
    return FirmwareSource(
      fileName: file,
      urls: fallback,
      origin: 'Tasmota OTA server',
      version: version,
    );
  }

  /// ESP8266 minimal build, used when the full image does not fit.
  FirmwareSource tasmotaMinimal() => FirmwareSource(
        fileName: 'tasmota-minimal.bin.gz',
        urls: [
          Uri.https(
              'ota.tasmota.com', '/tasmota/release/tasmota-minimal.bin.gz'),
          Uri.https(
              'raw.githubusercontent.com',
              '/arendst/Tasmota-firmware/firmware/release-firmware/tasmota/'
                  'tasmota-minimal.bin.gz'),
        ],
        origin: 'Tasmota OTA server',
      );

  Future<FirmwareSource> _officialObk(FwTarget t) async {
    final platform = t.obkPlatform;
    final suffix = obkOtaSuffix(platform);
    if (platform.isEmpty || suffix == null) {
      throw OtaException('No automatic download for "${t.version}". '
          'Pick the OTA file from the OpenBeken release page instead.');
    }
    final rel = await _latestRelease(_obkRepo);
    if (rel == null) {
      throw OtaException('Could not reach GitHub to find the latest release');
    }
    final version = _tag(rel);
    final name = '${platform}_$version$suffix';
    final asset = _asset(rel, name);
    if (asset == null) {
      throw OtaException('Release $version has no file named $name');
    }
    return FirmwareSource(
      fileName: name,
      urls: [asset.$1],
      origin: 'GitHub release $version',
      version: version,
      publishedSha256: asset.$2,
    );
  }

  /// Downloads over HTTPS only, following redirects, with a size cap.
  Future<Uint8List> download(FirmwareSource src,
      {void Function(int received, int? total)? onProgress}) async {
    Object? lastError;
    for (final url in src.urls) {
      if (url.scheme != 'https') continue;
      try {
        return await _downloadOne(url, onProgress);
      } catch (e) {
        lastError = e;
      }
    }
    throw OtaException('Download failed: $lastError');
  }

  Future<Uint8List> _downloadOne(
      Uri url, void Function(int, int?)? onProgress) async {
    // Redirects are followed by hand so every hop is checked for HTTPS
    // (GitHub release assets redirect to a CDN host).
    http.StreamedResponse res;
    var hops = 0;
    while (true) {
      if (url.scheme != 'https') {
        throw OtaException('Refused a non-HTTPS address: ${url.host}');
      }
      final req = http.Request('GET', url)
        ..headers['User-Agent'] = 'TasmoHub'
        ..followRedirects = false;
      res = await _client.send(req).timeout(const Duration(seconds: 30));
      final loc = res.headers['location'];
      if (res.statusCode >= 300 && res.statusCode < 400 && loc != null) {
        await res.stream.drain<void>();
        if (++hops > 5) throw OtaException('Too many redirects');
        url = url.resolve(loc);
        continue;
      }
      break;
    }
    if (res.statusCode != 200) throw OtaException('HTTP ${res.statusCode}');
    final total = res.contentLength;
    if (total != null && total > maxFirmwareBytes) {
      throw OtaException('File is too large ($total bytes)');
    }
    final out = BytesBuilder(copy: false);
    await for (final chunk in res.stream.timeout(const Duration(seconds: 30))) {
      out.add(chunk);
      if (out.length > maxFirmwareBytes) {
        throw OtaException('File is too large');
      }
      onProgress?.call(out.length, total);
    }
    final bytes = out.takeBytes();
    if (total != null && bytes.length != total) {
      throw OtaException('Download incomplete');
    }
    return bytes;
  }

  // ---- flashing -----------------------------------------------------------

  /// Basic auth plus the Referer a browser would send: Tasmota's
  /// privileged pages (/u4, /up, /u2) drop requests whose Referer is not the
  /// device itself unless SetOption128 allows API access, and /u2 then
  /// writes the image but never answers or restarts.
  Map<String, String> _auth(Device d, String? password) {
    final headers = {'Referer': 'http://${d.host}/up'};
    if (password == null || password.isEmpty) return headers;
    final user = d.username.isEmpty ? 'admin' : d.username;
    return {
      ...headers,
      'Authorization': 'Basic ${base64Encode(utf8.encode('$user:$password'))}',
    };
  }

  Uri _url(Device d, String path, [Map<String, String>? q]) {
    final parts = d.host.split(':');
    return Uri(
        scheme: 'http',
        host: parts[0],
        port: parts.length > 1 ? int.tryParse(parts[1]) : null,
        path: path,
        queryParameters: q);
  }

  /// Uploads [payload] through Tasmota's own web upgrade endpoint
  /// (the same requests its "Upgrade by file upload" page makes).
  Future<void> flashTasmota(
    Device d,
    String? password,
    Uint8List payload,
    String fileName, {
    required bool esp32,
    void Function(String step)? onStep,
  }) async {
    final auth = _auth(d, password);

    if (esp32 && payload.isNotEmpty && payload[0] == 0xE9) {
      // Devices with a safeboot partition must restart into it first.
      // /u4?u4=fct&api= answers "none" (dual OTA partitions: go ahead),
      // "true" (already in safeboot) or "false" (restarting into safeboot).
      // Some safeboot builds never answer "true" here (seen on a
      // POWR320D whose safeboot is 13.2.0), so once the device has been
      // asked to restart, its root page saying SAFEBOOT also counts.
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      var restarting = false;
      var last = 'no reply';
      while (true) {
        if (DateTime.now().isAfter(deadline)) {
          throw OtaException(
              'Device did not come back in safeboot mode (last reply: $last)');
        }
        String? answer;
        try {
          final res = await _client
              .get(_url(d, '/u4', {'u4': 'fct', 'api': ''}), headers: auth)
              .timeout(const Duration(seconds: 5));
          if (res.statusCode == 401) {
            throw OtaException('Web password rejected');
          }
          if (res.statusCode == 404) break; // older builds: no safeboot step
          answer = res.body.trim();
          last = 'HTTP ${res.statusCode} '
              '"${answer.length > 40 ? '${answer.substring(0, 40)}…' : answer}"';
        } on OtaException {
          rethrow;
        } on TimeoutException {
          last = 'timed out';
        } catch (e) {
          last = 'not reachable';
        }
        if (answer == 'none') break;
        if (answer == 'true') {
          // Same pause the device's own upload page makes.
          await Future<void>.delayed(const Duration(seconds: 1));
          break;
        }
        if (answer == 'false' || answer == null) restarting = true;
        if (restarting && answer != 'false' && await _showsSafeboot(d, auth)) {
          onStep?.call('Safeboot page found');
          await Future<void>.delayed(const Duration(seconds: 1));
          break;
        }
        onStep?.call('Restarting into safeboot mode…');
        await Future<void>.delayed(
            Duration(seconds: answer == 'false' ? 6 : 2));
      }
    }

    onStep?.call('Preparing upload…');
    final http.Response prep;
    try {
      prep = await _client
          .get(_url(d, '/up'), headers: auth)
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      throw OtaException('Device did not answer its upgrade page');
    }
    if (prep.statusCode == 401) throw OtaException('Web password rejected');
    if (prep.statusCode != 200) {
      throw OtaException('Device refused the upgrade page '
          '(HTTP ${prep.statusCode})');
    }

    onStep?.call('Uploading ${(payload.length / 1024).round()} KB…');
    final status =
        await _postUpload(d, auth, payload, fileName.split('/').last);
    if (status == null) {
      // The whole file was sent but the reply was unreadable (Tasmota
      // restarts right after answering). The version check after the
      // restart decides whether it worked.
      onStep?.call('Upload sent; waiting for the device…');
      return;
    }
    final (code, body) = status;
    if (code == 401) throw OtaException('Web password rejected');
    final text = body.replaceAll(RegExp(r'<[^>]+>'), ' ');
    if (RegExp(r'\bFailed\b', caseSensitive: false).hasMatch(text)) {
      final m =
          RegExp(r'Failed\s+(.{0,80})', caseSensitive: false).firstMatch(text);
      throw OtaException(
          'Device rejected the file: ${m?.group(1)?.trim() ?? 'upload failed'}');
    }
    if (code != 200) throw OtaException('Upload failed (HTTP $code)');
    onStep?.call('Upload sent; waiting for the device…');
  }

  /// True when the device's main page is Tasmota's safeboot page.
  Future<bool> _showsSafeboot(Device d, Map<String, String> auth) async {
    try {
      final res = await _client
          .get(_url(d, '/'), headers: auth)
          .timeout(const Duration(seconds: 5));
      return res.statusCode == 200 && isSafebootPage(res.body);
    } catch (_) {
      return false;
    }
  }

  /// Multipart POST to /u2 over a raw socket with HTTP/1.0.
  ///
  /// Tasmota's ESP8266 web server answers HTTP/1.1 uploads with chunked
  /// framing that strict clients reject ("Failed to parse HTTP"), and it
  /// restarts straight after. HTTP/1.0 makes it send a plain body and close.
  /// Returns null when the file was sent but no readable reply came back.
  Future<(int, String)?> _postUpload(Device d, Map<String, String> auth,
      Uint8List payload, String fileName) async {
    final url = _url(d, '/u2', {'fsz': '${payload.length}'});
    final boundary =
        '----TasmoHub${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
    final safeName = fileName.replaceAll(RegExp(r'["\r\n]'), '_');
    final head = latin1.encode('--$boundary\r\n'
        'Content-Disposition: form-data; name="u2"; filename="$safeName"\r\n'
        'Content-Type: application/octet-stream\r\n\r\n');
    final tail = latin1.encode('\r\n--$boundary--\r\n');
    final length = head.length + payload.length + tail.length;
    final request = StringBuffer()
      ..write('POST ${url.path}?${url.query} HTTP/1.0\r\n')
      ..write('Host: ${url.host}${url.hasPort ? ':${url.port}' : ''}\r\n')
      ..write('User-Agent: TasmoHub\r\n')
      ..write('Connection: close\r\n')
      ..write('Content-Type: multipart/form-data; boundary=$boundary\r\n')
      ..write('Content-Length: $length\r\n');
    auth.forEach((k, v) => request.write('$k: $v\r\n'));
    request.write('\r\n');

    final socket = await Socket.connect(url.host, url.port,
        timeout: const Duration(seconds: 10));
    final reply = BytesBuilder(copy: false);
    final done = Completer<void>();
    socket.listen(reply.add,
        onDone: () => done.isCompleted ? null : done.complete(),
        onError: (_) => done.isCompleted ? null : done.complete(),
        cancelOnError: true);
    try {
      socket.add(latin1.encode(request.toString()));
      socket.add(head);
      // Small slices keep memory flat and let a slow ESP keep up.
      const slice = 4096;
      for (var i = 0; i < payload.length; i += slice) {
        socket.add(payload.sublist(i, (i + slice).clamp(0, payload.length)));
        await socket.flush().timeout(const Duration(minutes: 2));
      }
      socket.add(tail);
      await socket.flush().timeout(const Duration(minutes: 2));
    } catch (e) {
      socket.destroy();
      if (reply.isNotEmpty) return _parseReply(reply.takeBytes());
      throw OtaException('Upload interrupted: $e');
    }
    await done.future.timeout(const Duration(minutes: 2), onTimeout: () {});
    socket.destroy();
    return _parseReply(reply.takeBytes());
  }

  static (int, String)? _parseReply(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    final text = latin1.decode(bytes, allowInvalid: true);
    final m = RegExp(r'^HTTP/1\.[01] (\d{3})').firstMatch(text);
    if (m == null) return null;
    final split = text.indexOf('\r\n\r\n');
    return (int.parse(m[1]!), split < 0 ? '' : text.substring(split + 4));
  }

  /// Reads an OpenBeken plug's startup command from its /startup_command page.
  /// Returns null when the page cannot be read.
  Future<String?> obkStartupCommand(Device d, String? password) async {
    try {
      final res = await _client
          .get(_url(d, '/startup_command'), headers: _auth(d, password))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      return res.body;
    } catch (_) {
      return null;
    }
  }

  /// OpenBeken: raw body to /api/ota, then /api/reboot.
  Future<void> flashObk(Device d, String? password, Uint8List payload,
      {void Function(String step)? onStep}) async {
    final auth = _auth(d, password);
    onStep?.call('Uploading ${(payload.length / 1024).round()} KB…');
    final res = await _client
        .post(_url(d, '/api/ota'),
            headers: {...auth, 'Content-Type': 'application/octet-stream'},
            body: payload)
        .timeout(const Duration(minutes: 4));
    if (res.statusCode == 401) throw OtaException('Password rejected');
    if (res.statusCode != 200 || res.body.contains('"error"')) {
      throw OtaException('Device rejected the upload: ${res.body.trim()}');
    }
    onStep?.call('Rebooting…');
    try {
      await _client
          .post(_url(d, '/api/reboot'), headers: auth)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // It may drop the connection while rebooting.
    }
  }

  /// Asks a Tasmota device to restart (used to leave safeboot once the new
  /// image is in place). Errors are ignored: it drops the connection.
  Future<void> restart(Device d, String? password) async {
    try {
      await _client
          .get(_url(d, '/cm', {'cmnd': 'Restart 1'}),
              headers: _auth(d, password))
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  /// Waits for the device to answer again and returns its firmware version.
  Future<FwTarget> waitForDevice(Device d, String? password,
      {Duration timeout = const Duration(minutes: 4),
      String hardwareHint = '',
      void Function(String step)? onStep}) async {
    final deadline = DateTime.now().add(timeout);
    await Future<void>.delayed(const Duration(seconds: 8));
    FwTarget? last;
    while (DateTime.now().isBefore(deadline)) {
      try {
        last = await readTarget(d, password, hardwareHint: hardwareHint);
        // Right after boot the reply can still be empty; wait for a version.
        if (last.version.isNotEmpty) return last;
      } catch (_) {}
      onStep?.call('Waiting for the device to restart…');
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    if (last != null) return last;
    throw OtaException('Device did not come back online. If it does not '
        'appear within a few minutes, power-cycle it.');
  }

  void close() => _client.close();
}

/// Tasmota's safeboot build shows "SAFEBOOT" above the device name and
/// "(release-safeboot)" style text in the footer on newer builds.
bool isSafebootPage(String html) =>
    RegExp(r'>\s*SAFEBOOT\s*<|release-safeboot').hasMatch(html);
