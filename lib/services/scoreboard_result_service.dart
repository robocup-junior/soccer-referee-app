import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:rcj_scoreboard/models/scoreboard_result.dart';
import 'package:rcj_scoreboard/services/referee_link.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// The scoreboard referee-link integration: receives deep links, stages a
/// fixture for the "Load match?" confirmation, holds the committed fixture,
/// and delivers final results through a persisted, retrying outbox.
///
/// Two fixtures can be in play: the COMMITTED one ([matchConfig], with its
/// token) and a PENDING one staged by a newer link. Every network reply is
/// checked against the identity it was requested for before being applied.
class ScoreboardResultService with ChangeNotifier {
  static const _tokenKey = 'scoreboard_token';
  static const _baseUrlKey = 'scoreboard_base_url';
  static const _outboxKey = 'scoreboard_result_outbox';
  static const _matchKey = 'scoreboard_match_config';
  static final Uri _defaultBaseUri = Uri.https('scoreboard.junior.robocup.org');
  static const _retryInterval = Duration(seconds: 20);
  static const _maxSubmissionRetries = 5;
  // Below _retryInterval so a hung request releases the lock before the tick.
  static const _requestTimeout = Duration(seconds: 15);

  ScoreboardResultService({http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null;

  final AppLinks _appLinks = AppLinks();
  final Uuid _uuid = const Uuid();
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  SharedPreferences? _prefs;
  StreamSubscription<Uri>? _linkSub;
  Timer? _retryTimer;

  String? _token;
  Uri _baseUri = _defaultBaseUri;
  ScoreboardMatchConfig? _matchConfig;
  String? _pendingToken;
  Uri? _pendingBaseUri;
  ScoreboardMatchConfig? _pendingMatchConfig;
  List<ResultOutboxItem> _outbox = [];
  bool _isSubmitting = false;
  String _statusMessage = 'Awaiting link';

  /// Fired once when the committed match's result is confirmed delivered
  /// (HTTP 200) — never for a queued/failed/conflicted one or a late response
  /// for a replaced match.
  void Function()? onCurrentResultDelivered;

  ScoreboardMatchConfig? get matchConfig => _matchConfig;
  ScoreboardMatchConfig? get pendingMatchConfig => _pendingMatchConfig;
  String get statusMessage => _statusMessage;
  bool get hasToken => _token?.isNotEmpty ?? false;
  List<ResultOutboxItem> get outbox => List.unmodifiable(_outbox);
  bool get hasConflict => conflictCount > 0;
  int get pendingCount => _count(ResultSubmissionState.pending);
  int get conflictCount => _count(ResultSubmissionState.conflict);
  int get submittedCount => _count(ResultSubmissionState.submitted);

  /// Items not yet confirmed delivered; "Clear linked match" wipes them.
  int get undeliveredCount =>
      _outbox.where((i) => i.state != ResultSubmissionState.submitted).length;

  int _count(ResultSubmissionState state) =>
      _outbox.where((i) => i.state == state).length;

  /// Any outbox item for [matchCode] (audit view; tests only).
  @visibleForTesting
  bool hasResultFor(String matchCode) =>
      _outbox.any((i) => i.matchCode == matchCode);

  /// True if THIS run (same token, #68) has an item for [matchCode] that blocks
  /// re-opening the result review. A terminal 401/422 rejection does not
  /// block: it is correctable and re-submittable (RAVF002).
  bool hasUnresolvedResultFor(String matchCode) => _outbox.any((i) =>
      i.matchCode == matchCode && i.token == _token && !_isTerminalRejection(i));

  static bool _isTerminalRejection(ResultOutboxItem i) =>
      i.state == ResultSubmissionState.failed &&
      (i.responseStatus == 401 || i.responseStatus == 422);

  /// Test seam: surface a committed config as a deep link / persisted load
  /// would, without the app_links channel or network I/O.
  @visibleForTesting
  void debugApplyMatchConfig(ScoreboardMatchConfig config, {String? token, Uri? baseUri}) {
    _matchConfig = config;
    if (token != null) _token = token;
    if (baseUri != null) _baseUri = baseUri;
    notifyListeners();
  }

  @visibleForTesting
  void debugApplyPendingMatchConfig(ScoreboardMatchConfig config,
      {required String token, required Uri baseUri}) {
    _pendingToken = token;
    _pendingBaseUri = baseUri;
    _pendingMatchConfig = config;
    _statusMessage = 'Confirm to load match';
    notifyListeners();
  }

  /// Poll this match's outbox item until it leaves `pending` or [timeout]
  /// elapses (null = still pending).
  Future<ResultSubmissionState?> awaitOutboxOutcome(String matchCode,
      {Duration timeout = const Duration(seconds: 4)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final item = _outbox.where((i) => i.matchCode == matchCode).lastOrNull;
      if (item != null && item.state != ResultSubmissionState.pending) return item.state;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  // ---- startup / persistence ----

  Future<void> initialize() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_tokenKey);
    final base = Uri.tryParse(prefs.getString(_baseUrlKey) ?? '');
    if (base != null && base.host.isNotEmpty) _baseUri = base;
    _outbox = _decodeOutbox(prefs.getString(_outboxKey));
    _matchConfig = _decodeConfig(prefs.getString(_matchKey));

    await _attachDeepLinkListener();
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(_retryInterval, (_) => processOutbox());

    if (hasToken) {
      // Surface the stored match at once (also offline); the network refresh
      // stays authoritative via its stale-response guard.
      final submitted = _submittedStatusForCommittedMatch();
      if (submitted != null) _statusMessage = submitted;
      if (_matchConfig != null || submitted != null) notifyListeners();
      unawaited(_logged(refreshMatchConfig(), 'initial refresh'));
      unawaited(_logged(processOutbox(), 'initial outbox run'));
    } else if (_matchConfig != null) {
      _statusMessage = 'Stored match ready';
      notifyListeners();
    }
  }

  static Future<void> _logged(Future<void> f, String what) => f.catchError(
      (Object e) => debugPrint('ScoreboardResultService: $what failed: $e'));

  /// Items are parsed one by one so a single corrupt entry can't strand the
  /// whole outbox.
  static List<ResultOutboxItem> _decodeOutbox(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final items = <ResultOutboxItem>[];
      for (final e in decoded.whereType<Map>()) {
        try {
          items.add(ResultOutboxItem.fromJson(Map<String, dynamic>.from(e)));
        } catch (err) {
          debugPrint('ScoreboardResultService: skipping malformed outbox item: $err');
        }
      }
      return items;
    } catch (e) {
      debugPrint('ScoreboardResultService: outbox parse failed: $e');
      return [];
    }
  }

  static ScoreboardMatchConfig? _decodeConfig(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      return json is Map
          ? ScoreboardMatchConfig.fromJson(Map<String, dynamic>.from(json))
          : null;
    } catch (e) {
      debugPrint('ScoreboardResultService: match parse failed: $e');
      return null;
    }
  }

  Future<void> _persistOutbox() async {
    await _prefs?.setString(
        _outboxKey, jsonEncode(_outbox.map((i) => i.toJson()).toList()));
  }

  Future<void> _persistConfig(ScoreboardMatchConfig config) async {
    await _prefs?.setString(_matchKey, jsonEncode(config.toJson()));
  }

  void disposeService() {
    _retryTimer?.cancel();
    _linkSub?.cancel();
    if (_ownsHttpClient) _httpClient.close();
  }

  // ---- deep links ----

  Future<void> _attachDeepLinkListener() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) await handleDeepLink(initial);
    } catch (e) {
      debugPrint('ScoreboardResultService: initial link failed: $e');
    }
    _linkSub?.cancel();
    _linkSub = _appLinks.uriLinkStream.listen(
      (uri) => unawaited(_logged(handleDeepLink(uri), 'deep link handling')),
      onError: (Object e) => debugPrint('ScoreboardResultService: link stream failed: $e'),
    );
  }

  /// Stage the link's fixture as PENDING and fetch its config; the committed
  /// fixture is untouched until [confirmPendingMatch].
  Future<void> handleDeepLink(Uri uri) async {
    final link = parseRefereeLink(uri, defaultBase: _defaultBaseUri);
    if (link == null) return;
    _pendingToken = link.token;
    _pendingBaseUri = link.baseUri;
    _pendingMatchConfig = null;
    _statusMessage = 'Confirm to load match';
    notifyListeners();

    final outcome = await _requestMatchConfig(link.token, link.baseUri);
    // A newer link or a confirm/cancel may have replaced the pending target.
    if (_pendingToken != link.token || _pendingBaseUri != link.baseUri) return;
    _pendingMatchConfig = outcome.config;
    _statusMessage = outcome.config != null ? 'Confirm to load match' : outcome.status;
    notifyListeners();
  }

  /// GET the fixture for [token] at [base]; `status` describes a failure.
  Future<({ScoreboardMatchConfig? config, String status})> _requestMatchConfig(
      String token, Uri base) async {
    try {
      final response = await _httpClient.get(
        base.replace(path: '/api/v1/soccer/match/'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(_requestTimeout);
      return switch (response.statusCode) {
        200 => switch (jsonDecode(response.body)) {
            final Map<String, dynamic> json => (
                config: ScoreboardMatchConfig.fromJson(json),
                status: 'Match loaded'
              ),
            _ => (config: null, status: 'Bad match data'),
          },
        401 => (config: null, status: 'Link expired'),
        final code => (config: null, status: 'Load failed ($code)'),
      };
    } catch (e) {
      debugPrint('ScoreboardResultService: match load failed: $e');
      return (config: null, status: 'Load failed (net)');
    }
  }

  Future<void> refreshMatchConfig() async {
    final token = _token;
    if (token == null || token.isEmpty) {
      _statusMessage = 'No link';
      notifyListeners();
      return;
    }
    final base = _baseUri;
    final outcome = await _requestMatchConfig(token, base);
    // Discard a stale response (a newer link or a clear changed the target).
    if (_token != token || _baseUri != base) return;
    final config = outcome.config;
    if (config != null) {
      _matchConfig = config;
      await _persistConfig(config);
      _statusMessage = _committedMatchStatus();
    } else {
      _statusMessage = outcome.status;
    }
    notifyListeners();
  }

  /// '✓ Submitted <code>' if THIS run already delivered the committed match.
  String? _submittedStatusForCommittedMatch() {
    final config = _matchConfig;
    if (config == null) return null;
    final delivered = _outbox.any((i) =>
        i.matchCode == config.matchCode &&
        i.token == _token &&
        i.state == ResultSubmissionState.submitted);
    return delivered ? '✓ Submitted ${config.matchCode}' : null;
  }

  String _committedMatchStatus() => _submittedStatusForCommittedMatch() ??
      (_matchConfig == null ? 'Awaiting link' : 'Match loaded');

  void _clearPending() {
    _pendingToken = null;
    _pendingBaseUri = null;
    _pendingMatchConfig = null;
  }

  /// Promote the pending fixture to committed. [expectedSignature] guards a
  /// stale dialog: nothing happens if the pending fixture changed.
  Future<void> confirmPendingMatch({String? expectedSignature}) async {
    final token = _pendingToken;
    final base = _pendingBaseUri;
    final config = _pendingMatchConfig;
    if (token == null || token.isEmpty || base == null || config == null) {
      _statusMessage = _committedMatchStatus();
      notifyListeners();
      return;
    }
    if (expectedSignature != null && config.signature != expectedSignature) {
      notifyListeners();
      return;
    }
    // Swap in memory SYNCHRONOUSLY: a link arriving during the awaits below
    // re-stages a new pending fixture that must not be wiped.
    _token = token;
    _baseUri = base;
    _matchConfig = config;
    _clearPending();
    _statusMessage = 'Match loaded';
    notifyListeners();

    // Old config removed FIRST, new one written LAST, so a kill in between
    // never pairs the new token with the previous fixture on disk.
    await _prefs?.remove(_matchKey);
    await _prefs?.setString(_tokenKey, token);
    await _prefs?.setString(_baseUrlKey, base.toString());
    await _persistConfig(config);
    unawaited(processOutbox());
  }

  void cancelPendingMatch({String? expectedSignature}) {
    // A stale Cancel must not discard a newer link (still fetching = null).
    if (expectedSignature != null &&
        _pendingMatchConfig?.signature != expectedSignature) {
      notifyListeners();
      return;
    }
    _clearPending();
    _statusMessage = _committedMatchStatus();
    notifyListeners();
  }

  /// Drop link, fixture, pending and the WHOLE outbox.
  Future<void> clearLinkedMatchData() => _unlink(keepOutbox: false);

  /// Drop the live link after a delivered result but KEEP the outbox as the
  /// audit trail (and so other undelivered items keep retrying).
  Future<void> resetLinkedMatchAfterSubmission() => _unlink(keepOutbox: true);

  Future<void> _unlink({required bool keepOutbox}) async {
    _token = null;
    _baseUri = _defaultBaseUri;
    _matchConfig = null;
    _clearPending();
    if (!keepOutbox) _outbox = [];
    _statusMessage = 'Awaiting link';
    final prefs = _prefs;
    if (prefs != null) {
      await prefs.remove(_tokenKey);
      await prefs.remove(_baseUrlKey);
      await prefs.remove(_matchKey);
      if (!keepOutbox) await prefs.remove(_outboxKey);
    }
    notifyListeners();
  }

  // ---- outbox ----

  Future<bool> enqueueFinalResult({
    required int homeGoals,
    required int awayGoals,
    String? comment,
    bool homeConfirmed = false,
    bool awayConfirmed = false,
    List<ActualModuleReport> actualHomeModules = const [],
    List<ActualModuleReport> actualAwayModules = const [],
  }) async {
    final token = _token;
    final config = _matchConfig;
    if (token == null || token.isEmpty || config == null) return false;

    // One submission per run: a retry-exhausted failure is still tracked
    // (revivable via retryPendingNow); a 401/422 rejection is replaceable.
    final tracked = _outbox.any((i) =>
        i.matchCode == config.matchCode &&
        i.token == token &&
        (i.state != ResultSubmissionState.failed ||
            i.retryCount >= _maxSubmissionRetries));
    if (tracked) {
      _statusMessage = 'Result already tracked';
      notifyListeners();
      return false;
    }

    final now = DateTime.now().toUtc();
    _outbox = [
      ..._outbox,
      ResultOutboxItem(
        id: _uuid.v4(),
        baseUrl: _baseUri.toString(),
        token: token,
        matchCode: config.matchCode,
        homeGoals: homeGoals,
        awayGoals: awayGoals,
        homeConfirmed: homeConfirmed,
        awayConfirmed: awayConfirmed,
        version: config.version,
        idempotencyKey: _uuid.v4(),
        comment: comment,
        actualHomeModules: actualHomeModules,
        actualAwayModules: actualAwayModules,
        state: ResultSubmissionState.pending,
        createdAt: now,
        updatedAt: now,
      ),
    ];
    _statusMessage = 'Result queued';
    await _persistOutbox();
    notifyListeners();
    unawaited(processOutbox());
    return true;
  }

  /// Revive retry-exhausted items (not 401/422 rejections) and run the outbox.
  Future<void> retryPendingNow() async {
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
      _statusMessage = 'Retrying…';
      await _persistOutbox();
      notifyListeners();
    }
    await processOutbox();
  }

  Future<void> processOutbox() async {
    if (_isSubmitting) return;
    _isSubmitting = true;
    try {
      // Snapshot ids, not indexes: the list can be replaced mid-await.
      final ids = [
        for (final i in _outbox)
          if (i.state == ResultSubmissionState.pending) i.id
      ];
      for (final id in ids) {
        await _submitItem(id);
      }
    } finally {
      _isSubmitting = false;
      notifyListeners();
    }
  }

  bool _isCurrentFixture(ResultOutboxItem item) =>
      _matchConfig?.matchCode == item.matchCode && _matchConfig?.version == item.version;

  Future<void> _submitItem(String id) async {
    final item = _outbox.where((i) => i.id == id).firstOrNull;
    if (item == null) return;
    final payload = {
      'home_goals': item.homeGoals,
      'away_goals': item.awayGoals,
      'home_confirmed': item.homeConfirmed,
      'away_confirmed': item.awayConfirmed,
      'version': item.version,
      'idempotency_key': item.idempotencyKey,
      if (item.comment?.isNotEmpty ?? false) 'comment': item.comment,
      // Submit-time module report (#85); omitted for legacy items.
      if (item.actualHomeModules.isNotEmpty || item.actualAwayModules.isNotEmpty)
        'actual_modules': {
          'home': item.actualHomeModules.map((m) => m.toJson()).toList(),
          'away': item.actualAwayModules.map((m) => m.toJson()).toList(),
        },
    };

    // The POST uses the item's OWN token/base, so it can complete after the
    // referee loaded another match; the visible status only changes while
    // the committed fixture is still this item's exact revision.
    try {
      final response = await _httpClient
          .post(
            Uri.parse(item.baseUrl).replace(path: '/api/v1/soccer/match/result/'),
            headers: {
              'Authorization': 'Bearer ${item.token}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(_requestTimeout);
      final body = _decodeBody(response.body);
      final index = _outbox.indexWhere((i) => i.id == id);
      if (index == -1) return; // cleared while in flight
      final current = _isCurrentFixture(item);
      final code = response.statusCode;
      switch (code) {
        case 200:
          _outbox[index] = item.copyWith(
              state: ResultSubmissionState.submitted,
              responseStatus: code,
              responseBody: body,
              clearError: true);
          if (current) {
            _statusMessage = '✓ Submitted ${item.matchCode}';
            _updateMatchVersionFromResponse(body);
            onCurrentResultDelivered?.call();
          }
        case 409:
          _outbox[index] = item.copyWith(
              state: ResultSubmissionState.conflict,
              responseStatus: code,
              responseBody: body,
              errorMessage: body?['reason']?.toString() ?? 'conflict');
          if (current) _statusMessage = 'Conflict — review';
        case 401 || 422:
          _outbox[index] = item.copyWith(
              state: ResultSubmissionState.failed,
              responseStatus: code,
              responseBody: body,
              errorMessage: body?['reason']?.toString() ?? 'request rejected');
          if (current) _statusMessage = 'Rejected ($code)';
        default:
          _markRetriableFailure(index, item, 'temporary_error_$code',
              responseStatus: code, responseBody: body, updateStatus: current);
      }
    } catch (e) {
      final index = _outbox.indexWhere((i) => i.id == id);
      if (index != -1) {
        _markRetriableFailure(index, item, 'network_error',
            updateStatus: _isCurrentFixture(item));
      }
      debugPrint('ScoreboardResultService: submit failed: $e');
    }
    await _persistOutbox();
    notifyListeners();
  }

  static Map<String, dynamic>? _decodeBody(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e) {
      debugPrint('ScoreboardResultService: response parse failed: $e');
      return null;
    }
  }

  void _markRetriableFailure(int index, ResultOutboxItem item, String error,
      {int? responseStatus, Map<String, dynamic>? responseBody, required bool updateStatus}) {
    final retries = item.retryCount + 1;
    final exhausted = retries >= _maxSubmissionRetries;
    _outbox[index] = item.copyWith(
      state: exhausted ? ResultSubmissionState.failed : ResultSubmissionState.pending,
      retryCount: retries,
      responseStatus: responseStatus,
      responseBody: responseBody,
      errorMessage: exhausted ? 'max_retries_reached' : error,
    );
    if (updateStatus) {
      _statusMessage = exhausted
          ? 'Sync failed ($retries×)'
          : 'Will retry ($retries/$_maxSubmissionRetries)';
    }
  }

  void _updateMatchVersionFromResponse(Map<String, dynamic>? body) {
    final config = _matchConfig;
    final version = (body?['version'] as num?)?.toInt();
    if (config == null || version == null) return;
    _matchConfig = config.copyWith(version: version, status: 'COMPLETED');
    unawaited(_persistConfig(_matchConfig!));
  }
}
