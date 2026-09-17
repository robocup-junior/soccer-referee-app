import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// Background timer alerts for a referee who leaves the app. Notification ids
/// are `base + threshold`: game 10000, break 30000, damage 20000 + module*100,
/// so co-scheduled alert sets never overwrite each other.
class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static Future<void>? _initFuture;

  static const _gameChannel = AndroidNotificationDetails(
    'game_timer_alerts',
    'Game Timer Alerts',
    importance: Importance.max,
    priority: Priority.high,
    playSound: false,
  );
  static const _damageChannel = AndroidNotificationDetails(
    'damage_timer_alerts',
    'Damage Timer Alerts',
    importance: Importance.max,
    priority: Priority.high,
    playSound: false,
  );
  static const _iosDetails = DarwinNotificationDetails(presentSound: true);

  /// Idempotent init (call from main). Does not request permission, so the
  /// first frame is never blocked on an OS dialog.
  static Future<void> initialize() =>
      _initFuture ??= _guard('initialize', () async {
        tz_data.initializeTimeZones();
        await _plugin.initialize(const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ));
      });

  static Future<void> requestPermission() =>
      _guard('requestPermission', () async {
        await initialize();
        await _plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
        await _plugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: false, sound: true);
      });

  static Future<void> cancelAll() => _guard('cancelAll', _plugin.cancelAll);

  /// Game-clock alerts; at 0 s the text reads match-over in the final period.
  static Future<void> scheduleGameAlerts(
          int remainingSeconds, Set<int> thresholds,
          {bool isFinalPeriod = false}) =>
      _scheduleAll(
        base: 10000,
        title: 'Game Timer',
        remaining: remainingSeconds,
        thresholds: thresholds,
        channel: _gameChannel,
        atZero: isFinalPeriod
            ? 'Full time — match over'
            : 'Time is up! Open the app to start the next timer',
      );

  static Future<void> scheduleBreakAlerts(
          int remainingSeconds, Set<int> thresholds) =>
      _scheduleAll(
        base: 30000,
        title: 'Break Timer',
        remaining: remainingSeconds,
        thresholds: thresholds,
        channel: _gameChannel,
        atZero: 'Time is up! Open the app to start the second half timer',
      );

  static Future<void> scheduleDamageAlerts(int moduleId, String moduleName,
          int penaltySeconds, Set<int> thresholds) =>
      _scheduleAll(
        base: 20000 + moduleId * 100,
        title: 'Damage Timer – $moduleName',
        remaining: penaltySeconds,
        thresholds: thresholds,
        channel: _damageChannel,
        atZero: 'Penalty time is up!',
      );

  static Future<void> _scheduleAll({
    required int base,
    required String title,
    required int remaining,
    required Set<int> thresholds,
    required AndroidNotificationDetails channel,
    required String atZero,
  }) async {
    if (kIsWeb) return;
    final now = tz.TZDateTime.now(tz.local);
    for (final threshold in thresholds) {
      final delay = remaining - threshold;
      if (delay <= 0) continue;
      await _guard(
          'schedule',
          () => _plugin.zonedSchedule(
                base + threshold,
                title,
                threshold == 0 ? atZero : '$threshold seconds remaining',
                now.add(Duration(seconds: delay)),
                NotificationDetails(android: channel, iOS: _iosDetails),
                androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
              ));
    }
  }

  static Future<void> _guard(String what, Future<void> Function() body) async {
    if (kIsWeb) return;
    try {
      await body();
    } catch (e) {
      debugPrint('NotificationService: $what failed: $e');
    }
  }
}
