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

  /// Fired once when the CURRENTLY-linked match's result is confirmed delivered
  /// (HTTP 200). Lets the app return to its clean start state only after a
  /// successful submission — never on a queued/failed/conflicted one (those keep
  /// the match on screen with its error status so the referee can decide). Not
  /// fired for a late response that belongs to an already-replaced match.
  void Function()? onCurrentResultDelivered;

  ScoreboardResultService({http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null;

  String _authValue(String token) => '$_bearerScheme $token';

  ScoreboardMatchConfig? get matchConfig => _matchConfig;
  ScoreboardMatchConfig? get pendingMatchConfig => _pendingMatchConfig;
  String get statusMessage => _statusMessage;

  /// Test-only seam: simulate a match config (and its credentials) surfacing
  /// — as a deep link / persisted load would — and notify listeners, WITHOUT
  /// the real [initialize] path. Unit tests can't run that path: it awaits the
  /// app_links method channel (`getInitialLink`), which has no handler under
  /// `flutter test` and never returns, and it performs real network I/O.
  @visibleForTesting
  void debugApplyMatchConfig(
    ScoreboardMatchConfig config, {
    String? token,
    Uri? baseUri,
  }) {
    _matchConfig = config;
    if (token != null) _token = token;
    if (baseUri != null) _baseUri = baseUri;
    notifyListeners();
  }

  @visibleForTesting
  void debugApplyPendingMatchConfig(
    ScoreboardMatchConfig config, {
    required String token,
    required Uri baseUri,
  }) {
    _pendingToken = token;
    _pendingBaseUri = baseUri;
    _pendingMatchConfig = config;
    _statusMessage = 'Confirm to load match';
    notifyListeners();
  }

  bool get hasToken => _token != null && _token!.isNotEmpty;

  /// Whether [matchCode] has ANY outbox item, in any state (the audit-trail
  /// view). The review gate uses [hasUnresolvedResultFor] instead, so this is
  /// retained only for tests asserting an item was recorded.
  @visibleForTesting
  bool hasResultFor(String matchCode) =>
      _outbox.any((item) => item.matchCode == matchCode);

  /// True if [matchCode] has an outbox item that should still BLOCK re-opening
  /// the full-time result review. Every state blocks EXCEPT a terminal rejection
  /// (HTTP 401/422): that result is correctable, so the review must stay
  /// reachable for the referee to fix and re-submit (RAVF002). A retry-exhausted
  /// transient failure (5xx / network) is NOT terminal here and keeps blocking —
  /// it is re-sent via [retryPendingNow], not by re-opening the review.
  bool hasUnresolvedResultFor(String matchCode) => _outbox.any(
      (item) => item.matchCode == matchCode && !_isTerminalRejection(item));

  static bool _isTerminalRejection(ResultOutboxItem item) =>
      item.state == ResultSubmissionState.failed &&
      (item.responseStatus == 401 || item.responseStatus == 422);

  /// Polls this match's outbox item until it reaches a terminal state
  /// (submitted / conflict / failed) or [timeout] elapses, returning that
  /// state — or null if the item is still pending (offline / slow) at the
  /// deadline. Centralizes the busy-poll the review screen used inline.
  Future<ResultSubmissionState?> awaitOutboxOutcome(
    String matchCode, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      ResultOutboxItem? item;
      for (final entry in _outbox) {
        if (entry.matchCode == matchCode) item = entry;
      }
      if (item != null && item.state != ResultSubmissionState.pending) {
        return item.state;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  bool get hasConflict => conflictCount > 0;
  int get pendingCount => _outbox
      .where((item) => item.state == ResultSubmissionState.pending)
      .length;
  int get conflictCount => _outbox
      .where((item) => item.state == ResultSubmissionState.conflict)
      .length;
  int get submittedCount => _outbox
      .where((item) => item.state == ResultSubmissionState.submitted)
      .length;

  /// Outbox items NOT yet confirmed delivered to the scoreboard (anything other
  /// than a 200/submitted: pending, conflict, or failed). Used to warn before
  /// "Clear linked match" — which calls [clearLinkedMatchData] and wipes the
  /// whole outbox — permanently discards undelivered results (RAVF003).
  int get undeliveredCount => _outbox
      .where((item) => item.state != ResultSubmissionState.submitted)
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
        final decoded = jsonDecode(outboxRaw);
        if (decoded is List) {
          // Parse each item independently. ResultOutboxItem.fromJson force-casts
          // required fields (id, base_url, token, idempotency_key), so a single
          // malformed or partially-written entry would otherwise throw and
          // discard the WHOLE outbox — silently stranding every other pending
          // submission (its delivery + 20s retry would never run again). Skip
          // only the bad entry and keep the valid ones.
          final restored = <ResultOutboxItem>[];
          for (final item in decoded) {
            if (item is! Map) continue;
            try {
              restored.add(
                  ResultOutboxItem.fromJson(Map<String, dynamic>.from(item)));
            } catch (e) {
              debugPrint(
                  'ScoreboardResultService: skipping malformed outbox item: $e');
            }
          }
          _outbox = restored;
        }
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
      // Restore a persistent "✓ Submitted" confirmation from the stored outbox
      // so a delivered result still reads as sent after an app restart (Part C),
      // rather than reverting to a generic status the background refresh sets.
      final submitted = _submittedStatusForCommittedMatch();
      if (submitted != null) {
        _statusMessage = submitted;
      }
      if (_matchConfig != null || submitted != null) {
        notifyListeners();
      }
      unawaited(refreshMatchConfig().catchError((error) {
        debugPrint('ScoreboardResultService: initial refresh failed: $error');
      }));
      unawaited(processOutbox().catchError((error) {
        debugPrint(
            'ScoreboardResultService: initial outbox run failed: $error');
      }));
    } else if (_matchConfig != null) {
      _statusMessage = 'Stored match ready';
      notifyListeners();
    }
  }

  void disposeService() {
    _retryTimer?.cancel();
    _linkSub?.cancel();
    if (_ownsHttpClient) {
      _httpClient.close();
    }
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
          debugPrint(
              'ScoreboardResultService: deep link handling failed: $error');
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

    _pendingToken = rawToken;
    _pendingBaseUri = parsed.baseUri;
    _pendingMatchConfig = null;
    _statusMessage = 'Confirm to load match';
    notifyListeners();
    await _fetchPendingMatchConfig(
      token: rawToken,
      requestBase: parsed.baseUri,
    );
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

  /// GET the match config for [token]/[requestBase] and map the HTTP outcome to
  /// a parsed config (on 200) plus a human status string. Pure network+parse;
  /// the stale-response guard and which field (committed vs pending) to write is
  /// the caller's responsibility, since each path tracks a different identity.
  ///
  /// `status` is only consumed on the FAILURE branches (config == null) — both
  /// callers set their own success message (the committed path prefers a
  /// persisted "✓ Submitted", the pending path shows "Confirm to load match").
  Future<({ScoreboardMatchConfig? config, String status})> _requestMatchConfig(
    String token,
    Uri requestBase,
  ) async {
    final endpoint = requestBase.replace(path: '/api/v1/soccer/match/');
    try {
      final response = await _httpClient.get(
        endpoint,
        headers: {'Authorization': _authValue(token)},
      ).timeout(_requestTimeout);

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          return (
            config: ScoreboardMatchConfig.fromJson(decoded),
            status: 'Match loaded',
          );
        }
        return (config: null, status: 'Bad match data');
      } else if (response.statusCode == 401) {
        return (config: null, status: 'Link expired');
      } else {
        return (config: null, status: 'Load failed (${response.statusCode})');
      }
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

    final requestBase = _baseUri;
    final outcome = await _requestMatchConfig(token, requestBase);

    // Discard a stale response: a newer link or a clear may have changed the
    // active token/base URL while this request was in flight. Applying it now
    // would pair the current token with a different (or cleared) match.
    if (_token != token || _baseUri != requestBase) {
      return;
    }

    if (outcome.config != null) {
      _matchConfig = outcome.config;
      await _prefs?.setString(
          _prefsMatchKey, jsonEncode(outcome.config!.toJson()));
      // Preserve a prior "✓ Submitted" confirmation across a refresh (Part C):
      // refreshing the config must not make a delivered result look un-sent.
      // _matchConfig is non-null here, so this is the submitted status or
      // 'Match loaded'.
      _statusMessage = _committedMatchStatus();
    } else {
      _statusMessage = outcome.status;
    }

    notifyListeners();
  }

  Future<void> _fetchPendingMatchConfig({
    required String token,
    required Uri requestBase,
  }) async {
    final outcome = await _requestMatchConfig(token, requestBase);

    // Stale guard: a newer link (or a confirm/cancel) may have replaced the
    // pending target while this request was in flight.
    if (_pendingToken != token || _pendingBaseUri != requestBase) {
      return;
    }

    if (outcome.config != null) {
      _pendingMatchConfig = outcome.config;
      _statusMessage = 'Confirm to load match';
    } else {
      _pendingMatchConfig = null;
      _statusMessage = outcome.status;
    }

    notifyListeners();
  }

  /// `'✓ Submitted <code>'` if the currently-committed match already has a
  /// delivered (submitted) outbox item, else null. Lets a successful submit's
  /// confirmation persist across refreshes and app restarts (Part C of #51).
  String? _submittedStatusForCommittedMatch() {
    final config = _matchConfig;
    if (config == null) return null;
    final submitted = _outbox.any((item) =>
        item.matchCode == config.matchCode &&
        item.state == ResultSubmissionState.submitted);
    return submitted ? '✓ Submitted ${config.matchCode}' : null;
  }

  Future<void> confirmPendingMatch({String? expectedSignature}) async {
    final token = _pendingToken;
    final baseUri = _pendingBaseUri;
    final config = _pendingMatchConfig;
    if (token == null || token.isEmpty || baseUri == null || config == null) {
      _statusMessage = _committedMatchStatus();
      notifyListeners();
      return;
    }

    // A stale "Load match?" dialog (a newer link replaced the pending match
    // after the dialog was built) must not commit the wrong fixture: the
    // dialog passes the signature it displayed; bail if it no longer matches.
    if (expectedSignature != null && config.signature != expectedSignature) {
      notifyListeners();
      return;
    }

    // Promote the pending match to committed SYNCHRONOUSLY, before any awaited
    // prefs write. A deep link can arrive (handleDeepLink) during those awaits;
    // doing the in-memory swap + pending clear up front means such a newer link
    // re-stages _pending* AFTER this point and is not wiped by the clear below.
    _token = token;
    _baseUri = baseUri;
    _matchConfig = config;
    _pendingToken = null;
    _pendingBaseUri = null;
    _pendingMatchConfig = null;
    _statusMessage = 'Match loaded';
    notifyListeners();

    // Persist with the match config written LAST, and the previous one removed
    // FIRST. A kill between these writes must never leave the new token/base
    // paired with the PREVIOUS match's config on disk — initialize() reads them
    // back independently and would surface the wrong fixture (offline, before a
    // refresh can correct it). Worst case here is new creds + no stored config,
    // which the next refresh repopulates from the (new) token.
    await _prefs?.remove(_prefsMatchKey);
    await _prefs?.setString(_prefsTokenKey, token);
    await _prefs?.setString(_prefsBaseUrlKey, baseUri.toString());
    await _prefs?.setString(_prefsMatchKey, jsonEncode(config.toJson()));

    unawaited(processOutbox());
  }

  void cancelPendingMatch({String? expectedSignature}) {
    // A stale Cancel must only discard the link the dialog was showing. Bail if
    // the loaded pending config no longer matches the dialog's signature — and
    // also when it is null, which means a newer link replaced it and is still
    // fetching (clearing then would silently drop that newer link).
    if (expectedSignature != null &&
        (_pendingMatchConfig == null ||
            _pendingMatchConfig!.signature != expectedSignature)) {
      notifyListeners();
      return;
    }
    _pendingToken = null;
    _pendingBaseUri = null;
    _pendingMatchConfig = null;
    // Preserve a "✓ Submitted" confirmation if the still-committed match was
    // already delivered (Part C): cancelling a mistaken second link must not
    // make the first match's submitted result look un-sent.
    _statusMessage = _committedMatchStatus();
    notifyListeners();
  }

  /// Status to show when no link is staged: the persistent submitted
  /// confirmation if the committed match was delivered, else a generic
  /// loaded/awaiting message.
  String _committedMatchStatus() =>
      _submittedStatusForCommittedMatch() ??
      (_matchConfig == null ? 'Awaiting link' : 'Match loaded');

  Future<bool> enqueueFinalResult({
    required int homeGoals,
    required int awayGoals,
    String? comment,
    bool homeConfirmed = false,
    bool awayConfirmed = false,
    List<ActualModuleReport> homeModules = const [],
    List<ActualModuleReport> awayModules = const [],
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
      _statusMessage = 'Result already tracked';
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
      homeConfirmed: homeConfirmed,
      awayConfirmed: awayConfirmed,
      version: matchConfig.version,
      idempotencyKey: _uuid.v4(),
      comment: comment,
      homeModules: homeModules,
      awayModules: awayModules,
      state: ResultSubmissionState.pending,
      responseStatus: null,
      responseBody: null,
      errorMessage: null,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );

    _outbox = [..._outbox, item];
    _statusMessage = 'Result queued';
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
      _statusMessage = 'Retrying…';
      await _persistOutbox();
      notifyListeners();
    }
    await processOutbox();
  }

  Future<void> clearLinkedMatchData() async {
    _token = null;
    _baseUri = _defaultBaseUri;
    _matchConfig = null;
    _pendingToken = null;
    _pendingBaseUri = null;
    _pendingMatchConfig = null;
    _outbox = [];
    _statusMessage = 'Awaiting link';

    final prefs = _prefs;
    if (prefs != null) {
      await prefs.remove(_prefsTokenKey);
      await prefs.remove(_prefsBaseUrlKey);
      await prefs.remove(_prefsMatchKey);
      await prefs.remove(_prefsOutboxKey);
    }

    notifyListeners();
  }

  /// Drop the live link (token/config/pending) and return to "Awaiting link"
  /// AFTER a result was delivered, but KEEP the outbox as the delivered-result
  /// audit trail (and so any other not-yet-delivered items still retry). Unlike
  /// [clearLinkedMatchData] this never wipes the outbox. The delivered item
  /// carries its own token/baseUrl, so clearing the live link cannot strand it.
  Future<void> resetLinkedMatchAfterSubmission() async {
    _token = null;
    _baseUri = _defaultBaseUri;
    _matchConfig = null;
    _pendingToken = null;
    _pendingBaseUri = null;
    _pendingMatchConfig = null;
    _statusMessage = 'Awaiting link';

    final prefs = _prefs;
    if (prefs != null) {
      await prefs.remove(_prefsTokenKey);
      await prefs.remove(_prefsBaseUrlKey);
      await prefs.remove(_prefsMatchKey);
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
      'home_confirmed': item.homeConfirmed,
      'away_confirmed': item.awayConfirmed,
      'version': item.version,
      'idempotency_key': item.idempotencyKey,
      if (item.comment?.isNotEmpty ?? false) 'comment': item.comment,
      // Report the actually-fielded modules per team (#85), read from the
      // PERSISTED item — never re-derived live — so a retry replays submit-time
      // state. Omitted entirely when both lists are empty (pre-#85 queued items,
      // non-referee edge) so the legacy payload stays byte-for-byte unchanged;
      // absence means "no report", not "no modules".
      if (item.homeModules.isNotEmpty || item.awayModules.isNotEmpty)
        'actual_modules': {
          'home': item.homeModules.map((m) => m.toJson()).toList(),
          'away': item.awayModules.map((m) => m.toJson()).toList(),
        },
    };

    try {
      final response = await _httpClient
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

      // The POST uses the item's OWN token/baseUrl, so it can complete after the
      // referee already loaded a different match (or the same code at a new
      // revision). The outbox item state is always updated (durability), but the
      // visible status + the committed match's version are only touched when the
      // live config is still this item's exact fixture revision — matchCode AND
      // version — so a late response can't stamp the wrong match.
      final isCurrentFixture = _matchConfig != null &&
          _matchConfig!.matchCode == item.matchCode &&
          _matchConfig!.version == item.version;

      if (response.statusCode == 200) {
        _outbox[index] = item.copyWith(
          state: ResultSubmissionState.submitted,
          responseStatus: response.statusCode,
          responseBody: body,
          clearError: true,
        );
        if (isCurrentFixture) {
          _statusMessage = '✓ Submitted ${item.matchCode}';
          _updateMatchVersionFromResponse(body);
          // The active match's result is now delivered: signal the app to
          // return to its clean start state. Fired only on a confirmed 200 for
          // the still-current fixture, so a queued/failed result never resets.
          onCurrentResultDelivered?.call();
        }
      } else if (response.statusCode == 409) {
        _outbox[index] = item.copyWith(
          state: ResultSubmissionState.conflict,
          responseStatus: response.statusCode,
          responseBody: body,
          errorMessage: body?['reason']?.toString() ?? 'conflict',
        );
        if (isCurrentFixture) _statusMessage = 'Conflict — review';
      } else if (response.statusCode == 401 || response.statusCode == 422) {
        _outbox[index] = item.copyWith(
          state: ResultSubmissionState.failed,
          responseStatus: response.statusCode,
          responseBody: body,
          errorMessage: body?['reason']?.toString() ?? 'request rejected',
        );
        if (isCurrentFixture) {
          _statusMessage = 'Rejected (${response.statusCode})';
        }
      } else {
        _markRetriableFailure(
          index: index,
          item: item,
          responseStatus: response.statusCode,
          responseBody: body,
          errorMessage: 'temporary_error_${response.statusCode}',
          updateStatus: isCurrentFixture,
        );
      }
    } catch (e) {
      // Re-find the item by id after the awaited request threw (the outbox may
      // have been cleared meanwhile).
      final index = _outbox.indexWhere((entry) => entry.id == id);
      if (index != -1) {
        final isCurrentFixture = _matchConfig != null &&
            _matchConfig!.matchCode == item.matchCode &&
            _matchConfig!.version == item.version;
        _markRetriableFailure(
          index: index,
          item: item,
          errorMessage: 'network_error',
          updateStatus: isCurrentFixture,
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
    // Only mutate the visible status when this item is still the committed
    // match's fixture; a late failure for an old item must not relabel the
    // currently-loaded match.
    bool updateStatus = true,
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
      if (updateStatus) _statusMessage = 'Sync failed ($nextRetryCount×)';
      return;
    }

    _outbox[index] = item.copyWith(
      state: ResultSubmissionState.pending,
      retryCount: nextRetryCount,
      responseStatus: responseStatus,
      responseBody: responseBody,
      errorMessage: errorMessage,
    );
    if (updateStatus) {
      _statusMessage = 'Will retry ($nextRetryCount/$_maxSubmissionRetries)';
    }
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
}
