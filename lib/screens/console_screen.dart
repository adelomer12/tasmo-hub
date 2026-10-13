import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/device_store.dart';

/// Raw command console, like the Tasmota web console but over `/cm`.
class ConsoleScreen extends StatefulWidget {
  const ConsoleScreen({super.key, required this.store, required this.device});
  final DeviceStore store;
  final Device device;

  @override
  State<ConsoleScreen> createState() => _ConsoleScreenState();
}

class _ConsoleScreenState extends State<ConsoleScreen> {
  final _cmd = TextEditingController();
  final _scroll = ScrollController();
  final List<(String, String, bool)> _log = [];
  bool _busy = false;

  static const _quick = ['Status 0', 'Status 8', 'Power', 'Timers', 'Rule1', 'IPAddress'];

  @override
  void dispose() {
    _cmd.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send([String? text]) async {
    final c = (text ?? _cmd.text).trim();
    if (c.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final res = await widget.store.command(widget.device, c);
      _log.add((c, const JsonEncoder.withIndent('  ').convert(res), false));
    } catch (e) {
      _log.add((c, '$e', true));
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _cmd.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final mono = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(fontFamily: 'monospace');
    return Scaffold(
      appBar: AppBar(title: Text('Console · ${widget.device.name}')),
      body: Column(children: [
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(12),
            itemCount: _log.length,
            itemBuilder: (_, i) {
              final (cmd, out, err) = _log[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('> $cmd', style: mono?.copyWith(fontWeight: FontWeight.bold)),
                    SelectableText(out,
                        style: mono?.copyWith(
                            color: err ? Theme.of(context).colorScheme.error : null)),
                  ],
                ),
              );
            },
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final q in _quick)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ActionChip(label: Text(q), onPressed: () => _send(q)),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _cmd,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                      hintText: 'Command, e.g. Backlog Power1 ON; Dimmer 50'),
                ),
              ),
              IconButton(
                onPressed: _busy ? null : _send,
                icon: _busy
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
