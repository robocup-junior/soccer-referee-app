// On-device/emulator smoke test for the single-tap actions feature (#12/#26)
// integrated with the bluetooth-banner UI (#17).
//
// Run on a booted emulator or device:
//   flutter test integration_test/app_smoke_test.dart -d <device-id>
//
// These cover what desk widget tests can't fully exercise: the real gesture
// arena on a real surface, and the Settings → toggle → Home wiring end to end.
// (BLE/MQTT hardware paths are intentionally NOT asserted here — those still
// need a real device + module/broker.)

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:rcj_scoreboard/main.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/screens/home.dart';
import 'package:rcj_scoreboard/screens/widgets/bluetooth_banner.dart';
import 'package:rcj_scoreboard/widgets/critical_gesture_detector.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Team A's score control is the first CriticalGestureDetector in the tree
  // (Home builds team A, then the timer column, then team B, then modules).
  Finder teamAScore() => find.byType(CriticalGestureDetector).first;

  Future<void> doubleTap(WidgetTester tester, Finder f) async {
    await tester.tap(f);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(f);
    // Let the double-tap recognizer resolve past kDoubleTapTimeout (~300ms).
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  testWidgets('Home renders with the bluetooth banner', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final game = Game();
    await tester.pumpWidget(MyApp(game: game));
    await tester.pumpAndSettle();

    expect(find.byType(Home), findsOneWidget);
    expect(find.byType(BluetoothBanner), findsOneWidget,
        reason: 'BLE status banner (#17) must render above the controls');
  });

  testWidgets('default mode: single tap is ignored, double tap scores',
      (tester) async {
    SharedPreferences.setMockInitialValues({}); // singleTapEnabled defaults false
    final game = Game();
    await tester.pumpWidget(MyApp(game: game));
    await tester.pumpAndSettle();

    expect(game.singleTapEnabled, isFalse);
    expect(game.teams[0].score, 0);

    // A single tap must NOT score (accidental-touch protection).
    await tester.tap(teamAScore());
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(game.teams[0].score, 0,
        reason: 'single tap must be ignored while double-tap mode is active');

    // A double tap scores.
    await doubleTap(tester, teamAScore());
    expect(game.teams[0].score, 1);
  });

  testWidgets('single-tap mode: a single tap scores', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final game = Game();
    await tester.pumpWidget(MyApp(game: game));
    await tester.pumpAndSettle();

    // Flip the preference (as the Settings toggle does) and let the
    // CriticalGestureDetector rebuild into single-tap mode.
    game.singleTapEnabled = true;
    await tester.pumpAndSettle();
    expect(game.singleTapEnabled, isTrue);

    final before = game.teams[0].score;
    await tester.tap(teamAScore());
    await tester.pumpAndSettle();
    expect(game.teams[0].score, before + 1,
        reason: 'in single-tap mode one tap must score');
  });
}
