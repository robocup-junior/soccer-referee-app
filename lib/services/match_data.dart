import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;


class Match {
  final String id;
  final String fieldRaw;
  final String field; // Extracted field number
  final String team1;
  final String team2;

  Match({
    required this.id,
    required this.fieldRaw,
    this.field = '',
    required this.team1,
    required this.team2,
  });

  factory Match.fromJson(Map<String, dynamic> json) {
    return Match(
      id: json['number']?.toString() ?? '', // Safely extract match number as the ID
      fieldRaw: json['pitch'] as String? ?? '', // Safely extract pitch
      team1: json['team1']?['name'] as String? ?? 'Unknown Team 1', // Safely extract team1 name
      team2: json['team2']?['name'] as String? ?? 'Unknown Team 2', // Safely extract team2 name
      field: RegExp(r'\d+')
              .firstMatch(json['pitch'] as String? ?? '')
              ?.group(0)
              ?.replaceFirst(RegExp(r'^0+'), '') ??
          '', // Safely extract field number
    );
  }
}

class MatchDataService {
  String _url = 'https://catigoal.com/rest/v1/RCJI25/matches?format=json';
  String _matchId = '';
  final String _state = '';
  List<Match> _matches = [];
  Match? _currentMatch;
  final ValueNotifier<String> stateNotifier = ValueNotifier('');
  late final SharedPreferences prefs;

  MatchDataService() {
    loadPreferences();
  }


  /// Loads MQTT settings from SharedPreferences
  Future<void> loadPreferences() async {
    prefs = await SharedPreferences.getInstance();
    _url = prefs.getString('matches_url') ?? 'https://catigoal.com/rest/v1/RCJI25/matches?format=json';
  }

  Future<List<Match>> fetchMatches(String url) async {
    final response = await http.get(Uri.parse(url));

    if (response.statusCode == 200) {
      debugPrint('Matches loaded successfully');
      final Map<String, dynamic> jsonResponse = json.decode(response.body);
      final List<dynamic> matchesList = jsonResponse['matches'];
      debugPrint('Number of matches: ${matchesList.length}');
      return matchesList.map((matchJson) => Match.fromJson(matchJson)).toList();
    } else {
      throw Exception('Failed to load matches');
    }
  }

  Match? findMatchById(List<Match> matches, String gameId) {
    try {
      // Iterate through matches and find the one with the matching ID
      for (var match in matches) {
        if (match.id == gameId) {
          return match;
        }
      }
      return null; // Return null if no match is found
    } catch (e) {
      return null; // Handle errors gracefully
    }
  }

  String get matchesUrl => _url;

  set matchesUrl(String? url) {
    if (url != null && url.isNotEmpty) {
      _url = url;
      // Save to preferences
      prefs.setString('matches_url', url);
    } else {
      debugPrint('Error: Invalid matches URL.');
    }
  }

  String get matchId => _matchId;
  set matchId(String? id) {
    if (id != null && id.isNotEmpty) {
      _matchId = id;
      // Save to preferences
      // prefs.setString('match_id', id); // Uncomment if using shared preferences
    } else {
      debugPrint('Error: Invalid match ID.');
    }
  }

  String get state => _state;

  Future<Match?> loadMatch() async {
    stateNotifier.value = 'Loading matches...';

    try {
      //print('Loading matches from: $_url');
      _matches = await fetchMatches(_url);
      debugPrint('Matches loaded: ${_matches.length}');
    } catch (e) {
      stateNotifier.value = 'Error loading matches';
      debugPrint('Error loading matches: $e');
      return null;
    }

    // Find the match by ID
    try {
      _currentMatch = findMatchById(_matches, _matchId);
      if (_currentMatch != null) {
        debugPrint('Current match found: ${_currentMatch!.id}');
        stateNotifier.value = 'Match ID $_matchId loaded';
        return _currentMatch;
      } else {
        stateNotifier.value = 'Match not found';
        debugPrint('Match not found for ID: $_matchId');
        return null;
      }
    } catch (e) {
      stateNotifier.value = 'Error finding match';
      debugPrint('Error finding match: $e');
      return null;
    }
  }
}