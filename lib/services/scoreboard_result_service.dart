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
  static const _customLinkScheme = 'rcjrefmate';
  static final Uri _defaultBaseUri = Uri.https('scoreboard.junior.robocup.org');
  static const _retryInterval = Duration(seconds: 20);
  static const _maxSubmissionRetries = 5;
  // Bounded per-request timeout, kept below _retryInterval so a hung request
  // releases _isSubmitting before the next periodic retry tick fires.
  static const _requestTimeout = Duration(seconds: 15);

  final AppLinks _appLinks = AppLinks();
  final Uuid _uuid = const Uuid();

  SharedPreferences? _prefs;
  StreamSubscription<Uri>? _linkSub;
  Timer? _retryTimer;

  String? _token;
  Uri _baseUri = _defaultBaseUri;
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
      // Surface a stored match immediately so Game applies the persisted
      // names/timing on a cold start (including offline), instead of showing
      // defaults until the background refresh returns or times out. The
      // stale-response guard in refreshMatchConfig keeps the eventual network
      // result authoritative.
      if (_matchConfig != null) {
        notifyListeners();
      }
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

    final tokenChanged = rawToken != _token;
    _token = rawToken;
    _baseUri = parsed.baseUri;
    _statusMessage = 'Referee link received';

    if (tokenChanged) {
      // Drop the previous match config the moment a different link arrives, so a
      // slow or failing fetch under the new token cannot leave the new token
      // paired with the old match's matchCode/version (which enqueueFinalResult
      // would otherwise submit). The new config is repopulated by the fetch
      // below on success.
      _matchConfig = null;
      await _prefs?.remove(_prefsMatchKey);
    }

    await _prefs?.setString(_prefsTokenKey, rawToken);
    await _prefs?.setString(_prefsBaseUrlKey, _baseUri.toString());

    notifyListeners();
    await refreshMatchConfig();
  }

  /// Parses HTTPS referee links and the custom `rcjrefmate://r/<token>` links.
  ///
  /// Returns `null` for unsupported schemes/hosts/formats, and returns the
  /// extracted token + resolved base URI for valid links.
  /// Example (debug only base override):
  /// rcjrefmate://r/abc123?base_url=http://10.0.2.2:8080
  ({String token, Uri baseUri})? _parseDeepLink(Uri uri) {
    if (uri.scheme == 'https') {
      if (uri.pathSegments.length < 2 || uri.pathSegments.first != 'r') {
        return null;
      }
      final token = Uri.decodeComponent(uri.pathSegments[1]).trim();
      if (token.isEmpty || !_isAllowedHttpsHost(uri.host)) return null;
      return (
        token: token,
        baseUri: Uri(
          scheme: 'https',
          host: uri.host,
          port: uri.hasPort ? uri.port : null,
        ),
      );
    }

    if (uri.scheme != _customLinkScheme) return null;

    if (uri.host != 'r' || uri.pathSegments.isEmpty) return null;

    final token = Uri.decodeComponent(uri.pathSegments.first).trim();
    Uri? baseUri;

    final rawBaseUrl = uri.queryParameters['base_url']?.trim();
    if (kDebugMode && rawBaseUrl != null && rawBaseUrl.isNotEmpty) {
      if (rawBaseUrl.startsWith('http://') ||
          rawBaseUrl.startsWith('https://')) {
        final parsedBase = Uri.tryParse(rawBaseUrl);
        if (parsedBase != null &&
            parsedBase.host.isNotEmpty &&
            (parsedBase.scheme == 'http' || parsedBase.scheme == 'https') &&
            _isAllowedLocalDebugBaseUri(parsedBase)) {
          baseUri = parsedBase.replace(path: '', query: null, fragment: null);
        }
      }
    }

    if (token.isEmpty) return null;
    return (token: token, baseUri: baseUri ?? _defaultBaseUri);
  }

  bool _isAllowedLocalDebugBaseUri(Uri uri) {
    final host = uri.host.toLowerCase();
    // Debug-only local hosts; any port is allowed for local test servers.
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        // Android emulator alias for host machine loopback.
        host == '10.0.2.2' ||
        _isPrivateIpv4Host(host);
  }

  bool _isAllowedHttpsHost(String host) {
    final normalizedHost = host.toLowerCase();
    return normalizedHost == _defaultBaseUri.host.toLowerCase();
  }

  bool _isPrivateIpv4Host(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return false;

    final octets = <int>[];
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return false;
      octets.add(value);
    }

    // RFC 1918: 10.0.0.0/8, 192.168.0.0/16, 172.16.0.0/12.
    if (octets[0] == 10) return true;
    if (octets[0] == 192 && octets[1] == 168) return true;
    if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) return true;
    return false;
  }

  Future<void> refreshMatchConfig() async {
    final token = _token;
    if (token == null || token.isEmpty) {
      _statusMessage = 'No referee token';
      notifyListeners();
      return;
    }

    final requestBase = _baseUri;
    final endpoint = requestBase.replace(path: '/api/v1/soccer/match/');

    try {
      final response = await http
          .get(
            endpoint,
            headers: {'Authorization': _authValue(token)},
          )
          .timeout(_requestTimeout);

      // Discard a stale response: a newer link or a clear may have changed the
      // active token/base URL while this request was in flight. Applying it now
      // would pair the current token with a different (or cleared) match.
      if (_token != token || _baseUri != requestBase) {
        return;
      }

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

    // Treat a retry-exhausted (revivable) failed item as tracked: it still
    // represents this match and can be re-sent via retryPendingNow, so a second
    // enqueue would create a second outbox item with a fresh idempotency_key and
    // allow two distinct final-result submissions for the same match. "Exhausted"
    // is identified by the internal retryCount, not the free-text errorMessage
    // (which on 401/422 comes from server-controlled body['reason']), so genuine
    // rejections stay non-tracked and replaceable by a fresh enqueue.
    final alreadyTracked = _outbox.any((item) =>
        item.matchCode == matchConfig.matchCode &&
        (item.state != ResultSubmissionState.failed ||
            item.retryCount >= _maxSubmissionRetries));
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
    // Revive submissions that exhausted their automatic transient-failure
    // retries so the operator can re-attempt them manually after, e.g., a long
    // network outage. "Exhausted" is keyed on the internal retryCount, not the
    // server-influenced errorMessage; terminal rejections (401/422) keep their
    // low retryCount and deliberately stay failed.
    var revived = false;
    for (var i = 0; i < _outbox.length; i++) {
      final item = _outbox[i];
      if (item.state == ResultSubmissionState.failed &&
          item.retryCount >= _maxSubmissionRetries) {
        _outbox[i] = item.copyWith(
          state: ResultSubmissionState.pending,
          retryCount: 0,
          clearError: true,
          clearResponse: true,
        );
        revived = true;
      }
    }
    if (revived) {
      _statusMessage = 'Retrying final result sync';
      await _persistOutbox();
      notifyListeners();
    }
    await processOutbox();
  }

  Future<void> clearLinkedMatchData() async {
    _token = null;
    _baseUri = _defaultBaseUri;
    _matchConfig = null;
    _outbox = [];
    _statusMessage = 'Waiting for referee app link';

    final prefs = _prefs;
    if (prefs != null) {
      await prefs.remove(_prefsTokenKey);
      await prefs.remove(_prefsBaseUrlKey);
      await prefs.remove(_prefsMatchKey);
      await prefs.remove(_prefsOutboxKey);
    }

    notifyListeners();
  }

  Future<void> processOutbox() async {
    if (_isSubmitting) return;
    _isSubmitting = true;
    try {
      // Snapshot pending item *ids*, not list indexes: the outbox list can be
      // replaced while a submission is suspended on an awaited HTTP call (e.g.
      // the Settings "Clear linked match" action calling clearLinkedMatchData,
      // or enqueueFinalResult appending a new item). A captured index would then
      // point at the wrong item or be out of range. Items added/changed mid-run
      // are handled by the next periodic/manual outbox run.
      final pendingIds = [
        for (final item in _outbox)
          if (item.state == ResultSubmissionState.pending) item.id,
      ];
      for (final id in pendingIds) {
        await _submitItem(id);
      }
      if (_shouldClearLinkedDataAfterSubmission()) {
        await clearLinkedMatchData();
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

  Future<void> _submitItem(String id) async {
    final startIndex = _outbox.indexWhere((entry) => entry.id == id);
    if (startIndex == -1) return;
    final item = _outbox[startIndex];

    final endpoint = Uri.parse(item.baseUrl).replace(
      path: '/api/v1/soccer/match/result/',
    );
    final payload = {
      'home_goals': item.homeGoals,
      'away_goals': item.awayGoals,
      'version': item.version,
      'idempotency_key': item.idempotencyKey,
      if (item.comment?.isNotEmpty ?? false) 'comment': item.comment,
    };

    try {
      final response = await http
          .post(
            endpoint,
            headers: {
              'Authorization': _authValue(item.token),
              'Content-Type': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(_requestTimeout);

      Map<String, dynamic>? body;
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) body = decoded;
      } catch (e) {
        debugPrint('ScoreboardResultService: response parse failed: $e');
      }

      // Re-find the item by id: the outbox may have been replaced while awaiting
      // the response (e.g. a manual clear). If it is gone, drop this result.
      final index = _outbox.indexWhere((entry) => entry.id == id);
      if (index == -1) return;

      if (response.statusCode == 200) {
        _outbox[index] = item.copyWith(
          state: ResultSubmissionState.submitted,
          responseStatus: response.statusCode,
          responseBody: body,
          clearError: true,
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
        _markRetriableFailure(
          index: index,
          item: item,
          responseStatus: response.statusCode,
          responseBody: body,
          errorMessage: 'temporary_error_${response.statusCode}',
        );
      }
    } catch (e) {
      // Re-find the item by id after the awaited request threw (the outbox may
      // have been cleared meanwhile).
      final index = _outbox.indexWhere((entry) => entry.id == id);
      if (index != -1) {
        _markRetriableFailure(
          index: index,
          item: item,
          errorMessage: 'network_error',
        );
      }
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

  void _markRetriableFailure({
    required int index,
    required ResultOutboxItem item,
    int? responseStatus,
    Map<String, dynamic>? responseBody,
    required String errorMessage,
  }) {
    final nextRetryCount = item.retryCount + 1;
    if (nextRetryCount >= _maxSubmissionRetries) {
      _outbox[index] = item.copyWith(
        state: ResultSubmissionState.failed,
        retryCount: nextRetryCount,
        responseStatus: responseStatus,
        responseBody: responseBody,
        errorMessage: 'max_retries_reached',
      );
      _statusMessage = 'Final result sync failed after $nextRetryCount attempts';
      return;
    }

    _outbox[index] = item.copyWith(
      state: ResultSubmissionState.pending,
      retryCount: nextRetryCount,
      responseStatus: responseStatus,
      responseBody: responseBody,
      errorMessage: errorMessage,
    );
    _statusMessage = 'Final result sync will retry ($nextRetryCount/$_maxSubmissionRetries)';
  }

  void _updateMatchVersionFromResponse(Map<String, dynamic>? body) {
    final matchConfig = _matchConfig;
    if (matchConfig == null || body == null) return;
    final nextVersion = (body['version'] as num?)?.toInt();
    if (nextVersion == null) return;

    _matchConfig = matchConfig.copyWith(
      version: nextVersion,
      status: 'COMPLETED',
    );
    _prefs?.setString(_prefsMatchKey, jsonEncode(_matchConfig!.toJson()));
  }

  bool _shouldClearLinkedDataAfterSubmission() {
    // Only auto-clear once EVERY queued result is submitted. The previous check
    // (any submitted && none pending/conflict) ignored terminal `failed` items,
    // so a different match's rejected result would be silently wiped — and the
    // outbox is its only persisted copy — the moment any other item succeeded.
    return _outbox.isNotEmpty &&
        _outbox.every(
            (entry) => entry.state == ResultSubmissionState.submitted);
  }
}
