import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:rcj_scoreboard/services/error_messages.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The field number in a venue string: first digit run, leading zeros
/// stripped ("Field 03" -> "3"); '' when there is none (or only "0", since
/// RCJ fields start at 1). Shared by the catigoal and scoreboard paths (#50).
String fieldNumberFromVenue(String raw) =>
    RegExp(r'\d+')
        .firstMatch(raw)
        ?.group(0)
        ?.replaceFirst(RegExp(r'^0+'), '') ??
    '';

class Match {
  const Match(
      {required this.id,
      required this.field,
      required this.team1,
      required this.team2});

  final String id;
  final String field;
  final String team1;
  final String team2;

  factory Match.fromJson(Map<String, dynamic> json) => Match(
        id: json['number']?.toString() ?? '',
        field: fieldNumberFromVenue(json['pitch'] as String? ?? ''),
        team1: json['team1']?['name'] as String? ?? 'Unknown Team 1',
        team2: json['team2']?['name'] as String? ?? 'Unknown Team 2',
      );
}

/// Loads a match's team names from the catigoal schedule (legacy, pre-scoreboard).
class MatchDataService {
  MatchDataService() {
    _loadPreferences();
  }

  static const _defaultUrl =
      'https://catigoal.com/rest/v1/RCJI26/matches?format=json';

  final ValueNotifier<String> stateNotifier = ValueNotifier('');
  SharedPreferences? _prefs;
  String _url = _defaultUrl;
  String _matchId = '';

  Future<void> _loadPreferences() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    _url = prefs.getString('matches_url') ?? _defaultUrl;
  }

  String get matchesUrl => _url;
  set matchesUrl(String url) {
    if (url.isEmpty) return;
    _url = url;
    _prefs?.setString('matches_url', url);
  }

  String get matchId => _matchId;
  set matchId(String id) {
    if (id.isNotEmpty) _matchId = id;
  }

  Future<Match?> loadMatch() async {
    stateNotifier.value = 'Loading matches...';
    try {
      final response = await http.get(Uri.parse(_url));
      if (response.statusCode != 200) {
        throw HttpStatusException(response.statusCode, url: _url);
      }
      final list = (json.decode(response.body)
          as Map<String, dynamic>)['matches'] as List;
      final match = list
          .map((m) => Match.fromJson(m as Map<String, dynamic>))
          .where((m) => m.id == _matchId)
          .firstOrNull;
      stateNotifier.value =
          match == null ? 'Match not found' : 'Match ID $_matchId loaded';
      return match;
    } catch (e) {
      stateNotifier.value = describeError(e).message;
      debugPrint('Error loading matches: $e');
      return null;
    }
  }
}
