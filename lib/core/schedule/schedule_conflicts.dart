import 'ics_export.dart';

/// 一处课表时间冲突（同一时段上了两门不同的课）。
class ScheduleConflict {
  ScheduleConflict({
    required this.firstIndex,
    required this.secondIndex,
    required this.day,
    required List<int> weeks,
  }) : weeks = List.unmodifiable(weeks);

  final int firstIndex;
  final int secondIndex;
  final int day;
  final List<int> weeks;

  String get weeksText => weeks.isEmpty ? '' : '第 ${weeks.join('、')} 周';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ScheduleConflict) return false;
    if (firstIndex != other.firstIndex ||
        secondIndex != other.secondIndex ||
        day != other.day ||
        weeks.length != other.weeks.length) {
      return false;
    }
    for (var i = 0; i < weeks.length; i++) {
      if (weeks[i] != other.weeks[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(firstIndex, secondIndex, day, Object.hashAll(weeks));
}

/// 课表时间冲突检测（纯函数）。
class ScheduleConflicts {
  const ScheduleConflicts._();

  static List<ScheduleConflict> find(List<IcsEntry> entries) {
    final result = <ScheduleConflict>[];
    for (var i = 0; i < entries.length; i++) {
      final first = entries[i];
      if (first.day < 1 || first.day > 7) continue;
      for (var j = i + 1; j < entries.length; j++) {
        final second = entries[j];
        if (second.day != first.day) continue;
        if (!_periodsOverlap(first, second)) continue;
        if (_isSameSession(first, second)) continue;
        final shared = _sharedWeeks(first, second);
        if (shared.isEmpty) continue;
        result.add(
          ScheduleConflict(
            firstIndex: i,
            secondIndex: j,
            day: first.day,
            weeks: shared,
          ),
        );
      }
    }
    return result;
  }

  static Set<int> conflictingIndices(List<IcsEntry> entries) {
    final indices = <int>{};
    for (final conflict in find(entries)) {
      indices.add(conflict.firstIndex);
      indices.add(conflict.secondIndex);
    }
    return indices;
  }

  static bool _periodsOverlap(IcsEntry a, IcsEntry b) =>
      a.startPeriod <= b.endPeriod && b.startPeriod <= a.endPeriod;

  static bool _isSameSession(IcsEntry a, IcsEntry b) =>
      a.name == b.name && a.teacher == b.teacher && a.location == b.location;

  static List<int> _sharedWeeks(IcsEntry a, IcsEntry b) {
    if (a.weeks.isEmpty || b.weeks.isEmpty) return const <int>[];
    final other = b.weeks.toSet();
    final shared = a.weeks.toSet().where(other.contains).toList()..sort();
    return shared;
  }
}
