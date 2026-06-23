import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/services/error_messages.dart';


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
  String macAddress = '';
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
    }
    notifyListeners();

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
    // Note: no `!isConnected` guard. While autoConnect is still retrying the
    // device is NOT connected, yet we must still call disconnect() to cancel
    // that pending retry loop and clear the connect intent — otherwise a dead
    // module is stuck on "Connecting..." forever with no way out.
    if (bleDevice == null) return;

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
  }

  void play() async {
    _lastState = _state;
    _playStatus(true);
    _penaltyTime = 0;
    _state = ModuleState.play;

    bleNotify();
    notifyListeners();
  }

  void playOrDamageAll() async {
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
  }

  void playAll() async {
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
  }

  void penalty(int seconds) {
    _playStatus(false);
    _penaltyTime = seconds;
    _state = ModuleState.damage;

    bleNotify();
    notifyListeners();
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

  void setLabel(String label) {
    _label = label.trim();
    notifyListeners();
    // Push the new name to the robot display immediately when connected;
    // bleSendName() self-guards on connection, so this is a no-op otherwise.
    // (Not in the START/STOP critical path — fire-and-forget is fine.)
    unawaited(bleSendName());
  }

  void applyPresetConfig(String macAddress, String label) {
    // Always apply the label: an empty label resolves to the default name via
    // the `name` getter, so reloading a preset whose module used the default
    // name correctly clears any custom label left over from a previous preset.
    setLabel(label);
    if (macAddress.isEmpty) return;
    final newMac = macAddress.toUpperCase();
    // Already connected to this exact module: just (re)label it. Re-running
    // setBleDevice()+bleConnect() would disconnect the live link and then race
    // bleConnect()'s isConnected guard, leaving it stuck on "Connecting...".
    if (_isConnected && this.macAddress.toUpperCase() == newMac) {
      return;
    }
    setBleDevice(BluetoothDevice.fromId(newMac));
    if (_isEnabled) {
      bleConnect();
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