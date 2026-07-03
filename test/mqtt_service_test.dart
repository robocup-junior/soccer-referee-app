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
    expect(service.isEnabled, isTrue,
        reason: 'a fresh install must be able to auto-connect on match load');
    expectSecretEquals(service.password, realDefaultPassword);
  });

  test('an explicit disable is preserved over the enabled-by-default',
      () async {
    SharedPreferences.setMockInitialValues({'mqtt_enabled': false});
    final service = MqttService();
    await service.loadPreferences();

    expect(service.isEnabled, isFalse);
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

  test('connect refuses the shipped production broker under flutter_test',
      () async {
    // Review #94 backstop: fresh prefs leave _server at the shipped
    // production default; a test-run connect must refuse before opening a
    // socket (an unseeded CI test could otherwise publish retained state to
    // a live field). Local/custom brokers stay allowed — every other test
    // here uses 127.0.0.1.
    final service = MqttService();
    await service.loadPreferences();

    final result = await service.connect();

    expect(result, isFalse);
    expect(
      service.connectionStateNotifier.value,
      MqttConnectionStateEx.disconnected,
    );
  });

  test(
      'connect still attempts when the state already reads connecting '
      '(the reconnect loop pre-sets it before every retry)', () async {
    SharedPreferences.setMockInitialValues({
      'mqtt_server': '127.0.0.1',
      'mqtt_port': 1,
    });
    final service = MqttService();
    await service.loadPreferences();
    // _onDisconnected's attemptReconnect sets the public state to
    // `connecting` before each `await connect()`. The re-entrancy guard must
    // therefore key on an internal in-flight flag, not on this state —
    // otherwise every retry short-circuits and MQTT never recovers from an
    // unintentional disconnect.
    service.connectionStateNotifier.value = MqttConnectionStateEx.connecting;

    final result = await service.connect();

    // Port 1 refuses immediately: a REAL attempt was made and failed (error
    // state), instead of returning while the state still reads `connecting`.
    expect(result, isFalse);
    expect(
      service.connectionStateNotifier.value,
      MqttConnectionStateEx.error,
    );
  });

  test('concurrent connect calls are serialized, never silently dropped',
      () async {
    SharedPreferences.setMockInitialValues({
      'mqtt_server': '127.0.0.1',
      'mqtt_port': 1,
    });
    final service = MqttService();
    await service.loadPreferences();

    // The second caller must wait for the first attempt and then run a fresh
    // one (both fail against the refused port) — a dropped second call was
    // how a match-load auto-connect racing a teardown-cancelled attempt left
    // the new match with MQTT down and no retry.
    final results = await Future.wait([service.connect(), service.connect()]);

    expect(results, [false, false]);
    expect(
      service.connectionStateNotifier.value,
      MqttConnectionStateEx.error,
    );
  });

  test('disconnect() vetoes connect waiters parked behind an in-flight attempt',
      () async {
    SharedPreferences.setMockInitialValues({
      'mqtt_server': '127.0.0.1',
      'mqtt_port': 1,
    });
    final service = MqttService();
    await service.loadPreferences();

    // first suspends on real socket I/O; second parks behind it; the
    // disconnect lands before either resumes. The parked waiter must NOT
    // spawn a fresh attempt after the explicit disconnect — a real second
    // attempt against the refused port would end in `error`, while a vetoed
    // one leaves the state exactly where disconnect() settled it.
    final first = service.connect();
    final second = service.connect();
    service.disconnect();

    expect(await Future.wait([first, second]), [false, false]);
    expect(
      service.connectionStateNotifier.value,
      MqttConnectionStateEx.disconnected,
    );
  });
}
