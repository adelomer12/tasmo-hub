import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/device_store.dart';
import '../widgets/device_tile.dart';
import 'device_edit_dialog.dart';
import 'device_screen.dart';
import 'discovery_screen.dart';
import 'mqtt_settings_screen.dart';
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
            RadioListTile<int>(
              value: s,
              groupValue: store.pollSeconds,
              title: Text(s == 0 ? 'Manual only' : 'Every $s s'),
              onChanged: (x) => Navigator.pop(ctx, x),
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
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'add', child: Text('Add by IP')),
                  PopupMenuItem(value: 'mqtt', child: Text('MQTT broker')),
                  PopupMenuItem(
                      value: 'settings', child: Text('Refresh interval')),
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
              onPressed: () => store.setRoomPower(room, false),
              child: const Text('All off')),
          TextButton(
              onPressed: () => store.setRoomPower(room, true),
              child: const Text('All on')),
        ],
      ),
    );
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
