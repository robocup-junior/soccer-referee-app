// Smoke test: builds the full app under the test binding and asserts the Home
// screen renders. This exercises the Game constructor — which registers a
// WidgetsBindingObserver and stands up the notification/vibration/wakelock/
// MQTT/bridge services — so the app startup path stays covered by `flutter test`.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:rcj_scoreboard/main.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/screens/home.dart';

void main() {
  testWidgets('App builds and shows the Home screen', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    // The app is portrait-only; use a phone-shaped surface so the Home layout
    // lays out without spurious overflow on the default 800x600 test window.
    await tester.binding.setSurfaceSize(const Size(480, 1024));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final game = Game();
    await tester.pumpWidget(MyApp(game: game));
    await tester.pump();

    expect(find.byType(Home), findsOneWidget);
  });
}
