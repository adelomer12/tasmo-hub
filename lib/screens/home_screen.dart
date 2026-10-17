import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/device_store.dart';
import '../widgets/device_tile.dart';
import 'about_screen.dart';
import 'arrange_screen.dart';
import 'device_edit_dialog.dart';
import 'device_screen.dart';
import 'discovery_screen.dart';
import 'mqtt_settings_screen.dart';
import 'scenes_screen.dart';
import '../services/mqtt_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.store});
  final DeviceStore store;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  DeviceStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    store.startPolling();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    store.stopPolling();
    super.dispose();
  }

  // Poll only while visible: saves battery and keeps radios quiet.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      store.mqtt.ensureConnected();
      store.startPolling();
    } else if (state == AppLifecycleState.paused) {
      store.stopPolling();
    }
  }

  Future<void> _openScan() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => DiscoveryScreen(store: store)));
    store.refreshAll();
  }

  Future<void> _openMqtt() => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => MqttSettingsScreen(store: store)));

  Future<void> _openScenes() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => ScenesScreen(store: store)));

  Future<void> _openArrange() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => ArrangeScreen(store: store)));

  Future<void> _openAbout() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const AboutScreen()));

  Future<void> _addManual() async {
    await showDialog<void>(
        context: context, builder: (_) => AddDeviceDialog(store: store));
  }

  Future<void> _settings() async {
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Refresh interval'),
        children: [
          for (final s in const [0, 5, 10, 30, 60])
            ListTile(
              leading: Icon(s == store.pollSeconds
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked),
              title: Text(s == 0 ? 'Manual only' : 'Every $s s'),
              onTap: () => Navigator.pop(ctx, s),
            ),
        ],
      ),
    );
    if (v != null) await store.setPollSeconds(v);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final devices = store.devices;
        return Scaffold(
          appBar: AppBar(
            title: const Text('TasmoHub'),
            actions: [
              if (store.mqtt.state != MqttLinkState.disabled)
                IconButton(
                  tooltip: 'MQTT: ${store.mqtt.state.name}',
                  onPressed: _openMqtt,
                  icon: Icon(
                    Icons.hub_outlined,
                    color: switch (store.mqtt.state) {
                      MqttLinkState.connected => Colors.green,
                      MqttLinkState.error => Colors.red,
                      _ => Colors.amber,
                    },
                  ),
                ),
              IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => store.refreshAll(force: true)),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'add') _addManual();
                  if (v == 'settings') _settings();
                  if (v == 'mqtt') _openMqtt();
                  if (v == 'scenes') _openScenes();
                  if (v == 'arrange') _openArrange();
                  if (v == 'about') _openAbout();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'scenes', child: Text('Scenes')),
                  PopupMenuItem(value: 'arrange', child: Text('Arrange')),
                  PopupMenuItem(value: 'add', child: Text('Add by IP')),
                  PopupMenuItem(value: 'mqtt', child: Text('MQTT broker')),
                  PopupMenuItem(
                      value: 'settings', child: Text('Refresh interval')),
                  PopupMenuItem(value: 'about', child: Text('About')),
                ],
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _openScan,
            icon: const Icon(Icons.radar),
            label: const Text('Scan'),
          ),
          body: devices.isEmpty
              ? _EmptyState(onScan: _openScan, onAdd: _addManual)
              : RefreshIndicator(
                  onRefresh: () => store.refreshAll(force: true),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                    children: [
                      _SceneBar(store: store, onManage: _openScenes),
                      for (final room in store.rooms) ...[
                        _RoomHeader(store: store, room: room),
                        for (final d
                            in devices.where((d) => d.room.trim() == room))
                          DeviceTile(
                            store: store,
                            device: d,
                            onTap: () => _openDevice(d),
                          ),
                      ],
                    ],
                  ),
                ),
        );
      },
    );
  }

  void _openDevice(Device d) => Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DeviceScreen(store: store, deviceId: d.id)));
}

/// One-tap scene chips; long-press or the gear opens the scene list.
class _SceneBar extends StatelessWidget {
  const _SceneBar({required this.store, required this.onManage});
  final DeviceStore store;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final scenes = store.scenes;
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final s in scenes)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onLongPress: onManage,
                child: ActionChip(
                  avatar: const Icon(Icons.auto_awesome, size: 18),
                  label: Text(s.name),
                  onPressed: () => runSceneWithFeedback(context, store, s),
                ),
              ),
            ),
          ActionChip(
            avatar: Icon(scenes.isEmpty ? Icons.add : Icons.tune, size: 18),
            label: Text(scenes.isEmpty ? 'Add a scene' : 'Scenes'),
            onPressed: onManage,
          ),
        ],
      ),
    );
  }
}

class _RoomHeader extends StatelessWidget {
  const _RoomHeader({required this.store, required this.room});
  final DeviceStore store;
  final String room;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 0, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(room.isEmpty ? 'No room' : room,
                style: Theme.of(context).textTheme.titleSmall),
          ),
          TextButton(
              onPressed: () => _confirmAll(context, false),
              child: const Text('All off')),
          TextButton(
              onPressed: () => _confirmAll(context, true),
              child: const Text('All on')),
        ],
      ),
    );
  }

  Future<void> _confirmAll(BuildContext context, bool on) async {
    final count = store.devices.where((d) => d.room.trim() == room).length;
    final name = room.isEmpty ? 'with no room' : 'in $room';
    final word = on ? 'on' : 'off';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(on ? Icons.power : Icons.power_off),
        title: Text('Turn all $word?'),
        content: Text('This switches $word $count '
            '${count == 1 ? 'device' : 'devices'} $name. '
            'Locked devices are skipped.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('All $word')),
        ],
      ),
    );
    if (ok == true) await store.setRoomPower(room, on);
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onScan, required this.onAdd});
  final VoidCallback onScan;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.device_hub, size: 64),
            const SizedBox(height: 16),
            const Text(
              'No devices yet.\nScan your network for Tasmota and OpenBeken '
              'devices, or add one by IP.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
                onPressed: onScan,
                icon: const Icon(Icons.radar),
                label: const Text('Scan network')),
            const SizedBox(height: 8),
            OutlinedButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add),
                label: const Text('Add by IP')),
          ],
        ),
      ),
    );
  }
}
