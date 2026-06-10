import 'dart:convert';

// Bridge protocol: "MQTT-over-BLE". Each message is a (topic, value) pair,
// framed as UTF-8 bytes: <topic> 0x00 <value>.

// Same Nordic UART Service UUIDs as robot modules. The bridge is distinguished
// from robot modules only by its MAC address, not by service UUID.
const String kBridgeServiceUUID = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
const String kBridgeTxCharUUID = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E';
const String kBridgeRxCharUUID = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';

const int kBridgeFieldSeparator = 0x00;

class BridgeTopics {
  static const String team1Score = 'team1_score';
  static const String team2Score = 'team2_score';
  static const String team1Color = 'team1_color';
  static const String team2Color = 'team2_color';
  // Reserved for iteration 2: team1_name, team2_name, team1_id, team2_id,
  // game_stage, time, field, and timer sync topics.
}

class BridgeMessage {
  final String topic;
  final String value;

  const BridgeMessage(this.topic, this.value);

  List<int> toBytes() {
    return [
      ...utf8.encode(topic),
      kBridgeFieldSeparator,
      ...utf8.encode(value),
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is BridgeMessage && other.topic == topic && other.value == value;

  @override
  int get hashCode => Object.hash(topic, value);

  @override
  String toString() => 'BridgeMessage($topic=$value)';
}
