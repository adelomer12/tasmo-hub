import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tasmo_hub/models/device.dart';
import 'package:tasmo_hub/models/tasmota_timer.dart';
import 'package:tasmo_hub/services/device_store.dart';
import 'package:tasmo_hub/services/mqtt_service.dart';
import 'package:tasmo_hub/services/tasmota_api.dart';

class FakeMqtt extends MqttService {
  final published = <(String, String)>[];
  final _ctrl = StreamController<MqttIncoming>.broadcast();
  void Function(String topic, String payload)? onPublish;

  @override
  Stream<MqttIncoming> get messages => _ctrl.stream;
  @override
  bool get isConnected => true;
  @override
  bool publish(String topic, String payload) {
    published.add((topic, payload));
    scheduleMicrotask(() => onPublish?.call(topic, payload));
    return true;
  }

  @override
  void setSubscriptions(Set<String> filters) {}
  void inject(String t, String p) => _ctrl.add(MqttIncoming(t, p));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parses chunked Timers reply', () {
    final set = parseTimers(Map<String, dynamic>.from(jsonDecode(
        '{"Timers":"ON","Timers1":{"Timer1":{"Enable":1,"Mode":0,'
        '"Time":"06:30","Window":0,"Days":"1111111","Repeat":1,"Output":1,'
        '"Action":1},"Timer2":{"Enable":0,"Mode":2,"Time":"-00:15",'
        '"Window":5,"Days":"-MTWTF-","Repeat":0,"Output":2,"Action":0}},'
        '"Timers4":{"Timer16":{"Enable":0,"Mode":0,"Time":"00:00",'
        '"Window":0,"Days":"0000000","Repeat":0,"Output":1,"Action":0}}}')));
    expect(set.active, isTrue);
    expect(set.timers.keys, [1, 2, 16]);
    final t1 = set.timers[1]!;
    expect(t1.enable, isTrue);
    expect(t1.daysLabel, 'Every day');
    expect(t1.actionLabel, 'Turn on');
    final t2 = set.timers[2]!;
    expect(t2.daysLabel, 'Weekdays');
    expect(t2.timeLabel, 'Sunset -00:15');
    expect(t2.repeat, isFalse);
    expect(t2.toJson()['Days'], '0111110');
    expect(set.timers[16]!.daysLabel, 'No days selected');
  });

  test('Status 0 exposes energy, device time and relay names', () {
    final s = parseStatus0(Map<String, dynamic>.from(
        jsonDecode('{"Status":{"FriendlyName":["LG Q","Lamp"]},'
            '"StatusTIM":{"Local":"2026-10-13T18:51:02"},'
            '"StatusSNS":{"ENERGY":{"TotalStartTime":"2023-10-19T11:58:00",'
            '"Total":885.49,"Yesterday":2.054,"Today":1.68,"Power":0}}}')));
    expect(s.friendlyNames, ['LG Q', 'Lamp']);
    expect(s.deviceTime, '2026-10-13T18:51:02');
    expect(s.energy['TotalStartTime'], '2023-10-19T11:58:00');
    expect(s.energy['Total'], 885.49);
  });

  test('timers over MQTT: merges chunked RESULTs and saves a timer', () async {
    SharedPreferences.setMockInitialValues({});
    final mqtt = FakeMqtt();
    final store = DeviceStore(mqtt: mqtt)
      ..mqttSettings = MqttSettings(enabled: true, host: 'b');
    final d = Device(id: 'x', host: '10.0.0.2', name: 'Plug', mqttTopic: 'p');
    await store.upsert(d);

    mqtt.onPublish = (topic, payload) {
      if (topic == 'cmnd/p/Timers') {
        mqtt.inject('stat/p/RESULT', '{"Timers":"OFF"}');
        mqtt.inject('stat/p/RESULT',
            '{"Timers1":{"Timer1":{"Enable":1,"Time":"06:30","Action":1}}}');
        mqtt.inject('stat/p/RESULT',
            '{"Timers2":{"Timer5":{"Enable":0,"Time":"21:00","Action":0}}}');
      } else if (topic == 'cmnd/p/Timer1') {
        final j = jsonDecode(payload) as Map<String, dynamic>;
        mqtt.inject('stat/p/RESULT', jsonEncode({'Timer1': j}));
      }
    };

    final set = await store
        .commandCollect(d, 'Timers', window: const Duration(milliseconds: 50))
        .then(parseTimers);
    expect(set.active, isFalse);
    expect(set.timers.keys, containsAll([1, 5]));

    final t = set.timers[1]!.copy()
      ..time = '07:15'
      ..days = [false, true, true, true, true, true, false];
    final saved = await store.saveTimer(d, t);
    expect(mqtt.published.last.$1, 'cmnd/p/Timer1');
    expect(jsonDecode(mqtt.published.last.$2)['Days'], '0111110');
    expect(saved.time, '07:15');
  });

  test('locked device refuses switching', () async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore(mqtt: FakeMqtt());
    final d = Device(id: 'y', host: '10.0.0.3', name: 'Fridge');
    await store.upsert(d);
    await store.setLocked(d, true);
    expect(store.setPower(d, 'POWER', false), throwsException);
    expect(Device.decodeList(Device.encodeList([d])).single.locked, isTrue);
  });
}
