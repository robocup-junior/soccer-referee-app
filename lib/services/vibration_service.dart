import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';

const List<int> kVibrationAlertOptions = [10, 5, 3, 0];

class VibrationService with ChangeNotifier {
  bool _gameTimerEnabled = true;
  bool _damageTimerEnabled = true;
  Set<int> _gameTimerAlerts = {10, 5, 3, 0};
  Set<int> _damageTimerAlerts = {5, 0};

  late SharedPreferences _prefs;
  bool _prefsLoaded = false;
  bool _hasVibrator = false;

  VibrationService() {
    _loadPreferences();
    _initVibrator();
  }

  Future<void> _initVibrator() async {
    if (kIsWeb) return;
    try {
      _hasVibrator = await Vibration.hasVibrator();
    } catch (e) {
      debugPrint('VibrationService: hasVibrator() failed: $e');
    }
  }

  Future<void> _loadPreferences() async {
    _prefs = await SharedPreferences.getInstance();
    _gameTimerEnabled =
        _prefs.getBool('vibration_game_timer_enabled') ?? true;
    _damageTimerEnabled =
        _prefs.getBool('vibration_damage_timer_enabled') ?? true;

    final gameAlerts =
        _prefs.getStringList('vibration_game_timer_alerts');
    if (gameAlerts != null) {
      _gameTimerAlerts =
          gameAlerts.map((e) => int.parse(e)).toSet();
    }

    final damageAlerts =
        _prefs.getStringList('vibration_damage_timer_alerts');
    if (damageAlerts != null) {
      _damageTimerAlerts =
          damageAlerts.map((e) => int.parse(e)).toSet();
    }

    _prefsLoaded = true;
    notifyListeners();
  }

  bool get gameTimerEnabled => _gameTimerEnabled;
  set gameTimerEnabled(bool value) {
    _gameTimerEnabled = value;
    if (_prefsLoaded) {
      _prefs.setBool('vibration_game_timer_enabled', value);
    }
    notifyListeners();
  }

  bool get damageTimerEnabled => _damageTimerEnabled;
  set damageTimerEnabled(bool value) {
    _damageTimerEnabled = value;
    if (_prefsLoaded) {
      _prefs.setBool('vibration_damage_timer_enabled', value);
    }
    notifyListeners();
  }

  Set<int> get gameTimerAlerts => _gameTimerAlerts;
  Set<int> get damageTimerAlerts => _damageTimerAlerts;

  void toggleGameTimerAlert(int seconds) {
    if (_gameTimerAlerts.contains(seconds)) {
      _gameTimerAlerts.remove(seconds);
    } else {
      _gameTimerAlerts.add(seconds);
    }
    if (_prefsLoaded) {
      _prefs.setStringList('vibration_game_timer_alerts',
          _gameTimerAlerts.map((e) => e.toString()).toList());
    }
    notifyListeners();
  }

  void toggleDamageTimerAlert(int seconds) {
    if (_damageTimerAlerts.contains(seconds)) {
      _damageTimerAlerts.remove(seconds);
    } else {
      _damageTimerAlerts.add(seconds);
    }
    if (_prefsLoaded) {
      _prefs.setStringList('vibration_damage_timer_alerts',
          _damageTimerAlerts.map((e) => e.toString()).toList());
    }
    notifyListeners();
  }

  /// Triggers a vibration for the game timer alert.
  Future<void> vibrateGameTimer() async {
    if (!_gameTimerEnabled || kIsWeb || !_hasVibrator) return;
    try {
      await Vibration.vibrate();
    } catch (e) {
      debugPrint('VibrationService: game-timer vibrate failed: $e');
    }
  }

  /// Triggers a vibration for the damage timer alert.
  Future<void> vibrateDamageTimer() async {
    if (!_damageTimerEnabled || kIsWeb || !_hasVibrator) return;
    try {
      await Vibration.vibrate();
    } catch (e) {
      debugPrint('VibrationService: damage-timer vibrate failed: $e');
    }
  }
}
