import 'package:live_activities/live_activities.dart';
import 'package:rcj_scoreboard/models/game.dart';

class LiveActivityUpdateService{
  final _liveActivitiesPlugin = LiveActivities();

  String _teamAName = '';
  String _teamBName = '';
  int _teamAScore = 0;
  int _teamBScore = 0;
  int _timeLeft = 600; // in seconds
  MatchStage _matchStage = MatchStage.firstHalf;

  final _activityId = 'gameStatsWidget';

  Future<void> initialize() async{
    await _liveActivitiesPlugin.init(appGroupId: "group.com.robocup.rcjScoreboard");
  }

  void setDetails(String teamAName, String teamBName, int teamAScore, int teamBScore, int timeLeft, MatchStage gameStage){
    _teamAName = teamAName;
    _teamBName = teamBName;
    _teamAScore = teamAScore;
    _teamBScore = teamBScore;
    _timeLeft = timeLeft;
    _matchStage = gameStage;
  }

  void updateScore (int teamAScore, int teamBScore){
    _teamAScore = teamAScore;
    _teamBScore = teamBScore;

    Map<String, dynamic> activityModel = {
      'team_a_name': _teamAName,
      'team_a_score': _teamAScore,
      'team_b_name': _teamBName,
      'team_b_score': _teamBScore,
      'time_left': _timeLeft,
      'match_stage': _matchStage,
    };

    _liveActivitiesPlugin.updateActivity(_activityId, activityModel);
  }

  void updateTime (int timeLeft){
    _timeLeft = timeLeft;

    Map<String, dynamic> activityModel = {
      'team_a_name': _teamAName,
      'team_a_score': _teamAScore,
      'team_b_name': _teamBName,
      'team_b_score': _teamBScore,
      'time_left': _timeLeft,
      'match_stage': _matchStage,
    };

    _liveActivitiesPlugin.updateActivity(_activityId, activityModel);
  }

  void startActivity(String teamAName, String teamBName, int teamAScore, int teamBScore, int timeLeft, MatchStage gameStage) {
    setDetails(teamAName, teamBName, teamAScore, teamBScore, timeLeft, gameStage);

    Map<String, dynamic> activityModel = {
      'team_a_name': _teamAName,
      'team_a_score': _teamAScore,
      'team_b_name': _teamBName,
      'team_b_score': _teamBScore,
      'time_left': _timeLeft,
      'match_stage': _matchStage,
    };
    _liveActivitiesPlugin.createActivity(_activityId, activityModel);
  }
}