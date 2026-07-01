import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mqtt_client/mqtt_client.dart';

/// A user-facing error: one-line [message] plus an optional actionable [hint].
class ErrorInfo {
  final String message;
  final String? hint;
  const ErrorInfo(this.message, {this.hint});
}

/// Thrown by match-data fetches when the server responds with a non-200 code.
/// Defined here (not in match_data.dart) so [describeError] can classify it
/// without a circular import.
class HttpStatusException implements Exception {
  final int statusCode;
  final String? url;
  const HttpStatusException(this.statusCode, {this.url});

  @override
  String toString() => 'HttpStatusException($statusCode, $url)';
}

/// Classify a caught error into a user-facing [ErrorInfo]. Classifies by type,
/// not by brittle string matching.
ErrorInfo describeError(Object error) {
  if (error is HttpStatusException) {
    return ErrorInfo('Server returned ${error.statusCode}',
        hint: 'Check the match-data URL in settings');
  }
  if (error is TimeoutException) {
    return const ErrorInfo('Connection timed out',
        hint: 'Move closer or check the device is powered');
  }
  if (error is SocketException) {
    return const ErrorInfo('Network error: unable to connect',
        hint: 'Check the network / Wi-Fi connection');
  }
  if (error is FormatException) {
    return const ErrorInfo('Unexpected response format',
        hint: 'Check the match-data URL in settings');
  }
  if (error is FlutterBluePlusException) {
    return const ErrorInfo('Bluetooth connection failed',
        hint: 'Move closer, re-power the robot, or re-scan');
  }
  // Fallback: keep the user-facing string short and fixed. The raw [error]
  // (which can be a verbose multi-line PlatformException) is logged by callers
  // via debugPrint — never surfaced into a status chip where it overflows the
  // layout.
  return const ErrorInfo('Connection failed',
      hint: 'Check the address and that the device is powered');
}

/// Map a BLE adapter state to a user-facing message for the Home banner and
/// the connect screen.
ErrorInfo describeAdapterState(BluetoothAdapterState state) {
  switch (state) {
    case BluetoothAdapterState.off:
    case BluetoothAdapterState.turningOff:
      return const ErrorInfo('Bluetooth is off',
          hint: 'Turn it on to connect robots');
    case BluetoothAdapterState.unauthorized:
      return const ErrorInfo('Bluetooth permission denied',
          hint: 'Allow Bluetooth in app settings');
    case BluetoothAdapterState.unavailable:
      return const ErrorInfo('Bluetooth unavailable on this device');
    default:
      // on / turningOn / unknown — caller decides whether to show anything.
      return const ErrorInfo('Bluetooth not ready');
  }
}

/// MQTT broker return code → message. Relocated verbatim from mqtt.dart so the
/// strings stay identical (single source of truth).
String describeMqttReturnCode(MqttConnectReturnCode code) {
  switch (code) {
    case MqttConnectReturnCode.unacceptedProtocolVersion:
      return 'Connection failed: Invalid protocol version';
    case MqttConnectReturnCode.identifierRejected:
      return 'Connection failed: Invalid client identifier';
    case MqttConnectReturnCode.brokerUnavailable:
      return 'Connection failed: Broker unavailable';
    case MqttConnectReturnCode.badUsernameOrPassword:
      return 'Auth failed: Bad username/password';
    case MqttConnectReturnCode.notAuthorized:
      return 'Auth failed: Invalid credentials';
    case MqttConnectReturnCode.noneSpecified:
      return 'Connection failed: No return code specified';
    default:
      return 'Connection failed: $code';
  }
}
