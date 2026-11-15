import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../common.dart';
import 'input_model.dart';
import 'model.dart';
import 'platform_model.dart';

const String kGamepadChannel = 'is2l/gamepad';
const String kOptionGamepadProfiles = 'is2l-gamepad-profiles';
const String kOptionGamepadPeerProfiles = 'is2l-gamepad-peer-profiles';
const String kOptionGamepadPassthrough = 'is2l-gamepad-passthrough';
const String kGamepadDefaultProfile = 'Xbox layout';

const int kGamepadTriggerThreshold = 128;
const double kGamepadStickThreshold = 0.5;

const List<String> kGamepadButtons = [
  'a',
  'b',
  'x',
  'y',
  'l1',
  'r1',
  'select',
  'start',
  'mode',
  'l3',
  'r3',
  'dpad_up',
  'dpad_down',
  'dpad_left',
  'dpad_right',
];
const List<String> kGamepadTriggers = ['lt', 'rt'];
const List<String> kGamepadSticks = ['ls', 'rs'];
const List<String> kGamepadStickTargets = ['ls', 'rs', 'dpad', 'mouse', 'none'];
const List<String> kGamepadMouseButtons = ['left', 'right', 'middle'];

const Map<String, String> kGamepadInputLabels = {
  'a': 'A',
  'b': 'B',
  'x': 'X',
  'y': 'Y',
  'l1': 'L1',
  'r1': 'R1',
  'select': 'Select',
  'start': 'Start',
  'mode': 'Mode',
  'l3': 'L3',
  'r3': 'R3',
  'dpad_up': 'D-pad up',
  'dpad_down': 'D-pad down',
  'dpad_left': 'D-pad left',
  'dpad_right': 'D-pad right',
  'lt': 'L2',
  'rt': 'R2',
  'ls': 'Left stick',
  'rs': 'Right stick',
  'dpad': 'D-pad',
  'mouse': 'Mouse movement',
  'none': 'Nothing',
};

const Map<String, String> kGamepadMouseLabels = {
  'left': 'Left mouse button',
  'right': 'Right mouse button',
  'middle': 'Middle mouse button',
};

const Map<String, String> kGamepadFallbackKeys = {
  'a': 'z',
  'b': 'x',
  'x': 'a',
  'y': 's',
  'l1': 'q',
  'r1': 'w',
  'select': 'backspace',
  'start': 'enter',
  'mode': 'esc',
  'l3': '1',
  'r3': '2',
  'dpad_up': 'up',
  'dpad_down': 'down',
  'dpad_left': 'left',
  'dpad_right': 'right',
  'lt': 'e',
  'rt': 'r',
  'ls_up': 'up',
  'ls_down': 'down',
  'ls_left': 'left',
  'ls_right': 'right',
  'rs_up': 'i',
  'rs_down': 'k',
  'rs_left': 'j',
  'rs_right': 'l',
};

class GamepadKey {
  final String id;
  final String label;
  final int usbHid;
  final String legacy;
  const GamepadKey(this.id, this.label, this.usbHid, this.legacy);
}

Map<String, GamepadKey> _buildGamepadKeys() {
  final keys = <String, GamepadKey>{};
  void add(String id, String label, int usbHid, String legacy) {
    keys[id] = GamepadKey(id, label, usbHid, legacy);
  }

  add('up', 'Up arrow', 0x52, 'VK_UP');
  add('down', 'Down arrow', 0x51, 'VK_DOWN');
  add('left', 'Left arrow', 0x50, 'VK_LEFT');
  add('right', 'Right arrow', 0x4f, 'VK_RIGHT');
  add('enter', 'Enter', 0x28, 'VK_RETURN');
  add('esc', 'Esc', 0x29, 'VK_ESCAPE');
  add('space', 'Space', 0x2c, 'VK_SPACE');
  add('tab', 'Tab', 0x2b, 'VK_TAB');
  add('backspace', 'Backspace', 0x2a, 'VK_BACK');
  add('shift', 'Shift', 0xe1, 'VK_SHIFT');
  add('ctrl', 'Ctrl', 0xe0, 'VK_CONTROL');
  add('alt', 'Alt', 0xe2, 'VK_MENU');
  for (var i = 0; i < 26; i++) {
    final c = String.fromCharCode(0x61 + i);
    add(c, c.toUpperCase(), 0x04 + i, c);
  }
  for (var i = 1; i <= 9; i++) {
    add('$i', '$i', 0x1e + i - 1, '$i');
  }
  add('0', '0', 0x27, '0');
  for (var i = 1; i <= 12; i++) {
    add('f$i', 'F$i', 0x3a + i - 1, 'VK_F$i');
  }
  return keys;
}

final Map<String, GamepadKey> kGamepadKeys = _buildGamepadKeys();

enum GamepadOutputType { none, pad, key, mouse }

class GamepadOutput {
  final GamepadOutputType type;
  final String value;
  const GamepadOutput(this.type, this.value);
  const GamepadOutput.none()
      : type = GamepadOutputType.none,
        value = '';
  const GamepadOutput.pad(this.value) : type = GamepadOutputType.pad;
  const GamepadOutput.key(this.value) : type = GamepadOutputType.key;
  const GamepadOutput.mouse(this.value) : type = GamepadOutputType.mouse;

  Map<String, dynamic> toJson() => {'t': type.name, 'v': value};

  static GamepadOutput fromJson(dynamic json) {
    if (json is! Map) return const GamepadOutput.none();
    final v = '${json['v'] ?? ''}';
    switch (json['t']) {
      case 'pad':
        if (kGamepadButtons.contains(v) || kGamepadTriggers.contains(v)) {
          return GamepadOutput.pad(v);
        }
        break;
      case 'key':
        if (kGamepadKeys.containsKey(v)) return GamepadOutput.key(v);
        break;
      case 'mouse':
        if (kGamepadMouseButtons.contains(v)) return GamepadOutput.mouse(v);
        break;
    }
    return const GamepadOutput.none();
  }

  String label() {
    switch (type) {
      case GamepadOutputType.pad:
        return '${translate('Controller')}: ${translate(kGamepadInputLabels[value] ?? value)}';
      case GamepadOutputType.key:
        return '${translate('Keyboard')}: ${translate(kGamepadKeys[value]?.label ?? value)}';
      case GamepadOutputType.mouse:
        return translate(kGamepadMouseLabels[value] ?? value);
      case GamepadOutputType.none:
        return translate('Nothing');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is GamepadOutput && other.type == type && other.value == value;

  @override
  int get hashCode => Object.hash(type, value);
}

class GamepadStickConfig {
  String target;
  bool invertX;
  bool invertY;
  double deadzone;
  double mouseSpeed;

  GamepadStickConfig(
      {required this.target,
      this.invertX = false,
      this.invertY = false,
      this.deadzone = 0.1,
      this.mouseSpeed = 12});

  GamepadStickConfig copy() => GamepadStickConfig(
      target: target,
      invertX: invertX,
      invertY: invertY,
      deadzone: deadzone,
      mouseSpeed: mouseSpeed);

  Map<String, dynamic> toJson() => {
        'target': target,
        'invertX': invertX,
        'invertY': invertY,
        'deadzone': deadzone,
        'mouseSpeed': mouseSpeed,
      };

  static GamepadStickConfig fromJson(dynamic json, String fallbackTarget) {
    if (json is! Map) return GamepadStickConfig(target: fallbackTarget);
    final target = '${json['target'] ?? fallbackTarget}';
    final deadzone = json['deadzone'];
    final mouseSpeed = json['mouseSpeed'];
    return GamepadStickConfig(
      target: kGamepadStickTargets.contains(target) ? target : fallbackTarget,
      invertX: json['invertX'] == true,
      invertY: json['invertY'] == true,
      deadzone: deadzone is num
          ? deadzone.toDouble().clamp(0.0, 0.9).toDouble()
          : 0.1,
      mouseSpeed: mouseSpeed is num
          ? mouseSpeed.toDouble().clamp(1.0, 60.0).toDouble()
          : 12.0,
    );
  }

  String label() {
    final parts = <String>[translate(kGamepadInputLabels[target] ?? target)];
    if (invertX) parts.add(translate('Invert X'));
    if (invertY) parts.add(translate('Invert Y'));
    parts.add('${translate('Deadzone')} ${(deadzone * 100).round()}%');
    return parts.join(', ');
  }
}

class GamepadProfile {
  String name;
  final Map<String, GamepadOutput> buttons;
  final Map<String, GamepadStickConfig> sticks;

  GamepadProfile(this.name, this.buttons, this.sticks);

  factory GamepadProfile.identity(String name) {
    final buttons = <String, GamepadOutput>{};
    for (final b in [...kGamepadButtons, ...kGamepadTriggers]) {
      buttons[b] = GamepadOutput.pad(b);
    }
    final sticks = <String, GamepadStickConfig>{};
    for (final s in kGamepadSticks) {
      sticks[s] = GamepadStickConfig(target: s);
    }
    return GamepadProfile(name, buttons, sticks);
  }

  GamepadProfile copy(String newName) => GamepadProfile(
      newName,
      Map<String, GamepadOutput>.from(buttons),
      sticks.map((k, v) => MapEntry(k, v.copy())));

  Map<String, dynamic> toJson() => {
        'name': name,
        'buttons': buttons.map((k, v) => MapEntry(k, v.toJson())),
        'sticks': sticks.map((k, v) => MapEntry(k, v.toJson())),
      };

  static GamepadProfile? fromJson(dynamic json) {
    if (json is! Map) return null;
    final name = json['name'];
    if (name is! String || name.isEmpty) return null;
    final profile = GamepadProfile.identity(name);
    final buttons = json['buttons'];
    if (buttons is Map) {
      for (final b in profile.buttons.keys.toList()) {
        if (buttons.containsKey(b)) {
          profile.buttons[b] = GamepadOutput.fromJson(buttons[b]);
        }
      }
    }
    final sticks = json['sticks'];
    if (sticks is Map) {
      for (final s in kGamepadSticks) {
        if (sticks.containsKey(s)) {
          profile.sticks[s] = GamepadStickConfig.fromJson(sticks[s], s);
        }
      }
    }
    return profile;
  }
}

class GamepadRawState {
  final int index;
  final bool connected;
  final int buttons;
  final int lx;
  final int ly;
  final int rx;
  final int ry;
  final int lt;
  final int rt;
  final String name;
  final Map<dynamic, dynamic> raw;

  const GamepadRawState(
      {required this.index,
      required this.connected,
      this.buttons = 0,
      this.lx = 0,
      this.ly = 0,
      this.rx = 0,
      this.ry = 0,
      this.lt = 0,
      this.rt = 0,
      this.name = '',
      this.raw = const {}});

  static int _int(dynamic v) => v is num ? v.toInt() : 0;

  factory GamepadRawState.fromMap(Map<dynamic, dynamic> m) {
    final raw = m['raw'];
    return GamepadRawState(
      index: _int(m['index']),
      connected: m['connected'] == true,
      buttons: _int(m['buttons']),
      lx: _int(m['lx']),
      ly: _int(m['ly']),
      rx: _int(m['rx']),
      ry: _int(m['ry']),
      lt: _int(m['lt']),
      rt: _int(m['rt']),
      name: '${m['name'] ?? ''}',
      raw: raw is Map ? raw : const {},
    );
  }

  bool pressed(String input) {
    final i = kGamepadButtons.indexOf(input);
    if (i >= 0) return (buttons & (1 << i)) != 0;
    if (input == 'lt') return lt >= kGamepadTriggerThreshold;
    if (input == 'rt') return rt >= kGamepadTriggerThreshold;
    return false;
  }
}

class GamepadMapped {
  int buttons = 0;
  int lx = 0;
  int ly = 0;
  int rx = 0;
  int ry = 0;
  int lt = 0;
  int rt = 0;
  final Set<String> keys = {};
  final Set<String> mouse = {};
  double mouseDx = 0;
  double mouseDy = 0;

  bool samePad(GamepadMapped o) =>
      buttons == o.buttons &&
      lx == o.lx &&
      ly == o.ly &&
      rx == o.rx &&
      ry == o.ry &&
      lt == o.lt &&
      rt == o.rt;

  GamepadMapped padOnly() {
    final m = GamepadMapped();
    m.buttons = buttons;
    m.lx = lx;
    m.ly = ly;
    m.rx = rx;
    m.ry = ry;
    m.lt = lt;
    m.rt = rt;
    return m;
  }

  Set<String> fallbackKeys() {
    final out = <String>{};
    void add(String name) {
      final k = kGamepadFallbackKeys[name];
      if (k != null) out.add(k);
    }

    for (var i = 0; i < kGamepadButtons.length; i++) {
      if ((buttons & (1 << i)) != 0) add(kGamepadButtons[i]);
    }
    if (lt >= kGamepadTriggerThreshold) add('lt');
    if (rt >= kGamepadTriggerThreshold) add('rt');
    final t = (kGamepadStickThreshold * 32767).round();
    if (ly <= -t) add('ls_up');
    if (ly >= t) add('ls_down');
    if (lx <= -t) add('ls_left');
    if (lx >= t) add('ls_right');
    if (ry <= -t) add('rs_up');
    if (ry >= t) add('rs_down');
    if (rx <= -t) add('rs_left');
    if (rx >= t) add('rs_right');
    return out;
  }

  List<String> describe({required bool keyboardFallback}) {
    final out = <String>[];
    if (!keyboardFallback) {
      for (var i = 0; i < kGamepadButtons.length; i++) {
        if ((buttons & (1 << i)) != 0) {
          out.add(translate(kGamepadInputLabels[kGamepadButtons[i]]!));
        }
      }
      if (lt > 0) out.add('${translate('L2')} $lt');
      if (rt > 0) out.add('${translate('R2')} $rt');
      if (lx != 0 || ly != 0) out.add('${translate('Left stick')} $lx, $ly');
      if (rx != 0 || ry != 0) out.add('${translate('Right stick')} $rx, $ry');
    }
    final allKeys = {...keys, if (keyboardFallback) ...fallbackKeys()};
    for (final k in allKeys) {
      out.add(
          '${translate('Keyboard')}: ${translate(kGamepadKeys[k]?.label ?? k)}');
    }
    for (final b in mouse) {
      out.add(translate(kGamepadMouseLabels[b] ?? b));
    }
    if (mouseDx != 0 || mouseDy != 0) out.add(translate('Mouse movement'));
    return out;
  }
}

GamepadMapped mapGamepadState(GamepadProfile profile, GamepadRawState raw) {
  final m = GamepadMapped();

  void apply(GamepadOutput? out, int value) {
    if (out == null) return;
    switch (out.type) {
      case GamepadOutputType.pad:
        if (out.value == 'lt') {
          m.lt = max(m.lt, value);
        } else if (out.value == 'rt') {
          m.rt = max(m.rt, value);
        } else {
          final i = kGamepadButtons.indexOf(out.value);
          if (i >= 0) m.buttons |= 1 << i;
        }
        break;
      case GamepadOutputType.key:
        m.keys.add(out.value);
        break;
      case GamepadOutputType.mouse:
        m.mouse.add(out.value);
        break;
      case GamepadOutputType.none:
        break;
    }
  }

  for (var i = 0; i < kGamepadButtons.length; i++) {
    if ((raw.buttons & (1 << i)) != 0) {
      apply(profile.buttons[kGamepadButtons[i]], 255);
    }
  }

  void applyTrigger(String name, int value) {
    final out = profile.buttons[name];
    if (out == null || value <= 0) return;
    final analog = out.type == GamepadOutputType.pad &&
        kGamepadTriggers.contains(out.value);
    if (analog) {
      apply(out, value.clamp(0, 255).toInt());
    } else if (value >= kGamepadTriggerThreshold) {
      apply(out, 255);
    }
  }

  applyTrigger('lt', raw.lt);
  applyTrigger('rt', raw.rt);

  void applyStick(String name, int rawX, int rawY) {
    final cfg = profile.sticks[name];
    if (cfg == null || cfg.target == 'none') return;
    var x = (rawX / 32767).clamp(-1.0, 1.0).toDouble();
    var y = (rawY / 32767).clamp(-1.0, 1.0).toDouble();
    final mag = sqrt(x * x + y * y);
    if (mag <= cfg.deadzone || mag == 0) return;
    final scaled = min(1.0, (mag - cfg.deadzone) / (1 - cfg.deadzone)) / mag;
    x = (x * scaled).clamp(-1.0, 1.0).toDouble();
    y = (y * scaled).clamp(-1.0, 1.0).toDouble();
    if (cfg.invertX) x = -x;
    if (cfg.invertY) y = -y;
    int axis(int current, double v) =>
        (current + (v * 32767).round()).clamp(-32768, 32767).toInt();
    switch (cfg.target) {
      case 'ls':
        m.lx = axis(m.lx, x);
        m.ly = axis(m.ly, y);
        break;
      case 'rs':
        m.rx = axis(m.rx, x);
        m.ry = axis(m.ry, y);
        break;
      case 'dpad':
        if (y <= -kGamepadStickThreshold) {
          m.buttons |= 1 << kGamepadButtons.indexOf('dpad_up');
        }
        if (y >= kGamepadStickThreshold) {
          m.buttons |= 1 << kGamepadButtons.indexOf('dpad_down');
        }
        if (x <= -kGamepadStickThreshold) {
          m.buttons |= 1 << kGamepadButtons.indexOf('dpad_left');
        }
        if (x >= kGamepadStickThreshold) {
          m.buttons |= 1 << kGamepadButtons.indexOf('dpad_right');
        }
        break;
      case 'mouse':
        m.mouseDx += x * cfg.mouseSpeed;
        m.mouseDy += y * cfg.mouseSpeed;
        break;
    }
  }

  applyStick('ls', raw.lx, raw.ly);
  applyStick('rs', raw.rx, raw.ry);
  return m;
}

class GamepadModel extends ChangeNotifier with WidgetsBindingObserver {
  GamepadModel._();
  static final GamepadModel instance = GamepadModel._();

  final MethodChannel _channel = const MethodChannel(kGamepadChannel);
  final ValueNotifier<int> live = ValueNotifier<int>(0);

  bool _initialized = false;
  bool _loaded = false;
  WeakReference<FFI>? _ffi;
  String _peerId = '';
  bool _sessionActive = false;
  bool _foreground = true;
  int _pageOpen = 0;
  bool _captureOn = false;
  bool _enabled = true;
  bool? _peerSupports;
  DateTime? _peerSupportsCheckedAt;

  final List<GamepadProfile> _profiles = [];
  Map<String, String> _peerProfiles = {};
  String _activeName = kGamepadDefaultProfile;

  final Map<int, GamepadRawState> _rawStates = {};
  final Map<int, GamepadMapped> _mapped = {};
  final Map<int, GamepadMapped> _sentPads = {};
  final Set<String> _downKeys = {};
  final Set<String> _downMouse = {};
  double _mouseVx = 0;
  double _mouseVy = 0;
  Timer? _mouseTimer;
  Worker? _piWorker;

  void Function(int index, String input)? onInputPressed;

  bool get enabled => _enabled;
  bool get sessionActive => _sessionActive;
  bool get passthroughActive => _sessionActive && _enabled;
  bool get keyboardFallback => _sessionActive && _peerSupports == false;
  bool get peerSupportKnown => _peerSupports != null;
  String get profileName => _activeName;
  String get peerId => _peerId;
  List<GamepadProfile> get profiles {
    _ensureLoaded();
    return List.unmodifiable(_profiles);
  }
  Map<int, GamepadRawState> get rawStates => _rawStates;
  GamepadMapped? mappedFor(int index) => _mapped[index];

  GamepadProfile get active {
    _ensureLoaded();
    return _profiles.firstWhere((p) => p.name == _activeName,
        orElse: () => _profiles.first);
  }

  bool shouldSwallowKey(PhysicalKeyboardKey key) {
    if (!_captureOn) return false;
    return (key.usbHidUsage & 0xffffff00) == 0x0005ff00;
  }

  void _ensureInit() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(_onMethodCall);
    WidgetsBinding.instance.addObserver(this);
  }

  void _ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    _profiles.clear();
    try {
      final text = bind.mainGetLocalOption(key: kOptionGamepadProfiles);
      if (text.isNotEmpty) {
        final list = jsonDecode(text);
        if (list is List) {
          for (final item in list) {
            final p = GamepadProfile.fromJson(item);
            if (p != null && !_profiles.any((e) => e.name == p.name)) {
              _profiles.add(p);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('gamepad: failed to load profiles: $e');
    }
    if (!_profiles.any((p) => p.name == kGamepadDefaultProfile)) {
      _profiles.insert(0, GamepadProfile.identity(kGamepadDefaultProfile));
    }
    _peerProfiles = {};
    try {
      final text = bind.mainGetLocalOption(key: kOptionGamepadPeerProfiles);
      if (text.isNotEmpty) {
        final map = jsonDecode(text);
        if (map is Map) {
          map.forEach((k, v) {
            if (k is String && v is String) _peerProfiles[k] = v;
          });
        }
      }
    } catch (e) {
      debugPrint('gamepad: failed to load peer profiles: $e');
    }
    _enabled = bind.mainGetLocalOption(key: kOptionGamepadPassthrough) != 'N';
  }

  void _saveProfiles() {
    bind.mainSetLocalOption(
        key: kOptionGamepadProfiles,
        value: jsonEncode(_profiles.map((p) => p.toJson()).toList()));
  }

  void _savePeerProfiles() {
    bind.mainSetLocalOption(
        key: kOptionGamepadPeerProfiles, value: jsonEncode(_peerProfiles));
  }

  void startSession(FFI ffi, String peerId) {
    if (!isAndroid) return;
    _ensureInit();
    _ensureLoaded();
    _ffi = WeakReference(ffi);
    _peerId = peerId;
    _sessionActive = true;
    _peerSupports = null;
    _peerSupportsCheckedAt = null;
    final remembered = _peerProfiles[peerId];
    _activeName = remembered != null && _profiles.any((p) => p.name == remembered)
        ? remembered
        : kGamepadDefaultProfile;
    _piWorker?.dispose();
    _piWorker = ever(ffi.ffiModel.pi.isSet, (bool isSet) {
      if (isSet) _forwardAll();
    });
    _updateCapture();
    notifyListeners();
  }

  void endSession() {
    if (!_sessionActive) return;
    _piWorker?.dispose();
    _piWorker = null;
    _releaseAll(disconnect: true);
    _sessionActive = false;
    _ffi = null;
    _peerSupports = null;
    _updateCapture();
    notifyListeners();
  }

  void pageOpened() {
    _ensureInit();
    _ensureLoaded();
    _pageOpen++;
    _releaseAll(disconnect: false);
    _updateCapture();
  }

  void pageClosed() {
    if (_pageOpen > 0) _pageOpen--;
    onInputPressed = null;
    _updateCapture();
    _forwardAll();
  }

  void setEnabled(bool value) {
    _ensureLoaded();
    if (_enabled == value) return;
    if (!value) _releaseAll(disconnect: true);
    _enabled = value;
    bind.mainSetLocalOption(
        key: kOptionGamepadPassthrough, value: value ? 'Y' : 'N');
    _updateCapture();
    notifyListeners();
  }

  void toggleEnabled() => setEnabled(!_enabled);

  void refreshPeerSupport() {
    final ffi = _ffi?.target;
    if (ffi == null || !_sessionActive || ffi.closed) return;
    if (!ffi.ffiModel.pi.isSet.value) return;
    _peerSupportsCheckedAt = null;
    _checkPeerSupports(ffi);
  }

  Future<List<Map<dynamic, dynamic>>> devices() async {
    if (!isAndroid) return [];
    try {
      final list = await _channel.invokeMethod('devices');
      if (list is List) {
        return list.whereType<Map<dynamic, dynamic>>().toList();
      }
    } catch (e) {
      debugPrint('gamepad: failed to list devices: $e');
    }
    return [];
  }

  void selectProfile(String name) {
    _ensureLoaded();
    if (!_profiles.any((p) => p.name == name)) return;
    _activeName = name;
    if (_peerId.isNotEmpty) {
      _peerProfiles[_peerId] = name;
      _savePeerProfiles();
    }
    _remapAll();
  }

  bool profileNameAvailable(String name) =>
      name.trim().isNotEmpty && !_profiles.any((p) => p.name == name.trim());

  bool createProfile(String name) {
    _ensureLoaded();
    name = name.trim();
    if (!profileNameAvailable(name)) return false;
    _profiles.add(GamepadProfile.identity(name));
    _saveProfiles();
    selectProfile(name);
    return true;
  }

  bool duplicateProfile(String name) {
    _ensureLoaded();
    name = name.trim();
    if (!profileNameAvailable(name)) return false;
    _profiles.add(active.copy(name));
    _saveProfiles();
    selectProfile(name);
    return true;
  }

  bool renameProfile(String name) {
    _ensureLoaded();
    name = name.trim();
    final current = active;
    if (current.name == kGamepadDefaultProfile) return false;
    if (!profileNameAvailable(name)) return false;
    final old = current.name;
    current.name = name;
    _activeName = name;
    for (final k in _peerProfiles.keys.toList()) {
      if (_peerProfiles[k] == old) _peerProfiles[k] = name;
    }
    _saveProfiles();
    _savePeerProfiles();
    notifyListeners();
    return true;
  }

  bool deleteProfile() {
    _ensureLoaded();
    final current = active;
    if (current.name == kGamepadDefaultProfile) return false;
    _profiles.remove(current);
    _peerProfiles.removeWhere((k, v) => v == current.name);
    _activeName = kGamepadDefaultProfile;
    _saveProfiles();
    _savePeerProfiles();
    _remapAll();
    return true;
  }

  void resetProfile() {
    _ensureLoaded();
    final current = active;
    final identity = GamepadProfile.identity(current.name);
    current.buttons
      ..clear()
      ..addAll(identity.buttons);
    current.sticks
      ..clear()
      ..addAll(identity.sticks);
    _saveProfiles();
    _remapAll();
  }

  void setOutput(String input, GamepadOutput output) {
    _ensureLoaded();
    active.buttons[input] = output;
    _saveProfiles();
    _remapAll();
  }

  void setStick(String stick, GamepadStickConfig config) {
    _ensureLoaded();
    active.sticks[stick] = config;
    _saveProfiles();
    _remapAll();
  }

  void _remapAll() {
    final profile = active;
    for (final e in _rawStates.entries) {
      _mapped[e.key] = mapGamepadState(profile, e.value);
    }
    _forwardAll();
    live.value++;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = !(state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached);
    if (foreground == _foreground) return;
    _foreground = foreground;
    if (!foreground) _releaseAll(disconnect: false);
    _updateCapture();
  }

  void _updateCapture() {
    if (!isAndroid) return;
    final want = _foreground && ((_sessionActive && _enabled) || _pageOpen > 0);
    if (want == _captureOn) return;
    _captureOn = want;
    _channel.invokeMethod('setCapture', want).catchError((e) {
      debugPrint('gamepad: setCapture failed: $e');
    });
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (call.method == 'state') {
      final args = call.arguments;
      if (args is Map) _onState(GamepadRawState.fromMap(args));
    }
    return null;
  }

  void _onState(GamepadRawState state) {
    final previous = _rawStates[state.index];
    if (!state.connected) {
      _rawStates.remove(state.index);
      _mapped.remove(state.index);
      _forwardAll();
      _dropPad(state.index);
      live.value++;
      notifyListeners();
      return;
    }
    _rawStates[state.index] = state;
    _mapped[state.index] = mapGamepadState(active, state);
    final callback = onInputPressed;
    if (callback != null) {
      for (final input in [...kGamepadButtons, ...kGamepadTriggers]) {
        if (state.pressed(input) && !(previous?.pressed(input) ?? false)) {
          callback(state.index, input);
          break;
        }
      }
    }
    _forwardAll();
    live.value++;
    if (previous == null || previous.name != state.name) notifyListeners();
  }

  bool get _canForward {
    final ffi = _ffi?.target;
    if (ffi == null || !_sessionActive || !_enabled || _pageOpen > 0) {
      return false;
    }
    if (ffi.closed || !ffi.ffiModel.pi.isSet.value) return false;
    if (ffi.ffiModel.viewOnly || !ffi.ffiModel.keyboard) return false;
    return true;
  }

  bool _checkPeerSupports(FFI ffi) {
    if (_peerSupports == true) return true;
    final now = DateTime.now();
    final last = _peerSupportsCheckedAt;
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      return false;
    }
    _peerSupportsCheckedAt = now;
    final before = _peerSupports;
    try {
      _peerSupports = bind.sessionPeerSupportsGamepad(sessionId: ffi.sessionId);
    } catch (e) {
      debugPrint('gamepad: sessionPeerSupportsGamepad failed: $e');
      _peerSupports = false;
    }
    if (before != _peerSupports) {
      scheduleMicrotask(notifyListeners);
    }
    return _peerSupports == true;
  }

  void _forwardAll() {
    if (!_canForward) return;
    final ffi = _ffi!.target!;
    final supports = _checkPeerSupports(ffi);
    final keys = <String>{};
    final mouse = <String>{};
    var vx = 0.0;
    var vy = 0.0;
    for (final e in _mapped.entries) {
      final m = e.value;
      keys.addAll(m.keys);
      mouse.addAll(m.mouse);
      vx += m.mouseDx;
      vy += m.mouseDy;
      if (supports) {
        final sent = _sentPads[e.key];
        if (sent == null || !sent.samePad(m)) {
          _sendPad(ffi, e.key, true, m);
          _sentPads[e.key] = m.padOnly();
        }
      } else {
        keys.addAll(m.fallbackKeys());
      }
    }
    _syncKeys(ffi, keys);
    _syncMouse(ffi, mouse);
    _mouseVx = vx;
    _mouseVy = vy;
    if (vx != 0 || vy != 0) {
      _mouseTimer ??=
          Timer.periodic(const Duration(milliseconds: 16), (_) => _moveMouse());
    } else {
      _mouseTimer?.cancel();
      _mouseTimer = null;
    }
  }

  void _moveMouse() {
    final ffi = _ffi?.target;
    if (ffi == null || !_canForward || (_mouseVx == 0 && _mouseVy == 0)) {
      _mouseTimer?.cancel();
      _mouseTimer = null;
      return;
    }
    ffi.cursorModel.updatePan(Offset(_mouseVx, _mouseVy), Offset.zero, false);
  }

  void _sendPad(FFI ffi, int index, bool connected, GamepadMapped m) {
    bind.sessionSendGamepad(
        sessionId: ffi.sessionId,
        index: index,
        connected: connected,
        buttons: m.buttons,
        lx: m.lx,
        ly: m.ly,
        rx: m.rx,
        ry: m.ry,
        lt: m.lt,
        rt: m.rt);
  }

  void _dropPad(int index) {
    final ffi = _ffi?.target;
    if (_sentPads.remove(index) != null && ffi != null && !ffi.closed) {
      _sendPad(ffi, index, false, GamepadMapped());
    }
  }

  void _syncKeys(FFI ffi, Set<String> keys) {
    for (final k in _downKeys.difference(keys)) {
      _sendKey(ffi, k, false);
    }
    for (final k in keys.difference(_downKeys)) {
      _sendKey(ffi, k, true);
    }
    _downKeys
      ..clear()
      ..addAll(keys);
  }

  void _sendKey(FFI ffi, String id, bool down) {
    final key = kGamepadKeys[id];
    if (key == null) return;
    final InputModel input = ffi.inputModel;
    if (ffi.ffiModel.isPeerAndroid) {
      input.inputKey(key.legacy, down: down, press: false);
    } else {
      input.newKeyboardMode('', key.usbHid, down, false);
    }
  }

  void _syncMouse(FFI ffi, Set<String> buttons) {
    for (final b in _downMouse.difference(buttons)) {
      _sendMouse(ffi, b, false);
    }
    for (final b in buttons.difference(_downMouse)) {
      _sendMouse(ffi, b, true);
    }
    _downMouse
      ..clear()
      ..addAll(buttons);
  }

  void _sendMouse(FFI ffi, String button, bool down) {
    final MouseButtons b;
    switch (button) {
      case 'right':
        b = MouseButtons.right;
        break;
      case 'middle':
        b = MouseButtons.wheel;
        break;
      default:
        b = MouseButtons.left;
    }
    ffi.inputModel.sendMouse(down ? 'down' : 'up', b);
  }

  void _releaseAll({required bool disconnect}) {
    _mouseTimer?.cancel();
    _mouseTimer = null;
    _mouseVx = 0;
    _mouseVy = 0;
    final ffi = _ffi?.target;
    if (ffi == null || ffi.closed) {
      _sentPads.clear();
      _downKeys.clear();
      _downMouse.clear();
      return;
    }
    _syncKeys(ffi, {});
    _syncMouse(ffi, {});
    for (final index in _sentPads.keys.toList()) {
      _sendPad(ffi, index, !disconnect, GamepadMapped());
    }
    if (disconnect) {
      _sentPads.clear();
    } else {
      for (final index in _sentPads.keys.toList()) {
        _sentPads[index] = GamepadMapped();
      }
    }
  }
}
