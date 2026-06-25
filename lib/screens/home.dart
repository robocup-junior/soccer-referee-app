import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:rcj_scoreboard/screens/module_settings.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/models/team.dart';
import 'package:rcj_scoreboard/models/module.dart';
import 'package:flutter/services.dart';
import 'package:rcj_scoreboard/screens/settings.dart';
import 'package:rcj_scoreboard/utils/colors.dart';
import 'package:rcj_scoreboard/widgets/critical_gesture_detector.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:rcj_scoreboard/services/ble_adapter_monitor.dart';
import 'package:rcj_scoreboard/services/match_state_store.dart';
import 'package:rcj_scoreboard/screens/widgets/bluetooth_banner.dart';

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  bool _didSetupCallbacks = false;
  Game? _game;
  void Function()? _switchOrderCallback;
  void Function()? _resumeCallback;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Set up model callbacks once. Using didChangeDependencies (not initState)
    // ensures BuildContext is valid for showDialog. The _didSetupCallbacks flag
    // is what enforces once-only (didChangeDependencies can fire repeatedly);
    // the stable Game provider instance is what makes that guard safe. Read with
    // listen:false — this is a one-time install, not a subscription (build()
    // establishes the real listening relationship).
    if (!_didSetupCallbacks) {
      _didSetupCallbacks = true;
      _game = Provider.of<Game>(context, listen: false);
      final callbacks = setupGameCallbacks(_game!, context);
      _switchOrderCallback = callbacks.switchOrder;
      _resumeCallback = callbacks.resume;
    }
  }

  @override
  void dispose() {
    // Clear the dialog callbacks we installed so the long-lived Game does not
    // retain closures capturing this disposed State's context. Guard on
    // identity so we never clear a newer Home's callback.
    if (identical(_game?.onRequestSwitchTeamOrderDialog, _switchOrderCallback)) {
      _game?.onRequestSwitchTeamOrderDialog = null;
    }
    if (identical(_game?.onRequestResumeMatch, _resumeCallback)) {
      _game?.onRequestResumeMatch = null;
    }
    super.dispose();
  }

  void _navigateToSettings(context, Game game) async {
    final updatedGame = await Navigator.push<Game>(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsScreen(game: game),
      ),
    );

    if (updatedGame != null) {
      if (!game.inGame) {
        game.gameInit();
      } else {
        game.gameRefresh();
      }
    }
  }

  // Long-press the remaining-time display to manually correct the clock
  // (issue #21). Editing is only allowed while the clock is stopped within an
  // active first or second half — this keeps the run-clock catch-up anchors
  // out of the picture (see Game.setRemainingTime). Half-time is excluded
  // because its clock runs continuously (the firstHalf->halfTime transition
  // calls startTimer() and SKIP jumps straight to the second half, so there is
  // no stopped half-time state); pre-match setup (inGame == false) is excluded
  // so the match duration is only changed via Settings; full time is excluded
  // by the stage check. The double-tap start/stop toggle lives on the button
  // below and is intentionally left untouched.
  void _editRemainingTime(BuildContext context, Game game) {
    if (game.isTimerRunning) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Stop the clock to edit the time.')),
      );
      return;
    }
    if (!game.inGame ||
        (game.currentStage != MatchStage.firstHalf &&
            game.currentStage != MatchStage.secondHalf)) {
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return FractionallySizedBox(
          heightFactor: 0.7,
          child: Container(
            color: Colors.grey[800],
            padding:
                const EdgeInsets.symmetric(vertical: 20.0, horizontal: 20.0),
            child: TimeSettingsWidget(game: game),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final game = Provider.of<Game>(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        debugPrint("didPop1: $didPop");
        if (didPop) {
          return;
        }
        final bool shouldPop = await _showExitDialog(context);
        if (shouldPop) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          backgroundColor: AppColors.primary,
          title: const Text('RCJ Soccer - RefMate',
              style: TextStyle(color: Colors.white)),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings),
              color: Colors.white,
              onPressed: () {
                _navigateToSettings(context, game);
              },
                // Navigate to config page
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              children: <Widget>[
                Consumer<BleAdapterMonitor>(
                  builder: (context, monitor, _) => BluetoothBanner(
                    state: monitor.state,
                    // FlutterBluePlus.turnOn() is Android-only; on iOS it throws
                    // and the OS forbids toggling the radio from an app, so we
                    // offer no button there (the banner hint guides the user).
                    onTurnOn: (!kIsWeb && Platform.isAndroid)
                        ? () {
                            FlutterBluePlus.turnOn().catchError((_) {});
                          }
                        : null,
                  ),
                ),
                Expanded(
                  flex: 6,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        flex: 1,
                        child: buildTeamContainer(game.teams[0], game),
                      ),
                      Expanded(
                        flex: 1,
                        child: Column(
                          children: [
                            GestureDetector(
                              onLongPress: () => _editRemainingTime(context, game),
                              child: Text(
                                  '${(game.remainingTime ~/ 60).toString().padLeft(2, '0')}:${(game.remainingTime % 60).toString().padLeft(2, '0')}',
                                  style: const TextStyle(fontSize: 36.0)),
                            ),
                            Text(game.gameStageString),
                            Text(
                              game.scoreboardResultService.statusMessage,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: game.scoreboardResultService.hasConflict
                                    ? Colors.orangeAccent
                                    : Colors.white70,
                              ),
                            ),
                            SizedBox(
                              width: double.infinity,
                              child: CriticalButton(
                                singleTap: game.singleTapEnabled,
                                onAction: () => game.toggleTimer(),
                                style: ElevatedButton.styleFrom(
                                  minimumSize: const Size(0, 36),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  backgroundColor: (game.isGameRunning
                                      ? (game.isTimerRunning
                                          ? AppColors.red
                                          : AppColors.green)
                                      : AppColors.green),
                                ),
                                child: Text(game.timerButtonText,
                                    style: const TextStyle(color: Colors.white)),
                              ),
                            )
                          ],
                        ),
                      ),
                      Expanded(
                        flex: 1,
                        //child: buildTeamContainer(game.teams[1], game),
                        child: buildTeamContainer(game.teams[1], game),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 20,
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          children: (game.teams[0].modules)
                              .where((module) => module.isEnabled)
                              .map((module) => buildModuleButton(module, game))
                              .toList(),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          children: (game.teams[1].modules)
                              .where((module) => module.isEnabled)
                              .map((module) => buildModuleButton(module, game))
                              .toList(),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: Container(
                    margin: const EdgeInsets.all(4.0),
                    width: double.infinity,
                    //height: 70.0,
                    child: CriticalButton(
                      singleTap: game.singleTapEnabled,
                      onAction: () => game.toggleAllModules(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            (game.currentStage == MatchStage.fullTime
                                ? AppColors.blue
                                : (game.isSomeonePlaying
                                    ? AppColors.red
                                    : AppColors.green)),
                        // shape: RoundedRectangleBorder(
                        //   borderRadius: BorderRadius.circular(30.0),
                        // )
                      ),
                      child: Text(
                          game.currentStage == MatchStage.fullTime
                              ? 'DISCONNECT ALL ROBOTS'
                              : (game.isSomeonePlaying
                                  ? 'STOP ALL ROBOTS'
                                  : 'START ALL ROBOTS'),
                          style: const TextStyle(color: Colors.white)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget buildModuleButton(Module module, Game game) {
  return ChangeNotifierProvider.value(
    value: module,
    child: Consumer<Module>(
      builder: (context, module, child) {
        return Expanded(
          child: CriticalGestureDetector(
            singleTap: game.singleTapEnabled,
            onAction: () {
              if (module.isPlaying) {
                if (game.isGameRunning) {
                  module.penalty(game.penaltyTime);
                } else {
                  module.stop();
                }
              } else {
                module.play();
              }
            },
            onLongPress: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ChangeNotifierProvider.value(
                  value: module,
                  child: const ModuleSettingsScreen(),
                ),
              ),
            ),
            // onLongPress: () => Navigator.push(context,
            //   MaterialPageRoute(builder: (context) => ModuleSettingsScreen(module: module)),
            // ),
            child: Container(
              margin: const EdgeInsets.all(4.0),
              decoration: BoxDecoration(
                  color: module.isConnected
                      ? (module.isPlaying ? AppColors.green : AppColors.red)
                      : AppColors.blue,
                  borderRadius: BorderRadius.circular(
                      10.0), // Adjust this value to control the roundness
                  border: Border(
                      bottom: BorderSide(
                    width: 5,
                    color: module.isPlaying ? AppColors.green : AppColors.red,
                  ))),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      module.name,
                      textAlign:
                          TextAlign.center, // Ensure the text is centered
                      style: const TextStyle(fontSize: 30, color: Colors.white),
                    ),
                    Text(
                      module.currentPenalty,
                      style: const TextStyle(fontSize: 18, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

Widget buildTeamContainer(Team team, Game game) {
  return ChangeNotifierProvider.value(
    value: team,
    child: Consumer<Team>(
      builder: (context, team, child) {
        return CriticalGestureDetector(
          singleTap: game.singleTapEnabled,
          onAction: () {
            team.addScore(1);
            game.stopAll(true);
            game.notifyModulesScore();
          },
          onLongPress: () {
            showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (context) {
                  return FractionallySizedBox(
                    heightFactor: 0.7,
                    child: Container(
                      color: Colors.grey[800],
                      padding: const EdgeInsets.symmetric(vertical: 20.0, horizontal: 20.0),
                      child: TeamSettingsWidget(team: team, game: game),
                    ),
                  );
                });
          },
          child: Container(

            // color bar for displaying team top mark
            decoration: BoxDecoration(
              color: Colors.transparent,
              border: Border(
                top: BorderSide(
                  color: team.id == "A" ? const Color(0xFF77FF00) : const Color(0xFFFF00FF), // Neon green or neon magenta
                  width: 5,
                ),
              ),
            ),

            //color: Colors.transparent,  // uncomment when no color bar is needed
            margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            child: Column(
              children: [
                Text(
                  team.name,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 3,
                ),
                const Spacer(),
                Text(team.score.toString(),
                    style: const TextStyle(fontSize: 40.0)),
              ],
            ),
          ),
        );
      },
    ),
  );
}

// Widget teamSettings(Team team, Game game) {
//   TextEditingController _nameController = TextEditingController(text: team.name);
//
//   return Column(
//     children: [
//       Text(
//         '${team.id == "team_a" ? "Team A" : team.id == "team_b" ? "Team B" : team.id} Config',
//         style: const TextStyle(
//           fontSize: 24.0,
//           color: Colors.white,
//         ),
//       ),
//       const Divider(),
//       SizedBox(height: 20.0),
//       Row(
//         children: [
//           Expanded(
//             flex: 2,
//             child: Text('Team Name', style: TextStyle(fontSize: 16.0)),
//           ),
//           Expanded(
//             flex: 4,
//             child: TextField(
//               controller: _nameController,
//               style: TextStyle(color: Colors.white),
//               decoration: InputDecoration(
//                 border: OutlineInputBorder(),
//                 filled: true,
//                 fillColor: Colors.grey[800],
//               ),
//               onSubmitted: (value) {
//                 team.name = value;
//                 //game.notifyListeners();
//               },
//             ),
//           ),
//         ],
//       ),
//       SizedBox(height: 20.0),
//       Row(
//         mainAxisAlignment: MainAxisAlignment.spaceEvenly,
//         children: [
//           Text('Score', style: TextStyle(fontSize: 16.0)),
//           ElevatedButton.icon(
//             onPressed: () {
//               team.addScore(-1);
//               game.notifyModulesScore();
//             },
//             style: ElevatedButton.styleFrom(
//               backgroundColor: Colors.blue,
//             ),
//             icon: Icon(Icons.remove, color: Colors.white),
//             label: Text('Sub', style: TextStyle(color: Colors.white)),
//           ),
//           ElevatedButton.icon(
//             style: ElevatedButton.styleFrom(
//               backgroundColor: Colors.blue,
//             ),
//             icon: Icon(Icons.add, color: Colors.white),
//             label: Text('Add', style: TextStyle(color: Colors.white)),
//             onPressed: () {
//               team.addScore(1);
//               game.notifyModulesScore();
//             },
//           ),
//         ],
//       ),
//     ],
//   );
// }
//














class TeamSettingsWidget extends StatefulWidget {
  final Team team;
  final Game game;

  const TeamSettingsWidget({required this.team, required this.game, super.key});

  @override
  State<TeamSettingsWidget> createState() => _TeamSettingsWidgetState();
}

class _TeamSettingsWidgetState extends State<TeamSettingsWidget> {
  late TextEditingController _nameController;
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.team.name);
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final team = widget.team;
    final game = widget.game;
    return Column(
      children: [
        Text(
          '${team.id == "A" ? "Team A" : team.id == "B" ? "Team B" : team.id} Config',
          style: const TextStyle(
            fontSize: 24.0,
            color: Colors.white,
          ),
        ),
        const Divider(),
        const SizedBox(height: 20.0),
        Row(
          children: [
            const Expanded(
              flex: 2,
              child: Text('Team Name', style: TextStyle(fontSize: 16.0)),
            ),
            Expanded(
              flex: 4,
              child: TextField(
                controller: _nameController,
                focusNode: _focusNode,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  filled: true,
                  fillColor: Colors.grey[800],
                ),
                onSubmitted: (value) {
                  // Route through Game.setTeamName so the edit also persists
                  // into the cold-resume snapshot (a direct team.name = bypasses
                  // every persistence chokepoint).
                  game.setTeamName(team, value);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 20.0),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            const Text('Score', style: TextStyle(fontSize: 16.0)),
            ElevatedButton.icon(
              onPressed: () {
                team.addScore(-1);
                game.notifyModulesScore();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
              ),
              icon: const Icon(Icons.remove, color: Colors.white),
              label: const Text('Sub', style: TextStyle(color: Colors.white)),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
              ),
              icon: const Icon(Icons.add, color: Colors.white),
              label: const Text('Add', style: TextStyle(color: Colors.white)),
              onPressed: () {
                team.addScore(1);
                game.notifyModulesScore();
              },
            ),
          ],
        ),
      ],
    );
  }
}

// Parse a remaining-time entry, accepting either a plain nonnegative seconds
// integer ("123") or "mm:ss" with a nonnegative minutes part and a seconds part
// in 0..59. Returns null for anything else ("5:99", "1:2:3", ":30", "", "ab"),
// so a referee typo is ignored rather than silently applied as a bad
// correction. Top-level + pure so it is unit-testable without a widget.
int? parseMmSs(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  if (text.contains(':')) {
    final parts = text.split(':');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
    final minutes = int.tryParse(parts[0]);
    final secs = int.tryParse(parts[1]);
    if (minutes == null || secs == null) return null;
    if (minutes < 0 || secs < 0 || secs > 59) return null;
    return minutes * 60 + secs;
  }
  final seconds = int.tryParse(text);
  if (seconds == null || seconds < 0) return null;
  return seconds;
}

// Bottom-sheet editor for the remaining match time (issue #21). Mirrors
// TeamSettingsWidget: quick +/- nudges plus an mm:ss field for a precise jump.
// Only shown while the clock is stopped (gated in Home._editRemainingTime), so
// it never has to reconcile a running clock.
class TimeSettingsWidget extends StatefulWidget {
  final Game game;

  const TimeSettingsWidget({required this.game, super.key});

  @override
  State<TimeSettingsWidget> createState() => _TimeSettingsWidgetState();
}

class _TimeSettingsWidgetState extends State<TimeSettingsWidget> {
  late TextEditingController _timeController;

  @override
  void initState() {
    super.initState();
    _timeController = TextEditingController(text: _format(widget.game.remainingTime));
  }

  @override
  void dispose() {
    _timeController.dispose();
    super.dispose();
  }

  String _format(int seconds) =>
      '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';

  void _apply(int seconds) {
    widget.game.setRemainingTime(seconds);
    // Reflect the clamped, authoritative value back into the field.
    _timeController.text = _format(widget.game.remainingTime);
  }

  void _nudge(int delta) => _apply(widget.game.remainingTime + delta);

  void _applyFromField() {
    final parsed = parseMmSs(_timeController.text);
    if (parsed != null) {
      _apply(parsed);
    } else {
      // Restore the current value if the entry was invalid.
      _timeController.text = _format(widget.game.remainingTime);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Text(
          'Edit remaining time',
          style: TextStyle(fontSize: 24.0, color: Colors.white),
        ),
        const Divider(),
        const SizedBox(height: 20.0),
        Row(
          children: [
            const Expanded(
              flex: 2,
              child: Text('Time (mm:ss)', style: TextStyle(fontSize: 16.0)),
            ),
            Expanded(
              flex: 3,
              child: TextField(
                controller: _timeController,
                keyboardType: TextInputType.datetime,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  filled: true,
                  fillColor: Colors.grey[800],
                ),
                onSubmitted: (_) => _applyFromField(),
              ),
            ),
            const SizedBox(width: 8.0),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
              onPressed: _applyFromField,
              child: const Text('Set', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
        const SizedBox(height: 20.0),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _nudgeButton('-1:00', () => _nudge(-60)),
            _nudgeButton('-0:30', () => _nudge(-30)),
            _nudgeButton('+0:30', () => _nudge(30)),
            _nudgeButton('+1:00', () => _nudge(60)),
          ],
        ),
      ],
    );
  }

  Widget _nudgeButton(String label, VoidCallback onPressed) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
      onPressed: onPressed,
      child: Text(label, style: const TextStyle(color: Colors.white)),
    );
  }
}

/// Installs the half-time "switch team order" dialog and the cold-resume prompt
/// callbacks on [game], returning the exact closures assigned so the caller can
/// clear them on dispose (both capture [context]).
({void Function() switchOrder, void Function() resume}) setupGameCallbacks(
    Game game, BuildContext context) {
  // A local function declaration (not a `final ... = () {}` variable) to satisfy
  // the analyzer's prefer_function_declarations_over_variables lint, which CI
  // runs as fatal (`flutter analyze --fatal-infos`).
  void callback() async {
    bool? switchOrder = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[800],
        title: const Text("Switch Team Order", style: TextStyle(color: Colors.white)),
        content: const Text("Do you want to switch the team order for the second half?"),
        actions: [Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Expanded(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.grey[600],
                ),
                onPressed: () {
                  Navigator.of(context).pop(false); // Keep current order
                },
                child: const Text("No", style: TextStyle(color: Colors.white)),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.grey[600],
                ),
                onPressed: () {
                  Navigator.of(context).pop(true); // Switch order
                },
                child: const Text("Yes", style: TextStyle(color: Colors.white)),
              ),
            ),
          ],
        ),
        ],
      ),
    );

    if (switchOrder == true) {
      game.toggleTeamOrder(); // Switch team order
    }
  }
  game.onRequestSwitchTeamOrderDialog = callback;

  // Cold-resume prompt (#45). Non-destructive: Resume is the prominent default;
  // Discard requires a deliberate second confirmation so a stray tap can never
  // wipe an in-progress match (double-tap safety invariant). The dialog is
  // non-dismissible (no barrier/back-button escape into neither path). A named
  // function declaration (not a `final x = () {}` variable) to satisfy the
  // analyzer's prefer_function_declarations_over_variables lint (fatal in CI).
  void resumeCallback() {
    // The draining setter may invoke this synchronously while callbacks are
    // installed in didChangeDependencies, so defer to after the frame —
    // showDialog() during build throws.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final snapshot = game.pendingResume;
      if (snapshot == null) return;
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: Colors.grey[800],
          title: const Text('Resume match in progress?',
              style: TextStyle(color: Colors.white)),
          content: Text(_resumeMatchBody(snapshot),
              style: const TextStyle(color: Colors.white)),
          actions: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey[600],
                    ),
                    onPressed: () async {
                      final confirmed = await _confirmDiscardMatch(dialogContext);
                      if (confirmed == true) {
                        await game.discardPendingMatch();
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop();
                        }
                      }
                    },
                    child: const Text('Discard',
                        style: TextStyle(color: Colors.white)),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green[600],
                    ),
                    onPressed: () {
                      game.resumePendingMatch();
                      Navigator.of(dialogContext).pop();
                    },
                    child: const Text('Resume',
                        style: TextStyle(color: Colors.white)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      );
    });
  }
  game.onRequestResumeMatch = resumeCallback;

  return (switchOrder: callback, resume: resumeCallback);
}

String _resumeMatchBody(MatchSnapshot snapshot) {
  final teams = snapshot.teams;
  final leftName = teams.isNotEmpty ? teams[0].name : 'Team A';
  final rightName = teams.length > 1 ? teams[1].name : 'Team B';
  final leftScore = teams.isNotEmpty ? teams[0].score : 0;
  final rightScore = teams.length > 1 ? teams[1].score : 0;
  final ageMin =
      ((DateTime.now().millisecondsSinceEpoch - snapshot.savedAtMs) / 60000)
          .floor();
  final saved = ageMin <= 0 ? 'saved just now' : 'saved $ageMin min ago';
  return '$leftName $leftScore – $rightScore $rightName\n'
      '${_resumeStageLabel(snapshot.stage)}, $saved';
}

String _resumeStageLabel(String stageName) {
  switch (stageName) {
    case 'firstHalf':
      return '1st half';
    case 'halfTime':
      return 'Half-time';
    case 'secondHalf':
      return '2nd half';
    case 'fullTime':
      return 'Full-time';
    default:
      return stageName;
  }
}

Future<bool?> _confirmDiscardMatch(BuildContext context) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: Colors.grey[800],
        title: const Text('Discard match?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
            'This permanently deletes the saved match and cannot be undone.',
            style: TextStyle(color: Colors.white)),
        actions: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey[600],
                  ),
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel',
                      style: TextStyle(color: Colors.white)),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red[600],
                  ),
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Discard',
                      style: TextStyle(color: Colors.white)),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

Future<bool> _showExitDialog(BuildContext context) async {
  bool? exitApp = await showDialog(
      context: context,
      useSafeArea: true,
      builder: (context) => AlertDialog(
            backgroundColor: Colors.grey[800],
            title: const Text("Exit", style: TextStyle(color: Colors.white)),
            content: const Text('Do you want to exit application?'),
            actions: [
              ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red[500],
                  ),
                  onPressed: () {
                    Navigator.of(context).pop(true);
                  },
                  child: const Text('Exit',
                      style: TextStyle(color: Colors.white))),
              ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue[500],
                  ),
                  onPressed: () {
                    Navigator.of(context).pop(false);
                  },
                  child: const Text(
                    'Return',
                    style: TextStyle(color: Colors.white),
                  )),
            ],
          ));
  return exitApp ?? false;
}
