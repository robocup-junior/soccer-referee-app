import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/services/error_messages.dart';
import 'package:rcj_scoreboard/services/match_state_store.dart';
import 'package:rcj_scoreboard/utils/ble_address.dart';


enum ModuleState {
  play,
  stop,
  damage,
  halfTime,
  fullTime,
}

// BLE Massage IDs
enum BleMsgId {
  bleMsgPing,
  bleMsgFwVersion,
  bleMsgSetName,
  bleMsgSetScore,
  bleMsgPlay,
  bleMsgStop,
  bleMsgDamage,
  bleMsgHalfBreak,
  bleMsgGameOver,
  bleMsgDisconnect,
  bleMsgAskForPenalty,
  bleMsgMaxId // Must be last be last
}


class Module with ChangeNotifier {
  final String _name;
  String? _label;
  final String _teamId;
  final Game _game;
  final int moduleId;
  final String _serviceUUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
  final String _characteristicUUIDTX = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";
  final String _characteristicUUIDRX = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";

  ModuleState _state = ModuleState.stop;
  ModuleState _lastState = ModuleState.stop;




  bool _isEnabled = true;
  bool _isConnected = false;
  bool _isPlaying = false;
  int _penaltyTime = 0;
  // One-shot set by [restoreFromSnapshot] on a cold-resume restore. The FIRST
  // post-restore [bleNotify] (fired seconds later from the reconnect's
  // connected-event, so a synchronous game-scoped flag would already be cleared)
  // consumes it and sends at most a STOP — never play/damage — so a robot can't
  // auto-PLAY or self-release its penalty while the match clock is frozen. It is
  // per-module so each module's own late reconnect is covered, and one-shot so
  // it can't linger and suppress the referee's later START.
  bool _suppressNextRestoreNotify = false;
  // Whether the module should resume playing when its penalty is cleared or
  // expires. Captured at penalty() entry: a module penalised from the play
  // state (the only way a connected module is penalised) resumes play, while a
  // no-module penalty recorded on a stopped module returns to stop.
  bool _resumeAfterPenalty = false;
  String macAddress = '';
  // The module's permanent hardware MAC (uppercase, '' if unknown) — the
  // stable identity the scoreboard server knows (#82). On Android it equals
  // [macAddress] (a BLE peripheral is addressed by its MAC); on iOS
  // [macAddress] is a per-phone CoreBluetooth UUID and this is recovered from
  // the QR scan, the advertised name `RCJs-m_<MAC>`, or the match-load
  // resolver. Reported in the scoreboard result POST instead of [macAddress].
  String hardwareMac = '';
  String bleStatus = 'Disconnected';
  // True while we want to be connected (connect tapped, autoConnect active).
  // Lets a device-level disconnect read as "Connecting..." (still trying) rather
  // than "Disconnected", until the user explicitly disconnects.
  bool _connectIntent = false;
  BluetoothDevice? bleDevice;
  StreamSubscription<BluetoothConnectionState>? subscription;
  // RX-notification listener. Held so it can be cancelled before a replacement
  // is attached on reconnect (bleInitModule runs on every connected event) and
  // on teardown — otherwise auto-reconnect would stack duplicate listeners that
  // each deliver the same inbound message. Cancelling only drops the Dart
  // subscription; it never turns the characteristic notification off on a live
  // connection.
  StreamSubscription<List<int>>? _rxSubscription;
  BluetoothCharacteristic? bleTX;
  BluetoothCharacteristic? bleRX;


  Module(this._game, this._teamId, this._name, this.moduleId);

  void init() {
    _stop();
    _penaltyTime = 0;
    _state = ModuleState.stop;
    _lastState = ModuleState.stop;
    _resumeAfterPenalty = false;
  }

  void enable() {
    _isEnabled = true;
  }

  void disable() {
    _isEnabled = false;
    _playStatus(false);
    bleDisconnect();
  }

  void bleNotify() async {
    if (_suppressNextRestoreNotify) {
      // First reconnect after a cold-resume restore: keep the robot stopped
      // regardless of the restored _state (esp. a restored `damage` module),
      // so its penalty countdown does not start while the match clock is
      // frozen. The referee's double-tap START re-arms play/damage with time.
      try {
        await bleSendStop();
      } finally {
        _suppressNextRestoreNotify = false;
      }
      return;
    }
    switch (_state) {
      case ModuleState.play:
        await bleSendPlay();
        break;
      case ModuleState.stop:
        await bleSendStop();
        break;
      case ModuleState.damage:
        await bleSendDamage(_penaltyTime);
        break;
      case ModuleState.halfTime:
        await bleSendHalfTime();
        break;
      case ModuleState.fullTime:
        await bleSendGameOver();
        break;
      }
  }

  void  bleConnect() async {
    //debugPrint('BLE connect...........................');
    if (bleDevice == null || bleDevice!.isConnected) return;
    //debugPrint('BLE connect222...........................');

    // Set the intent BEFORE the pre-connect delay so a bleDisconnect() that runs
    // during the delay (user Cancel / disconnectAll) is observable when we
    // re-check below — otherwise this in-flight connect would revive autoConnect
    // after the user asked to stop.
    _connectIntent = true;
    bleStatus = 'Connecting...';
    notifyListeners();

    // don't know why but without this delay sometimes it cannot connect more than 5 modules
    await Future.delayed(const Duration(milliseconds: 100));

    // Abort if the user disconnected (intent cleared) or the device connected
    // during the delay.
    if (!_connectIntent || (bleDevice?.isConnected ?? false)) return;

    subscription?.cancel();
    _registerBleSubscriber(bleDevice!);

    try {
      //bleStatus = 'Connecting...';
      await bleDevice?.connect(autoConnect:true, mtu: null);
    } catch (e) {
      // The initial connect() failed — drop the connect intent (parity with the
      // bridge) so a stray event can never flip the message back to
      // "Connecting...". Reconnection of a module that DID connect is handled by
      // connect(autoConnect:true) at the OS level, not by re-entering here.
      _connectIntent = false;
      bleStatus = describeError(e).message;
      debugPrint('BLE connect error: $e');
      subscription?.cancel();
      // #82 (iOS): connect() never even started because the identity is not
      // connectable — a stale cached UUID ("Peripheral not found") or a
      // MAC-shaped id fed to fromId ("invalid remoteId"). When the hardware
      // MAC is known, hand the module to the match-load resolver (it scans
      // only while no half runs) instead of leaving a dead error status. This
      // fires once per failed connect() CALL, never from disconnect events —
      // it is identity resolution, not reconnection (invariant #5).
      if (useIosBleUuid &&
          hardwareMac.isNotEmpty &&
          _isIosUnknownPeripheralError(e)) {
        _game.enrollIosMacResolve(this);
      }
    }
    notifyListeners();

  }

  /// The two iOS connect() failures that mean "this connection id cannot ever
  /// connect" (see flutter_blue_plus_darwin FlutterBluePlusPlugin.m): the UUID
  /// is unknown to CoreBluetooth, or the id was not a UUID at all.
  static bool _isIosUnknownPeripheralError(Object e) {
    final msg = e.toString();
    return msg.contains('Peripheral not found') ||
        msg.contains('invalid remoteId');
  }

  Future<bool> bleCheckServicesAndGetCharacteristics() async {
    List<BluetoothService> services = await bleDevice!.discoverServices();

    var service = services.where((element) => element.uuid == Guid.fromString(_serviceUUID));
    if (service.isEmpty) {
      debugPrint('Required service not found');
      bleDisconnect(reason: "Couldn't find robot service");
      return false;
    }

    var characteristic = service.firstOrNull?.characteristics.where((element) => element.uuid == Guid.fromString(_characteristicUUIDTX) || element.uuid == Guid.fromString(_characteristicUUIDRX));
    if (characteristic == null || characteristic.isEmpty) {
      debugPrint('Required characteristics not found');
      bleDisconnect(reason: 'Robot is missing expected data channel');
      return false;
    }

    bleTX = BluetoothCharacteristic(remoteId: bleDevice!.remoteId, serviceUuid: Guid.fromString(_serviceUUID) , characteristicUuid: Guid.fromString(_characteristicUUIDTX));
    bleRX = BluetoothCharacteristic(remoteId: bleDevice!.remoteId, serviceUuid: Guid.fromString(_serviceUUID) , characteristicUuid: Guid.fromString(_characteristicUUIDRX));

    return true;
  }

  Future<void> enableRXNotifications() async {
    if (bleRX != null) {
      try {
        await bleRX!.setNotifyValue(true);
        // Replace any previous listener so reconnects don't accumulate
        // duplicate handlers for the same characteristic.
        await _rxSubscription?.cancel();
        _rxSubscription = bleRX!.onValueReceived.listen((data) {
          handleReceivedData(data);
        });
      } catch (e) {
        debugPrint('Error enabling RX notifications: $e');
      }
    }
  }

  void handleReceivedData(List<int> data) {
    // Example: Convert data to a string
    // String receivedString = utf8.decode(data);
    // debugPrint('Received data: $receivedString');
    switch (BleMsgId.values[data[0]]) {
      case BleMsgId.bleMsgAskForPenalty:
        debugPrint('Ask for penalty');
        _askForPenalty();
        break;
      default:
        debugPrint('Unknown message ID: ${data[0]}');
    }
    // Add further processing logic here
  }

  void bleInitModule() async {
    await bleCheckServicesAndGetCharacteristics();

    await enableRXNotifications();

    bleSendCurrentState();
  }


  Future<bool> bleSendHalfTime() async {
    if (!_isConnected) return false;
    int seconds = 300;
    seconds = (_game.remainingTime * 1000) + 1000; // module take time in milliseconds and +1000 to start robot exactly when 0 show and not way for 0.x second

    try {
      await bleTX?.write([7] +
          [(seconds >> 24) & 0xFF,
            (seconds >> 16) & 0xFF,
            (seconds >> 8) & 0xFF,
            seconds & 0xFF]);
      return true;
    } catch (e) {
      debugPrint('Send HalfTime error');
      return false;
    }
  }

  Future<bool> bleSendGameOver() async {
    if (!_isConnected) return false;
    try {
      await bleTX?.write([BleMsgId.bleMsgGameOver.index, _game.getScore(_teamId), _game.getScore(_teamId, oppositeTeam: true)]);
      return true;
    } catch (e) {
      debugPrint('Send GameOver error');
      return false;
    }
  }


  Future<bool> bleSendName() async {
    if (!_isConnected) return false;
    try {
      final displayName = name.padRight(2).substring(0, 2);
      await bleTX?.write([BleMsgId.bleMsgSetName.index] + displayName.codeUnits);
      return true;
    } catch (e) {
      debugPrint('Send name error');
      return false;
    }
  }

  Future<bool> bleSendScore() async {
    if (!_isConnected) return false;
    try {
      await Future.delayed(const Duration(milliseconds: 200));
      await bleTX?.write([BleMsgId.bleMsgSetScore.index, _game.getScore(_teamId), _game.getScore(_teamId, oppositeTeam: true)]);
      return true;
    } catch (e) {
      debugPrint('Send score error $e');
      return false;
    }
  }

  Future<bool> bleSendStop() async {
    if (!_isConnected) return false;
    try {
      await bleTX?.write([BleMsgId.bleMsgStop.index]);
      return true;
    } catch (e) {
      debugPrint('Send stop error $e');
      return false;
    }
  }

  Future<bool> bleSendStopAll() async {
    if (!_isConnected) return false;
    try {
      await bleTX?.write([BleMsgId.bleMsgStop.index], timeout:0);
      return true;
    } catch (e) {
      //debugPrint('Send stop all error $e');
      return false;
    }
  }

  Future<bool> bleSendPlayAll() async {
    if (!_isConnected) return false;
    try {
      await bleTX?.write([BleMsgId.bleMsgPlay.index], timeout:0);
      return true;
    } catch (e) {
      //debugPrint('Send play all error $e');
      return false;
    }
  }


  Future<bool> bleSendPlay() async {
    if (!_isConnected) return false;
    try {
      await bleTX?.write([BleMsgId.bleMsgPlay.index]);
      return true;
    } catch (e) {
      debugPrint('Send play error');
      return false;
    }
  }

  Future<bool> bleSendDamage(int seconds) async {
    if (!_isConnected) return false;
    seconds = (seconds * 1000) + 1000; // module take time in milliseconds and +1000 to start robot exactly when 0 show and not way for 0.x second
    try {
      await bleTX?.write([BleMsgId.bleMsgDamage.index] +
        [(seconds >> 24) & 0xFF,
        (seconds >> 16) & 0xFF,
        (seconds >> 8) & 0xFF,
        seconds & 0xFF]);
      return true;
    } catch (e) {
      debugPrint('Send play error');
      return false;
    }
  }

  void bleSendCurrentState() async {
    await bleSendName();
    await bleSendScore();
    bleNotify();
  }


  void bleDisconnect({String? reason}) async {
    // #82: a module can be "Searching..." — enrolled with the iOS resolver,
    // no device yet. Cancel must reach that state too, and an in-flight scan
    // hit for it must not revive it (the resolver drops non-pending hits).
    _game.cancelIosMacResolve(this);
    // Note: no `!isConnected` guard. While autoConnect is still retrying the
    // device is NOT connected, yet we must still call disconnect() to cancel
    // that pending retry loop and clear the connect intent — otherwise a dead
    // module is stuck on "Connecting..." forever with no way out.
    if (bleDevice == null) {
      // Device-less Cancel (a Searching module): reflect the stop in status.
      if (bleStatus != 'Disconnected') {
        bleStatus = reason ?? 'Disconnected';
        notifyListeners();
      }
      return;
    }

    // Clear the connect intent *synchronously* before the async disconnect, so
    // the disconnect event that disconnect() triggers reads as an intended
    // "Disconnected" (not "Connecting...") and the OS autoConnect is not seen as
    // something to keep showing as in-progress.
    _connectIntent = false;
    _isConnected = false;
    bleStatus = reason ?? 'Disconnected';
    notifyListeners();

    // Cancel the connection-state listener BEFORE disconnecting so the teardown
    // disconnect event can't drive any further status work.
    // (Same cancel-first ordering as setBleDevice().)
    subscription?.cancel();
    _rxSubscription?.cancel();
    _rxSubscription = null;

    // Disconnect from device also disables auto connect
    await bleDevice?.disconnect();



  }

  void _playStatus(bool play) {
    if (play == _isPlaying) return; // skip if the current state is same
    _isPlaying = play;
    play ? _game.changeNumberOfPlaying(1) : _game.changeNumberOfPlaying(-1);
  }

  void playOrDamage() {
    _clearRestoreSuppress();
    _lastState = _state;
    if (_penaltyTime > 0) {
      _playStatus(false);
      _state = ModuleState.damage;
    } else {
      _playStatus(true);
      _penaltyTime = 0;
      _state = ModuleState.play;
    }

    bleNotify();
    notifyListeners();
    // Single-module action (not the simultaneous START/STOP fan-out), so a
    // scheduled flush is latency-safe and persists it even when the clock is
    // stopped (e.g. a robot toggled while the cold-resumed clock is frozen).
    _game.markMatchStateDirtyAndFlush();
  }

  void play() async {
    _clearRestoreSuppress();
    // Clearing or expiring a penalty for a module that was not playing before
    // the penalty (e.g. a no-module penalty recorded on a stopped module) must
    // return it to stop, not promote it to playing.
    if (_state == ModuleState.damage && !_resumeAfterPenalty) {
      _penaltyTime = 0;
      _stop();
      return;
    }
    _resumeAfterPenalty = false;

    _lastState = _state;
    _playStatus(true);
    _penaltyTime = 0;
    _state = ModuleState.play;

    bleNotify();
    notifyListeners();
    _game.markMatchStateDirtyAndFlush();
  }

  void playOrDamageAll() async {
    _clearRestoreSuppress();
    _lastState = _state;
    if (_penaltyTime > 0) {
      _playStatus(false);
      _state = ModuleState.damage;
      bleNotify();
    } else {
      _playStatus(true);
      _penaltyTime = 0;
      _state = ModuleState.play;

      for (int i = 0; i < 3; i++) {
        bleSendPlayAll();
        await Future.delayed(const Duration(milliseconds: 100));
      }
      // Send it one more time with acknowledgment to ensure all modules are in play state
      bleSendPlay();
    }
    _game.markMatchStateDirty();
  }

  void playAll() async {
    _clearRestoreSuppress();
    _lastState = _state;
    _playStatus(true);
    _penaltyTime = 0;
    _state = ModuleState.play;



    for (int i = 0; i < 3; i++) {
      bleSendPlayAll();
      await Future.delayed(const Duration(milliseconds: 100));
    }
    // Send it one more time with acknowledgment to ensure all modules are in play state
    bleSendPlay();
    _game.markMatchStateDirty();
  }

  // Cancel a pending cold-resume restore suppression: once the referee starts a
  // robot (any START path), subsequent reconnect bleNotify()s must reflect the
  // real state, not a lingering STOP. Without this a late reconnect after START
  // would STOP an already-playing robot (the play START path does not itself
  // call bleNotify, so it would not otherwise consume the one-shot).
  void _clearRestoreSuppress() {
    _suppressNextRestoreNotify = false;
  }

  void stopAll(bool removePenalty, {bool force = false}) async {
    if (removePenalty) _penaltyTime = 0;
    if (force) _lastState = ModuleState.stop;

    switch (_lastState) {
      case ModuleState.halfTime:
        halfTime();
      case ModuleState.fullTime:
        gameOver();
      default:
        _playStatus(false);
        _state = ModuleState.stop;
        for (int i = 0; i < 3; i++) {
          bleSendStopAll();
          await Future.delayed(const Duration(milliseconds: 100));
        }
    }
    _game.markMatchStateDirty();
  }

  void stop() {
    switch (_lastState) {
      case ModuleState.stop:
        _stop();
      case ModuleState.halfTime:
        halfTime();
      case ModuleState.fullTime:
        gameOver();
      default:
        debugPrint('Wrong last ModuleState');
    }
  }



  void _stop() {
    _playStatus(false);
    _state = ModuleState.stop;

    bleNotify();
    notifyListeners();
    _game.markMatchStateDirty();
  }

  void penalty(int seconds) {
    _resumeAfterPenalty = _isPlaying || _state == ModuleState.play;
    _playStatus(false);
    _penaltyTime = seconds;
    _state = ModuleState.damage;

    bleNotify();
    notifyListeners();
    // Penalty given is a discrete recoverable event; flush it (off the hot path)
    // so it survives a crash even if the clock isn't running to drive a heartbeat.
    _game.markMatchStateDirtyAndFlush();
  }

  void _askForPenalty() {
    if (_game.isGameRunning && _state == ModuleState.play) {
      penalty(_game.penaltyTime);
    } else {
      debugPrint('Penalty not allowed in current state: $_state');
    }
  }

  void halfTime() {
    _playStatus(false);
    _penaltyTime = 0;
    _state = ModuleState.halfTime;
    _lastState = ModuleState.halfTime;

    bleNotify();
    notifyListeners();
    _game.markMatchStateDirty();
  }

  void halfTimeSyncTime() {
    if (_state == ModuleState.halfTime) {
      bleNotify();
    }
  }


  void gameOver() {
    _playStatus(false);
    _state = ModuleState.fullTime;
    _lastState = ModuleState.fullTime;

    bleNotify();
    notifyListeners();
    _game.markMatchStateDirty();
  }



  void notifyTimer() {
    if (_penaltyTime > 0 ) {
      _penaltyTime --;
      if (_penaltyTime <= 0) {
        play();
      } else if (_penaltyTime % 10 == 0) {
        bleSendDamage(_penaltyTime);
      }
    }
  }

  void setBleDevice(BluetoothDevice? device) {
    // check if there is currently some device saved in devices if so try to call proper disconnect to it
    if (bleDevice != null) {
      debugPrint('try disconect previos one');
      bleDevice?.disconnect();
      // Cancel the old device's connection-state and RX listeners so they can't
      // drive reconnect work or duplicate-deliver messages against a device
      // we're replacing.
      subscription?.cancel();
      _rxSubscription?.cancel();
      _rxSubscription = null;
    }

    // Swapping the device is a fresh-connection boundary: clear the old
    // device's reconnect lifecycle so no stale intent carries over (issue #38).
    // Callers that want a connection call bleConnect() right after, which
    // re-establishes intent.
    _connectIntent = false;
    _isConnected = false;

     bleDevice = device;

     if (bleDevice == null) return;

     macAddress = bleDevice!.remoteId.toString();
     // #82: keep the stable hardware identity in step, never clobbering a
     // known value with an unknown one. On Android remoteId IS the MAC; on iOS
     // it is a UUID, so try the (possibly empty, e.g. fromId-built) platform
     // name — the connected event backfills reliably once the name is known.
     if (isMacFormat(macAddress)) {
       hardwareMac = macAddress.toUpperCase();
     } else {
       final parsed = macFromAdvertisedName(bleDevice!.platformName);
       if (parsed != null) hardwareMac = parsed;
     }
  }

  void _registerBleSubscriber(BluetoothDevice device) {
    subscription = device.connectionState.listen((BluetoothConnectionState state) async {
      debugPrint('BLE device status: $state');
      if (state == BluetoothConnectionState.disconnected) {
        _isConnected = false;
        debugPrint('disconnect');

        // Reconnection is owned entirely by connect(autoConnect:true): the OS
        // keeps retrying on the SAME GATT client, unbounded, until disconnect()
        // is called. That is exactly the in-match behavior we need — a penalised
        // robot (~1 min off) or a halftime power-down (~5 min) rejoins the
        // instant it returns, with no referee action. We deliberately do NOT
        // re-enter bleConnect() here: each call registers a fresh GATT clientIf
        // without close()-ing the previous BluetoothGatt, leaking ~1 client per
        // reconnect per module (device-verified on a Pixel 10) and exhausting
        // Android's ~30-client ceiling within minutes of penalty/halftime
        // cycling across 10 modules — a tournament-killer. See CLAUDE.md
        // invariant #5 and docs/ai/02_RUNTIME_ARCHITECTURE.md.
        //
        // So this handler only reflects status: while we still intend to be
        // connected, show "Connecting..." (also covers the initial disconnected
        // event right after connect()). Post-match teardown of powered-down
        // modules is a one-shot at the full-time transition
        // (Game.disconnectInactiveModules), not a per-disconnect action here —
        // doing it here would also tear down a fresh post-match connect on its
        // initial disconnected event.
        bleStatus = _connectIntent ? 'Connecting...' : 'Disconnected';
        notifyListeners();
      } else if (state == BluetoothConnectionState.connected) {
        _isConnected = true;
        debugPrint('Connect');
        bleStatus = 'Connected';
        // #82: once connected the advertised name is reliably cached, so a
        // module connected by UUID without a QR scan (saved device, scan-list
        // pick) still learns its hardware MAC for the scoreboard report.
        if (hardwareMac.isEmpty) {
          final parsed = macFromAdvertisedName(device.platformName);
          if (parsed != null) hardwareMac = parsed;
        }
        notifyListeners();
        bleInitModule();
      }
    });
  }






  String get currentPenalty => _penaltyTime > 0 ? _penaltyTime.toString() : '';


  bool get isEnabled => _isEnabled;
  bool get isConnected => _isConnected;
  // Trying to connect (autoConnect retrying), not yet connected. Lets the UI
  // offer a Cancel action to break out of an endless "Connecting..." loop.
  bool get isConnecting => _connectIntent && !_isConnected;
  bool get isPlaying => _isPlaying;
  String get name => (_label != null && _label!.isNotEmpty) ? _label! : _name;
  String get defaultName => _name;
  bool get hasCustomLabel => _label != null && _label!.isNotEmpty;
  int get penaltyTime => _penaltyTime;
  ModuleState get state => _state;
  @visibleForTesting
  ModuleState get lastState => _lastState;
  @visibleForTesting
  bool get suppressNextRestoreNotify => _suppressNextRestoreNotify;

  void setLabel(String label) {
    _label = label.trim();
    notifyListeners();
    // Push the new name to the robot display immediately when connected;
    // bleSendName() self-guards on connection, so this is a no-op otherwise.
    // (Not in the START/STOP critical path — fire-and-forget is fine.)
    unawaited(bleSendName());
    // A module label is recoverable state. Schedule a flush (not just a dirty
    // flag): labels are typically edited pre-match while the clock is stopped,
    // when the heartbeat isn't running, so a bare flag could be lost on a crash.
    // Off the START/STOP hot path, so the scheduled flush is fine.
    _game.markMatchStateDirtyAndFlush();
  }

  /// #82 (iOS): resolver status surface — the module is waiting for the
  /// match-load scan to learn its CoreBluetooth UUID. Guarded so it can never
  /// stomp a live or in-progress connection's status.
  void markSearching() {
    if (_isConnected || _connectIntent) return;
    bleStatus = 'Searching...';
    notifyListeners();
  }

  /// #82 (iOS): the resolver stopped (kickoff) without finding this module.
  /// The referee's manual scan/QR pairing stays available.
  void markSearchGaveUp() {
    if (_isConnected || _connectIntent) return;
    bleStatus = 'Not found';
    notifyListeners();
  }

  void applyPresetConfig(String macAddress, String label,
      {String? hardwareMac}) {
    // Always apply the label: an empty label resolves to the default name via
    // the `name` getter, so reloading a preset whose module used the default
    // name correctly clears any custom label left over from a previous preset.
    setLabel(label);
    // #82: record the stable hardware identity when the caller knows it
    // (snapshots, presets, iOS auto-pair). Android callers pass the MAC as the
    // connection id, so it doubles as the hardware MAC. Never clobber a known
    // value with an unknown one.
    if (hardwareMac != null && hardwareMac.isNotEmpty) {
      this.hardwareMac = hardwareMac.toUpperCase();
    } else if (isMacFormat(macAddress)) {
      this.hardwareMac = macAddress.toUpperCase();
    }
    // A slot may now carry only a hardware MAC while the iOS resolver looks
    // for its UUID — no connection identity yet means nothing to connect.
    if (macAddress.isEmpty) return;
    final newMac = macAddress.toUpperCase();
    // Already connected to this exact module: just (re)label it. Re-running
    // setBleDevice()+bleConnect() would disconnect the live link and then race
    // bleConnect()'s isConnected guard, leaving it stuck on "Connecting...".
    if (_isConnected && this.macAddress.toUpperCase() == newMac) {
      return;
    }
    // Same, keyed on the HARDWARE identity (#82): on iOS the stored connection
    // id is a UUID, so a re-pair passing the module's hardware MAC would never
    // match the guard above and would churn a live link — the auto-pair path
    // relies on re-pairs being no-ops (see _syncScoreboardModulePairing).
    if (_isConnected &&
        this.hardwareMac.isNotEmpty &&
        this.hardwareMac == newMac) {
      return;
    }
    setBleDevice(BluetoothDevice.fromId(newMac));
    if (_isEnabled) {
      bleConnect();
    }
  }

  // ---- Cold-resume snapshot / restore (#45) ----

  /// Capture this module's recoverable state for the match snapshot.
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

  /// Restore this module from a cold-resume snapshot. Ordering matters:
  ///   1. apply `isEnabled` first — `disable()` disconnects and
  ///      `applyPresetConfig` only reconnects when enabled, so the flag must be
  ///      correct before the reconnect step;
  ///   2. set the normalized state/penalty and arm the restore-notify one-shot;
  ///   3. re-establish the BLE device (a cold kill built a fresh Module with no
  ///      device), reusing the preset-load path for the auto-reconnect.
  void restoreFromSnapshot(ModuleSnapshot s) {
    if (s.isEnabled) {
      enable();
    } else {
      disable();
    }

    _penaltyTime = s.penaltyTime;
    // Normalize play/halfTime/fullTime -> stop for BOTH _state and _lastState:
    // a restored `play` _state would make the reconnect bleNotify() emit
    // bleSendPlay() (auto-PLAY), and a `play` _lastState would make the
    // single-tap Module.stop() (switches on _lastState) a silent no-op. Keep
    // damage/stop as-is.
    _state = _normalizeRestoredState(_parseState(s.state));
    _lastState = _normalizeRestoredState(_parseState(s.lastState));
    _suppressNextRestoreNotify = true;

    if (s.isEnabled && s.macAddress.isNotEmpty) {
      // applyPresetConfig() sets the label, builds the device and reconnects.
      // It takes a non-null label, hence `?? ''` (an empty label resolves to
      // the default name via the `name` getter). The hardware MAC rides along
      // (#82); a pre-split Android snapshot has none, but applyPresetConfig
      // backfills it from the MAC-shaped connection id.
      applyPresetConfig(s.macAddress, s.customLabel ?? '',
          hardwareMac: s.hardwareMac);
    } else {
      // Not reconnecting: still record the identities (for a later manual
      // connect / the iOS resolver) and apply the label, mirroring
      // applyPresetConfig's always-apply-label rule.
      macAddress = s.macAddress;
      if (s.hardwareMac.isNotEmpty) {
        hardwareMac = s.hardwareMac.toUpperCase();
      } else if (isMacFormat(s.macAddress)) {
        // Pre-split snapshot on Android: the stored connection id IS the MAC.
        hardwareMac = s.macAddress.toUpperCase();
      }
      setLabel(s.customLabel ?? '');
    }
    notifyListeners();
  }

  ModuleState _parseState(String name) => ModuleState.values.firstWhere(
        (s) => s.name == name,
        orElse: () => ModuleState.stop,
      );

  ModuleState _normalizeRestoredState(ModuleState state) {
    switch (state) {
      case ModuleState.damage:
        return ModuleState.damage;
      case ModuleState.stop:
      case ModuleState.play:
      case ModuleState.halfTime:
      case ModuleState.fullTime:
        return ModuleState.stop;
    }
  }

}


// class BleDeviceHandler {
//
//   BluetoothDevice device;
//   var subscription;
//
//
//   BleDeviceHandler(this.device) {
//
//   }
//
//   void _registerSubscriber() {
//     subscription = device.connectionState.listen((BluetoothConnectionState state) async {
//       debugPrint('BLE device status: $state');
//       if (state == BluetoothConnectionState.disconnected) {
//         // 1. typically, start a periodic timer that tries to
//         //    reconnect, or just call connect() again right now
//         // 2. you must always re-discover services after disconnection!
//         String bleStatus = 'Disconnected';
//         notifyListeners();
//         debugPrint("disconnect");
//       } else if (state == BluetoothConnectionState.connected) {
//         String bleStatus = 'Connect';
//       }
//     });
//     device.cancelWhenDisconnected(subscription, delayed:true, next:true);
//   }
//
//   Future connect() async {
//     _registerSubscriber();
//
//     // Connect to the device
//     try {
//       await device.connect();
//     } catch (e) {
//       debugPrint('BLE connect error');
//     }
//
//
//   }
//
//
//
//
// }