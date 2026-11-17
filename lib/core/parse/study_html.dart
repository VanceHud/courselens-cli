import '../model/academic_status.dart';
import '../model/study.dart';
import 'html.dart';
import 'table_rows.dart';

/// 考试安排 HTML 解析。
class StudyHtml {
  const StudyHtml._();

  static List<ExamEntry> exams(String html, String baseUrl) {
    _requireExamPage(html);
    return TableRows.rows(html, baseUrl).map(_examEntryOf).toList();
  }

  static ExamEntry _examEntryOf(TableRow row) {
    final campus = row.value(const ['考试校区', '校区']);
    final room = row.value(const ['考场', '考试地点', '考试教室']);
    final location = [campus, room]
        .where((s) => s.trim().isNotEmpty)
        .join(' ');
    return ExamEntry(
      name: row.value(const ['课程名称', '课程名']),
      time: row.value(const ['考试时间', '考试日期']),
      location: location,
      seat: row.value(const ['座位号', '座号']),
      examName: row.value(const ['考试场次', '考试名称', '考试性质']),
      teacher: row.value(const ['授课教师', '教师']),
    );
  }

  static void _requireExamPage(String html) {
    if (Html.isLoginPage(html)) {
      throw const AcademicException(
        AcademicStatus.SESSION_EXPIRED,
        '登录状态已失效，请重新登录',
      );
    }
    final document = Html.parse(html);
    final examTable = document.querySelectorAll('table').any((table) {
      final text = Html.textOf(table);
      return text.contains('课程') && text.contains('考试');
    });
    if (!examTable) {
      throw const AcademicException(
        AcademicStatus.PAGE_CHANGED,
        '响应里没有可识别的考试列表',
      );
    }
  }
}
