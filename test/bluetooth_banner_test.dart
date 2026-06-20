// test/bluetooth_banner_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:rcj_scoreboard/screens/widgets/bluetooth_banner.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('shows a descriptive banner when Bluetooth is off',
      (tester) async {
    await tester.pumpWidget(
        wrap(const BluetoothBanner(state: BluetoothAdapterState.off)));
    expect(find.text('Bluetooth is off'), findsOneWidget);
    expect(find.text('Turn it on to connect robots'), findsOneWidget);
  });

  testWidgets('renders nothing when Bluetooth is on', (tester) async {
    await tester.pumpWidget(
        wrap(const BluetoothBanner(state: BluetoothAdapterState.on)));
    expect(find.text('Bluetooth is off'), findsNothing);
    expect(find.byType(MaterialBanner), findsNothing);
  });

  testWidgets('renders nothing for unknown/turningOn (no cold-start flash)',
      (tester) async {
    for (final s in [
      BluetoothAdapterState.unknown,
      BluetoothAdapterState.turningOn,
    ]) {
      await tester.pumpWidget(wrap(BluetoothBanner(state: s)));
      expect(find.byType(MaterialBanner), findsNothing);
    }
  });
}
