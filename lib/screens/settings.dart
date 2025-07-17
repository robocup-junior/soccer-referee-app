import 'package:flutter/material.dart';
import '../models/game.dart';
import '../services/mqtt.dart';
import '../utils/colors.dart';

class SettingsScreen extends StatefulWidget {
  final Game game;

  SettingsScreen({required this.game});

  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late SetItem _selectedGameDuration;
  late SetItem _selectedHalftimeBreak;
  late SetItem _selectedNumberOfPlayers;
  late SetItem _selectedPenaltyTime;

  final List<SetItem> _gameDurations = [
    SetItem('2 mins', 60),
    SetItem('4 mins', 120),
    SetItem('8 mins', 240),
    SetItem('10 mins', 300),
    SetItem('20 mins', 600),
  ];

  final List<SetItem> _halftimeBreaks = [
    SetItem('1 min', 60),
    SetItem('2 mins', 120),
    SetItem('5 mins', 300),
    SetItem('10 mins', 600),
  ];

  final List<SetItem> _numberOfPlayersList = [
    SetItem('2', 1),
    SetItem('4', 2),
    SetItem('6', 3),
    SetItem('8', 4),
    SetItem('10', 5),
  ];

  final List<SetItem> _penaltyTimes = [
    SetItem('30 sec', 30),
    SetItem('60 sec', 60),
    SetItem('90 mins', 90),
  ];

  @override
  void initState() {
    super.initState();
    _selectedGameDuration = _gameDurations.firstWhere(
        (item) => item.values == widget.game.periodTime,
        orElse: () => _gameDurations[4]);
    _selectedHalftimeBreak = _halftimeBreaks.firstWhere(
        (item) => item.values == widget.game.halfTimeDuration,
        orElse: () => _halftimeBreaks[2]);
    _selectedNumberOfPlayers = _numberOfPlayersList.firstWhere(
        (item) => item.values == widget.game.numberOfPLayers,
        orElse: () => _numberOfPlayersList[1]);
    _selectedPenaltyTime = _penaltyTimes.firstWhere(
        (item) => item.values == widget.game.penaltyTime,
        orElse: () => _penaltyTimes[1]);
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvoked: (didPop) {},
      child: PopScope(
        canPop: false,
        onPopInvoked: (didPop) {
          if (didPop) {
            return;
          }
          Navigator.pop(context, widget.game);
        },
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Settings'),
            backgroundColor: AppColors.primary,
          ),
          body: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    children: [
                      ValueListenableBuilder<String>(
                          valueListenable: widget.game.matchDataService.stateNotifier,
                          builder: (context, matchStatus, child) {
                            return SettingsSection(
                              title: 'Match Data',
                              locked: false,
                              settings: [
                                SettingStatus(
                                  title: 'Status',
                                  status: matchStatus,
                                ),
                                SettingInputField(
                                  title: 'Data URL',
                                  initialValue: widget.game.matchDataService.matchesUrl,
                                  onChanged: (value) {
                                    widget.game.matchDataService.matchesUrl = value;
                                  },
                                ),
                                SettingInputField(
                                  title: 'Match ID',
                                  initialValue: widget.game.matchDataService.matchId,
                                  onChanged: (value) {
                                    widget.game.matchDataService.matchId = value;
                                  },
                                ),
                                SettingButton(
                                  title: 'Load match data',
                                  buttonText: 'Load',
                                  onPressed: () async {
                                    widget.game.loadMatchData();
                                  },
                                ),
                              ],
                            );
                          }
                      ),

                      SettingsSection(
                        title: 'Current Game',
                        locked: false,
                        settings: [
                          SettingButton(
                            title: 'Switch team order',
                            buttonText: 'Switch',
                            onPressed: () {
                              setState(() {
                                widget.game.toggleTeamOrder();
                              });
                            },
                          ),
                          SettingButton(
                            title: 'Reset current game',
                            buttonText: 'Reset',
                            onPressed: () {
                              setState(() {
                                widget.game.setTeamToDefaultOrder();
                                widget.game.gameInit();
                              });
                            },
                          ),
                          SettingButton(
                            title: 'Disconnect all robots',
                            buttonText: 'Disconnect',
                            onPressed: () {
                              widget.game.disconnectAll();
                            },
                          ),
                        ],
                      ),

                      ValueListenableBuilder<MqttConnectionStateEx>(
                          valueListenable:
                              widget.game.mqttService.connectionStateNotifier,
                          builder: (context, connectionState, child) {
                            return SettingsSection(
                              title: 'MQTT',
                              locked: false,
                              enabled: widget.game.mqttService.isEnabled,
                              onToggle: (value) {
                                setState(() {
                                  widget.game.mqttService.isEnabled = value;
                                });
                              },
                              settings: [
                                SettingStatus(
                                  title: 'MQTT status',
                                  status: connectionState == MqttConnectionStateEx.connected
                                      ? 'Connected'
                                      : connectionState == MqttConnectionStateEx.connecting
                                          ? 'Connecting'
                                          : connectionState == MqttConnectionStateEx.error
                                              ? (widget.game.mqttService.lastErrorMessage.isNotEmpty 
                                                  ? widget.game.mqttService.lastErrorMessage
                                                  : 'Connection error')
                                              : 'Disconnected',
                                ),
                                // SettingSwitch(
                                //   title: 'Auto connect',
                                //   value: widget.game.mqttService.autoConnect,
                                //   onChanged: (value) {
                                //     setState(() {
                                //       widget.game.mqttService.autoConnect = value;
                                //     });
                                //   },
                                // ),

                                SettingInputField(
                                    title: 'Server IP',
                                    initialValue:
                                        widget.game.mqttService.server ?? '',
                                    onChanged: (value) {
                                      widget.game.mqttService.server = value;
                                    }),
                                SettingInputField(
                                    title: 'Port',
                                    initialValue: widget.game.mqttService.port
                                            ?.toString() ??
                                        '',
                                    onChanged: (value) {
                                      widget.game.mqttService.port =
                                          int.tryParse(value);
                                    }),
                                SettingInputField(
                                    title: 'Username',
                                    initialValue:
                                        widget.game.mqttService.username ?? '',
                                    onChanged: (value) {
                                      widget.game.mqttService.username = value;
                                    }),
                                SettingInputField(
                                    title: 'Password',
                                    isPassword: true,
                                    initialValue:
                                        widget.game.mqttService.password ?? '',
                                    onChanged: (value) {
                                      widget.game.mqttService.password = value;
                                    }),
                                SettingSwitch(
                                  title: 'Secure Connection',
                                  value: widget.game.mqttService.secureConnection,
                                  onChanged: (value) {
                                    setState(() {
                                      widget.game.mqttService.secureConnection = value;
                                    });
                                  },
                                ),
                                SettingInputField(
                                    title: 'Field Number',
                                    initialValue: widget.game.mqttService.field_number,
                                    onChanged: (value) {
                                      widget.game.mqttService.topic_field = value;
                                    }),
                                SettingButton(
                                  title: 'Connect to MQTT',
                                  buttonText:
                                  (connectionState == MqttConnectionStateEx.connected ||
                                      connectionState == MqttConnectionStateEx.connecting)
                                          ? 'Disconnect'
                                          : 'Connect',
                                  onPressed: () async {
                                    if (connectionState == MqttConnectionStateEx.connected ||
                                        connectionState == MqttConnectionStateEx.connecting) {
                                      widget.game.mqttService.disconnect();
                                    } else {
                                      await widget.game.mqttService.connect();
                                    }
                                    setState(() {});
                                  },
                                ),
                              ],
                            );
                          }),
                      SettingsSection(
                        title: 'Game',
                        locked: widget.game.inGame,
                        settings: [
                          SettingDropdownButton(
                            title: 'Game Duration',
                            value: _selectedGameDuration,
                            options: _gameDurations,
                            onChanged: (value) {
                              setState(() {
                                _selectedGameDuration = value!;
                                widget.game.periodTime = value.values;
                              });
                            },
                          ),
                          SettingDropdownButton(
                            title: 'Halftime Break Duration',
                            value: _selectedHalftimeBreak,
                            options: _halftimeBreaks,
                            onChanged: (value) {
                              setState(() {
                                _selectedHalftimeBreak = value!;
                                widget.game.halfTimeDuration = value.values;
                              });
                            },
                          ),
                        ],
                      ),
                      SettingsSection(
                        title: 'Player',
                        locked: widget.game.inGame,
                        settings: [
                          SettingDropdownButton(
                            title: 'Number of Players',
                            value: _selectedNumberOfPlayers,
                            options: _numberOfPlayersList,
                            onChanged: (value) {
                              setState(() {
                                _selectedNumberOfPlayers = value!;
                                widget.game.numberOfPLayers = value.values;
                              });
                            },
                          ),
                          SettingDropdownButton(
                            title: 'Penalty Time',
                            value: _selectedPenaltyTime,
                            options: _penaltyTimes,
                            onChanged: (value) {
                              setState(() {
                                _selectedPenaltyTime = value!;
                                widget.game.penaltyTime = value.values;
                              });
                            },
                          ),
                        ],
                      ),
                      SettingsSection(
                        title: 'About',
                        locked: false,
                        settings: const [
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 4.0),
                            child: Text('Created for RoboFuze.com', style: TextStyle(fontSize: 14)),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 4.0),
                            child: Text('Author: Martin Faltus', style: TextStyle(fontSize: 14)),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 4.0),
                            child: Text('Version: 0.9.6', style: TextStyle(fontSize: 14)),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 4.0),
                            child: Text('Year: 2025', style: TextStyle(fontSize: 14)),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 4.0),
                            child: Text('License: Apache 2.0', style: TextStyle(fontSize: 14)),
                          ),

                        ],
                      ),
                    ],
                  ),
                ),
                // const Row(
                //   mainAxisAlignment: MainAxisAlignment.center,
                //   children: [
                //     Text(
                //         'Created for RoboFuze.com by Martin Faltus 2025 \nVersion 0.9.2',
                //         textAlign: TextAlign.center,
                //         style: TextStyle(fontSize: 12)),
                //   ],
                // ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// SettingsSection widget to group settings
class SettingsSection extends StatelessWidget {
  final String title;
  final List<Widget> settings;
  final bool locked;
  final bool? enabled;
  final ValueChanged<bool>? onToggle;

  SettingsSection(
      {required this.title, required this.settings, this.locked = false, this.enabled, this.onToggle});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: locked,
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 10),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(
                  title,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold),
                ),
                if (enabled != null && onToggle != null)
                  Switch(
                    value: enabled!,
                    onChanged: onToggle,
                    activeColor: Colors.blue,
                  ),
                if (locked) const Icon(Icons.lock, color: Colors.white),
              ]),
              if (enabled == null || enabled == true) ...settings,
            ],
          ),
        ),
      ),
    );
  }
}

// SettingDropdownButton widget for dropdown selections
class SettingDropdownButton extends StatelessWidget {
  final String title;
  final SetItem value;
  final List<SetItem> options;
  final ValueChanged<SetItem?> onChanged;

  SettingDropdownButton({
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(flex: 5, child: Text(title)),
          Expanded(
            flex: 2,
            child: DropdownButton<SetItem>(
              value: value,
              onChanged: onChanged,
              items: options.map<DropdownMenuItem<SetItem>>((SetItem item) {
                return DropdownMenuItem<SetItem>(
                  value: item,
                  child: Text(item.name),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

// SettingButton widget for action buttons
class SettingButton extends StatelessWidget {
  final String title;
  final String buttonText;
  final Function()? onPressed;

  SettingButton({
    required this.title,
    required this.buttonText,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(flex: 3, child: Text(title)),
          Expanded(
            flex: 2,
            child: ElevatedButton(
              onPressed: onPressed,
              child:
                  Text(buttonText, style: const TextStyle(color: Colors.white)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.grey[700],
              ),
            ),
          )
        ],
      ),
    );
  }
}

// // SettingInputField widget for text input fields
// class SettingInputField extends StatelessWidget {
//   final String title;
//   final String initialValue;
//   final ValueChanged<String> onChanged;
//   final bool isPassword;
//
//   SettingInputField({
//     required this.title,
//     required this.initialValue,
//     required this.onChanged,
//     this.isPassword = false,
//   });
//
//   @override
//   Widget build(BuildContext context) {
//     return Padding(
//       padding: const EdgeInsets.symmetric(vertical: 8.0),
//       child: Row(
//         mainAxisAlignment: MainAxisAlignment.spaceBetween,
//         children: [
//           Expanded(flex: 3, child: Text(title)),
//           Expanded(
//             flex: 4,
//             child: TextField(
//               controller: TextEditingController(text: initialValue),
//               onChanged: onChanged,
//               obscureText: isPassword,
//               style: const TextStyle(color: Colors.white),
//               decoration: InputDecoration(
//                 border: OutlineInputBorder(),
//                 filled: true,
//                 fillColor: Colors.grey[800],
//               ),
//             ),
//           ),
//         ],
//       ),
//     );
//   }
// }


class SettingInputField extends StatefulWidget {
  final String title;
  final String initialValue;
  final ValueChanged<String> onChanged;
  final bool isPassword;

  SettingInputField({
    required this.title,
    required this.initialValue,
    required this.onChanged,
    this.isPassword = false,
  });

  @override
  _SettingInputFieldState createState() => _SettingInputFieldState();
}

class _SettingInputFieldState extends State<SettingInputField> {
  late TextEditingController _controller;
  late FocusNode _focusNode;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _focusNode = FocusNode();
    if (!widget.isPassword) _obscure = false;
    _focusNode.addListener(() {
      if (widget.isPassword) {
        setState(() {
          _obscure = !_focusNode.hasFocus;
        });
      }
    });
  }

  @override
  void didUpdateWidget(covariant SettingInputField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialValue != oldWidget.initialValue) {
      _controller.text = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(flex: 3, child: Text(widget.title)),
          Expanded(
            flex: 4,
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              onChanged: widget.onChanged,
              obscureText: _obscure,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                border: OutlineInputBorder(),
                filled: true,
                fillColor: Colors.grey[800],
              ),
            ),
          ),
        ],
      ),
    );
  }
}






// SettingStatus widget to display the status of a setting
class SettingStatus extends StatefulWidget {
  final String title;
  final String status;

  SettingStatus({required this.title, required this.status});

  @override
  _SettingStatusState createState() => _SettingStatusState();
}

class _SettingStatusState extends State<SettingStatus> {
  late String _status;

  @override
  void initState() {
    super.initState();
    _status = widget.status;
  }

  @override
  void didUpdateWidget(covariant SettingStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) {
      setState(() {
        _status = widget.status;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(flex: 3, child: Text(widget.title)),
          Expanded(
            flex: 3,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                _status,
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.right,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// SettingSwitch widget for toggle settings
class SettingSwitch extends StatelessWidget {
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  const SettingSwitch({
    required this.title,
    required this.value,
    required this.onChanged,
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(flex: 5, child: Text(title)),
          Expanded(
            flex: 2,
            child: Switch(
              value: value,
              onChanged: onChanged,
              activeColor: Colors.blue,
            ),
          ),
        ],
      ),
    );
  }
}



// class SettingStatus extends StatelessWidget {
//   final String title;
//   final String status;
//
//   SettingStatus({required this.title, required this.status});
//
//   @override
//   Widget build(BuildContext context) {
//     return Padding(
//       padding: const EdgeInsets.symmetric(vertical: 8.0),
//       child: Row(
//         mainAxisAlignment: MainAxisAlignment.spaceBetween,
//         children: [
//           Expanded(
//             flex: 3,
//             child: Text(title)
//           ),
//           Expanded(
//             flex: 2,
//             child: Align(
//               alignment: Alignment.centerRight,
//               child: Text(
//                 status,
//                 style: const TextStyle(color: Colors.white),
//                 textAlign: TextAlign.right,
//               ),
//             ),
//           ),
//         ],
//       ),
//     );
//   }
// }

class SetItem {
  final int values;
  final String name;

  SetItem(this.name, this.values);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SetItem &&
          runtimeType == other.runtimeType &&
          values == other.values &&
          name == other.name;

  @override
  int get hashCode => values.hashCode ^ name.hashCode;
}
