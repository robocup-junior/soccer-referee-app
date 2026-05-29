# AUDIT-FIX-03 Report

## Summary

Persisted the configurable game parameters in `Game` using `SharedPreferences`. The public `periodTime`, `halfTimeDuration`, `numberOfPLayers`, and `penaltyTime` API remains assignment-compatible through getters/setters, defaults are still available synchronously during startup, and saved preferences are loaded asynchronously after construction. When preferences load while no game is running, `gameInit()` is called so the timer and enabled module count reflect the persisted values.

## Files changed

- `lib/models/game.dart` — added `SharedPreferences` persistence, private backing fields, getters/setters, async preference loading, and load-time clamping for player count.
- `docs/ai/handoff/AUDIT-FIX-03_REPORT.md` — this handoff report.

## Deviations

None.

## Verification results

`flutter analyze`

```text
Analyzing rcj_scoreboard...

   info • Constructors for public widgets should have a named 'key' parameter. Try adding a named parameter to the constructor • lib/main.dart:42:3 • use_key_in_widget_constructors
   info • Constructors in '@immutable' classes should be declared as 'const'. Try adding 'const' to the constructor declaration • lib/main.dart:42:3 • prefer_const_constructors_in_immutables
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/main.dart:59:22 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/main.dart:61:25 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/models/game.dart:135:29 • prefer_const_constructors
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/game.dart:170:13 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/game.dart:340:9 • avoid_print
   info • Statements in an if should be enclosed in a block. Try wrapping the statement in a block • lib/models/game.dart:353:7 • curly_braces_in_flow_control_structures
   info • The variable name '_team_id' isn't a lowerCamelCase identifier. Try changing the name to follow the lowerCamelCase style • lib/models/module.dart:35:16 • non_constant_identifier_names
warning • This default clause is covered by the previous cases. Try removing the default clause, or restructuring the preceding patterns • lib/models/module.dart:90:7 • unreachable_switch_default
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/module.dart:91:9 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/module.dart:117:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/module.dart:129:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/module.dart:136:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/module.dart:155:9 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/module.dart:166:9 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/module.dart:170:9 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/module.dart:197:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/module.dart:208:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/module.dart:220:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/module.dart:232:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/module.dart:243:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/module.dart:277:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/module.dart:293:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/module.dart:417:9 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/module.dart:444:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/module.dart:490:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/module.dart:503:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/module.dart:511:9 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/models/module.dart:515:9 • avoid_print
   info • Constructors in '@immutable' classes should be declared as 'const'. Try adding 'const' to the constructor declaration • lib/screens/home.dart:14:3 • prefer_const_constructors_in_immutables
   info • 'onPopInvoked' is deprecated and shouldn't be used. Use onPopInvokedWithResult instead. This feature was deprecated after v3.22.0-12.0.pre. Try replacing the use of the deprecated member with the replacement • lib/screens/home.dart:40:7 • deprecated_member_use
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/home.dart:59:21 • prefer_const_constructors
   info • Use a 'SizedBox' to add whitespace to a layout. Try using a 'SizedBox' rather than a 'Container' • lib/screens/home.dart:91:29 • sized_box_for_whitespace
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/home.dart:108:46 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/home.dart:174:36 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/home.dart:212:26 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/home.dart:278:32 • prefer_const_constructors
   info • Parameter 'key' could be a super parameter. Trying converting 'key' to a super parameter • lib/screens/home.dart:408:9 • use_super_parameters
   info • Invalid use of a private type in a public API. Try making the private type public, or making the API that uses the private type also be private • lib/screens/home.dart:411:3 • library_private_types_in_public_api
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/home.dart:446:9 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/home.dart:449:13 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/home.dart:451:22 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/home.dart:451:47 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/home.dart:458:24 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/home.dart:460:27 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/home.dart:472:9 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/home.dart:476:13 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/home.dart:476:34 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/home.dart:485:21 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/home.dart:486:22 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/home.dart:486:41 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/home.dart:492:21 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/home.dart:493:22 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/home.dart:493:41 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/home.dart:550:13 • prefer_const_constructors
   info • The variable name 'pop_enable' isn't a lowerCamelCase identifier. Try changing the name to follow the lowerCamelCase style • lib/screens/mac_qr_scanner.dart:13:8 • non_constant_identifier_names
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/mac_qr_scanner.dart:85:16 • prefer_const_constructors
   info • 'withOpacity' is deprecated and shouldn't be used. Use .withValues() to avoid precision loss. Try replacing the use of the deprecated member with the replacement • lib/screens/mac_qr_scanner.dart:101:37 • deprecated_member_use
   info • Invalid use of a private type in a public API. Try making the private type public, or making the API that uses the private type also be private • lib/screens/module_settings.dart:19:3 • library_private_types_in_public_api
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:190:17 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:192:26 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:196:26 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:201:13 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:202:13 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:203:13 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:209:27 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:211:29 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:213:28 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:214:25 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:217:22 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:220:13 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:239:83 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:243:13 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:253:27 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:254:92 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:260:17 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:267:13 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:268:13 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:270:22 • prefer_const_constructors
   info • Unnecessary instance of 'Container'. Try removing the 'Container' (but not its children) from the widget tree • lib/screens/module_settings.dart:277:26 • avoid_unnecessary_containers
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:280:71 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:281:81 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:308:15 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:309:16 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:309:44 • prefer_const_constructors
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/module_settings.dart:312:53 • prefer_const_constructors
   info • Constructors for public widgets should have a named 'key' parameter. Try adding a named parameter to the constructor • lib/screens/settings.dart:9:3 • use_key_in_widget_constructors
   info • Constructors in '@immutable' classes should be declared as 'const'. Try adding 'const' to the constructor declaration • lib/screens/settings.dart:9:3 • prefer_const_constructors_in_immutables
   info • Invalid use of a private type in a public API. Try making the private type public, or making the API that uses the private type also be private • lib/screens/settings.dart:12:3 • library_private_types_in_public_api
   info • 'onPopInvoked' is deprecated and shouldn't be used. Use onPopInvokedWithResult instead. This feature was deprecated after v3.22.0-12.0.pre. Try replacing the use of the deprecated member with the replacement • lib/screens/settings.dart:76:7 • deprecated_member_use
   info • 'onPopInvoked' is deprecated and shouldn't be used. Use onPopInvokedWithResult instead. This feature was deprecated after v3.22.0-12.0.pre. Try replacing the use of the deprecated member with the replacement • lib/screens/settings.dart:79:9 • deprecated_member_use
   info • Constructors for public widgets should have a named 'key' parameter. Try adding a named parameter to the constructor • lib/screens/settings.dart:404:3 • use_key_in_widget_constructors
   info • Constructors in '@immutable' classes should be declared as 'const'. Try adding 'const' to the constructor declaration • lib/screens/settings.dart:404:3 • prefer_const_constructors_in_immutables
   info • 'activeColor' is deprecated and shouldn't be used. Use activeThumbColor instead. This feature was deprecated after v3.31.0-2.0.pre. Try replacing the use of the deprecated member with the replacement • lib/screens/settings.dart:428:21 • deprecated_member_use
   info • Constructors for public widgets should have a named 'key' parameter. Try adding a named parameter to the constructor • lib/screens/settings.dart:448:3 • use_key_in_widget_constructors
   info • Constructors in '@immutable' classes should be declared as 'const'. Try adding 'const' to the constructor declaration • lib/screens/settings.dart:448:3 • prefer_const_constructors_in_immutables
   info • Constructors for public widgets should have a named 'key' parameter. Try adding a named parameter to the constructor • lib/screens/settings.dart:488:3 • use_key_in_widget_constructors
   info • Constructors in '@immutable' classes should be declared as 'const'. Try adding 'const' to the constructor declaration • lib/screens/settings.dart:488:3 • prefer_const_constructors_in_immutables
   info • The 'child' argument should be last in widget constructor invocations. Try moving the argument to the end of the argument list • lib/screens/settings.dart:506:15 • sort_child_properties_last
   info • Constructors for public widgets should have a named 'key' parameter. Try adding a named parameter to the constructor • lib/screens/settings.dart:568:3 • use_key_in_widget_constructors
   info • Constructors in '@immutable' classes should be declared as 'const'. Try adding 'const' to the constructor declaration • lib/screens/settings.dart:568:3 • prefer_const_constructors_in_immutables
   info • Invalid use of a private type in a public API. Try making the private type public, or making the API that uses the private type also be private • lib/screens/settings.dart:576:3 • library_private_types_in_public_api
   info • Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation • lib/screens/settings.dart:631:25 • prefer_const_constructors
   info • Constructors for public widgets should have a named 'key' parameter. Try adding a named parameter to the constructor • lib/screens/settings.dart:653:3 • use_key_in_widget_constructors
   info • Constructors in '@immutable' classes should be declared as 'const'. Try adding 'const' to the constructor declaration • lib/screens/settings.dart:653:3 • prefer_const_constructors_in_immutables
   info • Invalid use of a private type in a public API. Try making the private type public, or making the API that uses the private type also be private • lib/screens/settings.dart:656:3 • library_private_types_in_public_api
   info • Parameter 'key' could be a super parameter. Trying converting 'key' to a super parameter • lib/screens/settings.dart:709:9 • use_super_parameters
   info • 'activeColor' is deprecated and shouldn't be used. Use activeThumbColor instead. This feature was deprecated after v3.31.0-2.0.pre. Try replacing the use of the deprecated member with the replacement • lib/screens/settings.dart:729:15 • deprecated_member_use
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/ble.dart:26:5 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/ble.dart:27:5 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/ble.dart:33:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/ble.dart:72:9 • avoid_print
   info • The private field _state could be 'final'. Try making the field 'final' • lib/services/match_data.dart:40:10 • prefer_final_fields
   info • Redundant initialization to 'null'. Try removing the initializer • lib/services/match_data.dart:42:10 • avoid_init_to_null
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/match_data.dart:61:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/match_data.dart:64:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/match_data.dart:93:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/match_data.dart:104:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/match_data.dart:116:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/match_data.dart:119:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/match_data.dart:127:9 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/match_data.dart:132:9 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/match_data.dart:137:7 • avoid_print
   info • The variable name '_main_topic' isn't a lowerCamelCase identifier. Try changing the name to follow the lowerCamelCase style • lib/services/mqtt.dart:20:16 • non_constant_identifier_names
   info • The variable name 'field_number' isn't a lowerCamelCase identifier. Try changing the name to follow the lowerCamelCase style • lib/services/mqtt.dart:75:14 • non_constant_identifier_names
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:88:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:98:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:108:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:118:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:128:7 • avoid_print
   info • The variable name 'topic_field' isn't a lowerCamelCase identifier. Try changing the name to follow the lowerCamelCase style • lib/services/mqtt.dart:132:7 • non_constant_identifier_names
warning • The member 'notifyListeners' can only be used within 'package:flutter/src/foundation/change_notifier.dart' or a test • lib/services/mqtt.dart:134:29 • invalid_use_of_visible_for_testing_member
warning • The member 'notifyListeners' can only be used within instance members of subclasses of 'ChangeNotifier' • lib/services/mqtt.dart:134:29 • invalid_use_of_protected_member
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:166:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:203:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:206:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:211:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:218:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:222:7 • avoid_print
warning • The declaration '_subscribeToTopic' isn't referenced. Try removing the declaration of '_subscribeToTopic' • lib/services/mqtt.dart:244:8 • unused_element
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:247:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:256:9 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:267:11 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:278:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:349:7 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:356:5 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:366:5 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:371:7 • avoid_print
   info • The local variable '_attemptReconnect' starts with an underscore. Try renaming the variable to not start with an underscore • lib/services/mqtt.dart:376:18 • no_leading_underscores_for_local_identifiers
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:379:9 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:382:9 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:404:5 • avoid_print
   info • Don't invoke 'print' in production code. Try using a logging framework • lib/services/mqtt.dart:408:5 • avoid_print

154 issues found. (ran in 1.8s)
```

`grep -n "SharedPreferences\|_prefs\|game_period" lib/models/game.dart`

```text
17:  static const String _periodTimeKey = 'game_period_time';
36:  SharedPreferences? _prefs;
72:    _prefs = await SharedPreferences.getInstance();
73:    _periodTime = _prefs!.getInt(_periodTimeKey) ?? 600;
74:    _halfTimeDuration = _prefs!.getInt(_halfTimeDurationKey) ?? 300;
76:        (_prefs!.getInt(_numberOfPlayersKey) ?? 2).clamp(1, _maxPlayer).toInt();
77:    _penaltyTime = _prefs!.getInt(_penaltyTimeKey) ?? 60;
393:    _prefs?.setInt(_periodTimeKey, value);
399:    _prefs?.setInt(_halfTimeDurationKey, value);
405:    _prefs?.setInt(_numberOfPlayersKey, value);
411:    _prefs?.setInt(_penaltyTimeKey, value);
```

## Manual test status

Not run. No Android device or emulator session was available in this environment for the kill/restart persistence check.

## Open questions / risks

- `flutter analyze` reports 154 existing issues and exits non-zero, but no compile errors were reported.
- Reviewer should still perform the manual app restart test for all four game settings on an Android device or emulator.
