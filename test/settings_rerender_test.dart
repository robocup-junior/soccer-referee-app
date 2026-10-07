// Regression tests for the stateless Settings screen (PR #101 review): every
// control must redraw after the user changes it, and a rebuild while typing
// must not reset a masked address field.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/services/mqtt.dart';
import 'package:rcj_scoreboard/utils/ble_address.dart';
import 'package:rcj_scoreboard/widgets/settings_widgets.dart';

void main() {
  testWidgets(
      'a masked field keeps its text when the parent rebuilds on every '
      'keystroke with a fresh formatter', (tester) async {
    var stored = '';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SettingInputField(
            title: 'Bridge MAC',
            initialValue: stored,
            // A new formatter per build, exactly as SettingsScreen passes it.
            inputFormatters: [buildBleAddressMask()],
            onChanged: (v) => setState(() => stored = v),
          ),
        ),
      ),
    ));

    final field = find.byType(TextField);
    for (final ch in 'AABBCCDDEEFF'.split('')) {
      final current = tester.widget<TextField>(field).controller!.text;
      await tester.enterText(field, current + ch);
      await tester.pump();
    }

    expect(tester.widget<TextField>(field).controller!.text,
        'AA:BB:CC:DD:EE:FF');
    expect(stored, 'AA:BB:CC:DD:EE:FF');
  });

  testWidgets('Game timing setters notify so their dropdowns redraw',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final game = Game();
    await tester.pump();
    var notifications = 0;
    game.addListener(() => notifications++);

    game.periodTime = 300; // not at full time: used to be silent
    game.halfTimeDuration = 120;
    game.numberOfPlayers = 2;
    game.penaltyTime = 60;

    expect(notifications, 4);
  });

  testWidgets('MQTT switch setters bump switchesChanged', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final mqtt = MqttService();
    await tester.pump();
    var bumps = 0;
    mqtt.switchesChanged.addListener(() => bumps++);

    mqtt.isEnabled = !mqtt.isEnabled;
    mqtt.secureConnection = !mqtt.secureConnection;

    expect(bumps, 2);
  });
}
