import 'package:rcj_scoreboard/models/scoreboard_result.dart';

/// The link between the live referee match and a scoreboard fixture.
///
/// Team 'A' is always the left side and 'B' the right; `homeIsLeft` decides
/// which physical team is "home" ([deriveSides] is the single source of that
/// rule). The signatures dedupe applies/prompts/pairings; the resumed-fixture
/// fields let a cold-resumed match stay bound to the fixture it was playing
/// even when its config surfaces late or a different link is opened.
class ScoreboardBinding {
  String? homeTeamId;
  String? awayTeamId;

  /// A resumed match's final result stays suppressed until its bound fixture's
  /// config has surfaced (or forever, if a different fixture is loaded).
  bool suppressFinalResult = false;
  String? resumedMatchCode;
  int? resumedVersion;

  /// Signature of the last applied fixture (dedupes automatic re-applies).
  String? appliedSignature;

  /// MAC-set fingerprint of the last module auto-pair.
  String? pairedMacsSignature;

  /// Signature of the fixture whose result is reviewable at full time.
  String? fullTimeSignature;

  /// Signature of the last "Load match?" prompt raised.
  String? promptedSignature;

  /// Signature of the fixture the user just CONFIRMED loading; consumed by the
  /// next apply so a confirmed Load (which resets a live match) is never
  /// mistaken for an automatic refresh.
  String? confirmedLoadSignature;
  Future<void>? confirmedLoadClear;

  bool get isBoundToResumed => resumedMatchCode?.isNotEmpty ?? false;

  void deriveSides(ScoreboardMatchConfig config) {
    homeTeamId = config.homeIsLeft ? 'A' : 'B';
    awayTeamId = config.homeIsLeft ? 'B' : 'A';
  }

  /// Between-matches reset (gameInit). Keeps the side mapping and the applied
  /// signature: the fixture is still loaded, only the match is fresh.
  void resetForNewMatch() {
    pairedMacsSignature = null;
    suppressFinalResult = false;
    resumedMatchCode = null;
    resumedVersion = null;
    fullTimeSignature = null;
  }

  /// Drop the whole binding (result delivered, or drift to another fixture).
  void unbind() {
    homeTeamId = null;
    awayTeamId = null;
    appliedSignature = null;
    resetForNewMatch();
  }

  /// Restore a resumed match's binding from its snapshot.
  void bindResumed({
    required String? homeTeamId,
    required String? awayTeamId,
    required String? matchCode,
    required int? version,
  }) {
    this.homeTeamId = homeTeamId;
    this.awayTeamId = awayTeamId;
    resumedMatchCode = matchCode;
    resumedVersion = version;
  }

  /// Final gate before a POST: a submittable fixture (non-empty code), not
  /// suppressed, and not drifted away from the fixture a resume was bound to.
  bool canSubmit(ScoreboardMatchConfig? config) {
    if (config == null || config.matchCode.isEmpty) return false;
    if (suppressFinalResult) return false;
    return !isBoundToResumed || config.matchCode == resumedMatchCode;
  }

  /// MAC-set fingerprint. MACs are hex + colons, so the delimiters can't alias.
  static String macSignature(ScoreboardMatchConfig c) =>
      '${c.homeIsLeft}|${c.homeModuleMacs.join(',')}|${c.awayModuleMacs.join(',')}';
}
