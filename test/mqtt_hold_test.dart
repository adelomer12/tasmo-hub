// Live link tests against a local mosquitto (see mqtt_live_test.dart).
// MQTT_LIVE_PORT / MQTT_LIVE_PW, plus MQTT_RESTART_CMD to bounce the broker.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tasmo_hub/services/mqtt_service.dart';

final _port = int.tryParse(Platform.environment['MQTT_LIVE_PORT'] ?? '');
final _pw = Platform.environment['MQTT_LIVE_PW'] ?? '';
final _restart = Platform.environment['MQTT_RESTART_CMD'];

MqttSettings _settings() => MqttSettings(
    enabled: true,
    host: '127.0.0.1',
    port: _port ?? 1883,
    username: 'hub',
    password: _pw,
    clientId: 'tasmohub-test');

Future<void> until(bool Function() cond, {int seconds = 40}) async {
  for (var i = 0; i < seconds * 10 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(cond(), isTrue);
}

void main() {
  test('overlapping connects leave exactly one live session', () async {
    final m = MqttService();
    final a = m.connect(_settings());
    final b = m.connect(_settings());
    await Future.wait([a, b]);
    expect(m.state, MqttLinkState.connected);
    await Future<void>.delayed(const Duration(seconds: 6));
    expect(m.state, MqttLinkState.connected);
    await m.disconnect();
  }, skip: _port == null, timeout: const Timeout(Duration(seconds: 30)));

  test('detects a dropped broker and reconnects', () async {
    final m = MqttService();
    await m.connect(_settings());
    expect(m.state, MqttLinkState.connected);
    await Process.run('sh', ['-c', 'pkill -x mosquitto']);
    await until(() => m.state != MqttLinkState.connected, seconds: 15);
    await Process.run('sh', ['-c', _restart!]);
    await until(() => m.state == MqttLinkState.connected, seconds: 45);
    await m.disconnect();
  },
      skip: _port == null || _restart == null,
      timeout: const Timeout(Duration(seconds: 90)));
}
