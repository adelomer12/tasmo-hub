import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/device_store.dart';

/// Drag rooms and the devices inside each room into the order the home
/// screen shows them. Every drop is saved at once.
class ArrangeScreen extends StatelessWidget {
  const ArrangeScreen({super.key, required this.store});
  final DeviceStore store;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Arrange devices')),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final rooms = store.rooms;
          return CustomScrollView(
            slivers: [
              if (rooms.length > 1) ...[
                const _Header('Rooms'),
                SliverReorderableList(
                  itemCount: rooms.length,
                  onReorderItem: (from, to) =>
                      store.reorderRooms(_moved(rooms, from, to)),
                  itemBuilder: (context, i) => _Row(
                    key: ValueKey('room:${rooms[i]}'),
                    index: i,
                    icon: Icons.meeting_room_outlined,
                    title: rooms[i].isEmpty ? 'No room' : rooms[i],
                  ),
                ),
              ],
              for (final room in rooms) ..._roomSlivers(room),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _roomSlivers(String room) {
    final List<Device> devices =
        store.devices.where((d) => d.room.trim() == room).toList();
    return [
      _Header(room.isEmpty ? 'No room' : room),
      SliverReorderableList(
        itemCount: devices.length,
        onReorderItem: (from, to) => store.reorderRoom(
            room, _moved([for (final d in devices) d.id], from, to)),
        itemBuilder: (context, i) => _Row(
          key: ValueKey('dev:${devices[i].id}'),
          index: i,
          icon: Icons.power_outlined,
          title: devices[i].name,
          subtitle: devices[i].host,
        ),
      ),
    ];
  }

  /// [to] is already the index after removing the item at [from].
  static List<T> _moved<T>(List<T> list, int from, int to) {
    final out = [...list];
    out.insert(to, out.removeAt(from));
    return out;
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(text,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.primary)),
        ),
      );
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.index,
    required this.icon,
    required this.title,
    this.subtitle,
  });
  final int index;
  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Material(
        child: ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle!),
          trailing: ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.drag_handle),
            ),
          ),
        ),
      );
}
