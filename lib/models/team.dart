import 'package:flutter/foundation.dart';
import 'package:rcj_scoreboard/models/module.dart';

class Team with ChangeNotifier {
  String _name;
  final String id;
  final List<Module> modules;
  int score = 0;

  Team(this._name, this.modules, this.id);

  void addScore(int value) {
    if (value < 0 && score <= 0) return;
    score += value;
    notifyListeners();
  }

  // Getter for the team name
  String get name => _name;

  // Setter for the team name
  set name(String value) {
    if (value.isEmpty) {
      _name = 'Team $id'; // Default name if empty
    } else if (_name != value) {
      _name = value;
      // Notify listeners only if the name has changed

    }
    notifyListeners();
  }

}