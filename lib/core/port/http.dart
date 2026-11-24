import 'dart:async';
import 'dart:typed_data';

/// 通过异步 Zone 向下游网关引擎传递「跳过服务端代理缓存」意图，避免污染发往教务源站的请求头。
abstract final class HttpCacheScope {
  static final Object _bypassCacheZoneKey = Object();

  /// 当前异步调用链是否要求跳过远端有状态 Worker 代理缓存。
  static bool get isBypassCache => Zone.current[_bypassCacheZoneKey] == true;

  /// 在跳过服务端代理缓存的上下文中执行 [action]（常用于手动强制刷新）。
  static Future<T> runBypassingCache<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: <Object, Object>{_bypassCacheZoneKey: true});
}

/// 平台无关的 HTTP 方法定义。
enum HttpMethod {
  get('GET'),
  post('POST');

  const HttpMethod(this.wireName);
  final String wireName;
}

/// 平台无关的 HTTP 请求对象。
///
/// 请求头使用单值映射；[followRedirects] 默认为 `true`，仅在需要直接观察 3xx 状态码与
/// 票据响应头的协议步骤（如正方定制 CAS 登录提交）显式设为 `false`。
class HttpRequest {
  HttpRequest({
    required this.method,
    required this.url,
    Map<String, String> headers = const {},
    Uint8List? body,
    this.followRedirects = true,
    this.confirmedSelection = false,
  })  : headers = Map.unmodifiable(headers),
        body = body == null ? null : Uint8List.fromList(body);

  final HttpMethod method;
  final String url;
  final Map<String, String> headers;
  final Uint8List? body;
  final bool followRedirects;
  final bool confirmedSelection;

  @override
  String toString() =>
      'HttpRequest(${method.wireName}, $url, headers=${headers.length}, body=${body?.length ?? 0}B)';
}

/// 平台无关的 HTTP 响应对象。
///
/// 响应头采用多值映射以完整保留多条 `Set-Cookie`。
class HttpResponse {
  HttpResponse({
    required this.status,
    required this.finalUrl,
    Map<String, List<String>> headers = const {},
    Uint8List? body,
    List<StoredCookie> cookies = const [],
  })  : headers = Map.unmodifiable(
          headers.map((k, v) => MapEntry(k, List<String>.unmodifiable(v))),
        ),
        body = body == null ? Uint8List(0) : Uint8List.fromList(body),
        cookies = List.unmodifiable(cookies);

  final int status;
  final String finalUrl;
  final Map<String, List<String>> headers;
  final Uint8List body;
  final List<StoredCookie> cookies;

  @override
  String toString() => 'HttpResponse($status, $finalUrl, body=${body.length}B)';
}

/// 平台无关的 HTTP 传输端口。
///
/// 所有实现只允许抛出 `AcademicException`。
abstract interface class HttpEngine {
  Future<HttpResponse> execute(HttpRequest request);
}

/// 一条已存储的 Cookie。域/路径匹配规则由 core 的 `CookieJar` 统一裁决。
class StoredCookie {
  const StoredCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
    required this.secure,
    this.httpOnly = false,
    this.expiresAtEpochSeconds,
    this.hostOnly = true,
  });

  final String name;
  final String value;
  final String domain;
  final String path;
  final bool secure;
  final bool httpOnly;
  final int? expiresAtEpochSeconds;
  final bool hostOnly;

  Map<String, dynamic> toJson() => {
        'name': name,
        'value': value,
        'domain': domain,
        'path': path,
        'secure': secure,
        'httpOnly': httpOnly,
        'expiresAtEpochSeconds': expiresAtEpochSeconds,
        'hostOnly': hostOnly,
      };

  factory StoredCookie.fromJson(Map<String, dynamic> json) => StoredCookie(
        name: json['name'] as String? ?? '',
        value: json['value'] as String? ?? '',
        domain: json['domain'] as String? ?? '',
        path: json['path'] as String? ?? '/',
        secure: json['secure'] as bool? ?? false,
        httpOnly: json['httpOnly'] as bool? ?? false,
        expiresAtEpochSeconds: (json['expiresAtEpochSeconds'] as num?)?.toInt(),
        hostOnly: json['hostOnly'] as bool? ?? true,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StoredCookie &&
          name == other.name &&
          value == other.value &&
          domain == other.domain &&
          path == other.path &&
          secure == other.secure &&
          httpOnly == other.httpOnly &&
          expiresAtEpochSeconds == other.expiresAtEpochSeconds &&
          hostOnly == other.hostOnly;

  @override
  int get hashCode => Object.hash(
        name,
        value,
        domain,
        path,
        secure,
        httpOnly,
        expiresAtEpochSeconds,
        hostOnly,
      );

  @override
  String toString() =>
      'StoredCookie($name, domain=$domain, path=$path, secure=$secure, hostOnly=$hostOnly)';
}

abstract interface class CookieStore {
  List<StoredCookie> load(String host);
  void save(String host, List<StoredCookie> cookies);
  void clear();
}
