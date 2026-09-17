import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:rcj_scoreboard/models/bridge_message.dart';
import 'package:rcj_scoreboard/services/error_messages.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum BridgeConnectionState { disabled, disconnected, connecting, connected, error }

/// MQTT-over-BLE scoreboard bridge: a per-topic dedup queue drained with
/// write-with-response (the ACK). Fully separate from robot control and never
/// on its path. Like Module, the OS autoConnect owns reconnection while
/// [_connectIntent] holds; every await re-checks the intent so a Cancel
/// during setup can't be overwritten by a late continuation.
class BleBridgeService extends ChangeNotifier {
  BleBridgeService() {
    loadPreferences();
  }

  static final Guid _serviceGuid = Guid.fromString(kBridgeServiceUUID);
  static final Guid _txGuid = Guid.fromString(kBridgeTxCharUUID);

  final ValueNotifier<BridgeConnectionState> connectionStateNotifier =
      ValueNotifier(BridgeConnectionState.disconnected);
  final ValueNotifier<int> queueDepthNotifier = ValueNotifier(0);

  SharedPreferences? _prefs;
  bool _isEnabled = false;
  String _bridgeMacAddress = '';
  BluetoothDevice? _device;
  BluetoothCharacteristic? _txChar;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  final Queue<BridgeMessage> _queue = Queue<BridgeMessage>();
  bool _sendInProgress = false;
  bool _connectIntent = false;
  String? _lastErrorMessage;

  String? get lastErrorMessage => _lastErrorMessage;
  bool get isEnabled => _isEnabled;
  String get bridgeMacAddress => _bridgeMacAddress;
  bool get isConnected =>
      connectionStateNotifier.value == BridgeConnectionState.connected && _txChar != null;

  Future<void> loadPreferences() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    _isEnabled = prefs.getBool('bridge_enabled') ?? false;
    _bridgeMacAddress = prefs.getString('bridge_mac_address') ?? '';
    connectionStateNotifier.notifyListeners();
    notifyListeners();
  }

  set isEnabled(bool value) {
    _isEnabled = value;
    _prefs?.setBool('bridge_enabled', value);
    notifyListeners();
  }

  set bridgeMacAddress(String value) {
    _bridgeMacAddress = value;
    _prefs?.setString('bridge_mac_address', value);
    notifyListeners();
  }

  void _setState(BridgeConnectionState state) {
    connectionStateNotifier.value = state;
    notifyListeners();
  }

  Future<void> connect() async {
    if (_bridgeMacAddress.isEmpty ||
        connectionStateNotifier.value == BridgeConnectionState.connecting ||
        isConnected) {
      return;
    }
    _connectIntent = true;
    connectionStateNotifier.value = BridgeConnectionState.connecting;
    try {
      final device = _device = BluetoothDevice.fromId(_bridgeMacAddress.toUpperCase());
      await _connSub?.cancel();
      if (!_connectIntent) return;
      _connSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _txChar = null;
          _setState(_connectIntent
              ? BridgeConnectionState.connecting
              : BridgeConnectionState.disconnected);
        } else if (state == BluetoothConnectionState.connected) {
          _onConnected();
        }
      });
      await device.connect(autoConnect: true, mtu: null);
    } catch (e) {
      debugPrint('BleBridge: connect error: $e');
      if (_connectIntent) await _setErrorAndDisconnect(describeError(e).message);
    }
  }

  /// Explicit disconnect / Cancel. Settles the visible state BEFORE the slow
  /// plugin teardown.
  Future<void> disconnect() async {
    _connectIntent = false;
    _lastErrorMessage = null;
    _txChar = null;
    connectionStateNotifier.value = BridgeConnectionState.disconnected;
    await _connSub?.cancel();
    _connSub = null;
    await _safeDeviceDisconnect('disconnect');
  }

  /// Drain the queue (bounded), then disconnect; [shouldAbort] is re-checked
  /// throughout so a REPEAT that started a new match keeps the link.
  Future<void> disconnectAfterDrain({
    Duration timeout = const Duration(seconds: 3),
    bool Function()? shouldAbort,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while ((_queue.isNotEmpty || _sendInProgress) &&
        DateTime.now().isBefore(deadline) &&
        !(shouldAbort?.call() ?? false)) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      await Future<void>.delayed(
          remaining < const Duration(milliseconds: 100) ? remaining : const Duration(milliseconds: 100));
    }
    if (shouldAbort?.call() ?? false) return;
    await disconnect();
  }

  /// Queue (topic, value); a newer value for the same topic replaces the
  /// queued one.
  void publishTopic(String topic, String value) {
    if (!isEnabled) return;
    _queue.removeWhere((m) => m.topic == topic);
    _queue.add(BridgeMessage(topic, value));
    queueDepthNotifier.value = _queue.length;
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_sendInProgress || _queue.isEmpty || !isConnected) return;
    _sendInProgress = true;
    while (_queue.isNotEmpty && isConnected) {
      // Pop before awaiting so a concurrent publishTopic can't drop a message.
      final msg = _queue.removeFirst();
      queueDepthNotifier.value = _queue.length;
      await _sendWithRetry(msg);
    }
    _sendInProgress = false;
  }

  Future<bool> _sendWithRetry(BridgeMessage msg, {int maxRetries = 3}) async {
    final bytes = msg.toBytes();
    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        await _txChar!.write(bytes, withoutResponse: false, timeout: 5);
        return true;
      } catch (e) {
        if (attempt == maxRetries) debugPrint('BleBridge: send "${msg.topic}" failed: $e');
      }
    }
    return false;
  }

  Future<void> _onConnected() async {
    if (!_connectIntent) return;
    try {
      try {
        await _device?.requestMtu(247);
      } catch (e) {
        debugPrint('BleBridge: MTU request failed: $e');
      }
      if (!_connectIntent) return;
      final ready = await _discoverTxCharacteristic();
      if (!_connectIntent) {
        _txChar = null;
        return;
      }
      if (!ready) {
        await _setErrorAndDisconnect('Scoreboard service not found on this device');
        return;
      }
      _lastErrorMessage = null;
      _setState(BridgeConnectionState.connected);
      await _processQueue();
    } catch (e) {
      debugPrint('BleBridge: initialization error: $e');
      if (_connectIntent) await _setErrorAndDisconnect(describeError(e).message);
    }
  }

  Future<void> _setErrorAndDisconnect(String message) async {
    _lastErrorMessage = message;
    _connectIntent = false;
    await _connSub?.cancel();
    _connSub = null;
    await _safeDeviceDisconnect('error disconnect');
    _txChar = null;
    // A Cancel during the teardown already settled "Disconnected"; keep it.
    if (connectionStateNotifier.value == BridgeConnectionState.connecting) {
      _setState(BridgeConnectionState.error);
    }
  }

  Future<void> _safeDeviceDisconnect(String what) async {
    try {
      await _device?.disconnect();
    } catch (e) {
      debugPrint('BleBridge: $what failed: $e');
    }
  }

  Future<bool> _discoverTxCharacteristic() async {
    final device = _device;
    if (device == null) return false;
    final services = await device.discoverServices();
    final service = services.where((s) => s.uuid == _serviceGuid).firstOrNull;
    if (service == null || !service.characteristics.any((c) => c.uuid == _txGuid)) {
      debugPrint('BleBridge: bridge service/characteristic not found');
      return false;
    }
    _txChar = BluetoothCharacteristic(
        remoteId: device.remoteId, serviceUuid: _serviceGuid, characteristicUuid: _txGuid);
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
