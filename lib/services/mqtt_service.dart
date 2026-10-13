import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Broker settings. The password is kept in the platform keystore.
class MqttSettings {
  MqttSettings({
    this.enabled = false,
    this.host = '',
    this.port = 1883,
    this.tls = false,
    this.allowSelfSigned = false,
    this.username = '',
    this.password = '',
    this.preferMqtt = true,
    String? clientId,
  }) : clientId = clientId ?? 'tasmohub-${_randomSuffix()}';

  bool enabled;
  String host;
  int port;
  bool tls;

  /// Only for a home-lab broker with a self-signed cert. Off by default:
  /// accepting any certificate removes TLS's protection against MITM.
  bool allowSelfSigned;
  String username;
  String password;

  /// Route commands/refreshes over MQTT when connected (needed when the
  /// devices sit on a VLAN the phone cannot reach over HTTP).
  bool preferMqtt;
  String clientId;

  static String _randomSuffix() {
    final r = Random.secure();
    return List.generate(6, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  static const _prefsKey = 'mqtt_v1';
  static const _pwKey = 'mqtt_password';

  static Future<MqttSettings> load(FlutterSecureStorage secure) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    final s = MqttSettings();
    if (raw != null) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        s
          ..enabled = j['enabled'] == true
          ..host = (j['host'] as String?) ?? ''
          ..port = (j['port'] as int?) ?? 1883
          ..tls = j['tls'] == true
          ..allowSelfSigned = j['allowSelfSigned'] == true
          ..username = (j['username'] as String?) ?? ''
          ..preferMqtt = j['preferMqtt'] != false
          ..clientId = (j['clientId'] as String?) ?? s.clientId;
      } catch (_) {}
    }
    try {
      s.password = await secure.read(key: _pwKey) ?? '';
    } catch (_) {}
    return s;
  }

  Future<void> save(FlutterSecureStorage secure) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey,
        jsonEncode({
          'enabled': enabled,
          'host': host,
          'port': port,
          'tls': tls,
          'allowSelfSigned': allowSelfSigned,
          'username': username,
          'preferMqtt': preferMqtt,
          'clientId': clientId,
        }));
    if (password.isEmpty) {
      await secure.delete(key: _pwKey);
    } else {
      await secure.write(key: _pwKey, value: password);
    }
  }
}

/// Tasmota topic helpers. FullTopic defaults to `%prefix%/%topic%/`
/// and the prefixes to cmnd / stat / tele.
class TasmotaTopics {
  static const defaultFullTopic = '%prefix%/%topic%/';

  static String build(String fullTopic, String prefix, String topic,
      [String command = '']) {
    var ft = fullTopic.isEmpty ? defaultFullTopic : fullTopic;
    if (!ft.endsWith('/')) ft = '$ft/';
    return ft
            .replaceAll('%prefix%', prefix)
            .replaceAll('%topic%', topic)
            .replaceAll('%hostname%', topic)
            .replaceAll('%id%', topic) +
        command;
  }

  /// Splits an incoming topic using the device's FullTopic, returning the
  /// prefix and the trailing part (e.g. "RESULT", "POWER1", "LWT").
  static ({String prefix, String suffix})? match(
      String fullTopic, String deviceTopic, String incoming) {
    var ft = fullTopic.isEmpty ? defaultFullTopic : fullTopic;
    if (!ft.endsWith('/')) ft = '$ft/';
    final pattern = RegExp.escape(ft)
        .replaceAll('%prefix%', '([^/]+)')
        .replaceAll(
            RegExp(r'%topic%|%hostname%|%id%'), RegExp.escape(deviceTopic));
    final m = RegExp('^$pattern(.+)\$').firstMatch(incoming);
    if (m == null) return null;
    return (prefix: m.group(1)!, suffix: m.group(2)!);
  }

  /// Subscription filter covering one prefix of one device.
  static String filter(String fullTopic, String prefix, String topic) =>
      '${build(fullTopic, prefix, topic)}#';
}

/// One message from the broker.
class MqttIncoming {
  MqttIncoming(this.topic, this.payload, {this.retained = false});
  final String topic;
  final String payload;
  final bool retained;
}

enum MqttLinkState { disabled, connecting, connected, error }

/// Owns the broker connection. Topic interpretation lives in DeviceStore,
/// which knows the devices; this class only connects, subscribes and
/// publishes.
class MqttService extends ChangeNotifier {
  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _sub;
  final Set<String> _subscribed = {};
  final _incoming = StreamController<MqttIncoming>.broadcast();

  MqttLinkState state = MqttLinkState.disabled;
  String? lastError;

  Stream<MqttIncoming> get messages => _incoming.stream;
  bool get isConnected => state == MqttLinkState.connected;

  Future<void> connect(MqttSettings s) async {
    await disconnect();
    if (!s.enabled || s.host.trim().isEmpty) {
      state = MqttLinkState.disabled;
      notifyListeners();
      return;
    }
    state = MqttLinkState.connecting;
    lastError = null;
    notifyListeners();

    final c = MqttServerClient.withPort(s.host.trim(), s.clientId, s.port)
      ..logging(on: false)
      ..keepAlivePeriod = 30
      ..connectTimeoutPeriod = 5000
      ..autoReconnect = true
      ..resubscribeOnAutoReconnect = true
      ..secure = s.tls
      ..setProtocolV311();
    if (s.tls && s.allowSelfSigned) {
      c.onBadCertificate = (X509Certificate _) => true;
    }
    c.connectionMessage =
        MqttConnectMessage().withClientIdentifier(s.clientId).startClean();
    c.onDisconnected = () {
      if (state == MqttLinkState.connected) {
        state = MqttLinkState.connecting; // auto-reconnect in progress
        notifyListeners();
      }
    };
    c.onAutoReconnected = () {
      state = MqttLinkState.connected;
      notifyListeners();
    };
    _client = c;
    try {
      await c.connect(s.username.isEmpty ? null : s.username,
          s.password.isEmpty ? null : s.password);
    } catch (e) {
      lastError = '$e';
    }
    if (c.connectionStatus?.state != MqttConnectionState.connected) {
      lastError ??= 'Broker refused: ${c.connectionStatus?.returnCode}';
      state = MqttLinkState.error;
      c.autoReconnect = false;
      c.disconnect();
      _client = null;
      notifyListeners();
      return;
    }
    _sub = c.updates?.listen((events) {
      for (final e in events) {
        final msg = e.payload;
        if (msg is! MqttPublishMessage) continue;
        final payload = utf8.decode(msg.payload.message, allowMalformed: true);
        _incoming.add(MqttIncoming(e.topic, payload,
            retained: msg.header?.retain ?? false));
      }
    });
    state = MqttLinkState.connected;
    notifyListeners();
  }

  /// Makes the subscription set equal to [filters].
  void setSubscriptions(Set<String> filters) {
    final c = _client;
    if (c == null || !isConnected) return;
    for (final f in _subscribed.difference(filters)) {
      c.unsubscribe(f);
    }
    for (final f in filters.difference(_subscribed)) {
      c.subscribe(f, MqttQos.atMostOnce);
    }
    _subscribed
      ..clear()
      ..addAll(filters);
  }

  bool publish(String topic, String payload) {
    final c = _client;
    if (c == null || !isConnected) return false;
    final b = MqttClientPayloadBuilder()..addUTF8String(payload);
    c.publishMessage(topic, MqttQos.atLeastOnce, b.payload!);
    return true;
  }

  Future<void> disconnect() async {
    await _sub?.cancel();
    _sub = null;
    _subscribed.clear();
    final c = _client;
    _client = null;
    if (c != null) {
      c.autoReconnect = false;
      try {
        c.disconnect();
      } catch (_) {}
    }
    state = MqttLinkState.disabled;
  }

  @override
  void dispose() {
    disconnect();
    _incoming.close();
    super.dispose();
  }
}

/// Parsed `tasmota/discovery/<MAC>/config` payload (Tasmota native discovery,
/// SetOption19 0, retained). Lets the app find devices on other VLANs
/// through the broker without any HTTP scan.
class TasmotaDiscoveryInfo {
  TasmotaDiscoveryInfo({
    required this.mac,
    required this.ip,
    required this.topic,
    required this.fullTopic,
    required this.name,
    required this.version,
    required this.prefixes,
  });

  final String mac;
  final String ip;
  final String topic;
  final String fullTopic;
  final String name;
  final String version;
  final List<String> prefixes;

  static TasmotaDiscoveryInfo? parse(String payload) {
    try {
      final j = jsonDecode(payload);
      if (j is! Map) return null;
      final t = j['t'];
      if (t is! String || t.isEmpty) return null;
      final fn = j['fn'];
      String name = '${j['dn'] ?? ''}';
      if (name.isEmpty && fn is List && fn.isNotEmpty && fn.first != null) {
        name = '${fn.first}';
      }
      final tp = j['tp'];
      return TasmotaDiscoveryInfo(
        mac: formatMac('${j['mac'] ?? ''}'),
        ip: '${j['ip'] ?? ''}',
        topic: t,
        fullTopic: (j['ft'] as String?) ?? TasmotaTopics.defaultFullTopic,
        name: name.isEmpty ? t : name,
        version: '${j['sw'] ?? ''}',
        prefixes: tp is List && tp.length >= 3
            ? tp.map((e) => '$e').toList()
            : const ['cmnd', 'stat', 'tele'],
      );
    } catch (_) {
      return null;
    }
  }
}

/// "AABBCC112233" or "aa:bb:cc:11:22:33" -> "AA:BB:CC:11:22:33".
String formatMac(String raw) {
  final hex = raw.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '').toUpperCase();
  if (hex.length != 12) return raw.toUpperCase();
  return [for (var i = 0; i < 12; i += 2) hex.substring(i, i + 2)].join(':');
}
