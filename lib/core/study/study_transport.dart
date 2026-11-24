import 'dart:convert';
import 'dart:typed_data';

import '../model/academic_status.dart';
import '../net/page_charset.dart';
import '../parse/urls.dart';
import '../port/http.dart';
import '../port/runtime.dart';
import '../session/session.dart';

/// 一次读取拿到的已解码页面。
class FetchedPage {
  const FetchedPage({
    required this.status,
    required this.address,
    required this.body,
  });

  final int status;
  final String address;
  final String body;
}

/// 教务读数据与选课接口共用的协议传输层。
class StudyTransport {
  StudyTransport({
    required AccountSession session,
    required HttpEngine engine,
    required TextDecoder decoder,
    String? defaultRefererPath,
  })  : _session = session,
        _engine = engine,
        _decoder = decoder,
        _defaultRefererPath = defaultRefererPath;

  static const String _httpPrefix = 'http://';
  static const String _httpsPrefix = 'https://';
  static const String _ajaxHeader = 'X-Requested-With';
  static const String _acceptHeader =
      'application/json, text/javascript, text/html, */*; q=0.01';

  /// 桌面端 Chrome UA（避免新正方部分模块按移动端 UA 隐藏字段或拒绝桌面表格请求）。
  static const String desktopUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  final AccountSession _session;
  final HttpEngine _engine;
  final TextDecoder _decoder;

  /// POST/AJAX 未显式传 Referer 时使用的站内路径；为空则退回请求 origin。
  final String? _defaultRefererPath;

  AccountSession get session => _session;

  String resolveUrl(String path) {
    final lower = path.toLowerCase();
    if (lower.startsWith(_httpPrefix) || lower.startsWith(_httpsPrefix)) {
      return path;
    }
    var base = _session.baseUrl;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    var rel = path;
    while (rel.startsWith('/')) {
      rel = rel.substring(1);
    }
    return Urls.resolve('$base/', rel);
  }

  Future<FetchedPage> fetch(String url, {String? referer, bool ajax = false}) =>
      _send(
        method: HttpMethod.get,
        url: url,
        body: null,
        referer: referer,
        ajax: ajax,
      );

  Future<FetchedPage> submitForm(
    String url,
    Iterable<(String, String)> fields, {
    String? referer,
    bool ajax = false,
    bool confirmedSelection = false,
  }) =>
      _send(
        method: HttpMethod.post,
        url: url,
        body: _encodeForm(fields),
        referer: referer,
        ajax: ajax,
        confirmedSelection: confirmedSelection,
      );

  String withQuery(String url, Map<String, String> fields) {
    if (fields.isEmpty) return url;
    final separator = url.contains('?') ? '&' : '?';
    final query = fields.entries
        .map((e) => '${e.key}=${Urls.encodeComponent(e.value)}')
        .join('&');
    return '$url$separator$query';
  }

  static String? originOfUrl(String url) {
    final parsed = Urls.parseUrl(url);
    if (parsed == null) return null;
    final out = StringBuffer('${parsed.scheme}://${parsed.host}');
    if (parsed.hasExplicitPort && parsed.port > 0) {
      out.write(':${parsed.port}');
    }
    return out.toString();
  }

  static Uint8List _encodeForm(Iterable<(String, String)> fields) {
    final encoded = fields
        .map(
          (pair) =>
              '${Urls.encodeComponent(pair.$1)}=${Urls.encodeComponent(pair.$2)}',
        )
        .join('&');
    return Uint8List.fromList(utf8.encode(encoded));
  }

  Future<FetchedPage> _send({
    required HttpMethod method,
    required String url,
    required Uint8List? body,
    required String? referer,
    required bool ajax,
    bool confirmedSelection = false,
  }) async {
    final target = Urls.parseUrl(url);
    if (target == null) {
      throw AcademicException(AcademicStatus.UNTRUSTED_URL, '教务地址解析失败：$url');
    }
    final headers = await _requestHeaders(method, url, referer, ajax);
    final answer = await _session.withProtocolLock(
      () => _engine.execute(
        HttpRequest(
          method: method,
          url: url,
          headers: headers,
          body: body,
          confirmedSelection: confirmedSelection,
        ),
      ),
    );
    final finalParsed = Urls.parseUrl(answer.finalUrl);
    if (finalParsed != null) {
      await _session.cookies.save(finalParsed, answer.cookies);
    }
    _refuseIfFailed(answer.status);
    return FetchedPage(
      status: answer.status,
      address: answer.finalUrl,
      body: _decodeBody(answer),
    );
  }

  Future<Map<String, String>> _requestHeaders(
    HttpMethod method,
    String url,
    String? referer,
    bool ajax,
  ) async {
    final map = <String, String>{
      'Accept': _acceptHeader,
      'User-Agent': desktopUserAgent,
    };
    final origin = originOfUrl(url);
    if (method == HttpMethod.post) {
      map['Content-Type'] = 'application/x-www-form-urlencoded; charset=UTF-8';
      if (origin != null) map['Origin'] = origin;
    }
    if (ajax) {
      map[_ajaxHeader] = 'XMLHttpRequest';
      if (origin != null) map.putIfAbsent('Origin', () => origin);
    }
    if (referer != null && referer.trim().isNotEmpty) {
      map['Referer'] = referer;
    } else if (method == HttpMethod.post || ajax) {
      final fallbackReferer = _defaultReferer(origin);
      if (fallbackReferer != null) {
        map['Referer'] = fallbackReferer;
      }
    }
    final cookie = await _session.cookieHeaderFor(url);
    if (cookie.isNotEmpty) map['Cookie'] = cookie;
    return map;
  }

  String? _defaultReferer(String? origin) {
    final path = _defaultRefererPath;
    if (path != null && _session.baseUrl.trim().isNotEmpty) {
      return resolveUrl(path);
    }
    return origin;
  }

  static void _refuseIfFailed(int status) {
    // HTTP 901 是新正方 jwglxt AJAX 会话超时专有状态码。
    if (status == 401 || status == 403 || status == 901) {
      throw const AcademicException(
        AcademicStatus.SESSION_EXPIRED,
        '登录状态已失效，请重新登录',
      );
    }
    if (status == 429 || status >= 500) {
      throw AcademicException(
        AcademicStatus.NETWORK_RETRYABLE,
        '教务系统当前无法响应（HTTP $status），请稍后重试',
      );
    }
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
}
