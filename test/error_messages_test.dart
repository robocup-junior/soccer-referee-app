// test/error_messages_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:rcj_scoreboard/services/error_messages.dart';

void main() {
  group('describeAdapterState', () {
    test('off is descriptive and actionable', () {
      final info = describeAdapterState(BluetoothAdapterState.off);
      expect(info.message, 'Bluetooth is off');
      expect(info.hint, 'Turn it on to connect robots');
    });

    test('unauthorized points at permissions', () {
      final info = describeAdapterState(BluetoothAdapterState.unauthorized);
      expect(info.message, 'Bluetooth permission denied');
      expect(info.hint, 'Allow Bluetooth in app settings');
    });

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

    test('SocketException is a network error', () {
      final info = describeError(const SocketException('boom'));
      expect(info, 'Network error: unable to connect');
    });

    test('TimeoutException is a timeout', () {
      final info = describeError(TimeoutException('slow'));
      expect(info, 'Connection timed out');
    });

    test('FormatException is a bad response format', () {
      final info = describeError(const FormatException('bad json'));
      expect(info, 'Unexpected response format');
    });

    test('FlutterBluePlusException is a BLE failure', () {
      final info = describeError(
        FlutterBluePlusException(ErrorPlatform.android, 'connect', 133, 'gatt'),
      );
      expect(info, 'Bluetooth connection failed');
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

    test('broker unavailable maps to the existing string', () {
      expect(describeMqttReturnCode(MqttConnectReturnCode.brokerUnavailable),
          'Connection failed: Broker unavailable');
    });
  });
}
