import 'dart:async';

import '../model/academic_status.dart';
import '../port/http.dart';
import 'host_policy.dart';
import 'transport_policy.dart';

/// 传输安全约束判定（ADR-002 §1 & ADR-006）。
class TransportSecurity {
  const TransportSecurity._();

  static bool isDirectApiAllowed(
    String url, {
    bool requireSecure = TransportPolicy.requireSecurePolicy,
  }) {
    final scheme = schemeOf(url);
    if (scheme == null) return false;
    final lower = scheme.toLowerCase();
    if (lower == 'https') return true;
    return !requireSecure && lower == 'http';
  }

  static String? schemeOf(String url) {
    final separator = url.indexOf('://');
    if (separator <= 0) return null;
    final scheme = url.substring(0, separator);
    final first = scheme.codeUnitAt(0);
    final firstIsLetter =
        (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A);
    if (!firstIsLetter) return null;
    for (var i = 0; i < scheme.length; i++) {
      final c = scheme.codeUnitAt(i);
      final ok = (c >= 0x41 && c <= 0x5A) ||
          (c >= 0x61 && c <= 0x7A) ||
          (c >= 0x30 && c <= 0x39) ||
          c == 0x2B || // '+'
          c == 0x2D || // '-'
          c == 0x2E; // '.'
      if (!ok) return null;
    }
    return scheme;
  }

  static void requireDirectApi(
    String url, {
    bool requireSecure = TransportPolicy.requireSecurePolicy,
  }) {
    if (isDirectApiAllowed(url, requireSecure: requireSecure)) return;
    final scheme = schemeOf(url) ?? '(无协议头)';
    final reason = requireSecure
        ? '直连接口要求 HTTPS（严格模式），实际为 $scheme'
        : '直连接口只接受 HTTP/HTTPS，实际为 $scheme';
    throw AcademicException(
      AcademicStatus.INSECURE_TRANSPORT,
      '$reason：$url',
    );
  }
}

/// 给任意 [HttpEngine] 套上传输协议安全校验。
class GuardedHttpEngine implements HttpEngine {
  GuardedHttpEngine(
    this._delegate, {
    FutureOr<HttpResponse> Function(HttpRequest, AcademicException)? onInsecure,
    bool requireSecure = TransportPolicy.requireSecurePolicy,
  })  : _onInsecure = onInsecure,
        _requireSecure = requireSecure;

  final HttpEngine _delegate;
  final FutureOr<HttpResponse> Function(HttpRequest, AcademicException)?
      _onInsecure;
  final bool _requireSecure;

  @override
  Future<HttpResponse> execute(HttpRequest request) async {
    try {
      TransportSecurity.requireDirectApi(
        request.url,
        requireSecure: _requireSecure,
      );
    } on AcademicException catch (error) {
      if (_onInsecure != null) {
        return await _onInsecure(request, error);
      }
      rethrow;
    }
    return _delegate.execute(request);
  }
}

/// 给任意 [HttpEngine] 套上域名白名单校验及重定向拦截检查。
class HostGuardedHttpEngine implements HttpEngine {
  HostGuardedHttpEngine(
    this._delegate, {
    required List<String> allowedHosts,
    required bool requireSecure,
  })  : _allowedHosts = List.unmodifiable(allowedHosts),
        _requireSecure = requireSecure;

  static const String blockedRedirectHeader = 'X-CourseLens-Blocked-Redirect';

  final HttpEngine _delegate;
  final List<String> _allowedHosts;
  final bool _requireSecure;

  @override
  Future<HttpResponse> execute(HttpRequest request) async {
    if (!HostPolicy.isAllowed(request.url, _allowedHosts, _requireSecure)) {
      throw AcademicException(
        AcademicStatus.UNTRUSTED_URL,
        '目标域名不在学校白名单内：${request.url}',
      );
    }
    final response = await _delegate.execute(request);
    String? blocked;
    for (final entry in response.headers.entries) {
      if (entry.key.toLowerCase() == blockedRedirectHeader.toLowerCase() &&
          entry.value.isNotEmpty) {
        blocked = entry.value.first;
        break;
      }
    }
    if (blocked != null) {
      throw AcademicException(
        AcademicStatus.UNTRUSTED_URL,
        '重定向目标不在学校白名单内，已中止：$blocked',
      );
    }
    return response;
  }
}
