// lib/screens/widgets/bluetooth_banner.dart
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:rcj_scoreboard/services/error_messages.dart';

/// A persistent MaterialBanner shown on Home when the BLE adapter is not on.
/// Renders an empty box when Bluetooth is on, so it can sit unconditionally in
/// the widget tree.
class BluetoothBanner extends StatelessWidget {
  const BluetoothBanner({required this.state, this.onTurnOn, super.key});

  final BluetoothAdapterState state;

  /// Called when the user taps "Turn on". Only shown for the off/turningOff
  /// states, where turning the adapter on is the action that actually helps.
  final VoidCallback? onTurnOn;

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
    // Turning the adapter on only helps when it is simply off. For
    // `unauthorized` (needs a permission grant) or `unavailable` (no BLE
    // hardware) turnOn() does nothing, so we show no action button and let the
    // hint guide the user rather than offer a button that does nothing.
    // The caller also withholds [onTurnOn] where turning the radio on can't
    // work (iOS, where FlutterBluePlus.turnOn() throws and the OS forbids it),
    // so a null callback likewise suppresses the button.
    final canTurnOn = onTurnOn != null &&
        (state == BluetoothAdapterState.off ||
            state == BluetoothAdapterState.turningOff);
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
      // MaterialBanner requires a non-empty actions list, so the
      // no-action states get a zero-size placeholder.
      actions: [
        if (canTurnOn)
          TextButton(
            onPressed: onTurnOn,
            child:
                const Text('Turn on', style: TextStyle(color: Colors.white)),
          )
        else
          const SizedBox.shrink(),
      ],
    );
  }
}
