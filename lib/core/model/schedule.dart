import 'student_identity.dart';

/// 节次闭区间，`PeriodSpan(1, 2)` 表示第 1、2 节。
class PeriodSpan {
  PeriodSpan(this.start, this.end) {
    if (start < 1 || start > maxPeriod) {
      throw ArgumentError('节次起始越界：$start');
    }
    if (end < start || end > maxPeriod) {
      throw ArgumentError('节次结束越界：$end');
    }
  }

  static const int maxPeriod = 30;

  final int start;
  final int end;

  int get length => end - start + 1;

  Map<String, Object?> toJson() => <String, Object?>{
        'start': start,
        'end': end,
      };

  factory PeriodSpan.fromJson(Map<String, dynamic> json) {
    final s = ((json['start'] as num?)?.toInt() ?? 1).clamp(1, maxPeriod);
    final e = ((json['end'] as num?)?.toInt() ?? s).clamp(s, maxPeriod);
    return PeriodSpan(s, e);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeriodSpan && start == other.start && end == other.end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'PeriodSpan($start, $end)';
}

/// 展开后的上课周次集合及原始文案。
class WeekPattern {
  WeekPattern(Iterable<int> weeks, this.text)
      : weeks = Set.unmodifiable(weeks.toSet());

  const WeekPattern._empty()
      : weeks = const <int>{},
        text = '';

  static const WeekPattern empty = WeekPattern._empty();

  final Set<int> weeks;
  final String text;

  bool get isEmpty => weeks.isEmpty;

  int get highestWeek =>
      weeks.isEmpty ? 0 : weeks.reduce((a, b) => a > b ? a : b);

  bool contains(int week) => weeks.contains(week);

  bool overlaps(WeekPattern other) => weeks.any(other.weeks.contains);

  Map<String, Object?> toJson() => <String, Object?>{
        'weeks': (weeks.toList()..sort()),
        'text': text,
      };

  factory WeekPattern.fromJson(Map<String, dynamic> json) {
    final rawWeeks = json['weeks'];
    final parsed = <int>[];
    if (rawWeeks is List) {
      for (final item in rawWeeks) {
        final v = (item as num?)?.toInt();
        if (v != null) parsed.add(v);
      }
    }
    return WeekPattern(parsed, json['text'] as String? ?? '');
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! WeekPattern) return false;
    if (text != other.text || weeks.length != other.weeks.length) return false;
    return weeks.containsAll(other.weeks);
  }

  @override
  int get hashCode => Object.hash(text, Object.hashAllUnordered(weeks));

  @override
  String toString() => 'WeekPattern($text)';
}

/// 一条排课记录（某天、某节次区间、某周次集合上的一门课）。
class ScheduleEntry {
  ScheduleEntry({
    required this.name,
    required this.teacher,
    required this.location,
    required this.day,
    required this.period,
    required this.weeks,
    this.sourceId = '',
    this.courseCode = '',
    this.teachingClass = '',
    this.credits = '',
    this.assessment = '',
    this.courseCategory = '',
    this.campus = '',
    this.isRetake = false,
    this.teachingFormSymbol = '',
  }) {
    if (day < 1 || day > 7) {
      throw ArgumentError('星期越界：$day');
    }
  }

  final String name;
  final String teacher;
  final String location;
  final int day;
  final PeriodSpan period;
  final WeekPattern weeks;
  final String sourceId;
  final String courseCode;
  final String teachingClass;
  final String credits;
  final String assessment;
  final String courseCategory;
  final String campus;
  final bool isRetake;
  final String teachingFormSymbol;

  bool occursIn(int week) => weeks.contains(week);

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'teacher': teacher,
        'location': location,
        'day': day,
        'period': period.toJson(),
        'weeks': weeks.toJson(),
        'sourceId': sourceId,
        'courseCode': courseCode,
        'teachingClass': teachingClass,
        'credits': credits,
        'assessment': assessment,
        'courseCategory': courseCategory,
        'campus': campus,
        'isRetake': isRetake,
        'teachingFormSymbol': teachingFormSymbol,
      };

  factory ScheduleEntry.fromJson(Map<String, dynamic> json) {
    final rawPeriod = json['period'];
    final rawWeeks = json['weeks'];
    return ScheduleEntry(
      name: json['name'] as String? ?? '',
      teacher: json['teacher'] as String? ?? '',
      location: json['location'] as String? ?? '',
      day: ((json['day'] as num?)?.toInt() ?? 1).clamp(1, 7),
      period: rawPeriod is Map
          ? PeriodSpan.fromJson(Map<String, dynamic>.from(rawPeriod))
          : PeriodSpan(1, 2),
      weeks: rawWeeks is Map
          ? WeekPattern.fromJson(Map<String, dynamic>.from(rawWeeks))
          : WeekPattern.empty,
      sourceId: json['sourceId'] as String? ?? '',
      courseCode: json['courseCode'] as String? ?? '',
      teachingClass: json['teachingClass'] as String? ?? '',
      credits: json['credits'] as String? ?? '',
      assessment: json['assessment'] as String? ?? '',
      courseCategory: json['courseCategory'] as String? ?? '',
      campus: json['campus'] as String? ?? '',
      isRetake: json['isRetake'] == true,
      teachingFormSymbol: json['teachingFormSymbol'] as String? ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScheduleEntry &&
          name == other.name &&
          teacher == other.teacher &&
          location == other.location &&
          day == other.day &&
          period == other.period &&
          weeks == other.weeks &&
          sourceId == other.sourceId &&
          courseCode == other.courseCode &&
          teachingClass == other.teachingClass &&
          credits == other.credits &&
          assessment == other.assessment &&
          courseCategory == other.courseCategory &&
          campus == other.campus &&
          isRetake == other.isRetake &&
          teachingFormSymbol == other.teachingFormSymbol;

  @override
  int get hashCode => Object.hash(
        name,
        teacher,
        location,
        day,
        period,
        weeks,
        sourceId,
        courseCode,
        teachingClass,
        credits,
        assessment,
        courseCategory,
        campus,
        isRetake,
        teachingFormSymbol,
      );

  @override
  String toString() =>
      'ScheduleEntry($name, day=$day, period=${period.start}-${period.end}, weeks=${weeks.text})';
}

typedef CourseEntry = ScheduleEntry;

/// 实践课、实训、未排星期节次的实验或重修课程（来自 `sjkList` 或无节次的 `kbList`）。
class PracticalCourse {
  const PracticalCourse({
    required this.name,
    this.teacher = '',
    this.credits = '',
    this.weeksText = '',
    this.summary = '',
    this.category = '',
    this.assessment = '',
    this.campus = '',
    this.isRetake = false,
    this.courseCode = '',
    this.teachingClass = '',
  });

  final String name;
  final String teacher;
  final String credits;
  final String weeksText;
  final String summary;
  final String category;
  final String assessment;
  final String campus;
  final bool isRetake;
  final String courseCode;
  final String teachingClass;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'teacher': teacher,
        'credits': credits,
        'weeksText': weeksText,
        'summary': summary,
        'category': category,
        'assessment': assessment,
        'campus': campus,
        'isRetake': isRetake,
        'courseCode': courseCode,
        'teachingClass': teachingClass,
      };

  factory PracticalCourse.fromJson(Map<String, dynamic> json) =>
      PracticalCourse(
        name: json['name'] as String? ?? '',
        teacher: json['teacher'] as String? ?? '',
        credits: json['credits'] as String? ?? '',
        weeksText: json['weeksText'] as String? ?? '',
        summary: json['summary'] as String? ?? '',
        category: json['category'] as String? ?? '',
        assessment: json['assessment'] as String? ?? '',
        campus: json['campus'] as String? ?? '',
        isRetake: json['isRetake'] == true,
        courseCode: json['courseCode'] as String? ?? '',
        teachingClass: json['teachingClass'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PracticalCourse &&
          name == other.name &&
          teacher == other.teacher &&
          credits == other.credits &&
          weeksText == other.weeksText &&
          summary == other.summary &&
          category == other.category &&
          assessment == other.assessment &&
          campus == other.campus &&
          isRetake == other.isRetake &&
          courseCode == other.courseCode &&
          teachingClass == other.teachingClass;

  @override
  int get hashCode => Object.hash(
        name,
        teacher,
        credits,
        weeksText,
        summary,
        category,
        assessment,
        campus,
        isRetake,
        courseCode,
        teachingClass,
      );
}

/// 完整课表载荷（常规排课网格 [entries] + 实践/未排时间课程 [practicalCourses] + 可选学生信息 [studentInfo]）。
class Schedule {
  Schedule({
    required List<ScheduleEntry> entries,
    List<PracticalCourse> practicalCourses = const <PracticalCourse>[],
    this.studentInfo,
    this.termId = '',
  })  : entries = List.unmodifiable(entries),
        practicalCourses = List.unmodifiable(practicalCourses);

  final List<ScheduleEntry> entries;
  final List<PracticalCourse> practicalCourses;
  final StudentIdentity? studentInfo;
  final String termId;

  Map<String, Object?> toJson() => <String, Object?>{
        'entries': entries.map((e) => e.toJson()).toList(growable: false),
        'practicalCourses':
            practicalCourses.map((e) => e.toJson()).toList(growable: false),
        if (studentInfo != null && !studentInfo!.isEmpty)
          'studentInfo': studentInfo!.toJson(),
        'termId': termId,
      };

  factory Schedule.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'];
    final entries = <ScheduleEntry>[];
    if (rawEntries is List) {
      for (final item in rawEntries) {
        if (item is Map) {
          entries.add(ScheduleEntry.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    final rawPracticals = json['practicalCourses'];
    final practicals = <PracticalCourse>[];
    if (rawPracticals is List) {
      for (final item in rawPracticals) {
        if (item is Map) {
          practicals
              .add(PracticalCourse.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    final rawStudent = json['studentInfo'];
    final student = rawStudent is Map
        ? StudentIdentity.fromJson(Map<String, dynamic>.from(rawStudent))
        : null;
    return Schedule(
      entries: entries,
      practicalCourses: practicals,
      studentInfo: student,
      termId: json['termId'] as String? ?? '',
    );
  }
}
