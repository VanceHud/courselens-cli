import '../parse/urls.dart';
import '../port/http.dart';
import 'async_mutex.dart';
import 'set_cookie.dart';

/// 一次会话（一个学校 + 一个账号）的 Cookie 存储与匹配容器。
///
/// 核心不变式：
/// - 同一 `(domain, path, name)` 只留一份，覆盖而非累加；不同 `path`（如 `/` 与 `/jwglxt`）互不覆盖；
/// - 请求头序列化严格遵循 RFC 6265 §5.4：更长 `path` 排在更短 `path` 之前，同长度按创建先后确定性排序；
/// - `Max-Age<=0`、已过期 `Expires` 或 `deleteMe` 精确删除对应 `(domain, path, name)` 的 cookie；
/// - [retire] 后永久封死写入（`writeSealed = true`），防止飞行中的旧响应串号污染新会话；
/// - 域匹配严格检查标签边界上的点。
class CookieJar {
  CookieJar({required int Function() clock}) : _clock = clock;

  final int Function() _clock;
  final List<_HeldCookie> _held = <_HeldCookie>[];
  final AsyncMutex _stateGuard = AsyncMutex();
  bool _writeSealed = false;
  int _nextSeq = 0;

  Future<void> saveFromResponse(
    ParsedUrl sourceUrl,
    List<String> setCookieHeaders,
  ) async {
    if (setCookieHeaders.isEmpty) return;
    await _writeAtomically((now) {
      final incoming = <StoredCookie>[];
      for (final raw in setCookieHeaders) {
        final parsed = SetCookie.parse(raw, sourceUrl, now);
        if (parsed != null) incoming.add(parsed);
      }
      final origin = _originLabel(sourceUrl);
      _absorb(incoming, now, (_) => origin, fallbackUrl: sourceUrl);
    });
  }

  Future<void> save(
    ParsedUrl url,
    List<StoredCookie> cookies, {
    String? setByOrigin,
  }) async {
    if (cookies.isEmpty) return;
    await _writeAtomically((now) {
      final origin = setByOrigin ?? _originLabel(url);
      _absorb(cookies, now, (_) => origin, fallbackUrl: url);
    });
  }

  Future<List<StoredCookie>> loadForRequest(String url) async {
    final parsed = Urls.parseUrl(url);
    if (parsed == null) return const <StoredCookie>[];
    return loadForParsedUrl(parsed);
  }

  Future<List<StoredCookie>> loadForParsedUrl(ParsedUrl url) =>
      _readAtomically(() {
        final matched = _matchingHeld(url);
        return matched.map((h) => h.cookie).toList(growable: false);
      });

  Future<String> cookieHeaderFor(String url, {String? setByOrigin}) async {
    final parsed = Urls.parseUrl(url);
    if (parsed == null) return '';
    return cookieHeaderForParsedUrl(parsed, setByOrigin: setByOrigin);
  }

  Future<String> cookieHeaderForParsedUrl(
    ParsedUrl url, {
    String? setByOrigin,
  }) =>
      _readAtomically(() {
        final matched = _matchingHeld(url, setByOrigin: setByOrigin);
        return matched
            .map((h) => '${h.cookie.name}=${h.cookie.value}')
            .join('; ');
      });

  /// 返回由指定来源（`host:port`）种下的全部 cookie，不受路径匹配限制（用于会话迁移）。
  Future<List<StoredCookie>> cookiesSetBy(String origin) => _readAtomically(
        () => _held
            .where((h) => h.origin == origin)
            .map((h) => h.cookie)
            .toList(growable: false),
      );

  /// 取出全部未过期 cookie（用于落盘或注入浏览器）。
  Future<List<StoredCookie>> snapshot() => _readAtomically(
        () => _held.map((h) => h.cookie).toList(growable: false),
      );

  /// 直接注入 cookie（内嵌浏览器导出或本地归档恢复）。
  Future<void> restore(
    List<StoredCookie> cookies, {
    String? setByOrigin,
  }) =>
      _writeAtomically((now) {
        _absorb(cookies, now, (c) => setByOrigin ?? '${c.domain}:0');
        _dropExpired(now);
      });

  /// 清空但保持可用。
  Future<void> clear() => _stateGuard.withLock(_held.clear);

  /// 作废本 Cookie 容器：清空并永久拒收后续写入。
  Future<void> retire() => _stateGuard.withLock(() {
        _writeSealed = true;
        _held.clear();
      });

  Future<int> size() => _readAtomically(() => _held.length);

  List<_HeldCookie> _matchingHeld(ParsedUrl url, {String? setByOrigin}) {
    final matched = _held
        .where((h) => setByOrigin == null || h.origin == setByOrigin)
        .where((h) => _appliesTo(h.cookie, url))
        .toList();
    matched.sort(_compareHeldForRequest);
    return matched;
  }

  static int _compareHeldForRequest(_HeldCookie a, _HeldCookie b) {
    final byPathLength = b.cookie.path.length.compareTo(a.cookie.path.length);
    if (byPathLength != 0) return byPathLength;
    final bySeq = a.seq.compareTo(b.seq);
    if (bySeq != 0) return bySeq;
    final byPath = a.cookie.path.compareTo(b.cookie.path);
    if (byPath != 0) return byPath;
    final byDomain = a.cookie.domain.compareTo(b.cookie.domain);
    if (byDomain != 0) return byDomain;
    return a.cookie.name.compareTo(b.cookie.name);
  }

  void _absorb(
    List<StoredCookie> cookies,
    int now,
    String Function(StoredCookie) originFor, {
    ParsedUrl? fallbackUrl,
  }) {
    for (final rawCookie in cookies) {
      final incoming = _normalizeCookie(rawCookie, fallbackUrl);
      if (incoming.name.isEmpty || incoming.domain.isEmpty) continue;

      int? preservedSeq;
      _held.removeWhere((h) {
        if (_hasSameKey(h.cookie, incoming)) {
          preservedSeq ??= h.seq;
          return true;
        }
        return false;
      });

      if (!_isDeletedOrExpired(incoming, now)) {
        final seq = preservedSeq ?? _nextSeq++;
        _held.add(_HeldCookie(incoming, originFor(incoming), seq));
      }
    }
  }

  static StoredCookie _normalizeCookie(
    StoredCookie cookie,
    ParsedUrl? fallbackUrl,
  ) {
    var domain = cookie.domain.trim().toLowerCase();
    while (domain.startsWith('.')) {
      domain = domain.substring(1);
    }
    if (domain.isEmpty && fallbackUrl != null) {
      domain = fallbackUrl.host;
    }
    final rawPath = cookie.path.trim();
    final path = (rawPath.isEmpty || !rawPath.startsWith('/'))
        ? (fallbackUrl?.defaultCookiePath ?? '/')
        : rawPath;
    final name = cookie.name.trim();
    if (domain == cookie.domain && path == cookie.path && name == cookie.name) {
      return cookie;
    }
    return StoredCookie(
      name: name,
      value: cookie.value,
      domain: domain,
      path: path,
      secure: cookie.secure,
      httpOnly: cookie.httpOnly,
      expiresAtEpochSeconds: cookie.expiresAtEpochSeconds,
      hostOnly: cookie.hostOnly,
    );
  }

  Future<T> _readAtomically<T>(T Function() read) => _stateGuard.withLock(() {
        _dropExpired(_clock());
        return read();
      });

  Future<void> _writeAtomically(void Function(int now) change) =>
      _stateGuard.withLock(() {
        if (_writeSealed) return;
        change(_clock());
      });

  static bool _isExpiredAt(StoredCookie cookie, int now) =>
      cookie.expiresAtEpochSeconds != null &&
      cookie.expiresAtEpochSeconds! <= now;

  static bool _isDeletionSentinel(StoredCookie cookie) =>
      cookie.value.trim().toLowerCase() == 'deleteme';

  static bool _isDeletedOrExpired(StoredCookie cookie, int now) =>
      _isExpiredAt(cookie, now) || _isDeletionSentinel(cookie);

  void _dropExpired(int now) {
    _held.removeWhere((h) => _isDeletedOrExpired(h.cookie, now));
  }

  static bool _hasSameKey(StoredCookie a, StoredCookie b) =>
      a.name == b.name && a.domain == b.domain && a.path == b.path;

  static String _originLabel(ParsedUrl url) => '${url.host}:${url.port}';

  static bool _appliesTo(StoredCookie cookie, ParsedUrl url) {
    if (cookie.hostOnly) {
      if (url.host != cookie.domain) return false;
    } else if (!SetCookie.domainMatch(url.host, cookie.domain)) {
      return false;
    }
    if (cookie.secure && !url.isSecure) return false;
    return SetCookie.pathMatch(url.path, cookie.path);
  }
}

class _HeldCookie {
  const _HeldCookie(this.cookie, this.origin, this.seq);
  final StoredCookie cookie;
  final String origin;
  final int seq;
}
