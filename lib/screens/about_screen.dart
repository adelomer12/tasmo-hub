import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_info.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static final _links = [
    ('Tasmota documentation', 'https://tasmota.github.io/docs/'),
    (
      'OpenBeken documentation',
      'https://github.com/openshwprojects/OpenBK7231T_App'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final build = gitSha.isEmpty ? 'local build' : gitSha.substring(0, 7);
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Image.asset('assets/app_icon.png', width: 96, height: 96),
            ),
          ),
          const SizedBox(height: 16),
          Center(child: Text('TasmoHub', style: theme.textTheme.headlineSmall)),
          Center(
            child: Text('Version $appVersion ($build)',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          const SizedBox(height: 24),
          const Text(
              'Local control for Tasmota and OpenBeken devices: switches, '
              'energy, timers, rules, scenes and firmware updates.'),
          const SizedBox(height: 16),
          Card(
            child: Column(children: const [
              ListTile(
                leading: Icon(Icons.wifi_tethering),
                title: Text('No cloud'),
                subtitle: Text('The app talks only to your devices and your '
                    'MQTT broker, over your own network.'),
              ),
              ListTile(
                leading: Icon(Icons.lock_outline),
                title: Text('Passwords stay on this phone'),
                subtitle: Text('Device and broker passwords are kept in the '
                    'phone\'s secure storage.'),
              ),
            ]),
          ),
          const SizedBox(height: 8),
          for (final (label, url) in _links)
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: Text(label),
              onTap: () => launchUrl(Uri.parse(url),
                  mode: LaunchMode.externalApplication),
            ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Open-source licenses'),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'TasmoHub',
              applicationVersion: appVersion,
            ),
          ),
        ],
      ),
    );
  }
}
