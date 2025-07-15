import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:rcj_scoreboard/models/game.dart';


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
  final String _team_id;
  final Game _game;
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
  BluetoothDevice? bleDevice;
  StreamSubscription<BluetoothConnectionState>? subscription;
  BluetoothCharacteristic? bleTX;
  BluetoothCharacteristic? bleRX;


  Module(this._game, this._team_id, this._name);

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
      case ModuleState.stop:
        await bleSendStop();
      case ModuleState.damage:
        await bleSendDamage(_penaltyTime);
      case ModuleState.halfTime:
        await bleSendHalfTime();
      case ModuleState.fullTime:
        await bleSendGameOver();
      default:
        print('unknown module state');
    }
  }

  void  bleConnect() async {
    //print('BLE connect...........................');
    if (bleDevice == null || bleDevice!.isConnected) return;
    //print('BLE connect222...........................');


    // don't know why but without this delay sometimes it cannot connect more than 5 modules
    await Future.delayed(const Duration(milliseconds: 100));

    subscription?.cancel();
    //bleDevice?.disconnect();

    bleStatus = 'Connecting...';
    notifyListeners();

    _registerBleSubscriber(bleDevice!);

    try {
      //bleStatus = 'Connecting...';
      await bleDevice?.connect(autoConnect:true, mtu: null);
    } catch (e) {
      bleStatus = 'Connection error';
      print('BLE connect error');
      subscription?.cancel();
    }
    notifyListeners();

  }

  Future<bool> bleCheckServicesAndGetCharacteristics() async {
    List<BluetoothService> services = await bleDevice!.discoverServices();

    var service = services.where((element) => element.uuid == Guid.fromString(_serviceUUID));
    if (service.isEmpty) {
      print('Required service not found');
      bleDisconnect();
      return false;
    }

    var characteristic = service.firstOrNull?.characteristics.where((element) => element.uuid == Guid.fromString(_characteristicUUIDTX) || element.uuid == Guid.fromString(_characteristicUUIDRX));
    if (characteristic == null || characteristic.isEmpty) {
      print('Required characteristics not found');
      bleDisconnect();
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
        bleRX!.onValueReceived.listen((data) {
          handleReceivedData(data);
        });
      } catch (e) {
        print('Error enabling RX notifications: $e');
      }
    }
  }

  void handleReceivedData(List<int> data) {
    // Example: Convert data to a string
    // String receivedString = utf8.decode(data);
    // print('Received data: $receivedString');
    switch (BleMsgId.values[data[0]]) {
      case BleMsgId.bleMsgAskForPenalty:
        print('Ask for penalty');
        _askForPenalty();
        break;
      default:
        print('Unknown message ID: ${data[0]}');
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
      print('Send HalfTime error');
      return false;
    }
  }

  Future<bool> bleSendGameOver() async {
    if (!_isConnected) return false;
    try {
      await bleTX?.write([BleMsgId.bleMsgGameOver.index, _game.getScore(_team_id), _game.getScore(_team_id, oppositeTeam: true)]);
      return true;
    } catch (e) {
      print('Send GameOver error');
      return false;
    }
  }


  Future<bool> bleSendName() async {
    if (!_isConnected) return false;
    try {
      await bleTX?.write([BleMsgId.bleMsgSetName.index] + _name.substring(0,2).codeUnits);
      return true;
    } catch (e) {
      print('Send name error');
      return false;
    }
  }

  Future<bool> bleSendScore() async {
    if (!_isConnected) return false;
    try {
      await Future.delayed(const Duration(milliseconds: 200));
      await bleTX?.write([BleMsgId.bleMsgSetScore.index, _game.getScore(_team_id), _game.getScore(_team_id, oppositeTeam: true)]);
      return true;
    } catch (e) {
      print('Send score error $e');
      return false;
    }
  }

  Future<bool> bleSendStop() async {
    if (!_isConnected) return false;
    try {
      await bleTX?.write([BleMsgId.bleMsgStop.index]);
      return true;
    } catch (e) {
      print('Send stop error $e');
      return false;
    }
  }

  Future<bool> bleSendStopAll() async {
    if (!_isConnected) return false;
    try {
      await bleTX?.write([BleMsgId.bleMsgStop.index], timeout:0);
      return true;
    } catch (e) {
      //print('Send stop all error $e');
      return false;
    }
  }

  Future<bool> bleSendPlayAll() async {
    if (!_isConnected) return false;
    try {
      await bleTX?.write([BleMsgId.bleMsgPlay.index], timeout:0);
      return true;
    } catch (e) {
      //print('Send play all error $e');
      return false;
    }
  }


  Future<bool> bleSendPlay() async {
    if (!_isConnected) return false;
    try {
      await bleTX?.write([BleMsgId.bleMsgPlay.index]);
      return true;
    } catch (e) {
      print('Send play error');
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
      print('Send play error');
      return false;
    }
  }

  void bleSendCurrentState() async {
    await bleSendName();
    await bleSendScore();
    bleNotify();
  }


  void bleDisconnect() async {
    if (bleDevice == null || !bleDevice!.isConnected) return;

    // Disconnect from device also disable auto connect
    await bleDevice?.disconnect();

    // cancel to prevent duplicate listeners
    subscription?.cancel();

    _isConnected = false;

    notifyListeners();



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
        print('Wrong last ModuleState');
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
      print('Penalty not allowed in current state: $_state');
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
      print('try disconect previos one');
      bleDevice?.disconnect();
    }
    
     bleDevice = device;

     if (bleDevice == null) return;

     macAddress = bleDevice!.remoteId.toString();
  }

  void _registerBleSubscriber(BluetoothDevice device) {
    subscription = device.connectionState.listen((BluetoothConnectionState state) async {
      print('BLE device status: $state');
      if (state == BluetoothConnectionState.disconnected) {
        _isConnected = false;
        // 1. typically, start a periodic timer that tries to
        //    reconnect, or just call connect() again right now
        // 2. you must always re-discover services after disconnection!
        bleStatus = 'Disconnected';
        notifyListeners();
        print("disconnect");
      } else if (state == BluetoothConnectionState.connected) {
        //bleCheckServicesAndGetCharacteristics();
        _isConnected = true;
        print("Connect");
        bleStatus = 'Connected';
        //bleSendTest();
        notifyListeners();
        //bleSendCurrentState();
        bleInitModule();
      }
    });
    //device.cancelWhenDisconnected(subscription, delayed:true, next:true);
  }






  String get currentPenalty => _penaltyTime > 0 ? _penaltyTime.toString() : '';


  bool get isEnabled => _isEnabled;
  bool get isConnected => _isConnected;
  bool get isPlaying => _isPlaying;
  String get name => _name;
  int get penaltyTime => _penaltyTime;
  ModuleState get state => _state;

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
//       print('BLE device status: $state');
//       if (state == BluetoothConnectionState.disconnected) {
//         // 1. typically, start a periodic timer that tries to
//         //    reconnect, or just call connect() again right now
//         // 2. you must always re-discover services after disconnection!
//         String bleStatus = 'Disconnected';
//         notifyListeners();
//         print("disconnect");
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
//       print('BLE connect error');
//     }
//
//
//   }
//
//
//
//
// }