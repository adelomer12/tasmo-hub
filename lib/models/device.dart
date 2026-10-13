import 'dart:convert';

/// Firmware family. OpenBeken exposes a Tasmota-compatible `/cm` HTTP API,
/// so both are driven through the same client; the type only changes
/// labels and a few heuristics.
enum FirmwareType { tasmota, openbeken, unknown }

FirmwareType firmwareTypeFromName(String? name) => FirmwareType.values
    .firstWhere((t) => t.name == name, orElse: () => FirmwareType.unknown);

String firmwareLabel(FirmwareType t) => switch (t) {
      FirmwareType.tasmota => 'Tasmota',
      FirmwareType.openbeken => 'OpenBeken',
      FirmwareType.unknown => 'Tasmota-compatible',
    };

/// Persisted device configuration. Credentials are NOT part of this object's
/// JSON; they live in the platform keystore (see DeviceStore).
class Device {
  Device({
    required this.id,
    required this.host,
    required this.name,
    this.room = '',
    this.type = FirmwareType.unknown,
    this.username = 'admin',
    this.mac = '',
  });

  /// Stable id: MAC when known (survives DHCP changes), otherwise host.
  final String id;
  String host;
  String name;
  String room;
  FirmwareType type;
  String username;
  String mac;

  Map<String, dynamic> toJson() => {
        'id': id,
        'host': host,
        'name': name,
        'room': room,
        'type': type.name,
        'username': username,
        'mac': mac,
      };

  factory Device.fromJson(Map<String, dynamic> j) => Device(
        id: j['id'] as String,
        host: j['host'] as String,
        name: (j['name'] as String?) ?? j['host'] as String,
        room: (j['room'] as String?) ?? '',
        type: firmwareTypeFromName(j['type'] as String?),
        username: (j['username'] as String?) ?? 'admin',
        mac: (j['mac'] as String?) ?? '',
      );

  static String encodeList(List<Device> list) =>
      jsonEncode(list.map((d) => d.toJson()).toList());

  static List<Device> decodeList(String s) => (jsonDecode(s) as List)
      .map((e) => Device.fromJson(Map<String, dynamic>.from(e as Map)))
      .toList();
}

/// One sensor value flattened out of StatusSNS, e.g. ("AM2301", "Temperature", 23.4).
class SensorReading {
  const SensorReading(this.group, this.key, this.value, this.unit);
  final String group;
  final String key;
  final Object? value;
  final String unit;

  String get display {
    final v = value;
    final s = v is double ? v.toStringAsFixed(v.abs() < 10 ? 2 : 1) : '$v';
    return unit.isEmpty ? s : '$s $unit';
  }
}

/// Live state parsed from a `Status 0` response (plus later command results).
class DeviceState {
  DeviceState({this.online = false, this.authRequired = false, this.error});

  bool online;
  bool authRequired;
  String? error;
  DateTime? updated;

  /// Relay key (POWER, POWER1, POWER2...) -> on/off.
  final Map<String, bool> power = {};
  int? dimmer;
  int? ct;

  /// Hue 0-360, Sat 0-100, Bri 0-100.
  List<int>? hsb;
  List<SensorReading> sensors = [];

  String friendlyName = '';
  String deviceName = '';
  String version = '';
  String hardware = '';
  String ip = '';
  String mac = '';
  String hostname = '';
  String uptime = '';
  int? rssi;
  int? signal;
  String ssid = '';
  int? module;

  bool get hasLight => dimmer != null || hsb != null || ct != null;

  /// Sorted relay keys so POWER1 < POWER2 < POWER10.
  List<String> get relayKeys {
    final keys = power.keys.toList();
    int n(String k) => int.tryParse(k.substring(5)) ?? 0;
    keys.sort((a, b) => n(a).compareTo(n(b)));
    return keys;
  }

  bool get anyOn => power.values.any((v) => v);

  /// Merge a JSON object from either a Status section or a command reply.
  void applyStateJson(Map<String, dynamic> j) {
    for (final e in j.entries) {
      final k = e.key.toUpperCase();
      if (RegExp(r'^POWER\d*$').hasMatch(k)) {
        final v = e.value;
        if (v is String) power[k] = v.toUpperCase() == 'ON';
        if (v is num) power[k] = v != 0;
      }
    }
    final d = j['Dimmer'];
    if (d is num) dimmer = d.toInt();
    final c = j['CT'];
    if (c is num) ct = c.toInt();
    final h = j['HSBColor'];
    if (h is String) {
      final parts = h.split(',').map((p) => int.tryParse(p.trim())).toList();
      if (parts.length == 3 && !parts.contains(null)) {
        hsb = parts.cast<int>();
      }
    }
    final w = j['Wifi'];
    if (w is Map) {
      final r = w['RSSI'];
      if (r is num) rssi = r.toInt();
      final s = w['Signal'];
      if (s is num) signal = s.toInt();
      final ss = w['SSId'];
      if (ss is String) ssid = ss;
    }
    final up = j['Uptime'];
    if (up is String) uptime = up;
  }
}
