import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/models/module.dart';
import 'package:rcj_scoreboard/screens/module_settings.dart';
import 'package:rcj_scoreboard/utils/colors.dart';
import 'package:rcj_scoreboard/widgets/critical_gesture_detector.dart';

/// One robot slot on Home. Critical tap: play / penalise / stop the robot;
/// long-press opens the module's BLE settings.
class ModuleButton extends StatelessWidget {
  const ModuleButton({super.key, required this.module, required this.game});
  final Module module;
  final Game game;

  void _onAction() {
    if (game.noShowPenaltyGoalsActive) return;
    // No robots connected (#22): a tap records a penalty directly; tapping the
    // penalised module again clears it (Module.play on a damage slot).
    if (game.noModuleConnected &&
        game.isGameRunning &&
        module.state != ModuleState.damage) {
      module.penalty(game.penaltyTime);
    } else if (module.isPlaying) {
      game.isGameRunning ? module.penalty(game.penaltyTime) : module.stop();
    } else {
      module.play();
    }
  }

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider.value(
        value: module,
        child: Consumer<Module>(
          builder: (context, module, _) => Expanded(
            child: CriticalGestureDetector(
              singleTap: game.singleTapEnabled,
              onAction: _onAction,
              onLongPress: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChangeNotifierProvider.value(
                      value: module, child: const ModuleSettingsScreen()),
                ),
              ),
              child: Container(
                margin: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: module.isConnected
                      ? (module.isPlaying ? AppColors.green : AppColors.red)
                      : AppColors.blue,
                  borderRadius: BorderRadius.circular(10),
                  border: Border(
                    bottom: BorderSide(
                        width: 5,
                        color:
                            module.isPlaying ? AppColors.green : AppColors.red),
                  ),
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(module.name,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 30, color: Colors.white)),
                      Text(module.currentPenalty,
                          style: const TextStyle(
                              fontSize: 18, color: Colors.white)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}
