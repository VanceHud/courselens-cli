import '../parse/civil_date.dart';
import 'clock_text.dart';
import 'ics_export.dart';

/// 一条课前绝对时刻提醒。
class CourseReminder {
  const CourseReminder({
    required this.id,
    required this.title,
    required this.body,
    required this.fireAtEpochSeconds,
    required this.courseName,
    required this.location,
    required this.week,
    required this.day,
    required this.startPeriod,
  });

  final String id;
  final String title;
  final String body;
  final int fireAtEpochSeconds;
  final String courseName;
  final String location;
  final int week;
  final int day;
  final int startPeriod;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CourseReminder &&
          id == other.id &&
          title == other.title &&
          body == other.body &&
          fireAtEpochSeconds == other.fireAtEpochSeconds &&
          courseName == other.courseName &&
          location == other.location &&
          week == other.week &&
          day == other.day &&
          startPeriod == other.startPeriod;

  @override
  int get hashCode => Object.hash(
        id,
        title,
        body,
        fireAtEpochSeconds,
        courseName,
        location,
        week,
        day,
        startPeriod,
      );
}

/// 课前提醒纯函数规划器（上限默认 60 条以适配 iOS 64 条待发通知硬上限）。
class CourseReminderPlanner {
  const CourseReminderPlanner._();

  static const List<String> _weekdayNames = [
    '周一',
    '周二',
    '周三',
    '周四',
    '周五',
    '周六',
    '周日',
  ];

  static List<CourseReminder> plan({
    required List<IcsEntry> entries,
    required SemesterStart semesterStart,
    required List<PeriodTime> periodTimes,
    required int fromEpochSeconds,
    required int untilEpochSeconds,
    int leadMinutes = 15,
    int limit = 60,
    int utcOffsetSeconds = 8 * 3600,
  }) {
    if (limit <= 0 || untilEpochSeconds <= fromEpochSeconds) {
      return const <CourseReminder>[];
    }
    final times = <int, PeriodTime>{
      for (final p in periodTimes) p.period: p,
    };
    final startDays = CivilDate.daysFromCivil(
      semesterStart.year,
      semesterStart.month,
      semesterStart.day,
    );
    final leadSeconds = (leadMinutes < 0 ? 0 : leadMinutes) * 60;
    final result = <CourseReminder>[];

    for (final entry in entries) {
      if (entry.day < 1 || entry.day > 7) continue;
      final start = times[entry.startPeriod];
      final end = times[entry.endPeriod];
      if (start == null || end == null) continue;
      final startClock = _parseClock(start.start);
      final endClock = _parseClock(end.end);
      if (startClock == null || endClock == null) continue;

      final sortedWeeks = [...entry.weeks]..sort();
      for (final week in sortedWeeks) {
        final offset = (week - 1) * 7 + (entry.day - 1);
        final (year, month, day) =
            CivilDate.civilFromDays(startDays + offset);
        final classAt = CivilDate.epochSecondsAt(
          year,
          month,
          day,
          startClock.$1,
          startClock.$2,
          utcOffsetSeconds: utcOffsetSeconds,
        );
        final fireAt = classAt - leadSeconds;
        if (fireAt <= fromEpochSeconds || fireAt > untilEpochSeconds) continue;
        result.add(
          CourseReminder(
            id: _reminderId(entry, week, year, month, day),
            title: '${entry.name} 即将开始',
            body: _describe(entry, week, start, end, leadMinutes),
            fireAtEpochSeconds: fireAt,
            courseName: entry.name,
            location: entry.location,
            week: week,
            day: entry.day,
            startPeriod: entry.startPeriod,
          ),
        );
      }
    }

    result.sort((a, b) {
      final cmp = a.fireAtEpochSeconds.compareTo(b.fireAtEpochSeconds);
      return cmp != 0 ? cmp : a.id.compareTo(b.id);
    });
    return result.length <= limit ? result : result.sublist(0, limit);
  }

  static String _describe(
    IcsEntry entry,
    int week,
    PeriodTime start,
    PeriodTime end,
    int leadMinutes,
  ) {
    final out = StringBuffer()
      ..write('第$week周 ')
      ..write(_weekdayName(entry.day))
      ..write(
        ' 第${entry.startPeriod}-${entry.endPeriod}节 ${start.start}–${end.end}',
      );
    if (entry.location.trim().isNotEmpty) {
      out.write(' · ${entry.location}');
    }
    if (leadMinutes > 0) {
      out.write('（$leadMinutes 分钟后上课）');
    }
    return out.toString();
  }

  static String _reminderId(
    IcsEntry entry,
    int week,
    int year,
    int month,
    int day,
  ) {
    final material = [
      entry.name,
      entry.teacher,
      entry.location,
      entry.day.toString(),
      entry.startPeriod.toString(),
      entry.endPeriod.toString(),
      week.toString(),
      CivilDate.compactDate(year, month, day),
    ].join('|');
    return IcsExport.fnv1a64Hex(material);
  }

  static String _weekdayName(int day) =>
      day >= 1 && day <= 7 ? _weekdayNames[day - 1] : '周$day';

  static (int, int)? _parseClock(String value) {
    final minutes = ClockText.parseMinutes(value);
    if (minutes == null) return null;
    return (minutes ~/ 60, minutes % 60);
  }
}
