import 'package:flutter/material.dart';

import '../models/device.dart';
import '../models/scene.dart';
import '../services/device_store.dart';
import '../widgets/device_tile.dart';

/// Runs a scene and reports the outcome in a snackbar.
Future<void> runSceneWithFeedback(
    BuildContext context, DeviceStore store, Scene scene) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
        content: Text('Running ${scene.name}…'),
        duration: const Duration(seconds: 1)));
  final r = await store.runScene(scene);
  final detail = [...r.failed, ...r.skipped];
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text('${scene.name}: ${r.summary}'
          '${detail.isEmpty ? '' : '\n${detail.take(3).join('\n')}'}'),
    ));
}

/// Readable label for a scene step, e.g. "Lamp: on" or "Dimmer 40".
String describeAction(DeviceStore store, SceneAction a) {
  final d = store.byId(a.deviceId);
  final m = RegExp(r'^POWER(\d*)\s+(\w+)$', caseSensitive: false)
      .firstMatch(a.command.trim());
  if (d != null && m != null) {
    final idx = int.tryParse(m[1]!.isEmpty ? '1' : m[1]!) ?? 1;
    final names = store.stateOf(d).friendlyNames;
    final relays = store.stateOf(d).relayKeys.length;
    final relay = relays > 1
        ? (idx - 1 < names.length && names[idx - 1].isNotEmpty
            ? names[idx - 1]
            : 'Relay $idx')
        : null;
    final verb = m[2]!.toLowerCase();
    return relay == null ? 'Turn $verb' : '$relay: turn $verb';
  }
  return a.command;
}

class ScenesScreen extends StatelessWidget {
  const ScenesScreen({super.key, required this.store});
  final DeviceStore store;

  Future<void> _edit(BuildContext context, Scene? s) =>
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => SceneEditScreen(store: store, scene: s)));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final scenes = store.scenes;
        return Scaffold(
          appBar: AppBar(title: const Text('Scenes')),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _edit(context, null),
            icon: const Icon(Icons.add),
            label: const Text('New scene'),
          ),
          body: scenes.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'A scene sends commands to several devices with one '
                      'tap, e.g. "Night": hall light off, bedroom lamp 20%, '
                      'heater off.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ReorderableListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                  itemCount: scenes.length,
                  onReorderItem: store.reorderScenes,
                  itemBuilder: (context, i) {
                    final s = scenes[i];
                    final devices = s.actions.map((a) => a.deviceId).toSet();
                    return Card(
                      key: ValueKey(s.id),
                      child: ListTile(
                        leading: const Icon(Icons.auto_awesome),
                        title: Text(s.name),
                        subtitle: Text('${s.actions.length} steps · '
                            '${devices.length} devices'),
                        onTap: () => runSceneWithFeedback(context, store, s),
                        trailing: IconButton(
                          tooltip: 'Edit',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _edit(context, s),
                        ),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}

class SceneEditScreen extends StatefulWidget {
  const SceneEditScreen({super.key, required this.store, this.scene});
  final DeviceStore store;
  final Scene? scene;

  @override
  State<SceneEditScreen> createState() => _SceneEditScreenState();
}

class _SceneEditScreenState extends State<SceneEditScreen> {
  late final Scene _scene = widget.scene?.copy() ??
      Scene(
          id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
          name: '');
  late final TextEditingController _name =
      TextEditingController(text: _scene.name);

  DeviceStore get store => widget.store;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      showError(context, 'Give the scene a name');
      return;
    }
    if (_scene.actions.isEmpty) {
      showError(context, 'Add at least one step');
      return;
    }
    _scene.name = name;
    await store.upsertScene(_scene);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Delete ${_scene.name}?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Delete')),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    await store.removeScene(_scene);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _addStep() async {
    final device = await showModalBottomSheet<Device>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Choose a device')),
            for (final d in store.devices)
              ListTile(
                leading: Icon(d.locked ? Icons.lock_outline : Icons.power),
                title: Text(d.name),
                subtitle: Text(d.room.isEmpty ? d.host : d.room),
                onTap: () => Navigator.pop(ctx, d),
              ),
          ],
        ),
      ),
    );
    if (device == null || !mounted) return;
    final actions = await showModalBottomSheet<List<SceneAction>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _ActionPicker(store: store, device: device),
    );
    if (actions != null && actions.isNotEmpty) {
      setState(() => _scene.actions.addAll(actions));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.scene == null ? 'New scene' : 'Edit scene'),
        actions: [
          if (widget.scene != null)
            IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: _delete),
          IconButton(
              tooltip: 'Save', icon: const Icon(Icons.check), onPressed: _save),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: store.devices.isEmpty ? null : _addStep,
        icon: const Icon(Icons.add),
        label: const Text('Add step'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
                labelText: 'Name', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          if (_scene.actions.isEmpty)
            Text(
                'No steps yet. Tap "Add step" to pick a device and what it '
                'should do.',
                style: theme.textTheme.bodyMedium)
          else
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorderItem: (from, to) => setState(() {
                _scene.actions.insert(to, _scene.actions.removeAt(from));
              }),
              children: [
                for (var i = 0; i < _scene.actions.length; i++)
                  _stepTile(i, _scene.actions[i]),
              ],
            ),
          const SizedBox(height: 12),
          Text(
            'Devices run at the same time; steps for one device run in this '
            'order. Relay steps are skipped for devices with switching locked.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _stepTile(int i, SceneAction a) {
    final d = store.byId(a.deviceId);
    return Card(
      key: ObjectKey(a),
      child: ListTile(
        leading: ReorderableDragStartListener(
            index: i, child: const Icon(Icons.drag_handle)),
        title: Text(d?.name ?? 'Removed device'),
        subtitle: Text(describeAction(store, a)),
        onTap: () => _editCommand(a),
        trailing: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => setState(() => _scene.actions.removeAt(i)),
        ),
      ),
    );
  }

  Future<void> _editCommand(SceneAction a) async {
    final c = TextEditingController(text: a.command);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Command'),
        content: TextField(
          controller: c,
          autofocus: true,
          autocorrect: false,
          style: const TextStyle(fontFamily: 'monospace'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('OK')),
        ],
      ),
    );
    c.dispose();
    if (v != null && v.isNotEmpty) setState(() => a.command = v);
  }
}

/// Bottom sheet that turns a device into one or more scene steps.
class _ActionPicker extends StatefulWidget {
  const _ActionPicker({required this.store, required this.device});
  final DeviceStore store;
  final Device device;

  @override
  State<_ActionPicker> createState() => _ActionPickerState();
}

class _ActionPickerState extends State<_ActionPicker> {
  late final DeviceState s = widget.store.stateOf(widget.device);
  late double _dimmer = (s.dimmer ?? 50).toDouble();
  late double _ct = (s.ct ?? 326).clamp(153, 500).toDouble();
  final _custom = TextEditingController();

  Device get d => widget.device;

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  void _pick(List<String> commands) => Navigator.pop(context, [
        for (final c in commands) SceneAction(deviceId: d.id, command: c),
      ]);

  String _relayName(int i) {
    if (s.relayKeys.length <= 1) return 'Power';
    final n = s.friendlyNames;
    return i < n.length && n[i].isNotEmpty ? n[i] : 'Relay ${i + 1}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final relays = s.relayKeys.isEmpty ? const ['POWER1'] : s.relayKeys;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            left: 16,
            right: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(d.name, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              if (s.relayKeys.isNotEmpty)
                OutlinedButton.icon(
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: const Text('Use its current state'),
                  onPressed: () =>
                      Navigator.pop(context, widget.store.captureState(d)),
                ),
              for (var i = 0; i < relays.length; i++) ...[
                const SizedBox(height: 12),
                Text(_relayName(i), style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Wrap(spacing: 8, children: [
                  for (final v in const ['ON', 'OFF', 'TOGGLE'])
                    ActionChip(
                      label: Text(v[0] + v.substring(1).toLowerCase()),
                      onPressed: () => _pick(['${relays[i]} $v']),
                    ),
                ]),
              ],
              if (s.dimmer != null) ...[
                const SizedBox(height: 12),
                Text('Brightness ${_dimmer.round()}%',
                    style: theme.textTheme.titleSmall),
                Row(children: [
                  Expanded(
                    child: Slider(
                      value: _dimmer,
                      min: 1,
                      max: 100,
                      onChanged: (v) => setState(() => _dimmer = v),
                    ),
                  ),
                  TextButton(
                      onPressed: () => _pick(['Dimmer ${_dimmer.round()}']),
                      child: const Text('Add')),
                ]),
              ],
              if (s.ct != null) ...[
                Text('White temperature (CT ${_ct.round()})',
                    style: theme.textTheme.titleSmall),
                Row(children: [
                  Expanded(
                    child: Slider(
                      value: _ct,
                      min: 153,
                      max: 500,
                      onChanged: (v) => setState(() => _ct = v),
                    ),
                  ),
                  TextButton(
                      onPressed: () => _pick(['CT ${_ct.round()}']),
                      child: const Text('Add')),
                ]),
              ],
              if (s.hsb != null) ...[
                const SizedBox(height: 4),
                OutlinedButton(
                  onPressed: () => _pick(['HSBColor ${s.hsb!.join(',')}']),
                  child: const Text('Use its current colour'),
                ),
              ],
              const SizedBox(height: 12),
              Text('Any command', style: theme.textTheme.titleSmall),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _custom,
                    autocorrect: false,
                    style: const TextStyle(fontFamily: 'monospace'),
                    decoration: const InputDecoration(
                        hintText:
                            'e.g. Backlog Power1 ON; Delay 50; Power1 OFF'),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    final c = _custom.text.trim();
                    if (c.isNotEmpty) _pick([c]);
                  },
                  child: const Text('Add'),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
