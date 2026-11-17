import 'package:html/dom.dart';

import '../model/student_identity.dart';
import 'html.dart';

/// 正方教务页面上的学号、姓名与院系班级识别（覆盖标准形态、`zftal-ui-v5` 用户卡片、`#sessionUserKey` 回退）。
class ZhengfangIdentity {
  const ZhengfangIdentity._();

  static final RegExp _headingWithId = RegExp(
    r'^(.+?)(?:-|\[)([A-Za-z0-9]{6,})\]?$',
  );
  static final RegExp _whitespaceRun = RegExp(r'\s+');
  static const List<String> _trailingRoleLabels = ['同学', '学生', '教师', '老师'];
  static const String _nbsp = '\u00A0';

  static StudentIdentity parse(String html, [String baseUrl = '']) {
    if (Html.isLoginPage(html)) return const StudentIdentity();
    final document = Html.parse(html, baseUrl);

    final labelled = _readLabelledProfile(document);
    final (mediaDept, mediaClass) = _readMediaDepartmentAndClass(document);
    final department = (labelled['学院名称'] ?? labelled['学院'] ?? mediaDept).trim();
    final major = (labelled['专业名称'] ?? labelled['专业'] ?? '').trim();
    final className =
        (labelled['班级名称'] ?? labelled['行政班'] ?? labelled['班级'] ?? mediaClass)
            .trim();
    final rawGrade = (labelled['年级'] ??
            Html.attr(
              document.querySelector('#njdm_id, input[name=njdm_id]') ??
                  Element.tag('span'),
              'value',
            ))
        .trim();

    final fromHeading = _headingIdentity(document);
    final name = fromHeading != null
        ? fromHeading.name
        : _readName(document, labelled).trim();
    final studentId = fromHeading != null
        ? fromHeading.studentId
        : _readStudentId(document, labelled).trim();

    if (name.isEmpty && studentId.isEmpty) {
      return const StudentIdentity();
    }

    final provisional = StudentIdentity(
      name: name,
      studentId: studentId,
      department: department,
      major: major,
      className: className,
      grade: rawGrade,
    );
    if (provisional.grade.isNotEmpty) return provisional;
    final inferred = provisional.inferredEnrollmentYear();
    return inferred != null
        ? provisional.copyWith(grade: inferred.toString())
        : provisional;
  }

  static StudentIdentity? _headingIdentity(Document document) {
    for (final element in document
        .querySelectorAll('.infoContentTitle, .userInfo, .user-info')) {
      final text = Html.textOf(element);
      final match = _headingWithId.firstMatch(text);
      if (match != null) {
        return StudentIdentity(
          name: (match.group(1) ?? '').trim(),
          studentId: match.group(2) ?? '',
        );
      }
    }
    return null;
  }

  static (String, String) _readMediaDepartmentAndClass(Document document) {
    final paragraph = document.querySelector('.media-body p');
    if (paragraph == null) return ('', '');
    final raw = Html.textOf(paragraph)
        .replaceAll(_nbsp, ' ')
        .replaceAll(_whitespaceRun, ' ')
        .trim();
    if (raw.isEmpty) return ('', '');
    final parts = raw.split(' ').where((s) => s.isNotEmpty).toList();
    if (parts.length >= 2) {
      return (parts.first, parts.sublist(1).join(' '));
    }
    return (raw, '');
  }

  static Map<String, String> _readLabelledProfile(Document document) {
    final map = <String, String>{};
    for (final label
        in document.querySelectorAll('.middletopdwxxtit, label.col-sm-4')) {
      var field = Html.textOf(label).replaceAll(' ', '');
      while (field.endsWith(':') || field.endsWith('：')) {
        field = field.substring(0, field.length - 1);
      }
      final next = Html.nextElementSibling(label);
      final content = (next != null &&
              (next.classes.contains('middletopdwxxcont') ||
                  next.classes.contains('col-sm-8')))
          ? Html.textOf(next)
          : '';
      if (field.isNotEmpty && content.isNotEmpty) {
        map[field] = content;
      }
    }
    return map;
  }

  static String _readName(Document document, Map<String, String> labelled) {
    final element = document.querySelector(
      'input[name=xm], .media-heading, [name=studentName], #xhxm, .user-name, #studentName',
    );
    var name = '';
    if (element != null) {
      final attrVal = Html.attr(element, 'value');
      final raw = attrVal.trim().isNotEmpty ? attrVal : Html.textOf(element);
      name = _normalizeName(raw, dropRoleLabel: element.localName != 'input');
    }
    if (name.trim().isEmpty) {
      name = labelled['学生姓名'] ?? labelled['姓名'] ?? '';
    }
    return name;
  }

  static String _readStudentId(
    Document document,
    Map<String, String> labelled,
  ) {
    final element = document.querySelector(
      'input[name=xh], input[name=xh_id], input[name=studentId], #studentId, #sessionUserKey, #xh_id',
    );
    var id = '';
    if (element != null) {
      final attrVal = Html.attr(element, 'value');
      id = (attrVal.trim().isNotEmpty ? attrVal : Html.textOf(element)).trim();
    }
    if (id.trim().isEmpty) {
      // 从头像链接 `?xh_id=2400000000` 回退提取学号（`index_cxYhxxIndex.html`）。
      final img = document.querySelector('img[src*="xh_id="]');
      if (img != null) {
        final src = Html.attr(img, 'src');
        id = RegExp(r'[?&]xh_id=([A-Za-z0-9_-]+)').firstMatch(src)?.group(1) ??
            '';
      }
    }
    if (id.trim().isEmpty) {
      id = labelled['学号'] ?? '';
    }
    return id;
  }

  static String _normalizeName(String raw, {required bool dropRoleLabel}) {
    var collapsed =
        raw.replaceAll(_nbsp, ' ').replaceAll(_whitespaceRun, ' ').trim();
    if (!dropRoleLabel) return collapsed;
    for (final label in _trailingRoleLabels) {
      if (collapsed.endsWith(label)) {
        collapsed = collapsed.substring(0, collapsed.length - label.length);
      }
    }
    return collapsed.trim();
  }
}
