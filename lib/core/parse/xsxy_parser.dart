import '../model/academic_status.dart';
import '../model/qust_modules.dart';
import 'academic_json.dart';
import 'html.dart';
import 'study_json.dart';

/// 正方教务 `N105515` 学生学业情况查询与培养方案课程解析器。
class XsxyParser {
  const XsxyParser._();

  static final RegExp _gpaPattern = RegExp(
    r'(?:平均学分绩点|GPA)[^0-9]{0,120}?(\d+(?:\.\d+)?)',
    dotAll: true,
  );
  static final RegExp _totalCoursesPattern = RegExp(
    r'计划总课程(?:<!--[^>]*-->|\s|&nbsp;)*(\d+)',
  );
  static final RegExp _passedCoursesPattern = RegExp(
    r'计划总课程[\s\S]{0,200}?通过(?:<!--[^>]*-->|\s|&nbsp;)*(\d+)',
  );
  static final RegExp _failedCoursesPattern = RegExp(
    r'未通过(?:<!--[^>]*-->|\s|&nbsp;)*(\d+)',
  );
  static final RegExp _unstudiedCoursesPattern = RegExp(
    r'未修(?:<!--[^>]*-->|\s|&nbsp;)*(\d+)',
  );
  static final RegExp _inProgressCoursesPattern = RegExp(
    r'在读(?:<!--[^>]*-->|\s|&nbsp;)*(\d+)',
  );
  static final RegExp _outsidePassedPattern = RegExp(
    r'计划外[\s\S]{0,120}?通过(?:<!--[^>]*-->|\s|&nbsp;)*(\d+)',
  );

  /// 匹配正方 `xsxyqk` 内联 `<script>` 中动态拼接的 `<li id='li...'>` 节点。
  static final RegExp _scriptCategoryNode = RegExp(
    r"""<li\s+id=['"]li([^'"]+)['"][^>]*?fxfyqjd_id=['"]([^'"]*)['"][\s\S]{0,500}?xfyqjd_id=['"]([^'"]+)['"][\s\S]{0,220}?sfmjd=['"]([^'"]*)['"][\s\S]{0,220}?<p[^>]*?class=['"]title1['"][^>]*?yxxf=['"]([^'"]*)['"]\s*yqzdxf=['"]([^'"]*)['"]\s*sftg=['"]([^'"]*)['"][^>]*>\s*(?:"\s*\+\s*")?([^"<&]+)""",
  );

  static AcademicProgressReport parseProgressHtml(
    String html, [
    String baseUrl = '',
  ]) {
    if (Html.isLoginPage(html) || AcademicJson.looksLikeSessionExpired(html)) {
      throw const AcademicException(
        AcademicStatus.SESSION_EXPIRED,
        '登录状态已失效，请重新登录',
      );
    }
    final document = Html.parse(html, baseUrl);
    final hidden = Html.hiddenFieldsByIdOrName(document);
    final plainText = Html.textOf(document).replaceAll('\u00A0', ' ');

    final showGpaEl = document.querySelector('a[name=showGpa]');
    String gpa = '';
    if (showGpaEl != null && showGpaEl.parent != null) {
      final parentText = Html.textOf(showGpaEl.parent);
      gpa = _gpaPattern.firstMatch(parentText)?.group(1) ?? '';
    }
    if (gpa.isEmpty) {
      gpa = _gpaPattern.firstMatch(plainText)?.group(1) ?? '';
    }

    final total = _extractInt(_totalCoursesPattern, html) ??
        _extractInt(RegExp(r'计划总课程\s*(\d+)'), plainText) ??
        0;
    final passed = _extractInt(_passedCoursesPattern, html) ??
        _extractInt(RegExp(r'计划总课程\s*\d+\s*门\s*通过\s*(\d+)'), plainText) ??
        0;
    final failed = _extractInt(_failedCoursesPattern, html) ??
        _extractInt(RegExp(r'未通过\s*(\d+)'), plainText) ??
        0;
    final unstudied = _extractInt(_unstudiedCoursesPattern, html) ??
        _extractInt(RegExp(r'未修\s*(\d+)'), plainText) ??
        0;
    final inProgress = _extractInt(_inProgressCoursesPattern, html) ??
        _extractInt(RegExp(r'在读\s*(\d+)'), plainText) ??
        0;
    final outsidePassed = _extractInt(_outsidePassedPattern, html) ?? 0;

    final categories = _parseScriptCategories(html);
    if (gpa.isEmpty && total == 0 && categories.isEmpty) {
      throw const AcademicException(
        AcademicStatus.PAGE_CHANGED,
        '未能识别学业情况页面结构',
      );
    }

    return AcademicProgressReport(
      officialGpa: gpa,
      totalCourses: total,
      passedCourses: passed,
      failedCourses: failed,
      unstudiedCourses: unstudied,
      inProgressCourses: inProgress,
      outsidePlanPassedCourses: outsidePassed,
      studentId: (hidden['xh_id'] ?? hidden['sessionUserKey'] ?? '').trim(),
      cjlrxn: (hidden['cjlrxn'] ?? '').trim(),
      cjlrxq: (hidden['cjlrxq'] ?? '').trim(),
      hiddenParams: hidden,
      categories: categories,
    );
  }

  static List<CreditCategoryNode> _parseScriptCategories(String html) {
    final byId = <String, CreditCategoryNode>{};
    for (final match in _scriptCategoryNode.allMatches(html)) {
      final liId = (match.group(1) ?? '').trim();
      final parentId = (match.group(2) ?? '').trim();
      final nodeId = (match.group(3) ?? '').trim();
      final sfmjd = (match.group(4) ?? '').trim();
      final yxxfRaw = (match.group(5) ?? '').trim();
      final yqzdxfRaw = (match.group(6) ?? '').trim();
      final sftgRaw = (match.group(7) ?? '').trim();
      final rawName = (match.group(8) ?? '')
          .replaceAll('&nbsp;', '')
          .replaceAll('\u00A0', '')
          .trim();

      final id = nodeId.isNotEmpty ? nodeId : liId;
      if (id.isEmpty || rawName.isEmpty) continue;
      // 跳过无学分要求的占位节点（如 `qtkcxfyq` 其他课程、`cxcyqkxfyq` 创新创业空壳）
      if (yxxfRaw.isEmpty && yqzdxfRaw.isEmpty) continue;

      final earned = double.tryParse(yxxfRaw);
      final required = double.tryParse(yqzdxfRaw);
      double? remaining;
      if (earned != null && required != null) {
        final diff = required - earned;
        remaining = diff > 0 ? double.parse(diff.toStringAsFixed(2)) : 0.0;
      }

      byId.putIfAbsent(
        id,
        () => CreditCategoryNode(
          id: id,
          parentId: parentId,
          name: rawName,
          isLeaf: sfmjd == '1',
          earnedCredits: earned,
          requiredCredits: required,
          remainingCredits: remaining,
          passed: sftgRaw == '1' ||
              (earned != null && required != null && earned >= required),
        ),
      );
    }
    return byId.values.toList(growable: false);
  }

  static List<PlanCourseEntry> parsePlanCourses(String body) {
    final rows = AcademicJson.objects(body, const ['items', 'data', 'list']);
    final out = <PlanCourseEntry>[];
    for (final row in rows) {
      final name = AcademicJson.string(row, const ['KCMC', 'kcmc']).trim();
      if (name.isEmpty) continue;
      final code =
          AcademicJson.string(row, const ['KCH', 'KCH_ID', 'kch', 'kch_id'])
              .trim();
      final recYear =
          AcademicJson.string(row, const ['JYXDXNMC', 'JYXDXNM', 'XNMC', 'XNM'])
              .trim();
      final recSem = AcademicJson.string(
        row,
        const ['JYXDXQMC', 'JYXDXQM', 'XQMMC', 'XQM'],
      ).trim();
      final recommendedTerm = StudyJson.normalizeTermParts(recYear, recSem);

      out.add(
        PlanCourseEntry(
          courseCode: code,
          courseName: name,
          credits:
              AcademicJson.string(row, const ['XF', 'JHXF', 'xf']).trim(),
          category:
              AcademicJson.string(row, const ['KCXZMC', 'kcxzmc']).trim(),
          courseType:
              AcademicJson.string(row, const ['KCLBMC', 'kclbmc']).trim(),
          status: PlanCourseStatus.fromCode(
            AcademicJson.string(row, const ['XDZT', 'xdzt']),
          ),
          recommendedTerm: recommendedTerm,
          maxScore:
              AcademicJson.string(row, const ['MAXCJ', 'CJ', 'maxcj', 'cj'])
                  .trim(),
          score: AcademicJson.string(row, const ['CJ', 'cj']).trim(),
          makeupScore:
              AcademicJson.string(row, const ['MBKCJ', 'mbkcj']).trim(),
          retakeScore:
              AcademicJson.string(row, const ['MCXCJ', 'CXCJ1', 'mcxcj'])
                  .trim(),
          gpa: AcademicJson.string(row, const ['JD', 'jd']).trim(),
        ),
      );
    }
    return out;
  }

  static int? _extractInt(RegExp pattern, String text) {
    final raw = pattern.firstMatch(text)?.group(1);
    return raw == null ? null : int.tryParse(raw);
  }
}
