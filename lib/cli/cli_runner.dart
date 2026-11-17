import 'dart:async';
import 'dart:io' as io;

import 'package:http/http.dart' as http;

import '../core/courselens_core.dart';
import '../data/http/http_policy_provider.dart';
import '../data/http/io_http_engine.dart';
import '../data/http/relay_http_engine.dart';
import '../data/http/worker_session_http_engine.dart';
import 'cli_args.dart';
import 'cli_demo_fixtures.dart';
import 'cli_formatters.dart';
import 'cli_updater.dart';
import 'store/cli_session_store.dart';

/// 可注入的实时 HTTP 引擎工厂签名（便于单测拦截并断言零写网络发包与 `RESULT_UNKNOWN` 行为）。
typedef CliHttpEngineBuilder = HttpEngine Function({
  required HttpPolicyProvider policyProvider,
  required int Function() clock,
  String? relayUrl,
});

/// CourseLens 纯 Dart 原生命令行执行器。
///
/// 严格遵守纯 Dart 零 Flutter UI/插件依赖与 `docs/security.md` 七条安全红线：
/// - 标准输出（`out`）仅承载业务 Markdown 表格或 `--json` 纯净 JSON；
/// - 诊断、提示与错误统一写入 `err`（当启用 `--json` 且发生错误时，`out` 同步输出结构化错误 JSON）；
/// - 退出码契约：`0` 成功，`2` 选退课未加 `--confirm` 的零写包预检，`1` 参数/鉴权/存储/网络/业务错误。
class CliRunner {
  CliRunner({
    StringSink? out,
    StringSink? err,
    Future<String?> Function()? readStdinLine,
    Future<String> Function()? readStdinAll,
    Future<String?> Function(String prompt)? readHiddenPassword,
    Map<String, String>? environment,
    String? operatingSystem,
    DateTime Function()? nowProvider,
    CliHttpEngineBuilder? httpEngineBuilder,
    http.Client? workerHttpClient,
    CliSessionStore? sessionStoreOverride,
    CliProcessRunner? keychainProcessRunner,
    CliProcessRunner? chmodProcessRunner,
    void Function(AccountSession session)? onSessionRetired,
  })  : _out = out ?? io.stdout,
        _err = err ?? io.stderr,
        _readStdinLine = readStdinLine,
        _readStdinAll = readStdinAll,
        _readHiddenPassword = readHiddenPassword,
        _environment = environment,
        _operatingSystem = operatingSystem,
        _nowProvider = nowProvider ?? DateTime.now,
        _httpEngineBuilder = httpEngineBuilder,
        _workerHttpClient = workerHttpClient,
        _sessionStoreOverride = sessionStoreOverride,
        _keychainProcessRunner = keychainProcessRunner,
        _chmodProcessRunner = chmodProcessRunner,
        _onSessionRetired = onSessionRetired;

  static const int exitOk = 0;
  static const int exitError = 1;
  static const int exitPreviewConfirmRequired = 2;

  static const String _cliSchoolId = 'cli';
  static const String _defaultAccountKey = 'default';

  final StringSink _out;
  final StringSink _err;
  final Future<String?> Function()? _readStdinLine;
  final Future<String> Function()? _readStdinAll;
  final Future<String?> Function(String prompt)? _readHiddenPassword;
  final Map<String, String>? _environment;
  final String? _operatingSystem;
  final DateTime Function() _nowProvider;
  final CliHttpEngineBuilder? _httpEngineBuilder;
  final http.Client? _workerHttpClient;
  final CliSessionStore? _sessionStoreOverride;
  final CliProcessRunner? _keychainProcessRunner;
  final CliProcessRunner? _chmodProcessRunner;
  final void Function(AccountSession session)? _onSessionRetired;

  Map<String, String> get _env => _environment ?? io.Platform.environment;

  int _epochSeconds() => _nowProvider().millisecondsSinceEpoch ~/ 1000;

  /// 执行完整 CLI 命令并返回标准进程退出码（`0` / `1` / `2`）。
  Future<int> run(List<String> argv) async {
    final wantsJson = _rawArgvWantsJson(argv);
    ParsedCliInvocation invocation;
    try {
      invocation = CliArgs.parse(argv);
    } on CliUsageException catch (error) {
      return _emitFailure(
        code: error.isSecurityViolation ? 'SECURITY_REFUSED' : 'INVALID_ARGS',
        message: error.message,
        json: wantsJson,
      );
    }

    final jsonMode = invocation.global.json;
    try {
      return await _dispatch(invocation);
    } on CliUsageException catch (error) {
      return _emitFailure(
        code: error.isSecurityViolation ? 'SECURITY_REFUSED' : 'INVALID_ARGS',
        message: error.message,
        json: jsonMode,
      );
    } on CliStorageUnavailableException catch (error) {
      return _emitFailure(
        code: AcademicStatus.STORAGE_UNAVAILABLE.name,
        message: error.toString(),
        json: jsonMode,
      );
    } on AcademicException catch (error) {
      return _emitFailure(
        code: error.status.name,
        message: error.message.isEmpty ? error.status.name : error.message,
        json: jsonMode,
      );
    } on FormatException catch (error) {
      return _emitFailure(
        code: 'FORMAT_ERROR',
        message: error.message,
        json: jsonMode,
      );
    } on io.FileSystemException catch (error) {
      final pathSuffix = error.path != null ? ' (${error.path})' : '';
      return _emitFailure(
        code: 'IO_ERROR',
        message: '${error.message}$pathSuffix',
        json: jsonMode,
      );
    }
  }

  static bool _rawArgvWantsJson(List<String> argv) {
    for (final token in argv) {
      if (token == '--') break;
      if (token == '--json') return true;
    }
    return false;
  }

  int _emitFailure({
    required String code,
    required String message,
    required bool json,
  }) {
    _err.writeln('[$code] $message');
    if (json) {
      _out.writeln(CliFormatters.formatError(code: code, message: message));
    }
    return exitError;
  }

  Future<int> _dispatch(ParsedCliInvocation inv) async {
    switch (inv.command) {
      case CliCommandKind.version:
        _out.writeln(CliFormatters.formatVersion(json: inv.global.json));
        return exitOk;
      case CliCommandKind.help:
        _out.writeln(
          CliFormatters.formatHelp(
            topic: inv.helpTopic,
            json: inv.global.json,
          ),
        );
        return exitOk;
      case CliCommandKind.authStatus:
        return _runAuthStatus(inv);
      case CliCommandKind.authLogin:
        return _runAuthLogin(inv);
      case CliCommandKind.authWorker:
        return _runAuthWorker(inv);
      case CliCommandKind.authImportCookie:
        return _runAuthImportCookie(inv);
      case CliCommandKind.authLogout:
        return _runAuthLogout(inv);
      case CliCommandKind.workerTasksList:
        return _runWorkerTasksList(inv);
      case CliCommandKind.workerTasksShow:
        return _runWorkerTasksShow(inv);
      case CliCommandKind.workerTasksEnable:
        return _runWorkerTasksToggle(inv, enabled: true);
      case CliCommandKind.workerTasksDisable:
        return _runWorkerTasksToggle(inv, enabled: false);
      case CliCommandKind.workerTasksRun:
        return _runWorkerTasksRun(inv);
      case CliCommandKind.workerTasksDelete:
        return _runWorkerTasksDelete(inv);
      case CliCommandKind.workerPushCookies:
        return _runWorkerPushCookies(inv);
      case CliCommandKind.workerWebhookStatus:
        return _runWorkerWebhookStatus(inv);
      case CliCommandKind.workerWebhookSet:
        return _runWorkerWebhookSet(inv);
      case CliCommandKind.workerWebhookTest:
        return _runWorkerWebhookTest(inv);
      case CliCommandKind.workerWebhookClear:
        return _runWorkerWebhookClear(inv);
      case CliCommandKind.workerMonitorStatus:
        return _runWorkerMonitorStatus(inv);
      case CliCommandKind.workerMonitorSet:
        return _runWorkerMonitorSet(inv);
      case CliCommandKind.workerMonitorCheck:
        return _runWorkerMonitorCheck(inv);
      case CliCommandKind.today:
        return _runToday(inv);
      case CliCommandKind.schedule:
        return _runSchedule(inv);
      case CliCommandKind.grades:
        return _runGrades(inv);
      case CliCommandKind.exams:
        return _runExams(inv);
      case CliCommandKind.plan:
        return _runPlan(inv);
      case CliCommandKind.rooms:
        return _runRooms(inv);
      case CliCommandKind.courses:
        return _runCourses(inv);
      case CliCommandKind.select:
        return _runMutation(inv, dropping: false);
      case CliCommandKind.drop:
        return _runMutation(inv, dropping: true);
      case CliCommandKind.update:
        return _runUpdate(inv);
    }
  }

  Future<int> _runUpdate(ParsedCliInvocation inv) async {
    final updater = CliUpdater(
      environment: _env,
      httpClient: _workerHttpClient,
    );
    final report = await updater.run(inv);
    if (inv.global.json) {
      _out.writeln(CliFormatters.encodeJson(report.toJson()));
    } else {
      for (final line in report.textLines()) {
        _out.writeln(line);
      }
    }
    return report.hasError ? exitError : exitOk;
  }

  CliSessionStore _resolveStore(CliGlobalOptions global) {
    final override = _sessionStoreOverride;
    if (override != null) return override;
    final kind = CliStoreKind.parse(global.store);
    return CliCredentialStore.resolve(
      kind: kind,
      sessionFilePath: global.sessionFile,
      environment: _env,
      operatingSystem: _operatingSystem,
      processRunner: _keychainProcessRunner,
      chmodRunner: _chmodProcessRunner,
      now: _nowProvider,
    );
  }

  _LiveClientBundle _createLiveClient({
    required Iterable<String> trustedUrls,
    String? relayUrl,
  }) {
    final allowedHosts = <String>{};
    var requireSecure = true;
    for (final raw in trustedUrls) {
      final parsed = Urls.parseUrl(raw);
      if (parsed == null || parsed.host.isEmpty) continue;
      if (!parsed.isSecure) {
        requireSecure = false;
      }
      if (parsed.hasExplicitPort) {
        allowedHosts.add('${parsed.scheme}://${parsed.host}:${parsed.port}');
      } else {
        allowedHosts.add(parsed.host);
      }
    }

    final allowedHostsList = allowedHosts.toList(growable: false);
    final effectiveRelay = (relayUrl ?? '').trim();
    HttpPolicySnapshot snapshot() => HttpPolicySnapshot(
          allowedHosts: allowedHostsList,
          requireSecure: requireSecure,
          relayBaseUrl: effectiveRelay,
        );

    final engineBuilder = _httpEngineBuilder;
    final rawEngine = engineBuilder != null
        ? engineBuilder(
            policyProvider: snapshot,
            clock: _epochSeconds,
            relayUrl: effectiveRelay.isEmpty ? null : effectiveRelay,
          )
        : (effectiveRelay.isNotEmpty
            ? RelayHttpEngine(
                policyProvider: snapshot,
                clock: _epochSeconds,
              )
            : IoHttpEngine(
                policyProvider: snapshot,
                clock: _epochSeconds,
              ));

    // 红线 #4：强制套用 HostGuardedHttpEngine + GuardedHttpEngine 双层域名与 TLS 门卫
    final guarded = GuardedHttpEngine(
      HostGuardedHttpEngine(
        rawEngine,
        allowedHosts: allowedHostsList,
        requireSecure: requireSecure,
      ),
      requireSecure: requireSecure,
    );

    final memStore = InMemorySecureStore();
    final archive = SessionArchive(
      store: memStore,
      service: 'dev.courselens.sessions',
    );
    final client = AcademicClient(
      engine: guarded,
      decoder: const CharsetTextDecoder(),
      secureStore: memStore,
      clock: _epochSeconds,
      random: SystemSecureRandom(),
    );

    return _LiveClientBundle(
      client: client,
      archive: archive,
      allowedHosts: allowedHosts,
    );
  }

  static List<StoredCookie> _mapToStoredCookies(
    Map<String, String> cookies,
    String baseUrl,
  ) {
    final parsed = Urls.parseUrl(baseUrl);
    if (parsed == null || parsed.host.isEmpty) return const <StoredCookie>[];
    return cookies.entries
        .where((e) => e.key.trim().isNotEmpty)
        .map(
          (e) => StoredCookie(
            name: e.key.trim(),
            value: e.value,
            domain: parsed.host,
            path: '/',
            hostOnly: true,
            secure: parsed.isSecure,
          ),
        )
        .toList(growable: false);
  }

  Future<Map<String, String>> _extractActiveCookies({
    required _LiveClientBundle bundle,
    required String accountKey,
    required String baseUrl,
    required String username,
    required String systemId,
    Map<String, String> seedCookies = const <String, String>{},
  }) async {
    await bundle.client.persistSession(
      SavedAccount(
        schoolId: _cliSchoolId,
        accountKey: accountKey,
        protocol: 'cli',
        baseUrl: baseUrl,
        username: username,
        systemId: systemId,
      ),
    );
    final stored = await bundle.archive.cookiesFor(_cliSchoolId, accountKey);
    final out = <String, String>{...seedCookies};
    for (final c in stored) {
      if (c.name.trim().isNotEmpty) {
        out[c.name.trim()] = c.value;
      }
    }
    return out;
  }

  static String _inferSystemId({
    required String explicitOrSaved,
    required String baseUrl,
    StudySystemProbe? probe,
  }) {
    final normalized = explicitOrSaved.trim().toUpperCase();
    if (normalized.isNotEmpty && normalized != 'AUTO') {
      final known = AcademicSystem.fromId(normalized);
      if (known != null && known != AcademicSystem.AUTO) {
        return known.id;
      }
    }
    if (probe != null && probe.systemId.trim().isNotEmpty) {
      final detected = AcademicSystem.fromId(probe.systemId.trim());
      if (detected != null && detected != AcademicSystem.AUTO) {
        return detected.id;
      }
    }
    final lowerUrl = baseUrl.toLowerCase();
    if (lowerUrl.contains('/jsxsd')) return AcademicSystem.QZ.id;
    if (lowerUrl.contains('default2.aspx')) return AcademicSystem.ZF_OLD.id;
    return AcademicSystem.ZF.id;
  }

  _LiveClientBundle _createWorkerLiveClient({
    required String workerUrl,
    required String apiKey,
    required Iterable<String> allowedHosts,
    required bool requireSecure,
  }) {
    final hostSet = <String>{
      for (final item in allowedHosts)
        if (item.trim().isNotEmpty) item.trim(),
    };
    final allowedHostsList = hostSet.toList(growable: false);
    HttpPolicySnapshot snapshot() => HttpPolicySnapshot(
          allowedHosts: allowedHostsList,
          requireSecure: requireSecure,
        );

    final rawEngine = WorkerSessionHttpEngine(
      workerBaseUrlProvider: () => workerUrl,
      apiKeyProvider: () => apiKey,
      policyProvider: snapshot,
      client: _workerHttpClient,
    );

    // 红线 #4：客户端侧同样套用 HostGuardedHttpEngine + GuardedHttpEngine 双层门卫
    final guarded = GuardedHttpEngine(
      HostGuardedHttpEngine(
        rawEngine,
        allowedHosts: allowedHostsList,
        requireSecure: requireSecure,
      ),
      requireSecure: requireSecure,
    );

    final memStore = InMemorySecureStore();
    final archive = SessionArchive(
      store: memStore,
      service: 'dev.courselens.sessions',
    );
    final client = AcademicClient(
      engine: guarded,
      decoder: const CharsetTextDecoder(),
      secureStore: memStore,
      clock: _epochSeconds,
      random: SystemSecureRandom(),
    );

    return _LiveClientBundle(
      client: client,
      archive: archive,
      allowedHosts: hostSet,
    );
  }

  ({String workerUrl, String apiKey})? _resolveActiveWorkerAuth(
    ParsedCliInvocation inv,
    CliSessionRecord? record,
  ) {
    final explicitWorker = inv.global.workerUrl?.trim();
    final envKey = _env[CliCredentialStore.envApiKey]?.trim();

    if (explicitWorker != null && explicitWorker.isNotEmpty) {
      final matchedProfile = record?.findSavedWorker(explicitWorker);
      if (matchedProfile != null) {
        final key = (envKey != null && envKey.isNotEmpty)
            ? envKey
            : matchedProfile.apiKey;
        return (
          workerUrl: WorkerSessionHttpEngine.normalizeWorkerBaseUrl(
            matchedProfile.workerUrl,
          ),
          apiKey: key,
        );
      }

      if (!explicitWorker.contains('://')) {
        throw AcademicException(
          AcademicStatus.INVALID_CREDENTIALS,
          '未找到名为 "$explicitWorker" 的已保存 Worker 网关。请运行 `courselens auth worker --list` 查看或先通过 `--url <workerUrl>` 保存。',
        );
      }

      final normalizedExplicit =
          WorkerSessionHttpEngine.normalizeWorkerBaseUrl(explicitWorker);
      String? fallbackSavedKey;
      if (record?.workerUrl != null && record!.workerUrl!.trim().isNotEmpty) {
        final normalizedRecordUrl =
            WorkerSessionHttpEngine.normalizeWorkerBaseUrl(record.workerUrl!);
        if (normalizedRecordUrl == normalizedExplicit) {
          fallbackSavedKey = record.apiKey?.trim();
        }
      }
      final rawKey =
          (envKey != null && envKey.isNotEmpty) ? envKey : fallbackSavedKey;
      if (rawKey == null || rawKey.isEmpty) {
        throw const AcademicException(
          AcademicStatus.INVALID_CREDENTIALS,
          '已指定 --worker 但未提供 API Key。请设置环境变量 COURSELENS_API_KEY，或先运行 `courselens auth worker --url <workerUrl>` 保存密钥。',
        );
      }
      return (workerUrl: normalizedExplicit, apiKey: rawKey);
    }

    final savedWorkerUrl = record?.workerUrl?.trim();
    final envWorkerUrl = _env[CliCredentialStore.envWorkerUrl]?.trim();
    final rawWorker = (savedWorkerUrl != null && savedWorkerUrl.isNotEmpty)
        ? savedWorkerUrl
        : envWorkerUrl;
    if (rawWorker == null || rawWorker.isEmpty) return null;

    final savedKey = (record?.apiKey != null && record!.apiKey!.trim().isNotEmpty)
        ? record.apiKey!.trim()
        : record?.findSavedWorker(rawWorker)?.apiKey.trim();
    final rawKey =
        (savedKey != null && savedKey.isNotEmpty) ? savedKey : envKey;
    if (rawKey == null || rawKey.isEmpty) return null;

    return (
      workerUrl: WorkerSessionHttpEngine.normalizeWorkerBaseUrl(rawWorker),
      apiKey: rawKey,
    );
  }

  Future<
      ({
        String workerUrl,
        String apiKey,
        CliSessionStore store,
        CliSessionRecord? record,
      })> _requireWorkerAuth(ParsedCliInvocation inv) async {
    if (inv.global.demo) {
      throw const CliUsageException(
        '`courselens worker` 云端网关控制命令不支持 `--demo` 离线演示模式。',
      );
    }
    final store = _resolveStore(inv.global);
    final record = await store.load();
    final auth = _resolveActiveWorkerAuth(inv, record);
    if (auth == null) {
      throw const AcademicException(
        AcademicStatus.SESSION_EXPIRED,
        '当前未绑定有状态 Cloudflare Worker 网关。请先运行 `courselens auth worker --url <https://...>`，或传入 `--worker <name|url>`。',
      );
    }
    return (
      workerUrl: auth.workerUrl,
      apiKey: auth.apiKey,
      store: store,
      record: record,
    );
  }

  static List<String> _deriveAllowedHostsFromUrl(String rawUrl) {
    final parsed = Urls.parseUrl(rawUrl);
    if (parsed == null || parsed.host.isEmpty) return const <String>[];
    if (parsed.hasExplicitPort) {
      return <String>['${parsed.scheme}://${parsed.host}:${parsed.port}'];
    }
    return <String>[parsed.host];
  }

  /// 加载并恢复真实教务会话（支持有状态 Worker API Key 托管、已保存 Cookie，或 `env` 模式下无状态账号密码即时登录）。
  Future<_AuthenticatedLiveContext> _openAuthenticatedLiveContext(
    ParsedCliInvocation inv,
  ) async {
    final store = _resolveStore(inv.global);
    final record = await store.load();
    final workerAuth = _resolveActiveWorkerAuth(inv, record);

    if (workerAuth != null) {
      final remote = await WorkerSessionHttpEngine.fetchRemoteSession(
        workerBaseUrl: workerAuth.workerUrl,
        apiKey: workerAuth.apiKey,
        offline: false,
        client: _workerHttpClient,
      );
      final effectiveBaseUrl = remote.baseUrl.isNotEmpty
          ? remote.baseUrl
          : (record?.baseUrl ?? '');
      if (effectiveBaseUrl.isEmpty) {
        throw const AcademicException(
          AcademicStatus.VALIDATION_FAILED,
          '有状态 Worker 未返回有效的教务根地址（PORTAL_URL）。',
        );
      }
      final sanitizedRemoteHosts = <String>[
        for (final item in remote.allowedHosts)
          if (item.trim().isNotEmpty &&
              !item.contains('*') &&
              !item.contains('@'))
            item.trim(),
      ];
      final effectiveHosts = <String>{
        ...sanitizedRemoteHosts,
        ..._deriveAllowedHostsFromUrl(effectiveBaseUrl),
        if (remote.casBaseUrl.isNotEmpty)
          ..._deriveAllowedHostsFromUrl(remote.casBaseUrl),
      }.toList(growable: false);
      final effectiveRequireSecure = remote.requireSecure ||
          effectiveBaseUrl.toLowerCase().startsWith('https://');
      final bundle = _createWorkerLiveClient(
        workerUrl: workerAuth.workerUrl,
        apiKey: workerAuth.apiKey,
        allowedHosts: effectiveHosts,
        requireSecure: effectiveRequireSecure,
      );
      final effectiveUsername = remote.username.isNotEmpty
          ? remote.username
          : (record?.username?.trim() ?? '');
      final accountKey =
          effectiveUsername.isNotEmpty ? effectiveUsername : _defaultAccountKey;
      final systemId = _inferSystemId(
        explicitOrSaved: (record?.systemType != null &&
                record!.systemType!.trim().isNotEmpty)
            ? record.systemType!
            : remote.systemId,
        baseUrl: effectiveBaseUrl,
      );
      await bundle.client.bindRemoteManagedSession(
        schoolId: _cliSchoolId,
        accountKey: accountKey,
        academicBaseUrl: effectiveBaseUrl,
        username: effectiveUsername,
      );
      final effectiveRecord = record ??
          CliSessionRecord(
            baseUrl: effectiveBaseUrl,
            username: effectiveUsername,
            systemType: systemId,
            workerUrl: workerAuth.workerUrl,
            apiKey: workerAuth.apiKey,
            updatedAt: _nowProvider().toUtc(),
            backendName: 'flag',
          );
      return _AuthenticatedLiveContext(
        store: store,
        record: effectiveRecord,
        client: bundle.client,
        accountKey: accountKey,
        baseUrl: effectiveBaseUrl,
        systemId: systemId,
        username: effectiveUsername,
        identity: remote.identity
            .merge(StudentIdentity(studentId: effectiveUsername)),
      );
    }

    if (record == null) {
      throw const AcademicException(
        AcademicStatus.SESSION_EXPIRED,
        '当前尚未登录教务会话。请先运行 `courselens auth login`、`courselens auth worker`、`courselens auth import-cookie`，或使用 `--demo` 体验演示模式。',
      );
    }

    final effectiveRelay = inv.global.relayUrl ?? record.relayUrl;
    final bundle = _createLiveClient(
      trustedUrls: <String>[record.baseUrl],
      relayUrl: effectiveRelay,
    );
    final recUsername = record.username;
    final accountKey = (recUsername != null && recUsername.trim().isNotEmpty)
        ? recUsername.trim()
        : _defaultAccountKey;

    var effectiveBaseUrl = record.baseUrl;
    final savedSys = record.systemType;
    var systemId = _inferSystemId(
      explicitOrSaved: savedSys ?? 'AUTO',
      baseUrl: effectiveBaseUrl,
    );
    var identity = StudentIdentity(studentId: recUsername ?? '');

    final recPassword = record.password;
    if (record.cookies.isNotEmpty) {
      final storedCookies =
          _mapToStoredCookies(record.cookies, effectiveBaseUrl);
      await bundle.archive.save(
        SavedAccount(
          schoolId: _cliSchoolId,
          accountKey: accountKey,
          protocol: 'cookie',
          baseUrl: effectiveBaseUrl,
          username: recUsername ?? '',
          systemId: systemId,
        ),
        storedCookies,
      );
      await bundle.client.restoreSavedSessions();
    } else if (recUsername != null &&
        recUsername.isNotEmpty &&
        recPassword != null &&
        recPassword.isNotEmpty) {
      // env 无状态凭据模式：仅在内存中完成单次认证，绝不落盘密码
      StudySystemProbe? probe;
      if (savedSys == null ||
          savedSys.trim().isEmpty ||
          savedSys.toLowerCase() == 'auto') {
        try {
          probe = await bundle.client.probeStudySystem(
            schoolId: _cliSchoolId,
            academicBaseUrl: effectiveBaseUrl,
          );
        } on AcademicException {
          probe = null;
        }
        if (probe != null && probe.baseUrl.trim().isNotEmpty) {
          effectiveBaseUrl = probe.baseUrl.trim();
        }
        systemId = _inferSystemId(
          explicitOrSaved: savedSys ?? 'AUTO',
          baseUrl: effectiveBaseUrl,
          probe: probe,
        );
      }

      final loginResult = await bundle.client.loginJwglxt(
        schoolId: _cliSchoolId,
        accountKey: accountKey,
        username: recUsername,
        password: recPassword,
        academicBaseUrl: effectiveBaseUrl,
      );
      if (!loginResult.isSuccess) {
        throw AcademicException(
          loginResult.status,
          loginResult.message.isEmpty
              ? '环境变量凭据登录失败 (${loginResult.status.name})'
              : loginResult.message,
        );
      }
      identity = loginResult.identity;
      effectiveBaseUrl =
          await bundle.client.activeSessionBaseUrl(_cliSchoolId, accountKey) ??
              effectiveBaseUrl;
    } else {
      throw const AcademicException(
        AcademicStatus.SESSION_EXPIRED,
        '已存会话不包含有效 Cookie。请重新执行 `courselens auth login`、`courselens auth worker` 或 `courselens auth import-cookie`。',
      );
    }

    return _AuthenticatedLiveContext(
      store: store,
      record: record,
      client: bundle.client,
      accountKey: accountKey,
      baseUrl: effectiveBaseUrl,
      systemId: systemId,
      username: recUsername ?? '',
      identity: identity,
    );
  }

  // ---------------------------------------------------------------------------
  // 1. auth status / whoami
  // ---------------------------------------------------------------------------

  Future<int> _runAuthStatus(ParsedCliInvocation inv) async {
    if (inv.global.demo) {
      final demo = await CliDemoFixtures.bootstrap(clock: _epochSeconds);
      _out.writeln(
        CliFormatters.formatAuthStatus(
          json: inv.global.json,
          demo: true,
          storeBackend: 'demo (embedded-fixture)',
          authenticated: true,
          offline: inv.offline,
          alive: inv.offline ? null : true,
          baseUrl: CliDemoFixtures.demoAcademicBase,
          systemType: AcademicSystem.QZ.id,
          username: CliDemoFixtures.demoAccountKey,
          identity: demo.identity,
          cookieCount: 2,
          relayUrl: inv.global.relayUrl,
          updatedAt: _nowProvider().toUtc(),
          message: '演示沙盒会话已就绪（离线内嵌夹具）',
        ),
      );
      return exitOk;
    }

    final store = _resolveStore(inv.global);
    final record = await store.load();
    final workerAuth = _resolveActiveWorkerAuth(inv, record);

    if (workerAuth != null) {
      final savedBaseUrl = record?.baseUrl ?? '';
      final savedSys = record?.systemType;
      var identity = StudentIdentity(studentId: record?.username ?? '');

      if (inv.offline) {
        _out.writeln(
          CliFormatters.formatAuthStatus(
            json: inv.global.json,
            demo: false,
            storeBackend: store.backendDescription,
            authenticated: true,
            offline: true,
            alive: null,
            baseUrl: savedBaseUrl.isEmpty ? null : savedBaseUrl,
            systemType: savedSys,
            username: record?.username,
            identity: identity,
            cookieCount: 0,
            relayUrl: inv.global.relayUrl ?? record?.relayUrl,
            workerUrl: workerAuth.workerUrl,
            updatedAt: record?.updatedAt,
            message: '已读取本地有状态 Worker API Key 配置（--offline 已跳过联网探活）。',
          ),
        );
        return exitOk;
      }

      var alive = false;
      var effectiveBaseUrl = savedBaseUrl;
      var effectiveSys = savedSys;
      var effectiveUser = record?.username;
      var statusMessage = '有状态 Worker 会话校验失败。';
      try {
        final remote = await WorkerSessionHttpEngine.fetchRemoteSession(
          workerBaseUrl: workerAuth.workerUrl,
          apiKey: workerAuth.apiKey,
          offline: false,
          client: _workerHttpClient,
        );
        alive = remote.alive ?? remote.authenticated;
        if (remote.baseUrl.isNotEmpty) effectiveBaseUrl = remote.baseUrl;
        if (remote.systemId.isNotEmpty) effectiveSys = remote.systemId;
        if (remote.username.isNotEmpty) effectiveUser = remote.username;
        identity = remote.identity.merge(identity);
        statusMessage = alive
            ? '有状态 Cloudflare Worker 云端会话在线有效（本地零密码、零 Cookie）。'
            : '有状态 Worker 未能建立有效教务会话。';
      } on AcademicException catch (error) {
        alive = false;
        statusMessage = error.message.isEmpty ? error.status.name : error.message;
      }

      _out.writeln(
        CliFormatters.formatAuthStatus(
          json: inv.global.json,
          demo: false,
          storeBackend: store.backendDescription,
          authenticated: true,
          offline: false,
          alive: alive,
          baseUrl: effectiveBaseUrl.isEmpty ? null : effectiveBaseUrl,
          systemType: effectiveSys,
          username: effectiveUser,
          identity: identity,
          cookieCount: 0,
          relayUrl: inv.global.relayUrl ?? record?.relayUrl,
          workerUrl: workerAuth.workerUrl,
          updatedAt: record?.updatedAt,
          message: statusMessage,
        ),
      );
      return alive ? exitOk : exitError;
    }

    if (record == null ||
        (record.cookies.isEmpty &&
            (record.username == null || record.password == null))) {
      _out.writeln(
        CliFormatters.formatAuthStatus(
          json: inv.global.json,
          demo: false,
          storeBackend: store.backendDescription,
          authenticated: false,
          offline: inv.offline,
          alive: false,
          baseUrl: record?.baseUrl,
          systemType: record?.systemType,
          username: record?.username,
          identity: const StudentIdentity(),
          cookieCount: record?.cookies.length ?? 0,
          relayUrl: inv.global.relayUrl ?? record?.relayUrl,
          updatedAt: record?.updatedAt,
          message: '未检测到活动会话，请运行 auth login、auth worker 或 auth import-cookie。',
        ),
      );
      return exitError;
    }

    final systemType = _inferSystemId(
      explicitOrSaved: record.systemType ?? 'AUTO',
      baseUrl: record.baseUrl,
    );
    var identity = StudentIdentity(studentId: record.username ?? '');

    if (inv.offline) {
      _out.writeln(
        CliFormatters.formatAuthStatus(
          json: inv.global.json,
          demo: false,
          storeBackend: store.backendDescription,
          authenticated: true,
          offline: true,
          alive: null,
          baseUrl: record.baseUrl,
          systemType: systemType,
          username: record.username,
          identity: identity,
          cookieCount: record.cookies.length,
          relayUrl: inv.global.relayUrl ?? record.relayUrl,
          updatedAt: record.updatedAt,
          message: '已读取本地会话元数据（--offline 已跳过联网探活）。',
        ),
      );
      return exitOk;
    }

    var alive = false;
    var effectiveBaseUrl = record.baseUrl;
    var statusMessage = '教务会话已过期或不可达，请重新登录。';
    try {
      if (record.cookies.isNotEmpty) {
        final bundle = _createLiveClient(
          trustedUrls: <String>[record.baseUrl],
          relayUrl: inv.global.relayUrl ?? record.relayUrl,
        );
        final accountKey = record.username ?? _defaultAccountKey;
        final adopt = await bundle.client.adoptBrowserSession(
          schoolId: _cliSchoolId,
          accountKey: accountKey,
          academicBaseUrl: record.baseUrl,
          cookies: _mapToStoredCookies(record.cookies, record.baseUrl),
          username: record.username ?? '',
        );
        if (adopt.isSuccess) {
          alive = true;
          identity = adopt.identity.merge(identity);
          effectiveBaseUrl = await bundle.client
                  .activeSessionBaseUrl(_cliSchoolId, accountKey) ??
              record.baseUrl;
          statusMessage = '会话在线探活通过。';
        } else {
          await bundle.archive.save(
            SavedAccount(
              schoolId: _cliSchoolId,
              accountKey: accountKey,
              protocol: 'cookie',
              baseUrl: record.baseUrl,
              username: record.username ?? '',
              systemId: systemType,
            ),
            _mapToStoredCookies(record.cookies, record.baseUrl),
          );
          await bundle.client.restoreSavedSessions();
          alive = await bundle.client.validateSession(
            schoolId: _cliSchoolId,
            accountKey: accountKey,
            systemId: systemType,
            username: record.username ?? '',
          );
          if (alive) {
            statusMessage = '会话在线探活通过。';
          } else if (adopt.message.isNotEmpty) {
            statusMessage = adopt.message;
          }
        }
      } else {
        final ctx = await _openAuthenticatedLiveContext(inv);
        alive = true;
        identity = ctx.identity.merge(identity);
        effectiveBaseUrl = ctx.baseUrl;
        statusMessage = '无状态环境变量凭据在线验证通过。';
      }
    } on AcademicException catch (error) {
      alive = false;
      statusMessage = error.message.isEmpty ? error.status.name : error.message;
    }

    _out.writeln(
      CliFormatters.formatAuthStatus(
        json: inv.global.json,
        demo: false,
        storeBackend: store.backendDescription,
        authenticated: true,
        offline: false,
        alive: alive,
        baseUrl: effectiveBaseUrl,
        systemType: systemType,
        username: record.username,
        identity: identity,
        cookieCount: record.cookies.length,
        relayUrl: inv.global.relayUrl ?? record.relayUrl,
        updatedAt: record.updatedAt,
        message: statusMessage,
      ),
    );
    return alive ? exitOk : exitError;
  }

  // ---------------------------------------------------------------------------
  // 2. auth login
  // ---------------------------------------------------------------------------

  Future<int> _runAuthLogin(ParsedCliInvocation inv) async {
    if (inv.global.demo) {
      final demo = await CliDemoFixtures.bootstrap(clock: _epochSeconds);
      _out.writeln(
        CliFormatters.formatAuthSaved(
          json: inv.global.json,
          title: '演示模式登录成功',
          storeBackend: 'demo (embedded-fixture)',
          baseUrl: CliDemoFixtures.demoAcademicBase,
          systemType: AcademicSystem.QZ.id,
          username: CliDemoFixtures.demoAccountKey,
          identity: demo.identity,
          cookieCount: 2,
          verified: true,
          message: '已完成演示 CAS 夹具登录（未修改任何本地真实凭据）。',
        ),
      );
      return exitOk;
    }

    final store = _resolveStore(inv.global);
    final rawUrl = inv.url!;
    final username = inv.user!;
    final casUrl = inv.casUrl;
    final password = await _resolvePassword(inv);

    final trusted = <String>[
      rawUrl,
      if (casUrl != null && casUrl.isNotEmpty) casUrl,
    ];
    final bundle = _createLiveClient(
      trustedUrls: trusted,
      relayUrl: inv.global.relayUrl,
    );

    var effectiveBaseUrl = rawUrl;
    StudySystemProbe? probe;
    if (inv.system.toLowerCase() == 'auto') {
      try {
        probe = await bundle.client.probeStudySystem(
          schoolId: _cliSchoolId,
          academicBaseUrl: rawUrl,
        );
      } on AcademicException {
        probe = null;
      }
      if (probe != null && probe.baseUrl.trim().isNotEmpty) {
        effectiveBaseUrl = probe.baseUrl.trim();
      }
    }

    final systemId = _inferSystemId(
      explicitOrSaved: inv.system,
      baseUrl: effectiveBaseUrl,
      probe: probe,
    );

    final LoginResult result;
    if (casUrl != null && casUrl.trim().isNotEmpty) {
      result = await bundle.client.loginCas(
        schoolId: _cliSchoolId,
        accountKey: username,
        username: username,
        password: password,
        casBaseUrl: casUrl.trim(),
        academicBaseUrl: effectiveBaseUrl,
      );
    } else {
      result = await bundle.client.loginJwglxt(
        schoolId: _cliSchoolId,
        accountKey: username,
        username: username,
        password: password,
        academicBaseUrl: effectiveBaseUrl,
      );
    }

    if (!result.isSuccess) {
      final msg = result.message.isNotEmpty
          ? result.message
          : '教务登录未通过 (${result.status.name})';
      return _emitFailure(
        code: result.status.name,
        message: msg,
        json: inv.global.json,
      );
    }

    final finalBaseUrl =
        await bundle.client.activeSessionBaseUrl(_cliSchoolId, username) ??
            effectiveBaseUrl;
    final cookies = await _extractActiveCookies(
      bundle: bundle,
      accountKey: username,
      baseUrl: finalBaseUrl,
      username: username,
      systemId: systemId,
    );
    if (cookies.isEmpty) {
      return _emitFailure(
        code: AcademicStatus.SESSION_EXPIRED.name,
        message: '登录流程未返回有效会话 Cookie，请改用 `auth import-cookie` 导入浏览器会话。',
        json: inv.global.json,
      );
    }

    final existingBeforeLogin = await store.load();
    final record = CliSessionRecord(
      baseUrl: finalBaseUrl,
      username: username,
      systemType: systemId,
      cookies: cookies,
      relayUrl: inv.global.relayUrl,
      savedWorkers: _effectiveSavedWorkers(existingBeforeLogin),
      updatedAt: _nowProvider().toUtc(),
      backendName: store.backendDescription,
    );
    await store.save(record);

    final identity =
        result.identity.merge(StudentIdentity(studentId: username));
    _out.writeln(
      CliFormatters.formatAuthSaved(
        json: inv.global.json,
        title: '教务登录成功',
        storeBackend: store.backendDescription,
        baseUrl: finalBaseUrl,
        systemType: systemId,
        username: username,
        identity: identity,
        cookieCount: cookies.length,
        verified: true,
        message: '会话 Cookie 已安全保存（未落盘明文密码）。',
      ),
    );
    return exitOk;
  }

  Future<String> _resolvePassword(ParsedCliInvocation inv) async {
    final stdinLine = _readStdinLine;
    final stdinAll = _readStdinAll;
    final hiddenPrompt = _readHiddenPassword;

    if (inv.passwordStdin) {
      final String? raw;
      if (stdinLine != null) {
        raw = await stdinLine();
      } else if (stdinAll != null) {
        raw = await stdinAll();
      } else {
        raw = io.stdin.readLineSync();
      }
      final trimmed = _stripTrailingLineBreaks(raw ?? '');
      if (trimmed.isEmpty) {
        throw const CliUsageException('--password-stdin 未从标准输入读取到密码内容。');
      }
      return trimmed;
    }

    final passwordEnvName = inv.passwordEnv;
    if (passwordEnvName != null) {
      final val = _env[passwordEnvName];
      if (val == null || val.isEmpty) {
        throw CliUsageException('环境变量 $passwordEnvName 未设置或为空，无法读取登录密码。');
      }
      return val;
    }

    final fallbackEnvPassword = _env[CliCredentialStore.envPassword];
    if (fallbackEnvPassword != null && fallbackEnvPassword.isNotEmpty) {
      return fallbackEnvPassword;
    }

    if (hiddenPrompt != null) {
      final prompted = await hiddenPrompt('Password: ');
      final cleaned = _stripTrailingLineBreaks(prompted ?? '');
      if (cleaned.isEmpty) {
        throw const CliUsageException('未输入登录密码，已中止登录。');
      }
      return cleaned;
    }

    throw const CliUsageException(
      '当前非交互式终端无法安全回显隐藏密码提示。请改用 `--password-stdin` 或 `--password-env <VAR>` 传入密码。',
    );
  }

  static String _stripTrailingLineBreaks(String input) {
    var end = input.length;
    while (end > 0 &&
        (input.codeUnitAt(end - 1) == 0x0A ||
            input.codeUnitAt(end - 1) == 0x0D)) {
      end--;
    }
    return input.substring(0, end);
  }

  // ---------------------------------------------------------------------------
  // 2b. auth worker (--url / --name / --list / --use / --remove)
  // ---------------------------------------------------------------------------

  static List<CliSavedWorkerProfile> _effectiveSavedWorkers(
    CliSessionRecord? record,
  ) {
    if (record == null) return const <CliSavedWorkerProfile>[];
    if (record.savedWorkers.isNotEmpty) return record.savedWorkers;
    if (record.isWorkerMode) {
      return <CliSavedWorkerProfile>[
        CliSavedWorkerProfile(
          name: CliSavedWorkerProfile.deriveDefaultName(record.workerUrl!),
          workerUrl: record.workerUrl!,
          apiKey: record.apiKey!,
          baseUrl: record.baseUrl,
          username: record.username,
          systemType: record.systemType,
          updatedAt: record.updatedAt,
        ),
      ];
    }
    return const <CliSavedWorkerProfile>[];
  }

  Future<int> _runAuthWorker(ParsedCliInvocation inv) async {
    final store = _resolveStore(inv.global);
    final existing = await store.load();
    final currentProfiles = _effectiveSavedWorkers(existing);

    if (inv.listWorkers) {
      _out.writeln(
        CliFormatters.formatSavedWorkersList(
          json: inv.global.json,
          storeBackend: store.backendDescription,
          activeWorkerUrl: existing?.workerUrl,
          workers: currentProfiles,
        ),
      );
      return exitOk;
    }

    if (inv.removeWorker != null) {
      final target = inv.removeWorker!.trim();
      final seedRecord = existing?.copyWith(savedWorkers: currentProfiles);
      final matched = seedRecord?.findSavedWorker(target);
      if (matched == null) {
        return _emitFailure(
          code: 'NOT_FOUND',
          message: '未找到别名或地址匹配 "$target" 的已保存 Worker 网关。',
          json: inv.global.json,
        );
      }
      final remaining = seedRecord!.removeSavedWorker(target);
      final currentRecord = existing!;
      final activeWasRemoved = currentRecord.workerUrl != null &&
          currentRecord.workerUrl!.trim().toLowerCase() ==
              matched.workerUrl.trim().toLowerCase();

      String? nextActiveUrl =
          activeWasRemoved ? null : currentRecord.workerUrl;
      String? nextActiveKey =
          activeWasRemoved ? null : currentRecord.apiKey;
      var nextBaseUrl = activeWasRemoved ? '' : currentRecord.baseUrl;
      var nextUsername = activeWasRemoved ? null : currentRecord.username;
      var nextSystem = activeWasRemoved ? null : currentRecord.systemType;

      if (activeWasRemoved &&
          remaining.isNotEmpty &&
          currentRecord.cookies.isEmpty) {
        final fallback = remaining.first;
        nextActiveUrl = fallback.workerUrl;
        nextActiveKey = fallback.apiKey;
        nextBaseUrl = fallback.baseUrl;
        nextUsername = fallback.username;
        nextSystem = fallback.systemType;
      }

      if (remaining.isEmpty &&
          nextBaseUrl.isEmpty &&
          currentRecord.cookies.isEmpty &&
          nextActiveUrl == null) {
        await store.clear();
      } else {
        await store.save(
          CliSessionRecord(
            baseUrl: nextBaseUrl,
            username: nextUsername,
            systemType: nextSystem,
            cookies: currentRecord.cookies,
            relayUrl: currentRecord.relayUrl,
            workerUrl: nextActiveUrl,
            apiKey: nextActiveKey,
            savedWorkers: remaining,
            updatedAt: _nowProvider().toUtc(),
            backendName: store.backendDescription,
          ),
        );
      }

      _out.writeln(
        CliFormatters.formatSavedWorkersList(
          json: inv.global.json,
          storeBackend: store.backendDescription,
          activeWorkerUrl: nextActiveUrl,
          workers: remaining,
        ),
      );
      return exitOk;
    }

    if (inv.useWorker != null) {
      final target = inv.useWorker!.trim();
      final seedRecord = existing?.copyWith(savedWorkers: currentProfiles);
      final matched = seedRecord?.findSavedWorker(target);
      if (matched == null) {
        return _emitFailure(
          code: 'NOT_FOUND',
          message:
              '未找到名为或地址为 "$target" 的已保存 Worker 网关。运行 `courselens auth worker --list` 查看全部已存网关。',
          json: inv.global.json,
        );
      }

      var verifiedBaseUrl = matched.baseUrl;
      var systemId = matched.systemType ?? 'AUTO';
      var username = matched.username;
      var identity = StudentIdentity(studentId: username ?? '');

      if (!inv.noVerify) {
        final remote = await WorkerSessionHttpEngine.fetchRemoteSession(
          workerBaseUrl: matched.workerUrl,
          apiKey: matched.apiKey,
          offline: false,
          client: _workerHttpClient,
        );
        if (!remote.ok || remote.alive == false) {
          return _emitFailure(
            code: AcademicStatus.SESSION_EXPIRED.name,
            message: '目标 Worker (${matched.name}) 在线核验未通过，可追加 --no-verify 仅切换激活配置。',
            json: inv.global.json,
          );
        }
        verifiedBaseUrl = remote.baseUrl;
        systemId = remote.systemId.isNotEmpty ? remote.systemId : 'ZF';
        username = remote.username.isNotEmpty
            ? remote.username
            : (remote.identity.studentId.isNotEmpty
                ? remote.identity.studentId
                : username);
        identity = remote.identity;
      }

      final updatedEntry = CliSavedWorkerProfile(
        name: matched.name,
        workerUrl: matched.workerUrl,
        apiKey: matched.apiKey,
        baseUrl: verifiedBaseUrl,
        username: username,
        systemType: systemId == 'AUTO' ? null : systemId,
        updatedAt: _nowProvider().toUtc(),
      );
      final nextSaved = seedRecord!.upsertSavedWorker(updatedEntry);
      final nextRecord = CliSessionRecord(
        baseUrl: verifiedBaseUrl,
        username: username,
        systemType: systemId == 'AUTO' ? null : systemId,
        workerUrl: matched.workerUrl,
        apiKey: matched.apiKey,
        savedWorkers: nextSaved,
        updatedAt: _nowProvider().toUtc(),
        backendName: store.backendDescription,
      );
      await store.save(nextRecord);

      _out.writeln(
        CliFormatters.formatAuthSaved(
          json: inv.global.json,
          title: '已切换激活 Worker 网关 (${matched.name})',
          storeBackend: store.backendDescription,
          baseUrl: verifiedBaseUrl,
          systemType: systemId,
          username: username,
          identity: identity,
          cookieCount: 0,
          verified: !inv.noVerify,
          workerUrl: matched.workerUrl,
          message: '当前默认网关已切换为 ${matched.name} (${matched.keyHint})。',
        ),
      );
      return exitOk;
    }

    final workerUrl = WorkerSessionHttpEngine.normalizeWorkerBaseUrl(inv.url!);
    final seedRecord = (existing ??
            CliSessionRecord(
              baseUrl: '',
              savedWorkers: currentProfiles,
              updatedAt: _nowProvider().toUtc(),
            ))
        .copyWith(savedWorkers: currentProfiles);
    final existingMatched = seedRecord.findSavedWorker(workerUrl);

    final hasExplicitKeySource = inv.apiKeyStdin ||
        inv.apiKeyEnv != null ||
        ((_env[CliCredentialStore.envApiKey] ?? '').trim().isNotEmpty);
    final apiKey = (!hasExplicitKeySource && existingMatched != null)
        ? existingMatched.apiKey
        : await _resolveApiKey(inv);

    var verifiedBaseUrl = existingMatched?.baseUrl ?? '';
    var systemId = existingMatched?.systemType ?? 'AUTO';
    String? username = existingMatched?.username;
    var identity = const StudentIdentity();

    if (!inv.noVerify) {
      final remote = await WorkerSessionHttpEngine.fetchRemoteSession(
        workerBaseUrl: workerUrl,
        apiKey: apiKey,
        offline: false,
        client: _workerHttpClient,
      );
      if (!remote.ok || remote.alive == false) {
        return _emitFailure(
          code: AcademicStatus.SESSION_EXPIRED.name,
          message: '有状态 Worker 在线核验未通过，请检查 Worker Secrets 中的教务账密与地址配置（或使用 --no-verify 仅预先保存网关）。',
          json: inv.global.json,
        );
      }
      verifiedBaseUrl = remote.baseUrl;
      systemId = remote.systemId.isNotEmpty ? remote.systemId : 'ZF';
      username = remote.username.isNotEmpty
          ? remote.username
          : (remote.identity.studentId.isNotEmpty
              ? remote.identity.studentId
              : null);
      identity = remote.identity;
    }

    final profileName = (inv.name != null && inv.name!.trim().isNotEmpty)
        ? inv.name!.trim()
        : (existingMatched?.name ??
            CliSavedWorkerProfile.deriveDefaultName(workerUrl));
    final profile = CliSavedWorkerProfile(
      name: profileName,
      workerUrl: workerUrl,
      apiKey: apiKey,
      baseUrl: verifiedBaseUrl,
      username: username,
      systemType: systemId == 'AUTO' ? null : systemId,
      updatedAt: _nowProvider().toUtc(),
    );
    final nextSaved = seedRecord.upsertSavedWorker(profile);

    final record = CliSessionRecord(
      baseUrl: verifiedBaseUrl,
      username: username,
      systemType: systemId == 'AUTO' ? null : systemId,
      workerUrl: workerUrl,
      apiKey: apiKey,
      savedWorkers: nextSaved,
      updatedAt: _nowProvider().toUtc(),
      backendName: store.backendDescription,
    );
    await store.save(record);

    _out.writeln(
      CliFormatters.formatAuthSaved(
        json: inv.global.json,
        title: '有状态 Worker API Key 绑定成功 ($profileName)',
        storeBackend: store.backendDescription,
        baseUrl: verifiedBaseUrl,
        systemType: systemId,
        username: username,
        identity: identity,
        cookieCount: 0,
        verified: !inv.noVerify,
        workerUrl: workerUrl,
        message: inv.noVerify
            ? 'Worker 网关 "$profileName" (${profile.keyHint}) 已安全保存（按 --no-verify 跳过联网探活，本地零密码、零 Cookie）。'
            : 'Worker 网关 "$profileName" (${profile.keyHint}) 已通过在线核验并安全保存（教务会话由云端 Durable Object 托管）。',
      ),
    );
    return exitOk;
  }

  Future<String> _resolveApiKey(ParsedCliInvocation inv) async {
    final stdinLine = _readStdinLine;
    final stdinAll = _readStdinAll;
    final hiddenPrompt = _readHiddenPassword;

    if (inv.apiKeyStdin) {
      final String? raw;
      if (stdinLine != null) {
        raw = await stdinLine();
      } else if (stdinAll != null) {
        raw = await stdinAll();
      } else {
        raw = io.stdin.readLineSync();
      }
      final trimmed = _stripTrailingLineBreaks(raw ?? '').trim();
      if (trimmed.isEmpty) {
        throw const CliUsageException('--api-key-stdin 未从标准输入读取到 API Key 内容。');
      }
      return trimmed;
    }

    final apiKeyEnvName = inv.apiKeyEnv;
    if (apiKeyEnvName != null) {
      final val = _env[apiKeyEnvName]?.trim();
      if (val == null || val.isEmpty) {
        throw CliUsageException('环境变量 $apiKeyEnvName 未设置或为空，无法读取 Worker API Key。');
      }
      return val;
    }

    final fallbackEnvKey = _env[CliCredentialStore.envApiKey]?.trim();
    if (fallbackEnvKey != null && fallbackEnvKey.isNotEmpty) {
      return fallbackEnvKey;
    }

    if (hiddenPrompt != null) {
      final prompted = await hiddenPrompt('Worker API Key: ');
      final cleaned = _stripTrailingLineBreaks(prompted ?? '').trim();
      if (cleaned.isEmpty) {
        throw const CliUsageException('未输入 Worker API Key，已中止绑定。');
      }
      return cleaned;
    }

    throw const CliUsageException(
      '当前非交互式终端无法安全回显隐藏密钥提示。请改用 `--api-key-stdin`、`--api-key-env <VAR>` 或环境变量 `COURSELENS_API_KEY`。',
    );
  }

  // ---------------------------------------------------------------------------
  // 3. auth import-cookie
  // ---------------------------------------------------------------------------

  Future<int> _runAuthImportCookie(ParsedCliInvocation inv) async {
    final store = _resolveStore(inv.global);
    final rawUrl = inv.url!;
    final targetUri = Uri.parse(rawUrl);

    String? cookieInput = inv.cookie;
    String? harInput;

    final stdinAll = _readStdinAll;
    final stdinLine = _readStdinLine;
    final harFilePath = inv.harPath;

    if (inv.cookieStdin) {
      if (stdinAll != null) {
        cookieInput = await stdinAll();
      } else if (stdinLine != null) {
        cookieInput = await stdinLine() ?? '';
      } else {
        cookieInput =
            await io.stdin.transform(const io.SystemEncoding().decoder).join();
      }
      if (cookieInput.trim().isEmpty) {
        throw const CliUsageException('--cookie-stdin 未从标准输入读取到任何 Cookie 内容。');
      }
    } else if (harFilePath != null) {
      final file = io.File(harFilePath);
      if (!await file.exists()) {
        throw CliUsageException('找不到指定的 HAR 文件：$harFilePath');
      }
      harInput = await file.readAsString();
    }

    final extracted = CookieHarParser.extract(
      cookieHeader: cookieInput,
      harContent: harInput,
      targetBaseUri: targetUri,
    );
    if (extracted.isEmpty) {
      throw CliUsageException(
        '未能从输入源中提取出适用于 ${targetUri.host} 的有效会话 Cookie。',
      );
    }

    var finalBaseUrl = rawUrl;
    var systemId = _inferSystemId(
      explicitOrSaved: inv.system,
      baseUrl: rawUrl,
    );
    var identity = StudentIdentity(studentId: inv.user ?? '');
    var mergedCookies = Map<String, String>.from(extracted);
    var username = inv.user;

    if (!inv.noVerify) {
      final bundle = _createLiveClient(
        trustedUrls: <String>[rawUrl],
        relayUrl: inv.global.relayUrl,
      );
      StudySystemProbe? probe;
      if (inv.system.toLowerCase() == 'auto') {
        try {
          probe = await bundle.client.probeStudySystem(
            schoolId: _cliSchoolId,
            academicBaseUrl: rawUrl,
          );
        } on AcademicException {
          probe = null;
        }
        if (probe != null && probe.baseUrl.trim().isNotEmpty) {
          finalBaseUrl = probe.baseUrl.trim();
        }
        systemId = _inferSystemId(
          explicitOrSaved: inv.system,
          baseUrl: finalBaseUrl,
          probe: probe,
        );
      }

      final accountKey = (username != null && username.isNotEmpty)
          ? username
          : _defaultAccountKey;
      final adopt = await bundle.client.adoptBrowserSession(
        schoolId: _cliSchoolId,
        accountKey: accountKey,
        academicBaseUrl: finalBaseUrl,
        cookies: _mapToStoredCookies(extracted, finalBaseUrl),
        username: username ?? '',
      );
      if (!adopt.isSuccess && !adopt.isProvisional) {
        return _emitFailure(
          code: adopt.status.name,
          message: adopt.message.isEmpty
              ? '导入的 Cookie 在线核验未通过 (${adopt.status.name})，若需离线保存请追加 --no-verify。'
              : adopt.message,
          json: inv.global.json,
        );
      }

      identity = adopt.identity.merge(identity);
      if ((username == null || username.isEmpty) &&
          identity.studentId.isNotEmpty) {
        username = identity.studentId;
      }
      finalBaseUrl =
          await bundle.client.activeSessionBaseUrl(_cliSchoolId, accountKey) ??
              finalBaseUrl;
      mergedCookies = await _extractActiveCookies(
        bundle: bundle,
        accountKey: accountKey,
        baseUrl: finalBaseUrl,
        username: username ?? '',
        systemId: systemId,
        seedCookies: extracted,
      );
    }

    final existingBeforeImport = await store.load();
    final record = CliSessionRecord(
      baseUrl: finalBaseUrl,
      username: username,
      systemType: systemId,
      cookies: mergedCookies,
      relayUrl: inv.global.relayUrl,
      savedWorkers: _effectiveSavedWorkers(existingBeforeImport),
      updatedAt: _nowProvider().toUtc(),
      backendName: store.backendDescription,
    );
    await store.save(record);

    _out.writeln(
      CliFormatters.formatAuthSaved(
        json: inv.global.json,
        title: 'Cookie 会话导入成功',
        storeBackend: store.backendDescription,
        baseUrl: finalBaseUrl,
        systemType: systemId,
        username: username,
        identity: identity,
        cookieCount: mergedCookies.length,
        verified: !inv.noVerify,
        message: inv.noVerify
            ? 'Cookie 已保存（按 --no-verify 跳过联网探活）。'
            : 'Cookie 已通过在线核验并安全保存。',
      ),
    );
    return exitOk;
  }

  // ---------------------------------------------------------------------------
  // 4. auth logout (Redline #5: session.retire() + store.clear() / --keep-workers)
  // ---------------------------------------------------------------------------

  Future<int> _runAuthLogout(ParsedCliInvocation inv) async {
    if (inv.global.demo) {
      final demoSession = AccountSession(
        key: const SessionKey(
          CliDemoFixtures.demoSchoolId,
          CliDemoFixtures.demoAccountKey,
        ),
        baseUrl: CliDemoFixtures.demoAcademicBase,
        clock: _epochSeconds,
      );
      await demoSession.retire();
      _onSessionRetired?.call(demoSession);
      _out.writeln(
        CliFormatters.formatAuthLogout(
          json: inv.global.json,
          storeBackend: 'demo (embedded-fixture)',
          sessionRetired: demoSession.isRetired,
          message: '演示会话已封口退役。',
        ),
      );
      return exitOk;
    }

    final store = _resolveStore(inv.global);
    final existing = await store.load();
    var retired = false;

    if (existing != null) {
      final accountKey = existing.username ?? _defaultAccountKey;
      final effectiveBaseUrl = existing.baseUrl.isNotEmpty
          ? existing.baseUrl
          : (existing.workerUrl ?? 'https://localhost');
      final session = AccountSession(
        key: SessionKey(_cliSchoolId, accountKey),
        baseUrl: effectiveBaseUrl,
        clock: _epochSeconds,
      );
      final storedCookies =
          _mapToStoredCookies(existing.cookies, effectiveBaseUrl);
      if (storedCookies.isNotEmpty) {
        await session.cookies.restore(storedCookies);
      }
      // 红线 #5：显式调用 session.retire() 递增 epoch 并永久封口 CookieJar
      await session.retire();
      retired = session.isRetired;
      _onSessionRetired?.call(session);

      if (!existing.isWorkerMode && existing.baseUrl.isNotEmpty) {
        final bundle = _createLiveClient(
          trustedUrls: <String>[existing.baseUrl],
          relayUrl: inv.global.relayUrl ?? existing.relayUrl,
        );
        await bundle.client.clearAll();
      }
    } else {
      final emptySession = AccountSession(
        key: const SessionKey(_cliSchoolId, _defaultAccountKey),
        baseUrl: 'https://localhost',
        clock: _epochSeconds,
      );
      await emptySession.retire();
      retired = emptySession.isRetired;
      _onSessionRetired?.call(emptySession);
    }

    final preservedWorkers =
        inv.keepWorkers ? _effectiveSavedWorkers(existing) : const <CliSavedWorkerProfile>[];
    if (inv.keepWorkers && preservedWorkers.isNotEmpty) {
      await store.save(
        CliSessionRecord(
          baseUrl: '',
          savedWorkers: preservedWorkers,
          updatedAt: _nowProvider().toUtc(),
          backendName: store.backendDescription,
        ),
      );
    } else {
      await store.clear();
    }

    _out.writeln(
      CliFormatters.formatAuthLogout(
        json: inv.global.json,
        storeBackend: store.backendDescription,
        sessionRetired: retired,
        message: (inv.keepWorkers && preservedWorkers.isNotEmpty)
            ? '当前活跃会话已封口退出，已保留 ${preservedWorkers.length} 个已保存 Worker 网关（可通过 `auth worker --use` 一键重连）。'
            : (existing?.isWorkerMode == true
                ? '本机已存的 Worker API Key 记录已彻底清除（云端共享教务会话保持在线，不影响其他设备）。'
                : '本地持久化会话与内存 Cookie 容器已彻底清除。'),
      ),
    );
    return exitOk;
  }

  // ---------------------------------------------------------------------------
  // 4b. worker <tasks | push-cookies | webhook | monitor>
  // ---------------------------------------------------------------------------

  Future<int> _runWorkerTasksList(ParsedCliInvocation inv) async {
    final auth = await _requireWorkerAuth(inv);
    final snapshot = await WorkerSessionHttpEngine.fetchCloudTasks(
      workerBaseUrl: auth.workerUrl,
      apiKey: auth.apiKey,
      client: _workerHttpClient,
    );
    _out.writeln(
      CliFormatters.formatCloudTasksList(
        json: inv.global.json,
        workerUrl: auth.workerUrl,
        snapshot: snapshot,
      ),
    );
    return exitOk;
  }

  Future<int> _runWorkerTasksShow(ParsedCliInvocation inv) async {
    final auth = await _requireWorkerAuth(inv);
    final detail = await WorkerSessionHttpEngine.fetchCloudTaskDetail(
      workerBaseUrl: auth.workerUrl,
      apiKey: auth.apiKey,
      taskId: inv.taskId!,
      client: _workerHttpClient,
    );
    _out.writeln(
      CliFormatters.formatCloudTaskDetail(
        json: inv.global.json,
        workerUrl: auth.workerUrl,
        detail: detail,
      ),
    );
    return exitOk;
  }

  Future<int> _runWorkerTasksToggle(
    ParsedCliInvocation inv, {
    required bool enabled,
  }) async {
    final auth = await _requireWorkerAuth(inv);
    final patch = <String, Object?>{
      'enabled': enabled,
      'intervalSec': ?inv.intervalSec,
      if (inv.resetBaseline) 'resetBaseline': true,
    };
    final detail = await WorkerSessionHttpEngine.patchCloudTask(
      workerBaseUrl: auth.workerUrl,
      apiKey: auth.apiKey,
      taskId: inv.taskId!,
      patch: patch,
      client: _workerHttpClient,
    );
    _out.writeln(
      CliFormatters.formatCloudTaskDetail(
        json: inv.global.json,
        workerUrl: auth.workerUrl,
        detail: detail,
        heading: enabled ? '已开启云端任务' : '已关闭云端任务',
      ),
    );
    return exitOk;
  }

  Future<int> _runWorkerTasksRun(ParsedCliInvocation inv) async {
    final auth = await _requireWorkerAuth(inv);
    final tid = inv.taskId!.trim();
    final detail = await WorkerSessionHttpEngine.runCloudTask(
      workerBaseUrl: auth.workerUrl,
      apiKey: auth.apiKey,
      taskId: tid,
      confirmed: inv.confirm,
      client: _workerHttpClient,
    );
    _out.writeln(
      CliFormatters.formatCloudTaskDetail(
        json: inv.global.json,
        workerUrl: auth.workerUrl,
        detail: detail,
        heading: '云端任务单次执行完成',
      ),
    );
    return exitOk;
  }

  Future<int> _runWorkerTasksDelete(ParsedCliInvocation inv) async {
    final auth = await _requireWorkerAuth(inv);
    await WorkerSessionHttpEngine.deleteCloudTask(
      workerBaseUrl: auth.workerUrl,
      apiKey: auth.apiKey,
      taskId: inv.taskId!,
      client: _workerHttpClient,
    );
    final snapshot = await WorkerSessionHttpEngine.fetchCloudTasks(
      workerBaseUrl: auth.workerUrl,
      apiKey: auth.apiKey,
      client: _workerHttpClient,
    );
    _out.writeln(
      CliFormatters.formatCloudTasksList(
        json: inv.global.json,
        workerUrl: auth.workerUrl,
        snapshot: snapshot,
      ),
    );
    return exitOk;
  }

  Future<int> _runWorkerPushCookies(ParsedCliInvocation inv) async {
    final auth = await _requireWorkerAuth(inv);
    String? cookieInput = inv.cookie;
    String? harInput;

    if (inv.cookieStdin) {
      if (_readStdinAll != null) {
        cookieInput = await _readStdinAll();
      } else if (_readStdinLine != null) {
        cookieInput = await _readStdinLine() ?? '';
      } else {
        cookieInput =
            await io.stdin.transform(const io.SystemEncoding().decoder).join();
      }
      if (cookieInput.trim().isEmpty) {
        throw const CliUsageException('--cookie-stdin 未从标准输入读取到任何 Cookie 内容。');
      }
    } else if (inv.harPath != null) {
      final file = io.File(inv.harPath!);
      if (!await file.exists()) {
        throw CliUsageException('找不到指定的 HAR 文件：${inv.harPath}');
      }
      harInput = await file.readAsString();
    }

    var effectivePortalUrl = (inv.url ?? '').trim();
    if (effectivePortalUrl.isEmpty) {
      final remote = await WorkerSessionHttpEngine.fetchRemoteSession(
        workerBaseUrl: auth.workerUrl,
        apiKey: auth.apiKey,
        offline: true,
        client: _workerHttpClient,
      );
      effectivePortalUrl = remote.baseUrl.trim();
    }
    if (effectivePortalUrl.isEmpty) {
      throw const CliUsageException(
        '云端 Worker 尚未配置 PORTAL_URL，请追加 `--url <portalUrl>` 指定教务域名以便精确过滤 Cookie。',
      );
    }

    final extracted = CookieHarParser.extract(
      cookieHeader: cookieInput,
      harContent: harInput,
      targetBaseUri: Uri.parse(effectivePortalUrl),
    );
    if (extracted.isEmpty) {
      throw CliUsageException(
        '未能从输入源中提取出适用于 $effectivePortalUrl 的有效会话 Cookie。',
      );
    }

    final remote = await WorkerSessionHttpEngine.pushSessionCookies(
      workerBaseUrl: auth.workerUrl,
      apiKey: auth.apiKey,
      cookies: extracted,
      portalUrl: effectivePortalUrl,
      systemId: inv.system.toLowerCase() == 'auto' ? null : inv.system,
      username: inv.user,
      keepaliveIntervalSec: inv.intervalSec,
      client: _workerHttpClient,
    );

    _out.writeln(
      CliFormatters.formatAuthSaved(
        json: inv.global.json,
        title: '云端 Worker Cookie 动态注入成功',
        storeBackend: auth.store.backendDescription,
        baseUrl: remote.baseUrl.isNotEmpty ? remote.baseUrl : effectivePortalUrl,
        systemType: remote.systemId.isNotEmpty ? remote.systemId : 'ZF',
        username: remote.username.isNotEmpty ? remote.username : inv.user,
        identity: remote.identity,
        cookieCount: remote.injectedCookieCount ?? extracted.length,
        verified: remote.alive == true,
        workerUrl: auth.workerUrl,
        message: '已将 ${remote.injectedCookieCount ?? extracted.length} 项会话 Cookie AES-GCM 加密写入云端 Durable Object。',
      ),
    );
    return exitOk;
  }

  Future<int> _runWorkerWebhookStatus(ParsedCliInvocation inv) async {
    final auth = await _requireWorkerAuth(inv);
    final config = await WorkerSessionHttpEngine.fetchWebhookConfig(
      workerBaseUrl: auth.workerUrl,
      apiKey: auth.apiKey,
      client: _workerHttpClient,
    );
    _out.writeln(
      CliFormatters.formatWorkerWebhookConfig(
        json: inv.global.json,
        workerUrl: auth.workerUrl,
        config: config,
      ),
    );
    return exitOk;
  }

  Future<int> _runWorkerWebhookSet(ParsedCliInvocation inv) async {
    final auth = await _requireWorkerAuth(inv);
    String? secret;
    if (inv.secretStdin) {
      final String? raw;
      if (_readStdinLine != null) {
        raw = await _readStdinLine();
      } else if (_readStdinAll != null) {
        raw = await _readStdinAll();
      } else {
        raw = io.stdin.readLineSync();
      }
      final cleaned = _stripTrailingLineBreaks(raw ?? '').trim();
      if (cleaned.isEmpty) {
        throw const CliUsageException('--secret-stdin 未读取到 Webhook 签名密钥。');
      }
      secret = cleaned;
    } else if (inv.secretEnv != null) {
      final val = _env[inv.secretEnv!]?.trim();
      if (val == null || val.isEmpty) {
        throw CliUsageException('环境变量 ${inv.secretEnv} 未设置或为空。');
      }
      secret = val;
    }

    final config = await WorkerSessionHttpEngine.saveWebhookConfig(
      workerBaseUrl: auth.workerUrl,
      apiKey: auth.apiKey,
      payload: <String, Object?>{
        'enabled': true,
        'url': inv.url!.trim(),
        'provider': inv.webhookProvider ?? 'auto',
        'secret': ?secret,
        'telegramChatId': ?inv.chatId,
      },
      client: _workerHttpClient,
    );
    _out.writeln(
      CliFormatters.formatWorkerWebhookConfig(
        json: inv.global.json,
        workerUrl: auth.workerUrl,
        config: config,
        heading: '已保存云端 Webhook 推送通知配置',
      ),
    );
    return exitOk;
  }

  Future<int> _runWorkerWebhookTest(ParsedCliInvocation inv) async {
    final auth = await _requireWorkerAuth(inv);
    final config = await WorkerSessionHttpEngine.testWebhook(
      workerBaseUrl: auth.workerUrl,
      apiKey: auth.apiKey,
      client: _workerHttpClient,
    );
    _out.writeln(
      CliFormatters.formatWorkerWebhookConfig(
        json: inv.global.json,
        workerUrl: auth.workerUrl,
        config: config,
        heading: '云端 Webhook 测试消息已发送',
      ),
    );
    return exitOk;
  }

  Future<int> _runWorkerWebhookClear(ParsedCliInvocation inv) async {
    final auth = await _requireWorkerAuth(inv);
    final config = await WorkerSessionHttpEngine.deleteWebhookConfig(
      workerBaseUrl: auth.workerUrl,
      apiKey: auth.apiKey,
      client: _workerHttpClient,
    );
    _out.writeln(
      CliFormatters.formatWorkerWebhookConfig(
        json: inv.global.json,
        workerUrl: auth.workerUrl,
        config: config,
        heading: '已清除云端 Webhook 配置',
      ),
    );
    return exitOk;
  }

  Future<int> _runWorkerMonitorStatus(ParsedCliInvocation inv) async {
    final auth = await _requireWorkerAuth(inv);
    final status = await WorkerSessionHttpEngine.fetchMonitorStatus(
      workerBaseUrl: auth.workerUrl,
      apiKey: auth.apiKey,
      client: _workerHttpClient,
    );
    _out.writeln(
      CliFormatters.formatWorkerMonitorStatus(
        json: inv.global.json,
        workerUrl: auth.workerUrl,
        status: status,
      ),
    );
    return exitOk;
  }

  Future<int> _runWorkerMonitorSet(ParsedCliInvocation inv) async {
    final auth = await _requireWorkerAuth(inv);
    final targetsNeither =
        inv.monitorGrades == null && inv.monitorExams == null;
    final includeGrades = inv.monitorGrades != null ||
        (targetsNeither && (inv.intervalSec != null || inv.resetBaseline));
    final includeExams = inv.monitorExams != null ||
        (targetsNeither && (inv.intervalSec != null || inv.resetBaseline));
    final payload = <String, Object?>{
      if (includeGrades)
        'grades': <String, Object?>{
          'enabled': ?inv.monitorGrades,
          'intervalSec': ?inv.intervalSec,
          if (inv.resetBaseline) 'resetBaseline': true,
        },
      if (includeExams)
        'exams': <String, Object?>{
          'enabled': ?inv.monitorExams,
          'intervalSec': ?inv.intervalSec,
          if (inv.resetBaseline) 'resetBaseline': true,
        },
    };
    final status = await WorkerSessionHttpEngine.saveMonitorConfig(
      workerBaseUrl: auth.workerUrl,
      apiKey: auth.apiKey,
      payload: payload,
      client: _workerHttpClient,
    );
    _out.writeln(
      CliFormatters.formatWorkerMonitorStatus(
        json: inv.global.json,
        workerUrl: auth.workerUrl,
        status: status,
        heading: '已更新云端成绩/考试巡检配置',
      ),
    );
    return exitOk;
  }

  Future<int> _runWorkerMonitorCheck(ParsedCliInvocation inv) async {
    final auth = await _requireWorkerAuth(inv);
    final status = await WorkerSessionHttpEngine.runMonitorCheck(
      workerBaseUrl: auth.workerUrl,
      apiKey: auth.apiKey,
      kind: inv.monitorKind,
      client: _workerHttpClient,
    );
    _out.writeln(
      CliFormatters.formatWorkerMonitorStatus(
        json: inv.global.json,
        workerUrl: auth.workerUrl,
        status: status,
        heading: '云端成绩/考试即时巡检完成',
      ),
    );
    return exitOk;
  }

  // ---------------------------------------------------------------------------
  // 5. today [--date YYYY-MM-DD]
  // ---------------------------------------------------------------------------

  Future<int> _runToday(ParsedCliInvocation inv) async {
    final now = _nowProvider();
    final (year, month, day) =
        inv.parsedDate ?? (now.year, now.month, now.day);
    final todayStr = _formatIsoDate(year, month, day);
    final todayEpochDays = CivilDate.daysFromCivil(year, month, day);
    final weekday = _isoDayOfWeek(todayEpochDays);

    final tmrEpochDays = todayEpochDays + 1;
    final (tmrY, tmrM, tmrD) = CivilDate.civilFromDays(tmrEpochDays);
    final tomorrowStr = _formatIsoDate(tmrY, tmrM, tmrD);
    final tomorrowWeekday = _isoDayOfWeek(tmrEpochDays);

    late final Schedule schedule;
    late final List<ExamEntry> exams;
    late final List<PeriodTime> periodTimes;
    late final String effectiveTerm;
    int? currentWeek;
    int? tomorrowWeek;

    if (inv.global.demo) {
      final demo = await CliDemoFixtures.bootstrap(clock: _epochSeconds);
      schedule = demo.schedule;
      exams = demo.exams;
      periodTimes = demo.client.qustSifangLaoshanPeriodTimes();
      effectiveTerm = inv.global.term ?? _inferTermForDate(year, month, day);
      final semesterStart = _resolveSemesterStart(
        termId: inv.global.term,
        year: year,
        month: month,
        day: day,
      );
      final maxWeek = _computeTotalWeeks(schedule.entries);
      currentWeek = _weekNumberFor(
        semesterStart,
        year: year,
        month: month,
        day: day,
        maxWeek: maxWeek,
      );
      tomorrowWeek = _weekNumberFor(
        semesterStart,
        year: tmrY,
        month: tmrM,
        day: tmrD,
        maxWeek: maxWeek,
      );
    } else {
      final ctx = await _openAuthenticatedLiveContext(inv);
      final termOverride = inv.global.term ?? '';
      StudyCatalog? catalog;
      try {
        catalog = await ctx.client.loadStudyCatalog(
          schoolId: _cliSchoolId,
          accountKey: ctx.accountKey,
          systemId: ctx.systemId,
          username: ctx.username,
        );
      } on AcademicException {
        catalog = null;
      }

      schedule = await ctx.client.loadStudyScheduleBundle(
        schoolId: _cliSchoolId,
        accountKey: ctx.accountKey,
        systemId: ctx.systemId,
        username: ctx.username,
        termId: termOverride,
      );
      effectiveTerm = termOverride.isNotEmpty
          ? termOverride
          : (schedule.termId.isNotEmpty
              ? schedule.termId
              : (catalog != null && catalog.currentTerm.id.isNotEmpty
                  ? catalog.currentTerm.id
                  : _inferTermForDate(year, month, day)));
      exams = await ctx.client.fetchExams(
        schoolId: _cliSchoolId,
        accountKey: ctx.accountKey,
        systemId: ctx.systemId,
        username: ctx.username,
        termId: termOverride.isNotEmpty ? termOverride : null,
        allTerms: termOverride.isEmpty,
      );
      periodTimes = await _loadPeriodTimesOrPreset(ctx, effectiveTerm);

      final maxWeek = catalog?.totalWeeks ?? _computeTotalWeeks(schedule.entries);
      final semesterStart = (inv.parsedDate == null && catalog?.semesterStart != null)
          ? catalog!.semesterStart!
          : _resolveSemesterStart(
              termId: effectiveTerm,
              year: year,
              month: month,
              day: day,
              serverCurrentWeek:
                  inv.parsedDate == null ? catalog?.currentWeek : null,
            );
      currentWeek = _weekNumberFor(
        semesterStart,
        year: year,
        month: month,
        day: day,
        maxWeek: maxWeek,
      );
      tomorrowWeek = _weekNumberFor(
        semesterStart,
        year: tmrY,
        month: tmrM,
        day: tmrD,
        maxWeek: maxWeek,
      );
    }

    final todayClasses = _filterDailyClasses(
      entries: schedule.entries,
      weekday: weekday,
      academicWeek: currentWeek,
      periodTimes: periodTimes,
    );
    final tomorrowClasses = _filterDailyClasses(
      entries: schedule.entries,
      weekday: tomorrowWeekday,
      academicWeek: tomorrowWeek,
      periodTimes: periodTimes,
    );

    final allExamCountdowns = _buildExamCountdowns(exams, todayEpochDays);
    final futureOrUnknown = allExamCountdowns
        .where((e) => e.daysUntil == null || e.daysUntil! >= 0)
        .toList();
    final upcomingExams =
        futureOrUnknown.isNotEmpty ? futureOrUnknown : allExamCountdowns;

    _out.writeln(
      CliFormatters.formatToday(
        json: inv.global.json,
        date: todayStr,
        weekday: weekday,
        term: effectiveTerm,
        academicWeek: currentWeek,
        tomorrowDate: tomorrowStr,
        tomorrowWeekday: tomorrowWeekday,
        tomorrowAcademicWeek: tomorrowWeek,
        todayClasses: todayClasses,
        tomorrowClasses: tomorrowClasses,
        upcomingExams: upcomingExams,
      ),
    );
    return exitOk;
  }

  static List<CliDailyClassView> _filterDailyClasses({
    required List<ScheduleEntry> entries,
    required int weekday,
    required int? academicWeek,
    required List<PeriodTime> periodTimes,
  }) {
    if (academicWeek == null) return const <CliDailyClassView>[];
    final periodMap = <int, PeriodTime>{
      for (final p in periodTimes) p.period: p,
    };
    final matched = entries
        .where(
          (e) =>
              e.day == weekday &&
              (e.weeks.weeks.isEmpty || e.weeks.contains(academicWeek)),
        )
        .toList()
      ..sort((a, b) => a.period.start.compareTo(b.period.start));

    return matched
        .map(
          (e) => CliDailyClassView(
            courseName: e.name,
            teacher: e.teacher,
            location: e.location,
            day: e.day,
            startPeriod: e.period.start,
            endPeriod: e.period.end,
            startTime: periodMap[e.period.start]?.start ?? '',
            endTime: periodMap[e.period.end]?.end ?? '',
            weeksText: e.weeks.text,
          ),
        )
        .toList(growable: false);
  }

  // ---------------------------------------------------------------------------
  // 6. schedule [--week <1..30>] [--ics <out.ics>]
  // ---------------------------------------------------------------------------

  Future<int> _runSchedule(ParsedCliInvocation inv) async {
    final now = _nowProvider();
    late final Schedule schedule;
    late final List<PeriodTime> periodTimes;
    late final String effectiveTerm;
    StudyCatalog? catalog;

    if (inv.global.demo) {
      final demo = await CliDemoFixtures.bootstrap(clock: _epochSeconds);
      schedule = demo.schedule;
      periodTimes = demo.client.qustSifangLaoshanPeriodTimes();
      effectiveTerm = inv.global.term ?? CliDemoFixtures.demoDefaultTerm;
    } else {
      final ctx = await _openAuthenticatedLiveContext(inv);
      final termOverride = inv.global.term ?? '';
      try {
        catalog = await ctx.client.loadStudyCatalog(
          schoolId: _cliSchoolId,
          accountKey: ctx.accountKey,
          systemId: ctx.systemId,
          username: ctx.username,
        );
      } on AcademicException {
        catalog = null;
      }
      schedule = await ctx.client.loadStudyScheduleBundle(
        schoolId: _cliSchoolId,
        accountKey: ctx.accountKey,
        systemId: ctx.systemId,
        username: ctx.username,
        termId: termOverride,
      );
      effectiveTerm =
          termOverride.isNotEmpty ? termOverride : schedule.termId;
      periodTimes = await _loadPeriodTimesOrPreset(ctx, effectiveTerm);
    }

    final totalWeeks =
        catalog?.totalWeeks ?? _computeTotalWeeks(schedule.entries);
    final semesterStart = catalog?.semesterStart ??
        _resolveSemesterStart(
          termId: effectiveTerm.isNotEmpty ? effectiveTerm : null,
          year: now.year,
          month: now.month,
          day: now.day,
          serverCurrentWeek: catalog?.currentWeek,
        );

    final weekFilter = inv.week;
    final filteredEntries = weekFilter == null
        ? List<ScheduleEntry>.from(schedule.entries)
        : schedule.entries
            .where(
              (e) => e.weeks.weeks.isEmpty || e.weeks.contains(weekFilter),
            )
            .toList();
    filteredEntries.sort((a, b) {
      final dayCmp = a.day.compareTo(b.day);
      return dayCmp != 0 ? dayCmp : a.period.start.compareTo(b.period.start);
    });

    final icsEntries =
        filteredEntries.map((e) => e.toIcsEntry()).toList(growable: false);
    final conflicts = _buildConflictDetails(icsEntries);

    String? writtenIcsPath;
    final targetIcsPath = inv.icsPath;
    if (targetIcsPath != null && targetIcsPath.isNotEmpty) {
      final exportSource = weekFilter == null
          ? icsEntries
          : filteredEntries
              .map(
                (e) => IcsEntry(
                  name: e.name,
                  teacher: e.teacher,
                  location: e.location,
                  day: e.day,
                  startPeriod: e.period.start,
                  endPeriod: e.period.end,
                  weeks: <int>[weekFilter],
                  weeksText: e.weeks.text,
                ),
              )
              .toList(growable: false);
      final icsText = IcsExport.generate(
        entries: exportSource,
        semesterStart: semesterStart,
        totalWeeks: totalWeeks,
        periodTimes: periodTimes,
        nowEpochSeconds: _epochSeconds(),
      );
      final outFile = io.File(targetIcsPath);
      await outFile.parent.create(recursive: true);
      await outFile.writeAsString(icsText);
      writtenIcsPath = outFile.path;
    }

    _out.writeln(
      CliFormatters.formatSchedule(
        json: inv.global.json,
        term: effectiveTerm,
        weekFilter: weekFilter,
        totalWeeks: totalWeeks,
        semesterStart: semesterStart,
        entries: filteredEntries,
        practicalCourses: schedule.practicalCourses,
        conflicts: conflicts,
        periodTimes: periodTimes,
        icsPath: writtenIcsPath,
      ),
    );
    return exitOk;
  }

  // ---------------------------------------------------------------------------
  // 7. grades [--stats]
  // ---------------------------------------------------------------------------

  Future<int> _runGrades(ParsedCliInvocation inv) async {
    final termFilter = inv.global.term;
    late final GradeReport report;

    if (inv.global.demo) {
      final demo = await CliDemoFixtures.bootstrap(clock: _epochSeconds);
      if (termFilter != null && termFilter.isNotEmpty) {
        final filtered = demo.gradeReport.grades
            .where((g) => g.term == termFilter)
            .toList(growable: false);
        report = GradeMath.enrichReport(GradeReport(grades: filtered));
      } else {
        report = demo.gradeReport;
      }
    } else {
      final ctx = await _openAuthenticatedLiveContext(inv);
      final rawReport = await ctx.client.loadStudyGrades(
        schoolId: _cliSchoolId,
        accountKey: ctx.accountKey,
        systemId: ctx.systemId,
        username: ctx.username,
        termId: termFilter ?? '',
      );
      if (termFilter != null && termFilter.isNotEmpty) {
        final matching = rawReport.grades
            .where((g) => g.term.isEmpty || g.term == termFilter)
            .toList(growable: false);
        report = GradeMath.enrichReport(
          GradeReport(
            grades: matching,
            gradePointAverageRaw: rawReport.gradePointAverageRaw,
            totalCreditsRaw: rawReport.totalCreditsRaw,
          ),
        );
      } else {
        report = GradeMath.enrichReport(rawReport);
      }
    }

    final summary = GradeMath.summarize(report);
    _out.writeln(
      CliFormatters.formatGrades(
        json: inv.global.json,
        termFilter: termFilter,
        report: report,
        summary: summary,
        includeStats: inv.stats,
      ),
    );
    return exitOk;
  }

  // ---------------------------------------------------------------------------
  // 8. exams
  // ---------------------------------------------------------------------------

  Future<int> _runExams(ParsedCliInvocation inv) async {
    final now = _nowProvider();
    final refDateStr = _formatIsoDate(now.year, now.month, now.day);
    final refEpochDays = CivilDate.daysFromCivil(now.year, now.month, now.day);
    final termFilter = inv.global.term;

    late final List<ExamEntry> exams;
    if (inv.global.demo) {
      final demo = await CliDemoFixtures.bootstrap(clock: _epochSeconds);
      exams = (termFilter != null && termFilter.isNotEmpty)
          ? demo.exams
              .where((e) => e.termId.isEmpty || e.termId == termFilter)
              .toList(growable: false)
          : demo.exams;
    } else {
      final ctx = await _openAuthenticatedLiveContext(inv);
      exams = await ctx.client.fetchExams(
        schoolId: _cliSchoolId,
        accountKey: ctx.accountKey,
        systemId: ctx.systemId,
        username: ctx.username,
        termId: termFilter,
        allTerms: termFilter == null || termFilter.isEmpty,
      );
    }

    final views = _buildExamCountdowns(exams, refEpochDays);
    _out.writeln(
      CliFormatters.formatExams(
        json: inv.global.json,
        termFilter: termFilter,
        referenceDate: refDateStr,
        exams: views,
      ),
    );
    return exitOk;
  }

  // ---------------------------------------------------------------------------
  // 9. plan (N105515)
  // ---------------------------------------------------------------------------

  Future<int> _runPlan(ParsedCliInvocation inv) async {
    late final AcademicProgressReport report;
    final coursesByCategory = <String, List<PlanCourseEntry>>{};

    if (inv.global.demo) {
      await CliDemoFixtures.bootstrap(clock: _epochSeconds);
      report = CliDemoFixtures.academicProgress;
      coursesByCategory.addAll(CliDemoFixtures.planCoursesByCategory);
    } else {
      final ctx = await _openAuthenticatedLiveContext(inv);
      report = await ctx.client.fetchAcademicProgress(
        schoolId: _cliSchoolId,
        accountKey: ctx.accountKey,
        systemId: ctx.systemId,
        username: ctx.username,
      );
      for (final leaf in report.leafCategories) {
        try {
          final leafCourses = await ctx.client.fetchAcademicProgressCourses(
            leaf.id,
            schoolId: _cliSchoolId,
            accountKey: ctx.accountKey,
            systemId: ctx.systemId,
            username: ctx.username,
            studentId: report.studentId.isNotEmpty ? report.studentId : null,
            xnm: report.cjlrxn.isNotEmpty ? report.cjlrxn : null,
            xqm: report.cjlrxq.isNotEmpty ? report.cjlrxq : null,
          );
          coursesByCategory[leaf.id] = leafCourses;
        } on AcademicException {
          coursesByCategory[leaf.id] = const <PlanCourseEntry>[];
        }
      }
    }

    _out.writeln(
      CliFormatters.formatPlan(
        json: inv.global.json,
        report: report,
        coursesByCategory: coursesByCategory,
      ),
    );
    return exitOk;
  }

  // ---------------------------------------------------------------------------
  // 10. rooms (N2155)
  // ---------------------------------------------------------------------------

  Future<int> _runRooms(ParsedCliInvocation inv) async {
    final now = _nowProvider();
    final defaultDay =
        _isoDayOfWeek(CivilDate.daysFromCivil(now.year, now.month, now.day));
    final day = inv.day ?? defaultDay;
    final rawCampus = inv.campus;
    final campusId =
        (rawCampus != null && rawCampus.isNotEmpty) ? rawCampus : '1';

    final defaultSem = _resolveSemesterStart(
      termId: inv.global.term,
      year: now.year,
      month: now.month,
      day: now.day,
    );
    final inferredWeek = _weekNumberFor(
          defaultSem,
          year: now.year,
          month: now.month,
          day: now.day,
          maxWeek: 25,
        ) ??
        1;

    final weeks = inv.weeks ?? <int>[inferredWeek];
    final sections = inv.sections ?? const <int>[1, 2];

    final query = _CliEmptyClassroomQuery(
      campusId: campusId,
      termId: inv.global.term,
      week: weeks.first,
      weeks: weeks,
      dayOfWeek: day,
      startPeriod: sections.first,
      endPeriod: sections.last,
      explicitSections: sections,
    );

    late final List<EmptyClassroom> rooms;
    if (inv.global.demo) {
      await CliDemoFixtures.bootstrap(clock: _epochSeconds);
      rooms = CliDemoFixtures.emptyClassrooms.where((r) {
        if (rawCampus == null || rawCampus.isEmpty) return true;
        final c = rawCampus.trim();
        if (c == '1') return r.campus.contains('四方');
        if (c == '2') return r.campus.contains('崂山');
        return r.campus.contains(c) || r.id == c;
      }).toList(growable: false);
    } else {
      final ctx = await _openAuthenticatedLiveContext(inv);
      rooms = await ctx.client.queryEmptyClassrooms(
        query,
        schoolId: _cliSchoolId,
        accountKey: ctx.accountKey,
        systemId: ctx.systemId,
        username: ctx.username,
      );
    }

    _out.writeln(
      CliFormatters.formatRooms(
        json: inv.global.json,
        campusId: campusId,
        day: day,
        weeks: weeks,
        sections: sections,
        zcdBitmask: query.zcdBitmask,
        jcdBitmask: query.jcdBitmask,
        rooms: rooms,
      ),
    );
    return exitOk;
  }

  // ---------------------------------------------------------------------------
  // 11. courses [--query <kw>] (N255010 + Zzxk)
  // ---------------------------------------------------------------------------

  Future<int> _runCourses(ParsedCliInvocation inv) async {
    final kw = inv.query?.trim() ?? '';
    final kwLower = kw.toLowerCase();
    final term = inv.global.term ?? '';

    if (inv.global.demo) {
      final demo = await CliDemoFixtures.bootstrap(clock: _epochSeconds);
      final enrolled = CliDemoFixtures.enrolledCourses.where((c) {
        if (kwLower.isEmpty) return true;
        return c.courseCode.toLowerCase().contains(kwLower) ||
            c.courseName.toLowerCase().contains(kwLower) ||
            c.teacher.toLowerCase().contains(kwLower) ||
            c.jxbId.toLowerCase().contains(kwLower);
      }).toList(growable: false);

      final offers = CliDemoFixtures.courseOffers.where((o) {
        if (kwLower.isEmpty) return true;
        return o.id.toLowerCase().contains(kwLower) ||
            o.name.toLowerCase().contains(kwLower) ||
            o.teacher.toLowerCase().contains(kwLower);
      }).toList(growable: false);

      _out.writeln(
        CliFormatters.formatCourses(
          json: inv.global.json,
          term: term.isNotEmpty ? term : '2025-2026-2',
          query: kw.isEmpty ? null : kw,
          selectionRoundOpen: true,
          selectionClosedMessage: '',
          enrolledCourses: enrolled,
          selectedCourses: demo.selectedCourses,
          selectableOffers: offers,
          sectionsByCourse: CliDemoFixtures.sectionsByCourse,
        ),
      );
      return exitOk;
    }

    final ctx = await _openAuthenticatedLiveContext(inv);
    var enrolled = await ctx.client.fetchEnrolledCourses(
      schoolId: _cliSchoolId,
      accountKey: ctx.accountKey,
      systemId: ctx.systemId,
      username: ctx.username,
      termId: term.isNotEmpty ? term : null,
    );
    if (kwLower.isNotEmpty) {
      enrolled = enrolled
          .where(
            (c) =>
                c.courseCode.toLowerCase().contains(kwLower) ||
                c.courseName.toLowerCase().contains(kwLower) ||
                c.teacher.toLowerCase().contains(kwLower) ||
                c.jxbId.toLowerCase().contains(kwLower),
          )
          .toList(growable: false);
    }

    var selectionOpen = false;
    var closedMsg = '';
    var selected = const <SelectedCourse>[];
    final offers = <CourseOffer>[];
    final sectionsMap = <String, List<CourseSection>>{};

    if (ctx.systemId == AcademicSystem.ZF.id) {
      try {
        final scopes = await ctx.client.loadCourseScopes(
          schoolId: _cliSchoolId,
          accountKey: ctx.accountKey,
          systemId: ctx.systemId,
        );
        selectionOpen = scopes.isNotEmpty;
        if (selectionOpen) {
          selected = await ctx.client.loadSelectedCourses(
            schoolId: _cliSchoolId,
            accountKey: ctx.accountKey,
            systemId: ctx.systemId,
          );
          final seenOfferIds = <String>{};
          for (final scope in scopes) {
            final scopeOffers = await ctx.client.listCourses(
              schoolId: _cliSchoolId,
              accountKey: ctx.accountKey,
              systemId: ctx.systemId,
              scopeId: scope.id,
              query: CourseQuery(keyword: kw, pageSize: 50),
            );
            for (final o in scopeOffers) {
              if (seenOfferIds.add('${o.scopeId}|${o.id}')) {
                offers.add(o);
              }
            }
          }
          if (kw.isNotEmpty && offers.length <= 10) {
            for (final o in offers) {
              sectionsMap[o.id] = await ctx.client.listCourseSections(
                schoolId: _cliSchoolId,
                accountKey: ctx.accountKey,
                systemId: ctx.systemId,
                courseId: o.id,
                scopeId: o.scopeId,
              );
            }
          }
        }
      } on AcademicException catch (error) {
        if (error.status == AcademicStatus.ROUND_CLOSED ||
            error.status == AcademicStatus.UNSUPPORTED) {
          selectionOpen = false;
          closedMsg = error.message;
        } else {
          rethrow;
        }
      }
    } else {
      closedMsg = '当前教务系统 (${ctx.systemId}) 暂未开放自主选课列表接口';
    }

    _out.writeln(
      CliFormatters.formatCourses(
        json: inv.global.json,
        term: term,
        query: kw.isEmpty ? null : kw,
        selectionRoundOpen: selectionOpen,
        selectionClosedMessage: closedMsg,
        enrolledCourses: enrolled,
        selectedCourses: selected,
        selectableOffers: offers,
        sectionsByCourse: sectionsMap,
      ),
    );
    return exitOk;
  }

  // ---------------------------------------------------------------------------
  // 12. select & drop (Redline #2 两步确认制 + Redline #3 RESULT_UNKNOWN 只读核实)
  // ---------------------------------------------------------------------------

  Future<int> _runMutation(
    ParsedCliInvocation inv, {
    required bool dropping,
  }) async {
    final action = dropping ? 'drop' : 'select';
    final courseId = inv.courseId!;
    final requestedClassId = inv.classId;

    if (inv.global.demo) {
      return _runDemoMutation(
        inv: inv,
        action: action,
        dropping: dropping,
        courseId: courseId,
        requestedClassId: requestedClassId,
      );
    }

    final ctx = await _openAuthenticatedLiveContext(inv);
    final scopes = await ctx.client.loadCourseScopes(
      schoolId: _cliSchoolId,
      accountKey: ctx.accountKey,
      systemId: ctx.systemId,
    );
    if (scopes.isEmpty) {
      throw const AcademicException(
        AcademicStatus.ROUND_CLOSED,
        '当前未处于开放选课阶段，没有可用的选课轮次。',
      );
    }

    final selectedBefore = await ctx.client.loadSelectedCourses(
      schoolId: _cliSchoolId,
      accountKey: ctx.accountKey,
      systemId: ctx.systemId,
    );

    CourseOffer? matchedOffer;
    String resolvedScopeId = scopes.first.id;
    for (final scope in scopes) {
      final found = await ctx.client.listCourses(
        schoolId: _cliSchoolId,
        accountKey: ctx.accountKey,
        systemId: ctx.systemId,
        scopeId: scope.id,
        query: CourseQuery(keyword: courseId, pageSize: 50),
      );
      for (final item in found) {
        if (item.id == courseId) {
          matchedOffer = item;
          resolvedScopeId = scope.id;
          break;
        }
      }
      if (matchedOffer != null) break;
    }

    var candidateSections = const <CourseSection>[];
    if (matchedOffer != null) {
      candidateSections = await ctx.client.listCourseSections(
        schoolId: _cliSchoolId,
        accountKey: ctx.accountKey,
        systemId: ctx.systemId,
        courseId: courseId,
        scopeId: resolvedScopeId,
      );
    }

    SelectedCourse? matchedSelected;
    for (final sel in selectedBefore) {
      final courseMatch = sel.courseId == courseId;
      final sectionMatch =
          requestedClassId == null || sel.sectionId == requestedClassId;
      if (courseMatch && sectionMatch) {
        matchedSelected = sel;
        break;
      }
      if (requestedClassId != null && sel.sectionId == requestedClassId) {
        matchedSelected = sel;
        break;
      }
    }

    CourseSection? targetSection;
    if (requestedClassId != null && requestedClassId.isNotEmpty) {
      for (final sec in candidateSections) {
        if (sec.id == requestedClassId) {
          targetSection = sec;
          break;
        }
      }
    } else if (!dropping && candidateSections.length == 1) {
      targetSection = candidateSections.first;
    } else if (dropping && matchedSelected != null) {
      for (final sec in candidateSections) {
        if (sec.id == matchedSelected.sectionId) {
          targetSection = sec;
          break;
        }
      }
    }

    final resolvedClassId = requestedClassId ??
        targetSection?.id ??
        (dropping ? matchedSelected?.sectionId : null);

    // 红线 #2：不带 --confirm 时严禁发出任何写请求，仅做只读目标核实与撞课预检，返回退出码 2
    if (!inv.confirm) {
      var conflicts = const <CliConflictDetail>[];
      if (!dropping) {
        Schedule? currentSchedule;
        try {
          currentSchedule = await ctx.client.loadStudyScheduleBundle(
            schoolId: _cliSchoolId,
            accountKey: ctx.accountKey,
            systemId: ctx.systemId,
            username: ctx.username,
            termId: inv.global.term ?? '',
          );
        } on AcademicException {
          currentSchedule = null;
        }
        conflicts = _detectCandidateConflicts(
          scheduleEntries: currentSchedule?.entries ?? const <ScheduleEntry>[],
          selectedCourses: selectedBefore,
          candidateName: matchedOffer?.name ?? courseId,
          candidateTeacher:
              targetSection?.teacher ?? matchedOffer?.teacher ?? '',
          candidateLocation:
              targetSection?.location ?? matchedOffer?.location ?? '',
          candidateTime: targetSection?.time ?? matchedOffer?.time ?? '',
        );
      }

      final confirmCmd = _buildConfirmCommand(
        inv: inv,
        action: action,
        courseId: courseId,
        classId: resolvedClassId,
      );
      final previewMsg = resolvedClassId == null
          ? '检测到多个或未知教学班，请补充 --class-id <jxbId> 并附加 --confirm 后再执行。'
          : '干跑预检完成（未发送任何选退课写请求）。核对无误后请运行下方 --confirm 命令提交。';

      _out.writeln(
        CliFormatters.formatMutationPreview(
          json: inv.global.json,
          action: action,
          courseId: courseId,
          resolvedClassId: resolvedClassId,
          courseName: matchedOffer?.name ?? matchedSelected?.name ?? '',
          sectionName: targetSection?.name ?? '',
          teacher: targetSection?.teacher ??
              matchedSelected?.teacher ??
              matchedOffer?.teacher ??
              '',
          time: targetSection?.time ??
              matchedSelected?.time ??
              matchedOffer?.time ??
              '',
          location: targetSection?.location ??
              matchedSelected?.location ??
              matchedOffer?.location ??
              '',
          capacity: targetSection?.capacity ?? matchedOffer?.capacity,
          selected: targetSection?.selected ?? matchedOffer?.selected,
          remaining: targetSection?.remaining ?? matchedOffer?.remaining,
          alreadySelected: matchedSelected != null,
          conflicts: conflicts,
          candidateSections: candidateSections,
          confirmCommand: confirmCmd,
          message: previewMsg,
        ),
      );
      return exitPreviewConfirmRequired;
    }

    if (resolvedClassId == null || resolvedClassId.isEmpty) {
      throw CliUsageException(
        '$action --confirm 需要明确的 --class-id <jxbId>（当前课程存在 ${candidateSections.length} 个教学班或不在已选列表中）。',
      );
    }

    SelectionOutcome outcome;
    try {
      outcome = dropping
          ? await ctx.client.dropCourse(
              schoolId: _cliSchoolId,
              accountKey: ctx.accountKey,
              systemId: ctx.systemId,
              courseId: courseId,
              sectionId: resolvedClassId,
              scopeId: resolvedScopeId,
              confirmed: true,
            )
          : await ctx.client.selectCourse(
              schoolId: _cliSchoolId,
              accountKey: ctx.accountKey,
              systemId: ctx.systemId,
              courseId: courseId,
              sectionId: resolvedClassId,
              scopeId: resolvedScopeId,
              confirmed: true,
            );
    } on AcademicException catch (error) {
      if (error.status == AcademicStatus.RESULT_UNKNOWN) {
        outcome = SelectionOutcome(
          AcademicStatus.RESULT_UNKNOWN,
          error.message,
          matchedOffer?.name ?? matchedSelected?.name ?? '',
          resolvedClassId,
        );
      } else {
        rethrow;
      }
    }

    // 红线 #3：遇到 RESULT_UNKNOWN 超时或响应截断，绝不盲目重发 POST！立即自动只读复查已选列表
    if (outcome.status == AcademicStatus.RESULT_UNKNOWN) {
      return _verifyAfterUnknownOutcome(
        inv: inv,
        ctx: ctx,
        dropping: dropping,
        action: action,
        courseId: courseId,
        resolvedClassId: resolvedClassId,
        courseName: outcome.courseName.isNotEmpty
            ? outcome.courseName
            : (matchedOffer?.name ?? matchedSelected?.name ?? ''),
        initialMessage: outcome.message,
      );
    }

    final ok = outcome.isSuccess;
    final verificationState = ok
        ? (dropping ? 'CONFIRMED_DROPPED' : 'CONFIRMED_SELECTED')
        : 'REJECTED_${outcome.status.name}';
    final detailMessage = outcome.message.isNotEmpty
        ? outcome.message
        : (ok
            ? (dropping ? '退课提交成功。' : '选课提交成功。')
            : '操作未成功 (${outcome.status.name})。');

    if (!ok) {
      _err.writeln('[${outcome.status.name}] $detailMessage');
    }

    _out.writeln(
      CliFormatters.formatMutationResult(
        json: inv.global.json,
        ok: ok,
        action: action,
        status: outcome.status,
        courseId: courseId,
        classId:
            outcome.sectionId.isNotEmpty ? outcome.sectionId : resolvedClassId,
        courseName: outcome.courseName.isNotEmpty
            ? outcome.courseName
            : (matchedOffer?.name ?? matchedSelected?.name ?? ''),
        verificationState: verificationState,
        verifiedByReadOnlyCheck: false,
        message: detailMessage,
      ),
    );
    return ok ? exitOk : exitError;
  }

  Future<int> _verifyAfterUnknownOutcome({
    required ParsedCliInvocation inv,
    required _AuthenticatedLiveContext ctx,
    required bool dropping,
    required String action,
    required String courseId,
    required String resolvedClassId,
    required String courseName,
    required String initialMessage,
  }) async {
    try {
      final selectedAfter = await ctx.client.loadSelectedCourses(
        schoolId: _cliSchoolId,
        accountKey: ctx.accountKey,
        systemId: ctx.systemId,
      );
      final present = selectedAfter.any(
        (s) =>
            s.sectionId == resolvedClassId ||
            (s.courseId == courseId &&
                (s.sectionId.isEmpty || resolvedClassId.isEmpty)),
      );

      final applied = dropping ? !present : present;
      final verificationState = dropping
          ? (applied ? 'VERIFIED_DROPPED' : 'VERIFIED_STILL_SELECTED')
          : (applied ? 'VERIFIED_SELECTED' : 'VERIFIED_NOT_SELECTED');
      final message = applied
          ? '写请求返回 RESULT_UNKNOWN（$initialMessage），经只读已选列表复核确认${dropping ? "已成功退课" : "已成功选上"}（未重发写请求）。'
          : '写请求返回 RESULT_UNKNOWN（$initialMessage），经只读已选列表复核确认${dropping ? "课程仍在已选列表中（未退掉）" : "课程尚未进入已选列表（未选上）"}（未盲目重发写请求）。';

      if (!applied) {
        _err.writeln('[RESULT_UNKNOWN] $message');
      }

      _out.writeln(
        CliFormatters.formatMutationResult(
          json: inv.global.json,
          ok: applied,
          action: action,
          status: AcademicStatus.RESULT_UNKNOWN,
          courseId: courseId,
          classId: resolvedClassId,
          courseName: courseName,
          verificationState: verificationState,
          verifiedByReadOnlyCheck: true,
          message: message,
        ),
      );
      return applied ? exitOk : exitError;
    } on AcademicException catch (readError) {
      final msg =
          '写请求返回 RESULT_UNKNOWN（$initialMessage），且随后的只读核验亦失败（${readError.status.name}: ${readError.message}）。请稍后运行 `courselens courses` 核实，切勿盲目重复提交。';
      _err.writeln('[RESULT_UNKNOWN] $msg');
      _out.writeln(
        CliFormatters.formatMutationResult(
          json: inv.global.json,
          ok: false,
          action: action,
          status: AcademicStatus.RESULT_UNKNOWN,
          courseId: courseId,
          classId: resolvedClassId,
          courseName: courseName,
          verificationState: 'UNVERIFIED_READ_FAILED',
          verifiedByReadOnlyCheck: false,
          message: msg,
        ),
      );
      return exitError;
    }
  }

  Future<int> _runDemoMutation({
    required ParsedCliInvocation inv,
    required String action,
    required bool dropping,
    required String courseId,
    required String? requestedClassId,
  }) async {
    final demo = await CliDemoFixtures.bootstrap(clock: _epochSeconds);
    CourseOffer? offer;
    for (final item in CliDemoFixtures.courseOffers) {
      if (item.id == courseId) {
        offer = item;
        break;
      }
    }
    final sections =
        CliDemoFixtures.sectionsByCourse[courseId] ?? const <CourseSection>[];

    SelectedCourse? matchedSelected;
    for (final s in demo.selectedCourses) {
      if (s.courseId == courseId &&
          (requestedClassId == null || s.sectionId == requestedClassId)) {
        matchedSelected = s;
        break;
      }
    }

    CourseSection? targetSection;
    if (requestedClassId != null) {
      for (final sec in sections) {
        if (sec.id == requestedClassId) {
          targetSection = sec;
          break;
        }
      }
    } else if (!dropping && sections.length == 1) {
      targetSection = sections.first;
    } else if (dropping && matchedSelected != null) {
      for (final sec in sections) {
        if (sec.id == matchedSelected.sectionId) {
          targetSection = sec;
          break;
        }
      }
    }

    final resolvedClassId = requestedClassId ??
        targetSection?.id ??
        (dropping ? matchedSelected?.sectionId : null);

    if (!inv.confirm) {
      final conflicts = dropping
          ? const <CliConflictDetail>[]
          : _detectCandidateConflicts(
              scheduleEntries: demo.schedule.entries,
              selectedCourses: demo.selectedCourses,
              candidateName: offer?.name ?? courseId,
              candidateTeacher: targetSection?.teacher ?? offer?.teacher ?? '',
              candidateLocation:
                  targetSection?.location ?? offer?.location ?? '',
              candidateTime: targetSection?.time ?? offer?.time ?? '',
            );

      final confirmCmd = _buildConfirmCommand(
        inv: inv,
        action: action,
        courseId: courseId,
        classId: resolvedClassId,
      );
      _out.writeln(
        CliFormatters.formatMutationPreview(
          json: inv.global.json,
          action: action,
          courseId: courseId,
          resolvedClassId: resolvedClassId,
          courseName: offer?.name ?? matchedSelected?.name ?? '',
          sectionName: targetSection?.name ?? '',
          teacher: targetSection?.teacher ??
              matchedSelected?.teacher ??
              offer?.teacher ??
              '',
          time:
              targetSection?.time ?? matchedSelected?.time ?? offer?.time ?? '',
          location: targetSection?.location ??
              matchedSelected?.location ??
              offer?.location ??
              '',
          capacity: targetSection?.capacity ?? offer?.capacity,
          selected: targetSection?.selected ?? offer?.selected,
          remaining: targetSection?.remaining ?? offer?.remaining,
          alreadySelected: matchedSelected != null,
          conflicts: conflicts,
          candidateSections: sections,
          confirmCommand: confirmCmd,
          message: resolvedClassId == null
              ? '演示沙盒预检：该课程含多个教学班，请指定 --class-id <jxbId> 并附加 --confirm。'
              : '演示沙盒干跑预检完成（零写网络发包）。附加 --confirm 可模拟正式提交。',
        ),
      );
      return exitPreviewConfirmRequired;
    }

    if (resolvedClassId == null || resolvedClassId.isEmpty) {
      throw CliUsageException(
        '$action --confirm 需要指定 --class-id <jxbId>。',
      );
    }

    if (dropping) {
      if (matchedSelected == null) {
        final msg = '目标课程 $courseId ($resolvedClassId) 当前不在演示已选列表中。';
        _err.writeln('[PAGE_CHANGED] $msg');
        _out.writeln(
          CliFormatters.formatMutationResult(
            json: inv.global.json,
            ok: false,
            action: action,
            status: AcademicStatus.PAGE_CHANGED,
            courseId: courseId,
            classId: resolvedClassId,
            courseName: offer?.name ?? '',
            verificationState: 'REJECTED_PAGE_CHANGED',
            verifiedByReadOnlyCheck: false,
            message: msg,
          ),
        );
        return exitError;
      }
      _out.writeln(
        CliFormatters.formatMutationResult(
          json: inv.global.json,
          ok: true,
          action: action,
          status: AcademicStatus.SUCCESS,
          courseId: courseId,
          classId: resolvedClassId,
          courseName: matchedSelected.name,
          verificationState: 'CONFIRMED_DROPPED',
          verifiedByReadOnlyCheck: false,
          message: '演示沙盒退课成功（未向真实教务发包）。',
        ),
      );
      return exitOk;
    }

    if (offer == null || targetSection == null) {
      final msg = '未在演示可选列表中找到课程 $courseId 教学班 $resolvedClassId。';
      _err.writeln('[PAGE_CHANGED] $msg');
      _out.writeln(
        CliFormatters.formatMutationResult(
          json: inv.global.json,
          ok: false,
          action: action,
          status: AcademicStatus.PAGE_CHANGED,
          courseId: courseId,
          classId: resolvedClassId,
          courseName: offer?.name ?? '',
          verificationState: 'REJECTED_PAGE_CHANGED',
          verifiedByReadOnlyCheck: false,
          message: msg,
        ),
      );
      return exitError;
    }

    if (matchedSelected != null) {
      const msg = '该课程已在已选列表中，无需重复选课。';
      _err.writeln('[ALREADY_SELECTED] $msg');
      _out.writeln(
        CliFormatters.formatMutationResult(
          json: inv.global.json,
          ok: false,
          action: action,
          status: AcademicStatus.ALREADY_SELECTED,
          courseId: courseId,
          classId: resolvedClassId,
          courseName: offer.name,
          verificationState: 'REJECTED_ALREADY_SELECTED',
          verifiedByReadOnlyCheck: false,
          message: msg,
        ),
      );
      return exitError;
    }

    final conflicts = _detectCandidateConflicts(
      scheduleEntries: demo.schedule.entries,
      selectedCourses: demo.selectedCourses,
      candidateName: offer.name,
      candidateTeacher: targetSection.teacher,
      candidateLocation: targetSection.location,
      candidateTime: targetSection.time,
    );
    if (conflicts.isNotEmpty) {
      final msg = '上课时间冲突：${conflicts.first.summary}';
      _err.writeln('[CONFLICT] $msg');
      _out.writeln(
        CliFormatters.formatMutationResult(
          json: inv.global.json,
          ok: false,
          action: action,
          status: AcademicStatus.CONFLICT,
          courseId: courseId,
          classId: resolvedClassId,
          courseName: offer.name,
          verificationState: 'REJECTED_CONFLICT',
          verifiedByReadOnlyCheck: false,
          message: msg,
        ),
      );
      return exitError;
    }

    if ((targetSection.remaining ?? 1) <= 0) {
      const msg = '当前教学班名额已满（余量 0）。';
      _err.writeln('[NO_CAPACITY] $msg');
      _out.writeln(
        CliFormatters.formatMutationResult(
          json: inv.global.json,
          ok: false,
          action: action,
          status: AcademicStatus.NO_CAPACITY,
          courseId: courseId,
          classId: resolvedClassId,
          courseName: offer.name,
          verificationState: 'REJECTED_NO_CAPACITY',
          verifiedByReadOnlyCheck: false,
          message: msg,
        ),
      );
      return exitError;
    }

    _out.writeln(
      CliFormatters.formatMutationResult(
        json: inv.global.json,
        ok: true,
        action: action,
        status: AcademicStatus.SUCCESS,
        courseId: courseId,
        classId: resolvedClassId,
        courseName: offer.name,
        verificationState: 'CONFIRMED_SELECTED',
        verifiedByReadOnlyCheck: false,
        message: '演示沙盒选课成功（未向真实教务发包）。',
      ),
    );
    return exitOk;
  }

  // ---------------------------------------------------------------------------
  // 共享辅助计算：作息表、校历、冲突解析与倒计时
  // ---------------------------------------------------------------------------

  Future<List<PeriodTime>> _loadPeriodTimesOrPreset(
    _AuthenticatedLiveContext ctx,
    String termId,
  ) async {
    if (ctx.systemId == AcademicSystem.ZF.id) {
      try {
        final remote = await ctx.client.fetchCampusBellSchedule(
          schoolId: _cliSchoolId,
          accountKey: ctx.accountKey,
          systemId: ctx.systemId,
          username: ctx.username,
          termId: termId.isNotEmpty ? termId : null,
        );
        if (remote.isNotEmpty) return remote;
      } on AcademicException {
        // 回退至内置节次时间表
      }
    }
    return PeriodScheduleBuilder.qustSifangLaoshanPreset();
  }

  static int _isoDayOfWeek(int epochDays) => ((epochDays + 3) % 7 + 7) % 7 + 1;

  static int? _weekNumberFor(
    SemesterStart semesterStart, {
    required int year,
    required int month,
    required int day,
    required int maxWeek,
  }) {
    final startDays = CivilDate.daysFromCivil(
      semesterStart.year,
      semesterStart.month,
      semesterStart.day,
    );
    final targetDays = CivilDate.daysFromCivil(year, month, day);
    final diff = targetDays - startDays;
    if (diff < 0) return null;
    final week = (diff ~/ 7) + 1;
    if (week > maxWeek) return null;
    return week;
  }

  static int _computeTotalWeeks(List<ScheduleEntry> entries) {
    var maxW = 20;
    for (final e in entries) {
      for (final w in e.weeks.weeks) {
        if (w > maxW) maxW = w;
      }
    }
    return maxW;
  }

  static String _inferTermForDate(int year, int month, int day) {
    if (month >= 8) {
      return '$year-${year + 1}-1';
    }
    if (month == 1) {
      return '${year - 1}-$year-1';
    }
    return '${year - 1}-$year-2';
  }

  static SemesterStart _resolveSemesterStart({
    required String? termId,
    required int year,
    required int month,
    required int day,
    int? serverCurrentWeek,
  }) {
    final todayDays = CivilDate.daysFromCivil(year, month, day);
    final todayIsoWeekday = _isoDayOfWeek(todayDays);
    if (serverCurrentWeek != null && serverCurrentWeek >= 1) {
      final weekOneMonday =
          todayDays - (todayIsoWeekday - 1) - (serverCurrentWeek - 1) * 7;
      final (sy, sm, sd) = CivilDate.civilFromDays(weekOneMonday);
      return SemesterStart(sy, sm, sd);
    }

    if (termId != null) {
      final m = RegExp(r'^(\d{4})\s*-\s*(\d{4})\s*-\s*([123])$')
          .firstMatch(termId.trim());
      if (m != null) {
        final startYear = int.parse(m.group(1)!);
        final endYear = int.parse(m.group(2)!);
        final sem = m.group(3)!;
        if (sem == '1') {
          return _firstMondayOnOrAfter(startYear, 9, 1);
        }
        return _firstMondayOnOrAfter(endYear, 2, 24);
      }
    }

    if (month >= 8) {
      return _firstMondayOnOrAfter(year, 9, 1);
    }
    if (month == 1) {
      return _firstMondayOnOrAfter(year - 1, 9, 1);
    }
    return _firstMondayOnOrAfter(year, 2, 24);
  }

  static SemesterStart _firstMondayOnOrAfter(int year, int month, int day) {
    final baseDays = CivilDate.daysFromCivil(year, month, day);
    final dow = _isoDayOfWeek(baseDays);
    final offset = dow == 1 ? 0 : (8 - dow);
    final (ry, rm, rd) = CivilDate.civilFromDays(baseDays + offset);
    return SemesterStart(ry, rm, rd);
  }

  static String _formatIsoDate(int year, int month, int day) =>
      '${year.toString().padLeft(4, "0")}-${month.toString().padLeft(2, "0")}-${day.toString().padLeft(2, "0")}';

  static final RegExp _embeddedDatePattern = RegExp(
    r'(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})',
  );

  static String _extractExamIsoDate(ExamEntry e) {
    if (e.examDate.trim().isNotEmpty) return e.examDate.trim();
    final match = _embeddedDatePattern.firstMatch(e.time);
    if (match == null) return '';
    final y = match.group(1)!.padLeft(4, '0');
    final m = match.group(2)!.padLeft(2, '0');
    final d = match.group(3)!.padLeft(2, '0');
    return '$y-$m-$d';
  }

  static List<CliExamCountdownView> _buildExamCountdowns(
    List<ExamEntry> exams,
    int referenceEpochDays,
  ) {
    final out = <CliExamCountdownView>[];
    for (final e in exams) {
      final dateStr = _extractExamIsoDate(e);
      int? daysUntil;
      var text = '日期待定';
      if (dateStr.isNotEmpty) {
        try {
          final (ey, em, ed) = CliArgs.parseIsoDate(dateStr);
          final examDays = CivilDate.daysFromCivil(ey, em, ed);
          daysUntil = examDays - referenceEpochDays;
          if (daysUntil == 0) {
            text = '今天';
          } else if (daysUntil == 1) {
            text = '明天';
          } else if (daysUntil > 1) {
            text = '还有 $daysUntil 天';
          } else {
            text = '已结束 (${-daysUntil}天前)';
          }
        } on CliUsageException {
          daysUntil = null;
        }
      }
      final enriched = (e.examDate.isEmpty && dateStr.isNotEmpty)
          ? ExamEntry(
              name: e.name,
              time: e.time,
              location: e.location,
              seat: e.seat,
              examName: e.examName,
              teacher: e.teacher,
              termId: e.termId,
              campus: e.campus,
              examMethod: e.examMethod,
              credits: e.credits,
              courseCode: e.courseCode,
              examDate: dateStr,
              startTime: e.startTime,
              endTime: e.endTime,
            )
          : e;
      out.add(
        CliExamCountdownView(
          entry: enriched,
          daysUntil: daysUntil,
          countdownText: text,
        ),
      );
    }
    out.sort((a, b) {
      final da = a.daysUntil;
      final db = b.daysUntil;
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      if (da >= 0 && db < 0) return -1;
      if (da < 0 && db >= 0) return 1;
      return da.compareTo(db);
    });
    return out;
  }

  static List<CliConflictDetail> _buildConflictDetails(
    List<IcsEntry> icsEntries,
  ) {
    final rawConflicts = ScheduleConflicts.find(icsEntries);
    return rawConflicts.map((c) {
      final first = icsEntries[c.firstIndex];
      final second = icsEntries[c.secondIndex];
      final start = first.startPeriod > second.startPeriod
          ? first.startPeriod
          : second.startPeriod;
      final end = first.endPeriod < second.endPeriod
          ? first.endPeriod
          : second.endPeriod;
      return CliConflictDetail(
        day: c.day,
        firstCourse: first.name,
        secondCourse: second.name,
        startPeriod: start,
        endPeriod: end,
        weeks: c.weeks,
      );
    }).toList(growable: false);
  }

  static List<CliConflictDetail> _detectCandidateConflicts({
    required List<ScheduleEntry> scheduleEntries,
    required List<SelectedCourse> selectedCourses,
    required String candidateName,
    required String candidateTeacher,
    required String candidateLocation,
    required String candidateTime,
  }) {
    final candidateSlots = _parseScheduleTextToIcsEntries(
      name: candidateName,
      teacher: candidateTeacher,
      location: candidateLocation,
      scheduleText: candidateTime,
    );
    if (candidateSlots.isEmpty) return const <CliConflictDetail>[];

    final existing = <IcsEntry>[
      for (final e in scheduleEntries)
        IcsEntry(
          name: e.name,
          teacher: e.teacher,
          location: e.location,
          day: e.day,
          startPeriod: e.period.start,
          endPeriod: e.period.end,
          weeks: e.weeks.weeks.isEmpty
              ? <int>[for (var w = 1; w <= 16; w++) w]
              : (e.weeks.weeks.toList()..sort()),
          weeksText: e.weeks.text,
        ),
    ];

    for (final sel in selectedCourses) {
      existing.addAll(
        _parseScheduleTextToIcsEntries(
          name: sel.name,
          teacher: sel.teacher,
          location: sel.location,
          scheduleText: sel.time,
        ),
      );
    }

    final firstCandidateIdx = existing.length;
    final combined = <IcsEntry>[...existing, ...candidateSlots];
    final found = ScheduleConflicts.find(combined);

    final out = <CliConflictDetail>[];
    for (final c in found) {
      if (c.firstIndex < firstCandidateIdx &&
          c.secondIndex < firstCandidateIdx) {
        continue;
      }
      if (c.firstIndex >= firstCandidateIdx &&
          c.secondIndex >= firstCandidateIdx) {
        continue;
      }
      final first = combined[c.firstIndex];
      final second = combined[c.secondIndex];
      final start = first.startPeriod > second.startPeriod
          ? first.startPeriod
          : second.startPeriod;
      final end = first.endPeriod < second.endPeriod
          ? first.endPeriod
          : second.endPeriod;
      out.add(
        CliConflictDetail(
          day: c.day,
          firstCourse: first.name,
          secondCourse: second.name,
          startPeriod: start,
          endPeriod: end,
          weeks: c.weeks,
        ),
      );
    }
    return out;
  }

  static final RegExp _weekdayPattern = RegExp(
    r'(?:星期|周)([一二三四五六日天1-7])',
  );

  static List<IcsEntry> _parseScheduleTextToIcsEntries({
    required String name,
    required String teacher,
    required String location,
    required String scheduleText,
  }) {
    if (scheduleText.trim().isEmpty) return const <IcsEntry>[];
    final segments = scheduleText
        .split(RegExp(r'[;；\n]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);
    final entries = <IcsEntry>[];

    for (final seg in segments) {
      final dayMatch = _weekdayPattern.firstMatch(seg);
      if (dayMatch == null) continue;
      final day = _parseWeekdayToken(dayMatch.group(1)!);
      if (day == null) continue;

      final periods = ScheduleText.parsePeriodsFromAnywhere(seg);
      if (periods.isEmpty) continue;

      final parsedWeeks = ScheduleText.parseWeeks(seg);
      final weeks = parsedWeeks != null
          ? (parsedWeeks.weeks.toList()..sort())
          : <int>[for (var w = 1; w <= 16; w++) w];

      for (final p in periods) {
        entries.add(
          IcsEntry(
            name: name,
            teacher: teacher,
            location: location,
            day: day,
            startPeriod: p.start,
            endPeriod: p.end,
            weeks: weeks,
            weeksText: seg,
          ),
        );
      }
    }
    return entries;
  }

  static int? _parseWeekdayToken(String token) => switch (token) {
        '一' || '1' => 1,
        '二' || '2' => 2,
        '三' || '3' => 3,
        '四' || '4' => 4,
        '五' || '5' => 5,
        '六' || '6' => 6,
        '日' || '天' || '7' => 7,
        _ => null,
      };

  static String _buildConfirmCommand({
    required ParsedCliInvocation inv,
    required String action,
    required String courseId,
    required String? classId,
  }) {
    final parts = <String>['courselens'];
    if (inv.global.demo) parts.add('--demo');
    final term = inv.global.term;
    if (term != null && term.isNotEmpty) {
      parts.add('--term ${_shellQuoteIfNeeded(term)}');
    }
    final relay = inv.global.relayUrl;
    if (relay != null && relay.isNotEmpty) {
      parts.add('--relay ${_shellQuoteIfNeeded(relay)}');
    }
    final worker = inv.global.workerUrl;
    if (worker != null && worker.isNotEmpty) {
      parts.add('--worker ${_shellQuoteIfNeeded(worker)}');
    }
    if (inv.global.store != 'auto') {
      parts.add('--store ${inv.global.store}');
    }
    final sessFile = inv.global.sessionFile;
    if (sessFile != null && sessFile.isNotEmpty) {
      parts.add('--session-file ${_shellQuoteIfNeeded(sessFile)}');
    }
    parts.add(action);
    parts.add('--course-id ${_shellQuoteIfNeeded(courseId)}');
    if (classId != null && classId.isNotEmpty) {
      parts.add('--class-id ${_shellQuoteIfNeeded(classId)}');
    } else {
      parts.add('--class-id <jxbId>');
    }
    parts.add('--confirm');
    if (inv.global.json) parts.add('--json');
    return parts.join(' ');
  }

  static String _shellQuoteIfNeeded(String raw) {
    if (RegExp(r'^[A-Za-z0-9_./:@=-]+$').hasMatch(raw)) {
      return raw;
    }
    final escaped = raw.replaceAll("'", r"'\''");
    return "'$escaped'";
  }
}

class _LiveClientBundle {
  const _LiveClientBundle({
    required this.client,
    required this.archive,
    required this.allowedHosts,
  });

  final AcademicClient client;
  final SessionArchive archive;
  final Set<String> allowedHosts;
}

class _AuthenticatedLiveContext {
  const _AuthenticatedLiveContext({
    required this.store,
    required this.record,
    required this.client,
    required this.accountKey,
    required this.baseUrl,
    required this.systemId,
    required this.username,
    required this.identity,
  });

  final CliSessionStore store;
  final CliSessionRecord record;
  final AcademicClient client;
  final String accountKey;
  final String baseUrl;
  final String systemId;
  final String username;
  final StudentIdentity identity;
}

/// 扩展 [EmptyClassroomQuery] 以精确支持 `--sections 1,3,5` 等非连续节次位掩码。
class _CliEmptyClassroomQuery extends EmptyClassroomQuery {
  const _CliEmptyClassroomQuery({
    required super.campusId,
    super.termId,
    required super.week,
    required super.weeks,
    required super.dayOfWeek,
    required super.startPeriod,
    required super.endPeriod,
    required this.explicitSections,
  });

  final List<int> explicitSections;

  @override
  String get jcdBitmask {
    if (explicitSections.isEmpty) return super.jcdBitmask;
    var mask = BigInt.zero;
    for (final section in explicitSections) {
      if (section >= 1 && section <= 30) {
        mask |= BigInt.one << (section - 1);
      }
    }
    return mask == BigInt.zero ? super.jcdBitmask : mask.toString();
  }
}
