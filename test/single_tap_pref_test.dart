// Tests for the single-tap gesture preference added for issue #12.
//
// Like game_remaining_time_test.dart these use testWidgets: the Game
// constructor stands up the wakelock/notification/MQTT/bridge services, whose
// platform-channel calls reject asynchronously in the headless test VM. The
// widget test binding tolerates those pending platform replies; a bare test()
// reports them as "pending async work" and fails after completion.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:rcj_scoreboard/models/game.dart';

const _key = 'gesture_single_tap_enabled';

void main() {
  group('Game.singleTapEnabled', () {
    testWidgets('defaults to false (double-tap preserved)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final game = Game();
      await tester.pump();
      expect(game.singleTapEnabled, isFalse);
    });

    testWidgets('adopts the stored value on load', (tester) async {
      SharedPreferences.setMockInitialValues({_key: true});
      final game = Game();
      await tester.pump();
      expect(game.singleTapEnabled, isTrue);
    });

    testWidgets('setting persists to SharedPreferences', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final game = Game();
      await tester.pump();
      game.singleTapEnabled = true;
      await tester.pump();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(_key), isTrue);
    });

    testWidgets('notifies listeners on change', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final game = Game();
      await tester.pump();
      var notified = false;
      game.addListener(() => notified = true);
      game.singleTapEnabled = true;
      expect(notified, isTrue);
    });

    testWidgets('no-op set does not notify', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final game = Game();
      await tester.pump();
      var notified = false;
      game.addListener(() => notified = true);
      game.singleTapEnabled = false; // already false
      expect(notified, isFalse);
    });

    testWidgets('a toggle made before _loadPrefs resolves is not lost',
        (tester) async {
      // Stored default is false; the user toggles ON before the unawaited
      // _loadPrefs() in the constructor completes. The pending-write guard must
      // flush the user's choice rather than let the stored default clobber it.
      SharedPreferences.setMockInitialValues({_key: false});
      final game = Game();
      game.singleTapEnabled = true; // synchronous, before any pump => prefs null
      await tester.pump(); // _loadPrefs resolves here
      expect(game.singleTapEnabled, isTrue, reason: 'pre-load toggle preserved');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(_key), isTrue, reason: 'pending write flushed');
    });
  });
}
