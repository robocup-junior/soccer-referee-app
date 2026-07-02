import 'package:flutter_test/flutter_test.dart';
import 'package:rcj_scoreboard/services/mqtt.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const realDefaultPassword = 'S_p-@P2_rL7ZFv9';
  const legacyHintPassword = 'S_p-@P2_rL7ZFv9XYZ';

  void expectSecretEquals(String? actual, String expected) {
    expect(actual == expected, isTrue);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  });

  test('fresh prefs use secure MQTT and the working default password',
      () async {
    final service = MqttService();
    await service.loadPreferences();

    expect(service.secureConnection, isTrue);
    expectSecretEquals(service.password, realDefaultPassword);
  });

  test('stored legacy hint password is migrated in memory and on disk',
      () async {
    SharedPreferences.setMockInitialValues({
      'mqtt_password': legacyHintPassword,
    });
    final prefs = await SharedPreferences.getInstance();
    final service = MqttService();

    await service.loadPreferences();

    expectSecretEquals(service.password, realDefaultPassword);
    expectSecretEquals(prefs.getString('mqtt_password'), realDefaultPassword);
  });

  test('stored custom password and insecure setting are preserved', () async {
    SharedPreferences.setMockInitialValues({
      'mqtt_password': 'custom-secret',
      'mqtt_secure_connection': false,
    });
    final service = MqttService();

    await service.loadPreferences();

    expect(service.password, 'custom-secret');
    expect(service.secureConnection, isFalse);
  });

  test('connect returns false while already connecting without changing state',
      () async {
    SharedPreferences.setMockInitialValues({
      'mqtt_server': '127.0.0.1',
      'mqtt_port': 1,
    });
    final service = MqttService();
    await service.loadPreferences();
    service.connectionStateNotifier.value = MqttConnectionStateEx.connecting;

    final result = await service.connect();

    expect(result, isFalse);
    expect(
      service.connectionStateNotifier.value,
      MqttConnectionStateEx.connecting,
    );
  });
}
