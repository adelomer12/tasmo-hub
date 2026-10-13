import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/device.dart';

class AuthRequiredException implements Exception {
  @override
  String toString() => 'Device requires a web password';
}

class DeviceApiException implements Exception {
  DeviceApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Thin client for the Tasmota `/cm?cmnd=` HTTP API, which OpenBeken
/// implements too. Everything is local HTTP: no cloud, no telemetry.
///
/// Security note: Tasmota only accepts credentials as query parameters on
/// plain HTTP, so the password crosses the LAN in clear text. Keep IoT
/// devices on an isolated VLAN and never port-forward them.
class TasmotaApi {
  TasmotaApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Uri buildUri(String host, String command,
      {String? username, String? password}) {
    final hostPart = host.contains(':') ? host.split(':') : [host];
    final port = hostPart.length > 1 ? int.tryParse(hostPart[1]) : null;
    return Uri(
      scheme: 'http',
      host: hostPart[0],
      port: port,
      path: '/cm',
      queryParameters: {
        if (password != null && password.isNotEmpty) ...{
          'user': (username == null || username.isEmpty) ? 'admin' : username,
          'password': password,
        },
        'cmnd': command,
      },
    );
  }

  /// Sends one command and returns the decoded JSON object.
  /// Several commands can be chained with `Backlog cmd1; cmd2`.
  Future<Map<String, dynamic>> send(
    String host,
    String command, {
    String? username,
    String? password,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final uri = buildUri(host, command, username: username, password: password);
    final http.Response res;
    try {
      res = await _client.get(uri).timeout(timeout);
    } on TimeoutException {
      throw DeviceApiException('Timed out');
    } catch (e) {
      throw DeviceApiException('Unreachable');
    }
    if (res.statusCode == 401) throw AuthRequiredException();
    if (res.statusCode != 200) {
      throw DeviceApiException('HTTP ${res.statusCode}');
    }
    final body = utf8.decode(res.bodyBytes, allowMalformed: true).trim();
    final dynamic decoded;
    try {
      decoded = jsonDecode(_sanitize(body));
    } catch (_) {
      throw DeviceApiException('Not a Tasmota JSON reply');
    }
    if (decoded is! Map) throw DeviceApiException('Unexpected reply');
    final map = Map<String, dynamic>.from(decoded);
    // Tasmota answers 200 + {"WARNING":"Need user=<username>&password=<password>"}
    final warn = map['WARNING'];
    if (warn is String && warn.toLowerCase().contains('need user')) {
      throw AuthRequiredException();
    }
    return map;
  }

  /// Some firmware builds emit `nan`/`inf` for broken sensors, which is not
  /// valid JSON. Replace them with null so the rest of the reply survives.
  static String _sanitize(String s) => s.replaceAllMapped(
      RegExp(r'(:\s*)(-?nan|-?inf)\b', caseSensitive: false),
      (m) => '${m[1]}null');

  /// Fetches the full status (`Status 0`) and parses it into a DeviceState.
  Future<DeviceState> fetchState(String host,
      {String? username, String? password}) async {
    final j =
        await send(host, 'Status 0', username: username, password: password);
    return parseStatus0(j);
  }

  /// Fetches the root web page; used only to tell OpenBeken from Tasmota
  /// when the status JSON is ambiguous.
  Future<String?> fetchIndex(String host) async {
    try {
      final res = await _client
          .get(Uri.parse('http://$host/'))
          .timeout(const Duration(seconds: 3));
      return res.body;
    } catch (_) {
      return null;
    }
  }

  void close() => _client.close();
}

DeviceState parseStatus0(Map<String, dynamic> j) {
  final s = DeviceState(online: true)..updated = DateTime.now();

  Map<String, dynamic> sec(String k) {
    final v = j[k];
    return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  }

  final status = sec('Status');
  final fn = status['FriendlyName'];
  if (fn is List && fn.isNotEmpty) {
    s.friendlyName = '${fn.first}';
    s.friendlyNames = [for (final n in fn) '${n ?? ''}'];
  }
  if (fn is String) s.friendlyName = fn;
  s.deviceName = '${status['DeviceName'] ?? ''}';
  s.topic = '${status['Topic'] ?? ''}';
  final mod = status['Module'];
  if (mod is num) s.module = mod.toInt();

  // Some (older/OpenBeken) builds report Power only as a bitmask in
  // Status.Power ("1" or "0101"); StatusSTS below overrides when present.
  final pw = status['Power'];
  if (pw is num || pw is String) {
    final str = '$pw';
    if (RegExp(r'^[01]+$').hasMatch(str)) {
      if (str.length == 1) {
        s.power['POWER'] = str == '1';
      } else {
        for (var i = 0; i < str.length; i++) {
          s.power['POWER${i + 1}'] = str[str.length - 1 - i] == '1';
        }
      }
    }
  }

  final sts = sec('StatusSTS');
  if (sts.isNotEmpty) {
    if (sts.keys.any((k) => RegExp(r'^POWER\d*$').hasMatch(k))) {
      s.power.clear();
    }
    s.applyStateJson(sts);
  }

  final fwr = sec('StatusFWR');
  s.version = '${fwr['Version'] ?? ''}';
  s.hardware = '${fwr['Hardware'] ?? ''}';

  final net = sec('StatusNET');
  s.ip = '${net['IPAddress'] ?? ''}';
  s.mac = '${net['Mac'] ?? ''}';
  s.hostname = '${net['Hostname'] ?? ''}';

  final prm = sec('StatusPRM');
  if (s.uptime.isEmpty && prm['Uptime'] is String) {
    s.uptime = prm['Uptime'] as String;
  }

  final tim = sec('StatusTIM');
  if (tim['Local'] is String) s.deviceTime = tim['Local'] as String;

  final sns = sec('StatusSNS');
  s.sensors = flattenSensors(sns);
  if (sns['ENERGY'] is Map) {
    s.energy = Map<String, dynamic>.from(sns['ENERGY'] as Map);
  }
  return s;
}

const _skipSensorKeys = {'Time', 'TempUnit', 'PressureUnit', 'SpeedUnit'};

String _unitFor(String key, Map<String, dynamic> root) {
  final k = key.toLowerCase();
  if (k.contains('temperature') || k == 'dewpoint') {
    return '°${root['TempUnit'] ?? 'C'}';
  }
  if (k.contains('humidity')) return '%';
  if (k.contains('pressure')) return '${root['PressureUnit'] ?? 'hPa'}';
  if (k == 'power' || k == 'apparentpower' || k == 'reactivepower') {
    return k == 'power' ? 'W' : (k == 'apparentpower' ? 'VA' : 'VAr');
  }
  if (k == 'voltage') return 'V';
  if (k == 'current') return 'A';
  if (k == 'total' || k == 'today' || k == 'yesterday') return 'kWh';
  if (k == 'illuminance') return 'lx';
  if (k == 'co2' || k == 'eco2') return 'ppm';
  if (k == 'frequency') return 'Hz';
  return '';
}

/// Flattens StatusSNS ({"AM2301":{"Temperature":21.3}, "ENERGY":{...}})
/// into a list of readings, one level deep, ignoring housekeeping keys.
List<SensorReading> flattenSensors(Map<String, dynamic> sns) {
  final out = <SensorReading>[];
  for (final e in sns.entries) {
    if (_skipSensorKeys.contains(e.key)) continue;
    final v = e.value;
    if (v is Map) {
      for (final inner in v.entries) {
        final iv = inner.value;
        if (iv is Map || iv is List) continue;
        if (inner.key == 'TotalStartTime' || inner.key == 'Id') continue;
        out.add(SensorReading(
            e.key,
            '${inner.key}',
            iv is int ? iv : (iv is num ? iv.toDouble() : iv),
            _unitFor('${inner.key}', sns)));
      }
    } else if (v is num || v is String || v is bool) {
      out.add(SensorReading('', e.key, v, _unitFor(e.key, sns)));
    }
  }
  return out;
}

/// Best-effort firmware detection from Status 0 (+ optional index page).
FirmwareType detectFirmware(DeviceState s, {String? indexHtml}) {
  final v = s.version.toLowerCase();
  final hw = s.hardware.toLowerCase();
  if (v.contains('tasmota')) return FirmwareType.tasmota;
  const obkChips = [
    'bk72',
    'bl602',
    'w800',
    'w600',
    'xr809',
    'ln882',
    'openbk'
  ];
  if (obkChips.any((c) => hw.contains(c) || v.contains(c))) {
    return FirmwareType.openbeken;
  }
  if (indexHtml != null) {
    final h = indexHtml.toLowerCase();
    if (h.contains('openbk') || h.contains('openbeken')) {
      return FirmwareType.openbeken;
    }
    if (h.contains('tasmota')) return FirmwareType.tasmota;
  }
  if (hw.startsWith('esp')) return FirmwareType.tasmota;
  return FirmwareType.unknown;
}
