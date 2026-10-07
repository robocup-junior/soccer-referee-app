import 'package:flutter/foundation.dart';
import 'package:rcj_scoreboard/models/module.dart';

class Team with ChangeNotifier {
  Team(this._name, this.modules, this.id);

  String _name;
  final String id;
  final List<Module> modules;
  int score = 0;

  void addScore(int value) {
    if (value < 0 && score <= 0) return;
    score += value;
    notifyListeners();
  }

  String get name => _name;

  /// Empty resolves to the default name; no notification when unchanged (#28).
  set name(String value) {
    final next = value.isEmpty ? 'Team $id' : value;
    if (_name == next) return;
    _name = next;
    notifyListeners();
  }
}
