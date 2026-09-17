import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/models/scoreboard_result.dart';
import 'package:rcj_scoreboard/utils/colors.dart';
import 'package:rcj_scoreboard/widgets/critical_gesture_detector.dart';

/// Full-time review of a referee match: correct the score if needed, tick the
/// teams that confirmed it, add a note, submit.
class ScoreboardResultReviewScreen extends StatefulWidget {
  const ScoreboardResultReviewScreen({required this.game, super.key});
  final Game game;

  @override
  State<ScoreboardResultReviewScreen> createState() => _ScoreboardResultReviewScreenState();
}

class _ScoreboardResultReviewScreenState extends State<ScoreboardResultReviewScreen> {
  late final _review = widget.game.buildScoreboardResultReview();
  late int _homeGoals = _review.homeGoals;
  late int _awayGoals = _review.awayGoals;
  bool _homeConfirmed = false;
  bool _awayConfirmed = false;
  bool _submitting = false;
  final _commentController = TextEditingController();

  static const _white = TextStyle(color: Colors.white);

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    // Captured before the async gaps: the screen pops before the SnackBar.
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
          content: Text('Could not submit — the result may already be submitted or the match changed.')));
      return;
    }
    // The POST runs in the background; watch the outbox briefly to report the
    // outcome. Still pending at the deadline means offline OR merely slow.
    final state = await widget.game.scoreboardResultService.awaitOutboxOutcome(_review.matchCode);
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(switch (state) {
        ResultSubmissionState.submitted => 'Result sent successfully ✓',
        ResultSubmissionState.conflict => 'Already recorded on the server — check the status to decide.',
        ResultSubmissionState.failed => 'Submission rejected — the link may be invalid or expired.',
        ResultSubmissionState.pending || null => 'Saved — sending in the background.',
      }),
    ));
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.primary,
          iconTheme: const IconThemeData(color: Colors.white),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Submit result', style: TextStyle(color: Colors.white, fontSize: 18)),
              Text(_review.matchCode, style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ],
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header('Final result', 'The score sent to the scoreboard. Correct it here if needed.'),
                _scoreEditor(_review.homeName, _homeGoals, (v) => setState(() => _homeGoals = v)),
                const SizedBox(height: 10),
                _scoreEditor(_review.awayName, _awayGoals, (v) => setState(() => _awayGoals = v)),
                const SizedBox(height: 18),
                _header('Team confirmation', 'Tick a team that agrees with the result.'),
                _confirmTile(_review.homeName, _homeConfirmed, (v) => setState(() => _homeConfirmed = v ?? false)),
                _confirmTile(_review.awayName, _awayConfirmed, (v) => setState(() => _awayConfirmed = v ?? false)),
                const SizedBox(height: 18),
                _header('Comment', 'Notes about the match (e.g. a protest or incident).'),
                TextField(
                  controller: _commentController,
                  minLines: 2,
                  maxLines: 3,
                  style: _white,
                  decoration: InputDecoration(
                    hintText: 'Add a note…',
                    hintStyle: const TextStyle(color: Colors.white38),
                    isDense: true,
                    filled: true,
                    fillColor: Colors.grey[850],
                    border: const OutlineInputBorder(),
                    enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                    focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: Colors.white70)),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _submitting ? null : () => Navigator.of(context).pop(),
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
                      // A deliberate post-match action, not an in-match control:
                      // always single-tap.
                      child: CriticalButton(
                        singleTap: true,
                        onAction: _submitting ? () {} : () => unawaited(_submit()),
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
                                    strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)),
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

  Widget _header(String title, String hint) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Divider(color: Colors.white24, height: 1, thickness: 1),
            const SizedBox(height: 10),
            Text(title.toUpperCase(),
                style: const TextStyle(
                    color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 1.1)),
            const SizedBox(height: 2),
            Text(hint, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      );

  Widget _confirmTile(String name, bool value, ValueChanged<bool?> onChanged) => CheckboxListTile(
        value: value,
        onChanged: onChanged,
        dense: true,
        visualDensity: VisualDensity.compact,
        title: Text(name, style: _white),
        subtitle: const Text('Confirmed by team', style: TextStyle(color: Colors.white70)),
        activeColor: AppColors.green,
        checkColor: Colors.black,
        contentPadding: EdgeInsets.zero,
      );

  Widget _scoreEditor(String label, int value, ValueChanged<int> onChanged) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
            border: Border.all(color: Colors.white24), borderRadius: BorderRadius.circular(8)),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 16)),
            ),
            IconButton(
                onPressed: () => onChanged((value - 1).clamp(0, 999)),
                icon: const Icon(Icons.remove_circle_outline),
                color: Colors.white),
            SizedBox(
              width: 44,
              child: Text('$value',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600)),
            ),
            IconButton(
                onPressed: () => onChanged(value + 1),
                icon: const Icon(Icons.add_circle_outline),
                color: Colors.white),
          ],
        ),
      );
}
