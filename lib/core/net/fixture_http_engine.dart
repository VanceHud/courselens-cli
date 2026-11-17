import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../crypto/base64_codec.dart';
import '../model/academic_status.dart';
import '../parse/urls.dart';
import '../port/http.dart';
import 'async_mutex.dart';
import 'set_cookie.dart';

/// 一条录制下来的「请求 -> 响应」夹具。
///
/// 安全设计：不包含请求体字段，从结构上杜绝将 POST 口令录进仓库。
class HttpFixture {
  HttpFixture({
    required this.url,
    this.method = 'GET',
    this.status = 200,
    Map<String, List<String>> headers = const {},
    this.body = '',
    this.bodyBase64,
    this.finalUrl,
  }) : headers = Map.unmodifiable(
          headers.map((k, v) => MapEntry(k, List<String>.unmodifiable(v))),
        );

  static const int replayClockEpoch = 1700000000;

  final String url;
  final String method;
  final int status;
  final Map<String, List<String>> headers;
  final String body;
  final String? bodyBase64;
  final String? finalUrl;

  HttpResponse toResponse([String? defaultFinalUrl]) {
    final fallbackUrl = defaultFinalUrl ?? url;
    final bodyBytes = bodyBase64 != null
        ? (Base64Codec.decode(bodyBase64!) ?? base64.decode(bodyBase64!))
        : Uint8List.fromList(utf8.encode(body));
    return HttpResponse(
      status: status,
      finalUrl: finalUrl ?? fallbackUrl,
      headers: headers,
      body: bodyBytes,
      cookies: _parseCookies(fallbackUrl),
    );
  }

  List<StoredCookie> _parseCookies(String cookieUrl) {
    final recordedAt = Urls.parseUrl(cookieUrl);
    if (recordedAt == null) return const <StoredCookie>[];
    final rawHeaders = _recordedSetCookieHeaders();
    if (rawHeaders.isEmpty) return const <StoredCookie>[];
    final out = <StoredCookie>[];
    for (final raw in rawHeaders) {
      final parsed = SetCookie.parse(raw, recordedAt, replayClockEpoch);
      if (parsed != null) out.add(parsed);
    }
    return out;
  }

  List<String> _recordedSetCookieHeaders() {
    final out = <String>[];
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'set-cookie') {
        out.addAll(entry.value);
      }
    }
    return out;
  }

  factory HttpFixture.of(HttpRequest request, HttpResponse response) {
    final text = _utf8TextOrNull(response.body);
    return HttpFixture(
      url: request.url,
      method: request.method.wireName,
      status: response.status,
      headers: response.headers,
      body: text ?? '',
      bodyBase64: (text == null && response.body.isNotEmpty)
          ? Base64Codec.encode(response.body)
          : null,
      finalUrl: response.finalUrl != request.url ? response.finalUrl : null,
    );
  }

  static String? _utf8TextOrNull(Uint8List bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      return null;
    }
  }

  factory HttpFixture.fromJson(Map<String, dynamic> json) {
    final rawHeaders = json['headers'];
    final parsedHeaders = <String, List<String>>{};
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (value is List) {
          parsedHeaders[key] = value.map((e) => e.toString()).toList();
        } else if (value != null) {
          parsedHeaders[key] = <String>[value.toString()];
        }
      }
    }
    return HttpFixture(
      url: json['url'] as String? ?? '',
      method: json['method'] as String? ?? 'GET',
      status: (json['status'] as num?)?.toInt() ?? 200,
      headers: parsedHeaders,
      body: json['body'] as String? ?? '',
      bodyBase64: json['bodyBase64'] as String?,
      finalUrl: json['finalUrl'] as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'method': method,
        'status': status,
        'headers': headers,
        'body': body,
        'bodyBase64': bodyBase64,
        'finalUrl': finalUrl,
      };
}

/// 用录制的响应回放整条教务流程（演示模式与离线单测引擎）。
class FixtureHttpEngine implements HttpEngine {
  FixtureHttpEngine(
    List<HttpFixture> fixtures, {
    HttpResponse Function(HttpRequest)? onMiss,
  })  : _onMiss = onMiss,
        _tracks = _groupTracks(fixtures);

  factory FixtureHttpEngine.fromJson(
    String jsonText, {
    HttpResponse Function(HttpRequest)? onMiss,
  }) {
    final decoded = jsonDecode(jsonText);
    if (decoded is! List) {
      throw const FormatException('Fixture JSON 顶层必须是数组');
    }
    final list = decoded
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => HttpFixture.fromJson(Map<String, dynamic>.from(m)))
        .toList();
    return FixtureHttpEngine(list, onMiss: onMiss);
  }

  final Map<String, List<HttpFixture>> _tracks;
  final Map<String, int> _positions = <String, int>{};
  final AsyncMutex _stateGuard = AsyncMutex();
  final HttpResponse Function(HttpRequest)? _onMiss;

  int get endpointCount => _tracks.length;

  static Map<String, List<HttpFixture>> _groupTracks(
    List<HttpFixture> fixtures,
  ) {
    final map = <String, List<HttpFixture>>{};
    for (final item in fixtures) {
      final key = _requestKey(item.method, item.url);
      (map[key] ??= <HttpFixture>[]).add(item);
    }
    return map;
  }

  @override
  Future<HttpResponse> execute(HttpRequest request) async {
    final recorded = await _stateGuard.withLock(() => _takeNext(request));
    if (recorded == null) {
      if (_onMiss != null) return _onMiss(request);
      throw _missingFixture(request);
    }
    return recorded.toResponse();
  }

  Future<void> reset() => _stateGuard.withLock(_positions.clear);

  HttpFixture? _takeNext(HttpRequest request) {
    final id = _requestKey(request.method.wireName, request.url);
    final track = _tracks[id];
    if (track == null || track.isEmpty) return null;
    final index = _positions[id] ?? 0;
    _positions[id] = index + 1;
    return track[math.min(index, track.length - 1)];
  }

  static String _requestKey(String method, String url) =>
      '${method.trim().toUpperCase()} $url';

  AcademicException _missingFixture(HttpRequest request) {
    final keys = _tracks.keys.toList()..sort();
    return AcademicException(
      AcademicStatus.PAGE_CHANGED,
      '回放夹具中没有 ${request.method.wireName} ${request.url}；'
      '已录制 ${_tracks.length} 个端点：$keys',
    );
  }
}
