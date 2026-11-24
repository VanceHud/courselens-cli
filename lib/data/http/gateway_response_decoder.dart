import 'dart:convert' hide Base64Codec;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/courselens_core.dart';
import 'uncertain_write.dart';

/// Web 转发网关（`/v1/forward`）与有状态 Worker（`/v1/proxy` 及控制面接口）共用的
/// JSON 响应解码与网关错误码映射。
class GatewayResponseDecoder {
  const GatewayResponseDecoder({
    required this.unexpectedResponsePrefix,
    required this.requestFailedPrefix,
  });

  /// 响应不是 JSON 对象时的提示前缀，例如「有状态 Worker 返回了非预期响应」。
  final String unexpectedResponsePrefix;

  /// 网关错误体未携带 `error` 文案时的兜底前缀，例如「Worker 请求失败」。
  final String requestFailedPrefix;

  /// 解码网关 JSON 对象；HTTP >= 400 时按网关错误码映射抛出 [AcademicException]。
  Map<String, dynamic> decodeOrThrow(
    http.Response raw, {
    required bool mayHaveCommitted,
  }) {
    final decoded = decodeMap(raw, mayHaveCommitted: mayHaveCommitted);
    if (raw.statusCode >= 400) {
      throw mapError(
        raw.statusCode,
        decoded,
        mayHaveCommitted: mayHaveCommitted,
      );
    }
    return decoded;
  }

  /// 解码网关 JSON 对象。写请求遇到 2xx/5xx 非 JSON 响应（截断或网关/上游中途失败）时
  /// 按红线 #3 归为 `RESULT_UNKNOWN`；4xx 非 JSON 响应来自网关前置层拒绝，仍可重试。
  Map<String, dynamic> decodeMap(
    http.Response raw, {
    required bool mayHaveCommitted,
  }) {
    try {
      final parsed = jsonDecode(utf8.decode(raw.bodyBytes));
      if (parsed is Map) {
        return Map<String, dynamic>.from(parsed);
      }
    } catch (_) {
      // Handled below.
    }
    final rejectedBeforeUpstream =
        raw.statusCode >= 400 && raw.statusCode < 500;
    throw AcademicException(
      uncertainWriteStatus(
        mayHaveCommitted: mayHaveCommitted && !rejectedBeforeUpstream,
      ),
      '$unexpectedResponsePrefix（HTTP ${raw.statusCode}）',
    );
  }

  AcademicException mapError(
    int httpStatus,
    Map<String, dynamic> decoded, {
    bool mayHaveCommitted = false,
  }) {
    final rawCode = decoded['status'];
    final code = rawCode is String ? rawCode.trim() : '';
    final rawError = decoded['error'];
    final message = rawError is String && rawError.trim().isNotEmpty
        ? rawError.trim()
        : '$requestFailedPrefix（HTTP $httpStatus）';

    if (httpStatus == 401 && code.isEmpty) {
      return AcademicException(AcademicStatus.INVALID_CREDENTIALS, message);
    }

    final mapped = switch (code) {
      'UNAUTHORIZED' ||
      'INVALID_API_KEY' ||
      'INVALID_CREDENTIALS' => AcademicStatus.INVALID_CREDENTIALS,
      'SESSION_EXPIRED' => AcademicStatus.SESSION_EXPIRED,
      'CAPTCHA_REQUIRED' => AcademicStatus.CAPTCHA_REQUIRED,
      'UNTRUSTED_URL' || 'FORBIDDEN_ORIGIN' => AcademicStatus.UNTRUSTED_URL,
      'RESULT_UNKNOWN' => AcademicStatus.RESULT_UNKNOWN,
      'CONFIG_ERROR' ||
      'VALIDATION_FAILED' ||
      'PAYLOAD_TOO_LARGE' ||
      'NOT_FOUND' => AcademicStatus.VALIDATION_FAILED,
      'NETWORK_ERROR' || 'WEBHOOK_FAILED' => AcademicStatus.NETWORK_RETRYABLE,
      _ =>
        httpStatus == 401
            ? AcademicStatus.INVALID_CREDENTIALS
            : (httpStatus >= 500
                ? uncertainWriteStatus(mayHaveCommitted: mayHaveCommitted)
                : AcademicStatus.NETWORK_RETRYABLE),
    };
    return AcademicException(mapped, message);
  }

  /// 将网关回传的 `headers`（值为字符串或字符串数组）展平为多值头映射。
  static Map<String, List<String>> parseHeaders(
    Object? rawHeaders, {
    bool skipSetCookie = false,
  }) {
    final headers = <String, List<String>>{};
    if (rawHeaders is! Map) return headers;
    for (final entry in rawHeaders.entries) {
      final key = entry.key.toString();
      if (skipSetCookie && key.toLowerCase() == 'set-cookie') continue;
      final val = entry.value;
      if (val is List) {
        headers[key] = val.map((e) => e.toString()).toList();
      } else if (val != null) {
        headers[key] = <String>[val.toString()];
      }
    }
    return headers;
  }

  /// 解码网关回传的 `bodyBase64`，缺省或非法时返回空字节。
  static Uint8List decodeBody(Object? bodyBase64) {
    final b64 = bodyBase64 is String ? bodyBase64 : '';
    return b64.isEmpty
        ? Uint8List(0)
        : (Base64Codec.decode(b64) ?? Uint8List(0));
  }
}
