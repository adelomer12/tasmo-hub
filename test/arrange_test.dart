import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tasmo_hub/models/device.dart';
import 'package:tasmo_hub/screens/arrange_screen.dart';
import 'package:tasmo_hub/services/device_store.dart';

Future<DeviceStore> _store() async {
  SharedPreferences.setMockInitialValues({});
  final store = DeviceStore();
  for (final (id, room) in [
    ('a', 'Kitchen'),
    ('b', 'Bedroom'),
    ('c', 'Kitchen'),
    ('d', 'Kitchen'),
  ]) {
    await store.upsert(
        Device(id: id, host: '10.0.0.$id', name: 'Dev $id', room: room));
  }
  return store;
}

List<String> _ids(DeviceStore s) => [for (final d in s.devices) d.id];

void main() {
  test('reorderRoom moves devices only within their room slots', () async {
    final store = await _store();
    await store.reorderRoom('Kitchen', ['d', 'a', 'c']);
    expect(_ids(store), ['d', 'b', 'a', 'c']);
    expect(() => store.reorderRoom('Kitchen', ['a', 'c']), throwsArgumentError);
  });

  test('room order is saved and survives a reload', () async {
    final store = await _store();
    expect(store.rooms, ['Bedroom', 'Kitchen']);
    await store.reorderRooms(['Kitchen', 'Bedroom']);
    await store.reorderRoom('Kitchen', ['c', 'd', 'a']);

    final reloaded = DeviceStore();
    await reloaded.load();
    expect(reloaded.rooms, ['Kitchen', 'Bedroom']);
    expect(_ids(reloaded), ['c', 'b', 'd', 'a']);

    // A new room the user never placed goes after the arranged ones.
    await reloaded.upsert(
        Device(id: 'e', host: '10.0.0.9', name: 'Dev e', room: 'Attic'));
    expect(reloaded.rooms, ['Kitchen', 'Bedroom', 'Attic']);
    reloaded.dispose();
    store.dispose();
  });

  testWidgets('dragging a device handle reorders the room', (tester) async {
    final store = await _store();
    await tester.pumpWidget(MaterialApp(home: ArrangeScreen(store: store)));
    expect(find.text('Rooms'), findsOneWidget);

    final handle = find.descendant(
        of: find.ancestor(
            of: find.text('Dev a'), matching: find.byType(ListTile)),
        matching: find.byIcon(Icons.drag_handle));
    final rowHeight = tester.getSize(find.byType(ListTile).first).height;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(Offset(0, rowHeight * 2.5));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();
    expect([
      for (final d in store.devices)
        if (d.room == 'Kitchen') d.id
    ], [
      'c',
      'd',
      'a'
    ]);
    await tester.pump(const Duration(seconds: 1));
  });
}
