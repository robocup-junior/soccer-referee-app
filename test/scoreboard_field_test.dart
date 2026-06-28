// Tests for #50: a referee-link match must apply its venue's field number to
// the MQTT topic, mirroring the catigoal path (Match.fromJson + loadMatchData).
//
// Uses testWidgets for the same reason as game_recovery_test: the Game
// constructor stands up wakelock/notification/MQTT/bridge services whose
// platform-channel calls reject asynchronously in the headless test VM, which
// the widget binding tolerates. No clock is started, so no Timers leak.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/models/scoreboard_result.dart';

Map<String, dynamic> _config({
  required String matchCode,
  required String venue,
}) =>
    {
      'match_code': matchCode,
      'home_team': 'Home',
      'away_team': 'Away',
      'home_is_left': true,
      'venue': venue,
      'scheduled_start': null,
      'duration_seconds': 600,
      'timezone': 'Europe/Prague',
      'version': 1,
      'status': 'SCHEDULED',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  });

  // Two pumps let the async _loadPrefs() (one getInstance await) finish.
  Future<void> settleLoad(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  void apply(Game game, {required String matchCode, required String venue}) {
    game.scoreboardResultService.debugApplyMatchConfig(
      ScoreboardMatchConfig.fromJson(_config(matchCode: matchCode, venue: venue)),
    );
  }

  testWidgets('numeric venue sets the MQTT field topic', (tester) async {
    final game = Game();
    await settleLoad(tester);

    apply(game, matchCode: 'M-1', venue: 'Field 3');
    await tester.pump();

    expect(game.mqttService.topic, 'field_3');
    game.dispose();
  });

  testWidgets('venue field number strips leading zeros', (tester) async {
    final game = Game();
    await settleLoad(tester);

    apply(game, matchCode: 'M-1', venue: 'Field 03');
    await tester.pump();

    expect(game.mqttService.topic, 'field_3');
    game.dispose();
  });

  testWidgets('venue without digits leaves the field topic unchanged',
      (tester) async {
    final game = Game();
    await settleLoad(tester);

    // First a numeric venue establishes a known field.
    apply(game, matchCode: 'M-1', venue: 'Field 5');
    await tester.pump();
    expect(game.mqttService.topic, 'field_5');

    // A different fixture (new match_code dodges the signature dedupe) whose
    // venue carries no number must not clobber the existing field.
    apply(game, matchCode: 'M-2', venue: 'Center Court');
    await tester.pump();

    expect(game.mqttService.topic, 'field_5');
    game.dispose();
  });
}
