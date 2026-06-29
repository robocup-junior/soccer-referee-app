import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/models/scoreboard_result.dart';
import 'package:rcj_scoreboard/utils/colors.dart';
import 'package:rcj_scoreboard/widgets/critical_gesture_detector.dart';

/// Outcome of a submit attempt, derived from the outbox item's state shortly
/// after enqueuing, so the referee gets a clear message about what happened.
enum _SubmitOutcome { sent, conflict, rejected, queued }

class ScoreboardResultReviewScreen extends StatefulWidget {
  final Game game;

  const ScoreboardResultReviewScreen({required this.game, super.key});

  @override
  State<ScoreboardResultReviewScreen> createState() =>
      _ScoreboardResultReviewScreenState();
}

class _ScoreboardResultReviewScreenState
    extends State<ScoreboardResultReviewScreen> {
  late final ({
    String matchCode,
    String signature,
    String homeName,
    String awayName,
    int homeGoals,
    int awayGoals,
  }) _review;
  late int _homeGoals;
  late int _awayGoals;
  bool _homeConfirmed = false;
  bool _awayConfirmed = false;
  bool _submitting = false;
  final TextEditingController _commentController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _review = widget.game.buildScoreboardResultReview();
    _homeGoals = _review.homeGoals;
    _awayGoals = _review.awayGoals;
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  int _clampScore(int value) => value < 0 ? 0 : value;

  Future<void> _submit() async {
    if (_submitting) return;
    // Capture before the async gaps so we never touch a stale context after the
    // screen pops (the SnackBar rides the app-root messenger and survives it).
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _submitting = true);

    final enqueued = await widget.game.submitScoreboardResult(
      expectedSignature: _review.signature,
      homeGoals: _homeGoals,
      awayGoals: _awayGoals,
      comment: _commentController.text,
      homeConfirmed: _homeConfirmed,
      awayConfirmed: _awayConfirmed,
    );
    if (!mounted) return;
    if (!enqueued) {
      setState(() => _submitting = false);
      messenger.showSnackBar(const SnackBar(
        content: Text(
            'Could not submit — the result may already be submitted or the '
            'match changed.'),
      ));
      return;
    }

    // The result is now queued; the POST runs in the background. Watch the
    // outbox item briefly so we can tell the referee the actual outcome.
    final outcome = await _awaitOutcome(_review.matchCode);
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(_outcomeMessage(outcome))));
    navigator.pop();
  }

  /// Watch the outbox for this match's outcome. On a 200 the reset to the clean
  /// start state fires separately; on a conflict/rejection the match stays on
  /// the home screen with its error status so the referee can decide. A
  /// still-pending item at the deadline (offline OR a slow-but-succeeding POST —
  /// the request timeout is longer than this poll) is reported as queued.
  Future<_SubmitOutcome> _awaitOutcome(String matchCode) async {
    final state =
        await widget.game.scoreboardResultService.awaitOutboxOutcome(matchCode);
    switch (state) {
      case ResultSubmissionState.submitted:
        return _SubmitOutcome.sent;
      case ResultSubmissionState.conflict:
        return _SubmitOutcome.conflict;
      case ResultSubmissionState.failed:
        return _SubmitOutcome.rejected;
      case ResultSubmissionState.pending:
      case null:
        return _SubmitOutcome.queued;
    }
  }

  String _outcomeMessage(_SubmitOutcome outcome) {
    switch (outcome) {
      case _SubmitOutcome.sent:
        return 'Result sent successfully ✓';
      case _SubmitOutcome.conflict:
        return 'Already recorded on the server — check the status to decide.';
      case _SubmitOutcome.rejected:
        return 'Submission rejected — the link may be invalid or expired.';
      case _SubmitOutcome.queued:
        // The item is still pending at the deadline: this is EITHER offline OR
        // a slow-but-succeeding POST (the request timeout outlives this poll),
        // so the wording must not assert "no connection". It is saved either way
        // and the persistent status corrects to ✓ once it lands.
        return 'Saved — sending in the background.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Submit result',
                style: TextStyle(color: Colors.white, fontSize: 18)),
            Text(
              _review.matchCode,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---- Final result ---- (team names live here, so no separate
              // header line above is needed)
              _sectionHeader(
                'Final result',
                'The score sent to the scoreboard. Correct it here if needed.',
              ),
              _scoreEditor(
                label: _review.homeName,
                value: _homeGoals,
                onChanged: (value) =>
                    setState(() => _homeGoals = _clampScore(value)),
              ),
              const SizedBox(height: 10),
              _scoreEditor(
                label: _review.awayName,
                value: _awayGoals,
                onChanged: (value) =>
                    setState(() => _awayGoals = _clampScore(value)),
              ),
              const SizedBox(height: 18),

              // ---- Team confirmation ----
              _sectionHeader(
                'Team confirmation',
                'Tick a team that agrees with the result.',
              ),
              _confirmTile(
                name: _review.homeName,
                value: _homeConfirmed,
                onChanged: (value) =>
                    setState(() => _homeConfirmed = value ?? false),
              ),
              _confirmTile(
                name: _review.awayName,
                value: _awayConfirmed,
                onChanged: (value) =>
                    setState(() => _awayConfirmed = value ?? false),
              ),
              const SizedBox(height: 18),

              // ---- Comment ----
              _sectionHeader(
                'Comment',
                'Notes about the match (e.g. a protest or incident).',
              ),
              TextField(
                controller: _commentController,
                minLines: 2,
                maxLines: 3,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Add a note…',
                  hintStyle: const TextStyle(color: Colors.white38),
                  isDense: true,
                  filled: true,
                  fillColor: Colors.grey[850],
                  border: const OutlineInputBorder(),
                  enabledBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white70),
                  ),
                ),
              ),
              const SizedBox(height: 18),

              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _submitting
                          ? null
                          : () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Cancel'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white54),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    // Submit is a deliberate, post-match action (not an in-match
                    // robot/score/timer control), so the double-tap accidental-
                    // touch guard isn't needed here — always single-tap.
                    child: CriticalButton(
                      singleTap: true,
                      onAction:
                          _submitting ? () {} : () => unawaited(_submit()),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.green,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (_submitting)
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            )
                          else
                            const Icon(Icons.send),
                          const SizedBox(width: 8),
                          Text(_submitting ? 'Sending…' : 'Submit'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Section heading in the app's white/gray scheme — a thin rule for visual
  // separation (instead of a coloured title) plus a white label and gray hint.
  Widget _sectionHeader(String title, String hint) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(color: Colors.white24, height: 1, thickness: 1),
          const SizedBox(height: 10),
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            hint,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _confirmTile({
    required String name,
    required bool value,
    required ValueChanged<bool?> onChanged,
  }) {
    return CheckboxListTile(
      value: value,
      onChanged: onChanged,
      dense: true,
      visualDensity: VisualDensity.compact,
      title: Text(name, style: const TextStyle(color: Colors.white)),
      subtitle: const Text(
        'Confirmed by team',
        style: TextStyle(color: Colors.white70),
      ),
      activeColor: AppColors.green,
      checkColor: Colors.black,
      contentPadding: EdgeInsets.zero,
    );
  }

  Widget _scoreEditor({
    required String label,
    required int value,
    required ValueChanged<int> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white24),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
          IconButton(
            onPressed: () => onChanged(value - 1),
            icon: const Icon(Icons.remove_circle_outline),
            color: Colors.white,
          ),
          SizedBox(
            width: 44,
            child: Text(
              value.toString(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            onPressed: () => onChanged(value + 1),
            icon: const Icon(Icons.add_circle_outline),
            color: Colors.white,
          ),
        ],
      ),
    );
  }
}
