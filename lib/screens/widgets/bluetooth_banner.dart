// lib/screens/widgets/bluetooth_banner.dart
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:rcj_scoreboard/services/error_messages.dart';

/// A persistent MaterialBanner shown on Home when the BLE adapter is not on.
/// Renders an empty box when Bluetooth is on, so it can sit unconditionally in
/// the widget tree.
class BluetoothBanner extends StatelessWidget {
  const BluetoothBanner({required this.state, this.onOpenSettings, super.key});

  final BluetoothAdapterState state;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    const problemStates = {
      BluetoothAdapterState.off,
      BluetoothAdapterState.turningOff,
      BluetoothAdapterState.unauthorized,
      BluetoothAdapterState.unavailable,
    };
    if (!problemStates.contains(state)) {
      return const SizedBox.shrink();
    }
    final info = describeAdapterState(state);
    return MaterialBanner(
      backgroundColor: Colors.red.shade900,
      leading: const Icon(Icons.bluetooth_disabled, color: Colors.white),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(info.message,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold)),
          if (info.hint != null)
            Text(info.hint!, style: const TextStyle(color: Colors.white70)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: onOpenSettings,
          child: const Text('Open settings',
              style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}
