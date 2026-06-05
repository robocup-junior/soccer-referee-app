import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:rcj_scoreboard/screens/home.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/services/notification_service.dart';
import 'package:flutter/services.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.initialize();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  Game game = Game();

  runApp(MyApp(game: game));
}

class MyApp extends StatelessWidget {
  final Game game;

  const MyApp({required this.game, super.key});

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
          textTheme: const TextTheme(
            //bodySmall: TextStyle(color: Colors.white),
            bodyMedium: TextStyle(color: Colors.white),
            //bodyLarge: TextStyle(color: Colors.white),
          ),
        ),
        home: const Home(),
      ),
    );
  }
}