import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:rcj_scoreboard/screens/module_settings.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/models/team.dart';
import 'package:rcj_scoreboard/models/module.dart';
import 'package:flutter/services.dart';
import 'package:rcj_scoreboard/screens/settings.dart';
import 'package:rcj_scoreboard/utils/colors.dart';

class Home extends StatelessWidget {
  Home({super.key});

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

  @override
  Widget build(BuildContext context) {
    final game = Provider.of<Game>(context);
    setupGameCallbacks(game, context);

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
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
              icon: Icon(Icons.settings),
              color: Colors.white,
              onPressed: () {
                _navigateToSettings(context, game);
              },
                // Navigate to config page
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            children: <Widget>[
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
                          Text(
                              '${(game.remainingTime ~/ 60).toString().padLeft(2, '0')}:${(game.remainingTime % 60).toString().padLeft(2, '0')}',
                              style: const TextStyle(fontSize: 40.0)),
                          Text(game.gameStageString),
                          Container(
                            width: double.infinity,
                            child: GestureDetector(
                              onDoubleTap: () {
                                game.toggleTimer();
                              },
                              child: ElevatedButton(
                                onPressed: () {},
                                style: ElevatedButton.styleFrom(
                                  //minimumSize: const Size(120, 50),
                                  backgroundColor: (game.isGameRunning
                                      ? (game.isTimerRunning
                                          ? AppColors.red
                                          : AppColors.green)
                                      : AppColors.green),
                                ),
                                child: Text(game.timerButtonText,
                                    style: TextStyle(color: Colors.white)),
                              ),
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
                  child: GestureDetector(
                    onDoubleTap: () {
                      game.toggleAllModules();
                    },
                    child: ElevatedButton(
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
                          style: TextStyle(color: Colors.white)),
                      onPressed: () {},
                    ),
                  ),
                ),
              ),
            ],
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
          child: GestureDetector(
            onDoubleTap: () {
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
                  child: ModuleSettingsScreen(),
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
        return GestureDetector(
          onDoubleTap: () {
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
                      padding: EdgeInsets.symmetric(vertical: 20.0, horizontal: 20.0),
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

  const TeamSettingsWidget({Key? key, required this.team, required this.game}) : super(key: key);

  @override
  _TeamSettingsWidgetState createState() => _TeamSettingsWidgetState();
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
        SizedBox(height: 20.0),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: Text('Team Name', style: TextStyle(fontSize: 16.0)),
            ),
            Expanded(
              flex: 4,
              child: TextField(
                controller: _nameController,
                focusNode: _focusNode,
                style: TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  border: OutlineInputBorder(),
                  filled: true,
                  fillColor: Colors.grey[800],
                ),
                onSubmitted: (value) {
                  team.name = value;
                  game.notifyMQTT();
                },
              ),
            ),
          ],
        ),
        SizedBox(height: 20.0),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Text('Score', style: TextStyle(fontSize: 16.0)),
            ElevatedButton.icon(
              onPressed: () {
                team.addScore(-1);
                game.notifyModulesScore();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
              ),
              icon: Icon(Icons.remove, color: Colors.white),
              label: Text('Sub', style: TextStyle(color: Colors.white)),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
              ),
              icon: Icon(Icons.add, color: Colors.white),
              label: Text('Add', style: TextStyle(color: Colors.white)),
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






















void setupGameCallbacks(Game game, BuildContext context) {
  game.onRequestSwitchTeamOrderDialog = () async {
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
            SizedBox(width: 16),
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
  };
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
