import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tasmo_hub/models/device.dart';
import 'package:tasmo_hub/services/device_store.dart';
import 'package:tasmo_hub/services/mqtt_service.dart';

/// Fake broker link: records publishes, lets the test inject messages.
class FakeMqtt extends MqttService {
  final published = <(String, String)>[];
  final _ctrl = StreamController<MqttIncoming>.broadcast();
  Set<String> subs = {};

  @override
  Stream<MqttIncoming> get messages => _ctrl.stream;
  @override
  bool get isConnected => true;
  @override
  bool publish(String topic, String payload) {
    published.add((topic, payload));
    return true;
  }

  @override
  void setSubscriptions(Set<String> filters) => subs = filters;
  void inject(String t, String p) => _ctrl.add(MqttIncoming(t, p));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('topic build and match with default and custom FullTopic', () {
    expect(
        TasmotaTopics.build('', 'cmnd', 'plug1', 'POWER'), 'cmnd/plug1/POWER');
    expect(TasmotaTopics.match('', 'plug1', 'stat/plug1/RESULT'),
        (prefix: 'stat', suffix: 'RESULT'));
    expect(TasmotaTopics.match('', 'plug1', 'stat/plug10/RESULT'), isNull);
    const ft = 'home/%topic%/%prefix%/';
    expect(
        TasmotaTopics.build(ft, 'tele', 'lamp', 'LWT'), 'home/lamp/tele/LWT');
    expect(TasmotaTopics.match(ft, 'lamp', 'home/lamp/tele/SENSOR'),
        (prefix: 'tele', suffix: 'SENSOR'));
    expect(TasmotaTopics.filter('', 'tele', 'lamp'), 'tele/lamp/#');
  });

  test('parses Tasmota discovery config', () {
    final i = TasmotaDiscoveryInfo.parse(
        '{"ip":"192.168.20.31","dn":"Office Plug","fn":["Office Plug",null],'
        '"hn":"tasmota-A1B2C3","mac":"AABBCCA1B2C3","md":"Sonoff Basic",'
        '"sw":"14.2.0","t":"tasmota_A1B2C3","ft":"%prefix%/%topic%/",'
        '"tp":["cmnd","stat","tele"]}')!;
    expect(i.mac, 'AA:BB:CC:A1:B2:C3');
    expect(i.topic, 'tasmota_A1B2C3');
    expect(i.name, 'Office Plug');
    expect(TasmotaDiscoveryInfo.parse('not json'), isNull);
  });

  test('store routes LWT, RESULT, SENSOR and sends commands over MQTT',
      () async {
    final mqtt = FakeMqtt();
    final store = DeviceStore(mqtt: mqtt)
      ..mqttSettings = MqttSettings(enabled: true, host: 'b');
    final d = Device(
        id: 'AA:BB:CC:A1:B2:C3',
        host: '192.168.20.31',
        name: 'Plug',
        mqttTopic: 'plug1');
    await _mockPrefs();
    await store.upsert(d);
    expect(
        mqtt.subs,
        containsAll(
            ['stat/plug1/#', 'tele/plug1/#', DeviceStore.discoveryFilter]));
    expect(mqtt.published.last, ('cmnd/plug1/STATUS', '0'));

    mqtt.inject('tele/plug1/LWT', 'Online');
    mqtt.inject('tele/plug1/SENSOR',
        '{"Time":"x","ENERGY":{"Power":42,"Voltage":230}}');
    mqtt.inject('stat/plug1/POWER', 'ON');
    await Future<void>.delayed(Duration.zero);
    final s = store.stateOf(d);
    expect(s.online, isTrue);
    expect(s.viaMqtt, isTrue);
    expect(s.power['POWER'], isTrue);
    expect(s.sensors.firstWhere((r) => r.key == 'Power').display, '42 W');

    final reply = store.command(d, 'Power OFF');
    expect(mqtt.published.last, ('cmnd/plug1/Power', 'OFF'));
    mqtt.inject('stat/plug1/RESULT', '{"POWER":"OFF"}');
    expect(await reply, {'POWER': 'OFF'});
    expect(s.power['POWER'], isFalse);

    mqtt.inject('tele/plug1/LWT', 'Offline');
    await Future<void>.delayed(Duration.zero);
    expect(store.stateOf(d).online, isFalse);
  });

  test('discovery announces new devices and updates a moved one', () async {
    await _mockPrefs();
    final mqtt = FakeMqtt();
    final store = DeviceStore(mqtt: mqtt);
    final d = Device(
        id: 'AA:BB:CC:A1:B2:C3',
        host: '192.168.20.31',
        name: 'Plug',
        mac: 'AA:BB:CC:A1:B2:C3');
    await store.upsert(d);
    mqtt.inject('tasmota/discovery/AABBCCA1B2C3/config',
        '{"ip":"192.168.20.99","dn":"Plug","mac":"AABBCCA1B2C3","t":"plug1"}');
    mqtt.inject('tasmota/discovery/112233445566/config',
        '{"ip":"192.168.20.50","dn":"Lamp","mac":"112233445566","t":"lamp"}');
    await Future<void>.delayed(Duration.zero);
    expect(d.host, '192.168.20.99');
    expect(d.mqttTopic, 'plug1');
    expect(store.mqttDiscovered.keys,
        containsAll(['AA:BB:CC:A1:B2:C3', '11:22:33:44:55:66']));
  });
}

Future<void> _mockPrefs() async {
  SharedPreferences.setMockInitialValues({});
}
