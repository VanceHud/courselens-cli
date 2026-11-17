import 'package:html/dom.dart';

import '../model/term.dart';
import 'civil_date.dart';
import 'html.dart';

/// 新正方（`jwglxt`）`xtgl/index_initMenu.html` 上的服务端校历、当前周次与菜单入口。
class ZhengfangHomeMetadata {
  const ZhengfangHomeMetadata({
    this.studentId = '',
    this.schoolCode = '',
    this.xnm = '',
    this.xqm = '',
    this.currentTerm,
    this.currentWeek,
    this.serverDate = '',
    this.semesterStart,
    this.totalWeeks,
    this.menuPathsByGnmkdm = const <String, String>{},
  });

  final String studentId;
  final String schoolCode;
  final String xnm;
  final String xqm;
  final AcademicTerm? currentTerm;
  final int? currentWeek;
  final String serverDate;
  final SemesterStart? semesterStart;
  final int? totalWeeks;
  final Map<String, String> menuPathsByGnmkdm;

  bool get isEmpty =>
      studentId.isEmpty &&
      currentTerm == null &&
      currentWeek == null &&
      serverDate.isEmpty &&
      semesterStart == null &&
      menuPathsByGnmkdm.isEmpty;

  ZhengfangHomeMetadata merge(ZhengfangHomeMetadata fallback) {
    final mergedXnm = xnm.isNotEmpty ? xnm : fallback.xnm;
    final mergedXqm = xqm.isNotEmpty ? xqm : fallback.xqm;
    final mergedWeek = currentWeek ?? fallback.currentWeek;
    final mergedDate =
        serverDate.isNotEmpty ? serverDate : fallback.serverDate;
    final mergedMenus = <String, String>{
      ...fallback.menuPathsByGnmkdm,
      ...menuPathsByGnmkdm,
    };
    return ZhengfangHomeMetadata(
      studentId: studentId.isNotEmpty ? studentId : fallback.studentId,
      schoolCode: schoolCode.isNotEmpty ? schoolCode : fallback.schoolCode,
      xnm: mergedXnm,
      xqm: mergedXqm,
      currentTerm: currentTerm ??
          fallback.currentTerm ??
          ZhengfangHomeParser.termFromXnmXqm(mergedXnm, mergedXqm),
      currentWeek: mergedWeek,
      serverDate: mergedDate,
      semesterStart: semesterStart ??
          fallback.semesterStart ??
          ZhengfangHomeParser.deriveStartFromWeekAndDate(
            mergedWeek,
            mergedDate,
          ),
      totalWeeks: totalWeeks ?? fallback.totalWeeks,
      menuPathsByGnmkdm: Map.unmodifiable(mergedMenus),
    );
  }
}

/// 解析 `xtgl/index_initMenu.html` 及其异步区域片段（`AreaOne`/`AreaSix`/`AreaFive`）中的隐藏校历字段、`#xlyq` 学期区间与 `clickMenu` 路由。
class ZhengfangHomeParser {
  const ZhengfangHomeParser._();

  static const String initMenuPath = 'xtgl/index_initMenu.html?jsdm=xs';
  static const String areaOnePath =
      'xtgl/index_cxAreaOne.html?localeKey=zh_CN&gnmkdm=index';
  static const String areaSixPath =
      'xtgl/index_cxAreaSix.html?localeKey=zh_CN&gnmkdm=index';
  static const String areaFivePath =
      'xtgl/index_cxAreaFive.html?localeKey=zh_CN&gnmkdm=index';

  static final RegExp _calendarRange = RegExp(
    r'(\d{4})-(\d{2})-(\d{2})\s*(?:至|~|～|—|--?)\s*(\d{4})-(\d{2})-(\d{2})',
  );
  static final RegExp _isoDate = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$');
  static final RegExp _clickMenuCall = RegExp(
    r'''clickMenu\s*\(\s*['"]([^'"]+)['"]\s*,\s*['"]([^'"]+)['"]''',
  );

  static ZhengfangHomeMetadata parse(String html, [String baseUrl = '']) {
    if (Html.isLoginPage(html)) return const ZhengfangHomeMetadata();
    final document = Html.parse(html, baseUrl);
    final hidden = Html.hiddenFieldsByIdOrName(document);

    final studentId = _firstNonEmpty(hidden, const [
      'sessionUserKey',
      'xh_id',
      'xh',
      'studentId',
    ]);
    final schoolCode = _firstNonEmpty(hidden, const ['xxdm', 'hidxxdm']);
    final xnm = _firstNonEmpty(hidden, const ['xnm', 'cjlrxn']);
    final xqm = _firstNonEmpty(hidden, const ['xqm', 'cjlrxq']);
    final dqzcRaw = _firstNonEmpty(hidden, const ['dqzc']);
    final serverDate = _firstNonEmpty(hidden, const ['dqrq']);

    final currentWeek = int.tryParse(dqzcRaw);
    final currentTerm = termFromXnmXqm(xnm, xqm) ?? _termFromHeaderText(html);

    final (rangeStart, rangeWeeks) = _parseCalendarRange(document, html);
    final semesterStart =
        rangeStart ?? deriveStartFromWeekAndDate(currentWeek, serverDate);

    final menus = <String, String>{};
    for (final match in _clickMenuCall.allMatches(html)) {
      final code = (match.group(1) ?? '').trim();
      var path = (match.group(2) ?? '').trim();
      while (path.startsWith('/')) {
        path = path.substring(1);
      }
      if (code.isNotEmpty && path.isNotEmpty) {
        menus.putIfAbsent(code, () => path);
      }
    }

    return ZhengfangHomeMetadata(
      studentId: studentId,
      schoolCode: schoolCode,
      xnm: xnm,
      xqm: xqm,
      currentTerm: currentTerm,
      currentWeek:
          (currentWeek != null && currentWeek >= 1 && currentWeek <= 60)
              ? currentWeek
              : null,
      serverDate: serverDate,
      semesterStart: semesterStart,
      totalWeeks: rangeWeeks,
      menuPathsByGnmkdm: Map.unmodifiable(menus),
    );
  }

  static String _firstNonEmpty(Map<String, String> map, List<String> keys) {
    for (final key in keys) {
      final val = (map[key] ?? '').trim();
      if (val.isNotEmpty) return val;
    }
    return '';
  }

  static AcademicTerm? termFromXnmXqm(String xnm, String xqm) {
    final year = int.tryParse(
      xnm.length >= 4 ? xnm.substring(0, 4) : xnm,
    );
    if (year == null || year < 1990 || year > 2100) return null;
    final semester = switch (xqm.trim()) {
      '3' || '1' => 1,
      '12' || '2' => 2,
      '16' => 3,
      '32' => 4,
      _ => null,
    };
    if (semester == null) return null;
    return AcademicTerm('$year-${year + 1}-$semester');
  }

  static AcademicTerm? _termFromHeaderText(String html) {
    final m = RegExp(r'(\d{4})-(\d{4})学年\s*第?\s*([1-4])\s*学期').firstMatch(html);
    if (m == null) return null;
    return AcademicTerm('${m.group(1)}-${m.group(2)}-${m.group(3)}');
  }

  static (SemesterStart?, int?) _parseCalendarRange(
    Document document,
    String html,
  ) {
    final xlyqNode = document.getElementById('xlyq');
    final candidateText =
        xlyqNode != null ? Html.textOf(xlyqNode) : html;
    final match = _calendarRange.firstMatch(candidateText) ??
        _calendarRange.firstMatch(html);
    if (match == null) return (null, null);

    final y1 = int.tryParse(match.group(1) ?? '');
    final m1 = int.tryParse(match.group(2) ?? '');
    final d1 = int.tryParse(match.group(3) ?? '');
    final y2 = int.tryParse(match.group(4) ?? '');
    final m2 = int.tryParse(match.group(5) ?? '');
    final d2 = int.tryParse(match.group(6) ?? '');
    if (y1 == null ||
        m1 == null ||
        d1 == null ||
        y2 == null ||
        m2 == null ||
        d2 == null) {
      return (null, null);
    }
    try {
      final start = SemesterStart(y1, m1, d1);
      final startDays = CivilDate.daysFromCivil(y1, m1, d1);
      final endDays = CivilDate.daysFromCivil(y2, m2, d2);
      final spanDays = endDays - startDays + 1;
      final weeks = (spanDays >= 7 && spanDays <= 420)
          ? ((spanDays + 6) ~/ 7)
          : null;
      return (start, weeks);
    } on ArgumentError {
      return (null, null);
    }
  }

  static SemesterStart? deriveStartFromWeekAndDate(
    int? currentWeek,
    String serverDate,
  ) {
    if (currentWeek == null || currentWeek < 1 || currentWeek > 60) {
      return null;
    }
    final m = _isoDate.firstMatch(serverDate.trim());
    if (m == null) return null;
    final year = int.tryParse(m.group(1) ?? '');
    final month = int.tryParse(m.group(2) ?? '');
    final day = int.tryParse(m.group(3) ?? '');
    if (year == null || month == null || day == null) return null;
    final todayDays = CivilDate.daysFromCivil(year, month, day);
    // 1970-01-01 (days=0) was Thursday (ISO weekday 4 -> Monday=1..Sunday=7).
    final isoWeekday = ((todayDays + 3) % 7 + 7) % 7 + 1;
    final mondayWeek1Days =
        todayDays - ((currentWeek - 1) * 7 + (isoWeekday - 1));
    final (sy, sm, sd) = CivilDate.civilFromDays(mondayWeek1Days);
    try {
      return SemesterStart(sy, sm, sd);
    } on ArgumentError {
      return null;
    }
  }
}
