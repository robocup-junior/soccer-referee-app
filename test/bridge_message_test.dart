import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rcj_scoreboard/models/bridge_message.dart';
import 'package:rcj_scoreboard/screens/settings.dart';
import 'package:rcj_scoreboard/services/ble_bridge_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // Needed so SharedPreferences.setMockInitialValues works (platform channel).
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BridgeMessage framing', () {
    test('encodes topic 0x00 value in UTF-8', () {
      final bytes = const BridgeMessage('team1_score', '3').toBytes();
      final sep = bytes.indexOf(0x00);

      expect(sep, greaterThan(0), reason: 'separator must follow the topic');
      expect(utf8.decode(bytes.sublist(0, sep)), 'team1_score');
      expect(utf8.decode(bytes.sublist(sep + 1)), '3');
    });

    test('uses exactly one 0x00 separator', () {
      final bytes = const BridgeMessage('team2_score', '12').toBytes();
      expect(bytes.where((b) => b == 0x00).length, 1);
    });

    test('color hex value survives framing', () {
      final bytes = const BridgeMessage('team1_color', '77FF00').toBytes();
      final sep = bytes.indexOf(0x00);
      expect(utf8.decode(bytes.sublist(sep + 1)), '77FF00');
    });

    test('empty value still frames (topic + separator only)', () {
      final bytes = const BridgeMessage('time', '').toBytes();
      expect(bytes.last, 0x00);
      expect(utf8.decode(bytes.sublist(0, bytes.length - 1)), 'time');
    });

    test('equality and hashCode are by topic + value', () {
      expect(const BridgeMessage('t', '1'), const BridgeMessage('t', '1'));
      expect(const BridgeMessage('t', '1').hashCode,
          const BridgeMessage('t', '1').hashCode);
      expect(const BridgeMessage('t', '1') == const BridgeMessage('t', '2'),
          isFalse);
    });
  });

  group('BridgeTopics names', () {
    test('iteration-1 topic strings are stable (FW contract)', () {
      expect(BridgeTopics.team1Score, 'team1_score');
      expect(BridgeTopics.team2Score, 'team2_score');
      expect(BridgeTopics.team1Color, 'team1_color');
      expect(BridgeTopics.team2Color, 'team2_color');
    });
  });

  group('Bridge connection button label (#86)', () {
    test('maps all bridge states to the Settings button text', () {
      expect(
        bridgeConnectionButtonLabel(BridgeConnectionState.connected),
        'Disconnect',
      );
      expect(
        bridgeConnectionButtonLabel(BridgeConnectionState.connecting),
        'Cancel',
      );
      expect(
        bridgeConnectionButtonLabel(BridgeConnectionState.disabled),
        'Connect',
      );
      expect(
        bridgeConnectionButtonLabel(BridgeConnectionState.disconnected),
        'Connect',
      );
      expect(
        bridgeConnectionButtonLabel(BridgeConnectionState.error),
        'Connect',
      );
    });
  });

  group('BleBridgeService queue (disconnected — no BLE writes)', () {
    // When the service is enabled but not connected, publishTopic enqueues and
    // dedups, while _processQueue returns at its !isConnected guard before ever
    // touching the BLE characteristic. So queueDepthNotifier reflects the pure
    // bookkeeping with no radio involved.

    Future<BleBridgeService> makeEnabledService() async {
      SharedPreferences.setMockInitialValues({'bridge_enabled': true});
      final svc = BleBridgeService();
      await svc.loadPreferences();
      expect(svc.isEnabled, isTrue);
      expect(svc.isConnected, isFalse);
      return svc;
    }

    test('same topic dedups to a single queued message (latest wins)',
        () async {
      final svc = await makeEnabledService();

      svc.publishTopic(BridgeTopics.team1Score, '1');
      svc.publishTopic(BridgeTopics.team1Score, '2');
      svc.publishTopic(BridgeTopics.team1Score, '3');

      expect(svc.queueDepthNotifier.value, 1);
    });

    test('distinct topics each occupy a slot', () async {
      final svc = await makeEnabledService();

      svc.publishTopic(BridgeTopics.team1Score, '0');
      svc.publishTopic(BridgeTopics.team2Score, '0');
      svc.publishTopic(BridgeTopics.team1Color, '77FF00');
      svc.publishTopic(BridgeTopics.team2Color, 'FF00FF');

      expect(svc.queueDepthNotifier.value, 4);
    });

    test('a full score burst dedups per topic, not across topics', () async {
      final svc = await makeEnabledService();

      // Two goals back to back: the 4-topic burst repeats; each topic should
      // collapse to its latest value, leaving 4 entries, not 8.
      for (var score = 0; score < 2; score++) {
        svc.publishTopic(BridgeTopics.team1Score, score.toString());
        svc.publishTopic(BridgeTopics.team2Score, '0');
        svc.publishTopic(BridgeTopics.team1Color, '77FF00');
        svc.publishTopic(BridgeTopics.team2Color, 'FF00FF');
      }

      expect(svc.queueDepthNotifier.value, 4);
    });

    test('disabled service drops publishes (self-guard)', () async {
      SharedPreferences.setMockInitialValues({'bridge_enabled': false});
      final svc = BleBridgeService();
      await svc.loadPreferences();
      expect(svc.isEnabled, isFalse);

      svc.publishTopic(BridgeTopics.team1Score, '1');

      expect(svc.queueDepthNotifier.value, 0);
    });
  });

  group('BleBridgeService connection lifecycle (#86)', () {
    test('disconnect cancels a connecting bridge without a device', () async {
      SharedPreferences.setMockInitialValues({});
      final svc = BleBridgeService();
      await svc.loadPreferences();

      svc.connectionStateNotifier.value = BridgeConnectionState.connecting;

      await svc.disconnect();

      expect(
        svc.connectionStateNotifier.value,
        BridgeConnectionState.disconnected,
      );
      expect(svc.lastErrorMessage, isNull);
    });

    test('connect with empty bridge address leaves state unchanged', () async {
      SharedPreferences.setMockInitialValues({});
      final svc = BleBridgeService();
      await svc.loadPreferences();
      expect(svc.bridgeMacAddress, isEmpty);
      expect(
        svc.connectionStateNotifier.value,
        BridgeConnectionState.disconnected,
      );

      await svc.connect();

      expect(
        svc.connectionStateNotifier.value,
        BridgeConnectionState.disconnected,
      );
    });
  });
}
