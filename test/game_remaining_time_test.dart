// Tests for the manual remaining-time correction added for issue #21.
//
// parseMmSs is a top-level pure function, so it uses plain test(). The
// setRemainingTime cases use testWidgets (like the app smoke test): the Game
// constructor stands up the wakelock/notification/MQTT/bridge services, whose
// platform-channel calls reject asynchronously in the headless test VM. The
// widget test binding tolerates those pending platform replies; a bare test()
// reports them as "pending async work" and fails after completion.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/screens/home.dart';

void main() {
  group('parseMmSs', () {
    test('parses mm:ss', () {
      expect(parseMmSs('02:03'), 123);
      expect(parseMmSs('10:00'), 600);
      expect(parseMmSs('0:30'), 30);
    });

    test('parses a plain seconds integer', () {
      expect(parseMmSs('123'), 123);
      expect(parseMmSs('0'), 0);
    });

    test('trims surrounding whitespace', () {
      expect(parseMmSs('  1:05 '), 65);
    });

    test('rejects a seconds component outside 0..59', () {
      expect(parseMmSs('5:99'), isNull);
      expect(parseMmSs('5:60'), isNull);
    });

    test('rejects negative components', () {
      expect(parseMmSs('-1:00'), isNull);
      expect(parseMmSs('1:-30'), isNull);
      expect(parseMmSs('-30'), isNull);
    });

    test('rejects malformed input', () {
      expect(parseMmSs(''), isNull);
      expect(parseMmSs('   '), isNull);
      expect(parseMmSs('1:2:3'), isNull);
      expect(parseMmSs(':30'), isNull);
      expect(parseMmSs('1:'), isNull);
      expect(parseMmSs('ab:cd'), isNull);
      expect(parseMmSs('abc'), isNull);
    });
  });

  group('Game.setRemainingTime', () {
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

    testWidgets('floors at 1 second (never parks an active half at 0:00)',
        (tester) async {
      final game = makeGame();
      await tester.pump();
      game.setRemainingTime(0);
      expect(game.remainingTime, 1);
      game.setRemainingTime(-10);
      expect(game.remainingTime, 1);
    });

    testWidgets('clamps above periodTime to periodTime', (tester) async {
      final game = makeGame();
      await tester.pump();
      game.currentStage = MatchStage.firstHalf;
      game.setRemainingTime(9999);
      expect(game.remainingTime, 600);
    });

    testWidgets('notifies listeners', (tester) async {
      final game = makeGame();
      await tester.pump();
      var notified = false;
      game.addListener(() => notified = true);
      game.setRemainingTime(42);
      expect(notified, isTrue);
    });
  });
}
