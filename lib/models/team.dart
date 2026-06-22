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
    // Normalize first (empty -> default name), then notify only when the
    // effective name actually changes. Re-submitting the current name, or an
    // empty field when the team is already at its default, must not rebuild
    // listeners (#28).
    final nextName = value.isEmpty ? 'Team $id' : value;
    if (_name == nextName) return;
    _name = nextName;
    notifyListeners();
  }

}