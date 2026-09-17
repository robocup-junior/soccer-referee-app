import 'package:flutter/material.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/utils/colors.dart';
import 'package:rcj_scoreboard/utils/format.dart';

/// Bottom-sheet editor for the remaining match time (#21): +/- nudges plus an
/// mm:ss field. Only opened while the clock is stopped.
class TimeSettingsWidget extends StatefulWidget {
  const TimeSettingsWidget({super.key, required this.game});
  final Game game;

  @override
  State<TimeSettingsWidget> createState() => _TimeSettingsWidgetState();
}

class _TimeSettingsWidgetState extends State<TimeSettingsWidget> {
  late final _controller = TextEditingController(text: formatClock(widget.game.remainingTime));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _apply(int? seconds) {
    if (seconds != null) widget.game.setRemainingTime(seconds);
    // Reflect the clamped, authoritative value (or restore it on bad input).
    _controller.text = formatClock(widget.game.remainingTime);
  }

  @override
  Widget build(BuildContext context) {
    final buttonStyle = ElevatedButton.styleFrom(backgroundColor: Colors.blue);
    Widget nudge(String label, int delta) => ElevatedButton(
          style: buttonStyle,
          onPressed: () => _apply(widget.game.remainingTime + delta),
          child: Text(label, style: const TextStyle(color: Colors.white)),
        );
    return Column(
      children: [
        const Text('Edit remaining time', style: TextStyle(fontSize: 24, color: Colors.white)),
        const Divider(),
        const SizedBox(height: 20),
        Row(
          children: [
            const Expanded(flex: 2, child: Text('Time (mm:ss)', style: TextStyle(fontSize: 16))),
            Expanded(
              flex: 3,
              child: TextField(
                controller: _controller,
                keyboardType: TextInputType.datetime,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                    border: OutlineInputBorder(), filled: true, fillColor: AppColors.sheet),
                onSubmitted: (_) => _apply(parseMmSs(_controller.text)),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              style: buttonStyle,
              onPressed: () => _apply(parseMmSs(_controller.text)),
              child: const Text('Set', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [nudge('-1:00', -60), nudge('-0:30', -30), nudge('+0:30', 30), nudge('+1:00', 60)],
        ),
      ],
    );
  }
}
