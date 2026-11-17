/// 开学第一周的周一日期。
class SemesterStart {
  SemesterStart(this.year, this.month, this.day) {
    if (month < 1 || month > 12) {
      throw ArgumentError('月份越界：$month');
    }
    if (day < 1 || day > 31) {
      throw ArgumentError('日期越界：$day');
    }
  }

  final int year;
  final int month;
  final int day;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SemesterStart &&
          year == other.year &&
          month == other.month &&
          day == other.day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() =>
      '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
}

/// 学期值对象（形如 `2026-2027-1`）。
class AcademicTerm {
  const AcademicTerm(this.id, [String? name]) : name = name ?? id;

  final String id;
  final String name;

  /// 学年起始年，如 `2026-2027-1` -> `2026`。不识别给 0。
  int get year {
    final dash = id.indexOf('-');
    final prefix = dash < 0 ? id : id.substring(0, dash);
    return int.tryParse(prefix) ?? 0;
  }

  /// 学期序号 1/2/3/4（3 = 暑期/短学期，4 = 寒假）。
  int get semester {
    final dash = id.lastIndexOf('-');
    final suffix = dash < 0 ? '' : id.substring(dash + 1);
    return int.tryParse(suffix) ?? 0;
  }

  /// 下一个学期。
  AcademicTerm next() {
    if (semester == 1) {
      return AcademicTerm('$year-${year + 1}-2');
    }
    return AcademicTerm('${year + 1}-${year + 2}-1');
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcademicTerm && id == other.id && name == other.name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => id;
}

/// 学期的可选列表、当前选中学期与教务服务端校历权威元数据。
class StudyCatalog {
  StudyCatalog({
    required List<AcademicTerm> terms,
    required this.currentTerm,
    this.currentWeek,
    this.serverDate = '',
    this.semesterStart,
    this.totalWeeks,
  }) : terms = List.unmodifiable(terms);

  final List<AcademicTerm> terms;
  final AcademicTerm currentTerm;
  final int? currentWeek;
  final String serverDate;
  final SemesterStart? semesterStart;
  final int? totalWeeks;
}
