import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/device_store.dart';
import '../services/discovery.dart';
import '../widgets/device_tile.dart';

/// Add a device by IP/hostname: probes it first so only real
/// Tasmota/OpenBeken devices get saved.
class AddDeviceDialog extends StatefulWidget {
  const AddDeviceDialog({super.key, required this.store, this.initialHost});
  final DeviceStore store;
  final String? initialHost;

  @override
  State<AddDeviceDialog> createState() => _AddDeviceDialogState();
}

class _AddDeviceDialogState extends State<AddDeviceDialog> {
  late final _host = TextEditingController(text: widget.initialHost ?? '');
  final _user = TextEditingController(text: 'admin');
  final _pw = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _host.dispose();
    _user.dispose();
    _pw.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final host = _host.text.trim();
    if (host.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final found = await DiscoveryService(widget.store.api).probe(host,
        source: 'manual', username: _user.text.trim(), password: _pw.text);
    if (!mounted) return;
    if (found == null) {
      setState(() {
        _busy = false;
        _error = 'No Tasmota/OpenBeken API answered at $host';
      });
      return;
    }
    if (found.authRequired) {
      setState(() {
        _busy = false;
        _error = 'Wrong or missing web password';
      });
      return;
    }
    final st = found.state!;
    await widget.store.upsert(
      Device(
        id: st.mac.isNotEmpty ? st.mac : host,
        host: host,
        name: found.displayName,
        type: found.type,
        username: _user.text.trim(),
        mac: st.mac,
      ),
      password: _pw.text,
      state: st,
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final host = _host.text.trim();
    final public = host.isNotEmpty && !isPrivateIPv4(host);
    return AlertDialog(
      title: const Text('Add device'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _host,
            autofocus: widget.initialHost == null,
            keyboardType: TextInputType.url,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
                labelText: 'IP or hostname', hintText: '192.168.20.31'),
          ),
          if (public)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Warning: this is not a private LAN address. The device '
                'API is plain HTTP; never expose it to the internet.',
                style: TextStyle(color: Colors.orange),
              ),
            ),
          TextField(
            controller: _user,
            decoration: const InputDecoration(labelText: 'Web user'),
          ),
          TextField(
            controller: _pw,
            obscureText: true,
            decoration: const InputDecoration(
                labelText: 'Web password (if set)'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Add'),
        ),
      ],
    );
  }
}

/// Edit name, room, address and credentials of a saved device.
class EditDeviceDialog extends StatefulWidget {
  const EditDeviceDialog({super.key, required this.store, required this.device});
  final DeviceStore store;
  final Device device;

  @override
  State<EditDeviceDialog> createState() => _EditDeviceDialogState();
}

class _EditDeviceDialogState extends State<EditDeviceDialog> {
  late final _name = TextEditingController(text: widget.device.name);
  late final _room = TextEditingController(text: widget.device.room);
  late final _host = TextEditingController(text: widget.device.host);
  late final _user = TextEditingController(text: widget.device.username);
  final _pw = TextEditingController();
  bool _changePw = false;

  @override
  void dispose() {
    for (final c in [_name, _room, _host, _user, _pw]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final d = widget.device;
    await widget.store.update(d,
        name: _name.text.trim().isEmpty ? d.name : _name.text.trim(),
        room: _room.text.trim(),
        host: _host.text.trim().isEmpty ? d.host : _host.text.trim(),
        username: _user.text.trim());
    if (_changePw) await widget.store.setPassword(d, _pw.text);
    await widget.store.refresh(d);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final rooms = widget.store.rooms.where((r) => r.isNotEmpty).toList();
    return AlertDialog(
      title: const Text('Edit device'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name')),
          TextField(
              controller: _room,
              decoration: const InputDecoration(labelText: 'Room / group')),
          if (rooms.isNotEmpty)
            Wrap(spacing: 6, children: [
              for (final r in rooms)
                ActionChip(
                    label: Text(r), onPressed: () => _room.text = r),
            ]),
          TextField(
              controller: _host,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'IP or hostname')),
          TextField(
              controller: _user,
              decoration: const InputDecoration(labelText: 'Web user')),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _changePw,
            onChanged: (v) => setState(() => _changePw = v ?? false),
            title: Text(widget.store.passwordOf(widget.device) == null
                ? 'Set web password'
                : 'Change web password'),
          ),
          if (_changePw)
            TextField(
              controller: _pw,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'Web password', helperText: 'Empty = remove'),
            ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => _save().catchError((Object e) {
                  if (context.mounted) showError(context, e);
                }),
            child: const Text('Save')),
      ],
    );
  }
}
