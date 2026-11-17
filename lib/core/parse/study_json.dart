import 'dart:convert';

import '../model/academic_status.dart';
import '../model/grades.dart';
import '../model/qust_modules.dart';
import '../model/schedule.dart';
import '../model/student_identity.dart';
import '../model/study.dart';
import '../schedule/ics_export.dart';
import 'academic_json.dart';
import 'grades_html.dart';
import 'html.dart';
import 'schedule_text.dart';

/// 教务 JSON 接口的课表、实践课、作息、成绩、成绩分项、考试、空教室与选课名单解析。
class StudyJson {
  const StudyJson._();

  static const List<(String, List<String>)> _componentScoreFields = [
    ('平时', ['pscj', 'PSCJ']),
    ('期中', ['qzcj', 'QZCJ']),
    ('期末', ['qmcj', 'QMCJ']),
    ('实验', ['sycj', 'SYCJ']),
    ('实践', ['sjcj', 'SJCJ']),
  ];

  static const List<String> _scoreRemarkFields = ['ksxz', 'ksfs', 'cjbs'];

  static const Map<String, String> _xqmCodeMap = {
    '3': '1',
    '1': '1',
    '12': '2',
    '2': '2',
    '16': '3',
    '32': '4',
  };

  static const Map<String, String> _semesterByLabel = {
    '3': '1',
    '1': '1',
    '第一学期': '1',
    '秋': '1',
    '秋季': '1',
    '12': '2',
    '2': '2',
    '第二学期': '2',
    '春': '2',
    '春季': '2',
    '16': '3',
    '第三学期': '3',
    '暑假': '3',
    '短学期': '3',
    '32': '4',
    '第四学期': '4',
    '寒假': '4',
  };

  static final RegExp _fourDigitYear = RegExp(r'(\d{4})');
  static final RegExp _examTimeRange = RegExp(
    r'(\d{4}-\d{2}-\d{2})\D*(\d{1,2}:\d{2})\s*[-~～至—]\s*(\d{1,2}:\d{2})',
  );
  static final RegExp _examDateOnly = RegExp(r'(\d{4}-\d{2}-\d{2})');
  static final RegExp _bracketCleanup = RegExp(r'[【】\[\]]');

  /// 解析完整课表响应（含排课 `kbList`、无固定节次条目与实践课 `sjkList`、以及 `xsxx` 学生信息）。
  static Schedule parseSchedule(String body) {
    if (AcademicJson.looksLikeSessionExpired(body) || Html.isLoginPage(body)) {
      throw const AcademicException(
        AcademicStatus.SESSION_EXPIRED,
        '登录状态已失效，请重新登录',
      );
    }

    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const AcademicException(
        AcademicStatus.PAGE_CHANGED,
        '响应不是可解析的 JSON',
      );
    }

    List<JsonMap> kbRows;
    List<JsonMap> sjkRows = const <JsonMap>[];
    StudentIdentity? studentInfo;
    var termId = '';

    if (decoded is Map) {
      if (_looksLikeErrorObject(decoded)) {
        final message = AcademicJson.message(body);
        throw AcademicException(
          AcademicJson.status(body, 200),
          message,
        );
      }
      kbRows = _mapListOf(decoded['kbList']) ??
          _mapListOf(decoded['data']) ??
          _mapListOf(decoded['items']) ??
          const <JsonMap>[];
      sjkRows = _mapListOf(decoded['sjkList']) ?? const <JsonMap>[];
      final xsxx = decoded['xsxx'];
      if (xsxx is Map) {
        final xsxxMap = _stringKeyedMap(xsxx);
        studentInfo = _studentIdentityFromXsxx(xsxxMap);
        termId = _termIdOf(xsxxMap);
      }
    } else if (decoded is List) {
      kbRows = _mapListOf(decoded) ?? const <JsonMap>[];
    } else {
      throw const AcademicException(
        AcademicStatus.PAGE_CHANGED,
        '课表响应结构无法识别',
      );
    }

    final entries = <ScheduleEntry>[];
    final practicalCourses = <PracticalCourse>[];

    for (final row in kbRows) {
      final parsed = _scheduleEntriesOrPractical(row);
      entries.addAll(parsed.$1);
      if (parsed.$2 != null) {
        practicalCourses.add(parsed.$2!);
      }
    }
    for (final row in sjkRows) {
      final practical = _practicalCourseOf(row);
      if (practical != null) {
        practicalCourses.add(practical);
      }
    }

    return Schedule(
      entries: entries,
      practicalCourses: practicalCourses,
      studentInfo: studentInfo,
      termId: termId,
    );
  }

  static List<ScheduleEntry> schedule(String body) =>
      parseSchedule(body).entries;

  static List<ScheduleEntry> scheduleRows(List<JsonMap> rows) =>
      rows.expand((row) => _scheduleEntriesOrPractical(row).$1).toList();

  static (List<ScheduleEntry>, PracticalCourse?) _scheduleEntriesOrPractical(
    JsonMap row,
  ) {
    final name = _plainText(row, const ['kcmc', 'KCMC']);
    if (name.isEmpty) return (const <ScheduleEntry>[], null);

    final day = int.tryParse(_plainText(row, const ['xqj', 'XQJ']));
    final periods = ScheduleText.parsePeriods(
      _plainText(row, const ['jcs', 'JCS', 'jcor', 'JCOR', 'jc']),
    );
    if (day == null || day < 1 || day > 7 || periods.isEmpty) {
      return (const <ScheduleEntry>[], _practicalCourseOf(row));
    }

    final teacher = _plainText(row, const ['xm', 'XM', 'jsxm']);
    final campus = _plainText(row, const ['xqmc', 'cdxqmc', 'xqhmc']);
    final room = _plainText(row, const ['cdmc', 'CDMC', 'jxcdmc']);
    final location = _joinParts([campus, room]);
    final weeks = _plainText(row, const ['zcd', 'ZCD', 'weeks', 'qsjsz']);
    final sourceId = _plainText(row, const [
      'schedule_source_id',
      'kcb_id',
      'kb_id',
      'jxb_id',
      'jx0404id',
      'kch_id',
    ]);
    final courseCode = _plainText(row, const ['kch_id', 'kch', 'KCH']);
    final teachingClass = _plainText(row, const ['jxbmc', 'JXBMC']);
    final credits = _plainText(row, const ['xf', 'XF']);
    final assessment = _plainText(row, const ['khfsmc', 'ksfsmc']);
    final courseCategory = _plainText(row, const ['kcxz', 'kcxzmc', 'kclb']);
    final retakeRaw = _plainText(row, const ['cxbj', 'CXBJ']);
    final isRetake = retakeRaw == '1' || retakeRaw == '是' || retakeRaw.contains('重修');
    final teachingFormSymbol = _plainText(row, const ['xslxbj']);

    final parsedWeeks =
        ScheduleText.parseWeeks(weeks) ?? WeekPattern(const <int>{}, weeks);

    final scheduled = periods
        .map(
          (span) => ScheduleEntry(
            name: name,
            teacher: teacher,
            location: location,
            day: day,
            period: span,
            weeks: parsedWeeks,
            sourceId: sourceId,
            courseCode: courseCode,
            teachingClass: teachingClass,
            credits: credits,
            assessment: assessment,
            courseCategory: courseCategory,
            campus: campus,
            isRetake: isRetake,
            teachingFormSymbol: teachingFormSymbol,
          ),
        )
        .toList();
    return (scheduled, null);
  }

  static PracticalCourse? _practicalCourseOf(JsonMap row) {
    final name = _plainText(row, const ['kcmc', 'KCMC']);
    if (name.isEmpty) return null;
    final retakeRaw = _plainText(row, const ['cxbj', 'CXBJ']);
    return PracticalCourse(
      name: name,
      teacher: _plainText(row, const ['jsxm', 'xm', 'XM']),
      credits: _plainText(row, const ['xf', 'XF']),
      weeksText: _plainText(row, const ['qsjsz', 'zcd', 'ZCD']),
      summary: _plainText(row, const ['sjkcgs', 'qtkcgs']),
      category: _plainText(row, const ['kclb', 'kcxz', 'kcxzmc']),
      assessment: _plainText(row, const ['khfsmc', 'ksfsmc']),
      campus: _plainText(row, const ['xqmc', 'cdxqmc', 'xqhmc']),
      isRetake:
          retakeRaw == '1' || retakeRaw == '是' || retakeRaw.contains('重修'),
      courseCode: _plainText(row, const ['kch_id', 'kch', 'KCH']),
      teachingClass: _plainText(row, const ['jxbmc', 'jxbzh', 'jxb_id']),
    );
  }

  static StudentIdentity? _studentIdentityFromXsxx(JsonMap xsxx) {
    final id = _plainText(xsxx, const ['XH', 'XH_ID', 'xh', 'xh_id']);
    final name = _plainText(xsxx, const ['XM', 'xm']);
    if (id.isEmpty && name.isEmpty) return null;
    final grade = _plainText(xsxx, const ['NJDM_ID', 'njdm_id']);
    return StudentIdentity(
      studentId: id,
      name: name,
      major: _plainText(xsxx, const ['ZYMC', 'zymc']),
      className: _plainText(xsxx, const ['BJMC', 'bjmc']),
      grade: grade,
    );
  }

  /// 解析校区节次作息接口（`kbcx/xskbcx_cxRjc.html`）返回的 [PeriodTime] 列表。
  static List<PeriodTime> bellSchedule(String body) {
    final rows = AcademicJson.objects(body, const ['items', 'data', 'list']);
    final byPeriod = <int, PeriodTime>{};
    for (final row in rows) {
      final rawPeriod = _plainText(row, const ['jcmc', 'jc', 'JCMC'])
          .replaceAll(RegExp(r'[^0-9]'), '');
      final period = int.tryParse(rawPeriod);
      if (period == null || period < 1 || period > PeriodSpan.maxPeriod) {
        continue;
      }
      final start = _normalizeClock(
        _plainText(row, const ['qssj', 'kssj', 'QSSJ', 'KSSJ']),
      );
      final end = _normalizeClock(_plainText(row, const ['jssj', 'JSSJ']));
      if (start == null || end == null) continue;
      byPeriod[period] = PeriodTime(period, start, end);
    }
    final sortedKeys = byPeriod.keys.toList()..sort();
    return [for (final k in sortedKeys) byPeriod[k]!];
  }

  static String? _normalizeClock(String raw) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(raw.trim());
    if (match == null) return null;
    final h = int.tryParse(match.group(1) ?? '');
    final m = int.tryParse(match.group(2) ?? '');
    if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
      return null;
    }
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  static List<GradeEntry> grades(String body) =>
      gradeRows(AcademicJson.objects(body, const ['items', 'data']));

  static List<GradeEntry> gradeRows(List<JsonMap> rows) {
    final out = <GradeEntry>[];
    for (final row in rows) {
      final e = _gradeEntryOf(row);
      if (e != null) out.add(e);
    }
    return out;
  }

  static GradeEntry? _gradeEntryOf(JsonMap row) {
    final name = _plainText(
      row,
      const ['kc_mc', 'kcmc', 'KCMC', 'courseName'],
    );
    if (name.isEmpty) return null;
    return GradeEntry(
      name: name,
      score: _plainText(row, const ['zcjstr', 'cj', 'zcj', 'CJ']),
      credits: _plainText(row, const ['xf', 'XF']),
      // 严禁把 xfjd（学分×绩点）当作 jd（课程绩点），并原样保留服务器返回的补考封顶 jd。
      gradePoint: _plainText(row, const ['jd', 'JD']),
      term: _termIdOf(row),
      detail: _scoreDetailOf(row),
      courseCode: _plainText(row, const ['kch', 'kch_id', 'KCH', 'KCH_ID']),
      jxbId: _plainText(row, const ['jxb_id', 'JXB_ID']),
      numericScore: _plainText(row, const ['bfzcj', 'BFZCJ']),
      category: _plainText(row, const ['kcxzmc', 'kclbmc', 'KCXZMC']),
      examNature: _plainText(row, const ['ksxz', 'KSXZ']),
      // 在新正方 cjcx_cxXsgrcj.html 中，xm 为学生本人姓名，严禁回退读取 xm！
      teacher: _cleanTeacherText(
        _plainText(row, const ['jsxm', 'JSXM', 'jsmc', 'jsxx', 'rkjsxm']),
      ),
      department: _plainText(row, const ['kkbmmc', 'jgmc', 'KKBMMC']),
    );
  }

  static String _scoreDetailOf(JsonMap row) {
    final parts = <String>[];
    for (final (label, names) in _componentScoreFields) {
      final v = _plainText(row, names);
      if (v.isNotEmpty) parts.add('$label: $v');
    }
    for (final field in _scoreRemarkFields) {
      final v = _plainText(row, [field]);
      if (v.isNotEmpty) parts.add(v);
    }
    return parts.join(' | ');
  }

  /// 解析单门课程成绩分项明细（兼容 `cjcx_cxXsXmcjList.html` JSON 与 `cjcx_cxCjxqGjh.html` `<table id="subtab">`）。
  static List<GradeSubItem> parseSubItems(String body) {
    final trimmed = body.trimLeft();
    if (trimmed.startsWith('<')) {
      return _parseSubItemsHtml(body);
    }
    final rows = AcademicJson.objects(body, const ['items', 'data', 'list']);
    final out = <GradeSubItem>[];
    for (final row in rows) {
      final item = _subItemOf(row);
      if (item != null) out.add(item);
    }
    return out;
  }

  static List<GradeSubItem> _parseSubItemsHtml(String html) {
    if (Html.isLoginPage(html)) {
      throw const AcademicException(
        AcademicStatus.SESSION_EXPIRED,
        '登录状态已失效，请重新登录',
      );
    }
    final doc = Html.parse(html);
    final table = doc.querySelector('table#subtab') ?? doc.querySelector('table');
    if (table == null) return const <GradeSubItem>[];

    final out = <GradeSubItem>[];
    for (final tr in table.querySelectorAll('tr')) {
      final tds = tr.querySelectorAll('td');
      if (tds.length < 3) continue;
      final rawName = Html.textOf(tds[0])
          .replaceAll('\u00A0', ' ')
          .replaceAll(_bracketCleanup, '')
          .trim();
      if (rawName.isEmpty || rawName.contains('成绩分项')) continue;
      final ratio = Html.textOf(tds[1]).replaceAll('\u00A0', ' ').trim();
      final score = Html.textOf(tds[2]).replaceAll('\u00A0', ' ').trim();
      if (score.isEmpty) continue;
      final label = ratio.isNotEmpty ? '$rawName($ratio)' : rawName;
      out.add(GradeSubItem(name: label, score: score));
    }
    return out;
  }

  /// 将批量成绩分项列表（`cjcx_cxXsKccjList.html`）按 `jxb_id`（回退 `(termId, courseCode)`）挂载到成绩条目。
  static List<GradeEntry> attachSubItems(
    List<GradeEntry> grades,
    List<JsonMap> subRows,
  ) {
    if (grades.isEmpty || subRows.isEmpty) return grades;

    final byJxbId = <String, List<GradeSubItem>>{};
    final byTermAndCode = <String, List<GradeSubItem>>{};

    for (final row in subRows) {
      final item = _subItemOf(row);
      if (item == null) continue;
      final jxbId = _plainText(row, const ['jxb_id', 'JXB_ID']);
      if (jxbId.isNotEmpty) {
        (byJxbId[jxbId] ??= <GradeSubItem>[]).add(item);
      }
      final termId = _termIdOf(row);
      final code = _plainText(row, const ['kch', 'kch_id', 'KCH', 'KCH_ID']);
      if (termId.isNotEmpty && code.isNotEmpty) {
        final key = '$termId|$code';
        (byTermAndCode[key] ??= <GradeSubItem>[]).add(item);
      }
    }

    return grades.map((entry) {
      List<GradeSubItem>? matched;
      if (entry.jxbId.isNotEmpty) {
        matched = byJxbId[entry.jxbId];
      }
      if (matched == null &&
          !entry.isMakeup &&
          entry.term.isNotEmpty &&
          entry.courseCode.isNotEmpty) {
        matched = byTermAndCode['${entry.term}|${entry.courseCode}'];
      }
      if (matched == null || matched.isEmpty) return entry;
      return entry.copyWith(subItems: List<GradeSubItem>.unmodifiable(matched));
    }).toList();
  }

  static GradeSubItem? _subItemOf(JsonMap row) {
    final name = _plainText(row, const ['xmblmc', 'xmc', 'XMBLMC']);
    final score = _plainText(row, const ['xmcj', 'cj', 'XMCJ']);
    if (name.isEmpty || score.isEmpty) return null;
    return GradeSubItem(name: name, score: score);
  }

  static List<ExamEntry> exams(String body) =>
      examRows(AcademicJson.objects(body, const ['items', 'data']));

  static List<ExamEntry> examRows(List<JsonMap> rows) {
    final out = <ExamEntry>[];
    for (final row in rows) {
      final e = _examEntryOf(row);
      if (e != null) out.add(e);
    }
    return out;
  }

  static ExamEntry? _examEntryOf(JsonMap row) {
    final name = _plainText(row, const ['kskcmc', 'kcmc', 'kc_mc']);
    if (name.isEmpty) return null;

    final timeText = _plainText(row, const ['kssj', 'ksrq', 'kssjms']);
    final campus = _firstValidExamField(row, const ['cdxqmc', 'ksxq', 'xqmc']);
    final room = _firstValidExamField(row, const ['js_mc', 'cdmc', 'ksdd']);
    final seat = _firstValidExamField(row, const ['zwh', 'zwh_mc']);
    // 在新正方 kscx_cxXsksxxIndex.html 中，xm 为学生本人姓名，教师在 jsxx/jsxm/rkjsxm 中！
    final rawTeacher = _plainText(
      row,
      const ['jsxm', 'jsxx', 'rkjsxm', 'jsmc'],
    );
    final (examDate, startTime, endTime) = _parseExamTimeWindow(timeText);

    return ExamEntry(
      name: name,
      time: timeText,
      location: _joinParts([campus, room]),
      seat: seat,
      examName: _plainText(row, const ['ksccmc', 'ksmc', 'ksxz']),
      teacher: _cleanTeacherText(rawTeacher),
      termId: _termIdOf(row),
      campus: campus,
      examMethod: _plainText(row, const ['ksfs', 'khfs']),
      credits: _plainText(row, const ['xf', 'XF']),
      courseCode: _plainText(row, const ['kch', 'kch_id', 'KCH']),
      examDate: examDate,
      startTime: startTime,
      endTime: endTime,
    );
  }

  static bool _isWithheldExamValue(String value) {
    final v = value.trim();
    return v.isEmpty ||
        v == 'null' ||
        v == '-' ||
        v == '未放开不可查' ||
        v == '不可查';
  }

  static String _firstValidExamField(JsonMap row, List<String> names) {
    for (final name in names) {
      final v = _plainText(row, [name]);
      if (!_isWithheldExamValue(v)) return v;
    }
    return '';
  }

  static (String, String, String) _parseExamTimeWindow(String text) {
    final match = _examTimeRange.firstMatch(text);
    if (match != null) {
      final date = match.group(1) ?? '';
      final start = _normalizeClock(match.group(2) ?? '') ?? '';
      final end = _normalizeClock(match.group(3) ?? '') ?? '';
      return (date, start, end);
    }
    final dateOnly = _examDateOnly.firstMatch(text)?.group(1) ?? '';
    return (dateOnly, '', '');
  }

  static String _cleanTeacherText(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || !trimmed.contains('/')) return trimmed;
    final names = <String>[];
    for (final token in trimmed.split(RegExp(r'[;,，；]'))) {
      final parts = token.trim().split('/');
      if (parts.length >= 2 && parts[1].trim().isNotEmpty) {
        names.add(parts[1].trim());
      } else if (token.trim().isNotEmpty) {
        names.add(token.trim());
      }
    }
    return names.join(',');
  }

  /// 解析空教室查询响应（`cdjy/cdjy_cxKxcdlb.html`）。
  static List<EmptyClassroom> emptyClassrooms(List<JsonMap> rows) {
    final out = <EmptyClassroom>[];
    for (final row in rows) {
      final name = _plainText(row, const ['cdmc', 'CDMC']);
      if (name.isEmpty) continue;
      out.add(
        EmptyClassroom(
          id: _plainText(row, const ['cd_id', 'cdbh', 'CD_ID']),
          code: _plainText(row, const ['cdbh', 'cd_id', 'CDBH']),
          name: name,
          building: _plainText(row, const ['jxlmc', 'lh', 'JXLMC']),
          type: _plainText(row, const ['cdlbmc', 'CDLBMC']),
          seats: int.tryParse(_plainText(row, const ['zws', 'sjzws', 'ZWS'])),
          examSeats: int.tryParse(_plainText(row, const ['kszws1', 'KSZWS1'])),
          campus: _plainText(row, const ['xqmc', 'XQMC']),
          department: _plainText(row, const ['sydxmc', 'jgmc', 'SYDXMC']),
        ),
      );
    }
    return out;
  }

  /// 解析学生选课名单查询响应（`xkcx/xkmdcx_cxXkmdcxIndex.html`，严格忽略 `zjhm`/`sjhm` 隐私字段）。
  static List<EnrolledCourseEntry> enrolledCourses(List<JsonMap> rows) {
    final out = <EnrolledCourseEntry>[];
    for (final row in rows) {
      final name = _plainText(row, const ['kcmc', 'KCMC']);
      if (name.isEmpty) continue;
      final cxbj = _plainText(row, const ['cxbj', 'CXBJ']);
      final cxbjmc = _plainText(row, const ['cxbjmc', 'CXBJMC']);
      out.add(
        EnrolledCourseEntry(
          courseCode: _plainText(row, const ['kch_id', 'kch', 'KCH_ID', 'KCH']),
          courseName: name,
          teachingClass: _plainText(row, const ['jxbmc', 'JXBMC']),
          jxbId: _plainText(row, const ['jxb_id', 'JXB_ID']),
          // 在新正方 xkmdcx_cxXkmdcxIndex.html 中，xm 为学生本人姓名，严禁回退读取 xm！
          teacher: _cleanTeacherText(
            _plainText(row, const ['jsmc', 'jsxm', 'JSMC', 'jsxx', 'rkjsxm']),
          ),
          credits: _plainText(row, const ['xf', 'XF']),
          scheduleText: _plainText(row, const ['sksj', 'SKSJ']),
          location: _plainText(row, const ['jxdd', 'cdmc', 'JXDD']),
          campus: _plainText(row, const ['xqhmc', 'cdxqmc', 'XQHMC']),
          category: _plainText(row, const ['kcxzmc', 'KCXZMC']),
          courseType:
              _plainText(row, const ['kklxmc', 'kclbmc', 'kclb', 'KKLXMC']),
          selectionStatus:
              _plainText(row, const ['xkbjmc', 'xxlxmc', 'XKBJMC']),
          weeksText: _plainText(row, const ['qsjsz', 'QSJSZ']),
          isRetake: cxbj == '1' || cxbj == '是' || cxbjmc == '是',
          termId: _termIdOf(row),
        ),
      );
    }
    return out;
  }

  static String _termIdOf(JsonMap row) {
    final direct = _plainText(
      row,
      const ['xnxqid', 'xnxq01id', 'xnxq', 'term'],
    );
    return GradesHtml.term(direct) ?? _encodedTermId(row);
  }

  /// 将学年文本（`2026` 或 `2026-2027`）与学期编码/名称（`3`/`12`/`16`/`32` 或 `1`/`2`/`暑假`/`寒假`）归一为 `YYYY-YYYY-P`。
  static String normalizeTermParts(String rawYear, String rawSem) {
    final yearMatch = _fourDigitYear.firstMatch(rawYear.trim());
    final year = int.tryParse(yearMatch?.group(1) ?? '');
    if (year == null) return '';
    final part = _semesterByLabel[rawSem.trim()];
    if (part == null) return '';
    return '$year-${year + 1}-$part';
  }

  static String _encodedTermId(JsonMap row) {
    final rawYear = _plainText(
      row,
      const ['xnm', 'xn', 'xnmc', 'xnmmc', 'XNM', 'XNMC'],
    );
    final yearMatch = _fourDigitYear.firstMatch(rawYear);
    final year = int.tryParse(yearMatch?.group(1) ?? '');
    if (year == null) return '';

    final xqmCode = _plainText(row, const ['xqm', 'XQM']);
    if (xqmCode.isNotEmpty) {
      final mapped = _xqmCodeMap[xqmCode];
      if (mapped != null) return '$year-${year + 1}-$mapped';
    }

    // 注意：在新正方中 xqmc 常表示「校区名称」（如“四方校区”），必须优先读取 xqmmc！
    final label = _plainText(row, const ['xqmmc', 'XQMMC', 'xq', 'xqmc']);
    final part = _semesterByLabel[label];
    if (part == null) return '';
    return '$year-${year + 1}-$part';
  }

  static bool _looksLikeErrorObject(Map<dynamic, dynamic> root) {
    for (final key in const ['kbList', 'sjkList', 'data', 'items']) {
      if (root[key] is List) return false;
    }
    final status = root['status']?.toString().toLowerCase();
    final flag = root['flag']?.toString();
    final code = root['code']?.toString();
    return status == 'error' ||
        status == 'fail' ||
        flag == '0' ||
        flag == '-1' ||
        (code != null && code != '0' && code != '200');
  }

  static List<JsonMap>? _mapListOf(Object? candidate) {
    if (candidate is! List) return null;
    final rows = <JsonMap>[];
    for (final element in candidate) {
      if (element is Map) {
        rows.add(_stringKeyedMap(element));
      }
    }
    return rows;
  }

  static JsonMap _stringKeyedMap(Map<dynamic, dynamic> raw) {
    final out = <String, Object?>{};
    raw.forEach((key, value) {
      if (key != null) out[key.toString()] = value;
    });
    return out;
  }

  static String _joinParts(List<String> parts) {
    final cleaned = <String>[];
    for (final raw in parts) {
      final s = raw.trim();
      if (s.isEmpty) continue;
      if (cleaned.isNotEmpty) {
        final prev = cleaned.last;
        if (s == prev || prev.endsWith(s)) continue;
        if (s.startsWith(prev)) {
          cleaned[cleaned.length - 1] = s;
          continue;
        }
      }
      cleaned.add(s);
    }
    return cleaned.join(' ');
  }

  static String _plainText(JsonMap row, List<String> names) {
    final raw = AcademicJson.string(row, names);
    return raw.contains('<') ? Html.textOf(Html.parse(raw)) : raw.trim();
  }
}
