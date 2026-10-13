import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/device_store.dart';

void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text('$e')));
}

/// Compact card: name, status line, headline sensors, one switch per relay.
class DeviceTile extends StatelessWidget {
  const DeviceTile(
      {super.key, required this.store, required this.device, this.onTap});

  final DeviceStore store;
  final Device device;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = store.stateOf(device);
    final theme = Theme.of(context);
    final relays = s.relayKeys;
    final headline = s.sensors
        .where((r) => const {
              'Temperature',
              'Humidity',
              'Power',
              'Illuminance',
              'CarbonDioxide',
            }.contains(r.key))
        .take(3)
        .map((r) => r.display)
        .join('  ·  ');

    final statusText = s.authRequired
        ? 'Password needed'
        : !s.online
            ? (s.updated == null && s.error == null ? 'Connecting…' : 'Offline')
            : headline.isNotEmpty
                ? headline
                : '${firmwareLabel(device.type)} · ${device.host}';

    final dot = s.authRequired
        ? Colors.amber
        : s.online
            ? Colors.green
            : (s.error == null ? Colors.grey : Colors.red);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Icon(
                s.hasLight ? Icons.lightbulb_outline : Icons.power_outlined,
                color: s.anyOn ? theme.colorScheme.primary : theme.disabledColor,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(device.name,
                        style: theme.textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Row(children: [
                      Icon(Icons.circle, size: 8, color: dot),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(statusText,
                            style: theme.textTheme.bodySmall,
                            overflow: TextOverflow.ellipsis),
                      ),
                    ]),
                  ],
                ),
              ),
              if (s.online)
                for (final k in relays)
                  Column(mainAxisSize: MainAxisSize.min, children: [
                    Switch(
                      value: s.power[k] ?? false,
                      onChanged: (v) async {
                        try {
                          await store.setPower(device, k, v);
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
                    ),
                    if (relays.length > 1)
                      Text(k.replaceFirst('POWER', '#'),
                          style: theme.textTheme.labelSmall),
                  ]),
            ],
          ),
        ),
      ),
    );
  }
}
