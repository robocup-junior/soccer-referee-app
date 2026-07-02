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
import 'package:rcj_scoreboard/services/error_messages.dart';

enum MqttConnectionStateEx { disconnected, connecting, connected, error }

const String _defaultMqttPassword = 'S_p-@P2_rL7ZFv9';
const String _legacyMqttPasswordHint = 'S_p-@P2_rL7ZFv9XYZ';

class MqttService {
  MqttServerClient? _client;
  // The connect attempt currently in flight, if any (see connect()).
  Future<bool>? _pendingConnect;
  final String _mainTopic = 'rcj_soccer'; // To store the configured topic
  String _topic = ''; // To store the configured topic
  bool _isEnabled = false; // To store the enabled state
  late int _port; // To store the configured port
  late String _server; // To store the configured server
  late String _username; // To store the configured username
  late String _password; // To store the configured password
  late bool _secureConnection; // To store the secure connection state
  late bool _autoConnect; // To store the auto-connect state

  final String _clientIdentifier =
      'client_${const Uuid().v4()}'; // Generate unique client ID
  final ValueNotifier<MqttConnectionStateEx> connectionStateNotifier =
      ValueNotifier(MqttConnectionStateEx.disconnected);
  String _lastErrorMessage = '';
  late SharedPreferences prefs;

  final StreamController<String> _messageStreamController =
      StreamController<String>.broadcast();

  Stream<String> get messageStream => _messageStreamController.stream;

  MqttService() {
    loadPreferences().then((_) {}); // Load preferences on initialization
  }

  /// Loads MQTT settings from SharedPreferences
  Future<void> loadPreferences() async {
    prefs = await SharedPreferences.getInstance();
    _isEnabled = prefs.getBool('mqtt_enabled') ?? false;
    _secureConnection = prefs.getBool('mqtt_secure_connection') ?? true;
    _autoConnect = prefs.getBool('mqtt_auto_connect') ?? false;
    _topic = prefs.getString('mqtt_topic') ?? '';
    _port = prefs.getInt('mqtt_port') ?? 8883;
    _server = prefs.getString('mqtt_server') ??
        'f2ec5c0344964af6a9b036e32a4f726c.s1.eu.hivemq.cloud';
    _username = prefs.getString('mqtt_username') ?? 'RCj_soccer_2026';
    final storedPassword = prefs.getString('mqtt_password');
    if (storedPassword == _legacyMqttPasswordHint) {
      await prefs.setString('mqtt_password', _defaultMqttPassword);
    }
    _password = prefs.getString('mqtt_password') ?? _defaultMqttPassword;
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
    // Re-entrancy handling (#88): an auto-connect and a manual tap must not
    // stack clients, but a caller must not be silently dropped either — a
    // match-load connect can race a connect attempt that a full-time teardown
    // (#87) just cancelled, and a plain "return false while in flight" would
    // leave the new match with MQTT down and no retry. So SERIALIZE: wait for
    // any in-flight attempt to settle, then run a fresh one unless it already
    // produced a live connection. Keyed on an internal pending future, NOT on
    // the public connecting state — the bounded reconnect loop in
    // _onDisconnected sets connectionStateNotifier to `connecting` before
    // each retry, so a state-based guard would turn every retry into a no-op.
    while (_pendingConnect != null) {
      await _pendingConnect;
    }
    if (isConnected) {
      return true;
    }
    final attempt = _connect();
    _pendingConnect = attempt;
    try {
      return await attempt;
    } finally {
      _pendingConnect = null;
    }
  }

  Future<bool> _connect() async {
    if (_server.isEmpty || _port <= 0) {
      debugPrint('MQTT_LOGS::Error: Server or port not set.');
      return false;
    }

    connectionStateNotifier.value = MqttConnectionStateEx.connecting;

    final client = MqttServerClient.withPort(_server, _clientIdentifier, _port);
    _client = client;
    client.logging(
        on: false); // Disable logging for production, enable for debugging

    client.keepAlivePeriod = 300;
    // Capture the current connection in the callback closures so a stale
    // callback from a previous connect() can never read a newer _client.
    final capturedClient = client;
    client.onDisconnected = () => _onDisconnected(capturedClient);
    client.onConnected = () {
      if (identical(_client, capturedClient)) {
        _onConnected();
      }
    };
    client.onSubscribed = _onSubscribed;
    client.pongCallback = _pong; // Optional: for keep alive

    client.secure = _secureConnection;

    final connMess = MqttConnectMessage()
        .withClientIdentifier(_clientIdentifier)
        .withWillTopic('willtopic')
        .withWillMessage('Last will message :)')
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);

    client.connectionMessage = connMess;

    try {
      debugPrint('MQTT_LOGS::Connecting to $_server:$_port...');
      await client.connect(_username,
          _password); // Pass username/password again here for some brokers
    } on NoConnectionException catch (e) {
      if (!identical(_client, client)) return false;
      debugPrint('MQTT_LOGS::Client exception - $e');
      _lastErrorMessage = 'Network error: Unable to connect';
      connectionStateNotifier.value = MqttConnectionStateEx.error;
    } on SocketException catch (e) {
      if (!identical(_client, client)) return false;
      debugPrint('MQTT_LOGS::Socket exception - $e');
      _lastErrorMessage = 'Connection failed: ${e.message}';
      connectionStateNotifier.value = MqttConnectionStateEx.error;
    } on Exception catch (e) {
      // mqtt_client wraps most secure-connect failures in
      // NoConnectionException, but its socket onError paths can complete the
      // awaited future with the raw exception (e.g. a HandshakeException).
      // connect() is now also called unawaited from the match-load hook, so
      // an escaped exception would surface as an uncaught async error and pin
      // the status at "Connecting..." forever. Map anything Exception-shaped
      // to the error state; real programming errors (Error) still propagate.
      if (!identical(_client, client)) return false;
      debugPrint('MQTT_LOGS::Unexpected connect exception - $e');
      _lastErrorMessage = describeError(e).message;
      connectionStateNotifier.value = MqttConnectionStateEx.error;
    }

    if (!identical(_client, client)) return false;

    if (client.connectionStatus?.state == MqttConnectionState.connected) {
      debugPrint('MQTT_LOGS::Mosquitto client connected');
      return true;
    } else {
      debugPrint(
          'MQTT_LOGS::ERROR Mosquitto client connection failed - disconnecting, status is ${client.connectionStatus}');
      final status = client.connectionStatus;
      _lastErrorMessage = describeMqttReturnCode(
          status?.returnCode ?? MqttConnectReturnCode.noneSpecified);
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
          topicToPublish, MqttQos.atLeastOnce, builder.payload!,
          retain: true // Set to true if you want the message to be retained
          );
      debugPrint(
          'MQTT_LOGS::Published message: $message to topic: $topicToPublish');
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
    publishCMMessage(
        '${(remainingTime ~/ 60).toString().padLeft(2, '0')}:${(remainingTime % 60).toString().padLeft(2, '0')}',
        topic: 'time');
  }

  /// Publishes the score of both teams to their respective topics.
  void publishScore(List<Team> teams) {
    publishCMMessage(teams[0].score.toString(), topic: "team1_score");
    publishCMMessage(teams[1].score.toString(), topic: "team2_score");
  }

  /// Publishes the score of a specific team to its topic.
  void publishTeamNames(List<Team> teams) {
    publishCMMessage(
        teams[0].name.substring(
            0, teams[0].name.length > 20 ? 20 : teams[0].name.length),
        topic: "team1_name");
    publishCMMessage(
        teams[1].name.substring(
            0, teams[1].name.length > 20 ? 20 : teams[1].name.length),
        topic: "team2_name");
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
    final client = _client;
    if (client == null) {
      return;
    }
    _client = null;
    debugPrint('MQTT_LOGS::Disconnecting client');
    try {
      client.disconnect();
    } catch (e) {
      debugPrint('MQTT_LOGS::Disconnect error - $e');
    }
    connectionStateNotifier.value = MqttConnectionStateEx.disconnected;
  }

  void _onConnected() {
    debugPrint('MQTT_LOGS::Client connection was successful');
    _lastErrorMessage = '';
    connectionStateNotifier.value = MqttConnectionStateEx.connected;
  }

  // Max reconnect attempts before giving up (circuit-breaker for #37).
  static const int _maxReconnectAttempts = 10;

  void _onDisconnected(MqttServerClient disconnectedClient) {
    debugPrint('MQTT_LOGS::Client disconnected');
    // Ignore callbacks from a stale client. A delayed disconnect from a
    // previous connect() must never mutate the state of a newer connection:
    // the closure capture in connect() prevents *reading* a newer _client, and
    // this identical() check additionally refuses to *write* _client /
    // connection state / reconnect work unless the callback belongs to the
    // currently active client.
    if (!identical(_client, disconnectedClient)) {
      debugPrint('MQTT_LOGS::Ignoring disconnect callback from a stale client');
      return;
    }
    if (disconnectedClient.connectionStatus?.disconnectionOrigin ==
        MqttDisconnectionOrigin.solicited) {
      _client = null;
      debugPrint(
          'MQTT_LOGS::Disconnected callback is solicited, not attempting reconnection');
      connectionStateNotifier.value = MqttConnectionStateEx.disconnected;
      return;
    }
    // Unintentional disconnect: try to reconnect with bounded retries.
    Future<void> attemptReconnect() async {
      int attempts = 0;
      while (_isEnabled == true &&
          _client != null &&
          !isConnected &&
          attempts < _maxReconnectAttempts) {
        attempts++;
        connectionStateNotifier.value = MqttConnectionStateEx.connecting;
        debugPrint(
            'MQTT_LOGS::Attempting to reconnect ($attempts/$_maxReconnectAttempts)...');
        bool success = await connect();
        if (success) break;
        // Don't wait after the final failed attempt: the trailing delay would
        // otherwise open a 5s window in which a user disable/disconnect could
        // be clobbered by the exhausted-retry error below.
        if (attempts >= _maxReconnectAttempts) break;
        debugPrint('MQTT_LOGS::Reconnection failed, retrying in 5 seconds...');
        connectionStateNotifier.value = MqttConnectionStateEx.connecting;
        await Future.delayed(const Duration(seconds: 5));
      }
      // Only report exhaustion if this reconnect session is still active: a
      // user disable (_isEnabled == false) or solicited disconnect
      // (_client == null) during the loop must not be flipped back into error.
      if (_isEnabled == true &&
          _client != null &&
          !isConnected &&
          attempts >= _maxReconnectAttempts) {
        // Preserve the specific cause connect() recorded on the last attempt
        // instead of hiding it behind a generic message.
        final cause =
            _lastErrorMessage.isNotEmpty ? ' ($_lastErrorMessage)' : '';
        _lastErrorMessage =
            'Reconnection failed after $_maxReconnectAttempts attempts$cause';
        connectionStateNotifier.value = MqttConnectionStateEx.error;
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
