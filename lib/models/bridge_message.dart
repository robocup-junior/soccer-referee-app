import 'dart:convert';

/// Bridge protocol ("MQTT-over-BLE"): each message is a (topic, value) pair
/// framed as UTF-8 bytes `<topic> 0x00 <value>`, written to the Nordic UART
/// TX characteristic. The bridge shares the robot modules' service UUIDs and is
/// told apart only by its address.
const int kBridgeFieldSeparator = 0x00;

class BridgeTopics {
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
}
