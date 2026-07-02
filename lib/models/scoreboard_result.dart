import 'dart:convert';

enum ResultSubmissionState { pending, submitted, conflict, failed }

/// Soft inspection status the scoreboard reports per fielded robot for the
/// current competition day (rcj-scoreboard #112). [unknown] is the client-side
/// fallback for an absent/unrecognised value — treat both [unknown] and
/// [missing] as "not applicable / not yet cleared", never as a hard "blocked":
/// the server's "missing" conflates a non-inspecting league with an uninspected
/// robot.
enum InspectionStatus { ok, failed, missing, unknown }

InspectionStatus _inspectionStatusFromJson(dynamic value) {
  final name = value?.toString().toLowerCase().trim();
  return InspectionStatus.values.firstWhere(
    (s) => s.name == name,
    orElse: () => InspectionStatus.unknown,
  );
}

/// One fielded robot's soft inspection result for the current competition day
/// (rcj-scoreboard #112): its [status] and free-text [note]. [robot] is the
/// robot number.
class InspectionRobot {
  final int robot;
  final InspectionStatus status;
  final String note;

  const InspectionRobot({
    required this.robot,
    required this.status,
    required this.note,
  });

  factory InspectionRobot.fromJson(Map<String, dynamic> json) => InspectionRobot(
        // num.tryParse handles an int (3), a float (3.0), and a string ("3")
        // without ever throwing or silently dropping a valid robot.
        robot: num.tryParse(json['robot']?.toString() ?? '')?.toInt() ?? 0,
        status: _inspectionStatusFromJson(json['status']),
        note: (json['note']?.toString() ?? '').trim(),
      );

  Map<String, dynamic> toJson() =>
      {'robot': robot, 'status': status.name, 'note': note};

  @override
  bool operator ==(Object other) =>
      other is InspectionRobot &&
      other.robot == robot &&
      other.status == status &&
      other.note == note;

  @override
  int get hashCode => Object.hash(robot, status, note);
}

/// Parses the `*_inspection_robots` array, dropping non-map entries and any
/// entry with an invalid/non-positive robot number so the UI is never fed a
/// malformed row (this keeps a bad note from breaking the whole match load).
List<InspectionRobot> _inspectionRobotsFromJson(dynamic value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((m) => InspectionRobot.fromJson(Map<String, dynamic>.from(m)))
      .where((r) => r.robot > 0)
      .toList(growable: false);
}

class ScoreboardMatchConfig {
  static const int _defaultSlotDurationSeconds = 25 * 60;
  static const int _defaultPeriodDurationSeconds = 10 * 60;
  static const int _defaultHalfTimeDurationSeconds = 5 * 60;

  final String matchCode;
  final String homeTeamName;
  final String awayTeamName;
  final bool homeIsLeft;
  final String venueShortName;
  final DateTime? scheduledStart;
  final int durationSeconds;
  final int slotDurationSeconds;
  final int periodDurationSeconds;
  final int halfTimeDurationSeconds;
  final int playDurationSeconds;
  final bool hasExplicitTiming;
  final String timezone;
  final int version;
  final String status;
  final List<InspectionRobot> homeInspectionRobots;
  final List<InspectionRobot> awayInspectionRobots;

  /// MAC addresses of the home/away robots' comm modules, ordered by robot
  /// number (server payload keys `home_module_macs`/`away_module_macs`, #70).
  /// The app maps these onto the fixed per-side module slots for auto-pairing.
  /// Empty for older payloads that never carried them.
  final List<String> homeModuleMacs;
  final List<String> awayModuleMacs;

  const ScoreboardMatchConfig({
    required this.matchCode,
    required this.homeTeamName,
    required this.awayTeamName,
    required this.homeIsLeft,
    required this.venueShortName,
    required this.scheduledStart,
    required this.durationSeconds,
    required this.slotDurationSeconds,
    required this.periodDurationSeconds,
    required this.halfTimeDurationSeconds,
    required this.playDurationSeconds,
    required this.hasExplicitTiming,
    required this.timezone,
    required this.version,
    required this.status,
    this.homeModuleMacs = const [],
    this.awayModuleMacs = const [],
    this.homeInspectionRobots = const [],
    this.awayInspectionRobots = const [],
  });

  ScoreboardMatchConfig copyWith({
    String? matchCode,
    String? homeTeamName,
    String? awayTeamName,
    bool? homeIsLeft,
    String? venueShortName,
    DateTime? scheduledStart,
    int? durationSeconds,
    int? slotDurationSeconds,
    int? periodDurationSeconds,
    int? halfTimeDurationSeconds,
    int? playDurationSeconds,
    bool? hasExplicitTiming,
    String? timezone,
    int? version,
    String? status,
    List<String>? homeModuleMacs,
    List<String>? awayModuleMacs,
    List<InspectionRobot>? homeInspectionRobots,
    List<InspectionRobot>? awayInspectionRobots,
  }) {
    return ScoreboardMatchConfig(
      matchCode: matchCode ?? this.matchCode,
      homeTeamName: homeTeamName ?? this.homeTeamName,
      awayTeamName: awayTeamName ?? this.awayTeamName,
      homeIsLeft: homeIsLeft ?? this.homeIsLeft,
      venueShortName: venueShortName ?? this.venueShortName,
      scheduledStart: scheduledStart ?? this.scheduledStart,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      slotDurationSeconds: slotDurationSeconds ?? this.slotDurationSeconds,
      periodDurationSeconds: periodDurationSeconds ?? this.periodDurationSeconds,
      halfTimeDurationSeconds:
          halfTimeDurationSeconds ?? this.halfTimeDurationSeconds,
      playDurationSeconds: playDurationSeconds ?? this.playDurationSeconds,
      hasExplicitTiming: hasExplicitTiming ?? this.hasExplicitTiming,
      timezone: timezone ?? this.timezone,
      version: version ?? this.version,
      status: status ?? this.status,
      homeModuleMacs: homeModuleMacs ?? this.homeModuleMacs,
      awayModuleMacs: awayModuleMacs ?? this.awayModuleMacs,
      homeInspectionRobots: homeInspectionRobots ?? this.homeInspectionRobots,
      awayInspectionRobots: awayInspectionRobots ?? this.awayInspectionRobots,
    );
  }

  factory ScoreboardMatchConfig.fromJson(Map<String, dynamic> json) {
    final sideOrder = json['side_order'];
    bool? homeIsLeft;
    if (json['home_is_left'] is bool) {
      homeIsLeft = json['home_is_left'] as bool;
    } else if (json['home_side'] == 'left') {
      homeIsLeft = true;
    } else if (json['home_side'] == 'right') {
      homeIsLeft = false;
    } else if (sideOrder is Map) {
      final homeSide = sideOrder['home']?.toString().toLowerCase();
      if (homeSide == 'left') {
        homeIsLeft = true;
      } else if (homeSide == 'right') {
        homeIsLeft = false;
      }
    }

    String teamName(dynamic value, String fallback) {
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is Map) {
        final name = value['name']?.toString().trim() ?? '';
        if (name.isNotEmpty) return name;
      }
      return fallback;
    }

    final scheduledStartRaw = json['scheduled_start']?.toString();
    final scheduledStart =
        scheduledStartRaw == null ? null : DateTime.tryParse(scheduledStartRaw);
    int positiveSeconds(dynamic value, int fallback) {
      if (value is num) {
        final seconds = value.toInt();
        if (seconds > 0) return seconds;
      }
      return fallback;
    }

    int nonNegativeSeconds(dynamic value, int fallback) {
      if (value is num) {
        final seconds = value.toInt();
        if (seconds >= 0) return seconds;
      }
      return fallback;
    }

    final durationSeconds =
        positiveSeconds(json['duration_seconds'], _defaultSlotDurationSeconds);
    final periodDurationSeconds = positiveSeconds(
        json['period_duration_seconds'], _defaultPeriodDurationSeconds);
    final halfTimeDurationSeconds = nonNegativeSeconds(
        json['half_time_duration_seconds'], _defaultHalfTimeDurationSeconds);
    final hasExplicitTiming = json.containsKey('slot_duration_seconds') ||
        json.containsKey('period_duration_seconds') ||
        json.containsKey('half_time_duration_seconds') ||
        json.containsKey('play_duration_seconds');

    List<String> moduleMacs(dynamic value) {
      if (value is! List) return const [];
      return value
          .map((e) => e.toString().trim().toUpperCase())
          .where((mac) => mac.isNotEmpty)
          .toList();
    }

    return ScoreboardMatchConfig(
      matchCode: (json['match_code']?.toString() ?? '').trim(),
      homeTeamName: teamName(json['home_team'], 'Home'),
      awayTeamName: teamName(json['away_team'], 'Away'),
      homeIsLeft: homeIsLeft ?? true,
      venueShortName: (json['venue']?.toString() ?? '').trim(),
      scheduledStart: scheduledStart,
      durationSeconds: durationSeconds,
      slotDurationSeconds:
          positiveSeconds(json['slot_duration_seconds'], durationSeconds),
      periodDurationSeconds: periodDurationSeconds,
      halfTimeDurationSeconds: halfTimeDurationSeconds,
      playDurationSeconds:
          positiveSeconds(json['play_duration_seconds'], periodDurationSeconds * 2),
      hasExplicitTiming: hasExplicitTiming,
      timezone: (json['timezone']?.toString() ?? 'UTC').trim(),
      version: (json['version'] as num?)?.toInt() ?? 0,
      status: (json['status']?.toString() ?? '').toUpperCase(),
      homeModuleMacs: moduleMacs(json['home_module_macs']),
      awayModuleMacs: moduleMacs(json['away_module_macs']),
      homeInspectionRobots: _inspectionRobotsFromJson(json['home_inspection_robots']),
      awayInspectionRobots: _inspectionRobotsFromJson(json['away_inspection_robots']),
    );
  }

  /// Stable identity of a fixture+revision as displayed/applied. Used to dedupe
  /// the confirm-on-load prompt and to guard confirm/cancel against acting on a
  /// different fixture than the one a stale dialog is showing.
  ///
  /// Built via jsonEncode of an ordered field list (not a delimiter-joined
  /// string) so values containing the separator — e.g. a team name with a ':'
  /// — cannot collide with a different fixture.
  ///
  /// Venue is part of the load/apply identity so a corrected schedule payload
  /// that changes only the venue (same match/version) still re-applies and
  /// updates the MQTT field number (#50); timing is part of this identity so an
  /// organizer correction to period/half-time values re-applies before kickoff.
  ///
  /// The module MACs are deliberately NOT part of the signature: auto-pairing
  /// runs at match (re)load (see Game._applyScoreboardMatchConfig), and folding
  /// MACs into the fixture identity would make an out-of-band module-assignment
  /// change re-trigger the "Load match?" overwrite mid-match. A MAC-only
  /// correction therefore does not force a re-pair.
  String get signature => jsonEncode(<dynamic>[
        matchCode,
        version,
        durationSeconds,
        slotDurationSeconds,
        periodDurationSeconds,
        halfTimeDurationSeconds,
        playDurationSeconds,
        homeIsLeft,
        homeTeamName,
        awayTeamName,
        venueShortName,
      ]);

  /// Stable identity for reviewing/submitting final scores. Excludes
  /// live-clock/venue-only corrections that do not change the submission target
  /// or home/away score mapping, but still includes version, side, and team
  /// names so a result captured for one fixture revision cannot be submitted
  /// against a later side/name edit for the same match code.
  String get resultSignature => jsonEncode(<dynamic>[
        matchCode,
        version,
        homeIsLeft,
        homeTeamName,
        awayTeamName,
      ]);

  Map<String, dynamic> toJson() => {
        'match_code': matchCode,
        'home_team': homeTeamName,
        'away_team': awayTeamName,
        'home_is_left': homeIsLeft,
        'venue': venueShortName,
        'scheduled_start': scheduledStart?.toIso8601String(),
        'duration_seconds': durationSeconds,
        if (hasExplicitTiming) 'slot_duration_seconds': slotDurationSeconds,
        if (hasExplicitTiming) 'period_duration_seconds': periodDurationSeconds,
        if (hasExplicitTiming)
          'half_time_duration_seconds': halfTimeDurationSeconds,
        if (hasExplicitTiming) 'play_duration_seconds': playDurationSeconds,
        'timezone': timezone,
        'version': version,
        'status': status,
        'home_module_macs': homeModuleMacs,
        'away_module_macs': awayModuleMacs,
        'home_inspection_robots':
            homeInspectionRobots.map((r) => r.toJson()).toList(),
        'away_inspection_robots':
            awayInspectionRobots.map((r) => r.toJson()).toList(),
      };
}

class ResultOutboxItem {
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
  final int retryCount;
  final ResultSubmissionState state;
  final int? responseStatus;
  final Map<String, dynamic>? responseBody;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

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
    this.retryCount = 0,
    required this.state,
    this.responseStatus,
    this.responseBody,
    this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  ResultOutboxItem copyWith({
    ResultSubmissionState? state,
    int? responseStatus,
    Map<String, dynamic>? responseBody,
    String? errorMessage,
    int? retryCount,
    bool? homeConfirmed,
    bool? awayConfirmed,
    // A plain nullable parameter cannot distinguish "leave unchanged" from "set
    // to null" (both arrive as null), so an explicit flag is needed to actively
    // clear the response/error fields — e.g. on a successful submit or when a
    // failed item is revived for a fresh retry, so stale failure details do not
    // linger on a now-submitted/pending item.
    bool clearResponse = false,
    bool clearError = false,
  }) {
    return ResultOutboxItem(
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
      retryCount: retryCount ?? this.retryCount,
      state: state ?? this.state,
      responseStatus:
          clearResponse ? null : (responseStatus ?? this.responseStatus),
      responseBody: clearResponse ? null : (responseBody ?? this.responseBody),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  factory ResultOutboxItem.fromJson(Map<String, dynamic> json) {
    ResultSubmissionState parseState(String? value) {
      return ResultSubmissionState.values.firstWhere(
        (state) => state.name == value,
        orElse: () => ResultSubmissionState.pending,
      );
    }

    Map<String, dynamic>? parseBody(dynamic value) {
      if (value is Map<String, dynamic>) return value;
      if (value is String && value.isNotEmpty) {
        try {
          final decoded = jsonDecode(value);
          if (decoded is Map<String, dynamic>) return decoded;
        } catch (_) {
          return null;
        }
      }
      return null;
    }

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
      retryCount: (json['retry_count'] as num?)?.toInt() ?? 0,
      state: parseState(json['state'] as String?),
      responseStatus: (json['response_status'] as num?)?.toInt(),
      responseBody: parseBody(json['response_body']),
      errorMessage: json['error_message'] as String?,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now().toUtc(),
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ??
          DateTime.now().toUtc(),
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
        'retry_count': retryCount,
        'state': state.name,
        'response_status': responseStatus,
        'response_body': responseBody,
        'error_message': errorMessage,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };
}
