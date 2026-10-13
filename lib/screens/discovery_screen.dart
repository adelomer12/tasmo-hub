import 'dart:async';

import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/device_store.dart';
import '../services/discovery.dart';
import '../widgets/device_tile.dart';
import 'device_edit_dialog.dart';

class DiscoveryScreen extends StatefulWidget {
  const DiscoveryScreen({super.key, required this.store});
  final DeviceStore store;

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen> {
  late final DiscoveryService _svc = DiscoveryService(widget.store.api);
  final _range = TextEditingController();
  final _pw = TextEditingController();
  final Map<String, DiscoveredDevice> _found = {};
  final List<StreamSubscription<DiscoveredDevice>> _subs = [];
  bool _useMdns = true;
  bool _running = false;
  int _done = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    DiscoveryService.suggestedRange().then((r) {
      if (mounted && r != null && _range.text.isEmpty) {
        setState(() => _range.text = r);
      }
    });
  }

  @override
  void dispose() {
    _stop();
    _range.dispose();
    _pw.dispose();
    super.dispose();
  }

  void _stop() {
    _svc.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    if (mounted) setState(() => _running = false);
  }

  void _start() {
    final Ipv4Range range;
    try {
      range = Ipv4Range.parse(_range.text);
    } on FormatException catch (e) {
      showError(context, e.message);
      return;
    } catch (_) {
      showError(context, 'Enter a range like 192.168.20.0/24');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _found.clear();
      _running = true;
      _done = 0;
      _total = range.count;
    });

    var pending = _useMdns ? 2 : 1;
    void finished() {
      if (--pending == 0 && mounted) setState(() => _running = false);
    }

    void onFound(DiscoveredDevice d) {
      if (mounted) setState(() => _found[d.host] = d);
    }

    _subs.add(_svc.scan(range, password: _pw.text.isEmpty ? null : _pw.text,
        onProgress: (done, total) {
      if (mounted) setState(() => _done = done);
    }).listen(onFound, onDone: finished));
    if (_useMdns) {
      _subs.add(_svc.mdns().listen(onFound, onDone: finished));
    }
  }

  bool _isSaved(DiscoveredDevice d) => widget.store.devices.any((e) =>
      e.host == d.host ||
      (d.state != null && d.state!.mac.isNotEmpty && e.mac == d.state!.mac));

  Future<void> _add(DiscoveredDevice d) async {
    if (d.authRequired) {
      await showDialog<void>(
          context: context,
          builder: (_) =>
              AddDeviceDialog(store: widget.store, initialHost: d.host));
      setState(() {});
      return;
    }
    final st = d.state!;
    await widget.store.upsert(
      Device(
        id: st.mac.isNotEmpty ? st.mac : d.host,
        host: d.host,
        name: d.displayName,
        type: d.type,
        mac: st.mac,
      ),
      password: _pw.text.isEmpty ? null : _pw.text,
      state: st,
    );
    setState(() {});
  }

  Future<void> _addAll() async {
    for (final d in _found.values) {
      if (!d.authRequired && !_isSaved(d)) await _add(d);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _found.values.toList()
      ..sort((a, b) =>
          Ipv4Range.ipToInt(a.host).compareTo(Ipv4Range.ipToInt(b.host)));
    final addable = list.where((d) => !d.authRequired && !_isSaved(d)).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Find devices'),
        actions: [
          if (addable > 0)
            TextButton(onPressed: _addAll, child: Text('Add all ($addable)')),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(children: [
              TextField(
                controller: _range,
                enabled: !_running,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Subnet or range',
                  hintText: '192.168.20.0/24 or 192.168.20.10-80',
                  helperText:
                      'Scan the IoT VLAN directly if the phone is on another one',
                ),
              ),
              TextField(
                controller: _pw,
                enabled: !_running,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'Shared web password (optional)'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _useMdns,
                onChanged:
                    _running ? null : (v) => setState(() => _useMdns = v),
                title: const Text('Also browse mDNS'),
              ),
              Row(children: [
                Expanded(
                  child: _running
                      ? LinearProgressIndicator(
                          value: _total == 0 ? null : _done / _total)
                      : Text(_total == 0
                          ? 'Ready'
                          : 'Scanned $_done of $_total · found ${list.length}'),
                ),
                const SizedBox(width: 12),
                _running
                    ? OutlinedButton(
                        onPressed: _stop, child: const Text('Stop'))
                    : FilledButton.icon(
                        onPressed: _start,
                        icon: const Icon(Icons.radar),
                        label: const Text('Scan')),
              ]),
            ]),
          ),
          const Divider(height: 24),
          Expanded(
            child: ListenableBuilder(
              listenable: widget.store,
              builder: (context, _) {
                final fromBroker = widget.store.mqttDiscovered.values
                    .where((i) =>
                        (i.mac.isEmpty || widget.store.byMac(i.mac) == null) &&
                        !list.any((d) => d.host == i.ip && _isSaved(d)))
                    .toList()
                  ..sort((a, b) => a.name.compareTo(b.name));
                return ListView(children: [
                  if (fromBroker.isNotEmpty) ...[
                    const ListTile(
                        dense: true,
                        title: Text('Announced on the MQTT broker')),
                    for (final i in fromBroker)
                      ListTile(
                        leading: const Icon(Icons.hub_outlined),
                        title: Text(i.name),
                        subtitle: Text('${i.ip} · ${i.topic} · ${i.version}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: () => widget.store.addDiscovered(i),
                        ),
                      ),
                    if (list.isNotEmpty)
                      const ListTile(dense: true, title: Text('Network scan')),
                  ],
                  for (final d in list) _scanTile(d),
                ]);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _scanTile(DiscoveredDevice d) {
    final saved = _isSaved(d);
    final sub = [
      d.host,
      firmwareLabel(d.type),
      if (d.state?.version.isNotEmpty ?? false) d.state!.version,
      if (d.source != 'scan') d.source,
    ].join(' · ');
    return ListTile(
      key: ValueKey(d.host),
      leading: Icon(d.authRequired ? Icons.lock_outline : Icons.memory),
      title: Text(
          d.authRequired ? '${d.host} (password protected)' : d.displayName),
      subtitle: Text(sub),
      trailing: saved
          ? const Icon(Icons.check_circle, color: Colors.green)
          : IconButton(
              icon: const Icon(Icons.add_circle_outline),
              onPressed: () => _add(d)),
    );
  }
}
