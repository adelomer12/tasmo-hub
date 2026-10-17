import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';
import '../models/scene.dart';
import '../models/tasmota_rule.dart';
import '../models/tasmota_timer.dart';
import 'mqtt_service.dart';
import 'native_bridge.dart';
import 'tasmota_api.dart';

/// Owns the device list, credentials and live state, and keeps state fresh
/// through HTTP polling and/or MQTT push.
///
/// Device metadata goes to SharedPreferences; web and broker passwords go to
/// flutter_secure_storage (Android Keystore / iOS Keychain), never to
/// plain preferences or logs.
class DeviceStore extends ChangeNotifier {
  DeviceStore({TasmotaApi? api, MqttService? mqtt})
      : api = api ?? TasmotaApi(),
        mqtt = mqtt ?? MqttService() {
    this.mqtt.addListener(_onMqttLinkChanged);
    _mqttSub = this.mqtt.messages.listen(handleMqtt);
  }

  static const _prefsKey = 'devices_v1';
  static const _pwPrefix = 'pw_';
  static const _pollKey = 'poll_seconds';
  static const _scenesKey = 'scenes_v1';
  static const _roomOrderKey = 'room_order_v1';
  static const discoveryFilter = 'tasmota/discovery/+/config';

  final TasmotaApi api;
  final MqttService mqtt;
  final FlutterSecureStorage _secure = const FlutterSecureStorage();
  late final StreamSubscription<MqttIncoming> _mqttSub;

  final List<Device> _devices = [];
  final List<Scene> _scenes = [];

  /// Room order chosen by the user; rooms not listed follow alphabetically.
  List<String> _roomOrder = [];
  final Map<String, DeviceState> _state = {};
  final Map<String, String> _passwords = {};
  final Map<String, Completer<Map<String, dynamic>>> _pendingResult = {};
  final _results = StreamController<(String, Map<String, dynamic>)>.broadcast();

  /// Devices announced on `tasmota/discovery/#`, keyed by MAC.
  final Map<String, TasmotaDiscoveryInfo> mqttDiscovered = {};

  MqttSettings mqttSettings = MqttSettings();
  MqttLinkState _lastLink = MqttLinkState.disabled;
  Timer? _timer;
  bool _refreshing = false;
  int pollSeconds = 10;

  Timer? _nativeSync;

  /// Every UI change also refreshes the widget/tile copy (debounced; the
  /// bridge skips the call when nothing relevant changed).
  @override
  void notifyListeners() {
    super.notifyListeners();
    _nativeSync?.cancel();
    _nativeSync = Timer(const Duration(milliseconds: 800), () {
      NativeBridge.syncDevices(
        _devices,
        {for (final d in _devices) d.id: stateOf(d).relayKeys},
        Map.of(_passwords),
      );
    });
  }

  List<Device> get devices => List.unmodifiable(_devices);
  DeviceState stateOf(Device d) => _state[d.id] ??= DeviceState();
  String? passwordOf(Device d) => _passwords[d.id];

  List<String> get rooms {
    final present = _devices.map((d) => d.room.trim()).toSet();
    final ordered = [
      for (final r in _roomOrder)
        if (present.remove(r)) r
    ];
    return [...ordered, ...present.toList()..sort()];
  }

  /// Saves the order rooms are shown in.
  Future<void> reorderRooms(List<String> order) async {
    _roomOrder = [for (final r in order) r.trim()];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_roomOrderKey, _roomOrder);
    notifyListeners();
  }

  /// Puts the devices of [room] in the order of [deviceIds]. Devices keep
  /// the slots their room already had in the saved list, so other rooms
  /// are untouched.
  Future<void> reorderRoom(String room, List<String> deviceIds) async {
    final slots = [
      for (var i = 0; i < _devices.length; i++)
        if (_devices[i].room.trim() == room.trim()) i
    ];
    final byId = {for (final i in slots) _devices[i].id: _devices[i]};
    if (deviceIds.length != slots.length ||
        !deviceIds.every(byId.containsKey)) {
      throw ArgumentError('Device list does not match room "$room"');
    }
    for (var k = 0; k < slots.length; k++) {
      _devices[slots[k]] = byId[deviceIds[k]]!;
    }
    await _save();
    notifyListeners();
  }

  Device? byId(String id) {
    for (final d in _devices) {
      if (d.id == id) return d;
    }
    return null;
  }

  Device? byMac(String mac) {
    final m = formatMac(mac);
    for (final d in _devices) {
      if (d.mac.isNotEmpty && formatMac(d.mac) == m) return d;
    }
    return null;
  }

  /// True when this device is driven over MQTT instead of HTTP.
  bool usesMqtt(Device d) =>
      mqtt.isConnected && mqttSettings.preferMqtt && d.mqttTopic.isNotEmpty;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    pollSeconds = prefs.getInt(_pollKey) ?? 10;
    _roomOrder = prefs.getStringList(_roomOrderKey) ?? [];
    if (raw != null) {
      try {
        _devices
          ..clear()
          ..addAll(Device.decodeList(raw));
      } catch (_) {}
    }
    final rawScenes = prefs.getString(_scenesKey);
    if (rawScenes != null) {
      try {
        _scenes
          ..clear()
          ..addAll(Scene.decodeList(rawScenes));
      } catch (_) {}
    }
    for (final d in _devices) {
      try {
        final pw = await _secure.read(key: '$_pwPrefix${d.id}');
        if (pw != null) _passwords[d.id] = pw;
      } catch (_) {}
    }
    mqttSettings = await MqttSettings.load(_secure);
    notifyListeners();
    // Do not block app start on the broker.
    unawaited(mqtt.connect(mqttSettings));
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, Device.encodeList(_devices));
    _syncSubscriptions();
  }

  Future<void> setPollSeconds(int s) async {
    pollSeconds = s;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_pollKey, s);
    if (_timer != null) startPolling();
    notifyListeners();
  }

  Future<void> saveMqttSettings(MqttSettings s) async {
    mqttSettings = s;
    await s.save(_secure);
    mqttDiscovered.clear();
    await mqtt.connect(s);
  }

  /// Adds or updates (matched by id, MAC or host) and persists.
  Future<Device> upsert(Device d,
      {String? password, DeviceState? state}) async {
    final idx = _devices.indexWhere((e) =>
        e.id == d.id ||
        (d.mac.isNotEmpty && formatMac(e.mac) == formatMac(d.mac)) ||
        (d.host.isNotEmpty && e.host == d.host));
    Device target;
    if (idx >= 0) {
      final old = _devices[idx];
      target = old
        ..host = d.host.isNotEmpty ? d.host : old.host
        ..type = d.type != FirmwareType.unknown ? d.type : old.type
        ..mac = d.mac.isNotEmpty ? d.mac : old.mac
        ..mqttTopic = d.mqttTopic.isNotEmpty ? d.mqttTopic : old.mqttTopic
        ..fullTopic = d.fullTopic.isNotEmpty ? d.fullTopic : old.fullTopic;
    } else {
      target = d;
      _devices.add(d);
    }
    if (target.mqttTopic.isEmpty && (state?.topic.isNotEmpty ?? false)) {
      target.mqttTopic = state!.topic;
    }
    if (password != null) await setPassword(target, password);
    if (state != null) _state[target.id] = state;
    await _save();
    notifyListeners();
    if (usesMqtt(target)) _requestStatus(target);
    return target;
  }

  /// Adds a device announced through Tasmota MQTT discovery.
  Future<Device> addDiscovered(TasmotaDiscoveryInfo info) => upsert(Device(
        id: info.mac.isNotEmpty ? info.mac : info.topic,
        host: info.ip,
        name: info.name,
        type: FirmwareType.tasmota,
        mac: info.mac,
        mqttTopic: info.topic,
        fullTopic: info.fullTopic,
        prefixes: info.prefixes,
      ));

  Future<void> update(Device d,
      {String? name,
      String? room,
      String? host,
      String? username,
      String? mqttTopic}) async {
    if (name != null) d.name = name;
    if (room != null) d.room = room;
    if (host != null) d.host = host;
    if (username != null) d.username = username;
    if (mqttTopic != null) d.mqttTopic = mqttTopic;
    await _save();
    notifyListeners();
  }

  Future<void> setPassword(Device d, String password) async {
    if (password.isEmpty) {
      _passwords.remove(d.id);
      await _secure.delete(key: '$_pwPrefix${d.id}');
    } else {
      _passwords[d.id] = password;
      await _secure.write(key: '$_pwPrefix${d.id}', value: password);
    }
    notifyListeners();
  }

  Future<void> remove(Device d) async {
    _devices.removeWhere((e) => e.id == d.id);
    var scenesChanged = false;
    for (final sc in _scenes) {
      final before = sc.actions.length;
      sc.actions.removeWhere((a) => a.deviceId == d.id);
      scenesChanged |= sc.actions.length != before;
    }
    if (scenesChanged) await _saveScenes();
    _state.remove(d.id);
    _passwords.remove(d.id);
    await _secure.delete(key: '$_pwPrefix${d.id}');
    await _save();
    notifyListeners();
  }

  // ---- live state -------------------------------------------------------

  /// Devices being flashed. They get no status polls meanwhile: a small
  /// ESP8266 receiving firmware can crash when other requests arrive.
  final Set<String> _flashing = {};

  void setFlashing(Device d, bool on) =>
      on ? _flashing.add(d.id) : _flashing.remove(d.id);

  Future<void> refresh(Device d) async {
    if (_flashing.contains(d.id)) return;
    if (usesMqtt(d)) {
      _requestStatus(d);
      return;
    }
    try {
      final s = await api.fetchState(d.host,
          username: d.username, password: _passwords[d.id]);
      s.lwtOnline = _state[d.id]?.lwtOnline;
      _state[d.id] = s;
      var changed = false;
      // Pick up the MAC so the device survives a DHCP address change.
      if (d.mac.isEmpty && s.mac.isNotEmpty) {
        d.mac = s.mac;
        changed = true;
      }
      if (d.mqttTopic.isEmpty && s.topic.isNotEmpty) {
        d.mqttTopic = s.topic;
        changed = true;
      }
      if (changed) await _save();
    } on AuthRequiredException {
      _state[d.id] = DeviceState(authRequired: true, error: 'Password needed');
    } catch (e) {
      final prev = _state[d.id];
      _state[d.id] = (prev ?? DeviceState())
        ..online = false
        ..error = '$e';
    }
    notifyListeners();
  }

  /// Refreshes devices with a small concurrency cap so a big install does
  /// not flood cheap ESP/BK radios. MQTT devices push their own changes, so
  /// periodic polls skip them unless [force] is set (pull-to-refresh).
  Future<void> refreshAll({bool force = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final queue = _devices.where((d) => force || !usesMqtt(d)).toList();
      Future<void> worker() async {
        while (queue.isNotEmpty) {
          await refresh(queue.removeLast());
        }
      }

      await Future.wait(List.generate(6, (_) => worker()));
    } finally {
      _refreshing = false;
    }
  }

  void startPolling() {
    _timer?.cancel();
    refreshAll(force: true);
    if (pollSeconds <= 0) return;
    _timer =
        Timer.periodic(Duration(seconds: pollSeconds), (_) => refreshAll());
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  /// Runs a command and merges the reply into the cached state.
  /// Over MQTT the reply is the next `stat/<topic>/RESULT` (4 s timeout).
  Future<Map<String, dynamic>> command(Device d, String cmnd) async {
    if (usesMqtt(d)) return _mqttCommand(d, cmnd);
    final res = await api.send(d.host, cmnd,
        username: d.username, password: _passwords[d.id]);
    final s = stateOf(d)
      ..online = true
      ..authRequired = false
      ..error = null
      ..viaMqtt = false
      ..updated = DateTime.now();
    s.applyStateJson(res);
    notifyListeners();
    return res;
  }

  Future<Map<String, dynamic>> _mqttCommand(Device d, String cmnd) async {
    final trimmed = cmnd.trim();
    final sp = trimmed.indexOf(' ');
    final name = sp < 0 ? trimmed : trimmed.substring(0, sp);
    final payload = sp < 0 ? '' : trimmed.substring(sp + 1).trim();
    final topic =
        TasmotaTopics.build(d.fullTopic, d.cmndPrefix, d.mqttTopic, name);
    final completer = Completer<Map<String, dynamic>>();
    _pendingResult[d.id]?.complete(const {});
    _pendingResult[d.id] = completer;
    if (!mqtt.publish(topic, payload)) {
      _pendingResult.remove(d.id);
      throw Exception('MQTT not connected');
    }
    try {
      return await completer.future.timeout(const Duration(seconds: 4));
    } on TimeoutException {
      throw Exception('No MQTT reply from ${d.mqttTopic}');
    } finally {
      if (_pendingResult[d.id] == completer) _pendingResult.remove(d.id);
    }
  }

  void _requestStatus(Device d) {
    if (_flashing.contains(d.id)) return;
    mqtt.publish(
        TasmotaTopics.build(d.fullTopic, d.cmndPrefix, d.mqttTopic, 'STATUS'),
        '0');
  }

  /// Like [command], but over MQTT keeps collecting `RESULT` messages for
  /// [window] and merges them: Tasmota splits long replies (e.g. `Timers`)
  /// into several messages. Over HTTP the reply already holds everything.
  Future<Map<String, dynamic>> commandCollect(Device d, String cmnd,
      {Duration window = const Duration(milliseconds: 1500)}) async {
    if (!usesMqtt(d)) return command(d, cmnd);
    final merged = <String, dynamic>{};
    final sub = _results.stream
        .where((e) => e.$1 == d.id)
        .listen((e) => merged.addAll(e.$2));
    try {
      await command(d, cmnd);
      await Future<void>.delayed(window);
    } finally {
      await sub.cancel();
    }
    return merged;
  }

  Future<TimerSet> fetchTimers(Device d) async =>
      parseTimers(await commandCollect(d, 'Timers'));

  Future<void> setTimersActive(Device d, bool on) =>
      command(d, 'Timers ${on ? 1 : 0}');

  Future<TasmotaTimer> saveTimer(Device d, TasmotaTimer t) async {
    final res = await command(d, 'Timer${t.index} ${jsonEncode(t.toJson())}');
    return parseTimers(res).timers[t.index] ?? t;
  }

  /// `Timer<x> 0` resets the timer to its empty default.
  Future<TasmotaTimer> clearTimer(Device d, int index) async {
    final res = await command(d, 'Timer$index 0');
    return parseTimers(res).timers[index] ?? TasmotaTimer(index: index);
  }

  // ---- rules ------------------------------------------------------------

  Future<TasmotaRule> fetchRule(Device d, int index) async {
    final res = await commandCollect(d, 'Rule$index',
        window: const Duration(milliseconds: 600));
    return parseRule(index, res) ??
        (throw Exception('Device did not return Rule$index'));
  }

  /// Writes the text, then the flags, and returns what the device now holds.
  Future<TasmotaRule> saveRule(Device d, TasmotaRule r) async {
    await command(d, r.setTextCommand);
    await command(d, r.onceCommand(r.once));
    await command(d, r.stopOnErrorCommand(r.stopOnError));
    await command(d, r.enableCommand(r.enabled));
    return fetchRule(d, r.index);
  }

  Future<TasmotaRule> setRuleEnabled(Device d, TasmotaRule r, bool on) async {
    final res = await command(d, r.enableCommand(on));
    return parseRule(r.index, res) ?? (r..enabled = on);
  }

  // ---- scenes -----------------------------------------------------------

  List<Scene> get scenes => List.unmodifiable(_scenes);

  Future<void> _saveScenes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_scenesKey, Scene.encodeList(_scenes));
  }

  Future<void> upsertScene(Scene s) async {
    final i = _scenes.indexWhere((e) => e.id == s.id);
    if (i >= 0) {
      _scenes[i] = s;
    } else {
      _scenes.add(s);
    }
    await _saveScenes();
    notifyListeners();
  }

  Future<void> removeScene(Scene s) async {
    _scenes.removeWhere((e) => e.id == s.id);
    await _saveScenes();
    notifyListeners();
  }

  /// [to] is the final index (already adjusted for the removed item).
  Future<void> reorderScenes(int from, int to) async {
    _scenes.insert(to, _scenes.removeAt(from));
    await _saveScenes();
    notifyListeners();
  }

  /// One command per relay (current on/off) plus light level/colour, so a
  /// scene can be built by setting devices up by hand and capturing them.
  List<SceneAction> captureState(Device d) {
    final s = stateOf(d);
    return [
      for (final k in s.relayKeys)
        SceneAction(
            deviceId: d.id, command: '$k ${s.power[k]! ? 'ON' : 'OFF'}'),
      if (s.dimmer != null && s.anyOn)
        SceneAction(deviceId: d.id, command: 'Dimmer ${s.dimmer}'),
      if (s.ct != null && s.anyOn)
        SceneAction(deviceId: d.id, command: 'CT ${s.ct}'),
    ];
  }

  /// Devices run in parallel; each device's steps run in order so a radio
  /// only sees one request at a time. Relay steps skip locked devices.
  Future<SceneRunResult> runScene(Scene scene) async {
    final result = SceneRunResult();
    final byDevice = <String, List<SceneAction>>{};
    for (final a in scene.actions) {
      byDevice.putIfAbsent(a.deviceId, () => []).add(a);
    }
    await Future.wait(byDevice.entries.map((e) async {
      final d = byId(e.key);
      for (final a in e.value) {
        if (d == null) {
          result.failed.add('Removed device: ${a.command}');
          continue;
        }
        if (d.locked && a.isPower) {
          result.skipped.add('${d.name}: ${a.command}');
          continue;
        }
        try {
          await command(d, a.command);
          result.ok++;
        } catch (err) {
          result.failed.add('${d.name}: $err');
        }
      }
    }));
    await Future.wait(byDevice.keys
        .map(byId)
        .whereType<Device>()
        .where((d) => !usesMqtt(d))
        .map(refresh));
    return result;
  }

  Future<void> setLocked(Device d, bool locked) async {
    d.locked = locked;
    await _save();
    notifyListeners();
  }

  Future<void> setPower(Device d, String relayKey, bool on) async {
    if (d.locked) throw Exception('${d.name} is locked');
    final s = stateOf(d);
    final prev = s.power[relayKey];
    s.power[relayKey] = on; // optimistic
    notifyListeners();
    try {
      await command(d, '$relayKey ${on ? 'ON' : 'OFF'}');
    } catch (e) {
      if (prev != null) s.power[relayKey] = prev;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> setRoomPower(String room, bool on) async {
    final targets = _devices.where((d) => d.room.trim() == room).toList();
    await Future.wait(targets.map((d) async {
      try {
        // Per-relay commands work on both Tasmota and OpenBeken
        // (Tasmota's POWER0 shortcut is not universal).
        if (d.locked) return;
        final keys = stateOf(d).relayKeys;
        for (final k in keys.isEmpty ? ['POWER'] : keys) {
          await command(d, '$k ${on ? 'ON' : 'OFF'}');
        }
      } catch (_) {}
    }));
    await Future.wait(targets.where((d) => !usesMqtt(d)).map(refresh));
  }

  // ---- MQTT -------------------------------------------------------------

  void _onMqttLinkChanged() {
    final now = mqtt.state;
    if (now == MqttLinkState.connected &&
        _lastLink != MqttLinkState.connected) {
      _syncSubscriptions();
      for (final d in _devices.where(usesMqtt)) {
        _requestStatus(d);
      }
    }
    _lastLink = now;
    notifyListeners();
  }

  Set<String> subscriptionFilters() {
    final f = <String>{discoveryFilter};
    for (final d in _devices) {
      if (d.mqttTopic.isEmpty) continue;
      f.add(TasmotaTopics.filter(d.fullTopic, d.statPrefix, d.mqttTopic));
      f.add(TasmotaTopics.filter(d.fullTopic, d.telePrefix, d.mqttTopic));
    }
    return f;
  }

  void _syncSubscriptions() {
    if (mqtt.isConnected) mqtt.setSubscriptions(subscriptionFilters());
  }

  /// Routes one broker message to the device it belongs to.
  void handleMqtt(MqttIncoming m) {
    if (m.topic.startsWith('tasmota/discovery/') &&
        m.topic.endsWith('/config')) {
      final info = TasmotaDiscoveryInfo.parse(m.payload);
      if (info != null) {
        mqttDiscovered[info.mac.isNotEmpty ? info.mac : info.topic] = info;
        // Keep saved devices' IP/topic in sync with what they announce.
        final known = info.mac.isNotEmpty ? byMac(info.mac) : null;
        if (known != null &&
            (known.host != info.ip || known.mqttTopic != info.topic)) {
          if (info.ip.isNotEmpty) known.host = info.ip;
          known
            ..mqttTopic = info.topic
            ..fullTopic = info.fullTopic
            ..prefixes = info.prefixes;
          _save();
        }
        notifyListeners();
      }
      return;
    }
    for (final d in _devices) {
      if (d.mqttTopic.isEmpty) continue;
      final r = TasmotaTopics.match(d.fullTopic, d.mqttTopic, m.topic);
      if (r == null) continue;
      if (r.prefix != d.statPrefix && r.prefix != d.telePrefix) return;
      _applyMqtt(d, r.suffix, m.payload);
      return;
    }
  }

  void _applyMqtt(Device d, String suffix, String payload) {
    final key = suffix.toUpperCase();
    Map<String, dynamic>? json;
    try {
      final v = jsonDecode(payload);
      if (v is Map) json = Map<String, dynamic>.from(v);
    } catch (_) {}

    var s = stateOf(d);
    if (key == 'LWT') {
      final online = payload.trim().toLowerCase() == 'online';
      s
        ..lwtOnline = online
        ..online = online
        ..error = online ? null : 'Offline (LWT)';
      notifyListeners();
      return;
    }

    switch (key) {
      case 'STATUS0':
        if (json == null) return;
        final fresh = parseStatus0(json)..lwtOnline = s.lwtOnline;
        _state[d.id] = s = fresh;
        if (d.mac.isEmpty && fresh.mac.isNotEmpty) {
          d.mac = fresh.mac;
          _save();
        }
      case 'STATUS8':
      case 'STATUS10':
        final sns = json?['StatusSNS'];
        if (sns is Map) {
          s.sensors = flattenSensors(Map<String, dynamic>.from(sns));
          if (sns['ENERGY'] is Map) {
            s.energy = Map<String, dynamic>.from(sns['ENERGY'] as Map);
          }
        }
      case 'SENSOR':
        if (json != null) {
          s.sensors = flattenSensors(json);
          if (json['ENERGY'] is Map) {
            s.energy = Map<String, dynamic>.from(json['ENERGY'] as Map);
          }
        }
      case 'STATE':
      case 'RESULT':
        if (json != null) {
          s.applyStateJson(json);
          if (key == 'RESULT') _results.add((d.id, json));
        }
        final c = _pendingResult.remove(d.id);
        if (c != null && !c.isCompleted) c.complete(json ?? const {});
      default:
        if (RegExp(r'^POWER\d*$').hasMatch(key)) {
          final p = payload.trim().toUpperCase();
          if (p == 'ON' || p == 'OFF') s.power[key] = p == 'ON';
        } else {
          return; // ignore other stat/tele topics
        }
    }
    s
      ..online = s.lwtOnline ?? true
      ..authRequired = false
      ..error = null
      ..viaMqtt = true
      ..updated = DateTime.now();
    notifyListeners();
  }

  @override
  void dispose() {
    _nativeSync?.cancel();
    stopPolling();
    _mqttSub.cancel();
    _results.close();
    mqtt.removeListener(_onMqttLinkChanged);
    mqtt.dispose();
    api.close();
    super.dispose();
  }
}
