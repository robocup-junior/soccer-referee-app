String _two(int n) => n.toString().padLeft(2, '0');

/// `mm:ss` clock display of a duration in seconds.
String formatClock(int seconds) =>
    '${_two(seconds ~/ 60)}:${_two(seconds % 60)}';

/// Parse a remaining-time entry: plain nonnegative seconds ("123") or "mm:ss"
/// with seconds in 0..59. Null for anything else so a typo is ignored.
int? parseMmSs(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  if (!text.contains(':')) {
    final seconds = int.tryParse(text);
    return seconds == null || seconds < 0 ? null : seconds;
  }
  final parts = text.split(':');
  if (parts.length != 2) return null;
  final minutes = int.tryParse(parts[0]);
  final secs = int.tryParse(parts[1]);
  if (minutes == null || secs == null || minutes < 0 || secs < 0 || secs > 59) {
    return null;
  }
  return minutes * 60 + secs;
}

/// "N min", "N s" or "N min M s" (never a misleading "0 min").
String formatMatchDuration(int seconds) {
  if (seconds <= 0) return '0 s';
  final minutes = seconds ~/ 60;
  final secs = seconds % 60;
  if (minutes == 0) return '$secs s';
  if (secs == 0) return '$minutes min';
  return '$minutes min $secs s';
}

/// The fixture's kickoff in the phone's local time ("Tue 3 Jun · 14:05"), or
/// null when the payload carries none.
String? formatLocalKickoff(DateTime? scheduledStart) {
  if (scheduledStart == null) return null;
  final dt = scheduledStart.toLocal();
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${days[dt.weekday - 1]} ${dt.day} ${months[dt.month - 1]} · '
      '${_two(dt.hour)}:${_two(dt.minute)}';
}
