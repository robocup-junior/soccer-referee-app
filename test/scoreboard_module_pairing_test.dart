// Tests for #70: a referee-link match auto-pairs each side's comm modules from
// the server-provided MACs (home_module_macs / away_module_macs), mapping them
// onto the fixed per-side module slots by team ID so a swapped side never
// crosses the sides.
//
// Uses testWidgets for the same reason as scoreboard_field_test/game_recovery_
// test: the Game constructor stands up wakelock/notification/MQTT/bridge
// services whose platform-channel calls reject asynchronously in the headless
// test VM, which the widget binding tolerates. applyPresetConfig sets each
// slot's macAddress synchronously (before the BLE connect), so the assertions
// hold; a trailing pump drains the 100 ms connect fan-out so no Timer leaks.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/models/scoreboard_result.dart';
import 'package:rcj_scoreboard/models/team.dart';

Map<String, dynamic> _config({
  String matchCode = 'M-1',
  bool homeIsLeft = true,
  List<String> homeMacs = const [],
  List<String> awayMacs = const [],
}) =>
    {
      'match_code': matchCode,
      'home_team': 'Home',
      'away_team': 'Away',
      'home_is_left': homeIsLeft,
      'venue': '1',
      'scheduled_start': null,
      'duration_seconds': 600,
      'timezone': 'Europe/Prague',
      'version': 1,
      'status': 'SCHEDULED',
      'home_module_macs': homeMacs,
      'away_module_macs': awayMacs,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  });

  Future<void> settleLoad(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  Team teamById(Game game, String id) =>
      game.teams.firstWhere((t) => t.id == id);

  void apply(Game game, Map<String, dynamic> config) {
    game.scoreboardResultService.debugApplyMatchConfig(
      ScoreboardMatchConfig.fromJson(config),
    );
  }

  testWidgets('pairs home MACs onto team A and away MACs onto team B',
      (tester) async {
    final game = Game();
    await settleLoad(tester);

    apply(
      game,
      _config(
        homeIsLeft: true,
        homeMacs: ['A1:B2:C3:D4:E5:F6', '11:22:33:44:55:66'],
        awayMacs: ['AA:BB:CC:DD:EE:FF'],
      ),
    );
    await tester.pump();

    expect(teamById(game, 'A').modules[0].macAddress, 'A1:B2:C3:D4:E5:F6');
    expect(teamById(game, 'A').modules[1].macAddress, '11:22:33:44:55:66');
    expect(teamById(game, 'B').modules[0].macAddress, 'AA:BB:CC:DD:EE:FF');

    await tester.pump(const Duration(milliseconds: 400)); // drain connect fan-out
    game.dispose();
  });

  testWidgets('a right-side home maps home MACs onto team B (keyed by ID)',
      (tester) async {
    final game = Game();
    await settleLoad(tester);

    apply(
      game,
      _config(
        homeIsLeft: false,
        homeMacs: ['A1:B2:C3:D4:E5:F6'],
        awayMacs: ['AA:BB:CC:DD:EE:FF'],
      ),
    );
    await tester.pump();

    // home_is_left:false binds home -> team B, away -> team A.
    expect(teamById(game, 'B').modules[0].macAddress, 'A1:B2:C3:D4:E5:F6');
    expect(teamById(game, 'A').modules[0].macAddress, 'AA:BB:CC:DD:EE:FF');

    await tester.pump(const Duration(milliseconds: 400));
    game.dispose();
  });

  testWidgets('lower-case MACs are normalised to upper-case', (tester) async {
    final game = Game();
    await settleLoad(tester);

    apply(game, _config(homeMacs: ['a1:b2:c3:d4:e5:f6']));
    await tester.pump();

    expect(teamById(game, 'A').modules[0].macAddress, 'A1:B2:C3:D4:E5:F6');

    await tester.pump(const Duration(milliseconds: 400));
    game.dispose();
  });

  testWidgets('a partial MAC list only fills the slots it provides',
      (tester) async {
    final game = Game();
    await settleLoad(tester);

    apply(game, _config(homeMacs: ['A1:B2:C3:D4:E5:F6']));
    await tester.pump();

    // Only slot 0 was named; the rest stay unpaired.
    expect(teamById(game, 'A').modules[0].macAddress, 'A1:B2:C3:D4:E5:F6');
    expect(teamById(game, 'A').modules[1].macAddress, '');

    await tester.pump(const Duration(milliseconds: 400));
    game.dispose();
  });

  testWidgets('no module keys leaves every slot unpaired', (tester) async {
    final game = Game();
    await settleLoad(tester);

    apply(game, _config());
    await tester.pump();

    for (final module in teamById(game, 'A').modules) {
      expect(module.macAddress, '');
    }

    game.dispose();
  });
}
