/// Pure quiet-hours logic, shared by settings, notifications and tests.
///
/// A quiet-hours window is defined by two `HH:mm` times. The window may
/// wrap around midnight (e.g. 23:00 → 07:00). Times that cannot be parsed
/// are treated as "not in quiet hours".
class QuietHours {
  QuietHours._();

  /// Parses `HH:mm` into minutes since midnight, or `null` when invalid.
  static int? _toMinutes(String time) {
    final parts = time.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return hour * 60 + minute;
  }

  /// Whether [now] falls within the quiet-hours window
  /// ([start] inclusive, [end] exclusive; end may wrap past midnight).
  static bool isInQuietHours({
    required String start,
    required String end,
    DateTime? now,
  }) {
    final startMin = _toMinutes(start);
    final endMin = _toMinutes(end);
    if (startMin == null || endMin == null) return false;

    final current = now ?? DateTime.now();
    final currentMin = current.hour * 60 + current.minute;

    if (startMin == endMin) {
      // A zero-length window is always inactive.
      return false;
    }
    if (startMin < endMin) {
      return currentMin >= startMin && currentMin < endMin;
    }
    // Wraps around midnight.
    return currentMin >= startMin || currentMin < endMin;
  }
}
