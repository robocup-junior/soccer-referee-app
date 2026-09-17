import 'package:flutter/material.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/screens/mac_qr_scanner.dart';
import 'package:rcj_scoreboard/services/ble_bridge_service.dart';
import 'package:rcj_scoreboard/services/mqtt.dart';
import 'package:rcj_scoreboard/services/notification_service.dart';
import 'package:rcj_scoreboard/services/vibration_service.dart';
import 'package:rcj_scoreboard/utils/ble_address.dart';
import 'package:rcj_scoreboard/utils/colors.dart';
import 'package:rcj_scoreboard/widgets/app_dialogs.dart';
import 'package:rcj_scoreboard/widgets/module_presets_section.dart';
import 'package:rcj_scoreboard/widgets/settings_widgets.dart';

const _gameDurations = [
  SetItem('2 mins', 60),
  SetItem('4 mins', 120),
  SetItem('8 mins', 240),
  SetItem('10 mins', 300),
  SetItem('20 mins', 600),
];
const _halftimeBreaks = [
  SetItem('1 min', 60),
  SetItem('2 mins', 120),
  SetItem('5 mins', 300),
  SetItem('10 mins', 600),
];
const _playerCounts = [
  SetItem('2', 1),
  SetItem('4', 2),
  SetItem('6', 3),
  SetItem('8', 4),
  SetItem('10', 5),
];
const _penaltyTimes = [
  SetItem('30 sec', 30),
  SetItem('60 sec', 60),
  SetItem('90 sec', 90)
];

SetItem _itemFor(List<SetItem> options, int value, int fallbackIndex) => options
    .firstWhere((o) => o.values == value, orElse: () => options[fallbackIndex]);

String bridgeConnectionButtonLabel(BridgeConnectionState state) =>
    switch (state) {
      BridgeConnectionState.connected => 'Disconnect',
      BridgeConnectionState.connecting => 'Cancel',
      _ => 'Connect',
    };

/// All operator settings. The whole list rebuilds on any change of the game or
/// the services it shows, which is cheap and keeps every row in sync.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.game});
  final Game game;

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) Navigator.pop(context, game);
        },
        child: Scaffold(
          appBar: AppBar(
              title: const Text('Settings'),
              backgroundColor: AppColors.primary),
          body: SafeArea(
            top: false,
            child: ListenableBuilder(
              listenable: Listenable.merge([
                game,
                game.vibrationService,
                game.wakelockService,
                game.matchDataService.stateNotifier,
                game.bleBridgeService.connectionStateNotifier,
                game.mqttService.connectionStateNotifier,
              ]),
              builder: (context, _) => ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _matchDataSection(),
                  _scoreboardSection(context),
                  _currentGameSection(context),
                  _bridgeSection(context),
                  _mqttSection(),
                  SettingsSection(
                    title: 'Game',
                    locked: game.inGame,
                    settings: [
                      SettingDropdownButton(
                        title: 'Game Duration',
                        value: _itemFor(_gameDurations, game.periodTime, 4),
                        options: _gameDurations,
                        onChanged: (v) => game.periodTime = v!.values,
                      ),
                      SettingDropdownButton(
                        title: 'Halftime Break Duration',
                        value:
                            _itemFor(_halftimeBreaks, game.halfTimeDuration, 2),
                        options: _halftimeBreaks,
                        onChanged: (v) => game.halfTimeDuration = v!.values,
                      ),
                    ],
                  ),
                  SettingsSection(
                    title: 'Player',
                    locked: game.inGame,
                    settings: [
                      SettingDropdownButton(
                        title: 'Number of Players',
                        value: _itemFor(_playerCounts, game.numberOfPlayers, 1),
                        options: _playerCounts,
                        onChanged: (v) => _setPlayers(context, v!.values),
                      ),
                      SettingDropdownButton(
                        title: 'Penalty Time',
                        value: _itemFor(_penaltyTimes, game.penaltyTime, 1),
                        options: _penaltyTimes,
                        onChanged: (v) => game.penaltyTime = v!.values,
                      ),
                    ],
                  ),
                  ModulePresetsSection(game: game),
                  _alertsSection(),
                  SettingsSection(title: 'Display', settings: [
                    SettingSwitch(
                      title: 'Keep Screen Awake',
                      value: game.wakelockService.enabled,
                      onChanged: (v) => game.wakelockService.enabled = v,
                    ),
                  ]),
                  SettingsSection(title: 'Controls', settings: [
                    SettingSwitch(
                      title: 'Single-tap actions',
                      subtitle:
                          'Off by default. When on, start/stop, scoring and robot '
                          'controls fire on a single tap — removes the accidental-touch '
                          'protection.',
                      value: game.singleTapEnabled,
                      onChanged: (v) => game.singleTapEnabled = v,
                    ),
                  ]),
                  const SettingsSection(title: 'About', settings: [
                    _AboutLine('Created for RoboFuze.com'),
                    _AboutLine(
                        'Author: Martin Faltus, Fabian Weller, Marek Šuppa'),
                    _AboutLine('Version: 0.10.6'),
                    _AboutLine('Year: 2026'),
                    _AboutLine('License: Apache 2.0'),
                  ]),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _matchDataSection() {
    final data = game.matchDataService;
    return SettingsSection(title: 'Match Data', settings: [
      SettingStatus(title: 'Status', status: data.stateNotifier.value),
      SettingInputField(
          title: 'Data URL',
          initialValue: data.matchesUrl,
          onChanged: (v) => data.matchesUrl = v),
      SettingInputField(
          title: 'Match ID',
          initialValue: data.matchId,
          onChanged: (v) => data.matchId = v),
      SettingButton(
          title: 'Load match data',
          buttonText: 'Load',
          onPressed: game.loadMatchData),
    ]);
  }

  Widget _scoreboardSection(BuildContext context) {
    final service = game.scoreboardResultService;
    final config = service.matchConfig;
    String orNotLoaded(String? s) =>
        (s?.isNotEmpty ?? false) ? s! : 'Not loaded';
    return SettingsSection(title: 'Scoreboard Result API', settings: [
      SettingStatus(title: 'Link status', status: service.statusMessage),
      SettingStatus(
          title: 'Match code', status: orNotLoaded(config?.matchCode)),
      SettingStatus(
          title: 'Venue', status: orNotLoaded(config?.venueShortName)),
      SettingStatus(
          title: 'Outbox',
          status:
              'Pending ${service.pendingCount}, conflict ${service.conflictCount}, '
              'submitted ${service.submittedCount}'),
      if (game.canEndMatchEarly)
        SettingButton(
            title: 'End match now',
            buttonText: 'End',
            onPressed: () => _confirmEndMatchEarly(context)),
      SettingButton(
          title: 'Refresh linked match',
          buttonText: 'Refresh',
          onPressed: service.refreshMatchConfig),
      SettingButton(
          title: 'Retry pending result',
          buttonText: 'Retry',
          onPressed: service.retryPendingNow),
      SettingButton(
          title: 'Clear linked match',
          buttonText: 'Clear',
          onPressed: () => _clearLinkedMatch(context)),
    ]);
  }

  /// Clearing wipes the outbox; confirm when results are still undelivered.
  Future<void> _clearLinkedMatch(BuildContext context) async {
    final service = game.scoreboardResultService;
    final n = service.undeliveredCount;
    if (n == 0) {
      service.clearLinkedMatchData();
      return;
    }
    final (results, have, them) =
        n == 1 ? ('result', 'has', 'it') : ('results', 'have', 'they');
    final confirmed = await showChoiceDialog(
      context,
      title: 'Clear linked match?',
      body:
          '$n $results $have not been confirmed sent to the scoreboard yet. Clearing the '
          'linked match permanently discards $them — $them will not be sent.',
      confirmText: 'Clear anyway',
      confirmColor: Colors.red[600],
      dismissible: true,
    );
    if (confirmed == true) service.clearLinkedMatchData();
  }

  /// "End match now" (#84). The dialog pins the fixture AND the match state it
  /// displayed; a Load or a stage/score change while it sits open makes the
  /// confirm a no-op so a stale confirm can't end the wrong match.
  Future<void> _confirmEndMatchEarly(BuildContext context) async {
    (String?, MatchStage, bool, int, int) pin() => (
          game.scoreboardResultService.matchConfig?.signature,
          game.currentStage,
          game.inGame,
          game.teams[0].score,
          game.teams[1].score,
        );
    final expected = pin();
    final confirmed = await showChoiceDialog(
      context,
      title: 'End this match now?',
      body:
          'You will be taken to the result confirmation screen. Current score: '
          '${game.teams[0].name} ${game.teams[0].score} – ${game.teams[1].score} ${game.teams[1].name}.',
      confirmText: 'End',
      dismissible: true,
    );
    if (confirmed != true || !context.mounted) return;
    if (!game.canEndMatchEarly || expected.$1 == null || pin() != expected) {
      return;
    }
    // Pop to Home first: the review route is pushed over Home after the frame.
    Navigator.of(context).pop(game);
    game.endMatchEarly();
  }

  Widget _currentGameSection(BuildContext context) {
    final noShow = game.noShowPenaltyGoalsActive;
    return SettingsSection(title: 'Current Game', settings: [
      SettingButton(
          title: 'Switch team order',
          buttonText: 'Switch',
          onPressed: game.toggleTeamOrder),
      if (!noShow)
        SettingButton(
          title: 'Reset current game',
          buttonText: 'Reset',
          onPressed: () async {
            game.setTeamToDefaultOrder();
            game.gameInit();
            game.resetModuleNames();
            // gameInit keeps the resume snapshot; an intentional reset must not.
            await game.persistence.clearAndWait();
          },
        ),
      SettingStatus(
        title: 'No-show penalty goals',
        status: noShow
            ? '${game.noShowPenaltyScoringTeamName}: ${game.noShowPenaltyGoalIntervalLabel}'
            : 'Off',
      ),
      if (!noShow)
        for (final team in game.teams)
          SettingButton(
            title: '${team.name} scores no-show goals',
            buttonText: 'Start',
            onPressed: () async {
              final ok = await showChoiceDialog(
                context,
                title: 'Start no-show penalty goals?',
                body:
                    '${team.name} will receive ${game.noShowPenaltyGoalIntervalLabel} while '
                    'the game timer runs. The current game will be reset.',
                confirmText: 'Start',
                dismissible: true,
              );
              if (ok == true) game.startNoShowPenaltyGoals(team);
            },
          )
      else
        SettingButton(
            title: 'Stop no-show penalty goals',
            buttonText: 'Stop',
            onPressed: game.stopNoShowPenaltyGoals),
      SettingButton(
          title: 'Disconnect all robots',
          buttonText: 'Disconnect',
          onPressed: game.disconnectAll),
    ]);
  }

  Widget _bridgeSection(BuildContext context) {
    final bridge = game.bleBridgeService;
    final state = bridge.connectionStateNotifier.value;
    final busy = state == BridgeConnectionState.connected ||
        state == BridgeConnectionState.connecting;
    return SettingsSection(
      title: 'BLE Bridge',
      enabled: bridge.isEnabled,
      onToggle: (v) => bridge.isEnabled = v,
      settings: [
        SettingStatus(
          title: 'Bridge status',
          status: switch (state) {
            BridgeConnectionState.connected => 'Connected',
            BridgeConnectionState.connecting => 'Connecting...',
            BridgeConnectionState.error => bridge.lastErrorMessage ?? 'Error',
            _ => 'Disconnected',
          },
        ),
        SettingInputField(
          title: useIosBleUuid ? 'Bridge UUID' : 'Bridge MAC',
          initialValue: bridge.bridgeMacAddress,
          inputFormatters: [buildBleAddressMask()],
          maxLength: bleAddressMaxLength,
          hintText: bleAddressHint,
          onChanged: (v) => bridge.bridgeMacAddress = v,
        ),
        SettingButton(
          title: 'Scan QR code',
          buttonText: 'Scan QR',
          onPressed: () async {
            final mac = await scanMacQr(context);
            if (mac == null || !context.mounted) return;
            final address = await resolveScannedAddress(context, mac);
            if (address != null) bridge.bridgeMacAddress = address;
          },
        ),
        SettingButton(
          title: 'Bridge connection',
          buttonText: bridgeConnectionButtonLabel(state),
          onPressed: busy ? bridge.disconnect : bridge.connect,
        ),
      ],
    );
  }

  Widget _mqttSection() {
    final mqtt = game.mqttService;
    final state = mqtt.connectionStateNotifier.value;
    final busy = state == MqttConnectionStateEx.connected ||
        state == MqttConnectionStateEx.connecting;
    return SettingsSection(
      title: 'MQTT',
      enabled: mqtt.isEnabled,
      onToggle: (v) => mqtt.isEnabled = v,
      settings: [
        SettingStatus(
          title: 'MQTT status',
          status: switch (state) {
            MqttConnectionStateEx.connected => 'Connected',
            MqttConnectionStateEx.connecting => 'Connecting...',
            MqttConnectionStateEx.error => mqtt.lastErrorMessage.isNotEmpty
                ? mqtt.lastErrorMessage
                : 'Connection error',
            MqttConnectionStateEx.disconnected => 'Disconnected',
          },
        ),
        SettingInputField(
            title: 'Server IP',
            initialValue: mqtt.server,
            onChanged: (v) => mqtt.server = v),
        SettingInputField(
            title: 'Port',
            initialValue: '${mqtt.port}',
            onChanged: (v) => mqtt.port = int.tryParse(v)),
        SettingInputField(
            title: 'Username',
            initialValue: mqtt.username,
            onChanged: (v) => mqtt.username = v),
        SettingInputField(
            title: 'Password',
            isPassword: true,
            initialValue: mqtt.password,
            onChanged: (v) => mqtt.password = v),
        SettingSwitch(
            title: 'Secure Connection',
            value: mqtt.secureConnection,
            onChanged: (v) => mqtt.secureConnection = v),
        SettingInputField(
            title: 'Field Number',
            initialValue: mqtt.fieldNumber,
            onChanged: (v) => mqtt.topicField = v),
        SettingButton(
          title: 'Connect to MQTT',
          buttonText: busy ? 'Disconnect' : 'Connect',
          onPressed: busy ? mqtt.disconnect : mqtt.connect,
        ),
      ],
    );
  }

  Widget _alertsSection() {
    final vs = game.vibrationService;
    Widget chips(Set<int> selected, void Function(int) onToggle) =>
        SettingAlertChips(
            label: 'Alert at (sec remaining)',
            options: kVibrationAlertOptions,
            selected: selected,
            onToggle: onToggle);
    // Permission is requested lazily, when the user turns an alert on.
    void requestIfOn(bool on) {
      if (on) NotificationService.requestPermission();
    }

    return SettingsSection(title: 'Vibration & Notifications', settings: [
      SettingSwitch(
        title: 'Game Timer Vibration',
        value: vs.gameTimerEnabled,
        onChanged: (v) {
          vs.gameTimerEnabled = v;
          requestIfOn(v);
        },
      ),
      if (vs.gameTimerEnabled)
        chips(vs.gameTimerAlerts, vs.toggleGameTimerAlert),
      SettingSwitch(
        title: 'Damage Timer Vibration',
        value: vs.damageTimerEnabled,
        onChanged: (v) {
          vs.damageTimerEnabled = v;
          requestIfOn(v);
        },
      ),
      if (vs.damageTimerEnabled)
        chips(vs.damageTimerAlerts, vs.toggleDamageTimerAlert),
    ]);
  }

  Future<void> _setPlayers(BuildContext context, int perTeam) async {
    game.numberOfPlayers = perTeam;
    if (perTeam >= 4) {
      await showInfoDialog(
        context,
        title: 'Bluetooth Warning',
        body:
            'You selected ${perTeam * 2} players. This requires ${perTeam * 2} simultaneous '
            'Bluetooth connections. Some phones cannot support this many connections at once — '
            'on those devices, some robots may fail to connect.',
      );
    }
  }
}

class _AboutLine extends StatelessWidget {
  const _AboutLine(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(text, style: const TextStyle(fontSize: 14)),
      );
}
