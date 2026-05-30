import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:rcj_scoreboard/models/bridge_message.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum BridgeConnectionState {
  disabled,
  disconnected,
  connecting,
  connected,
  error,
}

class BleBridgeService extends ChangeNotifier {
  bool _isEnabled = false;
  String _bridgeMacAddress = '';
  late SharedPreferences prefs;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _txChar;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  final ValueNotifier<BridgeConnectionState> connectionStateNotifier =
      ValueNotifier(BridgeConnectionState.disconnected);
  final ValueNotifier<int> queueDepthNotifier = ValueNotifier(0);

  BleBridgeService() {
    loadPreferences();
  }

  Future<void> loadPreferences() async {
    prefs = await SharedPreferences.getInstance();
    _isEnabled = prefs.getBool('bridge_enabled') ?? false;
    _bridgeMacAddress = prefs.getString('bridge_mac_address') ?? '';
    connectionStateNotifier.notifyListeners();
    notifyListeners();
  }

  bool get isEnabled => _isEnabled;
  String get bridgeMacAddress => _bridgeMacAddress;
  bool get isConnected =>
      connectionStateNotifier.value == BridgeConnectionState.connected &&
      _txChar != null;

  set isEnabled(bool value) {
    _isEnabled = value;
    prefs.setBool('bridge_enabled', value);
    notifyListeners();
  }

  set bridgeMacAddress(String value) {
    _bridgeMacAddress = value;
    prefs.setString('bridge_mac_address', value);
    notifyListeners();
  }

  Future<void> connect() async {
    if (_bridgeMacAddress.isEmpty ||
        connectionStateNotifier.value == BridgeConnectionState.connecting ||
        isConnected) {
      return;
    }

    connectionStateNotifier.value = BridgeConnectionState.connecting;

    try {
      _device = BluetoothDevice.fromId(_bridgeMacAddress.toUpperCase());
      await _connSub?.cancel();
      _registerBleSubscriber(_device!);
      await _device!.connect(autoConnect: true, mtu: null);
    } catch (e) {
      debugPrint('BleBridge: connect error: $e');
      await _setErrorAndDisconnect();
    }
  }

  Future<void> disconnect() async {
    await _connSub?.cancel();
    _connSub = null;

    try {
      await _device?.disconnect();
    } catch (e) {
      debugPrint('BleBridge: disconnect error: $e');
    }

    _txChar = null;
    connectionStateNotifier.value = BridgeConnectionState.disconnected;
  }

  void publishTopic(String topic, String value) {}

  Future<void> _processQueue() async {}

  void _registerBleSubscriber(BluetoothDevice device) {
    _connSub =
        device.connectionState.listen((BluetoothConnectionState state) async {
      debugPrint('BleBridge status: $state');

      if (state == BluetoothConnectionState.disconnected) {
        _txChar = null;
        connectionStateNotifier.value = BridgeConnectionState.disconnected;
        notifyListeners();
      } else if (state == BluetoothConnectionState.connected) {
        await _onConnected();
      }
    });
  }

  Future<void> _onConnected() async {
    try {
      try {
        await _device?.requestMtu(247);
      } catch (e) {
        debugPrint('BleBridge: MTU request failed: $e');
      }

      final ready = await _discoverBridgeCharacteristic();
      if (!ready) {
        await _setErrorAndDisconnect();
        return;
      }

      connectionStateNotifier.value = BridgeConnectionState.connected;
      notifyListeners();
      await _processQueue();
    } catch (e) {
      debugPrint('BleBridge: initialization error: $e');
      await _setErrorAndDisconnect();
    }
  }

  Future<void> _setErrorAndDisconnect() async {
    await _connSub?.cancel();
    _connSub = null;

    try {
      await _device?.disconnect();
    } catch (e) {
      debugPrint('BleBridge: error disconnect failed: $e');
    }

    _txChar = null;
    connectionStateNotifier.value = BridgeConnectionState.error;
    notifyListeners();
  }

  Future<bool> _discoverBridgeCharacteristic() async {
    if (_device == null) return false;

    final services = await _device!.discoverServices();
    final service = services.where(
      (element) => element.uuid == Guid.fromString(kBridgeServiceUUID),
    );
    if (service.isEmpty) {
      debugPrint('BleBridge: required service not found');
      return false;
    }

    final characteristic = service.first.characteristics.where(
      (element) => element.uuid == Guid.fromString(kBridgeTxCharUUID),
    );
    if (characteristic.isEmpty) {
      debugPrint('BleBridge: TX characteristic not found');
      return false;
    }

    _txChar = BluetoothCharacteristic(
      remoteId: _device!.remoteId,
      serviceUuid: Guid.fromString(kBridgeServiceUUID),
      characteristicUuid: Guid.fromString(kBridgeTxCharUUID),
    );
    return true;
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _device?.disconnect();
    connectionStateNotifier.dispose();
    queueDepthNotifier.dispose();
    super.dispose();
  }
}
