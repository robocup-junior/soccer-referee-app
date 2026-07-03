import 'package:shared_preferences/shared_preferences.dart';

/// Seeds the explicit MQTT disable for suites that drive `Game` with its
/// REAL `MqttService`.
///
/// MQTT ships enabled by default with WORKING production credentials (#88),
/// so a Game-level test that applies a scoreboard config without this seed
/// fires a real network connect from the test VM — leaking timers into the
/// widget binding and, in the worst case, publishing retained reset state to
/// a live field's topics. Call this in `setUp` right after the prefs are
/// mocked/cleared.
///
/// Suites that ASSERT connect behavior must not use this seed — inject a fake
/// instead via the `game.mqttService = _RecordingMqttService(...)` seam (see
/// the "#88" groups in game_recovery_test.dart). `MqttService._connect` also
/// carries a structural backstop refusing the shipped production server under
/// FLUTTER_TEST, but an explicit seed keeps tests deterministic and quiet.
Future<void> seedMqttDisabledForGameTests() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('mqtt_enabled', false);
}
