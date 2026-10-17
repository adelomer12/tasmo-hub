import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tasmo_hub/app_info.dart';
import 'package:tasmo_hub/models/device.dart';
import 'package:tasmo_hub/screens/about_screen.dart';
import 'package:tasmo_hub/screens/home_screen.dart';
import 'package:tasmo_hub/services/device_store.dart';

class _RecordingStore extends DeviceStore {
  final calls = <(String, bool)>[];
  @override
  Future<void> setRoomPower(String room, bool on) async =>
      calls.add((room, on));
  @override
  Future<void> refreshAll({bool force = false}) async {}
}

void main() {
  test('appVersion matches pubspec.yaml', () {
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('version:'));
    expect(line.split(':')[1].trim().split('+').first, appVersion);
  });

  testWidgets('All off asks first and only acts on confirm', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = _RecordingStore();
    for (final id in ['a', 'b']) {
      await store.upsert(
          Device(id: id, host: '10.0.0.$id', name: 'Dev $id', room: 'Kitchen'));
    }
    store.stopPolling();
    await tester.pumpWidget(MaterialApp(home: HomeScreen(store: store)));
    await tester.pump();

    await tester.tap(find.text('All off'));
    await tester.pumpAndSettle();
    expect(find.text('Turn all off?'), findsOneWidget);
    expect(find.textContaining('2 devices in Kitchen'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.calls, isEmpty);

    await tester.tap(find.text('All on'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'All on'));
    await tester.pumpAndSettle();
    expect(store.calls, [('Kitchen', true)]);
    store.stopPolling();
  });

  testWidgets('About screen shows name and version', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AboutScreen()));
    expect(find.text('TasmoHub'), findsOneWidget);
    expect(find.textContaining('Version $appVersion'), findsOneWidget);
    expect(find.text('TasmoHub on GitHub'), findsOneWidget);
    expect(find.text('Open-source licenses'), findsNothing);
  });
}
