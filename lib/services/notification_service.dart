import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// Notification IDs:
///   Game timer:    10000 + threshold value
///   Damage timer:  20000 + (moduleId * 100) + threshold value
/// (threshold values from kVibrationAlertOptions are small integers, e.g. 0,3,5,10)

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();

  static const _androidGameChannel = AndroidNotificationDetails(
    'game_timer_alerts',
    'Game Timer Alerts',
    importance: Importance.max,
    priority: Priority.high,
    playSound: false,
  );

  static const _androidDamageChannel = AndroidNotificationDetails(
    'damage_timer_alerts',
    'Damage Timer Alerts',
    importance: Importance.max,
    priority: Priority.high,
    playSound: false,
  );

  static const _iosDetails = DarwinNotificationDetails(presentSound: true);

  /// One-time initialisation – call from main(). Does NOT request permission:
  /// init must not block the first frame on an OS dialog, and we don't want to
  /// prompt before the user has enabled a timer alert. Permission is requested
  /// lazily via [requestPermission].
  static Future<void> initialize() async {
    if (kIsWeb) return;
    try {
      tz_data.initializeTimeZones();
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const ios = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      await _plugin.initialize(
        const InitializationSettings(android: android, iOS: ios),
      );
    } catch (e) {
      debugPrint('NotificationService: initialize() failed: $e');
    }
  }

  /// Request notification permission. Call the moment the user enables a timer
  /// alert, so the OS prompt has context instead of firing on first launch.
  static Future<void> requestPermission() async {
    if (kIsWeb) return;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: false, sound: true);
    } catch (e) {
      debugPrint('NotificationService: requestPermission() failed: $e');
    }
  }

  /// Schedule a notification for each [threshold] still in the future.
  ///
  /// [remainingSeconds] is how many seconds are left on the game timer right now.
  static Future<void> scheduleGameAlerts(
      int remainingSeconds, Set<int> thresholds) async {
    if (kIsWeb) return;
    final now = tz.TZDateTime.now(tz.local);
    for (final threshold in thresholds) {
      final delay = remainingSeconds - threshold;
      if (delay <= 0) continue;
      try {
        await _plugin.zonedSchedule(
          10000 + threshold,
          'Game Timer',
          threshold == 0 ? 'Time is up! Open the app to start the next timer' : '$threshold seconds remaining',
          now.add(Duration(seconds: delay)),
          const NotificationDetails(
            android: _androidGameChannel,
            iOS: _iosDetails,
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      } catch (e) {
        debugPrint('NotificationService: scheduleGameAlerts failed: $e');
      }
    }
  }

  /// Schedule a notification for each [threshold] still in the future.
  ///
  /// [remainingSeconds] is how many seconds are left on the game timer right now.
  static Future<void> scheduleBreakAlerts(
      int remainingSeconds, Set<int> thresholds) async {
    if (kIsWeb) return;
    final now = tz.TZDateTime.now(tz.local);
    for (final threshold in thresholds) {
      final delay = remainingSeconds - threshold;
      if (delay <= 0) continue;
      try {
        await _plugin.zonedSchedule(
          10000 + threshold,
          'Break Timer',
          threshold == 0 ? 'Time is up! Open the app to start the second half timer' : '$threshold seconds remaining',
          now.add(Duration(seconds: delay)),
          const NotificationDetails(
            android: _androidGameChannel,
            iOS: _iosDetails,
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      } catch (e) {
        debugPrint('NotificationService: scheduleBreakAlerts failed: $e');
      }
    }
  }

  /// Schedule a notification for each [threshold] still in the future for a
  /// specific damage timer identified by [moduleId] and [moduleName].
  ///
  /// [penaltySeconds] is how many seconds remain on this module's damage timer.
  static Future<void> scheduleDamageAlerts(
      int moduleId, String moduleName, int penaltySeconds,
      Set<int> thresholds) async {
    if (kIsWeb) return;
    final now = tz.TZDateTime.now(tz.local);
    final base = 20000 + moduleId * 100;
    for (final threshold in thresholds) {
      final delay = penaltySeconds - threshold;
      if (delay <= 0) continue;
      try {
        await _plugin.zonedSchedule(
          base + threshold,
          'Damage Timer – $moduleName',
          threshold == 0
              ? 'Penalty time is up!'
              : '$threshold seconds remaining',
          now.add(Duration(seconds: delay)),
          const NotificationDetails(
            android: _androidDamageChannel,
            iOS: _iosDetails,
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      } catch (e) {
        debugPrint('NotificationService: scheduleDamageAlerts failed: $e');
      }
    }
  }

  /// Cancel all pending notifications (called when the app comes to foreground).
  static Future<void> cancelAll() async {
    if (kIsWeb) return;
    try {
      await _plugin.cancelAll();
    } catch (e) {
      debugPrint('NotificationService: cancelAll() failed: $e');
    }
  }
}
