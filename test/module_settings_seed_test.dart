// #82: the module-settings address field seeds from the connection id, and —
// when a slot has no connection id yet (iOS "Not found": module was off at
// load and arrived mid-match) — falls back to the known hardware MAC, so the
// referee can connect it with one Connect tap (the iOS MAC branch resolves by
// scan) instead of facing an empty field.
//
// testWidgets + a real Game for the same platform-channel reasons as
// game_recovery_test; modules stay disabled so nothing touches real BLE.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/models/module.dart';
import 'package:rcj_scoreboard/screens/module_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({'mqtt_enabled': false});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  });

  Future<Module> pumpedModule(WidgetTester tester, Game game) async {
    await tester.pump();
    await tester.pump();
    game.numberOfPlayers = 0;
    final module = game.teams.first.modules.first;
    return module;
  }

  Future<void> pumpScreen(WidgetTester tester, Module module) async {
    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider<Module>.value(
        value: module,
        child: const ModuleSettingsScreen(),
      ),
    ));
    await tester.pump();
  }

  testWidgets(
      'address field falls back to the hardware MAC when the slot has no '
      'connection id (mid-match late-arrival flow)', (tester) async {
    final game = Game();
    final module = await pumpedModule(tester, game);
    module.hardwareMac = 'A1:B2:C3:D4:E5:F6';

    await pumpScreen(tester, module);

    expect(find.text('A1:B2:C3:D4:E5:F6'), findsOneWidget);

    game.dispose();
  });

  testWidgets('address field prefers the connection id when present',
      (tester) async {
    final game = Game();
    final module = await pumpedModule(tester, game);
    module.macAddress = '12345678-1234-1234-1234-1234567890AB';
    module.hardwareMac = 'A1:B2:C3:D4:E5:F6';

    await pumpScreen(tester, module);

    expect(find.text('12345678-1234-1234-1234-1234567890AB'), findsOneWidget);
    expect(find.text('A1:B2:C3:D4:E5:F6'), findsNothing);

    game.dispose();
  });
}
