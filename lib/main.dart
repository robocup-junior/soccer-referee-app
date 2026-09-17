import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/screens/home.dart';
import 'package:rcj_scoreboard/services/notification_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Permission is requested later (first launch / settings), never here.
  unawaited(NotificationService.initialize());
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(MyApp(game: Game()));
}

class MyApp extends StatelessWidget {
  const MyApp({required this.game, super.key});
  final Game game;

  @override
  Widget build(BuildContext context) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: game),
          ChangeNotifierProvider.value(value: game.bleBridgeService),
          ChangeNotifierProvider.value(value: game.bleAdapterMonitor),
          for (final team in game.teams) ChangeNotifierProvider.value(value: team),
          for (final module in game.modules) ChangeNotifierProvider.value(value: module),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'RCJ Soccer - Score Board',
          theme: ThemeData(
            brightness: Brightness.dark,
            primarySwatch: Colors.blue,
            textTheme: const TextTheme(bodyMedium: TextStyle(color: Colors.white)),
          ),
          home: const Home(),
        ),
      );
}
