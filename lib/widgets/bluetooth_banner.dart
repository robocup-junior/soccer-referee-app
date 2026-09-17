import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:rcj_scoreboard/services/error_messages.dart';

/// Persistent banner on Home while the BLE adapter is not usable; an empty box
/// otherwise, so it can sit unconditionally in the tree. "Turn on" is offered
/// only when the radio is merely off (not unauthorized/unavailable) and the
/// caller can actually turn it on (Android).
class BluetoothBanner extends StatelessWidget {
  const BluetoothBanner({required this.state, this.onTurnOn, super.key});

  final BluetoothAdapterState state;
  final VoidCallback? onTurnOn;

  @override
  Widget build(BuildContext context) {
    if (!isAdapterProblem(state)) return const SizedBox.shrink();
    final info = describeAdapterState(state);
    final canTurnOn = onTurnOn != null &&
        (state == BluetoothAdapterState.off || state == BluetoothAdapterState.turningOff);
    return MaterialBanner(
      backgroundColor: Colors.red.shade900,
      leading: const Icon(Icons.bluetooth_disabled, color: Colors.white),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(info.message,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          if (info.hint != null) Text(info.hint!, style: const TextStyle(color: Colors.white70)),
        ],
      ),
      // MaterialBanner requires a non-empty actions list.
      actions: [
        if (canTurnOn)
          TextButton(
            onPressed: onTurnOn,
            child: const Text('Turn on', style: TextStyle(color: Colors.white)),
          )
        else
          const SizedBox.shrink(),
      ],
    );
  }
}
