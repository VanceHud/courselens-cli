import 'dart:convert';

import '../model/schedule.dart';
import '../model/term.dart';
import '../parse/civil_date.dart';

export '../model/term.dart' show SemesterStart;

/// 一节课的起止时间（`HH:mm`）。
class PeriodTime {
  const PeriodTime(this.period, this.start, this.end);

  final int period;
  final String start;
  final String end;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeriodTime &&
          period == other.period &&
          start == other.start &&
          end == other.end;

  @override
  int get hashCode => Object.hash(period, start, end);

  @override
  String toString() => 'PeriodTime($period, $start-$end)';
}

/// iCalendar 导出、冲突检测、周视图泳道与课前提醒共用的标准排课输入行。
class IcsEntry {
  IcsEntry({
    required this.name,
    required this.teacher,
    required this.location,
    required this.day,
    required this.startPeriod,
    required this.endPeriod,
    required List<int> weeks,
    this.weeksText = '',
  }) : weeks = List.unmodifiable(weeks);

  final String name;
  final String teacher;
  final String location;
  final int day;
  final int startPeriod;
  final int endPeriod;
  final List<int> weeks;
  final String weeksText;
}

extension ScheduleEntryIcsX on ScheduleEntry {
  IcsEntry toIcsEntry() => IcsEntry(
        name: name,
        teacher: teacher,
        location: location,
        day: day,
        startPeriod: period.start,
        endPeriod: period.end,
        weeks: weeks.weeks.toList(growable: false),
        weeksText: weeks.text,
      );
}

/// 课表 -> iCalendar (`.ics`) 纯函数生成器。
class IcsExport {
  const IcsExport._();

  static const int _daysPerWeek = 7;
  static const int _maxLineOctets = 75;
  static const String _timeZoneId = 'Asia/Shanghai';

  static final BigInt _fnvOffsetBasis =
      BigInt.parse('cbf29ce484222325', radix: 16);
  static final BigInt _fnvPrime = BigInt.parse('100000001b3', radix: 16);
  static final BigInt _mask64 = (BigInt.one << 64) - BigInt.one;

  static const List<(String, String)> _defaultShifts = [
    ('08:00', '08:45'),
    ('08:55', '09:40'),
    ('10:00', '10:45'),
    ('10:55', '11:40'),
    ('14:00', '14:45'),
    ('14:55', '15:40'),
    ('16:00', '16:45'),
    ('16:55', '17:40'),
    ('19:00', '19:45'),
    ('19:55', '20:40'),
    ('20:50', '21:35'),
    ('21:45', '22:30'),
  ];

  /// 默认 12 节作息表。
  static final List<PeriodTime> defaultPeriodTimes = List.unmodifiable([
    for (var i = 0; i < _defaultShifts.length; i++)
      PeriodTime(i + 1, _defaultShifts[i].$1, _defaultShifts[i].$2),
  ]);

  static String generate({
    required List<IcsEntry> entries,
    required SemesterStart semesterStart,
    int totalWeeks = 20,
    List<PeriodTime>? periodTimes,
    String calendarName = 'CourseLens 课表',
    int nowEpochSeconds = 0,
  }) {
    final activePeriods = periodTimes ?? defaultPeriodTimes;
    final schedule = <int, PeriodTime>{
      for (final p in activePeriods) p.period: p,
    };
    final firstMondayDays = CivilDate.daysFromCivil(
      semesterStart.year,
      semesterStart.month,
      semesterStart.day,
    );
    final stamp = CivilDate.compactUtcStamp(nowEpochSeconds);

    final document = StringBuffer();
    _appendCalendarPreamble(document, calendarName);
    for (final entry in entries) {
      _appendEntry(
        document,
        entry,
        schedule,
        firstMondayDays,
        totalWeeks,
        stamp,
      );
    }
    _appendLine(document, 'END:VCALENDAR');
    return document.toString();
  }

  static void _appendCalendarPreamble(
    StringBuffer target,
    String calendarName,
  ) {
    _appendLine(target, 'BEGIN:VCALENDAR');
    _appendLine(target, 'VERSION:2.0');
    _appendLine(target, 'PRODID:-//CourseLens//CN');
    _appendLine(target, 'CALSCALE:GREGORIAN');
    _appendLine(target, 'METHOD:PUBLISH');
    _appendLine(target, 'X-WR-CALNAME:${escapeIcalText(calendarName)}');
    _appendLine(target, 'X-WR-TIMEZONE:$_timeZoneId');
    _appendLine(target, 'BEGIN:VTIMEZONE');
    _appendLine(target, 'TZID:$_timeZoneId');
    _appendLine(target, 'BEGIN:STANDARD');
    _appendLine(target, 'DTSTART:19700101T000000');
    _appendLine(target, 'TZOFFSETFROM:+0800');
    _appendLine(target, 'TZOFFSETTO:+0800');
    _appendLine(target, 'END:STANDARD');
    _appendLine(target, 'END:VTIMEZONE');
  }

  static void _appendEntry(
    StringBuffer target,
    IcsEntry entry,
    Map<int, PeriodTime> schedule,
    int firstMondayDays,
    int totalWeeks,
    String stamp,
  ) {
    if (entry.day < 1 || entry.day > 7) return;
    final opening = schedule[entry.startPeriod];
    final closing = schedule[entry.endPeriod];
    if (opening == null || closing == null) return;
    if (!isClockText(opening.start) || !isClockText(closing.end)) return;

    final weeks = entry.weeks
        .where((w) => w >= 1 && w <= totalWeeks)
        .toList()
      ..sort();
    if (weeks.isEmpty) return;

    for (final weekNumber in weeks) {
      _appendEvent(
        target,
        entry,
        weekNumber,
        opening.start,
        closing.end,
        firstMondayDays,
        stamp,
      );
    }
  }

  static void _appendEvent(
    StringBuffer target,
    IcsEntry entry,
    int weekNumber,
    String startClock,
    String endClock,
    int firstMondayDays,
    String stamp,
  ) {
    final date = _eventDate(weekNumber, entry.day, firstMondayDays);
    _appendLine(target, 'BEGIN:VEVENT');
    _appendLine(target, 'UID:${eventUid(entry, date)}');
    _appendLine(target, 'DTSTAMP:$stamp');
    _appendLine(
      target,
      'DTSTART;TZID=$_timeZoneId:${date}T${_toIcalClock(startClock)}',
    );
    _appendLine(
      target,
      'DTEND;TZID=$_timeZoneId:${date}T${_toIcalClock(endClock)}',
    );
    _appendLine(target, 'SUMMARY:${escapeIcalText(entry.name)}');
    if (entry.location.trim().isNotEmpty) {
      _appendLine(target, 'LOCATION:${escapeIcalText(entry.location)}');
    }
    _appendLine(
      target,
      'DESCRIPTION:${escapeIcalText(_describeEvent(entry, weekNumber))}',
    );
    _appendLine(target, 'END:VEVENT');
  }

  static String _eventDate(int weekNumber, int dayOfWeek, int firstMondayDays) {
    final offsetDays = (weekNumber - 1) * _daysPerWeek + (dayOfWeek - 1);
    final (year, month, day) =
        CivilDate.civilFromDays(firstMondayDays + offsetDays);
    return CivilDate.compactDate(year, month, day);
  }

  static String eventUid(IcsEntry entry, String date) =>
      'courselens-${fingerprint(entry)}-$date@courselens';

  static String _describeEvent(IcsEntry entry, int weekNumber) {
    final out = StringBuffer();
    if (entry.teacher.trim().isNotEmpty) {
      out.write('任课教师: ${entry.teacher}\n');
    }
    out.write('第$weekNumber周');
    if (entry.weeksText.trim().isNotEmpty) {
      out.write('（${entry.weeksText}）');
    }
    return out.toString();
  }

  static String _toIcalClock(String clock) => '${clock.replaceAll(':', '')}00';

  /// 严格校验 `HH:mm`。
  static bool isClockText(String clock) {
    final halves = clock.split(':');
    if (halves.length != 2) return false;
    if (halves[0].length != 2 || halves[1].length != 2) return false;
    final hour = int.tryParse(halves[0]);
    final minute = int.tryParse(halves[1]);
    if (hour == null || minute == null) return false;
    return hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59;
  }

  /// RFC 5545 §3.3.11 文本转义。
  static String escapeIcalText(String raw) => raw
      .replaceAll(r'\', r'\\')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\n', r'\n')
      .replaceAll(',', r'\,')
      .replaceAll(';', r'\;');

  /// RFC 5545 §3.1 75 UTF-8 字节折行（不截断多字节字符）。
  static String foldLine(String line) {
    final totalBytes = utf8.encode(line);
    if (totalBytes.length <= _maxLineOctets) return '$line\r\n';

    final out = StringBuffer();
    var currentLine = StringBuffer();
    var currentOctets = 0;
    var firstLine = true;

    for (final rune in line.runes) {
      final ch = String.fromCharCode(rune);
      final chOctets = utf8.encode(ch).length;
      final limit = firstLine ? _maxLineOctets : (_maxLineOctets - 1);
      if (currentOctets + chOctets > limit && currentOctets > 0) {
        if (!firstLine) out.write(' ');
        out.write(currentLine.toString());
        out.write('\r\n');
        currentLine = StringBuffer();
        currentOctets = 0;
        firstLine = false;
      }
      currentLine.write(ch);
      currentOctets += chOctets;
    }
    if (currentOctets > 0) {
      if (!firstLine) out.write(' ');
      out.write(currentLine.toString());
      out.write('\r\n');
    }
    return out.toString();
  }

  static void _appendLine(StringBuffer target, String line) {
    target.write(foldLine(line));
  }

  /// 跨 VM / Wasm / JS 完全确定性的 64 位无符号 FNV-1a（16 位小写十六进制）。
  static String fnv1a64Hex(String material) {
    var hash = _fnvOffsetBasis;
    for (final byte in utf8.encode(material)) {
      hash = (hash ^ BigInt.from(byte & 0xFF)) & _mask64;
      hash = (hash * _fnvPrime) & _mask64;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static String fingerprint(IcsEntry entry) {
    final material = [
      entry.name,
      entry.teacher,
      entry.location,
      entry.day.toString(),
      entry.startPeriod.toString(),
      entry.endPeriod.toString(),
      entry.weeksText,
    ].join('|');
    return fnv1a64Hex(material);
  }
}
