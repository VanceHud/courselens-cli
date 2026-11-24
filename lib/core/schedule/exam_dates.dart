import '../model/study.dart';
import '../parse/civil_date.dart';

/// 考试日期的统一提取规则。
abstract final class ExamDates {
  static final RegExp _embeddedDatePattern = RegExp(
    r'(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})',
  );

  /// 从任意文本中提取首个 `YYYY-M-D` / `YYYY/M/D` / `YYYY.M.D` / `YYYY年M月D` 日期；
  /// 未找到或不是真实存在的日历日期时返回 `null`。
  static (int, int, int)? parse(String raw) {
    final match = _embeddedDatePattern.firstMatch(raw);
    if (match == null) return null;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final roundTrip = CivilDate.civilFromDays(
      CivilDate.daysFromCivil(year, month, day),
    );
    if (roundTrip != (year, month, day)) return null;
    return (year, month, day);
  }

  /// 考试日期：优先解析 [ExamEntry.examDate]，为空或不含合法日期时回退到 [ExamEntry.time]。
  static (int, int, int)? of(ExamEntry exam) =>
      parse(exam.examDate) ?? parse(exam.time);
}
