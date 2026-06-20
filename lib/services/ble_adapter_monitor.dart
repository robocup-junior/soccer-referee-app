import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Watches the BLE adapter state for the whole app lifetime so the UI can show
/// a persistent "Bluetooth is off" banner. The [stream] seam keeps it testable
/// without the platform channel.
class BleAdapterMonitor extends ChangeNotifier {
  BluetoothAdapterState _state = BluetoothAdapterState.unknown;
  StreamSubscription<BluetoothAdapterState>? _sub;

  BleAdapterMonitor({Stream<BluetoothAdapterState>? stream}) {
    _sub = (stream ?? FlutterBluePlus.adapterState).listen((s) {
      _state = s;
      notifyListeners();
    });
  }

  BluetoothAdapterState get state => _state;
  bool get isOn => _state == BluetoothAdapterState.on;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
