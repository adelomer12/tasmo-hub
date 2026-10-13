import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/device.dart';
import '../services/device_store.dart';
import '../widgets/device_tile.dart';
import 'console_screen.dart';
import 'device_edit_dialog.dart';

class DeviceScreen extends StatefulWidget {
  const DeviceScreen({super.key, required this.store, required this.deviceId});
  final DeviceStore store;
  final String deviceId;

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  DeviceStore get store => widget.store;

  // Slider values while dragging, so polling does not fight the finger.
  double? _dimmer;
  double? _ct;
  double? _hue;

  @override
  void initState() {
    super.initState();
    final d = store.byId(widget.deviceId);
    if (d != null) store.refresh(d);
  }

  Future<void> _run(Device d, String cmnd) async {
    try {
      await store.command(d, cmnd);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _menu(Device d, String action) async {
    switch (action) {
      case 'edit':
        await showDialog<void>(
            context: context,
            builder: (_) => EditDeviceDialog(store: store, device: d));
      case 'console':
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ConsoleScreen(store: store, device: d)));
      case 'web':
        await launchUrl(Uri.parse('http://${d.host}/'),
            mode: LaunchMode.externalApplication);
      case 'restart':
        final ok = await _confirm('Restart ${d.name}?',
            'The device reboots and is offline for a few seconds.');
        if (ok) await _run(d, 'Restart 1');
      case 'delete':
        final ok = await _confirm('Remove ${d.name}?',
            'Only removes it from this app; the device is not changed.');
        if (ok) {
          await store.remove(d);
          if (mounted) Navigator.pop(context);
        }
    }
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('OK')),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final d = store.byId(widget.deviceId);
        if (d == null) return const Scaffold();
        final s = store.stateOf(d);
        final theme = Theme.of(context);
        return Scaffold(
          appBar: AppBar(
            title: Text(d.name),
            actions: [
              IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () => store.refresh(d)),
              PopupMenuButton<String>(
                onSelected: (a) => _menu(d, a),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'console', child: Text('Console')),
                  PopupMenuItem(value: 'web', child: Text('Open web UI')),
                  PopupMenuItem(value: 'restart', child: Text('Restart')),
                  PopupMenuItem(value: 'delete', child: Text('Remove')),
                ],
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: () => store.refresh(d),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (s.authRequired)
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: ListTile(
                      leading: const Icon(Icons.lock_outline),
                      title: const Text('This device needs its web password'),
                      trailing: TextButton(
                          onPressed: () => _menu(d, 'edit'),
                          child: const Text('Set')),
                    ),
                  )
                else if (!s.online && s.error != null)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.cloud_off),
                      title: const Text('Device is not responding'),
                      subtitle: Text('${s.error} · ${d.host}'),
                    ),
                  ),
                if (s.relayKeys.isNotEmpty) ...[
                  _section(context, 'Power'),
                  Card(
                    child: Column(children: [
                      for (final k in s.relayKeys)
                        SwitchListTile(
                          title: Text(s.relayKeys.length == 1
                              ? 'Power'
                              : 'Relay ${k.replaceFirst('POWER', '')}'),
                          value: s.power[k] ?? false,
                          onChanged: s.online
                              ? (v) => store.setPower(d, k, v).catchError(
                                  (Object e) {
                                    if (context.mounted) showError(context, e);
                                  })
                              : null,
                        ),
                    ]),
                  ),
                ],
                if (s.hasLight) ...[
                  _section(context, 'Light'),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(children: [
                        if (s.dimmer != null)
                          _slider(
                            icon: Icons.brightness_6,
                            label: 'Brightness ${(_dimmer ?? s.dimmer!.toDouble()).round()}%',
                            value: _dimmer ?? s.dimmer!.toDouble(),
                            min: 0,
                            max: 100,
                            onChanged: (v) => setState(() => _dimmer = v),
                            onEnd: (v) async {
                              await _run(d, 'Dimmer ${v.round()}');
                              setState(() => _dimmer = null);
                            },
                          ),
                        if (s.ct != null)
                          _slider(
                            icon: Icons.thermostat,
                            label: 'White temperature '
                                '${(1000000 / (_ct ?? s.ct!.toDouble())).round()} K',
                            value: (_ct ?? s.ct!.toDouble()).clamp(153, 500),
                            min: 153,
                            max: 500,
                            onChanged: (v) => setState(() => _ct = v),
                            onEnd: (v) async {
                              await _run(d, 'CT ${v.round()}');
                              setState(() => _ct = null);
                            },
                          ),
                        if (s.hsb != null) ...[
                          _slider(
                            icon: Icons.palette_outlined,
                            label: 'Colour',
                            value: _hue ?? s.hsb![0].toDouble(),
                            min: 0,
                            max: 360,
                            color: HSVColor.fromAHSV(
                                    1, (_hue ?? s.hsb![0].toDouble()) % 360, 1, 1)
                                .toColor(),
                            onChanged: (v) => setState(() => _hue = v),
                            onEnd: (v) async {
                              // HSBColor1 sets only the hue, keeping sat/bri.
                              await _run(d, 'HSBColor1 ${v.round()}');
                              setState(() => _hue = null);
                            },
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Wrap(spacing: 8, children: [
                              for (final c in const [
                                ('Warm', 'White 100'),
                                ('Red', 'Color 1'),
                                ('Green', 'Color 3'),
                                ('Blue', 'Color 5'),
                              ])
                                ActionChip(
                                    label: Text(c.$1),
                                    onPressed: () => _run(d, c.$2)),
                            ]),
                          ),
                        ],
                      ]),
                    ),
                  ),
                ],
                if (s.sensors.isNotEmpty) ...[
                  _section(context, 'Sensors'),
                  Card(
                    child: Column(children: [
                      for (final r in s.sensors)
                        ListTile(
                          dense: true,
                          title: Text(r.key),
                          subtitle: r.group.isEmpty ? null : Text(r.group),
                          trailing: Text(r.display,
                              style: theme.textTheme.titleMedium),
                        ),
                    ]),
                  ),
                ],
                _section(context, 'Device'),
                Card(
                  child: Column(children: [
                    _info('Firmware', '${firmwareLabel(d.type)} ${s.version}'),
                    _info('Hardware', s.hardware),
                    _info('Address', d.host),
                    _info('Hostname', s.hostname),
                    _info('MAC', s.mac.isNotEmpty ? s.mac : d.mac),
                    _info('Wi-Fi',
                        [if (s.ssid.isNotEmpty) s.ssid, if (s.rssi != null) 'RSSI ${s.rssi}%', if (s.signal != null) '${s.signal} dBm'].join(' · ')),
                    _info('Uptime', s.uptime),
                    _info('Room', d.room),
                    _info(
                        'Updated',
                        s.updated == null
                            ? ''
                            : TimeOfDay.fromDateTime(s.updated!).format(context)),
                  ]),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _section(BuildContext context, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
        child: Text(t, style: Theme.of(context).textTheme.titleSmall),
      );

  Widget _info(String k, String v) => v.trim().isEmpty
      ? const SizedBox.shrink()
      : ListTile(dense: true, title: Text(k), trailing: Text(v));

  Widget _slider({
    required IconData icon,
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onEnd,
    Color? color,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Text(label),
          ]),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            activeColor: color,
            onChanged: onChanged,
            onChangeEnd: onEnd,
          ),
        ],
      ),
    );
  }
}
