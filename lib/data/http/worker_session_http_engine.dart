import 'dart:async';
import 'dart:convert' hide Base64Codec;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/courselens_core.dart';
import 'http_policy_provider.dart';
import 'relay_http_engine.dart';
import 'worker_gateway_models.dart';

export 'worker_gateway_models.dart';

/// 独立有状态 Cloudflare Worker（`workers/session_gateway/`）返回的远端会话摘要。
class WorkerRemoteSessionInfo {
  const WorkerRemoteSessionInfo({
    required this.ok,
    required this.authenticated,
    required this.alive,
    required this.schoolId,
    required this.schoolName,
    required this.baseUrl,
    this.casBaseUrl = '',
    required this.systemId,
    required this.allowedHosts,
    required this.requireSecure,
    this.hasPasswordAuth = false,
    this.hasStaticCredentials = false,
    required this.username,
    required this.identity,
    this.authenticatedAt,
    this.lastVerifiedAt,
    this.keepaliveMode = 'lazy',
    this.keepaliveIntervalSec = 0,
    this.capabilities = const <String>[],
    this.monitorGradesEnabled = false,
    this.monitorExamsEnabled = false,
    this.activeTaskCount = 0,
    this.nextAlarmAt,
    this.injectedCookieCount,
  });

  final bool ok;
  final bool authenticated;
  final bool? alive;
  final String schoolId;
  final String schoolName;
  final String baseUrl;
  final String casBaseUrl;
  final String systemId;
  final List<String> allowedHosts;
  final bool requireSecure;
  final bool hasPasswordAuth;
  final bool hasStaticCredentials;
  final String username;
  final StudentIdentity identity;
  final String? authenticatedAt;
  final String? lastVerifiedAt;
  final String keepaliveMode;
  final int keepaliveIntervalSec;
  final List<String> capabilities;
  final bool monitorGradesEnabled;
  final bool monitorExamsEnabled;
  final int activeTaskCount;
  final String? nextAlarmAt;
  final int? injectedCookieCount;

  factory WorkerRemoteSessionInfo.fromJson(Map<String, dynamic> json) {
    final rawStudent = json['identity'] ?? json['studentInfo'];
    final studentMap = rawStudent is Map
        ? Map<String, dynamic>.from(rawStudent)
        : const <String, dynamic>{};
    final username = (json['username'] as String? ?? '').trim();
    final studentId =
        (studentMap['studentId'] as String? ?? '').trim().isNotEmpty
            ? (studentMap['studentId'] as String).trim()
            : username;

    final rawHosts = json['allowedHosts'];
    final hosts = <String>[];
    if (rawHosts is List) {
      for (final item in rawHosts) {
        final s = item?.toString().trim() ?? '';
        if (s.isNotEmpty) hosts.add(s);
      }
    }

    final rawCaps = json['capabilities'];
    final caps = <String>[];
    if (rawCaps is List) {
      for (final item in rawCaps) {
        final s = item?.toString().trim() ?? '';
        if (s.isNotEmpty) caps.add(s);
      }
    }

    final keepaliveIntervalSec =
        (json['keepaliveIntervalSec'] as num?)?.toInt() ?? 0;
    final rawKeepaliveMode = (json['keepaliveMode'] as String? ?? '').trim();
    final keepaliveMode = rawKeepaliveMode.isNotEmpty
        ? rawKeepaliveMode
        : (keepaliveIntervalSec > 0 ? 'alarm' : 'lazy');

    return WorkerRemoteSessionInfo(
      ok: json['ok'] == true,
      authenticated: json['authenticated'] == true,
      alive: json['alive'] is bool ? json['alive'] as bool : null,
      schoolId: (json['schoolId'] as String? ?? '').trim(),
      schoolName: (json['schoolName'] as String? ?? '').trim(),
      baseUrl: (json['baseUrl'] as String? ?? '').trim(),
      casBaseUrl: (json['casBaseUrl'] as String? ?? '').trim(),
      systemId: (json['systemId'] as String? ?? 'ZF').trim(),
      allowedHosts: List<String>.unmodifiable(hosts),
      requireSecure: json['requireSecure'] != false,
      hasPasswordAuth: json['hasPasswordAuth'] == true,
      hasStaticCredentials: json['hasStaticCredentials'] == true,
      username: username.isNotEmpty ? username : studentId,
      identity: StudentIdentity(
        name: (studentMap['name'] as String? ??
                studentMap['studentName'] as String? ??
                '')
            .trim(),
        studentId: studentId,
        department: (studentMap['department'] as String? ?? '').trim(),
        className: (studentMap['className'] as String? ?? '').trim(),
      ),
      authenticatedAt: json['authenticatedAt'] as String?,
      lastVerifiedAt: json['lastVerifiedAt'] as String?,
      keepaliveMode: keepaliveMode,
      keepaliveIntervalSec: keepaliveIntervalSec,
      capabilities: List<String>.unmodifiable(caps),
      monitorGradesEnabled: json['monitorGradesEnabled'] == true,
      monitorExamsEnabled: json['monitorExamsEnabled'] == true,
      activeTaskCount: (json['activeTaskCount'] as num?)?.toInt() ?? 0,
      nextAlarmAt: json['nextAlarmAt'] as String?,
      injectedCookieCount: (json['injectedCookieCount'] as num?)?.toInt(),
    );
  }
}

/// 对接独立有状态 Cloudflare Worker 会话网关（`workers/session_gateway/`）的跨全平台 HTTP 引擎。
///
/// 与无状态 [RelayHttpEngine] 不同：
/// - 教务账号密码与原始 `CookieJar` 完全驻留在用户自建的 Cloudflare Durable Object 中；
/// - 五端 App 与原生 CLI 仅凭 `Worker URL + API Key` 发起请求，本地零密码、零原始 Cookie；
/// - 服务端遇到 HTTP `901` / 登录重定向会自动单飞重登并重放请求；
/// - 严格遵守红线 #3（`POST` 超时映射为 `RESULT_UNKNOWN` 绝不盲目重试）与红线 #4（`HostPolicy` 白名单校验）。
class WorkerSessionHttpEngine implements HttpEngine {
  WorkerSessionHttpEngine({
    required String Function() workerBaseUrlProvider,
    required String Function() apiKeyProvider,
    HttpPolicyProvider? policyProvider,
    http.Client? client,
    this.timeout = const Duration(seconds: 25),
  })  : _workerBaseUrlProvider = workerBaseUrlProvider,
        _apiKeyProvider = apiKeyProvider,
        _policyProvider = policyProvider,
        _client = client ?? http.Client();

  final String Function() _workerBaseUrlProvider;
  final String Function() _apiKeyProvider;
  final HttpPolicyProvider? _policyProvider;
  final http.Client _client;
  final Duration timeout;

  static const Set<String> _strippedClientHeaders = <String>{
    'cookie',
    'authorization',
    'x-courselens-key',
    'host',
    'content-length',
    'connection',
    'keep-alive',
    'transfer-encoding',
    'te',
    'trailer',
    'upgrade',
    'proxy-authorization',
    'proxy-connection',
    'x-forwarded-for',
    'x-forwarded-host',
    'x-forwarded-proto',
    'x-real-ip',
  };

  static bool _isLoopbackHost(String rawHost) {
    var host = rawHost.trim().toLowerCase();
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    host = host.replaceFirst(RegExp(r'\.+$'), '');
    return host == 'localhost' ||
        host.endsWith('.localhost') ||
        host == '127.0.0.1' ||
        host == '::1';
  }

  /// 规范化用户输入的 Worker 根地址（自动剥离末尾 `/`、`/health` 或 `/v1/...` 后缀），
  /// 拒绝非 `http(s)` 协议与内嵌 `userInfo`，并对非环回公网地址强制校验 HTTPS（安全红线 #5）。
  static String normalizeWorkerBaseUrl(String raw) {
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return '';

    final qIdx = trimmed.indexOf('?');
    if (qIdx >= 0) trimmed = trimmed.substring(0, qIdx);
    final hIdx = trimmed.indexOf('#');
    if (hIdx >= 0) trimmed = trimmed.substring(0, hIdx);

    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    const suffixes = <String>[
      '/v1/session/cookies',
      '/v1/session/refresh',
      '/v1/session',
      '/v1/proxy',
      '/v1/tasks',
      '/v1/webhook/test',
      '/v1/webhook',
      '/v1/monitor/check',
      '/v1/monitor',
      '/v1',
      '/health',
    ];
    for (final suffix in suffixes) {
      if (trimmed.toLowerCase().endsWith(suffix)) {
        trimmed = trimmed.substring(0, trimmed.length - suffix.length);
        break;
      }
    }
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    if (trimmed.isEmpty) return '';

    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        (!uri.isScheme('http') && !uri.isScheme('https')) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw AcademicException(
        AcademicStatus.UNTRUSTED_URL,
        '安全策略拦截：Worker 网关地址格式无效或包含非法协议/凭据（$raw）',
      );
    }
    if (uri.isScheme('http') && !_isLoopbackHost(uri.host)) {
      throw const AcademicException(
        AcademicStatus.UNTRUSTED_URL,
        '安全策略拦截：非本地环回的有状态 Worker 网关必须使用 HTTPS 加密传输',
      );
    }
    return trimmed;
  }

  /// 探测有状态 Worker 网关 `GET /health` 是否在线，并识别是否误填了无状态 Relay 地址。
  static Future<RelayHealthStatus> probeUrl(
    String workerBaseUrl, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final String normalized;
    try {
      normalized = normalizeWorkerBaseUrl(workerBaseUrl);
    } on AcademicException catch (error) {
      return RelayHealthStatus(
        ok: false,
        endpoint: workerBaseUrl.trim(),
        latencyMs: 0,
        message: error.message,
      );
    }
    if (normalized.isEmpty) {
      return const RelayHealthStatus(
        ok: false,
        endpoint: '',
        latencyMs: 0,
        message: '未填写有状态 Worker 地址',
      );
    }

    final endpoint = '$normalized/health';
    final uri = Uri.tryParse(endpoint);
    if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      return RelayHealthStatus(
        ok: false,
        endpoint: endpoint,
        latencyMs: 0,
        message: 'Worker 地址格式无效：$workerBaseUrl',
      );
    }

    final ownsClient = client == null;
    final activeClient = client ?? http.Client();
    final watch = Stopwatch()..start();
    try {
      final res = await activeClient
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(timeout);
      watch.stop();
      if (res.statusCode != 200) {
        return RelayHealthStatus(
          ok: false,
          statusCode: res.statusCode,
          endpoint: endpoint,
          latencyMs: watch.elapsedMilliseconds,
          message: 'Worker 网关返回 HTTP ${res.statusCode}',
        );
      }

      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is Map && decoded['ok'] == true) {
        final service = decoded['service']?.toString() ?? '';
        if (service != 'courselens-session-gateway') {
          final isStatelessRelay = service.toLowerCase().contains('relay');
          return RelayHealthStatus(
            ok: false,
            statusCode: res.statusCode,
            service: service,
            endpoint: endpoint,
            latencyMs: watch.elapsedMilliseconds,
            message: isStatelessRelay
                ? '该地址是无状态 Web 转发中继（$service），请部署并填写 workers/session_gateway 有状态会话网关地址'
                : '目标服务不是有状态会话网关（service=$service），请检查 workers/session_gateway 部署地址',
          );
        }
        return RelayHealthStatus(
          ok: true,
          statusCode: res.statusCode,
          service: service,
          endpoint: endpoint,
          latencyMs: watch.elapsedMilliseconds,
          message: '有状态 Worker 网关在线（${watch.elapsedMilliseconds} ms）',
        );
      }

      return RelayHealthStatus(
        ok: false,
        statusCode: res.statusCode,
        endpoint: endpoint,
        latencyMs: watch.elapsedMilliseconds,
        message: 'Worker 网关健康检查响应格式不匹配',
      );
    } on TimeoutException {
      watch.stop();
      return RelayHealthStatus(
        ok: false,
        endpoint: endpoint,
        latencyMs: watch.elapsedMilliseconds,
        message: '连接有状态 Worker 网关超时',
      );
    } catch (error) {
      watch.stop();
      return RelayHealthStatus(
        ok: false,
        endpoint: endpoint,
        latencyMs: watch.elapsedMilliseconds,
        message: '无法连接有状态 Worker 网关：$error',
      );
    } finally {
      if (ownsClient) {
        activeClient.close();
      }
    }
  }

  /// 使用 API Key 查询或按需激活云端托管的教务会话（`GET /v1/session`）。
  static Future<WorkerRemoteSessionInfo> fetchRemoteSession({
    required String workerBaseUrl,
    required String apiKey,
    bool offline = false,
    http.Client? client,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final decoded = await _callControlJson(
      workerBaseUrl: workerBaseUrl,
      apiKey: apiKey,
      method: 'GET',
      subPath: offline ? '/v1/session?offline=1' : '/v1/session',
      client: client,
      timeout: timeout,
    );
    return WorkerRemoteSessionInfo.fromJson(decoded);
  }

  /// 使用 API Key 强制触发云端重新登录并刷新 `CookieJar`（`POST /v1/session/refresh`）。
  static Future<WorkerRemoteSessionInfo> refreshRemoteSession({
    required String workerBaseUrl,
    required String apiKey,
    http.Client? client,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final decoded = await _callControlJson(
      workerBaseUrl: workerBaseUrl,
      apiKey: apiKey,
      method: 'POST',
      subPath: '/v1/session/refresh',
      client: client,
      timeout: timeout,
    );
    return WorkerRemoteSessionInfo.fromJson(decoded);
  }

  /// 动态推送扫码/WebView/SSO 登录后的会话 Cookie 至云端 Durable Object（`POST /v1/session/cookies`）。
  static Future<WorkerRemoteSessionInfo> pushSessionCookies({
    required String workerBaseUrl,
    required String apiKey,
    required Object cookies,
    String? portalUrl,
    String? systemId,
    String? username,
    int? keepaliveIntervalSec,
    http.Client? client,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final decoded = await _callControlJson(
      workerBaseUrl: workerBaseUrl,
      apiKey: apiKey,
      method: 'POST',
      subPath: '/v1/session/cookies',
      body: <String, Object?>{
        'cookies': cookies,
        if (portalUrl != null && portalUrl.trim().isNotEmpty)
          'portalUrl': portalUrl.trim(),
        if (systemId != null && systemId.trim().isNotEmpty)
          'systemId': systemId.trim(),
        if (username != null && username.trim().isNotEmpty)
          'username': username.trim(),
        'keepaliveIntervalSec': ?keepaliveIntervalSec,
      },
      client: client,
      timeout: timeout,
    );
    return WorkerRemoteSessionInfo.fromJson(decoded);
  }

  /// 使用 API Key 显式清空云端 Durable Object 中加密持久化的 `CookieJar`（`DELETE /v1/session`）。
  static Future<void> deleteRemoteSession({
    required String workerBaseUrl,
    required String apiKey,
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    await _callControlJson(
      workerBaseUrl: workerBaseUrl,
      apiKey: apiKey,
      method: 'DELETE',
      subPath: '/v1/session',
      client: client,
      timeout: timeout,
    );
  }

  // ---------------------------------------------------------------------------
  // 统一云端任务中心 API (/v1/tasks & /v1/tasks/:taskId)
  // ---------------------------------------------------------------------------

  static Future<CloudTaskListSnapshot> fetchCloudTasks({
    required String workerBaseUrl,
    required String apiKey,
    http.Client? client,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final decoded = await _callControlJson(
      workerBaseUrl: workerBaseUrl,
      apiKey: apiKey,
      method: 'GET',
      subPath: '/v1/tasks',
      client: client,
      timeout: timeout,
    );
    return CloudTaskListSnapshot.fromJson(decoded);
  }

  static Future<CloudTaskDetail> fetchCloudTaskDetail({
    required String workerBaseUrl,
    required String apiKey,
    required String taskId,
    http.Client? client,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final cleanId = taskId.trim();
    if (cleanId.isEmpty) {
      throw const AcademicException(
        AcademicStatus.VALIDATION_FAILED,
        '未指定云端任务 ID',
      );
    }
    final decoded = await _callControlJson(
      workerBaseUrl: workerBaseUrl,
      apiKey: apiKey,
      method: 'GET',
      subPath: '/v1/tasks/${Uri.encodeComponent(cleanId)}',
      client: client,
      timeout: timeout,
    );
    return CloudTaskDetail.fromJson(decoded);
  }

  static Future<CloudTaskDetail> patchCloudTask({
    required String workerBaseUrl,
    required String apiKey,
    required String taskId,
    required Map<String, Object?> patch,
    http.Client? client,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final cleanId = taskId.trim();
    if (cleanId.isEmpty) {
      throw const AcademicException(
        AcademicStatus.VALIDATION_FAILED,
        '未指定云端任务 ID',
      );
    }
    final decoded = await _callControlJson(
      workerBaseUrl: workerBaseUrl,
      apiKey: apiKey,
      method: 'PATCH',
      subPath: '/v1/tasks/${Uri.encodeComponent(cleanId)}',
      body: patch,
      client: client,
      timeout: timeout,
    );
    return CloudTaskDetail.fromJson(decoded);
  }

  static Future<CloudTaskDetail> runCloudTask({
    required String workerBaseUrl,
    required String apiKey,
    required String taskId,
    bool confirmed = false,
    http.Client? client,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final cleanId = taskId.trim();
    if (cleanId.isEmpty) {
      throw const AcademicException(
        AcademicStatus.VALIDATION_FAILED,
        '未指定云端任务 ID',
      );
    }
    final decoded = await _callControlJson(
      workerBaseUrl: workerBaseUrl,
      apiKey: apiKey,
      method: 'POST',
      subPath: '/v1/tasks/${Uri.encodeComponent(cleanId)}/run',
      body: <String, Object?>{
        if (confirmed) 'confirmed': true,
      },
      client: client,
      timeout: timeout,
    );
    return CloudTaskDetail.fromJson(decoded);
  }

  static Future<void> deleteCloudTask({
    required String workerBaseUrl,
    required String apiKey,
    required String taskId,
    http.Client? client,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final cleanId = taskId.trim();
    if (cleanId.isEmpty) {
      throw const AcademicException(
        AcademicStatus.VALIDATION_FAILED,
        '未指定云端任务 ID',
      );
    }
    await _callControlJson(
      workerBaseUrl: workerBaseUrl,
      apiKey: apiKey,
      method: 'DELETE',
      subPath: '/v1/tasks/${Uri.encodeComponent(cleanId)}',
      client: client,
      timeout: timeout,
    );
  }

  // ---------------------------------------------------------------------------
  // Webhook 通知与成绩/考试巡检 API (/v1/webhook* & /v1/monitor*)
  // ---------------------------------------------------------------------------

  static Future<WorkerWebhookConfig> fetchWebhookConfig({
    required String workerBaseUrl,
    required String apiKey,
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final decoded = await _callControlJson(
      workerBaseUrl: workerBaseUrl,
      apiKey: apiKey,
      method: 'GET',
      subPath: '/v1/webhook',
      client: client,
      timeout: timeout,
    );
    return WorkerWebhookConfig.fromJson(decoded);
  }

  static Future<WorkerWebhookConfig> saveWebhookConfig({
    required String workerBaseUrl,
    required String apiKey,
    required Map<String, Object?> payload,
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final decoded = await _callControlJson(
      workerBaseUrl: workerBaseUrl,
      apiKey: apiKey,
      method: 'PUT',
      subPath: '/v1/webhook',
      body: payload,
      client: client,
      timeout: timeout,
    );
    return WorkerWebhookConfig.fromJson(decoded);
  }

  static Future<WorkerWebhookConfig> deleteWebhookConfig({
    required String workerBaseUrl,
    required String apiKey,
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final decoded = await _callControlJson(
      workerBaseUrl: workerBaseUrl,
      apiKey: apiKey,
      method: 'DELETE',
      subPath: '/v1/webhook',
      client: client,
      timeout: timeout,
    );
    return WorkerWebhookConfig.fromJson(decoded);
  }

  static Future<WorkerWebhookConfig> testWebhook({
    required String workerBaseUrl,
    required String apiKey,
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final decoded = await _callControlJson(
      workerBaseUrl: workerBaseUrl,
      apiKey: apiKey,
      method: 'POST',
      subPath: '/v1/webhook/test',
      client: client,
      timeout: timeout,
    );
    return WorkerWebhookConfig.fromJson(decoded);
  }

  static Future<WorkerMonitorStatus> fetchMonitorStatus({
    required String workerBaseUrl,
    required String apiKey,
    http.Client? client,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final decoded = await _callControlJson(
      workerBaseUrl: workerBaseUrl,
      apiKey: apiKey,
      method: 'GET',
      subPath: '/v1/monitor',
      client: client,
      timeout: timeout,
    );
    return WorkerMonitorStatus.fromJson(decoded);
  }

  static Future<WorkerMonitorStatus> saveMonitorConfig({
    required String workerBaseUrl,
    required String apiKey,
    required Map<String, Object?> payload,
    http.Client? client,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final decoded = await _callControlJson(
      workerBaseUrl: workerBaseUrl,
      apiKey: apiKey,
      method: 'PATCH',
      subPath: '/v1/monitor',
      body: payload,
      client: client,
      timeout: timeout,
    );
    return WorkerMonitorStatus.fromJson(decoded);
  }

  static Future<WorkerMonitorStatus> runMonitorCheck({
    required String workerBaseUrl,
    required String apiKey,
    String kind = 'all',
    http.Client? client,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final decoded = await _callControlJson(
      workerBaseUrl: workerBaseUrl,
      apiKey: apiKey,
      method: 'POST',
      subPath: '/v1/monitor/check',
      body: <String, Object?>{'kind': kind},
      client: client,
      timeout: timeout,
    );
    return WorkerMonitorStatus.fromJson(decoded);
  }

  static Future<Map<String, dynamic>> _callControlJson({
    required String workerBaseUrl,
    required String apiKey,
    required String method,
    required String subPath,
    Map<String, Object?>? body,
    bool writeMayHaveCommitted = false,
    http.Client? client,
    required Duration timeout,
  }) async {
    final normalized = normalizeWorkerBaseUrl(workerBaseUrl);
    if (normalized.isEmpty) {
      throw const AcademicException(
        AcademicStatus.VALIDATION_FAILED,
        '未提供有状态 Worker 地址',
      );
    }
    final cleanKey = apiKey.trim();
    if (cleanKey.isEmpty) {
      throw const AcademicException(
        AcademicStatus.INVALID_CREDENTIALS,
        '未提供 Worker API Key',
      );
    }

    final uri = Uri.tryParse('$normalized$subPath');
    if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      throw AcademicException(
        AcademicStatus.VALIDATION_FAILED,
        'Worker 地址格式无效：$workerBaseUrl',
      );
    }

    final ownsClient = client == null;
    final activeClient = client ?? http.Client();
    try {
      final headers = <String, String>{
        'Accept': 'application/json',
        'Authorization': 'Bearer $cleanKey',
        if (body != null) 'Content-Type': 'application/json',
      };
      final encodedBody = body != null ? jsonEncode(body) : null;
      final http.Response raw;
      switch (method.toUpperCase()) {
        case 'POST':
          raw = await activeClient
              .post(uri, headers: headers, body: encodedBody)
              .timeout(timeout);
        case 'PUT':
          raw = await activeClient
              .put(uri, headers: headers, body: encodedBody)
              .timeout(timeout);
        case 'PATCH':
          raw = await activeClient
              .patch(uri, headers: headers, body: encodedBody)
              .timeout(timeout);
        case 'DELETE':
          raw = await activeClient
              .delete(uri, headers: headers, body: encodedBody)
              .timeout(timeout);
        default:
          raw = await activeClient.get(uri, headers: headers).timeout(timeout);
      }
      final decoded = _decodeJsonMap(raw);
      if (raw.statusCode >= 400) {
        throw _mapGatewayError(raw.statusCode, decoded);
      }
      return decoded;
    } on AcademicException {
      rethrow;
    } on TimeoutException {
      throw AcademicException(
        writeMayHaveCommitted
            ? AcademicStatus.RESULT_UNKNOWN
            : AcademicStatus.NETWORK_RETRYABLE,
        '连接有状态 Worker 接口超时，请检查 Worker 或教务站是否在线',
      );
    } catch (error) {
      throw AcademicException(
        AcademicStatus.NETWORK_RETRYABLE,
        '无法连接有状态 Worker：$error',
      );
    } finally {
      if (ownsClient) {
        activeClient.close();
      }
    }
  }

  Future<WorkerRemoteSessionInfo> getSession({bool offline = false}) =>
      fetchRemoteSession(
        workerBaseUrl: _workerBaseUrlProvider(),
        apiKey: _apiKeyProvider(),
        offline: offline,
        client: _client,
        timeout: timeout,
      );

  Future<WorkerRemoteSessionInfo> refreshSession() => refreshRemoteSession(
        workerBaseUrl: _workerBaseUrlProvider(),
        apiKey: _apiKeyProvider(),
        client: _client,
        timeout: timeout,
      );

  Future<void> deleteSession() => deleteRemoteSession(
        workerBaseUrl: _workerBaseUrlProvider(),
        apiKey: _apiKeyProvider(),
        client: _client,
        timeout: timeout,
      );

  @override
  Future<HttpResponse> execute(HttpRequest request) async {
    final workerBase = normalizeWorkerBaseUrl(_workerBaseUrlProvider());
    if (workerBase.isEmpty) {
      throw const AcademicException(
        AcademicStatus.NETWORK_RETRYABLE,
        '未配置有状态 Cloudflare Worker 地址',
      );
    }

    final apiKey = _apiKeyProvider().trim();
    if (apiKey.isEmpty) {
      throw const AcademicException(
        AcademicStatus.INVALID_CREDENTIALS,
        '缺少有状态 Worker API Key，请重新输入 API Key',
      );
    }

    final policy = _policyProvider?.call();
    if (policy != null &&
        policy.allowedHosts.isNotEmpty &&
        !HostPolicy.isAllowed(
          request.url,
          policy.allowedHosts,
          policy.requireSecure,
        )) {
      throw AcademicException(
        AcademicStatus.UNTRUSTED_URL,
        '目标域名不在学校白名单内：${request.url}',
      );
    }

    final sanitizedHeaders = <String, String>{};
    for (final entry in request.headers.entries) {
      final lower = entry.key.toLowerCase();
      if (_strippedClientHeaders.contains(lower) || lower.startsWith('cf-')) {
        continue;
      }
      sanitizedHeaders[entry.key] = entry.value;
    }

    final endpoint = '$workerBase/v1/proxy';
    final payload = <String, Object?>{
      'method': request.method.wireName,
      'url': request.url,
      'headers': sanitizedHeaders,
      if (request.body != null && request.body!.isNotEmpty)
        'bodyBase64': Base64Codec.encode(request.body!),
      'followRedirects': request.followRedirects,
    };

    final http.Response raw;
    try {
      raw = await _client
          .post(
            Uri.parse(endpoint),
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode(payload),
          )
          .timeout(timeout);
    } on TimeoutException {
      // Security Redline #3: Never mask an in-flight POST timeout.
      final status = request.method == HttpMethod.post
          ? AcademicStatus.RESULT_UNKNOWN
          : AcademicStatus.NETWORK_RETRYABLE;
      throw AcademicException(
        status,
        '连接有状态 Worker 网关超时，请检查网关或教务上游状态',
      );
    } catch (error) {
      throw AcademicException(
        AcademicStatus.NETWORK_RETRYABLE,
        '无法连接有状态 Worker 网关：$error',
      );
    }

    final decoded = _decodeJsonMap(raw);
    if (raw.statusCode >= 400) {
      throw _mapGatewayError(raw.statusCode, decoded);
    }

    final status = (decoded['status'] as num?)?.toInt() ?? raw.statusCode;
    final finalUrl = decoded['finalUrl'] as String? ?? request.url;
    final headers = <String, List<String>>{};
    final rawHeaders = decoded['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        final key = entry.key.toString();
        if (key.toLowerCase() == 'set-cookie') continue;
        final val = entry.value;
        if (val is List) {
          headers[key] = val.map((e) => e.toString()).toList();
        } else if (val != null) {
          headers[key] = <String>[val.toString()];
        }
      }
    }

    final bodyB64 = decoded['bodyBase64'] as String? ?? '';
    final bodyBytes = bodyB64.isEmpty
        ? Uint8List(0)
        : (Base64Codec.decode(bodyB64) ?? Uint8List(0));

    return HttpResponse(
      status: status,
      finalUrl: finalUrl,
      headers: headers,
      body: bodyBytes,
      cookies: const <StoredCookie>[],
    );
  }

  static Map<String, dynamic> _decodeJsonMap(http.Response raw) {
    try {
      final parsed = jsonDecode(utf8.decode(raw.bodyBytes));
      if (parsed is Map) {
        return Map<String, dynamic>.from(parsed);
      }
    } catch (_) {
      // Handled below.
    }
    throw AcademicException(
      AcademicStatus.NETWORK_RETRYABLE,
      '有状态 Worker 返回了非预期响应（HTTP ${raw.statusCode}）',
    );
  }

  static AcademicException _mapGatewayError(
    int httpStatus,
    Map<String, dynamic> decoded,
  ) {
    final code = (decoded['status'] as String? ?? '').trim();
    final message = (decoded['error'] as String? ?? '').trim().isNotEmpty
        ? (decoded['error'] as String).trim()
        : 'Worker 请求失败（HTTP $httpStatus）';

    if (httpStatus == 401 && code.isEmpty) {
      return AcademicException(AcademicStatus.INVALID_CREDENTIALS, message);
    }

    final mapped = switch (code) {
      'UNAUTHORIZED' ||
      'INVALID_API_KEY' ||
      'INVALID_CREDENTIALS' =>
        AcademicStatus.INVALID_CREDENTIALS,
      'SESSION_EXPIRED' => AcademicStatus.SESSION_EXPIRED,
      'CAPTCHA_REQUIRED' => AcademicStatus.CAPTCHA_REQUIRED,
      'UNTRUSTED_URL' || 'FORBIDDEN_ORIGIN' => AcademicStatus.UNTRUSTED_URL,
      'RESULT_UNKNOWN' => AcademicStatus.RESULT_UNKNOWN,
      'CONFIG_ERROR' ||
      'VALIDATION_FAILED' ||
      'PAYLOAD_TOO_LARGE' ||
      'NOT_FOUND' =>
        AcademicStatus.VALIDATION_FAILED,
      'WEBHOOK_FAILED' => AcademicStatus.NETWORK_RETRYABLE,
      _ => httpStatus == 401
          ? AcademicStatus.INVALID_CREDENTIALS
          : AcademicStatus.NETWORK_RETRYABLE,
    };
    return AcademicException(mapped, message);
  }
}
