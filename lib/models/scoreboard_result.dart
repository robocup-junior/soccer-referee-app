import 'dart:convert';

enum ResultSubmissionState { pending, submitted, conflict, failed }

class ScoreboardMatchConfig {
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
  });

  ScoreboardMatchConfig copyWith({
    String? matchCode,
    String? homeTeamName,
    String? awayTeamName,
    bool? homeIsLeft,
    String? venueShortName,
    DateTime? scheduledStart,
    int? durationSeconds,
    String? timezone,
    int? version,
    String? status,
  }) {
    return ScoreboardMatchConfig(
      matchCode: matchCode ?? this.matchCode,
      homeTeamName: homeTeamName ?? this.homeTeamName,
      awayTeamName: awayTeamName ?? this.awayTeamName,
      homeIsLeft: homeIsLeft ?? this.homeIsLeft,
      venueShortName: venueShortName ?? this.venueShortName,
      scheduledStart: scheduledStart ?? this.scheduledStart,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      timezone: timezone ?? this.timezone,
      version: version ?? this.version,
      status: status ?? this.status,
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
    final durationSeconds = (json['duration_seconds'] as num?)?.toInt() ?? 600;

    return ScoreboardMatchConfig(
      matchCode: (json['match_code']?.toString() ?? '').trim(),
      homeTeamName: teamName(json['home_team'], 'Home'),
      awayTeamName: teamName(json['away_team'], 'Away'),
      homeIsLeft: homeIsLeft ?? true,
      venueShortName: (json['venue']?.toString() ?? '').trim(),
      scheduledStart: scheduledStart,
      durationSeconds: durationSeconds <= 0 ? 600 : durationSeconds,
      timezone: (json['timezone']?.toString() ?? 'UTC').trim(),
      version: (json['version'] as num?)?.toInt() ?? 0,
      status: (json['status']?.toString() ?? '').toUpperCase(),
    );
  }

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
      };
}

class ResultOutboxItem {
  final String id;
  final String baseUrl;
  final String token;
  final String matchCode;
  final int homeGoals;
  final int awayGoals;
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
  }) {
    return ResultOutboxItem(
      id: id,
      baseUrl: baseUrl,
      token: token,
      matchCode: matchCode,
      homeGoals: homeGoals,
      awayGoals: awayGoals,
      version: version,
      idempotencyKey: idempotencyKey,
      comment: comment,
      retryCount: retryCount ?? this.retryCount,
      state: state ?? this.state,
      responseStatus: responseStatus ?? this.responseStatus,
      responseBody: responseBody ?? this.responseBody,
      errorMessage: errorMessage ?? this.errorMessage,
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
