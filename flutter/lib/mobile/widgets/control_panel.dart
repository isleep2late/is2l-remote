import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common.dart';
import '../../common/shared_state.dart';
import '../../common/widgets/dialog.dart';
import '../../consts.dart';
import '../../models/gamepad_model.dart';
import '../../models/input_model.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';

const kControlPanelChannel = 'is2l/panel';

const kPanelActionDisconnect = 'disconnect';
const kPanelActionToggleKeyboard = 'toggle_keyboard';
const kPanelActionSendEsc = 'send_esc';
const kPanelActionSendCtrlAltDel = 'send_ctrl_alt_del';
const kPanelActionSendAltTab = 'send_alt_tab';
const kPanelActionToggleFullscreen = 'toggle_fullscreen';
const kPanelActionFpsUp = 'fps_up';
const kPanelActionFpsDown = 'fps_down';
const kPanelActionQualityUp = 'quality_up';
const kPanelActionQualityDown = 'quality_down';
const kPanelActionCodecNext = 'codec_next';
const kPanelActionToggleGamepad = 'toggle_gamepad';
const kPanelActionControllerSetup = 'controller_setup';
const kPanelActionMouseMove = 'mouse_move';
const kPanelActionMouseClick = 'mouse_click';
const kPanelActionMouseScroll = 'mouse_scroll';

const _kPanelFpsSteps = <int>[30, 60, 90, 120];
const _kPanelQualitySteps = <int>[10, 25, 50, 75, 100];
const _kPanelUpdateInterval = Duration(milliseconds: 500);
const _kPanelDisconnectConfirm = Duration(seconds: 3);
const _kPanelTapTimeout = Duration(milliseconds: 350);
const _kPanelMouseSpeed = 2.0;

const _kPanelBackground = Color(0xFF121418);
const _kPanelSurface = Color(0xFF252931);
const _kPanelActive = Color(0xFF0071FF);
const _kPanelDanger = Color(0xFFC62828);
const _kPanelMuted = Color(0xFFA0A8B4);

class ControlPanelGamepadBinding {
  bool Function()? isActive;
  FutureOr<void> Function()? toggle;
  String Function()? padSource;
  FutureOr<void> Function()? openSetup;

  bool get attached => toggle != null;

  void attachDefaults() {
    if (!isAndroid) return;
    final model = GamepadModel.instance;
    isActive ??= () => model.passthroughActive;
    toggle ??= () {
      model.toggleEnabled();
    };
    padSource ??= () => model.externalFeedLive ? 'Hackmons Controller' : '';
    openSetup ??= openControllerSetup;
  }

  void clear() {
    isActive = null;
    toggle = null;
    padSource = null;
    openSetup = null;
  }
}

class ControlPanelController {
  ControlPanelController({
    required this.ffi,
    required this.id,
    required this.onToggleKeyboard,
    required this.isKeyboardVisible,
  });

  static final ControlPanelGamepadBinding gamepad =
      ControlPanelGamepadBinding();
  static const MethodChannel _channel = MethodChannel(kControlPanelChannel);

  final FFI ffi;
  final String id;
  final VoidCallback onToggleKeyboard;
  final bool Function() isKeyboardVisible;

  final ValueNotifier<Map<String, dynamic>> state =
      ValueNotifier<Map<String, dynamic>>(<String, dynamic>{});

  Timer? _timer;
  bool _running = false;
  bool _ticking = false;
  bool _settingsLoaded = false;
  bool _shown = false;
  String _lastSent = '';

  String _imageQuality = '';
  int _customQuality = kDefaultQuality.toInt();
  int _customFps = kDefaultFps.toInt();
  String _codecPref = '';
  String _viewStyle = '';
  List<String> _codecs = <String>[];
  double _scrollIntegral = 0;

  SessionID get _sessionId => ffi.sessionId;

  bool get _canControl => ffi.ffiModel.keyboard && !ffi.ffiModel.viewOnly;

  int get _effectiveFps =>
      _imageQuality == kRemoteImageQualityCustom ? _customFps : 30;

  String get _qualityLabel {
    switch (_imageQuality) {
      case kRemoteImageQualityCustom:
        return '$_customQuality%';
      case kRemoteImageQualityBest:
        return 'Best';
      case kRemoteImageQualityBalanced:
        return 'Balanced';
      case kRemoteImageQualityLow:
        return 'Low';
      default:
        return _imageQuality;
    }
  }

  void start() {
    if (_running) return;
    _running = true;
    ControlPanelController.gamepad.attachDefaults();
    if (isAndroid) {
      _channel.setMethodCallHandler(_onMethodCall);
    }
    _timer = Timer.periodic(_kPanelUpdateInterval, (_) => _tick());
  }

  void stop() {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    _timer = null;
    _shown = false;
    _lastSent = '';
    if (isAndroid) {
      _channel.setMethodCallHandler(null);
      _invoke('hide');
    }
  }

  Future<void> _invoke(String method, [dynamic arguments]) async {
    try {
      await _channel.invokeMethod(method, arguments);
    } catch (e) {
      debugPrint('control panel $method failed: $e');
    }
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (call.method != 'action') return null;
    final arguments = call.arguments;
    if (arguments is String) {
      await perform(arguments);
    } else if (arguments is Map) {
      final actionId = arguments['id'];
      if (actionId is String) {
        await perform(actionId, arguments);
      }
    }
    return null;
  }

  Future<void> _tick() async {
    if (!_running || _ticking) return;
    if (!ffi.ffiModel.pi.isSet.value) return;
    _ticking = true;
    try {
      if (!_settingsLoaded) {
        _settingsLoaded = true;
        await _loadSettings();
        if (!_running) return;
      }
      final next = _buildState();
      state.value = next;
      if (!isAndroid) return;
      final encoded = jsonEncode(next);
      if (!_shown) {
        _shown = true;
        _lastSent = encoded;
        await _invoke('show', next);
      } else if (encoded != _lastSent) {
        _lastSent = encoded;
        await _invoke('update', next);
      }
    } finally {
      _ticking = false;
    }
  }

  Future<void> _loadSettings() async {
    try {
      _imageQuality =
          await bind.sessionGetImageQuality(sessionId: _sessionId) ?? '';
      final quality =
          await bind.sessionGetCustomImageQuality(sessionId: _sessionId);
      var customQuality = quality != null && quality.isNotEmpty
          ? quality[0]
          : kDefaultQuality.toInt();
      if (customQuality < kMinQuality || customQuality > kMaxMoreQuality) {
        customQuality = kDefaultQuality.toInt();
      }
      _customQuality = customQuality;
      final fpsOption =
          await bind.sessionGetOption(sessionId: _sessionId, arg: 'custom-fps');
      var customFps = int.tryParse(fpsOption ?? '') ?? kDefaultFps.toInt();
      if (customFps < kMinFps || customFps > kMaxFps) {
        customFps = kDefaultFps.toInt();
      }
      _customFps = customFps;
      _codecPref = await bind.sessionGetOption(
              sessionId: _sessionId, arg: kOptionCodecPreference) ??
          '';
      _viewStyle = await bind.sessionGetViewStyle(sessionId: _sessionId) ?? '';
      _codecs = await _loadCodecs();
    } catch (e) {
      debugPrint('control panel settings failed: $e');
    }
  }

  Future<List<String>> _loadCodecs() async {
    final alternativeCodecs =
        await bind.sessionAlternativeCodecs(sessionId: _sessionId);
    try {
      final Map codecsJson = jsonDecode(alternativeCodecs);
      final vp8 = codecsJson['vp8'] == true;
      final av1 = codecsJson['av1'] == true;
      final h264 = codecsJson['h264'] == true;
      final h265 = codecsJson['h265'] == true;
      if (!(vp8 || av1 || h264 || h265)) return <String>[];
      return <String>[
        'auto',
        if (vp8) 'vp8',
        'vp9',
        if (av1) 'av1',
        if (h264) 'h264',
        if (h265) 'h265',
      ];
    } catch (e) {
      debugPrint('control panel codecs failed: $e');
      return <String>[];
    }
  }

  Map<String, dynamic> _buildState() {
    final pi = ffi.ffiModel.pi;
    final data = ffi.qualityMonitorModel.data;
    final binding = ControlPanelController.gamepad;
    var gamepadSupported = false;
    try {
      gamepadSupported =
          bind.sessionPeerSupportsGamepad(sessionId: _sessionId);
    } catch (_) {}
    return <String, dynamic>{
      'peer': pi.hostname.isNotEmpty ? pi.hostname : id,
      'fps': data.fps ?? '',
      'codec': data.codecFormat ?? '',
      'delay': data.delay ?? '',
      'quality': _qualityLabel,
      'gamepad': binding.isActive?.call() ?? false,
      'pad_source': binding.padSource?.call() ?? '',
      'gamepad_available': binding.attached,
      'setup_available': binding.openSetup != null,
      'gamepad_supported': gamepadSupported,
      'keyboard': isKeyboardVisible(),
      'target_fps': _effectiveFps,
      'view_style': _viewStyle,
      'codec_pref': _codecPref,
      'codec_available': _codecs.length > 1,
    };
  }

  Future<void> perform(String action, [Map? arguments]) async {
    if (!_running) return;
    switch (action) {
      case kPanelActionMouseMove:
        await _mouseMove(
            _number(arguments, 'dx'), _number(arguments, 'dy'));
        return;
      case kPanelActionMouseScroll:
        await _mouseScroll(_number(arguments, 'dy'));
        return;
      case kPanelActionMouseClick:
        if (!_canControl) return;
        await ffi.inputModel.tap(arguments?['button'] == 'right'
            ? MouseButtons.right
            : MouseButtons.left);
        return;
      case kPanelActionSendEsc:
        if (!_canControl) return;
        ffi.inputModel.inputKey('VK_ESCAPE');
        return;
      case kPanelActionSendAltTab:
        if (!_canControl) return;
        final old = ffi.inputModel.alt;
        ffi.inputModel.alt = true;
        ffi.inputModel.inputKey('VK_TAB');
        ffi.inputModel.alt = old;
        return;
      case kPanelActionSendCtrlAltDel:
        if (!_canControl) return;
        await bind.sessionCtrlAltDel(sessionId: _sessionId);
        return;
      case kPanelActionDisconnect:
        if (allowAskForNoteAtEndOfConnection(ffi, true)) {
          clientClose(_sessionId, ffi);
        } else {
          closeConnection();
        }
        return;
      case kPanelActionToggleKeyboard:
        onToggleKeyboard();
        break;
      case kPanelActionToggleFullscreen:
        await _toggleViewStyle();
        break;
      case kPanelActionFpsUp:
        await _stepFps(1);
        break;
      case kPanelActionFpsDown:
        await _stepFps(-1);
        break;
      case kPanelActionQualityUp:
        await _stepQuality(1);
        break;
      case kPanelActionQualityDown:
        await _stepQuality(-1);
        break;
      case kPanelActionCodecNext:
        await _cycleCodec();
        break;
      case kPanelActionToggleGamepad:
        final toggle = ControlPanelController.gamepad.toggle;
        if (toggle == null) {
          _gamepadUnavailable();
        } else {
          await toggle();
        }
        break;
      case kPanelActionControllerSetup:
        final openSetup = ControlPanelController.gamepad.openSetup;
        if (openSetup == null) {
          _gamepadUnavailable();
        } else {
          await openSetup();
        }
        break;
      default:
        debugPrint('control panel: unknown action $action');
        return;
    }
    if (!_running) return;
    await _loadSettings();
    if (!_running) return;
    state.value = _buildState();
  }

  double _number(Map? arguments, String key) {
    final value = arguments?[key];
    return value is num ? value.toDouble() : 0.0;
  }

  void _gamepadUnavailable() {
    showToast(translate('Controller support is not available'));
  }

  Future<void> _mouseMove(double dx, double dy) async {
    if (!_canControl) return;
    if (dx == 0 && dy == 0) return;
    final inputModel = ffi.inputModel;
    if (inputModel.relativeMouseMode.value) {
      await inputModel.sendMobileRelativeMouseMove(
          dx * _kPanelMouseSpeed, dy * _kPanelMouseSpeed);
    } else {
      await ffi.cursorModel.updatePan(
          Offset(dx * _kPanelMouseSpeed, dy * _kPanelMouseSpeed),
          Offset.zero,
          false);
    }
  }

  Future<void> _mouseScroll(double dy) async {
    if (!_canControl) return;
    if (ffi.ffiModel.isPeerAndroid) return;
    _scrollIntegral += dy / 4;
    if (_scrollIntegral > 1) {
      _scrollIntegral = 0;
      await ffi.inputModel.scroll(1);
    } else if (_scrollIntegral < -1) {
      _scrollIntegral = 0;
      await ffi.inputModel.scroll(-1);
    }
  }

  Future<void> _toggleViewStyle() async {
    final next = _viewStyle == kRemoteViewStyleOriginal
        ? kRemoteViewStyleAdaptive
        : kRemoteViewStyleOriginal;
    await bind.sessionSetViewStyle(sessionId: _sessionId, value: next);
    await ffi.canvasModel.updateViewStyle();
  }

  Future<bool> _isFpsAllowed() async {
    bool? direct;
    try {
      direct =
          ConnectionTypeState.find(id).direct.value == ConnectionType.strDirect;
    } catch (_) {}
    final hideFps = (await bind.mainIsUsingPublicServer() && direct != true) ||
        versionCmp(ffi.ffiModel.pi.version, '1.2.0') < 0;
    return !hideFps;
  }

  Future<void> _useCustomQuality(int quality, {required bool fpsAllowed}) async {
    final wasCustom = _imageQuality == kRemoteImageQualityCustom;
    if (!wasCustom) {
      await bind.sessionSetImageQuality(
          sessionId: _sessionId, value: kRemoteImageQualityCustom);
      _imageQuality = kRemoteImageQualityCustom;
    }
    if (!wasCustom || quality != _customQuality) {
      await bind.sessionSetCustomImageQuality(
          sessionId: _sessionId, value: quality);
      _customQuality = quality;
    }
    if (!wasCustom && fpsAllowed) {
      await bind.sessionSetCustomFps(sessionId: _sessionId, fps: _customFps);
    }
  }

  Future<void> _stepFps(int direction) async {
    if (!await _isFpsAllowed()) {
      showToast(translate('FPS cannot be changed on this connection'));
      return;
    }
    final current = _effectiveFps;
    int? next;
    if (direction > 0) {
      for (final step in _kPanelFpsSteps) {
        if (step > current) {
          next = step;
          break;
        }
      }
    } else {
      for (final step in _kPanelFpsSteps.reversed) {
        if (step < current) {
          next = step;
          break;
        }
      }
    }
    if (next == null) return;
    await _useCustomQuality(_customQuality, fpsAllowed: false);
    await bind.sessionSetCustomFps(sessionId: _sessionId, fps: next);
    _customFps = next;
  }

  Future<void> _stepQuality(int direction) async {
    final current = _imageQuality == kRemoteImageQualityCustom
        ? _customQuality
        : kDefaultQuality.toInt();
    int? next;
    if (direction > 0) {
      for (final step in _kPanelQualitySteps) {
        if (step > current) {
          next = step;
          break;
        }
      }
    } else {
      for (final step in _kPanelQualitySteps.reversed) {
        if (step < current) {
          next = step;
          break;
        }
      }
    }
    if (next == null) return;
    await _useCustomQuality(next, fpsAllowed: await _isFpsAllowed());
  }

  Future<void> _cycleCodec() async {
    if (_codecs.length < 2) {
      showToast(translate('No other codec is available'));
      return;
    }
    final index = _codecs.indexOf(_codecPref);
    final next = _codecs[(index + 1) % _codecs.length];
    await bind.sessionPeerOption(
        sessionId: _sessionId, name: kOptionCodecPreference, value: next);
    await bind.sessionChangePreferCodec(sessionId: _sessionId);
  }

  Future<void> openSheet(BuildContext context) async {
    if (_running && ffi.ffiModel.pi.isSet.value) {
      await _loadSettings();
      if (!_running) return;
      state.value = _buildState();
    }
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      enableDrag: false,
      backgroundColor: _kPanelBackground,
      builder: (_) => ControlPanelSheet(controller: this),
    );
  }
}

class ControlPanelSheet extends StatefulWidget {
  const ControlPanelSheet({Key? key, required this.controller})
      : super(key: key);

  final ControlPanelController controller;

  @override
  State<ControlPanelSheet> createState() => _ControlPanelSheetState();
}

class _ControlPanelSheetState extends State<ControlPanelSheet> {
  bool _disconnectArmed = false;
  Timer? _disarmTimer;

  ControlPanelController get controller => widget.controller;

  @override
  void dispose() {
    _disarmTimer?.cancel();
    super.dispose();
  }

  void _send(String action, [Map<String, dynamic>? arguments]) {
    controller.perform(action, arguments);
  }

  void _closeThenSend(String action) {
    Navigator.of(context).pop();
    controller.perform(action);
  }

  void _onDisconnect() {
    if (_disconnectArmed) {
      _disarmTimer?.cancel();
      _closeThenSend(kPanelActionDisconnect);
      return;
    }
    setState(() => _disconnectArmed = true);
    _disarmTimer?.cancel();
    _disarmTimer = Timer(_kPanelDisconnectConfirm, () {
      if (mounted) setState(() => _disconnectArmed = false);
    });
  }

  Widget _button(String label, VoidCallback? onPressed,
      {Color color = _kPanelSurface, int flex = 1}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: SizedBox(
          height: 52,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: color,
              foregroundColor: Colors.white,
              disabledBackgroundColor: _kPanelSurface.withOpacity(0.4),
              disabledForegroundColor: Colors.white38,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: onPressed,
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14)),
          ),
        ),
      ),
    );
  }

  Widget _label(String text, {int flex = 1}) {
    return Expanded(
      flex: flex,
      child: SizedBox(
        height: 52,
        child: Center(
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14)),
        ),
      ),
    );
  }

  Widget _header(Map<String, dynamic> state) {
    final stats = <String>[
      if ('${state['fps'] ?? ''}'.isNotEmpty) '${state['fps']} fps',
      if ('${state['codec'] ?? ''}'.isNotEmpty) '${state['codec']}',
      if ('${state['delay'] ?? ''}'.isNotEmpty) '${state['delay']} ms',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          Expanded(
            child: Text('${state['peer'] ?? ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 18)),
          ),
          Text(stats.join('  '),
              maxLines: 1,
              style: const TextStyle(color: _kPanelMuted, fontSize: 14)),
          IconButton(
            color: Colors.white,
            icon: const Icon(Icons.expand_more),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _controls(Map<String, dynamic> state) {
    final gamepadAvailable = state['gamepad_available'] == true;
    final gamepadOn = state['gamepad'] == true;
    final padSource = '${state['pad_source'] ?? ''}';
    final codecPref = '${state['codec_pref'] ?? ''}';
    final targetFps = '${state['target_fps'] ?? ''}';
    final quality = '${state['quality'] ?? ''}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _header(state),
        Row(children: [
          _button(
              _disconnectArmed
                  ? translate('Tap again')
                  : translate('Disconnect'),
              _onDisconnect,
              color: _kPanelDanger),
          _button(translate('Keyboard'),
              () => _closeThenSend(kPanelActionToggleKeyboard),
              color: state['keyboard'] == true ? _kPanelActive : _kPanelSurface),
          _button('Esc', () => _send(kPanelActionSendEsc)),
        ]),
        Row(children: [
          _button('Ctrl+Alt+Del', () => _send(kPanelActionSendCtrlAltDel)),
          _button('Alt+Tab', () => _send(kPanelActionSendAltTab)),
          _button(state['view_style'] == kRemoteViewStyleOriginal ? 'Fit' : '1:1',
              () => _send(kPanelActionToggleFullscreen)),
        ]),
        Row(children: [
          _button('FPS -', () => _send(kPanelActionFpsDown)),
          _label(targetFps.isEmpty ? 'FPS' : '$targetFps fps'),
          _button('FPS +', () => _send(kPanelActionFpsUp)),
        ]),
        Row(children: [
          _button('Quality -', () => _send(kPanelActionQualityDown)),
          _label(quality.isEmpty ? 'Quality' : quality),
          _button('Quality +', () => _send(kPanelActionQualityUp)),
        ]),
        Row(children: [
          _button(codecPref.isEmpty ? 'Codec' : 'Codec: $codecPref',
              () => _send(kPanelActionCodecNext)),
        ]),
        Row(children: [
          _button(gamepadOn ? 'Controller: on' : 'Controller: off',
              gamepadAvailable ? () => _send(kPanelActionToggleGamepad) : null,
              color: gamepadOn ? _kPanelActive : _kPanelSurface),
          _label(padSource.isEmpty
              ? 'Input: this device'
              : 'Input: $padSource'),
        ]),
        Row(children: [
          _button(
              kControllerSetupLabel,
              state['setup_available'] == true
                  ? () => _closeThenSend(kPanelActionControllerSetup)
                  : null),
        ]),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final wide = size.width > size.height;
    return SafeArea(
      child: SizedBox(
        height: size.height * (wide ? 0.92 : 0.8),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: ValueListenableBuilder<Map<String, dynamic>>(
            valueListenable: controller.state,
            builder: (context, state, _) {
              final controls = SingleChildScrollView(child: _controls(state));
              final pad = Padding(
                padding: const EdgeInsets.all(3),
                child: _PanelTouchPad(onAction: _send),
              );
              return wide
                  ? Row(children: [
                      Expanded(child: controls),
                      Expanded(child: pad),
                    ])
                  : Column(children: [
                      Expanded(flex: 3, child: controls),
                      Expanded(flex: 2, child: pad),
                    ]);
            },
          ),
        ),
      ),
    );
  }
}

class _PanelTouchPad extends StatefulWidget {
  const _PanelTouchPad({Key? key, required this.onAction}) : super(key: key);

  final void Function(String action, [Map<String, dynamic>? arguments])
      onAction;

  @override
  State<_PanelTouchPad> createState() => _PanelTouchPadState();
}

class _PanelTouchPadState extends State<_PanelTouchPad> {
  final Map<int, Offset> _pointers = <int, Offset>{};
  Offset _last = Offset.zero;
  Offset _travel = Offset.zero;
  Duration _downTime = Duration.zero;
  bool _moved = false;
  int _maxPointers = 0;

  Offset _centroid() {
    if (_pointers.isEmpty) return _last;
    var sum = Offset.zero;
    for (final position in _pointers.values) {
      sum += position;
    }
    return sum / _pointers.length.toDouble();
  }

  void _onDown(PointerDownEvent e) {
    if (_pointers.isEmpty) {
      _moved = false;
      _travel = Offset.zero;
      _maxPointers = 0;
      _downTime = e.timeStamp;
    }
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length > _maxPointers) _maxPointers = _pointers.length;
    _last = _centroid();
  }

  void _onMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    final current = _centroid();
    final delta = current - _last;
    _last = current;
    if (!_moved) {
      _travel += delta;
      if (_travel.distance > kTouchSlop) _moved = true;
    } else if (_pointers.length >= 2) {
      widget.onAction(kPanelActionMouseScroll,
          <String, dynamic>{'dx': delta.dx, 'dy': delta.dy});
    } else if (_maxPointers == 1) {
      widget.onAction(kPanelActionMouseMove,
          <String, dynamic>{'dx': delta.dx, 'dy': delta.dy});
    }
  }

  void _onUp(PointerUpEvent e) {
    if (_pointers.remove(e.pointer) == null) return;
    if (_pointers.isNotEmpty) {
      _last = _centroid();
      return;
    }
    if (!_moved && e.timeStamp - _downTime < _kPanelTapTimeout) {
      widget.onAction(kPanelActionMouseClick,
          <String, dynamic>{'button': _maxPointers >= 2 ? 'right' : 'left'});
    }
  }

  void _onCancel(PointerCancelEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.isNotEmpty) {
      _last = _centroid();
    } else {
      _moved = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      child: Container(
        decoration: BoxDecoration(
          color: _kPanelSurface,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(translate('Touch pad'),
            style: const TextStyle(color: Color(0xFF707884), fontSize: 16)),
      ),
    );
  }
}
