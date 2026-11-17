import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import '../../core/courselens_core.dart';
import 'http_policy_provider.dart';

/// 原生四端（Android / iOS / macOS / Windows）基于 `dart:io` 的 HTTP 引擎。
///
/// 关键安全纪律（Hard Rule 4）：
/// 禁用系统自动重定向，手工逐跳解析 `Location` 并在发包前执行 `HostPolicy.isAllowed` 校验；
/// 任何跳出学校白名单的 3xx 立即中止连接并标记 `X-CourseLens-Blocked-Redirect`。
class IoHttpEngine implements HttpEngine {
  IoHttpEngine({
    io.HttpClient? client,
    HttpPolicyProvider? policyProvider,
    int Function()? clock,
    this.timeout = const Duration(seconds: 20),
    this.maxRedirects = 12,
  })  : _client = client ?? _createDefaultClient(),
        _policyProvider = policyProvider ?? (() => const HttpPolicySnapshot()),
        _clock = clock ?? _systemEpochSeconds;

  final io.HttpClient _client;
  final HttpPolicyProvider _policyProvider;
  final int Function() _clock;
  final Duration timeout;
  final int maxRedirects;

  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/131.0.0.0 Safari/537.36';

  static io.HttpClient _createDefaultClient() {
    final client = io.HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    client.idleTimeout = const Duration(seconds: 15);
    client.autoUncompress = true;
    return client;
  }

  static int _systemEpochSeconds() =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000;

  @override
  Future<HttpResponse> execute(HttpRequest request) async {
    final policy = _policyProvider();
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

    final startedWithPost = request.method == HttpMethod.post;
    var currentUrl = request.url;
    var currentMethod = request.method;
    var currentBody = request.body;
    var convertedPostToGet = false;
    final hopJar = CookieJar(clock: _clock);
    final hopTombstones = <StoredCookie>[];
    final collectedCookies = <StoredCookie>[];

    for (var hop = 0; hop <= maxRedirects; hop++) {
      final uri = Uri.tryParse(currentUrl);
      if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
        throw AcademicException(
          AcademicStatus.UNTRUSTED_URL,
          '非法请求地址：$currentUrl',
        );
      }

      final response = await _sendSingleHop(
        uri: uri,
        method: currentMethod,
        hop: hop,
        startedWithPost: startedWithPost,
        baseHeaders: request.headers,
        hopJar: hopJar,
        hopTombstones: hopTombstones,
        convertedPostToGet: convertedPostToGet,
        body: currentBody,
      );

      final parsedHopUrl = Urls.parseUrl(currentUrl);
      final now = _clock();
      final hopCookies = _extractHopCookies(
        response.headers,
        parsedHopUrl,
        now,
      );
      if (parsedHopUrl != null && hopCookies.isNotEmpty) {
        _recordHopTombstones(hopTombstones, hopCookies, now);
        await hopJar.save(parsedHopUrl, hopCookies);
        collectedCookies.addAll(hopCookies);
      }

      final isRedirect = _isRedirectStatus(response.status);
      final location = _firstHeader(response.headers, 'location');
      if (!request.followRedirects || !isRedirect || location == null) {
        return HttpResponse(
          status: response.status,
          finalUrl: currentUrl,
          headers: response.headers,
          body: response.body,
          cookies: collectedCookies,
        );
      }

      if (hop == maxRedirects) {
        throw AcademicException(
          startedWithPost
              ? AcademicStatus.RESULT_UNKNOWN
              : AcademicStatus.NETWORK_RETRYABLE,
          '重定向次数超过上限（12 次）',
        );
      }

      final nextUrl = upgradeSameHostHttpRedirect(
        currentUrl,
        Urls.resolve(currentUrl, location),
      );
      if (policy.allowedHosts.isNotEmpty &&
          !HostPolicy.isAllowed(
            nextUrl,
            policy.allowedHosts,
            policy.requireSecure,
          )) {
        final blockedHeaders = <String, List<String>>{
          ...response.headers,
          HostGuardedHttpEngine.blockedRedirectHeader: <String>[nextUrl],
        };
        return HttpResponse(
          status: response.status,
          finalUrl: currentUrl,
          headers: blockedHeaders,
          body: response.body,
          cookies: collectedCookies,
        );
      }

      if (response.status == 301 ||
          response.status == 302 ||
          response.status == 303) {
        if (currentMethod == HttpMethod.post) {
          convertedPostToGet = true;
        }
        currentMethod = HttpMethod.get;
        currentBody = null;
      }
      currentUrl = nextUrl;
    }

    throw AcademicException(
      startedWithPost
          ? AcademicStatus.RESULT_UNKNOWN
          : AcademicStatus.NETWORK_RETRYABLE,
      '重定向异常中断',
    );
  }

  Future<({int status, Map<String, List<String>> headers, Uint8List body})>
      _sendSingleHop({
    required Uri uri,
    required HttpMethod method,
    required int hop,
    required bool startedWithPost,
    required Map<String, String> baseHeaders,
    required CookieJar hopJar,
    required List<StoredCookie> hopTombstones,
    required bool convertedPostToGet,
    Uint8List? body,
  }) async {
    var postMayHaveReachedUpstream = hop > 0 && startedWithPost;
    try {
      final req = await _client.openUrl(method.wireName, uri).timeout(timeout);
      req.followRedirects = false;
      req.persistentConnection = true;

      var hasUserAgent = false;
      String? baseCookie;
      for (final entry in baseHeaders.entries) {
        final lower = entry.key.toLowerCase();
        if (lower == 'cookie') {
          baseCookie = entry.value;
          continue;
        }
        if (lower == 'content-length') continue;
        if (convertedPostToGet && lower == 'content-type') continue;
        if (lower == 'user-agent') hasUserAgent = true;
        req.headers.set(entry.key, entry.value);
      }
      if (!hasUserAgent) {
        req.headers.set(io.HttpHeaders.userAgentHeader, defaultUserAgent);
      }

      final parsed = Urls.parseUrl(uri.toString());
      final activeHopCookies = parsed == null
          ? const <StoredCookie>[]
          : await hopJar.loadForParsedUrl(parsed);
      final deletedNames = parsed == null
          ? const <String>{}
          : _deletedNamesForUrl(hopTombstones, parsed);
      final mergedCookie = _mergeCookieHeaders(
        baseCookie,
        activeHopCookies,
        deletedNames: deletedNames,
      );
      if (mergedCookie.isNotEmpty) {
        req.headers.set(io.HttpHeaders.cookieHeader, mergedCookie);
      }

      if (body != null && body.isNotEmpty) {
        req.contentLength = body.length;
        req.add(body);
      }
      if (startedWithPost) {
        postMayHaveReachedUpstream = true;
      }

      final res = await req.close().timeout(timeout);
      final chunks = BytesBuilder(copy: false);
      await for (final chunk in res.timeout(timeout)) {
        chunks.add(chunk);
      }

      final headerMap = <String, List<String>>{};
      res.headers.forEach((name, values) {
        headerMap[name] = List<String>.from(values);
      });

      return (
        status: res.statusCode,
        headers: headerMap,
        body: chunks.takeBytes(),
      );
    } on TimeoutException {
      final status = postMayHaveReachedUpstream
          ? AcademicStatus.RESULT_UNKNOWN
          : AcademicStatus.NETWORK_RETRYABLE;
      throw AcademicException(
        status,
        '请求教务服务器超时，请检查校园网或 VPN 连接',
      );
    } on io.HandshakeException catch (error) {
      final status = postMayHaveReachedUpstream
          ? AcademicStatus.RESULT_UNKNOWN
          : AcademicStatus.NETWORK_RETRYABLE;
      throw AcademicException(
        status,
        'TLS 证书握手失败：${error.message}',
      );
    } on io.SocketException catch (error) {
      final status = postMayHaveReachedUpstream
          ? AcademicStatus.RESULT_UNKNOWN
          : AcademicStatus.NETWORK_RETRYABLE;
      throw AcademicException(
        status,
        '网络连接失败：${error.message}',
      );
    } on io.HttpException catch (error) {
      final status = postMayHaveReachedUpstream
          ? AcademicStatus.RESULT_UNKNOWN
          : AcademicStatus.NETWORK_RETRYABLE;
      throw AcademicException(
        status,
        'HTTP 协议错误：${error.message}',
      );
    }
  }

  static String _mergeCookieHeaders(
    String? initial,
    List<StoredCookie> activeHopCookies, {
    Set<String> deletedNames = const <String>{},
  }) {
    final initialPairs = <(String, String)>[];
    if (initial != null && initial.trim().isNotEmpty) {
      for (final part in initial.split(';')) {
        final eq = part.indexOf('=');
        if (eq <= 0) continue;
        final k = part.substring(0, eq).trim();
        final v = part.substring(eq + 1).trim();
        if (k.isEmpty || _isDeleteSentinelValue(v)) continue;
        initialPairs.add((k, v));
      }
    }

    final activeHopNames = activeHopCookies.map((c) => c.name).toSet();
    final out = <String>[
      for (final c in activeHopCookies) '${c.name}=${c.value}',
      for (final (k, v) in initialPairs)
        if (!activeHopNames.contains(k) && !deletedNames.contains(k)) '$k=$v',
    ];
    return out.join('; ');
  }

  static void _recordHopTombstones(
    List<StoredCookie> tombstones,
    List<StoredCookie> incoming,
    int nowEpochSeconds,
  ) {
    for (final c in incoming) {
      tombstones.removeWhere(
        (t) => t.name == c.name && t.domain == c.domain && t.path == c.path,
      );
      if (_isDeletedOrExpired(c, nowEpochSeconds)) {
        tombstones.add(c);
      }
    }
  }

  static Set<String> _deletedNamesForUrl(
    List<StoredCookie> tombstones,
    ParsedUrl url,
  ) {
    final out = <String>{};
    for (final c in tombstones) {
      if (_cookieMatchesUrl(c, url)) {
        out.add(c.name);
      }
    }
    return out;
  }

  static bool _cookieMatchesUrl(StoredCookie cookie, ParsedUrl url) {
    if (cookie.hostOnly) {
      if (url.host != cookie.domain) return false;
    } else if (!SetCookie.domainMatch(url.host, cookie.domain)) {
      return false;
    }
    if (cookie.secure && !url.isSecure) return false;
    return SetCookie.pathMatch(url.path, cookie.path);
  }

  static bool _isDeleteSentinelValue(String value) =>
      value.trim().toLowerCase() == 'deleteme';

  static bool _isDeletedOrExpired(StoredCookie c, int nowEpochSeconds) =>
      (c.expiresAtEpochSeconds != null &&
          c.expiresAtEpochSeconds! <= nowEpochSeconds) ||
      _isDeleteSentinelValue(c.value);

  static List<StoredCookie> _extractHopCookies(
    Map<String, List<String>> headers,
    ParsedUrl? hopUrl,
    int nowEpochSeconds,
  ) {
    if (hopUrl == null) return const <StoredCookie>[];
    final out = <StoredCookie>[];
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'set-cookie') {
        for (final raw in entry.value) {
          final parsed = SetCookie.parse(raw, hopUrl, nowEpochSeconds);
          if (parsed != null) out.add(parsed);
        }
      }
    }
    return out;
  }

  static final RegExp _httpAuthoritySplit = RegExp(
    r'^[Hh][Tt][Tt][Pp]://([^/?#]+)(.*)$',
  );

  /// 修复反代（如 Nginx TLS -> Tomcat:80 未配置 `proxy_redirect`）在同主机上返回明文
  /// `http://` `Location` 的场景：仅当源跳为默认端口 `https://`（443）且目标跳为**同一主机**
  /// 默认端口 `http://`（80）且不含凭据时，自动升级为 `https://<host><path+query+fragment>`。
  static String upgradeSameHostHttpRedirect(
    String currentUrl,
    String resolvedNextUrl,
  ) {
    final src = Urls.parseUrl(currentUrl);
    final dst = Urls.parseUrl(resolvedNextUrl);
    if (src == null || dst == null) return resolvedNextUrl;
    if (src.userInfo != null || dst.userInfo != null) return resolvedNextUrl;
    final srcDefaultHttps = src.scheme.toLowerCase() == 'https' &&
        (!src.hasExplicitPort || src.port == 443);
    final dstDefaultHttp = dst.scheme.toLowerCase() == 'http' &&
        (!dst.hasExplicitPort || dst.port == 80);
    if (!srcDefaultHttps || !dstDefaultHttp || dst.host != src.host) {
      return resolvedNextUrl;
    }

    final match = _httpAuthoritySplit.firstMatch(resolvedNextUrl.trim());
    if (match == null) return resolvedNextUrl;
    final rawSuffix = match.group(2) ?? '';
    final normalizedSuffix = rawSuffix.isEmpty
        ? '/'
        : (rawSuffix.startsWith('/') ? rawSuffix : '/$rawSuffix');
    final formattedHost = dst.host.contains(':') ? '[${dst.host}]' : dst.host;
    return 'https://$formattedHost$normalizedSuffix';
  }

  static bool _isRedirectStatus(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  static String? _firstHeader(Map<String, List<String>> headers, String lower) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower && entry.value.isNotEmpty) {
        return entry.value.first;
      }
    }
    return null;
  }
}
