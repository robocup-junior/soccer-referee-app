import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/models/team.dart';
import 'package:rcj_scoreboard/services/error_messages.dart';
import 'package:rcj_scoreboard/utils/format.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

enum MqttConnectionStateEx { disconnected, connecting, connected, error }

const String _defaultPassword = 'S_p-@P2_rL7ZFv9';
const String _legacyPasswordHint = 'S_p-@P2_rL7ZFv9XYZ';
const String _defaultServer =
    'f2ec5c0344964af6a9b036e32a4f726c.s1.eu.hivemq.cloud';

/// Publishes match state to `rcj_soccer/field_<N>/<topic>` (retained).
class MqttService {
  MqttService() {
    loadPreferences();
  }

  static const _mainTopic = 'rcj_soccer';
  static const _maxReconnectAttempts = 10;

  final String _clientId = 'client_${const Uuid().v4()}';
  final ValueNotifier<MqttConnectionStateEx> connectionStateNotifier =
      ValueNotifier(MqttConnectionStateEx.disconnected);

  SharedPreferences? _prefs;
  MqttServerClient? _client;
  // The connect attempt in flight; disconnect() bumps the epoch to veto any
  // caller parked behind it.
  Future<bool>? _pendingConnect;
  int _connectEpoch = 0;
  String _lastErrorMessage = '';

  bool _isEnabled = true;
  bool _secureConnection = true;
  String _topic = '';
  int _port = 8883;
  String _server = _defaultServer;
  String _username = 'RCj_soccer_2026';
  String _password = _defaultPassword;

  Future<void> loadPreferences() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    // Enabled by default so a fresh install auto-connects on match load (#88).
    _isEnabled = prefs.getBool('mqtt_enabled') ?? true;
    _secureConnection = prefs.getBool('mqtt_secure_connection') ?? true;
    _topic = prefs.getString('mqtt_topic') ?? '';
    _port = prefs.getInt('mqtt_port') ?? 8883;
    _server = prefs.getString('mqtt_server') ?? _defaultServer;
    _username = prefs.getString('mqtt_username') ?? 'RCj_soccer_2026';
    if (prefs.getString('mqtt_password') == _legacyPasswordHint) {
      await prefs.setString('mqtt_password', _defaultPassword);
    }
    _password = prefs.getString('mqtt_password') ?? _defaultPassword;
  }

  String get server => _server;
  int get port => _port;
  String get username => _username;
  String get password => _password;
  String get topic => _topic;
  String get fieldNumber => _topic.replaceFirst('field_', '');
  bool get isEnabled => _isEnabled;
  bool get secureConnection => _secureConnection;
  String get lastErrorMessage => _lastErrorMessage;
  bool get isConnected =>
      _client?.connectionStatus?.state == MqttConnectionState.connected;

  set server(String value) {
    if (value.isEmpty) return;
    _server = value;
    _prefs?.setString('mqtt_server', value);
  }

  set port(int? value) {
    if (value == null || value <= 0) return;
    _port = value;
    _prefs?.setInt('mqtt_port', value);
  }

  set username(String value) {
    _username = value;
    _prefs?.setString('mqtt_username', value);
  }

  set password(String value) {
    _password = value;
    _prefs?.setString('mqtt_password', value);
  }

  set topic(String value) {
    if (value.isEmpty) return;
    _topic = value;
    _prefs?.setString('mqtt_topic', value);
  }

  set topicField(String value) => topic = 'field_$value';

  set isEnabled(bool value) {
    _isEnabled = value;
    _prefs?.setBool('mqtt_enabled', value);
  }

  set secureConnection(bool value) {
    _secureConnection = value;
    _prefs?.setBool('mqtt_secure_connection', value);
  }

  // ---- connection ----

  /// Connect, serialising concurrent callers: a caller waits for any attempt
  /// in flight and then runs its own unless a connection now exists, or a
  /// disconnect() landed while it waited (epoch check).
  Future<bool> connect() async {
    final epoch = _connectEpoch;
    while (_pendingConnect != null) {
      await _pendingConnect;
      if (_connectEpoch != epoch) return false;
    }
    if (isConnected) return true;
    final attempt = _connect();
    _pendingConnect = attempt;
    try {
      return await attempt;
    } finally {
      _pendingConnect = null;
    }
  }

  void _fail(String message) {
    _lastErrorMessage = message;
    connectionStateNotifier.value = MqttConnectionStateEx.error;
  }

  Future<bool> _connect() async {
    if (_server.isEmpty || _port <= 0) return false;
    // Never dial the shipped production broker from a test run (review #94).
    if (Platform.environment.containsKey('FLUTTER_TEST') &&
        _server == _defaultServer) {
      debugPrint(
          'MQTT: refusing to dial the production broker from a test run');
      return false;
    }
    connectionStateNotifier.value = MqttConnectionStateEx.connecting;

    final client = MqttServerClient.withPort(_server, _clientId, _port)
      ..logging(on: false)
      ..keepAlivePeriod = 300
      ..secure = _secureConnection
      ..connectionMessage =
          MqttConnectMessage().withClientIdentifier(_clientId).startClean();
    // Callbacks capture THIS client so a stale one can't touch a newer link.
    client.onDisconnected = () => _onDisconnected(client);
    client.onConnected = () {
      if (identical(_client, client)) _onConnected();
    };
    _client = client;

    try {
      debugPrint('MQTT: connecting to $_server:$_port');
      await client.connect(_username, _password);
    } on NoConnectionException catch (e) {
      if (!identical(_client, client)) return false;
      debugPrint('MQTT: $e');
      _fail('Network error: Unable to connect');
    } on SocketException catch (e) {
      if (!identical(_client, client)) return false;
      _fail('Connection failed: ${e.message}');
    } on Exception catch (e) {
      // e.g. a HandshakeException escaping mqtt_client's socket onError path.
      if (!identical(_client, client)) return false;
      _fail(describeError(e).message);
    }
    if (!identical(_client, client)) return false;
    if (client.connectionStatus?.state == MqttConnectionState.connected) {
      return true;
    }
    _fail(describeMqttReturnCode(client.connectionStatus?.returnCode ??
        MqttConnectReturnCode.noneSpecified));
    return false;
  }

  void disconnect() {
    _connectEpoch++;
    final client = _client;
    if (client == null) return;
    _client = null;
    try {
      client.disconnect();
    } catch (e) {
      debugPrint('MQTT: disconnect error: $e');
    }
    connectionStateNotifier.value = MqttConnectionStateEx.disconnected;
  }

  void _onConnected() {
    _lastErrorMessage = '';
    connectionStateNotifier.value = MqttConnectionStateEx.connected;
  }

  void _onDisconnected(MqttServerClient client) {
    if (!identical(_client, client)) return;
    if (client.connectionStatus?.disconnectionOrigin ==
        MqttDisconnectionOrigin.solicited) {
      _client = null;
      connectionStateNotifier.value = MqttConnectionStateEx.disconnected;
      return;
    }
    Future.delayed(const Duration(seconds: 5), _reconnectLoop);
  }

  /// Bounded reconnect after an unsolicited drop (#37). A user disable or an
  /// explicit disconnect during the loop ends it without reporting an error.
  Future<void> _reconnectLoop() async {
    bool active() => _isEnabled && _client != null && !isConnected;
    var attempts = 0;
    while (active() && attempts < _maxReconnectAttempts) {
      attempts++;
      connectionStateNotifier.value = MqttConnectionStateEx.connecting;
      if (await connect() || attempts >= _maxReconnectAttempts) break;
      connectionStateNotifier.value = MqttConnectionStateEx.connecting;
      await Future.delayed(const Duration(seconds: 5));
    }
    if (active() && attempts >= _maxReconnectAttempts) {
      final cause = _lastErrorMessage.isNotEmpty ? ' ($_lastErrorMessage)' : '';
      _fail('Reconnection failed after $_maxReconnectAttempts attempts$cause');
    }
  }

  void dispose() => disconnect();

  // ---- publishing ----

  /// Publish (retained) to `rcj_soccer/<field topic>/<topic>`.
  void publishCMMessage(String message, {required String topic}) {
    final client = _client;
    if (!_isEnabled || client == null || !isConnected) return;
    final full =
        _topic.isNotEmpty ? '$_mainTopic/$_topic/$topic' : '$_mainTopic/$topic';
    final payload = (MqttClientPayloadBuilder()..addString(message)).payload!;
    client.publishMessage(full, MqttQos.atLeastOnce, payload, retain: true);
  }

  void publishTime(int remainingTime) =>
      publishCMMessage(formatClock(remainingTime), topic: 'time');

  void publishScore(List<Team> teams) {
    publishCMMessage('${teams[0].score}', topic: 'team1_score');
    publishCMMessage('${teams[1].score}', topic: 'team2_score');
  }

  void publishTeamNames(List<Team> teams) {
    String clip(String s) => s.length > 20 ? s.substring(0, 20) : s;
    publishCMMessage(clip(teams[0].name), topic: 'team1_name');
    publishCMMessage(clip(teams[1].name), topic: 'team2_name');
  }

  void publishTeam(List<Team> teams) {
    if (teams.length < 2) return;
    publishCMMessage(teams[0].id, topic: 'team1_id');
    publishCMMessage(teams[1].id, topic: 'team2_id');
  }

  void publishGameState(MatchStage state) => publishCMMessage(
        switch (state) {
          MatchStage.firstHalf => '1. Half',
          MatchStage.halfTime => 'Half-Time',
          MatchStage.secondHalf => '2. Half',
          MatchStage.fullTime => 'Game Over',
        },
        topic: 'game_stage',
      );
}
