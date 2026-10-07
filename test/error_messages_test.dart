// test/error_messages_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:rcj_scoreboard/services/error_messages.dart';

void main() {
  group('describeAdapterState', () {
    test('unavailable means no hardware', () {
      final info = describeAdapterState(BluetoothAdapterState.unavailable);
      expect(info.message, 'Bluetooth unavailable on this device');
    });
  });

  group('describeError', () {
    test('HttpStatusException includes the status code', () {
      final info =
          describeError(const HttpStatusException(404, url: 'http://x'));
      expect(info, 'Server returned 404');
    });

    test('unknown error falls back to a short, fixed message (no raw dump)',
        () {
      // The raw error must NOT leak into the user-facing string — a verbose
      // PlatformException there overflows the status row and borks the screen.
      final info = describeError(
          'PlatformException(some, very long, ${'x' * 500}, detail)');
      expect(info, 'Connection failed');
      expect(info.contains('x' * 50), isFalse);
    });
  });

  group('describeMqttReturnCode', () {
    test('bad credentials map to the existing string', () {
      expect(
          describeMqttReturnCode(MqttConnectReturnCode.badUsernameOrPassword),
          'Auth failed: Bad username/password');
    });
  });
}
