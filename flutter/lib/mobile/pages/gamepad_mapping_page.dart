import 'package:flutter/material.dart';

import '../../common.dart';
import '../../models/gamepad_model.dart';

class GamepadMappingPage extends StatefulWidget {
  const GamepadMappingPage({Key? key}) : super(key: key);

  @override
  State<GamepadMappingPage> createState() => _GamepadMappingPageState();
}

class _GamepadMappingPageState extends State<GamepadMappingPage> {
  final GamepadModel model = GamepadModel.instance;
  String? _bindTarget;
  List<Map<dynamic, dynamic>> _devices = [];

  @override
  void initState() {
    super.initState();
    model.pageOpened();
    model.addListener(_onModelChanged);
    model.onInputPressed = _onInputPressed;
    model.refreshPeerSupport();
    _loadDevices();
  }

  @override
  void dispose() {
    model.removeListener(_onModelChanged);
    model.pageClosed();
    super.dispose();
  }

  void _onModelChanged() {
    if (!mounted) return;
    _loadDevices();
    setState(() {});
  }

  Future<void> _loadDevices() async {
    final devices = await model.devices();
    if (!mounted) return;
    setState(() => _devices = devices);
  }

  void _onInputPressed(int index, String input) {
    final target = _bindTarget;
    if (target == null || !mounted) return;
    model.setOutput(input, GamepadOutput.pad(target));
    setState(() => _bindTarget = null);
    showToast(
        '${translate(kGamepadInputLabels[input] ?? input)} -> ${translate(kGamepadInputLabels[target] ?? target)}');
  }

  Future<T?> _pick<T>(String title, List<MapEntry<String, T>> options) {
    return showDialog<T>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: options
            .map((e) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, e.value),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(e.key),
                  ),
                ))
            .toList(),
      ),
    );
  }

  Future<String?> _promptName(String title, String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: translate('Name')),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(translate('Cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: Text(translate('OK'))),
        ],
      ),
    );
  }

  Future<bool> _confirm(String title, String text) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(translate('Cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(translate('OK'))),
        ],
      ),
    );
    return ok == true;
  }

  List<MapEntry<String, String>> _padTargets() => [
        ...kGamepadButtons,
        ...kGamepadTriggers
      ]
          .map((b) => MapEntry(translate(kGamepadInputLabels[b] ?? b), b))
          .toList();

  Future<void> _startBind() async {
    final target = await _pick<String>(
        translate('Choose the controller button to assign'), _padTargets());
    if (target == null || !mounted) return;
    setState(() => _bindTarget = target);
  }

  Future<void> _editOutput(String input) async {
    final label = translate(kGamepadInputLabels[input] ?? input);
    final kind = await _pick<String>(label, [
      MapEntry(translate('Controller button'), 'pad'),
      MapEntry(translate('Keyboard key'), 'key'),
      MapEntry(translate('Mouse button'), 'mouse'),
      MapEntry(translate('Nothing'), 'none'),
    ]);
    if (kind == null || !mounted) return;
    GamepadOutput? output;
    switch (kind) {
      case 'pad':
        final v = await _pick<String>(label, _padTargets());
        if (v != null) output = GamepadOutput.pad(v);
        break;
      case 'key':
        final v = await _pick<String>(
            label,
            kGamepadKeys.values
                .map((k) => MapEntry(translate(k.label), k.id))
                .toList());
        if (v != null) output = GamepadOutput.key(v);
        break;
      case 'mouse':
        final v = await _pick<String>(
            label,
            kGamepadMouseButtons
                .map((b) => MapEntry(translate(kGamepadMouseLabels[b]!), b))
                .toList());
        if (v != null) output = GamepadOutput.mouse(v);
        break;
      default:
        output = const GamepadOutput.none();
    }
    if (output == null) return;
    model.setOutput(input, output);
  }

  Future<void> _editStick(String stick) async {
    final current = model.active.sticks[stick];
    if (current == null) return;
    final cfg = current.copy();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          scrollable: true,
          title: Text(translate(kGamepadInputLabels[stick] ?? stick)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(child: Text(translate('Output'))),
                DropdownButton<String>(
                  value: cfg.target,
                  items: kGamepadStickTargets
                      .map((t) => DropdownMenuItem(
                          value: t,
                          child:
                              Text(translate(kGamepadInputLabels[t] ?? t))))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setDialogState(() => cfg.target = v);
                  },
                ),
              ]),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(translate('Invert X')),
                value: cfg.invertX,
                onChanged: (v) => setDialogState(() => cfg.invertX = v),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(translate('Invert Y')),
                value: cfg.invertY,
                onChanged: (v) => setDialogState(() => cfg.invertY = v),
              ),
              Text(
                  '${translate('Deadzone')} ${(cfg.deadzone * 100).round()}%'),
              Slider(
                value: cfg.deadzone,
                min: 0,
                max: 0.9,
                divisions: 18,
                onChanged: (v) => setDialogState(() => cfg.deadzone = v),
              ),
              if (cfg.target == 'mouse') ...[
                Text('${translate('Mouse speed')} ${cfg.mouseSpeed.round()}'),
                Slider(
                  value: cfg.mouseSpeed,
                  min: 1,
                  max: 60,
                  divisions: 59,
                  onChanged: (v) => setDialogState(() => cfg.mouseSpeed = v),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(translate('Cancel'))),
            TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(translate('OK'))),
          ],
        ),
      ),
    );
    if (ok == true) model.setStick(stick, cfg);
  }

  Future<void> _onProfileAction(String action) async {
    switch (action) {
      case 'new':
        final name = await _promptName(translate('New profile'), '');
        if (name != null && !model.createProfile(name)) {
          showToast(translate('This profile name is empty or already used'));
        }
        break;
      case 'duplicate':
        final name = await _promptName(
            translate('Duplicate profile'), '${model.profileName} 2');
        if (name != null && !model.duplicateProfile(name)) {
          showToast(translate('This profile name is empty or already used'));
        }
        break;
      case 'rename':
        final name =
            await _promptName(translate('Rename profile'), model.profileName);
        if (name != null && !model.renameProfile(name)) {
          showToast(translate('This profile name is empty or already used'));
        }
        break;
      case 'delete':
        if (await _confirm(translate('Delete profile'), model.profileName)) {
          model.deleteProfile();
        }
        break;
      case 'reset':
        if (await _confirm(
            translate('Reset to default'), model.profileName)) {
          model.resetProfile();
        }
        break;
    }
  }

  String _modeText() {
    if (!model.sessionActive) {
      return translate('Not connected to a remote device');
    }
    if (!model.enabled) {
      return translate('Controller passthrough is off');
    }
    if (model.keyboardFallback) {
      return translate(
          'Keyboard mode: this host does not support virtual controllers, so controller buttons are sent as keyboard keys');
    }
    if (model.peerSupportKnown) {
      return translate(
          'Virtual controller mode: the host receives a real controller');
    }
    return translate('Waiting for the remote device');
  }

  String _outputText(String input) {
    final out = model.active.buttons[input] ?? const GamepadOutput.none();
    if (model.keyboardFallback && out.type == GamepadOutputType.pad) {
      final key = kGamepadKeys[kGamepadFallbackKeys[out.value]];
      if (key != null) {
        return '${out.label()} (${translate('Keyboard')}: ${translate(key.label)})';
      }
    }
    return out.label();
  }

  bool _pressed(String input) =>
      model.rawStates.values.any((s) => s.pressed(input));

  Widget _indicator(bool lit) => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: lit ? MyTheme.accent : Colors.transparent,
          border: Border.all(color: lit ? MyTheme.accent : Colors.grey),
        ),
      );

  Widget _tile(
      {required Widget leading,
      required String title,
      required Widget subtitle,
      required bool lit,
      required VoidCallback onTap}) {
    return Material(
      color: lit ? MyTheme.accent.withOpacity(0.18) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(children: [
              leading,
              const SizedBox(width: 10),
              SizedBox(
                  width: 96,
                  child: Text(title,
                      style: const TextStyle(fontWeight: FontWeight.w600))),
              Expanded(child: subtitle),
              const Icon(Icons.chevron_right, size: 18),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buttonTile(String input) {
    return ValueListenableBuilder<int>(
      valueListenable: model.live,
      builder: (context, _, __) {
        final lit = _pressed(input);
        var title = translate(kGamepadInputLabels[input] ?? input);
        if (kGamepadTriggers.contains(input)) {
          final values = model.rawStates.values
              .map((s) => input == 'lt' ? s.lt : s.rt)
              .where((v) => v > 0);
          if (values.isNotEmpty) title = '$title ${values.first}';
        }
        return _tile(
          leading: _indicator(lit),
          title: title,
          subtitle: Text(_outputText(input),
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          lit: lit,
          onTap: () => _editOutput(input),
        );
      },
    );
  }

  Widget _stickTile(String stick) {
    return ValueListenableBuilder<int>(
      valueListenable: model.live,
      builder: (context, _, __) {
        var x = 0;
        var y = 0;
        for (final s in model.rawStates.values) {
          final sx = stick == 'ls' ? s.lx : s.rx;
          final sy = stick == 'ls' ? s.ly : s.ry;
          if (sx != 0 || sy != 0) {
            x = sx;
            y = sy;
            break;
          }
        }
        final lit = x != 0 || y != 0;
        final cfg = model.active.sticks[stick];
        return _tile(
          leading: _stickDot(x, y),
          title: translate(kGamepadInputLabels[stick] ?? stick),
          subtitle: Text(cfg?.label() ?? '',
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          lit: lit,
          onTap: () => _editStick(stick),
        );
      },
    );
  }

  Widget _stickDot(int x, int y) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.grey),
      ),
      child: Align(
        alignment: Alignment(
            (x / 32767).clamp(-1.0, 1.0).toDouble(),
            (y / 32767).clamp(-1.0, 1.0).toDouble()),
        child: Container(
          width: 8,
          height: 8,
          decoration:
              BoxDecoration(shape: BoxShape.circle, color: MyTheme.accent),
        ),
      ),
    );
  }

  Widget _controllers() {
    final states = model.rawStates.values.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final idle = _devices.where((d) {
      final index = d['index'];
      return index is! int || index < 0;
    }).toList();
    if (states.isEmpty && idle.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(translate(
            'No controller detected. Press any button on your controller.')),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Wrap(spacing: 8, runSpacing: 4, children: [
        ...states.map((s) => Chip(
              avatar: CircleAvatar(
                  backgroundColor: MyTheme.accent,
                  child: Text('${s.index + 1}',
                      style:
                          const TextStyle(color: Colors.white, fontSize: 12))),
              label: Text(s.name.isEmpty ? translate('Controller') : s.name),
            )),
        ...idle.map((d) => Chip(
              label: Text(
                  '${d['name'] ?? ''} (${translate('press a button to activate')})'),
            )),
      ]),
    );
  }

  Widget _testOutput() {
    return ValueListenableBuilder<int>(
      valueListenable: model.live,
      builder: (context, _, __) {
        final lines = <String>[];
        final indexes = model.rawStates.keys.toList()..sort();
        for (final i in indexes) {
          final mapped = model.mappedFor(i);
          if (mapped == null) continue;
          final parts =
              mapped.describe(keyboardFallback: model.keyboardFallback);
          lines.add('${i + 1}: ${parts.isEmpty ? '-' : parts.join(', ')}');
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(translate('Test'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(translate(
                  'Press buttons to see what the remote device will receive. Nothing is sent while this page is open.')),
              const SizedBox(height: 4),
              Text(lines.isEmpty ? '-' : lines.join('\n')),
            ],
          ),
        );
      },
    );
  }

  Widget _profileRow() {
    final isDefault = model.profileName == kGamepadDefaultProfile;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        Text(translate('Profile')),
        const SizedBox(width: 12),
        Expanded(
          child: DropdownButton<String>(
            isExpanded: true,
            value: model.active.name,
            items: model.profiles
                .map((p) => DropdownMenuItem(
                    value: p.name,
                    child: Text(
                        p.name == kGamepadDefaultProfile
                            ? translate(p.name)
                            : p.name,
                        overflow: TextOverflow.ellipsis)))
                .toList(),
            onChanged: (v) {
              if (v != null) model.selectProfile(v);
            },
          ),
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: _onProfileAction,
          itemBuilder: (context) => [
            PopupMenuItem(value: 'new', child: Text(translate('New profile'))),
            PopupMenuItem(
                value: 'duplicate',
                child: Text(translate('Duplicate profile'))),
            PopupMenuItem(
                value: 'rename',
                enabled: !isDefault,
                child: Text(translate('Rename profile'))),
            PopupMenuItem(
                value: 'delete',
                enabled: !isDefault,
                child: Text(translate('Delete profile'))),
            PopupMenuItem(
                value: 'reset', child: Text(translate('Reset to default'))),
          ],
        ),
      ]),
    );
  }

  Widget _bindRow() {
    final target = _bindTarget;
    if (target == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: ElevatedButton.icon(
            onPressed: _startBind,
            icon: const Icon(Icons.sports_esports),
            label: Text(translate('Bind by pressing a button')),
          ),
        ),
      );
    }
    return Container(
      color: MyTheme.accent.withOpacity(0.18),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        Expanded(
          child: Text(
              '${translate('Press the button you want to use for')} ${translate(kGamepadInputLabels[target] ?? target)}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        TextButton(
            onPressed: () => setState(() => _bindTarget = null),
            child: Text(translate('Cancel'))),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inputs = [...kGamepadButtons, ...kGamepadTriggers];
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        title: Text(translate('Controller')),
      ),
      body: SafeArea(
        child: LayoutBuilder(builder: (context, constraints) {
          final columns = constraints.maxWidth >= 560 ? 2 : 1;
          final tileWidth = (constraints.maxWidth / columns).floorToDouble();
          return ListView(
            children: [
              SwitchListTile(
                dense: true,
                title: Text(translate('Controller passthrough')),
                subtitle: Text(_modeText()),
                value: model.enabled,
                onChanged: (v) => model.setEnabled(v),
              ),
              _profileRow(),
              _controllers(),
              _bindRow(),
              const Divider(height: 8),
              Wrap(children: [
                ...inputs.map((i) =>
                    SizedBox(width: tileWidth, child: _buttonTile(i))),
                ...kGamepadSticks.map(
                    (s) => SizedBox(width: tileWidth, child: _stickTile(s))),
              ]),
              const Divider(height: 8),
              _testOutput(),
            ],
          );
        }),
      ),
    );
  }
}
