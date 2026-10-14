import 'package:flutter/material.dart';

import '../models/device.dart';
import '../models/tasmota_rule.dart';
import '../services/device_store.dart';
import '../widgets/device_tile.dart';

/// Lists Rule1..Rule3 with an enable switch each; tap to edit.
class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key, required this.store, required this.device});
  final DeviceStore store;
  final Device device;

  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends State<RulesScreen> {
  final Map<int, TasmotaRule> _rules = {};
  String? _error;
  bool _loading = true;

  DeviceStore get store => widget.store;
  Device get d => widget.device;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // One at a time: cheap radios drop parallel requests.
      for (var i = 1; i <= TasmotaRule.count; i++) {
        _rules[i] = await store.fetchRule(d, i);
      }
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _toggle(TasmotaRule r, bool on) async {
    try {
      final fresh = await store.setRuleEnabled(d, r, on);
      setState(() => _rules[r.index] = fresh);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _edit(TasmotaRule r) async {
    final saved = await Navigator.of(context).push<TasmotaRule>(
        MaterialPageRoute(
            builder: (_) => RuleEditScreen(store: store, device: d, rule: r)));
    if (saved != null) setState(() => _rules[saved.index] = saved);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('Rules · ${d.name}'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: d.type == FirmwareType.openbeken
          ? const _Message(
              icon: Icons.info_outline,
              text: 'OpenBeken does not use Tasmota rules. It runs '
                  'autoexec.bat scripts and addEventHandler commands, which '
                  'you can edit in its web UI under "Filesystem", or send '
                  'from the Console here.')
          : _loading && _rules.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      if (_error != null)
                        Card(
                          color: theme.colorScheme.errorContainer,
                          child: ListTile(
                            leading: const Icon(Icons.error_outline),
                            title: Text(_error!),
                          ),
                        ),
                      for (var i = 1; i <= TasmotaRule.count; i++)
                        if (_rules[i] != null) _ruleCard(_rules[i]!, theme),
                      const SizedBox(height: 8),
                      Text(
                        'Rules run on the device itself, so they keep working '
                        'without this app, Wi-Fi to the phone, or a server.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _ruleCard(TasmotaRule r, ThemeData theme) {
    final flags = [
      if (r.once) 'Once',
      if (r.stopOnError) 'Stop on error',
      if (r.free != null) '${r.free} free',
    ].join(' · ');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _edit(r),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Rule${r.index}',
                        style: theme.textTheme.titleMedium),
                  ),
                  Switch(
                    value: r.enabled,
                    onChanged:
                        r.text.trim().isEmpty ? null : (v) => _toggle(r, v),
                  ),
                ],
              ),
              Text(
                r.text.trim().isEmpty ? 'Empty: tap to write a rule' : r.text,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: r.text.trim().isEmpty
                    ? theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.hintColor)
                    : const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
              if (flags.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(flags, style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class RuleEditScreen extends StatefulWidget {
  const RuleEditScreen(
      {super.key,
      required this.store,
      required this.device,
      required this.rule});
  final DeviceStore store;
  final Device device;
  final TasmotaRule rule;

  @override
  State<RuleEditScreen> createState() => _RuleEditScreenState();
}

class _RuleEditScreenState extends State<RuleEditScreen> {
  late final TextEditingController _text;
  late bool _enabled = widget.rule.enabled;
  late bool _once = widget.rule.once;
  late bool _stop = widget.rule.stopOnError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: _pretty(widget.rule.text));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// One trigger per line for reading; the device stores a single line.
  static String _pretty(String rule) => rule
      .replaceAllMapped(
          RegExp(r'\s+(ON\s+\S+#)', caseSensitive: false), (m) => '\n${m[1]}')
      .trim();

  static String _flatten(String text) => text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .join(' ');

  void _insert(String snippet) {
    final cur = _text.text.trimRight();
    _text.text = cur.isEmpty ? snippet : '$cur\n$snippet';
    _text.selection = TextSelection.collapsed(offset: _text.text.length);
    setState(() {});
  }

  Future<void> _save() async {
    final flat = _flatten(_text.text);
    final r = TasmotaRule(
      index: widget.rule.index,
      enabled: flat.isNotEmpty && _enabled,
      once: _once,
      stopOnError: _stop,
      text: flat,
    );
    setState(() => _saving = true);
    try {
      final saved = await widget.store.saveRule(widget.device, r);
      if (!mounted) return;
      if (flat.isNotEmpty && saved.text.trim().isEmpty) {
        showError(context,
            'The device did not keep the rule. Check the syntax or length.');
        setState(() => _saving = false);
        return;
      }
      Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) {
        showError(context, e);
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _clear() async {
    _text.clear();
    setState(() => _enabled = false);
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final len = _flatten(_text.text).length;
    return Scaffold(
      appBar: AppBar(
        title: Text('Rule${widget.rule.index}'),
        actions: [
          IconButton(
            tooltip: 'Clear rule',
            icon: const Icon(Icons.delete_outline),
            onPressed: _saving ? null : _clear,
          ),
          IconButton(
            tooltip: 'Save',
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check),
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _text,
            minLines: 8,
            maxLines: null,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.multiline,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: 'ON Power1#State=1 DO Publish stat/x/y on ENDON',
              helperText: '$len / ${TasmotaRule.maxLength} characters'
                  '${len > TasmotaRule.maxLength ? ' (may not fit)' : ''}',
            ),
          ),
          const SizedBox(height: 12),
          Text('Insert example', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final (label, rule) in ruleSnippets)
                ActionChip(label: Text(label), onPressed: () => _insert(rule)),
            ],
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enabled'),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Once'),
            subtitle: const Text(
                'Each trigger fires one time, then waits until it is false again'),
            value: _once,
            onChanged: (v) => setState(() => _once = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Stop on error'),
            subtitle: const Text(
                'Disable this rule set if it causes an exception loop'),
            value: _stop,
            onChanged: (v) => setState(() => _stop = v),
          ),
          const SizedBox(height: 8),
          Text(
            'Each line is shown separately for reading; the device stores '
            'the rule as one line. Syntax: ON <trigger> DO <command> ENDON. '
            'Use Backlog to run several commands.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48),
              const SizedBox(height: 16),
              Text(text, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
}
