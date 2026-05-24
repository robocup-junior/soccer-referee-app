import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rcj_scoreboard/main.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/screens/home.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('App starts without crashing', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});

    final game = Game();
    await tester.pumpWidget(MyApp(game: game));

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(Home), findsOneWidget);
  });
}
