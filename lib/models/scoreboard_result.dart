import 'dart:convert';

enum ResultSubmissionState { pending, submitted, conflict, failed }

/// Per-robot soft inspection status for the day. [missing] and [unknown]
/// both mean "not applicable / not yet cleared", never a hard block.
enum InspectionStatus { ok, failed, missing, unknown }

int _robotNumber(Map<String, dynamic> json) =>
    num.tryParse(json['robot']?.toString() ?? '')?.toInt() ?? 0;

/// Parse a list of rows, dropping non-maps and rows with an invalid robot
/// number, so one bad row never breaks the whole payload.
List<T> _rows<T>(dynamic value, T Function(Map<String, dynamic>) parse, int Function(T) robotOf) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((m) => parse(Map<String, dynamic>.from(m)))
      .where((r) => robotOf(r) > 0)
      .toList(growable: false);
}

class InspectionRobot {
  const InspectionRobot({required this.robot, required this.status, required this.note});

  final int robot;
  final InspectionStatus status;
  final String note;

  factory InspectionRobot.fromJson(Map<String, dynamic> json) {
    final name = json['status']?.toString().toLowerCase().trim();
    return InspectionRobot(
      robot: _robotNumber(json),
      status: InspectionStatus.values
          .firstWhere((s) => s.name == name, orElse: () => InspectionStatus.unknown),
      note: (json['note']?.toString() ?? '').trim(),
    );
  }

  Map<String, dynamic> toJson() => {'robot': robot, 'status': status.name, 'note': note};

  @override
  bool operator ==(Object other) =>
      other is InspectionRobot && other.robot == robot && other.status == status && other.note == note;

  @override
  int get hashCode => Object.hash(robot, status, note);
}

/// One comm module as actually fielded at result-submit time (#85).
class ActualModuleReport {
  const ActualModuleReport({required this.robot, required this.mac, required this.connected});

  final int robot;
  final String mac;
  final bool connected;

  /// Canonical MAC form, applied on capture AND restore so the persisted
  /// round-trip is idempotent.
  static String normalizeMac(String raw) => raw.trim().toUpperCase();

  factory ActualModuleReport.fromJson(Map<String, dynamic> json) => ActualModuleReport(
        robot: _robotNumber(json),
        mac: normalizeMac(json['mac']?.toString() ?? ''),
        // A type test, not a cast: a corrupt value must not throw away the item.
        connected: json['connected'] is bool ? json['connected'] as bool : false,
      );

  Map<String, dynamic> toJson() => {'robot': robot, 'mac': mac, 'connected': connected};

  @override
  bool operator ==(Object other) =>
      other is ActualModuleReport && other.robot == robot && other.mac == mac && other.connected == connected;

  @override
  int get hashCode => Object.hash(robot, mac, connected);
}

class ScoreboardMatchConfig {
  const ScoreboardMatchConfig({
    required this.matchCode,
    required this.homeTeamName,
    required this.awayTeamName,
    required this.homeIsLeft,
    required this.venueShortName,
    required this.scheduledStart,
    required this.durationSeconds,
    required this.timezone,
    required this.version,
    required this.status,
    this.homeModuleMacs = const [],
    this.awayModuleMacs = const [],
    this.homeInspectionRobots = const [],
    this.awayInspectionRobots = const [],
  });

  final String matchCode;
  final String homeTeamName;
  final String awayTeamName;
  final bool homeIsLeft;
  final String venueShortName;
  final DateTime? scheduledStart;
  final int durationSeconds;
  final String timezone;
  final int version;
  final String status;

  /// Comm-module MACs per side, ordered by robot number (#70); empty for
  /// payloads that never carried them.
  final List<String> homeModuleMacs;
  final List<String> awayModuleMacs;
  final List<InspectionRobot> homeInspectionRobots;
  final List<InspectionRobot> awayInspectionRobots;

  ScoreboardMatchConfig copyWith({
    String? homeTeamName,
    String? awayTeamName,
    int? version,
    String? status,
    List<InspectionRobot>? homeInspectionRobots,
  }) =>
      ScoreboardMatchConfig(
        matchCode: matchCode,
        homeTeamName: homeTeamName ?? this.homeTeamName,
        awayTeamName: awayTeamName ?? this.awayTeamName,
        homeIsLeft: homeIsLeft,
        venueShortName: venueShortName,
        scheduledStart: scheduledStart,
        durationSeconds: durationSeconds,
        timezone: timezone,
        version: version ?? this.version,
        status: status ?? this.status,
        homeModuleMacs: homeModuleMacs,
        awayModuleMacs: awayModuleMacs,
        homeInspectionRobots: homeInspectionRobots ?? this.homeInspectionRobots,
        awayInspectionRobots: awayInspectionRobots,
      );

  factory ScoreboardMatchConfig.fromJson(Map<String, dynamic> json) {
    String teamName(dynamic value, String fallback) {
      final name = switch (value) {
        String s => s.trim(),
        Map m => m['name']?.toString().trim() ?? '',
        _ => '',
      };
      return name.isEmpty ? fallback : name;
    }

    List<String> macs(dynamic value) => value is! List
        ? const []
        : value.map((e) => e.toString().trim().toUpperCase()).where((m) => m.isNotEmpty).toList();

    final homeSide = json['home_side'] ??
        (json['side_order'] is Map ? json['side_order']['home']?.toString().toLowerCase() : null);
    final homeIsLeft = switch (json['home_is_left']) {
      bool b => b,
      _ => switch (homeSide) { 'left' => true, 'right' => false, _ => true },
    };
    final duration = (json['duration_seconds'] as num?)?.toInt() ?? 600;

    return ScoreboardMatchConfig(
      matchCode: (json['match_code']?.toString() ?? '').trim(),
      homeTeamName: teamName(json['home_team'], 'Home'),
      awayTeamName: teamName(json['away_team'], 'Away'),
      homeIsLeft: homeIsLeft,
      venueShortName: (json['venue']?.toString() ?? '').trim(),
      scheduledStart: DateTime.tryParse(json['scheduled_start']?.toString() ?? ''),
      durationSeconds: duration <= 0 ? 600 : duration,
      timezone: (json['timezone']?.toString() ?? 'UTC').trim(),
      version: (json['version'] as num?)?.toInt() ?? 0,
      status: (json['status']?.toString() ?? '').toUpperCase(),
      homeModuleMacs: macs(json['home_module_macs']),
      awayModuleMacs: macs(json['away_module_macs']),
      homeInspectionRobots: _rows(json['home_inspection_robots'], InspectionRobot.fromJson, (r) => r.robot),
      awayInspectionRobots: _rows(json['away_inspection_robots'], InspectionRobot.fromJson, (r) => r.robot),
    );
  }

  /// Fixture+revision identity as displayed/applied: dedupes the load prompt
  /// and guards confirm/cancel/submit against a stale dialog. Venue is part of
  /// it (a venue-only correction must re-apply, #50); module MACs and
  /// inspection rows are not (they must not re-trigger the load flow).
  /// jsonEncode, not a delimiter join, so a ':' in a name can't alias.
  String get signature => jsonEncode(<dynamic>[
        matchCode,
        version,
        durationSeconds,
        homeIsLeft,
        homeTeamName,
        awayTeamName,
        venueShortName,
      ]);

  Map<String, dynamic> toJson() => {
        'match_code': matchCode,
        'home_team': homeTeamName,
        'away_team': awayTeamName,
        'home_is_left': homeIsLeft,
        'venue': venueShortName,
        'scheduled_start': scheduledStart?.toIso8601String(),
        'duration_seconds': durationSeconds,
        'timezone': timezone,
        'version': version,
        'status': status,
        'home_module_macs': homeModuleMacs,
        'away_module_macs': awayModuleMacs,
        'home_inspection_robots': homeInspectionRobots.map((r) => r.toJson()).toList(),
        'away_inspection_robots': awayInspectionRobots.map((r) => r.toJson()).toList(),
      };
}

/// One queued final-result submission. Carries its own token/base so it can
/// be delivered after the referee moved on to another fixture.
class ResultOutboxItem {
  const ResultOutboxItem({
    required this.id,
    required this.baseUrl,
    required this.token,
    required this.matchCode,
    required this.homeGoals,
    required this.awayGoals,
    this.homeConfirmed = false,
    this.awayConfirmed = false,
    required this.version,
    required this.idempotencyKey,
    this.comment,
    this.actualHomeModules = const [],
    this.actualAwayModules = const [],
    this.retryCount = 0,
    required this.state,
    this.responseStatus,
    this.responseBody,
    this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String baseUrl;
  final String token;
  final String matchCode;
  final int homeGoals;
  final int awayGoals;
  final bool homeConfirmed;
  final bool awayConfirmed;
  final int version;
  final String idempotencyKey;
  final String? comment;
  // Submit-time module report (#85), persisted so retries replay it verbatim.
  final List<ActualModuleReport> actualHomeModules;
  final List<ActualModuleReport> actualAwayModules;
  final int retryCount;
  final ResultSubmissionState state;
  final int? responseStatus;
  final Map<String, dynamic>? responseBody;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// [clearResponse]/[clearError] actively null those fields (a nullable
  /// parameter cannot distinguish "unchanged" from "set to null").
  ResultOutboxItem copyWith({
    ResultSubmissionState? state,
    int? responseStatus,
    Map<String, dynamic>? responseBody,
    String? errorMessage,
    int? retryCount,
    bool? homeConfirmed,
    bool? awayConfirmed,
    bool clearResponse = false,
    bool clearError = false,
  }) =>
      ResultOutboxItem(
        id: id,
        baseUrl: baseUrl,
        token: token,
        matchCode: matchCode,
        homeGoals: homeGoals,
        awayGoals: awayGoals,
        homeConfirmed: homeConfirmed ?? this.homeConfirmed,
        awayConfirmed: awayConfirmed ?? this.awayConfirmed,
        version: version,
        idempotencyKey: idempotencyKey,
        comment: comment,
        actualHomeModules: actualHomeModules,
        actualAwayModules: actualAwayModules,
        retryCount: retryCount ?? this.retryCount,
        state: state ?? this.state,
        responseStatus: clearResponse ? null : (responseStatus ?? this.responseStatus),
        responseBody: clearResponse ? null : (responseBody ?? this.responseBody),
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        createdAt: createdAt,
        updatedAt: DateTime.now().toUtc(),
      );

  factory ResultOutboxItem.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic>? body(dynamic value) {
      if (value is Map<String, dynamic>) return value;
      if (value is! String || value.isEmpty) return null;
      try {
        final decoded = jsonDecode(value);
        return decoded is Map<String, dynamic> ? decoded : null;
      } catch (_) {
        return null;
      }
    }

    DateTime time(dynamic value) =>
        DateTime.tryParse(value as String? ?? '') ?? DateTime.now().toUtc();

    return ResultOutboxItem(
      id: json['id'] as String,
      baseUrl: json['base_url'] as String,
      token: json['token'] as String,
      matchCode: json['match_code'] as String? ?? '',
      homeGoals: (json['home_goals'] as num?)?.toInt() ?? 0,
      awayGoals: (json['away_goals'] as num?)?.toInt() ?? 0,
      homeConfirmed: json['home_confirmed'] as bool? ?? false,
      awayConfirmed: json['away_confirmed'] as bool? ?? false,
      version: (json['version'] as num?)?.toInt() ?? 0,
      idempotencyKey: json['idempotency_key'] as String,
      comment: json['comment'] as String?,
      actualHomeModules: _rows(json['actual_home_modules'], ActualModuleReport.fromJson, (r) => r.robot),
      actualAwayModules: _rows(json['actual_away_modules'], ActualModuleReport.fromJson, (r) => r.robot),
      retryCount: (json['retry_count'] as num?)?.toInt() ?? 0,
      state: ResultSubmissionState.values.firstWhere((s) => s.name == json['state'],
          orElse: () => ResultSubmissionState.pending),
      responseStatus: (json['response_status'] as num?)?.toInt(),
      responseBody: body(json['response_body']),
      errorMessage: json['error_message'] as String?,
      createdAt: time(json['created_at']),
      updatedAt: time(json['updated_at']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'base_url': baseUrl,
        'token': token,
        'match_code': matchCode,
        'home_goals': homeGoals,
        'away_goals': awayGoals,
        'home_confirmed': homeConfirmed,
        'away_confirmed': awayConfirmed,
        'version': version,
        'idempotency_key': idempotencyKey,
        'comment': comment,
        'actual_home_modules': actualHomeModules.map((m) => m.toJson()).toList(),
        'actual_away_modules': actualAwayModules.map((m) => m.toJson()).toList(),
        'retry_count': retryCount,
        'state': state.name,
        'response_status': responseStatus,
        'response_body': responseBody,
        'error_message': errorMessage,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };
}
