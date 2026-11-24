import 'dart:async';
import 'dart:convert' hide Base64Codec;

import 'package:http/http.dart' as http;

import '../../core/courselens_core.dart';
import 'gateway_response_decoder.dart';
import 'http_policy_provider.dart';
import 'uncertain_write.dart';

/// 无状态 Web 转发网关健康探测结果。
class RelayHealthStatus {
  const RelayHealthStatus({
    required this.ok,
    required this.endpoint,
    required this.latencyMs,
    required this.message,
    this.statusCode,
    this.service = '',
  });

  final bool ok;
  final int? statusCode;
  final String service;
  final int latencyMs;
  final String endpoint;
  final String message;
}

/// 无状态 HTTP 转发引擎（对接用户自建的无状态转发网关 / `--relay`）。
///
/// 浏览器受 CORS 与 `Set-Cookie` 禁读限制无法直连高校教务站；本引擎将单次请求封装为
/// JSON 发往用户自控的无状态转发网关，由网关在服务端逐跳校验 `HostPolicy` 并原样带回多值
/// `Set-Cookie` 与字节流，网关本身不落盘任何凭据或会话。
class RelayHttpEngine implements HttpEngine {
  RelayHttpEngine({
    required HttpPolicyProvider policyProvider,
    http.Client? client,
    int Function()? clock,
    this.timeout = const Duration(seconds: 25),
  })  : _policyProvider = policyProvider,
        _client = client ?? http.Client(),
        _clock = clock ?? _systemEpochSeconds;

  final HttpPolicyProvider _policyProvider;
  final http.Client _client;
  final int Function() _clock;
  final Duration timeout;

  static int _systemEpochSeconds() =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// 检测当前配置的无状态转发网关 `GET /health` 是否在线可用。
  Future<bool> checkHealth({
    String? relayBaseUrlOverride,
    Duration healthTimeout = const Duration(seconds: 5),
  }) async {
    final result = await probeHealth(
      relayBaseUrlOverride: relayBaseUrlOverride,
      healthTimeout: healthTimeout,
    );
    return result.ok;
  }

  /// 探测当前配置的无状态转发网关 `GET /health`，返回延迟与诊断详情。
  Future<RelayHealthStatus> probeHealth({
    String? relayBaseUrlOverride,
    Duration healthTimeout = const Duration(seconds: 5),
  }) {
    final base = (relayBaseUrlOverride ?? _policyProvider().relayBaseUrl).trim();
    return _probeWithClient(
      base,
      client: _client,
      timeout: healthTimeout,
    );
  }

  /// 直接针对任意 Relay 地址执行布尔健康检查。
  static Future<bool> checkUrl(
    String relayBaseUrl, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final status = await probeUrl(
      relayBaseUrl,
      client: client,
      timeout: timeout,
    );
    return status.ok;
  }

  /// 直接针对任意 Relay 地址执行详细健康探测。
  static Future<RelayHealthStatus> probeUrl(
    String relayBaseUrl, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final ownsClient = client == null;
    final activeClient = client ?? http.Client();
    try {
      return await _probeWithClient(
        relayBaseUrl,
        client: activeClient,
        timeout: timeout,
      );
    } finally {
      if (ownsClient) {
        activeClient.close();
      }
    }
  }

  static Future<RelayHealthStatus> _probeWithClient(
    String relayBaseUrl, {
    required http.Client client,
    required Duration timeout,
  }) async {
    final trimmed = relayBaseUrl.trim();
    if (trimmed.isEmpty) {
      return const RelayHealthStatus(
        ok: false,
        endpoint: '',
        latencyMs: 0,
        message: '未填写 Web 转发网关地址',
      );
    }

    final endpoint = _healthEndpoint(trimmed);
    final uri = Uri.tryParse(endpoint);
    if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      return RelayHealthStatus(
        ok: false,
        endpoint: endpoint,
        latencyMs: 0,
        message: '转发网关地址格式无效：$trimmed',
      );
    }

    final watch = Stopwatch()..start();
    try {
      final res = await client
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(timeout);
      watch.stop();
      if (res.statusCode != 200) {
        return RelayHealthStatus(
          ok: false,
          statusCode: res.statusCode,
          endpoint: endpoint,
          latencyMs: watch.elapsedMilliseconds,
          message: '转发网关返回 HTTP ${res.statusCode}',
        );
      }

      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is Map && decoded['ok'] == true) {
        final service = decoded['service']?.toString() ?? '';
        return RelayHealthStatus(
          ok: true,
          statusCode: res.statusCode,
          service: service,
          endpoint: endpoint,
          latencyMs: watch.elapsedMilliseconds,
          message: '转发网关在线（${watch.elapsedMilliseconds} ms）',
        );
      }

      return RelayHealthStatus(
        ok: false,
        statusCode: res.statusCode,
        endpoint: endpoint,
        latencyMs: watch.elapsedMilliseconds,
        message: '转发网关响应格式不匹配',
      );
    } on TimeoutException {
      watch.stop();
      return RelayHealthStatus(
        ok: false,
        endpoint: endpoint,
        latencyMs: watch.elapsedMilliseconds,
        message: '连接转发网关超时',
      );
    } catch (error) {
      watch.stop();
      return RelayHealthStatus(
        ok: false,
        endpoint: endpoint,
        latencyMs: watch.elapsedMilliseconds,
        message: '无法连接转发网关：$error',
      );
    }
  }

  @override
  Future<HttpResponse> execute(HttpRequest request) async {
    final policy = _policyProvider();
    final relayBase = policy.relayBaseUrl.trim();
    if (relayBase.isEmpty) {
      throw const AcademicException(
        AcademicStatus.NETWORK_RETRYABLE,
        'Web 端连接真实教务前需在「设置 -> Web 转发网关」填写无状态 Relay 地址（演示模式无需网关）',
      );
    }

    if (policy.allowedHosts.isNotEmpty &&
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

    final endpoint = _forwardEndpoint(relayBase);
    final payload = <String, Object?>{
      'method': request.method.wireName,
      'url': request.url,
      'headers': request.headers,
      if (request.body != null && request.body!.isNotEmpty)
        'bodyBase64': Base64Codec.encode(request.body!),
      'followRedirects': request.followRedirects,
      'allowedHosts': policy.allowedHosts,
      'requireSecure': policy.requireSecure,
    };

    final writeMayHaveCommitted = request.method == HttpMethod.post;
    final http.Response raw;
    try {
      raw = await _client
          .post(
            Uri.parse(endpoint),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw AcademicException(
        uncertainWriteStatus(mayHaveCommitted: writeMayHaveCommitted),
        '连接 Web 转发网关超时，请检查网关是否在线',
      );
    } catch (error) {
      throw AcademicException(
        uncertainWriteStatus(mayHaveCommitted: writeMayHaveCommitted),
        '无法连接 Web 转发网关：$error',
      );
    }

    final decoded = _gatewayDecoder.decodeOrThrow(
      raw,
      mayHaveCommitted: writeMayHaveCommitted,
    );

    final status = (decoded['status'] as num?)?.toInt() ?? raw.statusCode;
    final finalUrl = decoded['finalUrl'] as String? ?? request.url;
    final headers = GatewayResponseDecoder.parseHeaders(decoded['headers']);
    final bodyBytes = GatewayResponseDecoder.decodeBody(decoded['bodyBase64']);

    final now = _clock();
    final cookies = <StoredCookie>[];
    final hopCookies = decoded['hopCookies'];
    if (hopCookies is List) {
      for (final item in hopCookies) {
        if (item is Map) {
          final hopUrl = Urls.parseUrl(item['url']?.toString() ?? finalUrl);
          final setCookieLine = item['setCookie']?.toString() ?? '';
          if (hopUrl != null && setCookieLine.isNotEmpty) {
            final parsed = SetCookie.parse(setCookieLine, hopUrl, now);
            if (parsed != null) cookies.add(parsed);
          }
        }
      }
    } else {
      final fallbackUrl = Urls.parseUrl(finalUrl);
      if (fallbackUrl != null) {
        for (final entry in headers.entries) {
          if (entry.key.toLowerCase() == 'set-cookie') {
            for (final line in entry.value) {
              final parsed = SetCookie.parse(line, fallbackUrl, now);
              if (parsed != null) cookies.add(parsed);
            }
          }
        }
      }
    }

    return HttpResponse(
      status: status,
      finalUrl: finalUrl,
      headers: headers,
      body: bodyBytes,
      cookies: cookies,
    );
  }

  static const GatewayResponseDecoder _gatewayDecoder = GatewayResponseDecoder(
    unexpectedResponsePrefix: 'Web 转发网关返回了非预期响应',
    requestFailedPrefix: 'Web 转发网关请求失败',
  );

  static String _forwardEndpoint(String base) {
    var trimmed = base.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    if (trimmed.endsWith('/v1/forward')) return trimmed;
    if (trimmed.endsWith('/health')) {
      trimmed = trimmed.substring(0, trimmed.length - '/health'.length);
    }
    return '$trimmed/v1/forward';
  }

  static String _healthEndpoint(String base) {
    var trimmed = base.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    if (trimmed.endsWith('/health')) return trimmed;
    if (trimmed.endsWith('/v1/forward')) {
      trimmed = trimmed.substring(0, trimmed.length - '/v1/forward'.length);
    }
    return '$trimmed/health';
  }
}
