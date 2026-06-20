// Unit tests for Game.setRemainingTime — the manual remaining-time correction
// added for issue #21. Editing is gated to a stopped clock in the UI, so these
// tests cover the model's clamping contract per match stage.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:rcj_scoreboard/models/game.dart';

void main() {
  // Game() registers a WidgetsBindingObserver and reads SharedPreferences.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Game makeGame() {
    final game = Game();
    game.periodTime = 600;
    game.halfTimeDuration = 300;
    return game;
  }

  test('sets an in-range value exactly', () {
    final game = makeGame();
    game.setRemainingTime(123);
    expect(game.remainingTime, 123);
  });

  test('clamps negative values to 0', () {
    final game = makeGame();
    game.setRemainingTime(-10);
    expect(game.remainingTime, 0);
  });

  test('clamps above periodTime to periodTime during a half', () {
    final game = makeGame();
    game.currentStage = MatchStage.firstHalf;
    game.setRemainingTime(9999);
    expect(game.remainingTime, 600);
  });

  test('clamps to halfTimeDuration during the half-time break', () {
    final game = makeGame();
    game.currentStage = MatchStage.halfTime;
    game.setRemainingTime(9999);
    expect(game.remainingTime, 300);
  });

  test('notifies listeners', () {
    final game = makeGame();
    var notified = false;
    game.addListener(() => notified = true);
    game.setRemainingTime(42);
    expect(notified, isTrue);
  });
}
