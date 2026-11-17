import 'dart:convert';

import 'package:html/dom.dart';

import '../model/academic_status.dart';
import '../model/academic_system.dart';
import '../model/grades.dart';
import '../model/qust_modules.dart';
import '../model/schedule.dart';
import '../model/student_identity.dart';
import '../model/study.dart';
import '../model/term.dart';
import '../parse/academic_json.dart';
import '../parse/civil_date.dart';
import '../parse/grade_math.dart';
import '../parse/grades_html.dart';
import '../parse/html.dart';
import '../parse/schedule_html.dart';
import '../parse/study_html.dart';
import '../parse/study_json.dart';
import '../parse/urls.dart';
import '../parse/xsxy_parser.dart';
import '../parse/zhengfang_home.dart';
import '../schedule/ics_export.dart';
import '../schedule/period_schedule_builder.dart';
import 'study_transport.dart';

enum _Lookup {
  timetable('课表', 'xskb/xskb_list.do', 'xskbcx.aspx'),
  scores('成绩', 'kscj/cjcx_frm', 'xscjcx.aspx'),
  examList('考试', 'xsks/xsksap_query', 'xskscx.aspx');

  const _Lookup(this.label, this.modernPath, this.legacyPath);

  final String label;
  final String modernPath;
  final String legacyPath;

  Set<String> submitLabels({required bool wholeHistory}) {
    if (this != _Lookup.scores) {
      return const {'查询', '考试查询', '确定'};
    }
    if (wholeHistory) {
      return const {'历年成绩', '在校学习成绩查询', '查询历年成绩'};
    }
    return const {'按学期查询', '学期成绩', '查询', '成绩查询'};
  }
}

/// 教务只读数据总编排（新正方 `zf`、旧正方 `zf_old`、新强智 `qz`、旧强智 `qz_old`）。
class StudyReader {
  StudyReader({
    required StudyTransport transport,
    required AcademicSystem system,
    String username = '',
    String schedulePath = '',
    String gradesPath = '',
    String scheduleGnmkdm = defaultScheduleGnmkdm,
    String gradeGnmkdm = defaultGradeGnmkdm,
    required int Function() nowEpochSeconds,
  })  : _transport = transport,
        _system = system,
        _username = username,
        _schedulePath = schedulePath,
        _gradesPath = gradesPath,
        _scheduleGnmkdm = scheduleGnmkdm,
        _gradeGnmkdm = gradeGnmkdm,
        _nowEpochSeconds = nowEpochSeconds;

  static const String defaultScheduleGnmkdm = 'N253508';
  static const String personalScheduleGnmkdm = 'N2151';
  static const String defaultGradeGnmkdm = 'N305005';
  static const String subScoreGnmkdm = 'N305007';

  static const int _rowsPerPage = 200;
  static const int _subScoreRowsPerPage = 300;
  static const int _pageLimit = 100;
  static const int _semesterAggregateLimit = 100;
  static const int _frameDepthLimit = 3;

  static const String _zfInitMenuPath = 'xtgl/index_initMenu.html?jsdm=xs';
  static const String _primaryPersonalTimetablePath =
      'kbcx/xskbcx_cxXsgrkb.html';
  static const String _fallbackTimetablePath = 'kbcx/xskbcx_cxXsKb.html';
  static const String _zfBellSchedulePath = 'kbcx/xskbcx_cxRjc.html';
  static const String _primaryPersonalScorePath = 'cjcx/cjcx_cxXsgrcj.html';
  static const String _fallbackScorePath = 'cjcx/cjcx_cxDgXscj.html';
  static const String _bulkSubScorePath = 'cjcx/cjcx_cxXsKccjList.html';
  static const String _courseSubScorePath = 'cjcx/cjcx_cxXsXmcjList.html';
  static const String _courseSubScoreModalPath = 'cjcx/cjcx_cxCjxqGjh.html';
  static const String _modernScoreListPath = 'kscj/cjcx_list';
  static const String _modernScoreListPathFull = '/kscj/cjcx_list';
  static const String _qzExamListPath = 'xsks/xsksap_list';
  static const String _zfExamQueryPath =
      'kwgl/kscx_cxXsksxxIndex.html?doType=query&gnmkdm=N358105';
  static const String _zfAcademicProgressIndexPath =
      'xsxy/xsxyqk_cxXsxyqkIndex.html?ver=new&gnmkdm=N105515&layout=default';
  static const String _zfAcademicProgressCoursesPath =
      'xsxy/xsxyqk_cxJxzxjhxfyqKcxx.html?gnmkdm=N105515';
  static const String _zfEmptyClassroomQueryPath =
      'cdjy/cdjy_cxKxcdlb.html?doType=query&gnmkdm=N2155';
  static const String _zfEnrolledCoursesQueryPath =
      'xkcx/xkmdcx_cxXkmdcxIndex.html?doType=query&gnmkdm=N255010';
  static const String _timetableFrameMarker = 'xskb_list.do';
  static const String _legacyScoreFormMarker = '/kscj/cjcx_query';

  static const String _eventTargetField = '__EVENTTARGET';
  static const String _eventArgumentField = '__EVENTARGUMENT';

  static const int _autumnSemester = 1;
  static const int _springSemester = 2;
  static const int _summerSemester = 3;
  static const int _winterSemester = 4;

  final StudyTransport _transport;
  final AcademicSystem _system;
  final String _username;
  final String _schedulePath;
  final String _gradesPath;
  final String _scheduleGnmkdm;
  final String _gradeGnmkdm;
  final int Function() _nowEpochSeconds;

  FetchedPage? _cachedHome;

  String get _effectiveStudentId {
    if (_username.trim().isNotEmpty) return _username.trim();
    if (_transport.session.username.trim().isNotEmpty) {
      return _transport.session.username.trim();
    }
    return _transport.session.zfHomeMetadata?.studentId ?? '';
  }

  AcademicTerm _defaultTerm() {
    if (_system == AcademicSystem.ZF) {
      final homeTerm = _transport.session.zfHomeMetadata?.currentTerm;
      if (homeTerm != null) {
        return homeTerm;
      }
    }
    return calendarTerm(_nowEpochSeconds());
  }

  Future<bool> validate() async {
    final probeUrl = switch (_system) {
      AcademicSystem.ZF => _transport.resolveUrl(
          'xtgl/index_cxYhxxIndex.html?xt=jw&localeKey=zh_CN&gnmkdm=index',
        ),
      AcademicSystem.ZF_OLD => _transport.withQuery(
          _transport.resolveUrl('xs_main.aspx'),
          {'xh': _username},
        ),
      AcademicSystem.QZ =>
        _transport.resolveUrl('framework/xsMainV_new.htmlx?t1=1'),
      _ => _transport.resolveUrl('framework/xsMain.jsp'),
    };
    final FetchedPage landing;
    try {
      landing = await _transport.fetch(probeUrl);
    } on AcademicException {
      return false;
    }
    if (landing.status < 200 || landing.status > 299) return false;
    return !Html.isLoginPage(landing.body) &&
        !AcademicJson.looksLikeSessionExpired(landing.body);
  }

  Future<StudyCatalog> catalog() async {
    if (_system == AcademicSystem.ZF) {
      return _zfCatalog();
    }
    final FetchedPage source = switch (_system) {
      AcademicSystem.ZF_OLD => await _lookupPage(_Lookup.timetable),
      _ => await _qzTimetablePage(),
    };
    final listed = GradesHtml.terms(source.body)
        .map(AcademicTerm.new)
        .toList(growable: false);
    final selected = GradesHtml.selectedTerm(source.body);
    final active = selected != null
        ? AcademicTerm(selected)
        : calendarTerm(_nowEpochSeconds());
    return StudyCatalog(
      terms: _orderTerms([...listed, active]),
      currentTerm: active,
    );
  }

  Future<StudyCatalog> _zfCatalog() async {
    var homeMeta =
        _transport.session.zfHomeMetadata ?? const ZhengfangHomeMetadata();
    if (homeMeta.isEmpty) {
      try {
        final menuPage = _verify(
          await _transport.fetch(_transport.resolveUrl(_zfInitMenuPath)),
        );
        final parsed = ZhengfangHomeParser.parse(menuPage.body);
        if (!parsed.isEmpty) {
          homeMeta = parsed.merge(homeMeta);
        }
      } on AcademicException catch (e) {
        if (e.status == AcademicStatus.SESSION_EXPIRED) rethrow;
      }
    }

    if (homeMeta.currentTerm == null || homeMeta.currentWeek == null) {
      final areaOne = await _fetchOptionalZfHomeArea(
        ZhengfangHomeParser.areaOnePath,
      );
      if (areaOne != null) {
        homeMeta = areaOne.merge(homeMeta);
      }
    }

    if (homeMeta.semesterStart == null || homeMeta.serverDate.isEmpty) {
      final areaSix = await _fetchOptionalZfHomeArea(
        ZhengfangHomeParser.areaSixPath,
      );
      if (areaSix != null) {
        homeMeta = areaSix.merge(homeMeta);
      }
      if (homeMeta.semesterStart == null) {
        final areaFive = await _fetchOptionalZfHomeArea(
          ZhengfangHomeParser.areaFivePath,
        );
        if (areaFive != null) {
          homeMeta = areaFive.merge(homeMeta);
        }
      }
    }

    if (!homeMeta.isEmpty) {
      _transport.session.zfHomeMetadata = homeMeta;
    }

    AcademicTerm active;
    final htmlListed = <AcademicTerm>[];
    if (homeMeta.currentTerm != null) {
      active = homeMeta.currentTerm!;
    } else {
      FetchedPage? legacyPage;
      try {
        legacyPage = _verify(await _transport.fetch(_fallbackTimetableUrl()));
      } on AcademicException catch (e) {
        if (e.status == AcademicStatus.SESSION_EXPIRED) rethrow;
      }
      if (legacyPage != null) {
        final selected = GradesHtml.selectedTerm(legacyPage.body);
        active = selected != null
            ? AcademicTerm(selected)
            : calendarTerm(_nowEpochSeconds());
        htmlListed.addAll(
          GradesHtml.terms(legacyPage.body).map(AcademicTerm.new),
        );
      } else {
        active = calendarTerm(_nowEpochSeconds());
      }
    }

    final enrollmentYear = _inferEnrollmentYear(active.year);
    final bounded = _generateCohortTerms(enrollmentYear, active);
    final filteredHtml = htmlListed.where(
      (t) =>
          t.year >= enrollmentYear &&
          (t.year < active.year ||
              (t.year == active.year && t.semester <= active.semester)),
    );

    return StudyCatalog(
      terms: _orderTerms([...bounded, ...filteredHtml, active]),
      currentTerm: active,
      currentWeek: homeMeta.currentWeek,
      serverDate: homeMeta.serverDate,
      semesterStart: homeMeta.semesterStart,
      totalWeeks: homeMeta.totalWeeks,
    );
  }

  Future<ZhengfangHomeMetadata?> _fetchOptionalZfHomeArea(
    String relativePath,
  ) async {
    try {
      final page = _verify(
        await _transport.submitForm(
          _transport.resolveUrl(relativePath),
          const <(String, String)>[],
          referer: _transport.resolveUrl(_zfInitMenuPath),
          ajax: true,
        ),
      );
      if (page.status < 200 || page.status > 299) return null;
      final parsed = ZhengfangHomeParser.parse(page.body);
      return parsed.isEmpty ? null : parsed;
    } on AcademicException catch (e) {
      if (e.status == AcademicStatus.SESSION_EXPIRED) rethrow;
      return null;
    }
  }

  int _inferEnrollmentYear(int activeYear) {
    final id = _effectiveStudentId;
    final fromStudentId =
        StudentIdentity(studentId: id).inferredEnrollmentYear(
      maxYear: activeYear,
    );
    if (fromStudentId != null) return fromStudentId;
    return activeYear - 4;
  }

  static List<AcademicTerm> _generateCohortTerms(
    int enrollmentYear,
    AcademicTerm active,
  ) {
    final startYear =
        enrollmentYear <= active.year ? enrollmentYear : active.year;
    final out = <AcademicTerm>[];
    for (var year = startYear; year <= active.year; year++) {
      out.add(AcademicTerm('$year-${year + 1}-1'));
      if (year < active.year || active.semester >= 2) {
        out.add(AcademicTerm('$year-${year + 1}-2'));
      }
      if (year == active.year && active.semester >= 3) {
        out.add(AcademicTerm('$year-${year + 1}-${active.semester}'));
      }
    }
    return out;
  }

  /// 读取完整课表模型（包含 `entries` 与新正方 `sjkList` 实践/无固定节次课程 `practicalCourses`）。
  Future<Schedule> scheduleBundle(AcademicTerm? term) async {
    final target = term ?? _defaultTerm();
    return switch (_system) {
      AcademicSystem.ZF => _zfTimetableBundle(target),
      AcademicSystem.ZF_OLD => Schedule(
          entries: ScheduleHtml.parse(
            (await _webFormsQuery(_Lookup.timetable, target)).body,
            '',
          ),
          termId: target.id,
        ),
      _ => Schedule(
          entries: await _qzTimetable(target),
          termId: target.id,
        ),
    };
  }

  Future<List<ScheduleEntry>> schedule(AcademicTerm? term) async {
    final target = term ?? _defaultTerm();
    return switch (_system) {
      AcademicSystem.ZF => (await _zfTimetableBundle(target)).entries,
      AcademicSystem.ZF_OLD => ScheduleHtml.parse(
          (await _webFormsQuery(_Lookup.timetable, target)).body,
          '',
        ),
      _ => _qzTimetable(target),
    };
  }

  Future<Schedule> _zfTimetableBundle(AcademicTerm term) async {
    if (_schedulePath.trim().isNotEmpty) {
      final fields = _zfTermFields(term)
          .entries
          .map((e) => (e.key, e.value))
          .toList(growable: false);
      final answer = _verify(
        await _transport.submitForm(
          _customTimetableUrl(_schedulePath),
          fields,
          ajax: true,
        ),
      );
      final parsed = StudyJson.parseSchedule(answer.body);
      return parsed.termId.isEmpty
          ? Schedule(
              entries: parsed.entries,
              practicalCourses: parsed.practicalCourses,
              studentInfo: parsed.studentInfo,
              termId: term.id,
            )
          : parsed;
    }

    final personalFields = <String, String>{
      ..._zfTermFields(term),
      'kzlx': 'ck',
      'xsdm': '',
    };
    try {
      final answer = _verify(
        await _transport.submitForm(
          _zfUrlWithParams(
            _primaryPersonalTimetablePath,
            {'gnmkdm': personalScheduleGnmkdm},
          ),
          personalFields.entries.map((e) => (e.key, e.value)),
          ajax: true,
        ),
      );
      final parsed = StudyJson.parseSchedule(answer.body);
      return parsed.termId.isEmpty
          ? Schedule(
              entries: parsed.entries,
              practicalCourses: parsed.practicalCourses,
              studentInfo: parsed.studentInfo,
              termId: term.id,
            )
          : parsed;
    } on AcademicException catch (e) {
      if (e.status == AcademicStatus.SESSION_EXPIRED) rethrow;
    }

    final fallbackFields = _zfTermFields(term)
        .entries
        .map((e) => (e.key, e.value))
        .toList(growable: false);
    final fallbackAnswer = _verify(
      await _transport.submitForm(
        _fallbackTimetableUrl(),
        fallbackFields,
        ajax: true,
      ),
    );
    final parsed = StudyJson.parseSchedule(fallbackAnswer.body);
    return parsed.termId.isEmpty
        ? Schedule(
            entries: parsed.entries,
            practicalCourses: parsed.practicalCourses,
            studentInfo: parsed.studentInfo,
            termId: term.id,
          )
        : parsed;
  }

  /// 查询校区作息时间表（新正方 `POST kbcx/xskbcx_cxRjc.html?gnmkdm=N2151`）。
  Future<List<PeriodTime>> campusBellSchedule({
    AcademicTerm? term,
    String campusId = '1',
  }) async {
    if (_system != AcademicSystem.ZF) {
      return IcsExport.defaultPeriodTimes;
    }
    final target = term ?? _defaultTerm();
    final params = <String, String>{
      ..._zfTermFields(target),
      'xqh_id': campusId.trim().isEmpty ? '1' : campusId.trim(),
    };
    final answer = _verify(
      await _transport.submitForm(
        _zfUrlWithParams(
          _zfBellSchedulePath,
          {'gnmkdm': personalScheduleGnmkdm},
        ),
        params.entries.map((e) => (e.key, e.value)),
        ajax: true,
      ),
    );
    final parsed = StudyJson.bellSchedule(answer.body);
    if (parsed.isNotEmpty) return parsed;
    return campusId.trim() == '3'
        ? PeriodScheduleBuilder.qustGaomiPreset()
        : PeriodScheduleBuilder.qustSifangLaoshanPreset();
  }

  Future<List<ScheduleEntry>> _qzTimetable(AcademicTerm term) async {
    final entry = await _qzTimetablePage();
    final submitted = _pageFormFields(entry)
        ..['xnxq01id'] = term.id
        ..['zc'] = '';
    final formElement =
        Html.parse(entry.body, entry.address).querySelector('form');
    final target = formElement != null
        ? Html.action(formElement, entry.address)
        : entry.address;
    _assertStudyEndpoint(target, _Lookup.timetable);
    final answer = _verify(
      await _submitAsDeclared(formElement, target, submitted, entry.address),
    );
    final echoed = GradesHtml.selectedTerm(answer.body);
    if (echoed != null && echoed != term.id) {
      throw const AcademicException(
        AcademicStatus.PAGE_CHANGED,
        '学校未按所选学期返回课表，请刷新后重试',
      );
    }
    return ScheduleHtml.parse(answer.body, answer.address);
  }

  Future<GradeReport> grades(AcademicTerm? term) async {
    final report = await switch (_system) {
      AcademicSystem.ZF => _zfScores(term),
      AcademicSystem.ZF_OLD => _legacyZfScores(term),
      _ => _qzScores(term),
    };
    return GradeMath.enrichReport(report);
  }

  Future<GradeReport> _zfScores(AcademicTerm? term) async {
    final (rows, header) = await _collectZfScorePages(term);
    var entries = StudyJson.gradeRows(rows);

    // 非致命单次批量抓取全学期成绩分项（平时/作业/实验/期末），按 jxb_id 自动挂载。
    if (entries.isNotEmpty) {
      try {
        final subRows = await _fetchBulkSubScoreRows();
        if (subRows.isNotEmpty) {
          entries = StudyJson.attachSubItems(entries, subRows);
        }
      } on AcademicException catch (e) {
        if (e.status == AcademicStatus.SESSION_EXPIRED) rethrow;
      } catch (_) {
        // 离线最小夹具或部分未开放 N305007 的学校安全忽略。
      }
    }

    return GradeReport(
      grades: entries,
      gradePointAverageRaw:
          AcademicJson.string(header, const ['pjxfjd', 'gradePointAverage']),
      totalCreditsRaw:
          AcademicJson.string(header, const ['sxzxf', 'totalCredits']),
    );
  }

  Future<(List<JsonMap>, JsonMap)> _collectZfScorePages(
    AcademicTerm? term,
  ) async {
    Future<(List<JsonMap>, JsonMap)> queryAt(String url) =>
        _collectJsonPages((pageNumber) {
          final params = <String, String>{
            ..._zfTermFields(term),
            'queryModel.showCount': _rowsPerPage.toString(),
            'queryModel.currentPage': pageNumber.toString(),
            'queryModel.sortName': '',
            'queryModel.sortOrder': 'asc',
            'time': '0',
          };
          return _transport.submitForm(
            url,
            params.entries.map((e) => (e.key, e.value)),
            ajax: true,
          );
        });

    if (_gradesPath.trim().isNotEmpty) {
      return queryAt(_customScoreUrl(_gradesPath));
    }

    final primaryUrl = _zfUrlWithParams(
      _primaryPersonalScorePath,
      {'doType': 'query', 'gnmkdm': _gradeGnmkdm},
    );
    try {
      return await queryAt(primaryUrl);
    } on AcademicException catch (e) {
      if (e.status == AcademicStatus.SESSION_EXPIRED) rethrow;
    }

    final fallbackUrl = _zfUrlWithParams(
      _fallbackScorePath,
      {'doType': 'query', 'gnmkdm': _gradeGnmkdm},
    );
    return queryAt(fallbackUrl);
  }

  Future<List<JsonMap>> _fetchBulkSubScoreRows() async {
    final url = _zfUrlWithParams(
      _bulkSubScorePath,
      {'gnmkdm': subScoreGnmkdm},
    );
    final (rows, _) = await _collectJsonPages(
      (pageNumber) {
        final params = <String, String>{
          'xnm': '',
          'xqm': '',
          'queryModel.showCount': _subScoreRowsPerPage.toString(),
          'queryModel.currentPage': pageNumber.toString(),
          'queryModel.sortName': '',
          'queryModel.sortOrder': 'asc',
          'time': '0',
        };
        return _transport.submitForm(
          url,
          params.entries.map((e) => (e.key, e.value)),
          ajax: true,
        );
      },
      rowsPerPage: _subScoreRowsPerPage,
    );
    return rows;
  }

  /// 按课程教学班查询成绩分项明细（`cjcx/cjcx_cxXsXmcjList.html?gnmkdm=N305007`，兜底 `cjcx_cxCjxqGjh.html`）。
  Future<List<GradeSubItem>> gradeSubItems(GradeEntry entry) async {
    if (_system != AcademicSystem.ZF) return entry.subItems;
    final jxbId = entry.jxbId.trim();
    if (jxbId.isEmpty) return entry.subItems;

    final normalizedTerm = GradesHtml.term(entry.term);
    final term = normalizedTerm != null ? AcademicTerm(normalizedTerm) : null;
    final termFields = _zfTermFields(term);

    try {
      final page = _verify(
        await _transport.submitForm(
          _zfUrlWithParams(_courseSubScorePath, {'gnmkdm': subScoreGnmkdm}),
          <String, String>{
            ...termFields,
            'jxb_id': jxbId,
            'queryModel.showCount': '50',
            'queryModel.currentPage': '1',
          }.entries.map((e) => (e.key, e.value)),
          ajax: true,
        ),
      );
      final parsed = StudyJson.parseSubItems(page.body);
      if (parsed.isNotEmpty) return parsed;
    } on AcademicException catch (e) {
      if (e.status == AcademicStatus.SESSION_EXPIRED) rethrow;
    }

    try {
      final modal = _verify(
        await _transport.submitForm(
          _zfUrlWithParams(_courseSubScoreModalPath, {'gnmkdm': _gradeGnmkdm}),
          <String, String>{
            ...termFields,
            'jxb_id': jxbId,
            'kcmc': entry.name,
          }.entries.map((e) => (e.key, e.value)),
          ajax: true,
        ),
      );
      final parsed = StudyJson.parseSubItems(modal.body);
      if (parsed.isNotEmpty) return parsed;
    } on AcademicException catch (e) {
      if (e.status == AcademicStatus.SESSION_EXPIRED) rethrow;
    }

    return entry.subItems;
  }

  Future<GradeReport> _qzScores(AcademicTerm? term) async {
    final entry = await _lookupPage(_Lookup.scores);
    final query = _pageFormFields(entry)
      ..['kksj'] = term?.id ?? ''
      ..['kcmc'] = ''
      ..['kcxz'] = ''
      ..['kcsx'] = ''
      ..['xsfs'] = 'all';
    if (!_usesScriptedTable(entry)) {
      final answer = await _legacyQzScores(entry, term);
      return GradesHtml.parse(answer.body, answer.address);
    }
    final (rows, header) = await _collectJsonPages((pageNumber) {
      return _transport.fetch(
        _transport.withQuery(
          _transport.resolveUrl(_modernScoreListPath),
          {
            ...query,
            'pageNum': pageNumber.toString(),
            'pageSize': _rowsPerPage.toString(),
          },
        ),
        referer: entry.address,
        ajax: true,
      );
    });
    return GradeReport(
      grades: StudyJson.gradeRows(rows),
      gradePointAverageRaw: AcademicJson.string(header, const ['pjxfjd']),
      totalCreditsRaw: AcademicJson.string(header, const ['sxzxf']),
    );
  }

  Future<List<ExamEntry>> exams(
    AcademicTerm? term, {
    bool allTerms = false,
  }) async {
    if (_system == AcademicSystem.ZF) {
      final target = allTerms ? null : (term ?? _defaultTerm());
      return _zfExams(target);
    }
    final target = term ?? _defaultTerm();
    return switch (_system) {
      AcademicSystem.ZF_OLD => StudyHtml.exams(
          (await _webFormsQuery(_Lookup.examList, target)).body,
          '',
        ),
      _ => _qzExams(target),
    };
  }

  Future<List<ExamEntry>> _zfExams(AcademicTerm? term) async {
    final (rows, _) = await _collectJsonPages((pageNumber) {
      final params = <String, String>{
        ..._zfTermFields(term),
        'ksmcdmb_id': '',
        'queryModel.showCount': _rowsPerPage.toString(),
        'queryModel.currentPage': pageNumber.toString(),
      };
      return _transport.submitForm(
        _transport.resolveUrl(_zfExamQueryPath),
        params.entries.map((e) => (e.key, e.value)),
        ajax: true,
      );
    });
    return StudyJson.examRows(rows);
  }

  /// 学业情况与培养方案总览（新正方 `GET xsxy/xsxyqk_cxXsxyqkIndex.html?ver=new&gnmkdm=N105515&layout=default`）。
  Future<AcademicProgressReport> academicProgress() async {
    _requireZfSystem('学业情况查询');
    final page = _verify(
      await _transport.fetch(
        _transport.resolveUrl(_zfAcademicProgressIndexPath),
      ),
    );
    final report = XsxyParser.parseProgressHtml(page.body);
    _transport.session.cachedAcademicProgress = report;
    return report;
  }

  /// 学业情况末级类别课程明细（新正方 `POST xsxy/xsxyqk_cxJxzxjhxfyqKcxx.html?gnmkdm=N105515`）。
  Future<List<PlanCourseEntry>> academicProgressCourses(
    String categoryId, {
    String? studentId,
    String? xnm,
    String? xqm,
  }) async {
    _requireZfSystem('学业情况课程明细');
    final trimmedId = categoryId.trim();
    if (trimmedId.isEmpty) return const <PlanCourseEntry>[];

    final cached = _transport.session.cachedAcademicProgress;
    final hidden = cached?.hiddenParams ?? const <String, String>{};
    final defaultFields = _zfTermFields(_defaultTerm());

    final resolvedStudentId = (studentId ?? '').trim().isNotEmpty
        ? studentId!.trim()
        : ((cached?.studentId ?? '').trim().isNotEmpty
            ? cached!.studentId
            : _effectiveStudentId);
    final resolvedXnm = (xnm ?? '').trim().isNotEmpty
        ? xnm!.trim()
        : (hidden['cjlrxn'] ?? defaultFields['xnm'] ?? '');
    final resolvedXqm = (xqm ?? '').trim().isNotEmpty
        ? xqm!.trim()
        : (hidden['cjlrxq'] ?? defaultFields['xqm'] ?? '');

    final params = <String, String>{
      'xfyqjd_id': trimmedId,
      'xh_id': resolvedStudentId,
      'cjlrxn': resolvedXnm,
      'cjlrxq': resolvedXqm,
      'bkcjlrxn': hidden['bkcjlrxn'] ?? resolvedXnm,
      'bkcjlrxq': hidden['bkcjlrxq'] ?? resolvedXqm,
      'xscjcxkz': hidden['xscjcxkz'] ?? '0',
      'cjcxkzzt': hidden['cjcxkzzt'] ?? '2',
      'cjztkz': hidden['cjztkz'] ?? '0',
      'cjzt': hidden['cjzt'] ?? '',
    };
    final page = _verify(
      await _transport.submitForm(
        _transport.resolveUrl(_zfAcademicProgressCoursesPath),
        params.entries.map((e) => (e.key, e.value)),
        referer: _transport.resolveUrl(_zfAcademicProgressIndexPath),
        ajax: true,
      ),
    );
    return XsxyParser.parsePlanCourses(page.body);
  }

  /// 空教室查询（新正方 `POST cdjy/cdjy_cxKxcdlb.html?doType=query&gnmkdm=N2155`）。
  Future<List<EmptyClassroom>> emptyClassrooms(
    EmptyClassroomQuery query,
  ) async {
    _requireZfSystem('空教室查询');
    final term = (query.termId != null && query.termId!.trim().isNotEmpty)
        ? AcademicTerm(query.termId!.trim())
        : _defaultTerm();
    final termFields = _zfTermFields(term);

    final params = <String, String>{
      'fwzt': 'cx',
      'xqh_id': query.campusId.trim().isEmpty ? '1' : query.campusId.trim(),
      'xnm': termFields['xnm'] ?? '',
      'xqm': termFields['xqm'] ?? '',
      'cdlb_id': query.roomTypeId.trim(),
      'cdejlb_id': '',
      'qszws': query.minSeats?.toString() ?? '',
      'jszws': query.maxSeats?.toString() ?? '',
      'cdmc': query.roomNameKeyword.trim(),
      'lh': query.building.trim(),
      'jyfs': '0',
      'cdjylx': '',
      'zcd': query.zcdBitmask,
      'xqj': query.xqjParam,
      'jcd': query.jcdBitmask,
      'queryModel.showCount':
          (query.pageSize < 1 ? 50 : query.pageSize).toString(),
      'queryModel.currentPage': (query.page < 1 ? 1 : query.page).toString(),
      'queryModel.sortName': 'cdbh',
      'queryModel.sortOrder': 'asc',
    };

    final page = _verify(
      await _transport.submitForm(
        _transport.resolveUrl(_zfEmptyClassroomQueryPath),
        params.entries.map((e) => (e.key, e.value)),
        ajax: true,
      ),
    );
    final rows = AcademicJson.objects(page.body, const ['items', 'data']);
    return StudyJson.emptyClassrooms(rows);
  }

  /// 全天候学生已选课程名单查询（新正方 `POST xkcx/xkmdcx_cxXkmdcxIndex.html?doType=query&gnmkdm=N255010`）。
  ///
  /// 注意：严禁读取或存储服务端原始响应中的 `zjhm` / `sjhm` 字段。
  Future<List<EnrolledCourseEntry>> enrolledCourses({
    AcademicTerm? term,
  }) async {
    _requireZfSystem('选课名单查询');
    final target = term ?? _defaultTerm();
    final (rows, _) = await _collectJsonPages((pageNumber) {
      final params = <String, String>{
        ..._zfTermFields(target),
        'queryModel.showCount': _rowsPerPage.toString(),
        'queryModel.currentPage': pageNumber.toString(),
        'queryModel.sortName': '',
        'queryModel.sortOrder': 'asc',
        'time': '0',
      };
      return _transport.submitForm(
        _transport.resolveUrl(_zfEnrolledCoursesQueryPath),
        params.entries.map((e) => (e.key, e.value)),
        ajax: true,
      );
    });
    return StudyJson.enrolledCourses(rows);
  }

  void _requireZfSystem(String featureName) {
    if (_system != AcademicSystem.ZF) {
      throw AcademicException(
        AcademicStatus.UNSUPPORTED,
        '当前版本尚未适配 ${_system.id} 的$featureName',
      );
    }
  }

  Future<List<ExamEntry>> _qzExams(AcademicTerm term) async {
    final entry = await _lookupPage(_Lookup.examList);
    final query = _pageFormFields(entry)
      ..['xnxqid'] = term.id
      ..['xqlb'] = '';
    final target = _transport.resolveUrl(_qzExamListPath);
    if (!_usesScriptedTable(entry)) {
      final answer = _verify(
        await _transport.submitForm(
          target,
          query.entries.map((e) => (e.key, e.value)),
          referer: entry.address,
        ),
      );
      return StudyHtml.exams(answer.body, target);
    }
    final (rows, _) = await _collectJsonPages((pageNumber) {
      return _transport.fetch(
        _transport.withQuery(
          target,
          {
            ...query,
            'pageNum': pageNumber.toString(),
            'pageSize': _rowsPerPage.toString(),
          },
        ),
        referer: entry.address,
        ajax: true,
      );
    });
    return StudyJson.examRows(rows);
  }

  Future<FetchedPage> _homePage() async {
    final cached = _cachedHome;
    if (cached != null) return cached;
    final url = switch (_system) {
      AcademicSystem.ZF_OLD => _transport.withQuery(
          _transport.resolveUrl('xs_main.aspx'),
          {'xh': _username},
        ),
      AcademicSystem.QZ_OLD => _transport.resolveUrl('framework/xsMain.jsp'),
      _ => _transport.resolveUrl('framework/xsMainV.htmlx'),
    };
    final page = _verify(await _transport.fetch(url));
    _cachedHome = page;
    return page;
  }

  Future<FetchedPage> _lookupPage(_Lookup kind) async {
    final home = await _homePage();
    final marker =
        _system == AcademicSystem.ZF_OLD ? kind.legacyPath : kind.modernPath;
    String? discovered;
    final doc = Html.parse(home.body, home.address);
    for (final candidate
        in doc.querySelectorAll('a[href], [data-src], [data-url]')) {
      final address = _linkAddress(candidate);
      final qIdx = address.indexOf('?');
      final beforeQ = qIdx < 0 ? address : address.substring(0, qIdx);
      if (beforeQ.toLowerCase().endsWith(marker.toLowerCase())) {
        discovered = Urls.resolve(home.address, address);
        break;
      }
    }
    final String url;
    if (discovered != null) {
      url = discovered;
    } else if (_system == AcademicSystem.ZF_OLD) {
      throw AcademicException(
        AcademicStatus.UNSUPPORTED,
        '学校页面里找不到${kind.label}查询入口',
      );
    } else {
      url = _transport.resolveUrl(kind.modernPath);
    }
    _assertStudyEndpoint(url, kind);
    return _verify(await _transport.fetch(url, referer: home.address));
  }

  Future<FetchedPage> _qzTimetablePage() async {
    var page = await _lookupPage(_Lookup.timetable);
    for (var i = 0; i < _frameDepthLimit; i++) {
      final frame = _frameSourceEndingWith(
        Html.parse(page.body, page.address).documentElement,
        _timetableFrameMarker,
      );
      if (frame == null) return page;
      final url = Urls.resolve(page.address, Html.attr(frame, 'src'));
      _assertStudyEndpoint(url, _Lookup.timetable);
      page = _verify(await _transport.fetch(url, referer: page.address));
    }
    throw const AcademicException(
      AcademicStatus.PAGE_CHANGED,
      '学校课表页面的框架嵌套层级异常',
    );
  }

  Future<FetchedPage> _webFormsQuery(
    _Lookup kind,
    AcademicTerm? term, [
    FetchedPage? startFrom,
  ]) async {
    var page = startFrom ?? await _lookupPage(kind);
    if (term != null) page = await _applyTermPostBacks(page, kind, term);
    if (kind != _Lookup.timetable) {
      page = await _clickLookupButton(page, kind, term);
    }
    return page;
  }

  Future<FetchedPage> _applyTermPostBacks(
    FetchedPage page,
    _Lookup kind,
    AcademicTerm term,
  ) async {
    var current = page;
    final wanted = <(List<String>, String)>[
      (const ['xnd', 'ddlXN', 'xn'], '${term.year}-${term.year + 1}'),
      (const ['xqd', 'ddlXQ', 'xq'], term.semester.toString()),
    ];
    for (final (aliases, value) in wanted) {
      final form = _requireForm(current, kind);
      Element? select;
      for (final candidate in form.querySelectorAll('select[name]')) {
        final name = Html.attr(candidate, 'name');
        final dollarIdx = name.lastIndexOf(r'$');
        final shortName =
            dollarIdx < 0 ? name : name.substring(dollarIdx + 1);
        if (aliases.contains(shortName)) {
          select = candidate;
          break;
        }
      }
      if (select == null) {
        throw const AcademicException(
          AcademicStatus.PAGE_CHANGED,
          '学校页面里没有学年或学期下拉框',
        );
      }
      Element? option;
      for (final opt in select.querySelectorAll('option')) {
        if (Html.attr(opt, 'value') == value ||
            Html.textOf(opt).trim() == value) {
          option = opt;
          break;
        }
      }
      if (option == null) {
        throw AcademicException(
          AcademicStatus.UNSUPPORTED,
          '学校还没有开放这个学期的${kind.label}',
        );
      }
      final already = select.querySelector('option[selected]') ??
          select.querySelector('option');
      if (already != null &&
          Html.attr(already, 'value') == Html.attr(option, 'value')) {
        continue;
      }
      final selectName = Html.attr(select, 'name');
      final fields = _pageFormFields(current)
        ..[selectName] = Html.attr(option, 'value')
        ..[_eventTargetField] = selectName
        ..[_eventArgumentField] = '';
      current = await _postWebFormsForm(current, form, fields, kind);
    }
    return current;
  }

  Future<FetchedPage> _clickLookupButton(
    FetchedPage page,
    _Lookup kind,
    AcademicTerm? term,
  ) async {
    final form = _requireForm(page, kind);
    final button =
        _pickSubmit(form, kind.submitLabels(wholeHistory: term == null));
    if (button == null) {
      if (kind == _Lookup.scores && term == null) {
        throw const AcademicException(
          AcademicStatus.PAGE_CHANGED,
          '没有找到学校历年成绩的查询按钮',
        );
      }
      return page;
    }
    final fields = _pageFormFields(
      page,
      (Html.attr(button, 'name'), Html.attr(button, 'value')),
    )
      ..[_eventTargetField] = ''
      ..[_eventArgumentField] = '';
    return _postWebFormsForm(page, form, fields, kind);
  }

  Future<GradeReport> _legacyZfScores(AcademicTerm? term) async {
    final entry = await _lookupPage(_Lookup.scores);
    if (term != null || _scoreQueryButton(entry, wholeHistory: true) != null) {
      final page = await _webFormsQuery(_Lookup.scores, term, entry);
      final parsed = GradesHtml.parse(page.body, page.address).grades;
      return GradeReport(
        grades: parsed
            .map(
              (row) => row.term.trim().isEmpty && term != null
                  ? row.copyWith(term: term.id)
                  : row,
            )
            .toList(growable: false),
      );
    }

    final semesters = GradesHtml.terms(entry.body)
        .map(AcademicTerm.new)
        .toList()
      ..sort((a, b) => b.id.compareTo(a.id));
    if (semesters.isEmpty ||
        _scoreQueryButton(entry, wholeHistory: false) == null) {
      throw const AcademicException(
        AcademicStatus.PAGE_CHANGED,
        '既找不到历年成绩入口，也没有可逐学期汇总的查询按钮，请核对学校成绩页面',
      );
    }
    if (semesters.length > _semesterAggregateLimit) {
      throw const AcademicException(
        AcademicStatus.PAGE_CHANGED,
        '学校给出的成绩学期数量异常，暂时无法完整汇总',
      );
    }

    final collected = <GradeEntry>{};
    for (final semester in semesters) {
      final page = await _webFormsQuery(_Lookup.scores, semester);
      final rows = GradesHtml.parse(page.body, page.address).grades;
      if (rows.any((r) => r.term.trim().isNotEmpty && r.term != semester.id)) {
        throw const AcademicException(
          AcademicStatus.PAGE_CHANGED,
          '学校返回的成绩学期与所查学期不符，历年成绩无法完整汇总',
        );
      }
      for (final r in rows) {
        collected.add(
          r.term.trim().isEmpty ? r.copyWith(term: semester.id) : r,
        );
      }
    }
    return GradeReport(grades: collected.toList(growable: false));
  }

  Element? _scoreQueryButton(FetchedPage page, {required bool wholeHistory}) {
    final form = Html.parse(page.body, page.address).querySelector('form');
    if (form == null) return null;
    return _pickSubmit(
      form,
      _Lookup.scores.submitLabels(wholeHistory: wholeHistory),
    );
  }

  Future<FetchedPage> _postWebFormsForm(
    FetchedPage page,
    Element form,
    Map<String, String> fields,
    _Lookup kind,
  ) async {
    final target = Html.action(form, page.address);
    _assertStudyEndpoint(target, kind);
    return _verify(
      await _transport.submitForm(
        target,
        fields.entries.map((e) => (e.key, e.value)),
        referer: page.address,
      ),
    );
  }

  Future<FetchedPage> _legacyQzScores(
    FetchedPage wrapper,
    AcademicTerm? term,
  ) async {
    final frameSource = _frameSourceEndingWith(
      Html.parse(wrapper.body, wrapper.address).documentElement,
      _legacyScoreFormMarker,
    );
    final page = frameSource != null
        ? _verify(
            await _transport.fetch(
              Urls.resolve(wrapper.address, Html.attr(frameSource, 'src')),
              referer: wrapper.address,
            ),
          )
        : wrapper;
    final document = Html.parse(page.body, page.address);
    final form = document.querySelector('form[name=kscjQueryForm]') ??
        document.querySelector('form');
    if (form == null) {
      throw const AcademicException(
        AcademicStatus.PAGE_CHANGED,
        '学校成绩页面里没有可用的查询表单',
      );
    }
    final target = Html.queryFormAction(form, page.body, page.address);
    if (target == null || !_isScoreEndpoint(target)) {
      throw const AcademicException(
        AcademicStatus.PAGE_CHANGED,
        '学校成绩查询的提交地址已改变',
      );
    }
    final fields = _pageFormFields(page)
      ..['kksj'] = term?.id ?? ''
      ..['kcmc'] = ''
      ..['kcxz'] = ''
      ..['kcsx'] = ''
      ..['xsfs'] = 'all';
    return _verify(
      await _transport.submitForm(
        target,
        fields.entries.map((e) => (e.key, e.value)),
        referer: page.address,
      ),
    );
  }

  static bool _isScoreEndpoint(String url) {
    final path = Urls.parseUrl(url)?.path ?? '';
    return path.endsWith(_modernScoreListPathFull) ||
        path.endsWith(_legacyScoreFormMarker);
  }

  Future<(List<JsonMap>, JsonMap)> _collectJsonPages(
    Future<FetchedPage> Function(int pageNumber) request, {
    int rowsPerPage = _rowsPerPage,
  }) async {
    final collected = <JsonMap>[];
    final fingerprints = <String>{};
    var header = <String, dynamic>{};
    for (var pageNumber = 1; pageNumber <= _pageLimit; pageNumber++) {
      final response = _verify(await request(pageNumber));
      final rows =
          AcademicJson.objects(response.body, const ['items', 'data']);
      final parsedRoot = AcademicJson.parse(response.body);
      final root = parsedRoot is Map
          ? Map<String, dynamic>.from(parsedRoot)
          : <String, dynamic>{};
      if (pageNumber == 1) header = root;
      final declared = _declaredRowCount(root);
      if (rows.isNotEmpty &&
          !fingerprints.add(rows.map(jsonEncode).join(', '))) {
        throw const AcademicException(
          AcademicStatus.PAGE_CHANGED,
          '学校把同一页内容重复返回了，请稍后重试',
        );
      }
      collected.addAll(rows);
      if (declared != null && collected.length >= declared) {
        return (collected, header);
      }
      if (rows.isEmpty) {
        if (declared != null && collected.length < declared) {
          throw const AcademicException(
            AcademicStatus.PAGE_CHANGED,
            '学校返回的分页数据不完整，请刷新后重试',
          );
        }
        return (collected, header);
      }
      if (declared == null && rows.length < rowsPerPage) {
        return (collected, header);
      }
    }
    throw const AcademicException(
      AcademicStatus.PAGE_CHANGED,
      '翻页次数已超过上限，请指定学期后再查询',
    );
  }

  int? _declaredRowCount(JsonMap root) {
    final common = AcademicJson.integer(
      root,
      const ['count', 'totalCount', 'totalResult', 'records'],
    );
    if (common != null) return common;
    if (_system == AcademicSystem.ZF) return null;
    return AcademicJson.integer(root, const ['total']);
  }

  static FetchedPage _verify(FetchedPage page) {
    if (Html.isLoginPage(page.body) ||
        AcademicJson.looksLikeSessionExpired(page.body)) {
      throw const AcademicException(
        AcademicStatus.SESSION_EXPIRED,
        '登录状态已失效，请重新登录',
      );
    }
    if (page.status < 200 || page.status > 299) {
      throw const AcademicException(
        AcademicStatus.PAGE_CHANGED,
        '学校查询页面当前不可访问',
      );
    }
    return page;
  }

  void _assertStudyEndpoint(String url, _Lookup kind) {
    final pageName =
        _system == AcademicSystem.ZF_OLD ? kind.legacyPath : kind.modernPath;
    final path = Urls.parseUrl(url)?.path ?? '';
    if (!path.toLowerCase().endsWith('/${pageName.toLowerCase()}')) {
      throw AcademicException(
        AcademicStatus.PAGE_CHANGED,
        '学校${kind.label}的入口地址已改变',
      );
    }
  }

  static Map<String, String> _pageFormFields(
    FetchedPage page, [
    (String, String)? clickedSubmit,
  ]) {
    final form = Html.parse(page.body, page.address).querySelector('form');
    if (form == null) return <String, String>{};
    final out = <String, String>{};
    for (final (k, v) in Html.formFields(form, clickedSubmit: clickedSubmit)) {
      out[k] = v;
    }
    return out;
  }

  static bool _usesScriptedTable(FetchedPage page) =>
      page.body.contains('qzTable') || page.body.contains('/assets_newL/');

  Future<FetchedPage> _submitAsDeclared(
    Element? formElement,
    String url,
    Map<String, String> fields,
    String referer,
  ) {
    if (formElement != null &&
        Html.attr(formElement, 'method').toLowerCase() == 'post') {
      return _transport.submitForm(
        url,
        fields.entries.map((e) => (e.key, e.value)),
        referer: referer,
      );
    }
    return _transport.fetch(_transport.withQuery(url, fields), referer: referer);
  }

  String _zfUrlWithParams(String path, Map<String, String> defaultParams) {
    final resolved = _transport.resolveUrl(path);
    final qIdx = resolved.indexOf('?');
    final existingQuery = qIdx < 0 ? '' : resolved.substring(qIdx + 1);
    final missing = <String, String>{};
    for (final entry in defaultParams.entries) {
      final keyPrefix = '${entry.key}=';
      if (!existingQuery.split('&').any((p) => p.startsWith(keyPrefix))) {
        missing[entry.key] = entry.value;
      }
    }
    return _transport.withQuery(resolved, missing);
  }

  String _fallbackTimetableUrl() => _zfUrlWithParams(
        _fallbackTimetablePath,
        {'gnmkdm': _scheduleGnmkdm},
      );

  String _customTimetableUrl(String customPath) => _zfUrlWithParams(
        customPath.trim(),
        {'gnmkdm': _scheduleGnmkdm},
      );

  String _customScoreUrl(String customPath) => _zfUrlWithParams(
        customPath.trim(),
        {'doType': 'query', 'gnmkdm': _gradeGnmkdm},
      );

  static List<AcademicTerm> _orderTerms(List<AcademicTerm> terms) {
    final seen = <String>{};
    final deduped = <AcademicTerm>[];
    for (final t in terms) {
      if (seen.add(t.id)) deduped.add(t);
    }
    deduped.sort((a, b) => b.id.compareTo(a.id));
    return deduped;
  }

  static Map<String, String> _zfTermFields(AcademicTerm? term) => {
        'xnm': term?.year.toString() ?? '',
        'xqm': switch (term?.semester) {
          _autumnSemester => '3',
          _springSemester => '12',
          _summerSemester => '16',
          _winterSemester => '32',
          _ => '',
        },
      };

  static Element _requireForm(FetchedPage page, _Lookup kind) {
    final form = Html.parse(page.body, page.address).querySelector('form');
    if (form == null) {
      throw AcademicException(
        AcademicStatus.PAGE_CHANGED,
        '学校${kind.label}页面缺少查询表单',
      );
    }
    return form;
  }

  static String _linkAddress(Element element) {
    final dataUrl = Html.attr(element, 'data-url').trim();
    if (dataUrl.isNotEmpty) return dataUrl;
    final dataSrc = Html.attr(element, 'data-src').trim();
    if (dataSrc.isNotEmpty) return dataSrc;
    return Html.attr(element, 'href');
  }

  static Element? _frameSourceEndingWith(Element? root, String suffix) {
    if (root == null) return null;
    for (final candidate in root.querySelectorAll('iframe[src]')) {
      final src = Html.attr(candidate, 'src');
      final qIdx = src.indexOf('?');
      final beforeQ = qIdx < 0 ? src : src.substring(0, qIdx);
      if (beforeQ.endsWith(suffix)) return candidate;
    }
    return null;
  }

  static Element? _pickSubmit(Element form, Set<String> labels) {
    for (final candidate
        in form.querySelectorAll('input[type=submit], button')) {
      if (Html.hasAttr(candidate, 'disabled')) continue;
      final rawVal = Html.attr(candidate, 'value').trim();
      final caption =
          (rawVal.isNotEmpty ? rawVal : Html.textOf(candidate)).trim();
      if (labels.contains(caption)) return candidate;
    }
    return null;
  }
}

/// 按给定 UTC 秒数推算国内教务常识学期（8月后为新学年第一学期，2–7月为第二学期）。
AcademicTerm calendarTerm(int epochSeconds) {
  const secondsPerDay = 86400;
  final days = epochSeconds >= 0
      ? epochSeconds ~/ secondsPerDay
      : -((-epochSeconds + secondsPerDay - 1) ~/ secondsPerDay);
  final (year, month, _) = CivilDate.civilFromDays(days);
  final academicYearStart = month >= 8 ? year : year - 1;
  final half = (month >= 8 || month < 2) ? 1 : 2;
  return AcademicTerm('$academicYearStart-${academicYearStart + 1}-$half');
}
