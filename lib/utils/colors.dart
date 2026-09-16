import 'package:flutter/material.dart';

class AppColors {
  static const Color primary = Color(0xFF0D47A1);
  static const Color red = Color(0xFFF44336);
  static const Color green = Color(0xFF4CAF50);
  static const Color blue = Color(0xFF2196F3);
  static const Color background = Colors.black;
  static const Color sheet = Color(0xFF424242); // Colors.grey[800]
  static const Color button = Color(0xFF616161); // Colors.grey[700]

  /// Team marker colours: neon green for 'A' (left), neon magenta for 'B'.
  static const Color teamA = Color(0xFF77FF00);
  static const Color teamB = Color(0xFFFF00FF);

  static Color team(String teamId) => teamId == 'A' ? teamA : teamB;

  /// `RRGGBB` form of [team], as published to the scoreboard bridge.
  static String teamHex(String teamId) =>
      (team(teamId).toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();
}
