import 'dart:convert';

import '../port/http.dart';
import 'async_mutex.dart';
import 'fixture_http_engine.dart';

/// 将真实请求/响应录制成 [HttpFixture]，绝不录制请求体。
class RecordingHttpEngine implements HttpEngine {
  RecordingHttpEngine(
    this._delegate, {
    String Function(HttpRequest, String)? sanitizeResponseBody,
  }) : _sanitizeResponseBody = sanitizeResponseBody ?? ((_, body) => body);

  final HttpEngine _delegate;
  final String Function(HttpRequest, String) _sanitizeResponseBody;
  final AsyncMutex _lock = AsyncMutex();
  final List<HttpFixture> _fixtures = <HttpFixture>[];

  @override
  Future<HttpResponse> execute(HttpRequest request) async {
    final response = await _delegate.execute(request);
    final recorded = HttpFixture.of(request, response);
    final fixture = recorded.bodyBase64 != null
        ? recorded
        : HttpFixture(
            url: recorded.url,
            method: recorded.method,
            status: recorded.status,
            headers: recorded.headers,
            body: _sanitizeResponseBody(request, recorded.body),
            finalUrl: recorded.finalUrl,
          );
    await _lock.withLock(() => _fixtures.add(fixture));
    return response;
  }

  Future<List<HttpFixture>> drain() => _lock.withLock(() {
        final copy = List<HttpFixture>.unmodifiable(_fixtures);
        _fixtures.clear();
        return copy;
      });

  Future<List<HttpFixture>> snapshot() =>
      _lock.withLock(() => List<HttpFixture>.unmodifiable(_fixtures));

  Future<String> toJson() async {
    final items = await drain();
    return const JsonEncoder.withIndent('  ')
        .convert(items.map((e) => e.toJson()).toList());
  }
}
