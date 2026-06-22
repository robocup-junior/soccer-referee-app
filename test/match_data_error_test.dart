import 'package:flutter_test/flutter_test.dart';
import 'package:rcj_scoreboard/services/error_messages.dart';

void main() {
  // loadMatch() drives stateNotifier through describeError; this proves the
  // mapping produces the descriptive schedule-load message for an HTTP error.
  test('describeError on a 404 yields the schedule-load message', () {
    final info = describeError(const HttpStatusException(404));
    expect(info.message, 'Server returned 404');
    expect(info.hint, 'Check the match-data URL in settings');
  });
}
