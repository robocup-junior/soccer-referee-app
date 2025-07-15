import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:rcj_scoreboard/screens/home.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:flutter/services.dart';

void main() {

  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations(
  [DeviceOrientation.portraitUp]);

  // // A team
  // Module moduleA1 = Module('A1');
  // Module moduleA2 = Module('A2');
  // Module moduleA3 = Module('A3');
  // Module moduleA4 = Module('A4');
  // Module moduleA5 = Module('A5');
  // Team teamA = Team('Team A', [moduleA1, moduleA2, moduleA3, moduleA4 ,moduleA5]);
  //
  // // B team
  // Module moduleB1 = Module('B1');
  // Module moduleB2 = Module('B2');
  // Module moduleB3 = Module('B3');
  // Module moduleB4 = Module('B4');
  // Module moduleB5 = Module('B5');
  // Team teamB = Team('Team B', [moduleB1, moduleB2, moduleB3, moduleB4 ,moduleB5]);
  //
  // // moduleA1.isEnabled = true;
  // // moduleA2.isEnabled = true;
  // // moduleB1.isEnabled = true;
  // // moduleB2.isEnabled = true;

  Game game = Game();

  runApp(MyApp(game : game));
}

class MyApp extends StatelessWidget {
  final Game game;

  MyApp({required this.game});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: game),
        ...game.teams.map((team) => ChangeNotifierProvider.value(value: team)),
        ...game.teams[0].modules.map((module) => ChangeNotifierProvider.value(value: module)),
        ...game.teams[1].modules.map((module) => ChangeNotifierProvider.value(value: module)),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'RCJ Soccer - Score Board',
        theme: ThemeData(
          brightness: Brightness.dark,
          primarySwatch: Colors.blue,
          textTheme: TextTheme(
            //bodySmall: TextStyle(color: Colors.white),
            bodyMedium: TextStyle(color: Colors.white),
            //bodyLarge: TextStyle(color: Colors.white),
          ),
        ),
        home: Home(),
      ),
    );
  }
}