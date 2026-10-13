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
    this.mqttTopic = '',
    this.fullTopic = '',
    this.prefixes = const ['cmnd', 'stat', 'tele'],
    this.locked = false,
  });

  /// Stable id: MAC when known (survives DHCP changes), otherwise host.
  final String id;
  String host;
  String name;
  String room;
  FirmwareType type;
  String username;
  String mac;

  /// Tasmota `Topic` (e.g. tasmota_A1B2C3). Empty = not usable over MQTT.
  String mqttTopic;

  /// Tasmota `FullTopic`; empty means the default `%prefix%/%topic%/`.
  String fullTopic;

  /// cmnd / stat / tele prefixes (Prefix1..3), in that order.
  List<String> prefixes;

  /// App-side switch lock: relays cannot be toggled from this app (guards
  /// against accidental taps on e.g. a fridge or server plug).
  bool locked;

  String get cmndPrefix => prefixes[0];
  String get statPrefix => prefixes[1];
  String get telePrefix => prefixes[2];

  Map<String, dynamic> toJson() => {
        'id': id,
        'host': host,
        'name': name,
        'room': room,
        'type': type.name,
        'username': username,
        'mac': mac,
        'mqttTopic': mqttTopic,
        'fullTopic': fullTopic,
        'prefixes': prefixes,
        'locked': locked,
      };

  factory Device.fromJson(Map<String, dynamic> j) => Device(
        id: j['id'] as String,
        host: j['host'] as String,
        name: (j['name'] as String?) ?? j['host'] as String,
        room: (j['room'] as String?) ?? '',
        type: firmwareTypeFromName(j['type'] as String?),
        username: (j['username'] as String?) ?? 'admin',
        mac: (j['mac'] as String?) ?? '',
        mqttTopic: (j['mqttTopic'] as String?) ?? '',
        fullTopic: (j['fullTopic'] as String?) ?? '',
        prefixes: (j['prefixes'] is List && (j['prefixes'] as List).length >= 3)
            ? (j['prefixes'] as List).map((e) => '$e').toList()
            : const ['cmnd', 'stat', 'tele'],
        locked: j['locked'] == true,
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

  /// Last update came from MQTT rather than HTTP.
  bool viaMqtt = false;

  /// From the retained `tele/<topic>/LWT` (null = unknown).
  bool? lwtOnline;
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
  String topic = '';
  int? module;

  /// One name per relay (Status.FriendlyName), used to label timer outputs.
  List<String> friendlyNames = [];

  /// Raw StatusSNS.ENERGY, kept for the energy card (TotalStartTime etc.).
  Map<String, dynamic> energy = {};

  /// Device local time from StatusTIM.Local / STATE.Time ("2026-10-13T18:51:02").
  String deviceTime = '';

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
    final t = j['Time'];
    if (t is String && t.contains('T')) deviceTime = t;
  }
}
