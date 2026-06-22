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

  Future<void> _applyWakelock() async {
    if (kIsWeb) return;
    // WakelockPlus.toggle returns a Future whose PlatformException surfaces
    // asynchronously, so it must be awaited inside the try to be caught.
    try {
      await WakelockPlus.toggle(enable: _enabled);
    } catch (e) {
      debugPrint('WakelockService: toggle(enable: $_enabled) failed: $e');
    }
  }

  @override
  void dispose() {
    if (!kIsWeb) {
      // dispose() can't be async/awaited, so attach catchError to swallow the
      // asynchronously-delivered PlatformException instead of a sync try/catch.
      WakelockPlus.disable().catchError(
        (e) => debugPrint('WakelockService: disable() on dispose failed: $e'),
      );
    }
    super.dispose();
  }
}
