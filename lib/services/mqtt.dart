// lib/services/mqtt_service.dart
import 'dart:async';
import 'dart:io';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rcj_scoreboard/models/team.dart';
import 'package:rcj_scoreboard/models/game.dart';



enum MqttConnectionStateEx { disconnected, connecting, connected, error }


class MqttService {
  MqttServerClient? _client;
  final String _mainTopic = 'rcj_soccer'; // To store the configured topic
  String _topic = ''; // To store the configured topic
  bool _isEnabled = false; // To store the enabled state
  late int _port; // To store the configured port
  late String _server; // To store the configured server
  late String _username; // To store the configured username
  late String _password; // To store the configured password
  late bool _secureConnection; // To store the secure connection state
  late bool _autoConnect; // To store the auto-connect state

  final String _clientIdentifier = 'client_${const Uuid().v4()}'; // Generate unique client ID
  final ValueNotifier<MqttConnectionStateEx> connectionStateNotifier = ValueNotifier(MqttConnectionStateEx.disconnected);
  String _lastErrorMessage = '';
  late SharedPreferences prefs;

  final StreamController<String> _messageStreamController = StreamController<
      String>.broadcast();

  Stream<String> get messageStream => _messageStreamController.stream;

  MqttService() {
    loadPreferences().then((_) {}); // Load preferences on initialization
  }

  /// Loads MQTT settings from SharedPreferences
  Future<void> loadPreferences() async {
    prefs = await SharedPreferences.getInstance();
    _isEnabled = prefs.getBool('mqtt_enabled') ?? false;
    _secureConnection = prefs.getBool('mqtt_secure_connection') ?? false;
    _autoConnect = prefs.getBool('mqtt_auto_connect') ?? false;
    _topic = prefs.getString('mqtt_topic') ?? '';
    _port = prefs.getInt('mqtt_port') ?? 8883;
    _server = prefs.getString('mqtt_server') ?? 'f2ec5c0344964af6a9b036e32a4f726c.s1.eu.hivemq.cloud';
    _username = prefs.getString('mqtt_username') ?? 'RCj_soccer_2025';
    _password = prefs.getString('mqtt_password') ?? '';
  }


  // Getters for server, port, username, and password
  String? get server => _server;
  int? get port => _port;
  String? get username => _username;
  String? get password => _password;
  String get topic => _topic;
  String get fieldNumber => _topic.replaceFirst('field_', '');
  bool get isEnabled => _isEnabled;
  bool get secureConnection => _secureConnection;
  bool get autoConnect => _autoConnect;
  String get lastErrorMessage => _lastErrorMessage;

  // Setters for server, port, username, and password
  set server(String? value) {
    if (value != null && value.isNotEmpty) {
      _server = value;
      // Save to preferences
      prefs.setString('mqtt_server', value);
    } else {
      debugPrint('MQTT_LOGS::Error: Invalid server address.');
    }
  }

  set port(int? value) {
    if (value != null && value > 0) {
      _port = value;
      // Save to preferences
      prefs.setInt('mqtt_port', value);
    } else {
      debugPrint('MQTT_LOGS::Error: Invalid port number.');
    }
  }

  set username(String? value) {
    if (value != null) {
      _username = value;
      // Save to preferences
      prefs.setString('mqtt_username', value);
    } else {
      debugPrint('MQTT_LOGS::Error: Invalid username.');
    }
  }

  set password(String? value) {
    if (value != null) {
      _password = value;
      // Save to preferences
      prefs.setString('mqtt_password', value);
    } else {
      debugPrint('MQTT_LOGS::Error: Invalid password.');
    }
  }

  set topic(String value) {
    if (value.isNotEmpty) {
      _topic = value;
      // Save to preferences
      prefs.setString('mqtt_topic', value);
    } else {
      debugPrint('MQTT_LOGS::Error: Invalid topic.');
    }
  }

  set topicField(String value) {
    topic = 'field_$value';
  }

  set isEnabled(bool value) {
    _isEnabled = value;
    // Save to preferences
    prefs.setBool('mqtt_enabled', value);
  }

  set secureConnection(bool value) {
    _secureConnection = value;
    // Save to preferences
    prefs.setBool('mqtt_secure_connection', value);
  }

  set autoConnect(bool value) {
    _autoConnect = value;
    // Save to preferences
    prefs.setBool('mqtt_auto_connect', value);
  }

  bool get isConnected =>
      _client?.connectionStatus?.state == MqttConnectionState.connected;


  Future<bool> connect() async {
    if (_server.isEmpty || _port <= 0) {
      debugPrint('MQTT_LOGS::Error: Server or port not set.');
      return false;
    }

    connectionStateNotifier.value = MqttConnectionStateEx.connecting;


    _client = MqttServerClient.withPort(_server, _clientIdentifier, _port);
    _client!.logging(on: false); // Disable logging for production, enable for debugging


    _client!.keepAlivePeriod = 300;
    _client!.onDisconnected = _onDisconnected;
    _client!.onConnected = _onConnected;
    _client!.onSubscribed = _onSubscribed;
    _client!.pongCallback = _pong; // Optional: for keep alive

    _client!.secure = _secureConnection;

    final connMess = MqttConnectMessage()
        .withClientIdentifier(_clientIdentifier)
        .withWillTopic('willtopic') // Optional: Example Will topic
        .withWillMessage('Last will message :)') // Optional: Example Will message
        .startClean() // Non persistent session
        .withWillQos(MqttQos.atLeastOnce);

  if (_username.isNotEmpty && _password.isNotEmpty) {
    connMess.authenticateAs(_username, _password);
  }

    _client!.connectionMessage = connMess;

    try {
      debugPrint('MQTT_LOGS::Connecting to $_server:$_port...');
      await _client!.connect(_username, _password); // Pass username/password again here for some brokers
    } on NoConnectionException catch (e) {
      debugPrint('MQTT_LOGS::Client exception - $e');
      _lastErrorMessage = 'Network error: Unable to connect';
      connectionStateNotifier.value = MqttConnectionStateEx.error;
    } on SocketException catch (e) {
      debugPrint('MQTT_LOGS::Socket exception - $e');
      _lastErrorMessage = 'Connection failed: ${e.message}';
      connectionStateNotifier.value = MqttConnectionStateEx.error;
    }

    if (_client!.connectionStatus!.state == MqttConnectionState.connected) {
      debugPrint('MQTT_LOGS::Mosquitto client connected');
      return true;
    } else {
      debugPrint('MQTT_LOGS::ERROR Mosquitto client connection failed - disconnecting, status is ${_client!.connectionStatus}');
      final status = _client!.connectionStatus!;
      if (status.returnCode == MqttConnectReturnCode.unacceptedProtocolVersion) {
        _lastErrorMessage = 'Connection failed: Invalid protocol version';
      } else if (status.returnCode == MqttConnectReturnCode.identifierRejected) {
        _lastErrorMessage = 'Connection failed: Invalid client identifier';
      } else if (status.returnCode == MqttConnectReturnCode.brokerUnavailable) {
        _lastErrorMessage = 'Connection failed: Broker unavailable';
      } else if (status.returnCode == MqttConnectReturnCode.badUsernameOrPassword) {
        _lastErrorMessage = 'Auth failed: Bad username/password';
      } else if (status.returnCode == MqttConnectReturnCode.notAuthorized) {
        _lastErrorMessage = 'Auth failed: Invalid credentials';
      } else if (status.returnCode == MqttConnectReturnCode.noneSpecified) {
        _lastErrorMessage = 'Connection failed: No return code specified';
      } else {
        _lastErrorMessage = 'Connection failed: ${status.returnCode}';
      }
      connectionStateNotifier.value = MqttConnectionStateEx.error;
      return false;
    }
  }

  void publishMessage(String message, {String? specificTopic}) {
    if (_isEnabled == true &&
        _client != null &&
        _client!.connectionStatus!.state == MqttConnectionState.connected) {
      final topicToPublish = specificTopic ?? _mainTopic;
      if (topicToPublish.isEmpty) {
          debugPrint('MQTT_LOGS::Error: Topic not set for publishing.');
          return;
      }
      final builder = MqttClientPayloadBuilder();
      builder.addString(message);
      _client!.publishMessage(
          topicToPublish,
          MqttQos.atLeastOnce,
          builder.payload!,
          retain: true // Set to true if you want the message to be retained
      );
      debugPrint('MQTT_LOGS::Published message: $message to topic: $topicToPublish');
    }
  }

  /// Publishes a message to a topic specific for the communication module.
  /// The topic will be: _mainTopic/[_topic]/[topic] if _topic is not empty, otherwise _mainTopic/[topic].
  void publishCMMessage(String message, {required String topic}) {
    final String fullTopic;
    if (_topic.isNotEmpty) {
      fullTopic = '$_mainTopic/$_topic/$topic';
    } else {
      fullTopic = '$_mainTopic/$topic';
    }
    publishMessage(message, specificTopic: fullTopic);
  }


  /// Publishes the remaining time in MM:SS format to the 'time' topic.
  void publishTime(int remainingTime) {
    publishCMMessage('${(remainingTime ~/ 60).toString().padLeft(2, '0')}:${(remainingTime % 60).toString().padLeft(2, '0')}', topic: 'time');
  }

  /// Publishes the score of both teams to their respective topics.
  void publishScore(List<Team> teams) {
    publishCMMessage(teams[0].score.toString(), topic: "team1_score");
    publishCMMessage(teams[1].score.toString(), topic: "team2_score");
  }

  /// Publishes the score of a specific team to its topic.
  void publishTeamNames(List<Team> teams) {
    publishCMMessage(teams[0].name.substring(0, teams[0].name.length > 20 ? 20 : teams[0].name.length), topic: "team1_name");
    publishCMMessage(teams[1].name.substring(0, teams[1].name.length > 20 ? 20 : teams[1].name.length), topic: "team2_name");
  }

  void publishTeam(List<Team> teams) {
    if (teams.length < 2) return; // Ensure there are at least two teams
    publishCMMessage(teams[0].id, topic: "team1_id");
    publishCMMessage(teams[1].id, topic: "team2_id");
  }

  /// Publishes the game stage string to the 'game_stage' topic.
  void publishGameState(MatchStage state) {
    String gameStageString;
    switch (state) {
      case MatchStage.firstHalf:
        gameStageString = '1. Half';
      case MatchStage.halfTime:
        gameStageString = 'Half-Time';
      case MatchStage.secondHalf:
        gameStageString = '2. Half';
      case MatchStage.fullTime:
        gameStageString = 'Game Over';
    }

    publishCMMessage(gameStageString, topic: 'game_stage');
  }


  void disconnect() {
    if (_client != null) {
      debugPrint('MQTT_LOGS::Disconnecting client');
      _client!.disconnect();
    }
  }

  void _onConnected() {
    debugPrint('MQTT_LOGS::Client connection was successful');
    _lastErrorMessage = '';
    connectionStateNotifier.value = MqttConnectionStateEx.connected;
  }

  void _onDisconnected() {
    debugPrint('MQTT_LOGS::Client disconnected');
    if (_client != null &&
        _client!.connectionStatus!.disconnectionOrigin ==
            MqttDisconnectionOrigin.solicited) {
      _client = null;
      debugPrint('MQTT_LOGS::Disconnected callback is solicited, not attempting reconnection');
      connectionStateNotifier.value = MqttConnectionStateEx.disconnected;
      return;
    }
    // Unintentional disconnect: try to reconnect after a delay
    Future<void> attemptReconnect() async {
      while (_isEnabled == true && _client != null && !isConnected) {
        connectionStateNotifier.value = MqttConnectionStateEx.connecting;
        debugPrint('MQTT_LOGS::Attempting to reconnect...');
        bool success = await connect();
        if (success) break;
        debugPrint('MQTT_LOGS::Reconnection failed, retrying in 5 seconds...');
        connectionStateNotifier.value = MqttConnectionStateEx.connecting;
        await Future.delayed(const Duration(seconds: 5));
      }
    }

    Future.delayed(const Duration(seconds: 5), attemptReconnect);
  }

  void _onSubscribed(String topic) {
    debugPrint('MQTT_LOGS::Subscribed to topic: $topic');
  }

  void _pong() {
    debugPrint('MQTT_LOGS::Ping response client callback invoked');
  }

  void dispose() {
    _messageStreamController.close();
    disconnect();
  }
}
