import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mqtt_client/mqtt_client.dart';

/// A user-facing error: one-line [message] plus an optional actionable [hint].
class ErrorInfo {
  const ErrorInfo(this.message, {this.hint});
  final String message;
  final String? hint;
}

/// Thrown by match-data fetches on a non-200 response.
class HttpStatusException implements Exception {
  const HttpStatusException(this.statusCode, {this.url});
  final int statusCode;
  final String? url;

  @override
  String toString() => 'HttpStatusException($statusCode, $url)';
}

/// Classify a caught error by type into a short, fixed user-facing message.
/// The raw error is for debugPrint only: it can be a verbose multi-line
/// PlatformException that overflows a status label.
ErrorInfo describeError(Object error) => switch (error) {
      HttpStatusException(:final statusCode) => ErrorInfo(
          'Server returned $statusCode',
          hint: 'Check the match-data URL in settings'),
      TimeoutException() => const ErrorInfo('Connection timed out',
          hint: 'Move closer or check the device is powered'),
      SocketException() => const ErrorInfo('Network error: unable to connect',
          hint: 'Check the network / Wi-Fi connection'),
      FormatException() => const ErrorInfo('Unexpected response format',
          hint: 'Check the match-data URL in settings'),
      FlutterBluePlusException() => const ErrorInfo(
          'Bluetooth connection failed',
          hint: 'Move closer, re-power the robot, or re-scan'),
      _ => const ErrorInfo('Connection failed',
          hint: 'Check the address and that the device is powered'),
    };

/// Adapter states in which robots cannot be connected.
bool isAdapterProblem(BluetoothAdapterState state) => const {
      BluetoothAdapterState.off,
      BluetoothAdapterState.turningOff,
      BluetoothAdapterState.unauthorized,
      BluetoothAdapterState.unavailable,
    }.contains(state);

ErrorInfo describeAdapterState(BluetoothAdapterState state) => switch (state) {
      BluetoothAdapterState.off ||
      BluetoothAdapterState.turningOff =>
        const ErrorInfo('Bluetooth is off',
            hint: 'Turn it on to connect robots'),
      BluetoothAdapterState.unauthorized => const ErrorInfo(
          'Bluetooth permission denied',
          hint: 'Allow Bluetooth in app settings'),
      BluetoothAdapterState.unavailable =>
        const ErrorInfo('Bluetooth unavailable on this device'),
      _ => const ErrorInfo('Bluetooth not ready'),
    };

String describeMqttReturnCode(MqttConnectReturnCode code) => switch (code) {
      MqttConnectReturnCode.unacceptedProtocolVersion =>
        'Connection failed: Invalid protocol version',
      MqttConnectReturnCode.identifierRejected =>
        'Connection failed: Invalid client identifier',
      MqttConnectReturnCode.brokerUnavailable =>
        'Connection failed: Broker unavailable',
      MqttConnectReturnCode.badUsernameOrPassword =>
        'Auth failed: Bad username/password',
      MqttConnectReturnCode.notAuthorized => 'Auth failed: Invalid credentials',
      MqttConnectReturnCode.noneSpecified =>
        'Connection failed: No return code specified',
      _ => 'Connection failed: $code',
    };
