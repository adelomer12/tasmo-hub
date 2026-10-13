import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';
import 'tasmota_api.dart';

/// Owns the device list, credentials and live state, and polls devices.
///
/// Device metadata goes to SharedPreferences; web passwords go to
/// flutter_secure_storage (Android Keystore / iOS Keychain), never to
/// plain preferences or logs.
class DeviceStore extends ChangeNotifier {
  DeviceStore({TasmotaApi? api}) : api = api ?? TasmotaApi();

  static const _prefsKey = 'devices_v1';
  static const _pwPrefix = 'pw_';
  static const _pollKey = 'poll_seconds';

  final TasmotaApi api;
  final FlutterSecureStorage _secure = const FlutterSecureStorage();

  final List<Device> _devices = [];
  final Map<String, DeviceState> _state = {};
  final Map<String, String> _passwords = {};
  Timer? _timer;
  bool _refreshing = false;
  int pollSeconds = 10;

  List<Device> get devices => List.unmodifiable(_devices);
  DeviceState stateOf(Device d) => _state[d.id] ??= DeviceState();
  String? passwordOf(Device d) => _passwords[d.id];

  List<String> get rooms {
    final r = _devices.map((d) => d.room.trim()).toSet().toList()..sort();
    return r;
  }

  Device? byId(String id) {
    for (final d in _devices) {
      if (d.id == id) return d;
    }
    return null;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    pollSeconds = prefs.getInt(_pollKey) ?? 10;
    if (raw != null) {
      try {
        _devices
          ..clear()
          ..addAll(Device.decodeList(raw));
      } catch (_) {}
    }
    for (final d in _devices) {
      try {
        final pw = await _secure.read(key: '$_pwPrefix${d.id}');
        if (pw != null) _passwords[d.id] = pw;
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, Device.encodeList(_devices));
  }

  Future<void> setPollSeconds(int s) async {
    pollSeconds = s;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_pollKey, s);
    if (_timer != null) startPolling();
    notifyListeners();
  }

  /// Adds or updates (matched by id, MAC or host) and persists.
  Future<Device> upsert(Device d, {String? password, DeviceState? state}) async {
    final idx = _devices.indexWhere((e) =>
        e.id == d.id ||
        (d.mac.isNotEmpty && e.mac == d.mac) ||
        e.host == d.host);
    Device target;
    if (idx >= 0) {
      target = _devices[idx]
        ..host = d.host
        ..type = d.type
        ..mac = d.mac.isNotEmpty ? d.mac : _devices[idx].mac;
    } else {
      target = d;
      _devices.add(d);
    }
    if (password != null) await setPassword(target, password);
    if (state != null) _state[target.id] = state;
    await _save();
    notifyListeners();
    return target;
  }

  Future<void> update(Device d,
      {String? name, String? room, String? host, String? username}) async {
    if (name != null) d.name = name;
    if (room != null) d.room = room;
    if (host != null) d.host = host;
    if (username != null) d.username = username;
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
  }

  Future<void> remove(Device d) async {
    _devices.removeWhere((e) => e.id == d.id);
    _state.remove(d.id);
    _passwords.remove(d.id);
    await _secure.delete(key: '$_pwPrefix${d.id}');
    await _save();
    notifyListeners();
  }

  // ---- live state -------------------------------------------------------

  Future<void> refresh(Device d) async {
    try {
      final s = await api.fetchState(d.host,
          username: d.username, password: _passwords[d.id]);
      _state[d.id] = s;
      // Pick up the MAC so the device survives a DHCP address change.
      if (d.mac.isEmpty && s.mac.isNotEmpty) {
        d.mac = s.mac;
        await _save();
      }
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

  /// Refreshes all devices with a small concurrency cap so a big install
  /// does not flood cheap ESP/BK radios.
  Future<void> refreshAll() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final queue = List<Device>.from(_devices);
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
    refreshAll();
    if (pollSeconds <= 0) return;
    _timer = Timer.periodic(Duration(seconds: pollSeconds), (_) => refreshAll());
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  /// Runs a command and merges the reply into the cached state.
  Future<Map<String, dynamic>> command(Device d, String cmnd) async {
    final res = await api.send(d.host, cmnd,
        username: d.username, password: _passwords[d.id]);
    final s = stateOf(d)
      ..online = true
      ..authRequired = false
      ..error = null
      ..updated = DateTime.now();
    s.applyStateJson(res);
    notifyListeners();
    return res;
  }

  Future<void> setPower(Device d, String relayKey, bool on) async {
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
        final keys = stateOf(d).relayKeys;
        for (final k in keys.isEmpty ? ['POWER'] : keys) {
          await command(d, '$k ${on ? 'ON' : 'OFF'}');
        }
      } catch (_) {}
    }));
    await Future.wait(targets.map(refresh));
  }

  @override
  void dispose() {
    stopPolling();
    api.close();
    super.dispose();
  }
}
