import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/services/error_messages.dart';
import 'package:rcj_scoreboard/services/match_state_store.dart';
import 'package:rcj_scoreboard/utils/ble_address.dart';

enum ModuleState { play, stop, damage, halfTime, fullTime }

/// Message ids of the robot-module BLE protocol (first byte of every frame).
enum BleMsgId {
  ping,
  fwVersion,
  setName,
  setScore,
  play,
  stop,
  damage,
  halfBreak,
  gameOver,
  disconnect,
  askForPenalty,
}

/// Nordic UART Service, shared by robot modules and the scoreboard bridge.
const String kNusServiceUuid = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
const String kNusTxCharUuid = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E';
const String kNusRxCharUuid = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';

/// One robot slot: its match state (play / stop / damage ...) and its BLE link.
///
/// Reconnection is owned by the OS: `connect(autoConnect: true)` is called once
/// and retries indefinitely on the same GATT client until `disconnect()`. The
/// connection-state handler only reflects status (CLAUDE.md invariant #5).
class Module with ChangeNotifier {
  Module(this._game, this._teamId, this.defaultName, this.moduleId);

  final Game _game;
  final String _teamId;
  final String defaultName;
  final int moduleId;

  static final Guid _serviceGuid = Guid.fromString(kNusServiceUuid);
  static final Guid _txGuid = Guid.fromString(kNusTxCharUuid);
  static final Guid _rxGuid = Guid.fromString(kNusRxCharUuid);

  // ---- match state ----
  String? _label;
  ModuleState _state = ModuleState.stop;
  ModuleState _lastState = ModuleState.stop;
  int _penaltyTime = 0;
  bool _isEnabled = true;
  bool _isPlaying = false;
  // Whether the module resumes play when its penalty clears: a penalty given to
  // a playing robot resumes play, one recorded on a stopped slot returns to stop.
  bool _resumeAfterPenalty = false;
  // One-shot armed by a cold-resume restore: the first reconnect after it sends
  // at most STOP, so a restored damage/play robot can't auto-run while the match
  // clock is frozen. Cleared by any START path.
  bool _suppressNextRestoreNotify = false;

  // ---- BLE link ----
  /// Connection id: the MAC on Android, a per-phone CoreBluetooth UUID on iOS.
  String macAddress = '';
  String _hardwareMac = '';
  String bleStatus = 'Disconnected';
  bool _isConnected = false;
  bool _connectIntent = false;
  bool _isSearching = false;
  BluetoothDevice? bleDevice;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _rxSub;
  BluetoothCharacteristic? _tx;
  BluetoothCharacteristic? _rx;

  // ---- getters ----
  String get name => hasCustomLabel ? _label! : defaultName;
  bool get hasCustomLabel => _label?.isNotEmpty ?? false;
  String get currentPenalty => _penaltyTime > 0 ? '$_penaltyTime' : '';
  int get penaltyTime => _penaltyTime;
  ModuleState get state => _state;
  bool get isEnabled => _isEnabled;
  bool get isPlaying => _isPlaying;
  bool get isConnected => _isConnected;
  bool get isConnecting => _connectIntent && !_isConnected;
  bool get isSearching => _isSearching;

  /// The permanent hardware MAC (uppercase, '' if unknown): the identity the
  /// scoreboard knows. Equals [macAddress] on Android; on iOS it is recovered
  /// from the QR code, the advertised name `RCJs-m_<MAC>`, or the resolver.
  String get hardwareMac => _hardwareMac;
  set hardwareMac(String value) => _hardwareMac = value.trim().toUpperCase();

  @visibleForTesting
  ModuleState get lastState => _lastState;
  @visibleForTesting
  bool get suppressNextRestoreNotify => _suppressNextRestoreNotify;
  @visibleForTesting
  set debugIsConnected(bool value) => _isConnected = value;

  // ---- enable / labels ----

  void init() {
    _enter(ModuleState.stop);
    _penaltyTime = 0;
    _lastState = ModuleState.stop;
    _resumeAfterPenalty = false;
  }

  void enable() => _isEnabled = true;

  void disable() {
    _isEnabled = false;
    _setPlaying(false);
    bleDisconnect();
  }

  void setLabel(String label) {
    _label = label.trim();
    notifyListeners();
    unawaited(bleSendName());
    _game.persistence.markDirtyAndFlush();
  }

  // ---- match-state transitions ----

  void _setPlaying(bool playing) {
    if (playing == _isPlaying) return;
    _isPlaying = playing;
    _game.changeNumberOfPlaying(playing ? 1 : -1);
  }

  /// Move to [next], push it to the robot and persist. [flush] schedules a
  /// write now (single-module actions off the START/STOP fan-out); otherwise
  /// only the dirty flag is set.
  void _enter(ModuleState next, {bool playing = false, bool flush = false}) {
    _setPlaying(playing);
    _state = next;
    bleNotify();
    notifyListeners();
    flush
        ? _game.persistence.markDirtyAndFlush()
        : _game.persistence.markDirty();
  }

  void play() {
    _suppressNextRestoreNotify = false;
    if (_state == ModuleState.damage && !_resumeAfterPenalty) {
      _penaltyTime = 0;
      _enter(ModuleState.stop);
      return;
    }
    _resumeAfterPenalty = false;
    _lastState = _state;
    _penaltyTime = 0;
    _enter(ModuleState.play, playing: true, flush: true);
  }

  void stop() {
    switch (_lastState) {
      case ModuleState.stop:
        _enter(ModuleState.stop);
      case ModuleState.halfTime:
        halfTime();
      case ModuleState.fullTime:
        gameOver();
      default:
        debugPrint('Wrong last ModuleState');
    }
  }

  void penalty(int seconds) {
    _resumeAfterPenalty = _isPlaying || _state == ModuleState.play;
    _penaltyTime = seconds;
    _enter(ModuleState.damage, flush: true);
  }

  void halfTime() {
    _penaltyTime = 0;
    _lastState = ModuleState.halfTime;
    _enter(ModuleState.halfTime);
  }

  void gameOver() {
    _lastState = ModuleState.fullTime;
    _enter(ModuleState.fullTime);
  }

  /// Re-send the half-time countdown so the robot's break clock stays in sync.
  void halfTimeSyncTime() {
    if (_state == ModuleState.halfTime) bleNotify();
  }

  /// Simultaneous START (CLAUDE.md invariant #1): three fire-and-forget PLAY
  /// frames, never awaited, then one acknowledged PLAY. With [clearPenalty]
  /// false a penalised robot is (re)sent DAMAGE instead of PLAY.
  void playAll({required bool clearPenalty}) async {
    _suppressNextRestoreNotify = false;
    _lastState = _state;
    if (!clearPenalty && _penaltyTime > 0) {
      _setPlaying(false);
      _state = ModuleState.damage;
      bleNotify();
      _game.persistence.markDirty();
      return;
    }
    _setPlaying(true);
    _penaltyTime = 0;
    _state = ModuleState.play;
    for (var i = 0; i < 3; i++) {
      bleSendPlayAll();
      await Future.delayed(const Duration(milliseconds: 100));
    }
    bleSendPlay();
    _game.persistence.markDirty();
  }

  /// Simultaneous STOP (invariant #1). A module parked in half-time/full-time
  /// is re-sent that state instead of STOP unless [force] is set.
  void stopAll(bool removePenalty, {bool force = false}) async {
    if (removePenalty) _penaltyTime = 0;
    if (force) _lastState = ModuleState.stop;
    switch (_lastState) {
      case ModuleState.halfTime:
        halfTime();
      case ModuleState.fullTime:
        gameOver();
      default:
        _setPlaying(false);
        _state = ModuleState.stop;
        for (var i = 0; i < 3; i++) {
          bleSendStopAll();
          await Future.delayed(const Duration(milliseconds: 100));
        }
    }
    _game.persistence.markDirty();
  }

  /// One second of penalty countdown; re-sends DAMAGE every 10 s and releases
  /// the robot at zero.
  void notifyTimer() {
    if (_penaltyTime <= 0) return;
    _penaltyTime--;
    if (_penaltyTime <= 0) {
      play();
    } else if (_penaltyTime % 10 == 0) {
      bleSendDamage(_penaltyTime);
    }
  }

  void _askForPenalty() {
    if (_game.isGameRunning && _state == ModuleState.play) {
      penalty(_game.penaltyTime);
    } else {
      debugPrint('Penalty not allowed in current state: $_state');
    }
  }

  // ---- BLE protocol ----

  static List<int> _millisFrame(BleMsgId id, int seconds) {
    // Robots take milliseconds; +1000 so they start exactly when 0 shows.
    final ms = seconds * 1000 + 1000;
    return [
      id.index,
      (ms >> 24) & 0xFF,
      (ms >> 16) & 0xFF,
      (ms >> 8) & 0xFF,
      ms & 0xFF
    ];
  }

  List<int> _scoreFrame(BleMsgId id) => [
        id.index,
        _game.getScore(_teamId),
        _game.getScore(_teamId, oppositeTeam: true),
      ];

  /// Write one frame; false when not connected or the write failed. Callers on
  /// the START/STOP fan-out pass `timeout: 0` (fire-and-forget).
  Future<bool> _write(List<int> frame, {int timeout = 15}) async {
    if (!_isConnected) return false;
    try {
      await _tx?.write(frame, timeout: timeout);
      return true;
    } catch (e) {
      if (timeout != 0) debugPrint('BLE write ${frame.first} failed: $e');
      return false;
    }
  }

  Future<bool> bleSendPlayAll() => _write([BleMsgId.play.index], timeout: 0);
  Future<bool> bleSendStopAll() => _write([BleMsgId.stop.index], timeout: 0);
  Future<bool> bleSendPlay() => _write([BleMsgId.play.index]);
  Future<bool> bleSendStop() => _write([BleMsgId.stop.index]);
  Future<bool> bleSendDamage(int seconds) =>
      _write(_millisFrame(BleMsgId.damage, seconds));
  Future<bool> bleSendHalfTime() =>
      _write(_millisFrame(BleMsgId.halfBreak, _game.remainingTime));
  Future<bool> bleSendGameOver() => _write(_scoreFrame(BleMsgId.gameOver));
  Future<bool> bleSendName() => _write(
      [BleMsgId.setName.index, ...name.padRight(2).substring(0, 2).codeUnits]);

  Future<bool> bleSendScore() async {
    if (!_isConnected) return false;
    await Future.delayed(const Duration(milliseconds: 200));
    return _write(_scoreFrame(BleMsgId.setScore));
  }

  /// Push the current match state to the robot.
  void bleNotify() async {
    if (_suppressNextRestoreNotify) {
      _suppressNextRestoreNotify = false;
      await bleSendStop();
      return;
    }
    switch (_state) {
      case ModuleState.play:
        await bleSendPlay();
      case ModuleState.stop:
        await bleSendStop();
      case ModuleState.damage:
        await bleSendDamage(_penaltyTime);
      case ModuleState.halfTime:
        await bleSendHalfTime();
      case ModuleState.fullTime:
        await bleSendGameOver();
    }
  }

  void _handleReceivedData(List<int> data) {
    if (data.isNotEmpty && data[0] == BleMsgId.askForPenalty.index) {
      _askForPenalty();
    } else {
      debugPrint('Unknown BLE message: $data');
    }
  }

  // ---- BLE link lifecycle ----

  void bleConnect() async {
    if (bleDevice == null || bleDevice!.isConnected) return;
    _connectIntent = true;
    bleStatus = 'Connecting...';
    notifyListeners();

    // Without this delay more than ~5 simultaneous connects intermittently fail.
    await Future.delayed(const Duration(milliseconds: 100));
    if (!_connectIntent || (bleDevice?.isConnected ?? false)) return;

    _connSub?.cancel();
    final device = bleDevice!;
    _connSub =
        device.connectionState.listen((s) => _onConnectionState(device, s));
    try {
      await bleDevice?.connect(autoConnect: true, mtu: null);
    } catch (e) {
      _connectIntent = false;
      bleStatus = describeError(e).message;
      debugPrint('BLE connect error: $e');
      _connSub?.cancel();
      // iOS: the id itself is unconnectable (stale cached UUID or a MAC fed to
      // fromId). Hand the slot back to the resolver; this is identity
      // resolution on a failed connect() CALL, never a reconnect loop.
      if (useIosBleUuid && _isIosUnknownPeripheralError(e)) {
        _game.iosPairing.enroll(this);
      }
    }
    notifyListeners();
  }

  /// flutter_blue_plus' (darwin 7.0.3) internal strings for "this id can never
  /// connect". Re-verify against FlutterBluePlusPlugin.m when upgrading fbp.
  static bool _isIosUnknownPeripheralError(Object e) {
    final msg = e.toString();
    return msg.contains('Peripheral not found') ||
        msg.contains('invalid remoteId');
  }

  void _onConnectionState(
      BluetoothDevice device, BluetoothConnectionState state) {
    debugPrint('BLE $name: $state');
    if (state == BluetoothConnectionState.disconnected) {
      _isConnected = false;
      // Status only: the OS autoConnect keeps retrying on the same GATT client.
      bleStatus = _connectIntent ? 'Connecting...' : 'Disconnected';
      notifyListeners();
    } else if (state == BluetoothConnectionState.connected) {
      _isConnected = true;
      _isSearching = false;
      bleStatus = 'Connected';
      // The advertised name is authoritative for the hardware MAC of THIS link.
      final parsed = _macFromDevice(device);
      if (parsed != null) hardwareMac = parsed;
      if (hardwareMac.isNotEmpty) {
        _game.iosPairing.record(hardwareMac, macAddress);
      }
      notifyListeners();
      _initLink();
    }
  }

  static String? _macFromDevice(BluetoothDevice device) =>
      macFromAdvertisedName(device.platformName) ??
      macFromAdvertisedName(device.advName);

  Future<void> _initLink() async {
    final device = bleDevice!;
    final services = await device.discoverServices();
    final service = services.where((s) => s.uuid == _serviceGuid).firstOrNull;
    if (service == null) {
      bleDisconnect(reason: "Couldn't find robot service");
      return;
    }
    final hasChars = service.characteristics
        .any((c) => c.uuid == _txGuid || c.uuid == _rxGuid);
    if (!hasChars) {
      bleDisconnect(reason: 'Robot is missing expected data channel');
      return;
    }
    _tx = BluetoothCharacteristic(
        remoteId: device.remoteId,
        serviceUuid: _serviceGuid,
        characteristicUuid: _txGuid);
    _rx = BluetoothCharacteristic(
        remoteId: device.remoteId,
        serviceUuid: _serviceGuid,
        characteristicUuid: _rxGuid);
    try {
      await _rx!.setNotifyValue(true);
      // Replace the listener so reconnects don't stack duplicate handlers.
      await _rxSub?.cancel();
      _rxSub = _rx!.onValueReceived.listen(_handleReceivedData);
    } catch (e) {
      debugPrint('Error enabling RX notifications: $e');
    }
    await bleSendName();
    await bleSendScore();
    bleNotify();
  }

  /// Cancel connecting / disconnect. Also cancels the OS autoConnect retry loop
  /// and a pending iOS resolver search, so a stuck slot always has a way out.
  void bleDisconnect({String? reason}) async {
    _game.iosPairing.cancel(this);
    _isSearching = false;
    _connectIntent = false;
    _isConnected = false;
    final status = reason ?? 'Disconnected';
    if (bleDevice == null) {
      if (bleStatus != status) {
        bleStatus = status;
        notifyListeners();
      }
      return;
    }
    bleStatus = status;
    notifyListeners();
    _cancelLinkListeners();
    try {
      await bleDevice?.disconnect();
    } catch (e) {
      debugPrint('bleDisconnect error: $e');
    }
  }

  void _cancelLinkListeners() {
    _connSub?.cancel();
    _rxSub?.cancel();
    _rxSub = null;
  }

  /// Point this slot at [device] (or nothing). Tears down the previous link and
  /// keeps [hardwareMac] in step: explicit > MAC-shaped id > advertised name;
  /// a changed id with nothing derivable clears the stale MAC.
  void setBleDevice(BluetoothDevice? device, {String? hardwareMac}) {
    if (bleDevice != null) {
      unawaited(bleDevice!.disconnect().catchError((Object e) {
        debugPrint('setBleDevice disconnect error: $e');
      }));
      _cancelLinkListeners();
    }
    _connectIntent = false;
    _isConnected = false;
    _isSearching = false;
    bleDevice = device;
    if (device == null) return;

    final previousId = macAddress;
    macAddress = device.remoteId.toString();
    if (hardwareMac != null && hardwareMac.isNotEmpty) {
      this.hardwareMac = hardwareMac;
    } else if (isMacFormat(macAddress)) {
      this.hardwareMac = macAddress;
    } else {
      final parsed = _macFromDevice(device);
      if (parsed != null) {
        this.hardwareMac = parsed;
      } else if (previousId.toUpperCase() != macAddress.toUpperCase()) {
        this.hardwareMac = '';
      }
    }
  }

  /// iOS resolver status: waiting for the match-load scan to learn the UUID.
  void markSearching() {
    if (_isConnected || _connectIntent) return;
    _isSearching = true;
    bleStatus = 'Searching...';
    notifyListeners();
  }

  /// iOS resolver stopped (kickoff) without finding this module.
  void markSearchGaveUp() {
    _isSearching = false;
    if (_isConnected || _connectIntent) return;
    bleStatus = 'Not found';
    notifyListeners();
  }

  /// Apply a stored pairing: label (always; '' restores the default name),
  /// identity, and a connect when enabled. Idempotent for a slot already live
  /// on the same module so re-pairs never churn a working link.
  void applyPresetConfig(String macAddress, String label,
      {String? hardwareMac}) {
    setLabel(label);
    final targetMac = (hardwareMac != null && hardwareMac.isNotEmpty)
        ? hardwareMac.toUpperCase()
        : (isMacFormat(macAddress) ? macAddress.toUpperCase() : '');

    if (macAddress.isEmpty) {
      // Hardware MAC only (iOS slot awaiting its UUID). A changed identity
      // retires the whole previous link, not just the MAC.
      if (targetMac.isEmpty) return;
      if (this.hardwareMac != targetMac &&
          (bleDevice != null || this.macAddress.isNotEmpty)) {
        setBleDevice(null);
        this.macAddress = '';
      }
      this.hardwareMac = targetMac;
      return;
    }

    final newId = macAddress.toUpperCase();
    if (_isConnected && this.macAddress.toUpperCase() == newId) {
      if (targetMac.isNotEmpty) this.hardwareMac = targetMac;
      return;
    }
    if (_isConnected &&
        this.hardwareMac.isNotEmpty &&
        this.hardwareMac == newId) {
      return;
    }
    setBleDevice(BluetoothDevice.fromId(newId), hardwareMac: targetMac);
    if (_isEnabled) bleConnect();
  }

  // ---- cold-resume snapshot ----

  ModuleSnapshot toSnapshot() => ModuleSnapshot(
        moduleId: moduleId,
        isEnabled: _isEnabled,
        macAddress: macAddress,
        hardwareMac: hardwareMac,
        customLabel: hasCustomLabel ? _label : null,
        state: _state.name,
        lastState: _lastState.name,
        penaltyTime: _penaltyTime,
      );

  /// Restore from a snapshot. play/halfTime/fullTime normalise to stop (a
  /// restored `play` would auto-PLAY on reconnect); damage is kept, with the
  /// restore-notify one-shot armed so the reconnect sends STOP only.
  void restoreFromSnapshot(ModuleSnapshot s) {
    s.isEnabled ? enable() : disable();
    _penaltyTime = s.penaltyTime;
    _state = _restoredState(s.state);
    _lastState = _restoredState(s.lastState);
    _suppressNextRestoreNotify = true;

    if (s.isEnabled && s.macAddress.isNotEmpty) {
      applyPresetConfig(s.macAddress, s.customLabel ?? '',
          hardwareMac: s.hardwareMac);
    } else {
      macAddress = s.macAddress;
      if (s.hardwareMac.isNotEmpty) {
        hardwareMac = s.hardwareMac;
      } else if (isMacFormat(s.macAddress)) {
        hardwareMac = s.macAddress;
      }
      setLabel(s.customLabel ?? '');
    }
    notifyListeners();
  }

  static ModuleState _restoredState(String name) =>
      name == ModuleState.damage.name ? ModuleState.damage : ModuleState.stop;
}
