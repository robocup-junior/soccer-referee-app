import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';

const List<int> kVibrationAlertOptions = [10, 5, 3, 0];

/// Timer-alert preferences. The enabled flags and threshold sets govern BOTH
/// in-app vibration and the background notifications (one "Vibration &
/// Notifications" setting).
class VibrationService with ChangeNotifier {
  VibrationService() {
    _loadPreferences();
    _initVibrator();
  }

  final _game = _AlertPref('vibration_game_timer', {10, 5, 3, 0});
  final _damage = _AlertPref('vibration_damage_timer', {5, 0});
  SharedPreferences? _prefs;
  bool _hasVibrator = false;

  bool get gameTimerEnabled => _game.enabled;
  bool get damageTimerEnabled => _damage.enabled;
  Set<int> get gameTimerAlerts => _game.alerts;
  Set<int> get damageTimerAlerts => _damage.alerts;

  set gameTimerEnabled(bool value) => _setEnabled(_game, value);
  set damageTimerEnabled(bool value) => _setEnabled(_damage, value);
  void toggleGameTimerAlert(int seconds) => _toggle(_game, seconds);
  void toggleDamageTimerAlert(int seconds) => _toggle(_damage, seconds);

  Future<void> vibrateGameTimer() => _vibrate(_game);
  Future<void> vibrateDamageTimer() => _vibrate(_damage);

  Future<void> _initVibrator() async {
    if (kIsWeb) return;
    try {
      _hasVibrator = await Vibration.hasVibrator();
    } catch (e) {
      debugPrint('VibrationService: hasVibrator() failed: $e');
    }
  }

  Future<void> _loadPreferences() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    for (final pref in [_game, _damage]) {
      pref.enabled = prefs.getBool(pref.enabledKey) ?? true;
      final stored = prefs.getStringList(pref.alertsKey);
      if (stored != null) pref.alerts = stored.map(int.parse).toSet();
    }
    notifyListeners();
  }

  void _setEnabled(_AlertPref pref, bool value) {
    pref.enabled = value;
    _prefs?.setBool(pref.enabledKey, value);
    notifyListeners();
  }

  void _toggle(_AlertPref pref, int seconds) {
    pref.alerts.contains(seconds)
        ? pref.alerts.remove(seconds)
        : pref.alerts.add(seconds);
    _prefs?.setStringList(
        pref.alertsKey, pref.alerts.map((e) => '$e').toList());
    notifyListeners();
  }

  Future<void> _vibrate(_AlertPref pref) async {
    if (!pref.enabled || kIsWeb || !_hasVibrator) return;
    try {
      await Vibration.vibrate();
    } catch (e) {
      debugPrint('VibrationService: vibrate failed: $e');
    }
  }
}

class _AlertPref {
  _AlertPref(this._key, this.alerts);
  final String _key;
  bool enabled = true;
  Set<int> alerts;
  String get enabledKey => '${_key}_enabled';
  String get alertsKey => '${_key}_alerts';
}
