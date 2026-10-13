// Integration test against a real broker. Skipped unless MQTT_LIVE_PORT is
// set, e.g. with a local mosquitto that requires user "hub" / MQTT_LIVE_PW:
//   MQTT_LIVE_PORT=18830 MQTT_LIVE_PW='s3cret!' flutter test test/mqtt_live_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tasmo_hub/services/device_store.dart';
import 'package:tasmo_hub/services/mqtt_service.dart';

final _port = int.tryParse(Platform.environment['MQTT_LIVE_PORT'] ?? '');
final _pw = Platform.environment['MQTT_LIVE_PW'] ?? '';

/// Minimal fake Tasmota device speaking the real MQTT protocol.
Future<MqttServerClient> fakeTasmota() async {
  final c = MqttServerClient.withPort('127.0.0.1', 'fake-tasmota', _port!)
    ..logging(on: false)
    ..setProtocolV311();
  await c.connect('hub', _pw);
  void pub(String t, String p, {bool retain = false}) => c.publishMessage(t,
      MqttQos.atLeastOnce, (MqttClientPayloadBuilder()..addString(p)).payload!,
      retain: retain);
  var power = false;
  c.subscribe('cmnd/plug1/#', MqttQos.atMostOnce);
  c.updates!.listen((events) {
    for (final e in events) {
      final cmd = e.topic.split('/').last.toUpperCase();
      final payload =
          utf8.decode((e.payload as MqttPublishMessage).payload.message);
      if (cmd == 'POWER') {
        power = payload.toUpperCase() == 'ON';
        pub('stat/plug1/RESULT', '{"POWER":"${power ? 'ON' : 'OFF'}"}');
        pub('stat/plug1/POWER', power ? 'ON' : 'OFF');
      } else if (cmd == 'STATUS') {
        pub(
            'stat/plug1/STATUS0',
            '{"Status":{"DeviceName":"Live Plug","Topic":"plug1"},'
                '"StatusNET":{"Mac":"AA:BB:CC:00:00:01","IPAddress":"10.9.9.9"},'
                '"StatusSTS":{"POWER":"${power ? 'ON' : 'OFF'}"},'
                '"StatusSNS":{"ENERGY":{"Power":12}}}');
      }
    }
  });
  pub('tele/plug1/LWT', 'Online', retain: true);
  pub(
      'tasmota/discovery/AABBCC000001/config',
      '{"ip":"10.9.9.9","dn":"Live Plug","mac":"AABBCC000001","t":"plug1",'
          '"ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],"sw":"14.2.0"}',
      retain: true);
  return c;
}

Future<void> until(bool Function() cond) async {
  for (var i = 0; i < 50 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(cond(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('wrong password is reported as an error', () async {
    final m = MqttService();
    await m.connect(MqttSettings(
        enabled: true,
        host: '127.0.0.1',
        port: _port!,
        username: 'hub',
        password: 'wrong'));
    expect(m.state, MqttLinkState.error);
    await m.disconnect();
  }, skip: _port == null);

  test('discovers, controls and reads a device through a real broker',
      () async {
    SharedPreferences.setMockInitialValues({});
    final device = await fakeTasmota();
    final store = DeviceStore();
    store.mqttSettings = MqttSettings(
        enabled: true,
        host: '127.0.0.1',
        port: _port!,
        username: 'hub',
        password: _pw);
    await store.mqtt.connect(store.mqttSettings);
    expect(store.mqtt.state, MqttLinkState.connected);

    // Retained discovery message arrives on subscribe.
    await until(() => store.mqttDiscovered.isNotEmpty);
    final d = await store.addDiscovered(store.mqttDiscovered.values.first);
    expect(d.mqttTopic, 'plug1');

    // addDiscovered requests STATUS 0 over MQTT.
    await until(() => store.stateOf(d).sensors.isNotEmpty);
    expect(store.stateOf(d).deviceName, 'Live Plug');
    expect(store.stateOf(d).online, isTrue);

    final res = await store.command(d, 'Power ON');
    expect(res, {'POWER': 'ON'});
    expect(store.stateOf(d).power['POWER'], isTrue);

    await store.setPower(d, 'POWER', false);
    expect(store.stateOf(d).power['POWER'], isFalse);

    device.disconnect();
    await store.mqtt.disconnect();
  }, skip: _port == null, timeout: const Timeout(Duration(seconds: 30)));
}
