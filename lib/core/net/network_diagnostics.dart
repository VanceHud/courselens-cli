import '../model/academic_status.dart';

/// 网络不可达与传输层故障的细分语义类别（纯 Dart，零平台依赖）。
enum NetworkFailureKind {
  /// 设备断网、DNS 解析失败或无可用路由（含未连校园网导致内网域名无法解析）。
  deviceOffline,

  /// 连接教务服务器或网关等待上游响应超时（常见于未挂校园网 VPN 的黑洞路由或教务拥堵）。
  upstreamTimeout,

  /// 教务服务器拒绝连接、重置连接或网关返回 502/503/504 维护状态。
  upstreamUnavailable,

  /// Web 端本地或自建无状态中继（Relay）不可达。
  relayUnreachable,

  /// 有状态 Cloudflare Worker 云端网关自身不可达。
  workerUnreachable,

  /// TLS / SSL 证书校验或握手异常。
  tlsError,

  /// 其他可重试网络传输异常。
  unknownNetwork,
}

/// 面向 UI 展示与诊断的结构化网络故障描述。
class NetworkDiagnostic {
  const NetworkDiagnostic({
    required this.kind,
    required this.shortLabel,
    required this.userMessage,
    required this.technicalHint,
    this.isRetryable = true,
  });

  final NetworkFailureKind kind;
  final String shortLabel;
  final String userMessage;
  final String technicalHint;
  final bool isRetryable;
}

/// 统一的网络异常分类与人性化中文文案清洗器。
///
/// 消除底层 `SocketException`、`ClientException`、操作系统 `errno` 及原始枚举名泄漏，
/// 同时严格遵守 `lib/core/` 纯 Dart 纯度红线。
abstract final class NetworkDiagnostics {
  static final RegExp _rawWrapperPrefix = RegExp(
    r'^(?:AcademicException\([A-Z_]+:\s*|ClientException(?:\s+with\s+SocketException)?:\s*|SocketException:\s*|HandshakeException:\s*|HttpException:\s*|网络连接失败：\s*|HTTP 协议错误：\s*)+',
    caseSensitive: false,
  );

  static final RegExp _osErrorTail = RegExp(
    r'\s*\(OS Error:[^)]*\)\s*(?:,\s*address\s*=\s*[^,)]+(?:,\s*port\s*=\s*\d+)?)?',
    caseSensitive: false,
  );

  /// 判断任意异常对象是否属于可重试的网络/不可达故障。
  static bool isNetworkFailure(Object error) {
    if (error is AcademicException) {
      return error.status == AcademicStatus.NETWORK_RETRYABLE;
    }
    final lower = error.toString().toLowerCase();
    return lower.contains('socketexception') ||
        lower.contains('clientexception') ||
        lower.contains('timeoutexception') ||
        lower.contains('handshakeexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('network is unreachable') ||
        lower.contains('no address associated with hostname') ||
        lower.contains('connection refused') ||
        lower.contains('connection timed out') ||
        lower.contains('connection reset') ||
        lower.contains('failed to fetch') ||
        lower.contains('xmlhttprequest error');
  }

  /// 对网络异常进行语义归类并生成面向用户的温和中文提示。
  static NetworkDiagnostic classify(
    Object error, {
    bool isWorkerMode = false,
    bool isWebRelay = false,
  }) {
    final raw = error is AcademicException ? error.message : error.toString();
    final fullLower = '$raw ${error is AcademicException ? (error.cause ?? '') : ''}'
        .toLowerCase();
    final hint = _sanitizeTechnicalHint(raw);

    // 1. TLS / 证书错误
    if (fullLower.contains('tls') ||
        fullLower.contains('ssl') ||
        fullLower.contains('handshake') ||
        fullLower.contains('certificate') ||
        fullLower.contains('证书')) {
      return NetworkDiagnostic(
        kind: NetworkFailureKind.tlsError,
        shortLabel: '安全连接异常',
        userMessage: '服务器安全证书握手失败，请检查系统时间、校园网认证门户劫持或网络代理设置',
        technicalHint: hint,
      );
    }

    // 2. Web 无状态中继未启动或不可达
    final mentionsRelay = fullLower.contains('无状态中继') ||
        fullLower.contains('relay') ||
        fullLower.contains('127.0.0.1:8787') ||
        fullLower.contains('localhost:8787') ||
        (isWebRelay &&
            !isWorkerMode &&
            (fullLower.contains('failed to fetch') ||
                fullLower.contains('xmlhttprequest') ||
                fullLower.contains('connection refused') ||
                fullLower.contains('无法连接中继')));
    if (mentionsRelay) {
      return NetworkDiagnostic(
        kind: NetworkFailureKind.relayUnreachable,
        shortLabel: 'Web 中继未连接',
        userMessage: '无法连接 Web 无状态中继服务，请确认本机或远端 Relay 已启动，或切换至云端 Worker 模式',
        technicalHint: hint,
      );
    }

    // 3. 有状态 Worker 云端网关区分「网关自身不可达」与「网关在线但上游教务不可达」
    final mentionsUpstreamFromGateway = fullLower.contains('上游教务') ||
        fullLower.contains('upstream') ||
        fullLower.contains('bad gateway') ||
        fullLower.contains('502') ||
        fullLower.contains('503') ||
        fullLower.contains('504');
    if (isWorkerMode && !mentionsUpstreamFromGateway) {
      if (fullLower.contains('timeout') || fullLower.contains('超时')) {
        return NetworkDiagnostic(
          kind: NetworkFailureKind.upstreamTimeout,
          shortLabel: '云端同步超时',
          userMessage: '等待云端 Worker 或学校教务响应超时，请检查当前网络连接或稍后重试',
          technicalHint: hint,
        );
      }
      if (fullLower.contains('failed host lookup') ||
          fullLower.contains('network is unreachable') ||
          fullLower.contains('no address associated') ||
          fullLower.contains('errno = 7') ||
          fullLower.contains('errno = 8') ||
          fullLower.contains('errno = 101') ||
          fullLower.contains('failed to fetch') ||
          fullLower.contains('无法连接有状态 worker') ||
          fullLower.contains('连接云端网关失败') ||
          fullLower.contains('请求云端 worker 失败')) {
        return NetworkDiagnostic(
          kind: NetworkFailureKind.workerUnreachable,
          shortLabel: '当前离线或网关不可达',
          userMessage: '当前设备网络不可用或无法连接云端 Worker 网关，请检查 Wi-Fi / 移动数据连接',
          technicalHint: hint,
        );
      }
    }

    // 4. DNS 失败 / 设备断网 / 内网域名无法解析
    if (fullLower.contains('failed host lookup') ||
        fullLower.contains('no address associated with hostname') ||
        fullLower.contains('nodename nor servname provided') ||
        fullLower.contains('getaddrinfo') ||
        fullLower.contains('network is unreachable') ||
        fullLower.contains('no route to host') ||
        fullLower.contains('software caused connection abort') ||
        fullLower.contains('errno = 7') ||
        fullLower.contains('errno = 8') ||
        fullLower.contains('errno = 51') ||
        fullLower.contains('errno = 101') ||
        fullLower.contains('errno = 103')) {
      return NetworkDiagnostic(
        kind: NetworkFailureKind.deviceOffline,
        shortLabel: '离线或未接入校园网',
        userMessage: '当前网络不可用或无法解析教务域名，请检查网络连接或接入校园网 VPN',
        technicalHint: hint,
      );
    }

    // 5. 请求或连接超时
    if (fullLower.contains('timeout') ||
        fullLower.contains('timed out') ||
        fullLower.contains('超时') ||
        fullLower.contains('errno = 60') ||
        fullLower.contains('errno = 110')) {
      return NetworkDiagnostic(
        kind: NetworkFailureKind.upstreamTimeout,
        shortLabel: '连接教务超时',
        userMessage: isWorkerMode
            ? '云端网关访问学校教务超时，可能教务系统正处于高峰拥堵或临时维护'
            : '连接学校教务服务器超时，请确认已接入校园网 / VPN，或稍后重试',
        technicalHint: hint,
      );
    }

    // 6. 目标端口拒绝 / 502-504 维护 / 连接重置
    if (fullLower.contains('connection refused') ||
        fullLower.contains('connection reset') ||
        fullLower.contains('broken pipe') ||
        fullLower.contains('connection closed') ||
        fullLower.contains('errno = 61') ||
        fullLower.contains('errno = 104') ||
        fullLower.contains('errno = 111') ||
        mentionsUpstreamFromGateway) {
      return NetworkDiagnostic(
        kind: NetworkFailureKind.upstreamUnavailable,
        shortLabel: '教务服务暂不可达',
        userMessage: '学校教务服务器暂时无法响应（可能处于停机维护或仅限校园网访问），请稍后重试',
        technicalHint: hint,
      );
    }

    // 7. 兜底网络异常
    return NetworkDiagnostic(
      kind: NetworkFailureKind.unknownNetwork,
      shortLabel: '网络连接受限',
      userMessage: isWorkerMode
          ? '暂时无法完成云端同步，请检查网络连接后重试'
          : '暂时无法连接教务服务器，请检查网络连接或校园网 VPN 后重试',
      technicalHint: hint,
    );
  }

  /// 生成人性化的操作失败提示；若已有本地缓存快照，自动附带缓存时间安抚文案。
  static String formatActionFailure(
    String actionLabel,
    Object error, {
    String? cachedAgeLabel,
    bool isWorkerMode = false,
    bool isWebRelay = false,
  }) {
    final diag = classify(
      error,
      isWorkerMode: isWorkerMode,
      isWebRelay: isWebRelay,
    );
    final cleanCacheAge = cachedAgeLabel?.trim() ?? '';
    if (cleanCacheAge.isNotEmpty) {
      return '$actionLabel暂未成功：${diag.userMessage}（当前展示 $cleanCacheAge 的本地缓存）';
    }
    return '$actionLabel失败：${diag.userMessage}';
  }

  static String _sanitizeTechnicalHint(String raw) {
    var cleaned = raw.trim();
    if (cleaned.isEmpty) return '';
    cleaned = cleaned.replaceFirst(_rawWrapperPrefix, '');
    if (cleaned.endsWith(')')) {
      final openCount = '('.allMatches(cleaned).length;
      final closeCount = ')'.allMatches(cleaned).length;
      if (closeCount > openCount) {
        cleaned = cleaned.substring(0, cleaned.length - 1);
      }
    }
    cleaned = cleaned.replaceAll(_osErrorTail, '').trim();
    if (cleaned.length > 96) {
      cleaned = '${cleaned.substring(0, 96)}…';
    }
    return cleaned;
  }
}
