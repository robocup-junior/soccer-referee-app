import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:rcj_scoreboard/services/ble_adapter_monitor.dart';

void main() {
  test('tracks the latest adapter state and notifies', () async {
    final controller = StreamController<BluetoothAdapterState>();
    final monitor = BleAdapterMonitor(stream: controller.stream);
    var notifications = 0;
    monitor.addListener(() => notifications++);

    controller.add(BluetoothAdapterState.off);
    await Future.delayed(Duration.zero);
    expect(monitor.state, BluetoothAdapterState.off);
    expect(monitor.isOn, isFalse);

    controller.add(BluetoothAdapterState.on);
    await Future.delayed(Duration.zero);
    expect(monitor.isOn, isTrue);
    expect(notifications, 2);

    await controller.close();
    monitor.dispose();
  });
}
