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
      id: json['#'] as String,
      fieldRaw: json['Field'] as String,
      team1: json['Teams_1'] as String,
      team2: json['Teams_3'] as String,

      // Extract only the number from the fieldRaw string
      // Example: "L-1" -> "1"
      field: RegExp(r'\d+').firstMatch(json['Field'] as String)?.group(0) ?? '',
    );
  }
}

class MatchDataService {
  String _url = 'https://raw.githubusercontent.com/robocup-junior/soccer-matches/refs/heads/main/data/RCJI25/matches.json';
  String _matchId = '';
  String _state = '';
  List<Match> _matches = [];
  Match? _currentMatch = null;
  final ValueNotifier<String> stateNotifier = ValueNotifier('');
  late SharedPreferences prefs;

  MatchDataService() {
    loadPreferences();
  }


  /// Loads MQTT settings from SharedPreferences
  Future<void> loadPreferences() async {
    prefs = await SharedPreferences.getInstance();
    _url = prefs.getString('matches_url') ?? 'https://raw.githubusercontent.com/robocup-junior/soccer-matches/refs/heads/main/data/RCJI25/matches.json';
  }

  Future<List<Match>> fetchMatches(String url) async {
    final response = await http.get(Uri.parse(url));

    //print(response.body);
    if (response.statusCode == 200) {
      print('Matches loaded successfully');
      final List<dynamic> jsonList = json.decode(response.body);
      print('Number of matches: ${jsonList.length}');
      return jsonList.map((json) => Match.fromJson(json)).toList();
    } else {
      throw Exception('Failed to load matches');
    }
  }

  Match? findMatchById(List<Match> matches, String gameId) {
    try {
      return matches.firstWhere((match) => match.id == gameId);
    } catch (e) {
      return null;
    }
  }

  String get matchesUrl => _url;

  set matchesUrl(String? url) {
    if (url != null && url.isNotEmpty) {
      _url = url;
      // Save to preferences
      prefs.setString('matches_url', url);
    } else {
      print('Error: Invalid matches URL.');
    }
  }

  String get matchId => _matchId;
  set matchId(String? id) {
    if (id != null && id.isNotEmpty) {
      _matchId = id;
      // Save to preferences
      // prefs.setString('match_id', id); // Uncomment if using shared preferences
    } else {
      print('Error: Invalid match ID.');
    }
  }

  String get state => _state;

  Future<Match?> loadMatch() async {
    stateNotifier.value = 'Loading matches...';

    try {
      //print('Loading matches from: $_url');
      _matches = await fetchMatches(_url);
      print('Matches loaded: ${_matches.length}');
    } catch (e) {
      stateNotifier.value = 'Error loading matches';
      print('Error loading matches: $e');
      return null;
    }

    // Find the match by ID
    try {
      _currentMatch = findMatchById(_matches, _matchId);
      if (_currentMatch != null) {
        print('Current match found: ${_currentMatch!.id}');
        stateNotifier.value = 'Match ID $_matchId loaded';
        return _currentMatch;
      } else {
        stateNotifier.value = 'Match not found';
        print('Match not found for ID: $_matchId');
        return null;
      }
    } catch (e) {
      stateNotifier.value = 'Error finding match';
      print('Error finding match: $e');
      return null;
    }
  }
}