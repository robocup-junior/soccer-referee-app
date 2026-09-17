import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/models/team.dart';
import 'package:rcj_scoreboard/utils/colors.dart';
import 'package:rcj_scoreboard/widgets/app_dialogs.dart';
import 'package:rcj_scoreboard/widgets/critical_gesture_detector.dart';
import 'package:rcj_scoreboard/widgets/inspection_robot_list.dart';

/// A team's name + score on Home. Critical tap scores a goal (and stops all
/// robots); long-press opens the team editor sheet.
class TeamPanel extends StatelessWidget {
  const TeamPanel({super.key, required this.team, required this.game});
  final Team team;
  final Game game;

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider.value(
        value: team,
        child: Consumer<Team>(
          builder: (context, team, _) => CriticalGestureDetector(
            singleTap: game.singleTapEnabled,
            onAction: () {
              if (game.noShowPenaltyGoalsActive) return;
              team.addScore(1);
              game.stopAll(true);
              game.notifyModulesScore();
            },
            onLongPress: () => showDarkSheet(context,
                heightFactor: 0.85, child: TeamSettingsWidget(team: team, game: game)),
            child: Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: AppColors.team(team.id), width: 5)),
              ),
              margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: Column(
                children: [
                  Text(team.name,
                      textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, maxLines: 3),
                  const Spacer(),
                  Text('${team.score}', style: const TextStyle(fontSize: 40)),
                ],
              ),
            ),
          ),
        ),
      );
}

/// Bottom-sheet editor: team name, score +/- and the fixture's inspection rows.
class TeamSettingsWidget extends StatefulWidget {
  const TeamSettingsWidget({super.key, required this.team, required this.game});
  final Team team;
  final Game game;

  @override
  State<TeamSettingsWidget> createState() => _TeamSettingsWidgetState();
}

class _TeamSettingsWidgetState extends State<TeamSettingsWidget> {
  late final _nameController = TextEditingController(text: widget.team.name);

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _score(int delta) {
    widget.team.addScore(delta);
    widget.game.notifyModulesScore();
  }

  @override
  Widget build(BuildContext context) {
    final team = widget.team;
    final robots = widget.game.inspectionRobotsForTeam(team);
    return Column(
      children: [
        Text('Team ${team.id} Config', style: const TextStyle(fontSize: 24, color: Colors.white)),
        const Divider(),
        const SizedBox(height: 20),
        Row(
          children: [
            const Expanded(flex: 2, child: Text('Team Name', style: TextStyle(fontSize: 16))),
            Expanded(
              flex: 4,
              child: TextField(
                controller: _nameController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                    border: OutlineInputBorder(), filled: true, fillColor: AppColors.sheet),
                // Through Game so the edit persists into the resume snapshot.
                onSubmitted: (value) => widget.game.setTeamName(team, value),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            const Text('Score', style: TextStyle(fontSize: 16)),
            _scoreButton(Icons.remove, 'Sub', () => _score(-1)),
            ListenableBuilder(
              listenable: team,
              builder: (_, __) => Text('${team.score}',
                  style: const TextStyle(
                      fontSize: 28, color: Colors.white, fontWeight: FontWeight.bold)),
            ),
            _scoreButton(Icons.add, 'Add', () => _score(1)),
          ],
        ),
        // Own scroll area so a long inspection note never pushes the score
        // controls out of reach.
        if (robots.isNotEmpty)
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 20),
                  const Text('Inspection',
                      style: TextStyle(
                          fontSize: 16, color: Colors.white70, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  InspectionRobotList(robots: robots),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _scoreButton(IconData icon, String label, VoidCallback onPressed) =>
      ElevatedButton.icon(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
        icon: Icon(icon, color: Colors.white),
        label: Text(label, style: const TextStyle(color: Colors.white)),
      );
}
