import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/game.dart';
import '../services/ble_bridge_service.dart';
import '../services/mqtt.dart';
import '../services/notification_service.dart';
import '../services/preset_service.dart';
import '../services/vibration_service.dart';
import '../utils/ble_address.dart';
import '../utils/colors.dart';
import 'mac_qr_scanner.dart';

class SettingsScreen extends StatefulWidget {
  final Game game;

  const SettingsScreen({super.key, required this.game});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
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
    SetItem('90 sec', 90),
  ];

  // iOS addresses a BLE device by a CoreBluetooth UUID, not a MAC; the mask,
  // length and hint differ by platform. Shared with the per-module address field
  // via utils/ble_address.dart so both screens stay in sync.
  final _bridgeAddressMask = buildBleAddressMask();

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
        (item) => item.values == widget.game.numberOfPlayers,
        orElse: () => _numberOfPlayersList[1]);
    _selectedPenaltyTime = _penaltyTimes.firstWhere(
        (item) => item.values == widget.game.penaltyTime,
        orElse: () => _penaltyTimes[1]);
  }

  @override
  void dispose() {
    super.dispose();
  }

  // Apply a scanned bridge QR result to the bridge address. QR codes always
  // encode a MAC (mac_qr_scanner only accepts a 17-char MAC), but iOS cannot
  // connect by MAC — it needs the device's CoreBluetooth UUID, so resolve it via
  // the shared BLE scan (utils/ble_address.dart). On Android the scanned MAC is
  // the address, so it is applied directly.
  Future<void> _applyBridgeQrResult(String macResult) async {
    if (!useIosBleUuid) {
      setState(() {
        widget.game.bleBridgeService.bridgeMacAddress = macResult;
      });
      return;
    }

    final resolvedUuid = await resolveIosDeviceUuid(macResult);

    if (resolvedUuid != null) {
      if (mounted) {
        setState(() {
          widget.game.bleBridgeService.bridgeMacAddress = resolvedUuid;
        });
      }
      return;
    }

    if (mounted) {
      await showCupertinoDialog(
        context: context,
        builder: (BuildContext context) {
          return CupertinoAlertDialog(
            title: const Text('No device found'),
            content: const Text(
                'No device was found matching the MAC address you scanned'),
            actions: [
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () {
                  Navigator.of(context).pop();
                },
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
    }
  }

  Future<void> _confirmStartNoShowPenaltyGoals(int scoringTeamIndex) async {
    final scoringTeam = widget.game.teams[scoringTeamIndex];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start no-show penalty goals?'),
        content: Text(
          '${scoringTeam.name} will receive ${widget.game.noShowPenaltyGoalIntervalLabel} '
          'while the game timer runs. The current game will be reset.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Start'),
          ),
        ],
      ),
    );

    if (!mounted || confirmed != true) return;
    setState(() {
      widget.game.startNoShowPenaltyGoals(scoringTeam);
    });
  }

  Future<void> _confirmEndMatchEarly() async {
    final game = widget.game;
    // Pin the fixture the referee is confirming. A new deep link can be
    // loaded while this dialog sits open (Home's "Load match?" dialog renders
    // in the same root overlay, above us), swapping matchConfig under a stale
    // confirm — the same stale-dialog class the load/review paths guard with
    // expectedSignature. Version bumps of the same fixture change the
    // signature too; the conservative no-op just makes the referee re-tap.
    final expectedSignature =
        game.scoreboardResultService.matchConfig?.signature;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End this match now?'),
        content: Text(
          'You will be taken to the result confirmation screen. '
          'Current score: ${game.teams[0].name} ${game.teams[0].score} '
          '– ${game.teams[1].score} ${game.teams[1].name}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('End'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    // The fixture can be cleared/changed while the dialog sits open; re-check
    // the gate AND that it is still the exact fixture this dialog showed, so
    // a stale confirm can't end a different (or edited) match.
    if (!game.canEndMatchEarly) return;
    if (expectedSignature == null ||
        game.scoreboardResultService.matchConfig?.signature !=
            expectedSignature) {
      return;
    }
    // Pop Settings back to Home FIRST (returning the game so Home's
    // _navigateToSettings continuation runs gameRefresh(), not gameInit() —
    // endMatchEarly sets inGame synchronously below, before that continuation's
    // microtask runs). Home's onRequestReviewScoreboardResult callback is
    // deferred to a post-frame callback, so the review route is pushed over
    // Home, never over the disappearing Settings route.
    Navigator.of(context).pop(game);
    game.endMatchEarly();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {},
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
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
          body: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Expanded(
                    child: ListView(
                      children: [
                        ValueListenableBuilder<String>(
                            valueListenable:
                                widget.game.matchDataService.stateNotifier,
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
                                    initialValue:
                                        widget.game.matchDataService.matchesUrl,
                                    onChanged: (value) {
                                      widget.game.matchDataService.matchesUrl =
                                          value;
                                    },
                                  ),
                                  SettingInputField(
                                    title: 'Match ID',
                                    initialValue:
                                        widget.game.matchDataService.matchId,
                                    onChanged: (value) {
                                      widget.game.matchDataService.matchId =
                                          value;
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
                            }),
                        AnimatedBuilder(
                          animation: widget.game.scoreboardResultService,
                          builder: (context, child) {
                            final service = widget.game.scoreboardResultService;
                            final config = service.matchConfig;
                            return SettingsSection(
                              title: 'Scoreboard Result API',
                              locked: false,
                              settings: [
                                SettingStatus(
                                  title: 'Link status',
                                  status: service.statusMessage,
                                ),
                                SettingStatus(
                                  title: 'Match code',
                                  status: config?.matchCode.isNotEmpty == true
                                      ? config!.matchCode
                                      : 'Not loaded',
                                ),
                                SettingStatus(
                                  title: 'Venue',
                                  status:
                                      config?.venueShortName.isNotEmpty == true
                                          ? config!.venueShortName
                                          : 'Not loaded',
                                ),
                                SettingStatus(
                                  title: 'Outbox',
                                  status:
                                      'Pending ${service.pendingCount}, conflict ${service.conflictCount}, submitted ${service.submittedCount}',
                                ),
                                SettingButton(
                                  title: 'Refresh linked match',
                                  buttonText: 'Refresh',
                                  onPressed: () {
                                    service.refreshMatchConfig();
                                  },
                                ),
                                SettingButton(
                                  title: 'Retry pending result',
                                  buttonText: 'Retry',
                                  onPressed: () {
                                    service.retryPendingNow();
                                  },
                                ),
                                SettingButton(
                                  title: 'Clear linked match',
                                  buttonText: 'Clear',
                                  onPressed: () {
                                    // Clearing wipes the whole outbox. Confirm
                                    // first if any results haven't been
                                    // confirmed sent, so a stray tap can't
                                    // silently discard undelivered results
                                    // (RAVF003). Nothing undelivered → clear
                                    // straight away (no friction).
                                    final undelivered =
                                        service.undeliveredCount;
                                    if (undelivered == 0) {
                                      service.clearLinkedMatchData();
                                      return;
                                    }
                                    final plural = undelivered == 1 ? '' : 's';
                                    showDialog(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        title:
                                            const Text('Clear linked match?'),
                                        content: Text(
                                          '$undelivered result$plural '
                                          '${undelivered == 1 ? 'has' : 'have'} '
                                          'not been confirmed sent to the '
                                          'scoreboard yet. Clearing the linked '
                                          'match permanently discards '
                                          '${undelivered == 1 ? 'it' : 'them'} '
                                          '— ${undelivered == 1 ? 'it' : 'they'} '
                                          'will not be sent.',
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.of(ctx).pop(),
                                            child: const Text('Cancel'),
                                          ),
                                          TextButton(
                                            style: TextButton.styleFrom(
                                              foregroundColor: Colors.red,
                                            ),
                                            onPressed: () {
                                              Navigator.of(ctx).pop();
                                              service.clearLinkedMatchData();
                                            },
                                            child: const Text('Clear anyway'),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ],
                            );
                          },
                        ),
                        AnimatedBuilder(
                          animation: widget.game,
                          builder: (context, child) {
                            final noShowActive =
                                widget.game.noShowPenaltyGoalsActive;
                            return SettingsSection(
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
                                if (!noShowActive)
                                  SettingButton(
                                    title: 'Reset current game',
                                    buttonText: 'Reset',
                                    onPressed: () async {
                                      setState(() {
                                        widget.game.setTeamToDefaultOrder();
                                        widget.game.gameInit();
                                        widget.game.resetModuleNames();
                                      });
                                      // gameInit() deliberately does not clear
                                      // the cold-resume snapshot; an intentional
                                      // reset must, or a kill would re-offer this
                                      // match. Awaited so the clear lands before
                                      // a possible immediate kill (off the
                                      // robot-command path).
                                      await widget.game.clearMatchSnapshot();
                                    },
                                  ),
                                SettingStatus(
                                  title: 'No-show penalty goals',
                                  status: noShowActive
                                      ? '${widget.game.noShowPenaltyScoringTeamName}: ${widget.game.noShowPenaltyGoalIntervalLabel}'
                                      : 'Off',
                                ),
                                if (!noShowActive) ...[
                                  SettingButton(
                                    title:
                                        '${widget.game.teams[0].name} scores no-show goals',
                                    buttonText: 'Start',
                                    onPressed: () =>
                                        _confirmStartNoShowPenaltyGoals(0),
                                  ),
                                  SettingButton(
                                    title:
                                        '${widget.game.teams[1].name} scores no-show goals',
                                    buttonText: 'Start',
                                    onPressed: () =>
                                        _confirmStartNoShowPenaltyGoals(1),
                                  ),
                                ],
                                if (noShowActive)
                                  SettingButton(
                                    title: 'Stop no-show penalty goals',
                                    buttonText: 'Stop',
                                    onPressed: () {
                                      setState(() {
                                        widget.game.stopNoShowPenaltyGoals();
                                      });
                                    },
                                  ),
                                if (widget.game.canEndMatchEarly)
                                  SettingButton(
                                    title: 'End match now',
                                    buttonText: 'End',
                                    onPressed: _confirmEndMatchEarly,
                                  ),
                                SettingButton(
                                  title: 'Disconnect all robots',
                                  buttonText: 'Disconnect',
                                  onPressed: () {
                                    widget.game.disconnectAll();
                                  },
                                ),
                              ],
                            );
                          },
                        ),
                        ValueListenableBuilder<BridgeConnectionState>(
                            valueListenable: widget
                                .game.bleBridgeService.connectionStateNotifier,
                            builder: (context, bridgeState, child) {
                              return SettingsSection(
                                title: 'BLE Bridge',
                                locked: false,
                                enabled: widget.game.bleBridgeService.isEnabled,
                                onToggle: (value) {
                                  setState(() {
                                    widget.game.bleBridgeService.isEnabled =
                                        value;
                                  });
                                },
                                settings: [
                                  SettingStatus(
                                    title: 'Bridge status',
                                    status: bridgeState ==
                                            BridgeConnectionState.connected
                                        ? 'Connected'
                                        : bridgeState ==
                                                BridgeConnectionState.connecting
                                            ? 'Connecting...'
                                            : bridgeState ==
                                                    BridgeConnectionState.error
                                                ? (widget.game.bleBridgeService
                                                        .lastErrorMessage ??
                                                    'Error')
                                                : 'Disconnected',
                                  ),
                                  SettingInputField(
                                    title: useIosBleUuid
                                        ? 'Bridge UUID'
                                        : 'Bridge MAC',
                                    initialValue: widget
                                        .game.bleBridgeService.bridgeMacAddress,
                                    inputFormatters: [_bridgeAddressMask],
                                    maxLength: bleAddressMaxLength,
                                    hintText: bleAddressHint,
                                    onChanged: (value) {
                                      widget.game.bleBridgeService
                                          .bridgeMacAddress = value;
                                    },
                                  ),
                                  SettingButton(
                                    title: 'Scan QR code',
                                    buttonText: 'Scan QR',
                                    onPressed: () async {
                                      final result = await Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) =>
                                              const BarcodeScannerSimple(),
                                        ),
                                      );
                                      if (!context.mounted) return;
                                      if (result is String) {
                                        await _applyBridgeQrResult(result);
                                      }
                                    },
                                  ),
                                  SettingButton(
                                    title: 'Bridge connection',
                                    buttonText: bridgeState ==
                                            BridgeConnectionState.connected
                                        ? 'Disconnect'
                                        : 'Connect',
                                    onPressed: () async {
                                      if (bridgeState ==
                                          BridgeConnectionState.connected) {
                                        await widget.game.bleBridgeService
                                            .disconnect();
                                      } else {
                                        await widget.game.bleBridgeService
                                            .connect();
                                      }
                                      setState(() {});
                                    },
                                  ),
                                ],
                              );
                            }),
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
                                    status: connectionState ==
                                            MqttConnectionStateEx.connected
                                        ? 'Connected'
                                        : connectionState ==
                                                MqttConnectionStateEx.connecting
                                            ? 'Connecting...'
                                            : connectionState ==
                                                    MqttConnectionStateEx.error
                                                ? (widget
                                                        .game
                                                        .mqttService
                                                        .lastErrorMessage
                                                        .isNotEmpty
                                                    ? widget.game.mqttService
                                                        .lastErrorMessage
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
                                          widget.game.mqttService.username ??
                                              '',
                                      onChanged: (value) {
                                        widget.game.mqttService.username =
                                            value;
                                      }),
                                  SettingInputField(
                                      title: 'Password',
                                      isPassword: true,
                                      initialValue:
                                          widget.game.mqttService.password ??
                                              '',
                                      onChanged: (value) {
                                        widget.game.mqttService.password =
                                            value;
                                      }),
                                  SettingSwitch(
                                    title: 'Secure Connection',
                                    value: widget
                                        .game.mqttService.secureConnection,
                                    onChanged: (value) {
                                      setState(() {
                                        widget.game.mqttService
                                            .secureConnection = value;
                                      });
                                    },
                                  ),
                                  SettingInputField(
                                      title: 'Field Number',
                                      initialValue:
                                          widget.game.mqttService.fieldNumber,
                                      onChanged: (value) {
                                        widget.game.mqttService.topicField =
                                            value;
                                      }),
                                  SettingButton(
                                    title: 'Connect to MQTT',
                                    buttonText: (connectionState ==
                                                MqttConnectionStateEx
                                                    .connected ||
                                            connectionState ==
                                                MqttConnectionStateEx
                                                    .connecting)
                                        ? 'Disconnect'
                                        : 'Connect',
                                    onPressed: () async {
                                      if (connectionState ==
                                              MqttConnectionStateEx.connected ||
                                          connectionState ==
                                              MqttConnectionStateEx
                                                  .connecting) {
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
                                  widget.game.numberOfPlayers = value.values;
                                });
                                if (value!.values >= 4) {
                                  showDialog(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text('Bluetooth Warning'),
                                      content: Text(
                                        'You selected ${value.values * 2} players. '
                                        'This requires ${value.values * 2} simultaneous Bluetooth connections. '
                                        'Some phones cannot support this many connections at once — '
                                        'on those devices, some robots may fail to connect.',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.of(ctx).pop(),
                                          child: const Text('OK'),
                                        ),
                                      ],
                                    ),
                                  );
                                }
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
                        ModulePresetsSection(game: widget.game),
                        AnimatedBuilder(
                          animation: widget.game.vibrationService,
                          builder: (context, child) {
                            final vs = widget.game.vibrationService;
                            return SettingsSection(
                              title: 'Vibration & Notifications',
                              locked: false,
                              settings: [
                                SettingSwitch(
                                  title: 'Game Timer Vibration',
                                  value: vs.gameTimerEnabled,
                                  onChanged: (value) {
                                    vs.gameTimerEnabled = value;
                                    // Ask for notification permission only now,
                                    // when the user opts into timer alerts.
                                    if (value) {
                                      NotificationService.requestPermission();
                                    }
                                  },
                                ),
                                if (vs.gameTimerEnabled)
                                  SettingAlertChips(
                                    label: 'Alert at (sec remaining)',
                                    options: kVibrationAlertOptions,
                                    selected: vs.gameTimerAlerts,
                                    onToggle: (sec) {
                                      vs.toggleGameTimerAlert(sec);
                                    },
                                  ),
                                SettingSwitch(
                                  title: 'Damage Timer Vibration',
                                  value: vs.damageTimerEnabled,
                                  onChanged: (value) {
                                    vs.damageTimerEnabled = value;
                                    if (value) {
                                      NotificationService.requestPermission();
                                    }
                                  },
                                ),
                                if (vs.damageTimerEnabled)
                                  SettingAlertChips(
                                    label: 'Alert at (sec remaining)',
                                    options: kVibrationAlertOptions,
                                    selected: vs.damageTimerAlerts,
                                    onToggle: (sec) {
                                      vs.toggleDamageTimerAlert(sec);
                                    },
                                  ),
                              ],
                            );
                          },
                        ),
                        AnimatedBuilder(
                          animation: widget.game.wakelockService,
                          builder: (context, child) {
                            final ws = widget.game.wakelockService;
                            return SettingsSection(
                              title: 'Display',
                              locked: false,
                              settings: [
                                SettingSwitch(
                                  title: 'Keep Screen Awake',
                                  value: ws.enabled,
                                  onChanged: (value) {
                                    ws.enabled = value;
                                  },
                                ),
                              ],
                            );
                          },
                        ),
                        AnimatedBuilder(
                          animation: widget.game,
                          builder: (context, child) {
                            return SettingsSection(
                              title: 'Controls',
                              locked: false,
                              settings: [
                                SettingSwitch(
                                  title: 'Single-tap actions',
                                  subtitle:
                                      'Off by default. When on, start/stop, '
                                      'scoring and robot controls fire on a '
                                      'single tap — removes the accidental-touch '
                                      'protection.',
                                  value: widget.game.singleTapEnabled,
                                  onChanged: (value) {
                                    widget.game.singleTapEnabled = value;
                                  },
                                ),
                              ],
                            );
                          },
                        ),
                        const SettingsSection(
                          title: 'About',
                          locked: false,
                          settings: [
                            Padding(
                              padding: EdgeInsets.symmetric(vertical: 4.0),
                              child: Text('Created for RoboFuze.com',
                                  style: TextStyle(fontSize: 14)),
                            ),
                            Padding(
                              padding: EdgeInsets.symmetric(vertical: 4.0),
                              child: Text(
                                  'Author: Martin Faltus, Fabian Weller, Marek Šuppa',
                                  style: TextStyle(fontSize: 14)),
                            ),
                            Padding(
                              padding: EdgeInsets.symmetric(vertical: 4.0),
                              child: Text('Version: 0.10.4',
                                  style: TextStyle(fontSize: 14)),
                            ),
                            Padding(
                              padding: EdgeInsets.symmetric(vertical: 4.0),
                              child: Text('Year: 2026',
                                  style: TextStyle(fontSize: 14)),
                            ),
                            Padding(
                              padding: EdgeInsets.symmetric(vertical: 4.0),
                              child: Text('License: Apache 2.0',
                                  style: TextStyle(fontSize: 14)),
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

  const SettingsSection(
      {super.key,
      required this.title,
      required this.settings,
      this.locked = false,
      this.enabled,
      this.onToggle});

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
                    activeThumbColor: Colors.blue,
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

  const SettingDropdownButton({
    super.key,
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

  const SettingButton({
    super.key,
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
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.grey[700],
              ),
              child:
                  Text(buttonText, style: const TextStyle(color: Colors.white)),
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
  final List<TextInputFormatter>? inputFormatters;
  final int? maxLength;
  final String? hintText;

  const SettingInputField({
    super.key,
    required this.title,
    required this.initialValue,
    required this.onChanged,
    this.isPassword = false,
    this.inputFormatters,
    this.maxLength,
    this.hintText,
  });

  @override
  State<SettingInputField> createState() => _SettingInputFieldState();
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
              inputFormatters: widget.inputFormatters,
              maxLength: widget.maxLength,
              // Suppress the character counter so the longer UUID limit doesn't
              // grow the compact settings row.
              buildCounter: (context,
                      {required currentLength,
                      required isFocused,
                      maxLength}) =>
                  null,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                filled: true,
                fillColor: Colors.grey[800],
                hintText: widget.hintText,
                hintStyle: const TextStyle(color: Colors.grey),
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

  const SettingStatus({super.key, required this.title, required this.status});

  @override
  State<SettingStatus> createState() => _SettingStatusState();
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
  final String? subtitle;

  const SettingSwitch({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 5,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4.0),
                    child: Text(
                      subtitle!,
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: Colors.blue,
            ),
          ),
        ],
      ),
    );
  }
}

// SettingAlertChips widget for multi-select vibration alert thresholds
class SettingAlertChips extends StatelessWidget {
  final String label;
  final List<int> options;
  final Set<int> selected;
  final void Function(int) onToggle;

  const SettingAlertChips({
    required this.label,
    required this.options,
    required this.selected,
    required this.onToggle,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: options.map((sec) {
              final isSelected = selected.contains(sec);
              return FilterChip(
                label: Text(sec == 0 ? '0 (end)' : '${sec}s'),
                selected: isSelected,
                onSelected: (_) => onToggle(sec),
                selectedColor: Colors.blue,
                checkmarkColor: Colors.white,
                labelStyle: TextStyle(
                  color: isSelected ? Colors.white : null,
                ),
              );
            }).toList(),
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

class ModulePresetsSection extends StatefulWidget {
  final Game game;

  const ModulePresetsSection({super.key, required this.game});

  @override
  State<ModulePresetsSection> createState() => _ModulePresetsSectionState();
}

class _ModulePresetsSectionState extends State<ModulePresetsSection> {
  final PresetService _presetService = PresetService();
  List<GamePreset>? _presets;

  @override
  void initState() {
    super.initState();
    _loadPresets();
  }

  Future<void> _loadPresets() async {
    final presets = await _presetService.loadAll();
    if (mounted) {
      setState(() {
        _presets = presets;
      });
    }
  }

  Future<void> _saveCurrentPreset() async {
    final name = await _showNameDialog();
    if (name == null || name.trim().isEmpty) return;

    final preset = widget.game.createPreset(name.trim());
    await _presetService.save(preset);
    await _loadPresets();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Preset "${preset.name}" saved')),
      );
    }
  }

  Future<String?> _showNameDialog() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save Preset'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Preset name',
            hintText: 'e.g. My team robots',
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadPreset(GamePreset preset) async {
    widget.game.applyPreset(preset);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Loaded "${preset.name}" – connecting robots...')),
      );
    }
  }

  Future<void> _deletePreset(GamePreset preset) async {
    await _presetService.delete(preset.id);
    await _loadPresets();
  }

  @override
  Widget build(BuildContext context) {
    final presets = _presets;

    final settingItems = <Widget>[
      SettingButton(
        title: 'Save current robot configuration',
        buttonText: 'Save',
        onPressed: _saveCurrentPreset,
      ),
      if (presets == null)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8.0),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (presets.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 4.0),
          child: Text(
            'No presets saved yet.',
            style: TextStyle(color: Colors.grey, fontSize: 14),
          ),
        )
      else
        ...presets.map((preset) => _PresetTile(
              preset: preset,
              onLoad: () => _loadPreset(preset),
              onDelete: () => _deletePreset(preset),
            )),
    ];

    return SettingsSection(
      title: 'Module Presets',
      locked: false,
      settings: settingItems,
    );
  }
}

class _PresetTile extends StatelessWidget {
  final GamePreset preset;
  final VoidCallback onLoad;
  final VoidCallback onDelete;

  const _PresetTile({
    required this.preset,
    required this.onLoad,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              preset.name,
              style: const TextStyle(fontSize: 14),
            ),
          ),
          TextButton(
            onPressed: onLoad,
            child: const Text('Load'),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            onPressed: onDelete,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}
