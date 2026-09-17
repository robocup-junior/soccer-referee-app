import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/screens/settings.dart';
import 'package:rcj_scoreboard/services/ble_adapter_monitor.dart';
import 'package:rcj_scoreboard/utils/colors.dart';
import 'package:rcj_scoreboard/utils/format.dart';
import 'package:rcj_scoreboard/widgets/app_dialogs.dart';
import 'package:rcj_scoreboard/widgets/bluetooth_banner.dart';
import 'package:rcj_scoreboard/widgets/critical_gesture_detector.dart';
import 'package:rcj_scoreboard/widgets/game_prompts.dart';
import 'package:rcj_scoreboard/widgets/module_button.dart';
import 'package:rcj_scoreboard/widgets/scrolling_status_text.dart';
import 'package:rcj_scoreboard/widgets/team_panel.dart';
import 'package:rcj_scoreboard/widgets/time_settings_sheet.dart';

/// The match control screen. Every critical action (score, start/stop, robot
/// control) goes through [CriticalGestureDetector]/[CriticalButton]: double-tap
/// by default, single-tap only via the explicit Settings opt-in.
class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  GamePrompts? _prompts;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Once: didChangeDependencies gives a context valid for showDialog.
    _prompts ??= GamePrompts(Provider.of<Game>(context, listen: false), context)..install();
  }

  @override
  void dispose() {
    _prompts?.uninstall();
    super.dispose();
  }

  Future<void> _openSettings(Game game) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen(game: game)));
    // Apply changed durations/player count to a fresh match; otherwise just
    // re-publish the current state.
    game.inGame ? game.broadcastFullState() : game.gameInit();
  }

  /// Long-press on the clock (#21): editable only while stopped inside a half.
  void _editRemainingTime(Game game) {
    if (game.isTimerRunning) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Stop the clock to edit the time.')));
      return;
    }
    if (!game.inGame ||
        (game.currentStage != MatchStage.firstHalf && game.currentStage != MatchStage.secondHalf)) {
      return;
    }
    showDarkSheet(context, heightFactor: 0.7, child: TimeSettingsWidget(game: game));
  }

  Future<void> _confirmExit() async {
    final exit = await showChoiceDialog(
      context,
      title: 'Exit',
      body: 'Do you want to exit application?',
      cancelText: 'Return',
      confirmText: 'Exit',
      confirmColor: Colors.red[500],
      dismissible: true,
    );
    if (exit == true) SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final game = Provider.of<Game>(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmExit();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          backgroundColor: AppColors.primary,
          title: const Text('RCJ Soccer - RefMate', style: TextStyle(color: Colors.white)),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings),
              color: Colors.white,
              onPressed: () => _openSettings(game),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                Consumer<BleAdapterMonitor>(
                  builder: (_, monitor, __) => BluetoothBanner(
                    state: monitor.state,
                    // iOS forbids toggling the radio from an app.
                    onTurnOn: (!kIsWeb && Platform.isAndroid)
                        ? () => FlutterBluePlus.turnOn().catchError((_) {})
                        : null,
                  ),
                ),
                Expanded(
                  flex: 6,
                  child: Row(
                    children: [
                      Expanded(child: TeamPanel(team: game.teams[0], game: game)),
                      Expanded(child: _clockColumn(game)),
                      Expanded(child: TeamPanel(team: game.teams[1], game: game)),
                    ],
                  ),
                ),
                Expanded(
                  flex: 20,
                  child: Row(
                    children: [
                      for (final team in game.teams)
                        Expanded(
                          child: Column(
                            children: [
                              for (final m in team.modules.where((m) => m.isEnabled))
                                ModuleButton(module: m, game: game),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(flex: 4, child: _allRobotsButton(game)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _clockColumn(Game game) {
    final service = game.scoreboardResultService;
    return Column(
      children: [
        GestureDetector(
          onLongPress: () => _editRemainingTime(game),
          child: Text(formatClock(game.remainingTime), style: const TextStyle(fontSize: 36)),
        ),
        Text(game.gameStageString),
        ScrollingStatusText(
          text: service.statusMessage,
          style: TextStyle(
              fontSize: 12, color: service.hasConflict ? Colors.orangeAccent : Colors.white70),
        ),
        SizedBox(
          width: double.infinity,
          // At full time a referee match has one action: submit the result.
          child: game.needsScoreboardResultReview
              ? ElevatedButton(
                  onPressed: () => openScoreboardResultReview(context, game),
                  style: _timerButtonStyle(AppColors.blue, horizontal: 8),
                  child: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('Submit result', style: TextStyle(color: Colors.white)),
                  ),
                )
              : CriticalButton(
                  singleTap: game.singleTapEnabled,
                  onAction: game.toggleTimer,
                  style: _timerButtonStyle(
                      game.isGameRunning && game.isTimerRunning ? AppColors.red : AppColors.green),
                  child: Text(game.timerButtonText, style: const TextStyle(color: Colors.white)),
                ),
        ),
      ],
    );
  }

  ButtonStyle _timerButtonStyle(Color color, {double horizontal = 12}) =>
      ElevatedButton.styleFrom(
        minimumSize: const Size(0, 36),
        padding: EdgeInsets.symmetric(horizontal: horizontal, vertical: 8),
        backgroundColor: color,
        foregroundColor: Colors.white,
      );

  Widget _allRobotsButton(Game game) {
    final (color, label) = game.currentStage == MatchStage.fullTime
        ? (AppColors.blue, 'DISCONNECT ALL ROBOTS')
        : game.isSomeonePlaying
            ? (AppColors.red, 'STOP ALL ROBOTS')
            : (AppColors.green, 'START ALL ROBOTS');
    return Container(
      margin: const EdgeInsets.all(4),
      width: double.infinity,
      child: CriticalButton(
        singleTap: game.singleTapEnabled,
        onAction: game.toggleAllModules,
        style: ElevatedButton.styleFrom(backgroundColor: color),
        child: Text(label, style: const TextStyle(color: Colors.white)),
      ),
    );
  }
}
