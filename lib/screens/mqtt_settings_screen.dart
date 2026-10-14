import 'package:flutter/material.dart';

import '../services/device_store.dart';
import '../services/mqtt_service.dart';

class MqttSettingsScreen extends StatefulWidget {
  const MqttSettingsScreen({super.key, required this.store});
  final DeviceStore store;

  @override
  State<MqttSettingsScreen> createState() => _MqttSettingsScreenState();
}

class _MqttSettingsScreenState extends State<MqttSettingsScreen> {
  late final MqttSettings _s = widget.store.mqttSettings;
  late final _host = TextEditingController(text: _s.host);
  late final _port = TextEditingController(text: '${_s.port}');
  late final _user = TextEditingController(text: _s.username);
  late final _pw = TextEditingController(text: _s.password);
  late final _clientId = TextEditingController(text: _s.clientId);
  late bool _enabled = _s.enabled;
  late bool _tls = _s.tls;
  late bool _selfSigned = _s.allowSelfSigned;
  late bool _prefer = _s.preferMqtt;
  bool _saving = false;
  bool _showPw = false;

  @override
  void dispose() {
    for (final c in [_host, _port, _user, _pw, _clientId]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final s = MqttSettings(
      enabled: _enabled,
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? (_tls ? 8883 : 1883),
      tls: _tls,
      allowSelfSigned: _tls && _selfSigned,
      username: _user.text.trim(),
      password: _pw.text,
      preferMqtt: _prefer,
      clientId: _clientId.text.trim().isEmpty ? null : _clientId.text.trim(),
    );
    await widget.store.saveMqttSettings(s);
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MQTT broker')),
      body: ListenableBuilder(
        listenable: widget.store.mqtt,
        builder: (context, _) {
          final m = widget.store.mqtt;
          final (label, color) = switch (m.state) {
            MqttLinkState.connected => ('Connected', Colors.green),
            MqttLinkState.connecting => ('Connecting…', Colors.amber),
            MqttLinkState.error => ('Error: ${m.lastError ?? ''}', Colors.red),
            MqttLinkState.disabled => ('Disabled', Colors.grey),
          };
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.circle, color: color, size: 14),
                title: Text(label),
                subtitle: m.isConnected
                    ? Text('${widget.store.mqttDiscovered.length} devices '
                        'announced via tasmota/discovery')
                    : null,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
                title: const Text('Use MQTT'),
              ),
              TextField(
                controller: _host,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                    labelText: 'Broker host', hintText: '192.168.10.5'),
              ),
              TextField(
                controller: _port,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Port'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _tls,
                onChanged: (v) => setState(() {
                  _tls = v;
                  if (_port.text == '1883' && v) _port.text = '8883';
                  if (_port.text == '8883' && !v) _port.text = '1883';
                }),
                title: const Text('TLS'),
              ),
              if (_tls)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _selfSigned,
                  onChanged: (v) => setState(() => _selfSigned = v),
                  title: const Text('Accept self-signed certificate'),
                  subtitle: const Text(
                      'Only for your own LAN broker. This disables certificate '
                      'checks and allows man-in-the-middle attacks.'),
                ),
              TextField(
                controller: _user,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'Username'),
              ),
              TextField(
                controller: _pw,
                obscureText: !_showPw,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Password',
                  helperText: _pw.text != _pw.text.trim()
                      ? 'Note: the password starts or ends with a space'
                      : null,
                  suffixIcon: IconButton(
                    tooltip: _showPw ? 'Hide password' : 'Show password',
                    icon:
                        Icon(_showPw ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _showPw = !_showPw),
                  ),
                ),
              ),
              TextField(
                controller: _clientId,
                decoration: const InputDecoration(labelText: 'Client ID'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _prefer,
                onChanged: (v) => setState(() => _prefer = v),
                title: const Text('Control devices over MQTT when connected'),
                subtitle: const Text(
                    'Off = MQTT only for live updates and discovery; '
                    'commands still go over HTTP'),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Connecting…' : 'Save and connect'),
              ),
            ],
          );
        },
      ),
    );
  }
}
