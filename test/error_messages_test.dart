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
      final info = describeError(const HttpStatusException(404, url: 'http://x'));
      expect(info.message, 'Server returned 404');
      expect(info.hint, 'Check the match-data URL in settings');
    });

    test('SocketException is a network error', () {
      final info = describeError(const SocketException('boom'));
      expect(info.message, 'Network error: unable to connect');
      expect(info.hint, 'Check the network / Wi-Fi connection');
    });

    test('TimeoutException is a timeout', () {
      final info = describeError(TimeoutException('slow'));
      expect(info.message, 'Connection timed out');
      expect(info.hint, 'Move closer or check the device is powered');
    });

    test('FormatException is a bad response format', () {
      final info = describeError(const FormatException('bad json'));
      expect(info.message, 'Unexpected response format');
      expect(info.hint, 'Check the match-data URL in settings');
    });

    test('FlutterBluePlusException is a BLE failure', () {
      final info = describeError(
        FlutterBluePlusException(ErrorPlatform.android, 'connect', 133, 'gatt'),
      );
      expect(info.message, 'Bluetooth connection failed');
      expect(info.hint, 'Move closer, re-power the robot, or re-scan');
    });

    test('unknown error falls back without crashing', () {
      final info = describeError('weird');
      expect(info.message, startsWith('Something went wrong'));
    });
  });

  group('describeMqttReturnCode', () {
    test('bad credentials map to the existing string', () {
      expect(describeMqttReturnCode(MqttConnectReturnCode.badUsernameOrPassword),
          'Auth failed: Bad username/password');
    });

    test('broker unavailable maps to the existing string', () {
      expect(describeMqttReturnCode(MqttConnectReturnCode.brokerUnavailable),
          'Connection failed: Broker unavailable');
    });
  });
}
