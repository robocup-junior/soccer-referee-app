import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class WakelockService with ChangeNotifier {
  bool _enabled = false;

  late SharedPreferences _prefs;
  bool _prefsLoaded = false;

  WakelockService() {
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    _prefs = await SharedPreferences.getInstance();
    _enabled = _prefs.getBool('wakelock_enabled') ?? false;
    _prefsLoaded = true;
    _applyWakelock();
    notifyListeners();
  }

  bool get enabled => _enabled;
  set enabled(bool value) {
    _enabled = value;
    if (_prefsLoaded) {
      _prefs.setBool('wakelock_enabled', value);
    }
    _applyWakelock();
    notifyListeners();
  }

  void _applyWakelock() {
    if (kIsWeb) return;
    try {
      WakelockPlus.toggle(enable: _enabled);
    } catch (_) {}
  }

  @override
  void dispose() {
    if (!kIsWeb) {
      try {
        WakelockPlus.disable();
      } catch (_) {}
    }
    super.dispose();
  }
}
