import 'package:flutter/material.dart';

import '../models/device.dart';
import '../models/tasmota_timer.dart';
import '../services/device_store.dart';
import '../widgets/device_tile.dart';

/// Tasmota timer configuration: global `Timers` switch and Timer1..16.
class TimersScreen extends StatefulWidget {
  const TimersScreen({super.key, required this.store, required this.device});
  final DeviceStore store;
  final Device device;

  @override
  State<TimersScreen> createState() => _TimersScreenState();
}

class _TimersScreenState extends State<TimersScreen> {
  bool? _active;
  final Map<int, TasmotaTimer> _timers = {};
  bool _loading = true;
  String? _error;
  final Set<int> _busy = {};

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
      final set = await widget.store.fetchTimers(d);
      if (!mounted) return;
      setState(() {
        _active = set.active;
        _timers
          ..clear()
          ..addAll(set.timers);
        if (set.timers.isEmpty && set.active == null) {
          _error = 'This firmware did not return any timers. Timers need '
              'Tasmota (OpenBeken uses its own clock events).';
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _run(int idx, Future<TasmotaTimer> Function() op) async {
    setState(() => _busy.add(idx));
    try {
      final t = await op();
      if (mounted) setState(() => _timers[idx] = t);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy.remove(idx));
    }
  }

  Future<void> _setActive(bool v) async {
    final prev = _active;
    setState(() => _active = v);
    try {
      await widget.store.setTimersActive(d, v);
    } catch (e) {
      if (mounted) {
        setState(() => _active = prev);
        showError(context, e);
      }
    }
  }

  Future<void> _edit(TasmotaTimer t) async {
    final edited = await Navigator.of(context).push<TasmotaTimer>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => TimerEditScreen(
          timer: t.copy(),
          outputs: _outputNames(),
        ),
      ),
    );
    if (edited != null) {
      await _run(t.index, () => widget.store.saveTimer(d, edited));
    }
  }

  /// "1 - LG Q" style labels, one per relay.
  List<String> _outputNames() {
    final s = widget.store.stateOf(d);
    final n = s.relayKeys.isEmpty ? 1 : s.relayKeys.length;
    return [
      for (var i = 0; i < n; i++)
        i < s.friendlyNames.length && s.friendlyNames[i].isNotEmpty
            ? '${i + 1} - ${s.friendlyNames[i]}'
            : '${i + 1}',
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outputs = _outputNames();
    final indices = List.generate(TasmotaTimer.count, (i) => i + 1)
        .where((i) => _timers.containsKey(i))
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(d.name),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  if (_error != null)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.info_outline),
                        title: Text(_error!),
                      ),
                    ),
                  if (_active != null)
                    Card(
                      child: SwitchListTile(
                        title: const Text('Timer control active'),
                        subtitle: _active!
                            ? null
                            : const Text('All timers are paused'),
                        value: _active!,
                        onChanged: _setActive,
                      ),
                    ),
                  for (final i in indices)
                    _TimerCard(
                      timer: _timers[i]!,
                      outputName: _timers[i]!.output - 1 < outputs.length &&
                              _timers[i]!.output >= 1
                          ? outputs[_timers[i]!.output - 1]
                          : '${_timers[i]!.output}',
                      busy: _busy.contains(i),
                      dimmed: _active == false,
                      onToggle: (v) => _run(i, () {
                        final t = _timers[i]!.copy()..enable = v;
                        return widget.store.saveTimer(d, t);
                      }),
                      onEdit: () => _edit(_timers[i]!),
                      onClear: () =>
                          _run(i, () => widget.store.clearTimer(d, i)),
                    ),
                  if (indices.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'Timers run on the device itself, so they work even '
                        'when this phone is off. The device needs correct '
                        'time (NTP) and, for sunrise/sunset, its location.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _TimerCard extends StatelessWidget {
  const _TimerCard({
    required this.timer,
    required this.outputName,
    required this.busy,
    required this.dimmed,
    required this.onToggle,
    required this.onEdit,
    required this.onClear,
  });

  final TasmotaTimer timer;
  final String outputName;
  final bool busy;
  final bool dimmed;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final strong =
        theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600);
    return Opacity(
      opacity: (timer.enable && !dimmed) ? 1 : 0.6,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: busy ? null : onEdit,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text('${timer.index}', style: theme.textTheme.titleMedium),
                  const SizedBox(width: 8),
                  Switch(
                      value: timer.enable, onChanged: busy ? null : onToggle),
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  const Spacer(),
                  PopupMenuButton<String>(
                    enabled: !busy,
                    onSelected: (v) => v == 'edit' ? onEdit() : onClear(),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(value: 'clear', child: Text('Clear')),
                    ],
                  ),
                ]),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 16,
                    runSpacing: 4,
                    children: [
                      Text.rich(TextSpan(children: [
                        TextSpan(text: 'Action: ', style: muted),
                        TextSpan(text: timer.actionLabel, style: strong),
                      ])),
                      Text.rich(TextSpan(children: [
                        TextSpan(text: 'Output: ', style: muted),
                        TextSpan(text: outputName, style: strong),
                      ])),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                    'Time: ${timer.timeLabel}'
                    '${timer.window > 0 ? '  (±${timer.window} min)' : ''}',
                    style: theme.textTheme.bodyLarge),
                const SizedBox(height: 4),
                Text('${timer.daysLabel}${timer.repeat ? '' : '  · once'}',
                    style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen editor for one timer. Pops the edited timer, or null.
class TimerEditScreen extends StatefulWidget {
  const TimerEditScreen(
      {super.key, required this.timer, required this.outputs});
  final TasmotaTimer timer;
  final List<String> outputs;

  @override
  State<TimerEditScreen> createState() => _TimerEditScreenState();
}

class _TimerEditScreenState extends State<TimerEditScreen> {
  late final TasmotaTimer t = widget.timer;

  TimeOfDay _parseTime() {
    final m = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(t.time);
    if (m == null) return const TimeOfDay(hour: 0, minute: 0);
    return TimeOfDay(
        hour: int.parse(m.group(1)!) % 24, minute: int.parse(m.group(2)!) % 60);
  }

  bool get _negativeOffset => t.time.startsWith('-');

  void _setTime(TimeOfDay tod, {bool? negative}) {
    final hh = tod.hour.toString().padLeft(2, '0');
    final mm = tod.minute.toString().padLeft(2, '0');
    final neg = t.mode != 0 && (negative ?? _negativeOffset);
    setState(() => t.time = '${neg ? '-' : ''}$hh:$mm');
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _parseTime(),
      helpText: t.mode == 0
          ? 'Switch time'
          : 'Offset from ${TasmotaTimer.modeNames[t.mode].toLowerCase()}',
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked != null) _setTime(picked);
  }

  @override
  Widget build(BuildContext context) {
    final outputs = widget.outputs;
    final tod = _parseTime();
    final timeText =
        '${tod.hour.toString().padLeft(2, '0')}:${tod.minute.toString().padLeft(2, '0')}';
    return Scaffold(
      appBar: AppBar(
        title: Text('Timer ${t.index}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, t),
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enabled'),
            value: t.enable,
            onChanged: (v) => setState(() => t.enable = v),
          ),
          const SizedBox(height: 8),
          Text('Action', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: [
              for (var i = 0; i < 3; i++)
                ButtonSegment(
                    value: i, label: Text(TasmotaTimer.actionNames[i])),
              const ButtonSegment(value: 3, label: Text('Rule')),
            ],
            selected: {t.action.clamp(0, 3)},
            onSelectionChanged: (s) => setState(() => t.action = s.first),
          ),
          if (t.action == 3)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Triggers Clock#Timer in your rules instead of '
                  'switching a relay.'),
            ),
          const SizedBox(height: 16),
          if (outputs.length > 1 && t.action != 3)
            DropdownButtonFormField<int>(
              initialValue: t.output.clamp(1, outputs.length),
              decoration: const InputDecoration(labelText: 'Output'),
              items: [
                for (var i = 0; i < outputs.length; i++)
                  DropdownMenuItem(value: i + 1, child: Text(outputs[i])),
              ],
              onChanged: (v) => setState(() => t.output = v ?? 1),
            ),
          const SizedBox(height: 16),
          Text('Trigger', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: [
              for (var i = 0; i < 3; i++)
                ButtonSegment(value: i, label: Text(TasmotaTimer.modeNames[i])),
            ],
            selected: {t.mode.clamp(0, 2)},
            onSelectionChanged: (s) => setState(() {
              t.mode = s.first;
              if (t.mode == 0) t.time = t.time.replaceFirst('-', '');
            }),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule),
            title: Text(t.mode == 0
                ? 'Time'
                : 'Offset (${_negativeOffset ? 'before' : 'after'} ${TasmotaTimer.modeNames[t.mode].toLowerCase()})'),
            trailing: Text(
                '${t.mode != 0 ? (_negativeOffset ? '−' : '+') : ''}$timeText',
                style: Theme.of(context).textTheme.headlineSmall),
            onTap: _pickTime,
          ),
          if (t.mode != 0)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Before the event'),
              value: _negativeOffset,
              onChanged: (v) => _setTime(tod, negative: v),
            ),
          const SizedBox(height: 8),
          Text('Days', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            children: [
              for (var i = 0; i < 7; i++)
                FilterChip(
                  label: Text(TasmotaTimer.dayNames[i]),
                  selected: t.days[i],
                  onSelected: (v) => setState(() {
                    t.days = List.of(t.days)..[i] = v;
                  }),
                ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Repeat'),
            subtitle: const Text('Off = run once, then disable itself'),
            value: t.repeat,
            onChanged: (v) => setState(() => t.repeat = v),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Random window'),
            subtitle: Text(t.window == 0
                ? 'Exact time'
                : 'Fires at a random moment within ±${t.window} min'),
          ),
          Slider(
            value: t.window.toDouble().clamp(0, 15),
            min: 0,
            max: 15,
            divisions: 15,
            label: '±${t.window} min',
            onChanged: (v) => setState(() => t.window = v.round()),
          ),
        ],
      ),
    );
  }
}
