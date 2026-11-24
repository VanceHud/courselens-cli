import '../model/academic_status.dart';
import '../model/qust_modules.dart';
import '../model/study.dart';
import 'html.dart';
import 'table_rows.dart';

/// 考试安排与空教室筛选元数据 HTML 解析。
class StudyHtml {
  const StudyHtml._();

  static List<ExamEntry> exams(String html, String baseUrl) {
    _requireExamPage(html);
    return TableRows.rows(html, baseUrl).map(_examEntryOf).toList();
  }

  /// 从新正方空教室入口页（`cdjy/cdjy_cxKxcdlb.html`）动态解析本校校区与场地类别下拉选项。
  static EmptyClassroomFilterOptions emptyClassroomFilters(String html) {
    if (html.trim().isEmpty || Html.isLoginPage(html)) {
      return EmptyClassroomFilterOptions();
    }
    final document = Html.parse(html);

    bool isPlaceholderLabel(String label) {
      final clean = label.replaceAll(RegExp(r'\s+'), '').toLowerCase();
      return clean.isEmpty ||
          clean.contains('请选择') ||
          clean == '--' ||
          clean == '---' ||
          clean == '---请选择---';
    }

    final campuses = <CampusOption>[];
    final seenCampusIds = <String>{};
    final campusSelect = document.querySelector('select#xqh_id') ??
        document.querySelector('select[name="xqh_id"]') ??
        document.querySelector('select#xq_id') ??
        document.querySelector('select[name="xq_id"]');
    if (campusSelect != null) {
      for (final opt in campusSelect.querySelectorAll('option')) {
        final id = (opt.attributes['value'] ?? '').trim();
        final label = Html.textOf(opt).trim();
        if (id.isEmpty || isPlaceholderLabel(label)) continue;
        if (seenCampusIds.add(id)) {
          campuses.add(CampusOption(id: id, name: label));
        }
      }
    }

    final roomTypes = <RoomTypeOption>[];
    final seenRoomIds = <String>{};
    final roomSelect = document.querySelector('select#cdlb_id') ??
        document.querySelector('select[name="cdlb_id"]') ??
        document.querySelector('select#cdjylx') ??
        document.querySelector('select[name="cdjylx"]');
    if (roomSelect != null) {
      for (final opt in roomSelect.querySelectorAll('option')) {
        final id = (opt.attributes['value'] ?? '').trim();
        final label = Html.textOf(opt).trim();
        if (id.isEmpty || isPlaceholderLabel(label)) continue;
        if (seenRoomIds.add(id)) {
          roomTypes.add(RoomTypeOption(id: id, name: label));
        }
      }
    }
    if (roomTypes.isNotEmpty) {
      roomTypes.insert(0, const RoomTypeOption(id: '', name: '全部类型'));
    }

    return EmptyClassroomFilterOptions(
      campuses: campuses,
      roomTypes: roomTypes,
    );
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
