import 'package:flutter_test/flutter_test.dart';
import 'package:tasmo_hub/models/scene.dart';
import 'package:tasmo_hub/models/tasmota_rule.dart';

void main() {
  group('parseRule', () {
    test('nested reply (Tasmota 9+)', () {
      final r = parseRule(1, {
        'Rule1': {
          'State': 'ON',
          'Once': 'OFF',
          'StopOnError': 'ON',
          'Length': 37,
          'Free': 474,
          'Rules': 'ON System#Boot DO Power1 ON ENDON',
        }
      })!;
      expect(r.enabled, isTrue);
      expect(r.once, isFalse);
      expect(r.stopOnError, isTrue);
      expect(r.free, 474);
      expect(r.text, 'ON System#Boot DO Power1 ON ENDON');
    });

    test('legacy flat reply', () {
      final r = parseRule(2, {
        'Rule2': 'OFF',
        'Once': 'ON',
        'StopOnError': 'OFF',
        'Free': 511,
        'Rules': '',
      })!;
      expect(r.enabled, isFalse);
      expect(r.once, isTrue);
      expect(r.text, '');
    });

    test('missing rule returns null', () {
      expect(parseRule(3, {'Command': 'Unknown'}), isNull);
    });

    test('commands', () {
      final r = TasmotaRule(index: 2, text: '  ');
      expect(r.setTextCommand, 'Rule2 "');
      r.text = 'ON a#b DO c ENDON';
      expect(r.setTextCommand, 'Rule2 ON a#b DO c ENDON');
      expect(r.enableCommand(true), 'Rule2 1');
      expect(r.onceCommand(true), 'Rule2 5');
      expect(r.stopOnErrorCommand(false), 'Rule2 8');
    });
  });

  group('Scene', () {
    test('round-trips through JSON', () {
      final s = Scene(id: 'a', name: 'Night', actions: [
        SceneAction(deviceId: 'd1', command: 'POWER1 OFF'),
        SceneAction(deviceId: 'd2', command: 'Dimmer 20'),
      ]);
      final back = Scene.decodeList(Scene.encodeList([s])).single;
      expect(back.name, 'Night');
      expect(back.actions.map((a) => a.command), ['POWER1 OFF', 'Dimmer 20']);
      expect(back.actions.first.deviceId, 'd1');
    });

    test('isPower only matches relay commands', () {
      bool p(String c) => SceneAction(deviceId: 'x', command: c).isPower;
      expect(p('POWER1 ON'), isTrue);
      expect(p('Power OFF'), isTrue);
      expect(p('PowerOnState 1'), isFalse);
      expect(p('Dimmer 30'), isFalse);
    });
  });
}
