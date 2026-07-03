import 'package:flutter_test/flutter_test.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Game> createGame(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'notif_permission_requested': true,
    });
    final game = Game();
    addTearDown(game.dispose);
    await tester.pump();
    game.periodTime = 180;
    game.halfTimeDuration = 60;
    return game;
  }

  int scoreFor(Game game, String teamId) {
    return game.teams.firstWhere((team) => team.id == teamId).score;
  }

  group('No-show penalty goals', () {
    testWidgets('awards one goal per elapsed 30 seconds to the selected team',
        (tester) async {
      final game = await createGame(tester);
      game.startNoShowPenaltyGoals(game.teams[0]);

      await tester.pump(const Duration(seconds: 29));
      expect(scoreFor(game, 'A'), 0);
      expect(scoreFor(game, 'B'), 0);

      await tester.pump(const Duration(seconds: 1));
      expect(scoreFor(game, 'A'), 1);
      expect(scoreFor(game, 'B'), 0);

      await tester.pump(const Duration(seconds: 30));
      expect(scoreFor(game, 'A'), 2);
      expect(scoreFor(game, 'B'), 0);

      game.stopNoShowPenaltyGoals();
    });

    testWidgets('keeps scoring by team id after team order switches',
        (tester) async {
      final game = await createGame(tester);
      game.startNoShowPenaltyGoals(game.teams[0]);
      game.toggleTeamOrder();

      await tester.pump(const Duration(seconds: 30));

      expect(game.teams.first.id, 'B');
      expect(scoreFor(game, 'A'), 1);
      expect(scoreFor(game, 'B'), 0);

      game.stopNoShowPenaltyGoals();
    });

    testWidgets('stopping no-show mode stops future automatic goals',
        (tester) async {
      final game = await createGame(tester);
      game.startNoShowPenaltyGoals(game.teams[0]);

      await tester.pump(const Duration(seconds: 30));
      expect(scoreFor(game, 'A'), 1);

      game.stopNoShowPenaltyGoals();
      expect(game.noShowPenaltyGoalsActive, isFalse);
      expect(game.isTimerRunning, isFalse);

      await tester.pump(const Duration(seconds: 120));
      expect(scoreFor(game, 'A'), 1);
    });

    testWidgets('caps automatic goals at a 10-goal difference', (tester) async {
      final game = await createGame(tester);
      game.periodTime = 600;
      game.startNoShowPenaltyGoals(game.teams[0]);

      await tester.pump(const Duration(seconds: 330));

      expect(scoreFor(game, 'A'), 10);
      expect(scoreFor(game, 'B'), 0);

      game.stopNoShowPenaltyGoals();
    });

    testWidgets('deactivates automatically at full time', (tester) async {
      final game = await createGame(tester);
      game.periodTime = 30;
      game.halfTimeDuration = 1;
      game.startNoShowPenaltyGoals(game.teams[0]);

      await tester.pump(const Duration(seconds: 31));
      expect(game.currentStage, MatchStage.secondHalf);
      expect(game.noShowPenaltyGoalsActive, isTrue);

      game.toggleTimer();
      await tester.pump(const Duration(seconds: 30));

      expect(game.currentStage, MatchStage.fullTime);
      expect(game.noShowPenaltyGoalsActive, isFalse);

      // Flush the #87 full-time transport teardown's 1 s delayed task —
      // any test that reaches fullTime must pump past it or the widget
      // binding fails with "A Timer is still pending".
      await tester.pump(const Duration(milliseconds: 1500));
    });
  });
}
