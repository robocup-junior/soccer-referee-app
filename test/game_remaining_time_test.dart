// Unit tests for Game.setRemainingTime — the manual remaining-time correction
// added for issue #21. Editing is gated to a stopped clock in the UI, so these
// tests cover the model's clamping contract per match stage.
//
// These use testWidgets (like the app smoke test) rather than a plain test():
// the Game constructor stands up the wakelock/notification/MQTT/bridge services,
// whose platform-channel calls reject asynchronously in the headless test VM.
// The widget test binding tolerates those pending platform replies; a bare
// test() reports them as "pending async work" and fails after completion.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:rcj_scoreboard/models/game.dart';

void main() {
  Game makeGame() {
    final game = Game();
    game.periodTime = 600;
    game.halfTimeDuration = 300;
    return game;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('sets an in-range value exactly', (tester) async {
    final game = makeGame();
    await tester.pump();
    game.setRemainingTime(123);
    expect(game.remainingTime, 123);
  });

  testWidgets('clamps negative values to 0', (tester) async {
    final game = makeGame();
    await tester.pump();
    game.setRemainingTime(-10);
    expect(game.remainingTime, 0);
  });

  testWidgets('clamps above periodTime to periodTime during a half',
      (tester) async {
    final game = makeGame();
    await tester.pump();
    game.currentStage = MatchStage.firstHalf;
    game.setRemainingTime(9999);
    expect(game.remainingTime, 600);
  });

  testWidgets('clamps to halfTimeDuration during the half-time break',
      (tester) async {
    final game = makeGame();
    await tester.pump();
    game.currentStage = MatchStage.halfTime;
    game.setRemainingTime(9999);
    expect(game.remainingTime, 300);
  });

  testWidgets('notifies listeners', (tester) async {
    final game = makeGame();
    await tester.pump();
    var notified = false;
    game.addListener(() => notified = true);
    game.setRemainingTime(42);
    expect(notified, isTrue);
  });
}
