import 'package:flutter/material.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/models/scoreboard_result.dart';
import 'package:rcj_scoreboard/screens/scoreboard_result_review.dart';
import 'package:rcj_scoreboard/services/match_state_store.dart';
import 'package:rcj_scoreboard/utils/format.dart';
import 'package:rcj_scoreboard/widgets/app_dialogs.dart';
import 'package:rcj_scoreboard/widgets/inspection_robot_list.dart';

/// The dialogs Game asks Home to raise: half-time side switch, cold-resume,
/// "Load match?" for a deep link, and the full-time result review.
///
/// Every prompt is deferred to a post-frame callback (Game's draining setters
/// may fire synchronously during install) and re-entrancy guarded. The
/// closures are kept so [uninstall] only clears callbacks this instance set.
class GamePrompts {
  GamePrompts(this.game, this.context);

  final Game game;
  final BuildContext context;
  bool _confirmOpen = false;
  bool _reviewOpen = false;

  void install() {
    game.onRequestSwitchTeamOrderDialog = _switchOrder;
    game.onRequestResumeMatch = _resume;
    game.onRequestConfirmScoreboardMatch = _confirmLoad;
    game.onRequestReviewScoreboardResult = _review;
  }

  void uninstall() {
    if (identical(game.onRequestSwitchTeamOrderDialog, _switchOrder)) {
      game.onRequestSwitchTeamOrderDialog = null;
    }
    if (identical(game.onRequestResumeMatch, _resume)) game.onRequestResumeMatch = null;
    if (identical(game.onRequestConfirmScoreboardMatch, _confirmLoad)) {
      game.onRequestConfirmScoreboardMatch = null;
    }
    if (identical(game.onRequestReviewScoreboardResult, _review)) {
      game.onRequestReviewScoreboardResult = null;
    }
  }

  void _afterFrame(Future<void> Function() body) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) body();
    });
  }

  Future<void> _switchOrder() async {
    final yes = await showChoiceDialog(
      context,
      title: 'Switch Team Order',
      body: 'Do you want to switch the team order for the second half?',
      cancelText: 'No',
      confirmText: 'Yes',
    );
    if (yes == true) game.toggleTeamOrder();
  }

  /// Resume is the prominent default; Discard needs a second confirmation so a
  /// stray tap can never wipe an in-progress match.
  void _resume() => _afterFrame(() async {
        while (game.pendingResume != null) {
          if (!context.mounted) return;
          final resume = await showChoiceDialog(
            context,
            title: 'Resume match in progress?',
            body: _resumeBody(game.pendingResume!),
            cancelText: 'Discard',
            confirmText: 'Resume',
            confirmColor: Colors.green[600],
          );
          if (resume == true) {
            game.resumePendingMatch();
            return;
          }
          if (!context.mounted) return;
          final discard = await showChoiceDialog(
            context,
            title: 'Discard match?',
            body: 'This permanently deletes the saved match and cannot be undone.',
            confirmText: 'Discard',
            confirmColor: Colors.red[600],
          );
          if (discard == true) {
            await game.discardPendingMatch();
            return;
          }
        }
      });

  void _confirmLoad(ScoreboardMatchConfig config) => _afterFrame(() async {
        if (_confirmOpen) return;
        _confirmOpen = true;
        // Bind Load/Cancel to the fixture displayed, not a newer pending link.
        final signature = config.signature;
        try {
          final load = await showChoiceDialog(
            context,
            title: 'Load match?',
            content: _LoadMatchDetails(config: config, replacesMatch: game.inGame),
            confirmText: 'Load',
            confirmColor: Colors.green[600],
          );
          if (load == true) {
            await game.confirmScoreboardMatch(expectedSignature: signature);
          } else {
            game.scoreboardResultService.cancelPendingMatch(expectedSignature: signature);
          }
        } finally {
          _confirmOpen = false;
          game.onPendingMatchPromptClosed();
        }
      });

  void _review() => _afterFrame(() async {
        if (_reviewOpen || !game.needsScoreboardResultReview) return;
        _reviewOpen = true;
        try {
          await openScoreboardResultReview(context, game);
        } finally {
          _reviewOpen = false;
        }
      });

  static String _resumeBody(MatchSnapshot snapshot) {
    final teams = snapshot.teams;
    final left = teams.elementAtOrNull(0);
    final right = teams.elementAtOrNull(1);
    final ageMin =
        ((DateTime.now().millisecondsSinceEpoch - snapshot.savedAtMs) / 60000).floor();
    final saved = ageMin <= 0 ? 'saved just now' : 'saved $ageMin min ago';
    final stage = switch (snapshot.stage) {
      'firstHalf' => '1st half',
      'halfTime' => 'Half-time',
      'secondHalf' => '2nd half',
      'fullTime' => 'Full-time',
      final s => s,
    };
    return '${left?.name ?? 'Team A'} ${left?.score ?? 0} – '
        '${right?.score ?? 0} ${right?.name ?? 'Team B'}\n$stage, $saved';
  }
}

Future<void> openScoreboardResultReview(BuildContext context, Game game) async {
  if (!game.needsScoreboardResultReview) return;
  await Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => ScoreboardResultReviewScreen(game: game)),
  );
}

class _LoadMatchDetails extends StatelessWidget {
  const _LoadMatchDetails({required this.config, required this.replacesMatch});
  final ScoreboardMatchConfig config;
  final bool replacesMatch;

  static const _heading = TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16);

  @override
  Widget build(BuildContext context) {
    final duration = formatMatchDuration(config.durationSeconds);
    final kickoff = formatLocalKickoff(config.scheduledStart);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${config.homeTeamName} vs ${config.awayTeamName}', style: _heading),
          _detail(config.venueShortName.isNotEmpty
              ? 'Field ${config.venueShortName} · $duration'
              : duration),
          if (kickoff != null) _detail('Kickoff $kickoff (local time)'),
          if (replacesMatch) _detail('⚠ This replaces the match in progress.', warning: true),
          const SizedBox(height: 12),
          _team(config.homeTeamName, config.homeInspectionRobots),
          const SizedBox(height: 10),
          _team(config.awayTeamName, config.awayInspectionRobots),
        ],
      ),
    );
  }

  Widget _detail(String line, {bool warning = false}) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(line,
            style: TextStyle(
              color: warning ? Colors.orangeAccent : Colors.white70,
              fontWeight: warning ? FontWeight.w600 : FontWeight.normal,
            )),
      );

  Widget _team(String name, List<InspectionRobot> robots) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(name, style: _heading.copyWith(decoration: TextDecoration.underline)),
          InspectionRobotList(robots: robots),
        ],
      );
}
