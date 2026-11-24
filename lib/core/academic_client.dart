import 'dart:convert';

import 'login/browser_session_import_flow.dart';
import 'login/zhengfang_cas_login_flow.dart';
import 'login/zhengfang_jwglxt_login_flow.dart';
import 'model/academic_status.dart';
import 'model/academic_system.dart';
import 'model/course_query.dart';
import 'model/grades.dart';
import 'model/qust_modules.dart';
import 'model/schedule.dart';
import 'model/selection.dart';
import 'model/study.dart';
import 'model/term.dart';
import 'net/page_charset.dart';
import 'parse/grade_math.dart';
import 'parse/grades_html.dart';
import 'parse/schedule_html.dart';
import 'parse/schedule_text.dart';
import 'parse/study_html.dart';
import 'parse/system_detector.dart';
import 'port/http.dart';
import 'port/runtime.dart';
import 'port/storage.dart';
import 'schedule/course_reminder_planner.dart';
import 'schedule/ics_export.dart';
import 'schedule/period_schedule_builder.dart';
import 'schedule/schedule_conflicts.dart';
import 'schedule/week_grid_planner.dart';
import 'selection/zhengfang_selection.dart';
import 'session/credential_vault.dart';
import 'session/login_result.dart';
import 'session/session.dart';
import 'session/session_archive.dart';
import 'study/study_probe.dart';
import 'study/study_reader.dart';
import 'study/study_system_probe.dart';
import 'study/study_transport.dart';

class _PageBody {
  const _PageBody(this.text, this.finalUrl);

  final String text;
  final String finalUrl;
}

/// App 面向的唯一业务核心门面（纯 Dart，无任何平台/UI 依赖）。
class AcademicClient {
  AcademicClient({
    required HttpEngine engine,
    required TextDecoder decoder,
    required SecureStore secureStore,
    required int Function() clock,
    required SecureRandom random,
  })  : _engine = engine,
        _decoder = decoder,
        _clock = clock,
        _random = random,
        _sessions = SessionStore(clock: clock),
        _credentials = CredentialVault(
          store: secureStore,
          service: 'dev.courselens.credentials',
        ),
        _workerKeys = CredentialVault(
          store: secureStore,
          service: 'dev.courselens.worker_keys',
        ),
        _archive = SessionArchive(
          store: secureStore,
          service: 'dev.courselens.sessions',
        );

  static const String probeSessionLabel = 'study-detection';
  static const String defaultSelectionGnmkdm = 'N253512';

  final HttpEngine _engine;
  final TextDecoder _decoder;
  final int Function() _clock;
  final SecureRandom _random;

  final SessionStore _sessions;
  final CredentialVault _credentials;
  final CredentialVault _workerKeys;
  final SessionArchive _archive;

  CredentialVault get credentialVault => _credentials;
  CredentialVault get workerKeyVault => _workerKeys;

  Future<void> saveWorkerApiKey(
    String schoolId,
    String accountKey,
    String apiKey,
  ) =>
      _withStorage(() => _workerKeys.save(schoolId, accountKey, apiKey));

  Future<String?> loadWorkerApiKey(String schoolId, String accountKey) =>
      _withStorage(() => _workerKeys.load(schoolId, accountKey));

  Future<bool> hasWorkerApiKey(String schoolId, String accountKey) =>
      _withStorage(() => _workerKeys.has(schoolId, accountKey));

  Future<void> forgetWorkerApiKey(String schoolId, String accountKey) =>
      _withStorage(() => _workerKeys.forget(schoolId, accountKey));

  /// 绑定由有状态 Cloudflare Worker 在云端托管 Cookie 的会话（本地不落盘原始教务 Cookie）。
  Future<void> bindRemoteManagedSession({
    required String schoolId,
    required String accountKey,
    required String academicBaseUrl,
    String username = '',
  }) async {
    final session =
        await _sessions.replace(schoolId, accountKey, academicBaseUrl);
    if (username.trim().isNotEmpty) {
      session.username = username.trim();
    }
  }

  Future<bool> persistSession(SavedAccount account) => _withStorage(() async {
        final session =
            await _sessions.find(account.schoolId, account.accountKey);
        final cookies = session != null
            ? await session.cookies.snapshot()
            : const <StoredCookie>[];
        final effectiveAccount = (session != null &&
                session.baseUrl.trim().isNotEmpty &&
                session.baseUrl != account.baseUrl)
            ? account.copyWith(baseUrl: session.baseUrl)
            : account;
        return _archive.save(effectiveAccount, cookies);
      });

  Future<List<SavedAccount>> savedAccounts() =>
      _withStorage(_archive.accounts);

  Future<SavedAccount?> activeSavedAccount() =>
      _withStorage(_archive.activeAccount);

  Future<bool> setActiveAccount(String schoolId, String accountKey) =>
      _withStorage(() => _archive.setActive(schoolId, accountKey));

  Future<List<SavedAccount>> restoreSavedSessions() => _withStorage(() async {
        final accounts = await _archive.accounts();
        for (final account in accounts) {
          if (account.baseUrl.trim().isEmpty) continue;
          final cookies =
              await _archive.cookiesFor(account.schoolId, account.accountKey);
          if (cookies.isEmpty && account.protocol != 'worker') continue;
          final session = await _sessions.replace(
            account.schoolId,
            account.accountKey,
            account.baseUrl,
          );
          if (cookies.isNotEmpty) {
            await session.cookies.restore(cookies);
          }
          if (account.username.trim().isNotEmpty) {
            session.username = account.username;
          }
        }
        return accounts;
      });

  Future<bool> validateSession({
    required String schoolId,
    required String accountKey,
    required String systemId,
    String username = '',
  }) async {
    final session = await _sessions.requireActive(schoolId, accountKey);
    try {
      return await _openReader(session, systemId, username, '', '').validate();
    } on AcademicException {
      return false;
    }
  }

  Future<LoginResult> relogin(String schoolId, String accountKey) =>
      _withStorage(() async {
        SavedAccount? account;
        for (final item in await _archive.accounts()) {
          if (item.schoolId == schoolId && item.accountKey == accountKey) {
            account = item;
            break;
          }
        }
        if (account == null) {
          return const LoginResult(
            AcademicStatus.SESSION_EXPIRED,
            message: '没有保存过这个账号，请重新登录',
          );
        }
        if (account.protocol != 'cas' && account.protocol != 'jwglxt') {
          return const LoginResult(
            AcademicStatus.SESSION_EXPIRED,
            message: '网页登录的会话需要重新在浏览器里登录',
          );
        }
        final password = await _credentials.load(schoolId, accountKey);
        if (password == null) {
          return const LoginResult(
            AcademicStatus.INVALID_CREDENTIALS,
            message: '没有保存该账号的口令，请重新输入密码',
          );
        }
        final username = account.username.trim().isEmpty
            ? accountKey
            : account.username;
        if (account.protocol == 'cas') {
          return loginCas(
            schoolId: schoolId,
            accountKey: accountKey,
            username: username,
            password: password,
            casBaseUrl: account.casBaseUrl,
            academicBaseUrl: account.baseUrl,
          );
        }
        return loginJwglxt(
          schoolId: schoolId,
          accountKey: accountKey,
          username: username,
          password: password,
          academicBaseUrl: account.baseUrl,
        );
      });

  Future<void> forgetAccount(String schoolId, String accountKey) async {
    await _sessions.invalidate(schoolId, accountKey);
    await _withStorage(() async {
      await _archive.remove(schoolId, accountKey);
      await _credentials.forget(schoolId, accountKey);
      await _workerKeys.forget(schoolId, accountKey);
    });
  }

  Future<LoginResult> loginCas({
    required String schoolId,
    required String accountKey,
    required String username,
    required String password,
    required String casBaseUrl,
    required String academicBaseUrl,
    String? captcha,
  }) async {
    final session =
        await _sessions.session(schoolId, accountKey, academicBaseUrl);
    final flow = ZhengfangCasLoginFlow(
      session: session,
      engine: _engine,
      decoder: _decoder,
      casBaseUrl: casBaseUrl,
      academicBaseUrl: academicBaseUrl,
    );
    final result = await flow.login(username, password, captcha: captcha);
    return result.isSuccess
        ? _rememberCredential(result, schoolId, accountKey, password)
        : result;
  }

  Future<LoginResult> _rememberCredential(
    LoginResult result,
    String schoolId,
    String accountKey,
    String password,
  ) async {
    try {
      await _credentials.save(schoolId, accountKey, password);
      return result;
    } on SecureStoreException catch (error) {
      return LoginResult(
        result.status,
        identity: result.identity,
        captcha: result.captcha,
        message:
            '登录成功，但口令未能保存（安全存储不可用，状态码 ${error.platformStatus}）：下次仍需重新输入',
      );
    }
  }

  Future<LoginResult> loginJwglxt({
    required String schoolId,
    required String accountKey,
    required String username,
    required String password,
    required String academicBaseUrl,
    String? captcha,
  }) async {
    final session =
        await _sessions.session(schoolId, accountKey, academicBaseUrl);
    final flow = ZhengfangJwglxtLoginFlow(
      session: session,
      engine: _engine,
      decoder: _decoder,
      random: _random,
      baseUrl: session.baseUrl.isNotEmpty ? session.baseUrl : academicBaseUrl,
      clock: _clock,
    );
    final result = await flow.login(username, password, captcha: captcha);
    return result.isSuccess
        ? _rememberCredential(result, schoolId, accountKey, password)
        : result;
  }

  Future<LoginResult> adoptBrowserSession({
    required String schoolId,
    required String accountKey,
    required String academicBaseUrl,
    required List<StoredCookie> cookies,
    String? homePath,
    String username = '',
    String? browserUrl,
  }) async {
    final candidateSession = AccountSession(
      key: SessionKey(schoolId, accountKey),
      baseUrl: academicBaseUrl,
      clock: _clock,
    );
    final result = await BrowserSessionImportFlow(
      session: candidateSession,
      engine: _engine,
      decoder: _decoder,
      baseUrl: academicBaseUrl,
    ).importSession(
      cookies,
      homePath: homePath,
      username: username,
      browserUrl: browserUrl,
    );
    if (!result.isSuccess && !result.isProvisional) return result;

    final effectiveBaseUrl = candidateSession.baseUrl.trim().isNotEmpty
        ? candidateSession.baseUrl
        : academicBaseUrl;
    final session =
        await _sessions.replace(schoolId, accountKey, effectiveBaseUrl);
    await session.cookies.restore(await candidateSession.cookies.snapshot());
    session.zfHomeMetadata = candidateSession.zfHomeMetadata;
    if (username.trim().isNotEmpty) {
      session.username = username;
    }
    return result;
  }

  /// 读取当前活动会话的规范化教务根地址（如裸根探测后自动升级为 `.../jwglxt`）。
  Future<String?> activeSessionBaseUrl(
    String schoolId,
    String accountKey,
  ) async =>
      (await _sessions.find(schoolId, accountKey))?.baseUrl;

  /// 将指定账号活动会话切换至同校备用节点根地址（退役旧会话并迁移 Cookie 快照，清空旧节点首页缓存）。
  Future<void> switchSessionBaseUrl({
    required String schoolId,
    required String accountKey,
    required String newBaseUrl,
  }) async {
    final trimmed = newBaseUrl.trim();
    if (trimmed.isEmpty) return;
    final previous = await _sessions.find(schoolId, accountKey);
    final prevCookies = previous != null
        ? await previous.cookies.snapshot()
        : const <StoredCookie>[];
    final prevUsername = previous?.username ?? '';
    final updated = await _sessions.replace(schoolId, accountKey, trimmed);
    if (prevCookies.isNotEmpty) {
      await updated.cookies.restore(prevCookies);
    }
    if (prevUsername.isNotEmpty) {
      updated.username = prevUsername;
    }
  }

  Future<AcademicSystem?> probeSystem(String loginPageUrl) async {
    final request = HttpRequest(method: HttpMethod.get, url: loginPageUrl);
    final response = await _engine.execute(request);
    return SystemDetector.classify(_decodeBody(response));
  }

  Future<bool> hasSavedCredential(String schoolId, String accountKey) =>
      _withStorage(() => _credentials.has(schoolId, accountKey));

  Future<void> forgetCredential(String schoolId, String accountKey) async {
    await _withStorage(() => _credentials.forget(schoolId, accountKey));
    await _sessions.invalidate(schoolId, accountKey);
  }

  Future<T> _withStorage<T>(Future<T> Function() block) async {
    try {
      return await block();
    } on SecureStoreException catch (error) {
      throw AcademicException(
        AcademicStatus.STORAGE_UNAVAILABLE,
        '安全存储不可用（状态码 ${error.platformStatus}）：${error.message}',
        error,
      );
    }
  }

  Future<List<ScheduleEntry>> loadSchedule({
    required String schoolId,
    required String accountKey,
    required String path,
  }) async {
    final session = await _sessions.requireActive(schoolId, accountKey);
    final page = await _loadPage(session, path);
    return ScheduleHtml.parse(page.text, page.finalUrl);
  }

  Future<GradeReport> loadGrades({
    required String schoolId,
    required String accountKey,
    required String path,
  }) async {
    final session = await _sessions.requireActive(schoolId, accountKey);
    final page = await _loadPage(session, path);
    return GradeMath.enrichReport(GradesHtml.parse(page.text, page.finalUrl));
  }

  Future<List<ExamEntry>> loadExams({
    required String schoolId,
    required String accountKey,
    required String path,
  }) async {
    final session = await _sessions.requireActive(schoolId, accountKey);
    final page = await _loadPage(session, path);
    return StudyHtml.exams(page.text, page.finalUrl);
  }

  Future<StudySystemProbe?> probeStudySystem({
    required String schoolId,
    required String academicBaseUrl,
  }) =>
      StudyProbe(
        engine: _engine,
        decoder: _decoder,
        clock: _clock,
      ).detect(
        schoolId: schoolId,
        accountKey: probeSessionLabel,
        academicBaseUrl: academicBaseUrl,
      );

  Future<StudyCatalog> loadStudyCatalog({
    required String schoolId,
    required String accountKey,
    required String systemId,
    String username = '',
    String schedulePath = '',
  }) async {
    final session = await _sessions.requireActive(schoolId, accountKey);
    return _openReader(session, systemId, username, schedulePath, '').catalog();
  }

  Future<List<ScheduleEntry>> loadStudySchedule({
    required String schoolId,
    required String accountKey,
    required String systemId,
    String username = '',
    String termId = '',
    String schedulePath = '',
  }) async {
    final session = await _sessions.requireActive(schoolId, accountKey);
    final term = termId.trim().isNotEmpty ? AcademicTerm(termId) : null;
    return _openReader(session, systemId, username, schedulePath, '')
        .schedule(term);
  }

  /// 读取完整课表模型（含排课条目与 `sjkList` 实践/无固定节次课程）。
  Future<Schedule> loadStudyScheduleBundle({
    required String schoolId,
    required String accountKey,
    required String systemId,
    String username = '',
    String termId = '',
    String schedulePath = '',
  }) async {
    final session = await _sessions.requireActive(schoolId, accountKey);
    final term = termId.trim().isNotEmpty ? AcademicTerm(termId) : null;
    return _openReader(session, systemId, username, schedulePath, '')
        .scheduleBundle(term);
  }

  /// 查询校区官方节次作息时间表（新正方 `POST kbcx/xskbcx_cxRjc.html?gnmkdm=N2151`）。
  Future<List<PeriodTime>> fetchCampusBellSchedule({
    required String schoolId,
    required String accountKey,
    String systemId = 'zf',
    String username = '',
    String? termId,
    String campusId = '1',
  }) async {
    final session = await _sessions.requireActive(schoolId, accountKey);
    final term =
        (termId != null && termId.trim().isNotEmpty) ? AcademicTerm(termId) : null;
    return _openReader(session, systemId, username, '', '').campusBellSchedule(
      term: term,
      campusId: campusId,
    );
  }

  Future<GradeReport> loadStudyGrades({
    required String schoolId,
    required String accountKey,
    required String systemId,
    String username = '',
    String termId = '',
    String gradesPath = '',
  }) async {
    final session = await _sessions.requireActive(schoolId, accountKey);
    final term = termId.trim().isNotEmpty ? AcademicTerm(termId) : null;
    return _openReader(session, systemId, username, '', gradesPath)
        .grades(term);
  }

  /// 按课程教学班查询成绩分项明细（平时 / 作业 / 实验 / 期末等）。
  Future<List<GradeSubItem>> fetchGradeSubItems(
    GradeEntry entry, {
    required String schoolId,
    required String accountKey,
    String systemId = 'zf',
    String username = '',
  }) async {
    final session = await _sessions.requireActive(schoolId, accountKey);
    return _openReader(session, systemId, username, '', '').gradeSubItems(entry);
  }

  Future<List<ExamEntry>> loadStudyExams({
    required String schoolId,
    required String accountKey,
    required String systemId,
    String username = '',
    String termId = '',
    bool allTerms = false,
  }) async {
    final session = await _sessions.requireActive(schoolId, accountKey);
    final term = termId.trim().isNotEmpty ? AcademicTerm(termId) : null;
    return _openReader(session, systemId, username, '', '')
        .exams(term, allTerms: allTerms);
  }

  /// 查询考试安排（支持 `allTerms: true` 拉取全学期考试记录）。
  Future<List<ExamEntry>> fetchExams({
    required String schoolId,
    required String accountKey,
    String systemId = 'zf',
    String username = '',
    String? termId,
    bool allTerms = false,
  }) =>
      loadStudyExams(
        schoolId: schoolId,
        accountKey: accountKey,
        systemId: systemId,
        username: username,
        termId: termId ?? '',
        allTerms: allTerms,
      );

  /// 学业情况与培养方案总览（新正方 `N105515`）。
  Future<AcademicProgressReport> fetchAcademicProgress({
    required String schoolId,
    required String accountKey,
    String systemId = 'zf',
    String username = '',
  }) async {
    final session = await _sessions.requireActive(schoolId, accountKey);
    return _openReader(session, systemId, username, '', '').academicProgress();
  }

  /// 学业情况末级类别培养方案课程列表（新正方 `N105515`）。
  Future<List<PlanCourseEntry>> fetchAcademicProgressCourses(
    String categoryId, {
    required String schoolId,
    required String accountKey,
    String systemId = 'zf',
    String username = '',
    String? studentId,
    String? xnm,
    String? xqm,
  }) async {
    final session = await _sessions.requireActive(schoolId, accountKey);
    return _openReader(session, systemId, username, '', '')
        .academicProgressCourses(
      categoryId,
      studentId: studentId,
      xnm: xnm,
      xqm: xqm,
    );
  }

  /// 动态获取本校空教室筛选元数据（校区与场地类别，新正方 `N2155`）。
  Future<EmptyClassroomFilterOptions> fetchEmptyClassroomFilters({
    required String schoolId,
    required String accountKey,
    String systemId = 'zf',
    String username = '',
  }) async {
    final session = await _sessions.requireActive(schoolId, accountKey);
    return _openReader(session, systemId, username, '', '')
        .emptyClassroomFilters();
  }

  /// 空教室查询（新正方 `N2155`）。
  Future<List<EmptyClassroom>> queryEmptyClassrooms(
    EmptyClassroomQuery query, {
    required String schoolId,
    required String accountKey,
    String systemId = 'zf',
    String username = '',
  }) async {
    final session = await _sessions.requireActive(schoolId, accountKey);
    return _openReader(session, systemId, username, '', '')
        .emptyClassrooms(query);
  }

  /// 全天候已选课程名单查询（新正方 `N255010`，非选课阶段仍可用）。
  Future<List<EnrolledCourseEntry>> fetchEnrolledCourses({
    required String schoolId,
    required String accountKey,
    String systemId = 'zf',
    String username = '',
    String? termId,
  }) async {
    final session = await _sessions.requireActive(schoolId, accountKey);
    final term =
        (termId != null && termId.trim().isNotEmpty) ? AcademicTerm(termId) : null;
    return _openReader(session, systemId, username, '', '')
        .enrolledCourses(term: term);
  }

  Future<List<CourseScope>> loadCourseScopes({
    required String schoolId,
    required String accountKey,
    required String systemId,
  }) async =>
      (await _selectionFor(schoolId, accountKey, systemId)).scopes();

  Future<List<CourseOffer>> listCourses({
    required String schoolId,
    required String accountKey,
    required String systemId,
    required String scopeId,
    required CourseQuery query,
  }) async =>
      (await _selectionFor(schoolId, accountKey, systemId))
          .courses(scopeId, query);

  Future<List<CourseSection>> listCourseSections({
    required String schoolId,
    required String accountKey,
    required String systemId,
    required String courseId,
    required String scopeId,
  }) async =>
      (await _selectionFor(schoolId, accountKey, systemId))
          .sections(courseId, scopeId);

  Future<SelectionOutcome> selectCourse({
    required String schoolId,
    required String accountKey,
    required String systemId,
    required String courseId,
    required String sectionId,
    required String scopeId,
    required bool confirmed,
  }) async =>
      (await _selectionFor(schoolId, accountKey, systemId)).select(
        courseId: courseId,
        sectionId: sectionId,
        scopeId: scopeId,
        confirmed: confirmed,
      );

  Future<SelectionOutcome> dropCourse({
    required String schoolId,
    required String accountKey,
    required String systemId,
    required String courseId,
    required String sectionId,
    required String scopeId,
    required bool confirmed,
  }) async =>
      (await _selectionFor(schoolId, accountKey, systemId)).drop(
        courseId: courseId,
        sectionId: sectionId,
        scopeId: scopeId,
        confirmed: confirmed,
      );

  Future<List<SelectedCourse>> loadSelectedCourses({
    required String schoolId,
    required String accountKey,
    required String systemId,
  }) async =>
      (await _selectionFor(schoolId, accountKey, systemId)).selected();

  Future<ZhengfangSelection> _selectionFor(
    String schoolId,
    String accountKey,
    String systemId,
  ) async {
    final system = _systemOrFail(systemId);
    if (system != AcademicSystem.ZF) {
      throw AcademicException(
        AcademicStatus.UNSUPPORTED,
        '当前版本尚未适配${system.id}的选课接口（课表、成绩与考试不受影响）',
      );
    }
    final session = await _sessions.requireActive(schoolId, accountKey);
    return ZhengfangSelection(
      transport: StudyTransport(
        session: session,
        engine: _engine,
        decoder: _decoder,
        defaultRefererPath: StudyReader.defaultRefererPathFor(system),
      ),
      courseGnmkdm: defaultSelectionGnmkdm,
    );
  }

  StudyReader _openReader(
    AccountSession session,
    String systemId,
    String username,
    String schedulePath,
    String gradesPath,
  ) {
    final system = _systemOrFail(systemId);
    return StudyReader(
      transport: StudyTransport(
        session: session,
        engine: _engine,
        decoder: _decoder,
        defaultRefererPath: StudyReader.defaultRefererPathFor(system),
      ),
      system: system,
      username: username,
      schedulePath: schedulePath,
      gradesPath: gradesPath,
      nowEpochSeconds: _clock,
    );
  }

  static AcademicSystem _systemOrFail(String systemId) {
    final system = AcademicSystem.fromId(systemId);
    if (system == null || system == AcademicSystem.AUTO) {
      throw AcademicException(
        AcademicStatus.UNSUPPORTED,
        '未知教务类型：$systemId',
      );
    }
    return system;
  }

  Future<int> sessionEpoch(String schoolId, String accountKey) async =>
      (await _sessions.requireActive(schoolId, accountKey)).epoch;

  Future<void> signOut(String schoolId, String accountKey) async {
    await _sessions.invalidate(schoolId, accountKey);
    await _withStorage(() async {
      await _credentials.forget(schoolId, accountKey);
      await _workerKeys.forget(schoolId, accountKey);
    });
  }

  Future<void> clearAll() async {
    await _sessions.clear();
    await _withStorage(_credentials.forgetAll);
    await _withStorage(_workerKeys.forgetAll);
    await _withStorage(_archive.clear);
  }

  Future<_PageBody> _loadPage(AccountSession session, String path) async {
    final url = _absoluteUrl(path, session.baseUrl);
    final cookie = await session.cookieHeaderFor(url);
    final request = HttpRequest(
      method: HttpMethod.get,
      url: url,
      headers: cookie.isEmpty ? const {} : {'Cookie': cookie},
    );
    final response =
        await session.withProtocolLock(() => _engine.execute(request));
    return _PageBody(_decodeBody(response), response.finalUrl);
  }

  String _decodeBody(HttpResponse response) {
    String? contentType;
    for (final entry in response.headers.entries) {
      if (entry.key.toLowerCase() == 'content-type' && entry.value.isNotEmpty) {
        contentType = entry.value.first;
        break;
      }
    }
    final charset = PageCharset.detect(contentType, response.body);
    return charset == PageCharset.utf8Charset
        ? utf8.decode(response.body, allowMalformed: true)
        : _decoder.decode(response.body, charset);
  }

  static String _absoluteUrl(String path, String baseUrl) {
    final lower = path.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return path;
    }
    var base = baseUrl;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    var rel = path;
    while (rel.startsWith('/')) {
      rel = rel.substring(1);
    }
    return '$base/$rel';
  }

  GradeSummary summarize(GradeReport report) => GradeMath.summarize(report);

  String exportIcs({
    required List<IcsEntry> entries,
    required int startYear,
    required int startMonth,
    required int startDay,
    required int totalWeeks,
    required List<PeriodTime> periodTimes,
  }) =>
      IcsExport.generate(
        entries: entries,
        semesterStart: SemesterStart(startYear, startMonth, startDay),
        totalWeeks: totalWeeks,
        periodTimes: periodTimes,
        nowEpochSeconds: _clock(),
      );

  List<PeriodTime> defaultPeriodTimes() => IcsExport.defaultPeriodTimes;

  List<PeriodTime> qustSifangLaoshanPeriodTimes() =>
      PeriodScheduleBuilder.qustSifangLaoshanPreset();

  List<PeriodTime> qustGaomiPeriodTimes() =>
      PeriodScheduleBuilder.qustGaomiPreset();

  List<ScheduleConflict> findConflicts(List<IcsEntry> entries) =>
      ScheduleConflicts.find(entries);

  List<PeriodTime> buildPeriodSchedule(PeriodScheduleSpec spec) =>
      PeriodScheduleBuilder.build(spec);

  List<WeekGridPlacement> planWeekGrid(List<IcsEntry> entries) =>
      WeekGridPlanner.place(entries);

  List<CourseReminder> planCourseReminders({
    required List<IcsEntry> entries,
    required SemesterStart semesterStart,
    required List<PeriodTime> periodTimes,
    required int fromEpochSeconds,
    required int untilEpochSeconds,
    int leadMinutes = 15,
    int limit = 60,
  }) =>
      CourseReminderPlanner.plan(
        entries: entries,
        semesterStart: semesterStart,
        periodTimes: periodTimes,
        fromEpochSeconds: fromEpochSeconds,
        untilEpochSeconds: untilEpochSeconds,
        leadMinutes: leadMinutes,
        limit: limit,
      );

  List<int> parseWeeks(String text) {
    final parsed = ScheduleText.parseWeeks(text);
    if (parsed == null) return const <int>[];
    final sorted = parsed.weeks.toList()..sort();
    return sorted;
  }
}
