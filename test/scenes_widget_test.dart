import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tasmo_hub/models/scene.dart';
import 'package:tasmo_hub/screens/scenes_screen.dart';
import 'package:tasmo_hub/services/device_store.dart';

void main() {
  testWidgets('scene list and editor render', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeviceStore();
    await store.upsertScene(Scene(id: 'a', name: 'Night', actions: [
      SceneAction(deviceId: 'gone', command: 'POWER1 OFF'),
    ]));
    await tester.pumpWidget(MaterialApp(home: ScenesScreen(store: store)));
    expect(find.text('Night'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Removed device'), findsOneWidget);
    expect(find.text('POWER1 OFF'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });
}
