// GamePrompts.uninstall must clear exactly the callbacks its install() set.
// Each evaluation of a method tear-off is a new object, so an identical()
// guard never matched and left a disposed Home's context on Game (PR #101).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/widgets/game_prompts.dart';

void main() {
  Future<(Game, BuildContext)> setUp(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final game = Game();
    late BuildContext context;
    await tester.pumpWidget(Builder(builder: (c) {
      context = c;
      return const SizedBox();
    }));
    await tester.pump();
    return (game, context);
  }

  testWidgets('uninstall clears every callback install set', (tester) async {
    final (game, context) = await setUp(tester);
    final prompts = GamePrompts(game, context)..install();
    expect(game.onRequestSwitchTeamOrderDialog, isNotNull);

    prompts.uninstall();

    expect(game.onRequestSwitchTeamOrderDialog, isNull);
    expect(game.onRequestResumeMatch, isNull);
    expect(game.onRequestConfirmScoreboardMatch, isNull);
    expect(game.onRequestReviewScoreboardResult, isNull);
    game.dispose();
  });

  testWidgets('uninstall keeps a callback a newer owner installed',
      (tester) async {
    final (game, context) = await setUp(tester);
    final stale = GamePrompts(game, context)..install();
    final fresh = GamePrompts(game, context)..install();

    stale.uninstall();

    expect(game.onRequestSwitchTeamOrderDialog, isNotNull,
        reason: "the old Home must not clear the new Home's callbacks");
    fresh.uninstall();
    expect(game.onRequestSwitchTeamOrderDialog, isNull);
    game.dispose();
  });
}
