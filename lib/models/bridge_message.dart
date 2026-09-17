import 'dart:convert';

import 'package:rcj_scoreboard/models/module.dart';

/// Bridge protocol ("MQTT-over-BLE"): each message is a (topic, value) pair
/// framed as UTF-8 bytes `<topic> 0x00 <value>`, written to the Nordic UART
/// TX characteristic. The bridge shares the robot modules' service UUIDs and is
/// told apart only by its address.
const String kBridgeServiceUUID = kNusServiceUuid;
const String kBridgeTxCharUUID = kNusTxCharUuid;
const int kBridgeFieldSeparator = 0x00;

class BridgeTopics {
  static const String team1Score = 'team1_score';
  static const String team2Score = 'team2_score';
  static const String team1Color = 'team1_color';
  static const String team2Color = 'team2_color';

  /// Topic for the team at display position [index] (0 = left).
  static String score(int index) => 'team${index + 1}_score';
  static String color(int index) => 'team${index + 1}_color';
}

class BridgeMessage {
  final String topic;
  final String value;

  const BridgeMessage(this.topic, this.value);

  List<int> toBytes() =>
      [...utf8.encode(topic), kBridgeFieldSeparator, ...utf8.encode(value)];

  @override
  bool operator ==(Object other) =>
      other is BridgeMessage && other.topic == topic && other.value == value;

  @override
  int get hashCode => Object.hash(topic, value);

  @override
  String toString() => 'BridgeMessage($topic=$value)';
}
