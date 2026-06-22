import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:rcj_scoreboard/models/scoreboard_result.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class ScoreboardResultService with ChangeNotifier {
  static const _prefsTokenKey = 'scoreboard_token';
  static const _prefsBaseUrlKey = 'scoreboard_base_url';
  static const _prefsOutboxKey = 'scoreboard_result_outbox';
  static const _prefsMatchKey = 'scoreboard_match_config';
  static const _bearerScheme = '\u0042earer';
  static const _fallbackLinkScheme = 'rcjrefmate';
  static const _retryInterval = Duration(seconds: 20);

  final AppLinks _appLinks = AppLinks();
  final Uuid _uuid = const Uuid();

  SharedPreferences? _prefs;
  StreamSubscription<Uri>? _linkSub;
  Timer? _retryTimer;

  String? _token;
  Uri _baseUri = Uri.https('scoreboard.junior.robocup.org');
  ScoreboardMatchConfig? _matchConfig;
  List<ResultOutboxItem> _outbox = [];
  bool _isSubmitting = false;
  String _statusMessage = 'Waiting for referee app link';

  String _authValue(String token) => '$_bearerScheme $token';

  ScoreboardMatchConfig? get matchConfig => _matchConfig;
  String get statusMessage => _statusMessage;
  bool get hasToken => _token != null && _token!.isNotEmpty;
  bool get hasConflict => conflictCount > 0;
  int get pendingCount =>
      _outbox.where((item) => item.state == ResultSubmissionState.pending).length;
  int get conflictCount => _outbox
      .where((item) => item.state == ResultSubmissionState.conflict)
      .length;
  int get submittedCount => _outbox
      .where((item) => item.state == ResultSubmissionState.submitted)
      .length;
  List<ResultOutboxItem> get outbox => List.unmodifiable(_outbox);

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    _token = _prefs!.getString(_prefsTokenKey);

    final baseUrl = _prefs!.getString(_prefsBaseUrlKey);
    if (baseUrl != null && baseUrl.isNotEmpty) {
      final parsed = Uri.tryParse(baseUrl);
      if (parsed != null && parsed.host.isNotEmpty) {
        _baseUri = parsed;
      }
    }

    final outboxRaw = _prefs!.getString(_prefsOutboxKey);
    if (outboxRaw != null && outboxRaw.isNotEmpty) {
      try {
        final list = jsonDecode(outboxRaw) as List<dynamic>;
        _outbox = list
            .whereType<Map>()
            .map((item) =>
                ResultOutboxItem.fromJson(Map<String, dynamic>.from(item)))
            .toList();
      } catch (e) {
        debugPrint('ScoreboardResultService: outbox parse failed: $e');
      }
    }

    final storedMatchRaw = _prefs!.getString(_prefsMatchKey);
    if (storedMatchRaw != null && storedMatchRaw.isNotEmpty) {
      try {
        final json = jsonDecode(storedMatchRaw);
        if (json is Map) {
          _matchConfig =
              ScoreboardMatchConfig.fromJson(Map<String, dynamic>.from(json));
        }
      } catch (e) {
        debugPrint('ScoreboardResultService: match parse failed: $e');
      }
    }

    await _attachDeepLinkListener();
    _startRetryLoop();

    if (hasToken) {
      unawaited(refreshMatchConfig().catchError((error) {
        debugPrint('ScoreboardResultService: initial refresh failed: $error');
      }));
      unawaited(processOutbox().catchError((error) {
        debugPrint('ScoreboardResultService: initial outbox run failed: $error');
      }));
    } else if (_matchConfig != null) {
      _statusMessage = 'Stored match ready; open a new referee link when needed';
      notifyListeners();
    }
  }

  void disposeService() {
    _retryTimer?.cancel();
    _linkSub?.cancel();
  }

  Future<void> _attachDeepLinkListener() async {
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        await handleDeepLink(initialUri);
      }
    } catch (e) {
      debugPrint('ScoreboardResultService: initial link failed: $e');
    }

    _linkSub?.cancel();
    _linkSub = _appLinks.uriLinkStream.listen(
      (uri) {
        unawaited(handleDeepLink(uri).catchError((error) {
          debugPrint('ScoreboardResultService: deep link handling failed: $error');
        }));
      },
      onError: (error) =>
          debugPrint('ScoreboardResultService: link stream failed: $error'),
    );
  }

  Future<void> handleDeepLink(Uri uri) async {
    final parsed = _parseDeepLink(uri);
    if (parsed == null) return;

    final rawToken = parsed.token;
    if (rawToken.isEmpty) return;

    _token = rawToken;
    _baseUri = parsed.baseUri;
    _statusMessage = 'Referee link received';

    await _prefs?.setString(_prefsTokenKey, rawToken);
    await _prefs?.setString(_prefsBaseUrlKey, _baseUri.toString());

    notifyListeners();
    await refreshMatchConfig();
  }

  ({String token, Uri baseUri})? _parseDeepLink(Uri uri) {
    if (uri.scheme == 'https') {
      if (uri.pathSegments.length < 2 || uri.pathSegments.first != 'r') {
        return null;
      }
      final token = Uri.decodeComponent(uri.pathSegments[1]).trim();
      if (token.isEmpty || uri.host.isEmpty) return null;
      return (
        token: token,
        baseUri: Uri(
          scheme: 'https',
          host: uri.host,
          port: uri.hasPort ? uri.port : null,
        ),
      );
    }

    if (uri.scheme != _fallbackLinkScheme) return null;

    if (uri.host != 'r' || uri.pathSegments.isEmpty) return null;

    final token = Uri.decodeComponent(uri.pathSegments.first).trim();
    Uri? baseUri;

    final rawBaseUrl = uri.queryParameters['base_url']?.trim();
    if (kDebugMode && rawBaseUrl != null && rawBaseUrl.isNotEmpty) {
      final decodedBase = Uri.decodeComponent(rawBaseUrl);
      final parsedBase = Uri.tryParse(decodedBase);
      if (parsedBase != null &&
          parsedBase.host.isNotEmpty &&
          (parsedBase.scheme == 'http' || parsedBase.scheme == 'https')) {
        baseUri = parsedBase.replace(path: '', query: null, fragment: null);
      }
    }

    if (token.isEmpty) return null;
    return (token: token, baseUri: baseUri ?? _baseUri);
  }

  Future<void> refreshMatchConfig() async {
    final token = _token;
    if (token == null || token.isEmpty) {
      _statusMessage = 'No referee token';
      notifyListeners();
      return;
    }

    final endpoint = _baseUri.replace(path: '/api/v1/soccer/match');

    try {
      final response = await http.get(
        endpoint,
        headers: {'Authorization': _authValue(token)},
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json is Map<String, dynamic>) {
          _matchConfig = ScoreboardMatchConfig.fromJson(json);
          await _prefs?.setString(_prefsMatchKey, jsonEncode(json));
          _statusMessage = _matchConfig!.matchCode.isEmpty
              ? 'Match loaded'
              : 'Match loaded (${_matchConfig!.matchCode})';
        } else {
          _statusMessage = 'Invalid match payload';
        }
      } else if (response.statusCode == 401) {
        _statusMessage = 'Referee token is invalid or expired';
      } else {
        _statusMessage = 'Match load failed (${response.statusCode})';
      }
    } catch (e) {
      _statusMessage = 'Match load failed (network)';
      debugPrint('ScoreboardResultService: match load failed: $e');
    }

    notifyListeners();
  }

  Future<bool> enqueueFinalResult({
    required int homeGoals,
    required int awayGoals,
    String? comment,
  }) async {
    final token = _token;
    final matchConfig = _matchConfig;
    if (token == null || token.isEmpty || matchConfig == null) {
      return false;
    }

    final alreadyTracked = _outbox.any((item) =>
        item.matchCode == matchConfig.matchCode &&
        item.state != ResultSubmissionState.failed);
    if (alreadyTracked) {
      _statusMessage = 'Result already queued or submitted';
      notifyListeners();
      return false;
    }

    final item = ResultOutboxItem(
      id: _uuid.v4(),
      baseUrl: _baseUri.toString(),
      token: token,
      matchCode: matchConfig.matchCode,
      homeGoals: homeGoals,
      awayGoals: awayGoals,
      version: matchConfig.version,
      idempotencyKey: _uuid.v4(),
      comment: comment,
      state: ResultSubmissionState.pending,
      responseStatus: null,
      responseBody: null,
      errorMessage: null,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );

    _outbox = [..._outbox, item];
    _statusMessage = 'Final result queued for sync';
    await _persistOutbox();
    notifyListeners();

    unawaited(processOutbox());
    return true;
  }

  Future<void> retryPendingNow() async {
    await processOutbox();
  }

  Future<void> processOutbox() async {
    if (_isSubmitting) return;
    _isSubmitting = true;
    try {
      while (true) {
        final pendingIndex = _outbox
            .indexWhere((item) => item.state == ResultSubmissionState.pending);
        if (pendingIndex < 0) break;
        final pendingItem = _outbox[pendingIndex];
        await _submitItem(pendingIndex, pendingItem);
      }
    } finally {
      _isSubmitting = false;
      notifyListeners();
    }
  }

  void _startRetryLoop() {
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(
      _retryInterval,
      (_) => processOutbox(),
    );
  }

  Future<void> _submitItem(int index, ResultOutboxItem item) async {
    final endpoint = Uri.parse(item.baseUrl).replace(
      path: '/api/v1/soccer/match/result',
    );
    final payload = {
      'home_goals': item.homeGoals,
      'away_goals': item.awayGoals,
      'version': item.version,
      'idempotency_key': item.idempotencyKey,
      if (item.comment?.isNotEmpty ?? false) 'comment': item.comment,
    };

    try {
      final response = await http.post(
        endpoint,
        headers: {
          'Authorization': _authValue(item.token),
          'Content-Type': 'application/json',
        },
        body: jsonEncode(payload),
      );

      Map<String, dynamic>? body;
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) body = decoded;
      } catch (e) {
        debugPrint('ScoreboardResultService: response parse failed: $e');
      }

      if (response.statusCode == 200) {
        _outbox[index] = item.copyWith(
          state: ResultSubmissionState.submitted,
          responseStatus: response.statusCode,
          responseBody: body,
          errorMessage: null,
        );
        _statusMessage = 'Final result submitted';
        _updateMatchVersionFromResponse(body);
      } else if (response.statusCode == 409) {
        _outbox[index] = item.copyWith(
          state: ResultSubmissionState.conflict,
          responseStatus: response.statusCode,
          responseBody: body,
          errorMessage: body?['reason']?.toString() ?? 'conflict',
        );
        _statusMessage = 'Final result requires manual review';
      } else if (response.statusCode == 401 || response.statusCode == 422) {
        _outbox[index] = item.copyWith(
          state: ResultSubmissionState.failed,
          responseStatus: response.statusCode,
          responseBody: body,
          errorMessage: body?['reason']?.toString() ?? 'request rejected',
        );
        _statusMessage = 'Final result rejected (${response.statusCode})';
      } else {
        _outbox[index] = item.copyWith(
          state: ResultSubmissionState.pending,
          responseStatus: response.statusCode,
          responseBody: body,
          errorMessage: 'temporary_error_${response.statusCode}',
        );
        _statusMessage = 'Final result sync will retry';
      }
    } catch (e) {
      _outbox[index] = item.copyWith(
        state: ResultSubmissionState.pending,
        errorMessage: 'network_error',
      );
      _statusMessage = 'Final result sync offline; retrying';
      debugPrint('ScoreboardResultService: submit failed: $e');
    }

    await _persistOutbox();
    notifyListeners();
  }

  Future<void> _persistOutbox() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final encoded = jsonEncode(_outbox.map((item) => item.toJson()).toList());
    await prefs.setString(_prefsOutboxKey, encoded);
  }

  void _updateMatchVersionFromResponse(Map<String, dynamic>? body) {
    final matchConfig = _matchConfig;
    if (matchConfig == null || body == null) return;
    final nextVersion = (body['version'] as num?)?.toInt();
    if (nextVersion == null) return;

    _matchConfig = ScoreboardMatchConfig(
      matchCode: matchConfig.matchCode,
      homeTeamName: matchConfig.homeTeamName,
      awayTeamName: matchConfig.awayTeamName,
      homeIsLeft: matchConfig.homeIsLeft,
      venueShortName: matchConfig.venueShortName,
      scheduledStart: matchConfig.scheduledStart,
      durationSeconds: matchConfig.durationSeconds,
      timezone: matchConfig.timezone,
      version: nextVersion,
      status: 'COMPLETED',
    );
    _prefs?.setString(_prefsMatchKey, jsonEncode(_matchConfig!.toJson()));
  }
}
