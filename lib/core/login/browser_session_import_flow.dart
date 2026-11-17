import 'dart:convert';

import '../model/academic_status.dart';
import '../model/student_identity.dart';
import '../net/page_charset.dart';
import '../parse/authenticated_page.dart';
import '../parse/html.dart';
import '../parse/urls.dart';
import '../parse/zhengfang_home.dart';
import '../parse/zhengfang_identity.dart';
import '../port/http.dart';
import '../port/runtime.dart';
import '../session/login_result.dart';
import '../session/session.dart';
import '../study/study_transport.dart';

/// 接管内嵌浏览器中的会话（支持裸根 `/jwglxt` 自动发现、同站停留页、单层子框架、GBK/Big5 备选解码）。
class BrowserSessionImportFlow {
  BrowserSessionImportFlow({
    required AccountSession session,
    required HttpEngine engine,
    required TextDecoder decoder,
    required String baseUrl,
  })  : _session = session,
        _engine = engine,
        _decoder = decoder,
        _baseUrl = baseUrl,
        _effectiveRoot = _trimTrailingSlash(baseUrl);

  static const String _gbk = 'gbk';
  static const String _big5 = 'big5';
  static const String _initMenuPath = '/xtgl/index_initMenu.html?jsdm=xs';
  static const String _userCardPath =
      '/xtgl/index_cxYhxxIndex.html?xt=jw&localeKey=zh_CN&gnmkdm=index';

  final AccountSession _session;
  final HttpEngine _engine;
  final TextDecoder _decoder;
  final String _baseUrl;
  String _effectiveRoot;

  Future<LoginResult> importSession(
    List<StoredCookie> cookies, {
    String? homePath,
    String username = '',
    String? browserUrl,
  }) =>
      _session.withProtocolLock(() async {
        final generation = _session.epoch;
        try {
          final result = await _run(cookies, homePath, username, browserUrl);
          if (_session.epoch != generation) {
            return const LoginResult(
              AcademicStatus.SESSION_EXPIRED,
              message: '会话在接管过程中被替换，结果已丢弃',
            );
          }
          return result;
        } on Exception {
          if (_session.epoch != generation) {
            return const LoginResult(
              AcademicStatus.SESSION_EXPIRED,
              message: '会话在接管过程中被替换',
            );
          }
          rethrow;
        }
      });

  Future<LoginResult> _run(
    List<StoredCookie> cookies,
    String? homePath,
    String username,
    String? browserUrl,
  ) async {
    if (cookies.isEmpty) {
      return const LoginResult(
        AcademicStatus.SESSION_EXPIRED,
        message: '浏览器里没有任何 cookie：请先在网页中完成登录',
      );
    }

    await _session.cookies.restore(cookies);

    // 若 baseUrl 为裸根但浏览器停留页或 Cookie path 明确指向 `/jwglxt`，提前更新上下文根路径。
    _adoptContextHint(browserUrl, cookies);

    final primary = _verificationUrl(homePath);
    final parsedPrimary = Urls.parseUrl(primary);
    if (parsedPrimary == null) {
      return LoginResult(
        AcademicStatus.VALIDATION_FAILED,
        message: '教务地址无法解析：$_baseUrl',
      );
    }

    final header = await _session.cookies.cookieHeaderForParsedUrl(
      parsedPrimary,
    );
    if (header.isEmpty) {
      return LoginResult(
        AcademicStatus.SESSION_EXPIRED,
        message: '浏览器里的 cookie 都不适用于 $_effectiveRoot：请确认已在该校页面上完成登录',
      );
    }

    final findings = <String>[];
    final verdict = await _scanCandidates(
      primary,
      parsedPrimary.host,
      browserUrl,
      findings,
    );

    return switch (verdict) {
      _ScanAccepted() => () {
          _session.username = username;
          return LoginResult(
            AcademicStatus.SUCCESS,
            identity: verdict.identity,
            message: verdict.note,
          );
        }(),
      _ScanStillLoginForm() => LoginResult(
          AcademicStatus.SESSION_EXPIRED,
          message: '浏览器中的登录状态已失效（${verdict.url} 仍是登录页）：请重新在网页中登录',
        ),
      _ScanNoSignal() => LoginResult(
          AcademicStatus.VALIDATION_FAILED,
          message: _pendingMessage(findings),
          isProvisional: true,
        ),
    };
  }

  void _adoptContextHint(String? browserUrl, List<StoredCookie> cookies) {
    if (!_hasNoContextPath(_effectiveRoot)) return;
    final origin = StudyTransport.originOfUrl(_effectiveRoot);
    if (origin == null) return;

    final fromBrowser = Html.jwglxtContextPath('', browserUrl ?? '');
    if (fromBrowser != null && fromBrowser.isNotEmpty) {
      _effectiveRoot = '$origin$fromBrowser';
      _session.updateBaseUrl(_effectiveRoot);
      return;
    }

    for (final c in cookies) {
      if (c.path == '/jwglxt' || c.path.startsWith('/jwglxt/')) {
        _effectiveRoot = '$origin/jwglxt';
        _session.updateBaseUrl(_effectiveRoot);
        return;
      }
    }
  }

  static bool _hasNoContextPath(String url) {
    final path = Urls.parseUrl(url)?.path ?? '';
    return path.isEmpty || path == '/';
  }

  Future<_ScanResult> _scanCandidates(
    String primary,
    String host,
    String? browserUrl,
    List<String> findings,
  ) async {
    String? loginFormAt;
    for (final url in _pagesToInspect(primary, host, browserUrl)) {
      final verdict = await _inspect(url, host, findings);
      switch (verdict) {
        case _PageIdentified():
          final enriched = await _enrichZfIdentityIfIncomplete(verdict.identity);
          return _ScanAccepted(enriched, '已接管浏览器会话');
        case _PageSignedIn():
          final enriched =
              await _enrichZfIdentityIfIncomplete(const StudentIdentity());
          if (!enriched.isEmpty) {
            return _ScanAccepted(enriched, '已接管浏览器会话');
          }
          return const _ScanAccepted(
            StudentIdentity(),
            '已接管浏览器会话，但未能从首页识别姓名/学号（该校页面结构与已知形态不同）',
          );
        case _PageStillLoginForm():
          if (url == primary && loginFormAt == null) loginFormAt = url;
        case _PageInconclusive():
          break;
      }
    }

    // 针对新正方裸根或首页缺少身份字段的情况，非致命尝试探测 index_initMenu / index_cxYhxxIndex。
    final fallbackIdentity = await _probeZfAuthenticatedEndpoints();
    if (fallbackIdentity != null) {
      return _ScanAccepted(fallbackIdentity, '已接管浏览器会话');
    }

    if (loginFormAt != null) return _ScanStillLoginForm(loginFormAt);
    return const _ScanNoSignal();
  }

  Future<StudentIdentity?> _probeZfAuthenticatedEndpoints() async {
    var merged = const StudentIdentity();
    var authenticated = false;

    try {
      final menu = await _fetch('$_effectiveRoot$_initMenuPath');
      await _acceptCookies(menu);
      if (menu.response.status == 200 && !Html.isLoginPage(menu.text)) {
        final meta = ZhengfangHomeParser.parse(menu.text);
        if (!meta.isEmpty) {
          _session.zfHomeMetadata = meta;
          authenticated = true;
        }
        merged = merged.merge(
          ZhengfangIdentity.parse(menu.text, _effectiveRoot),
        );
      }
    } catch (_) {
      return null;
    }

    final enriched = await _enrichZfIdentityIfIncomplete(merged);
    if (!enriched.isEmpty) return enriched;
    return authenticated ? const StudentIdentity() : null;
  }

  Future<StudentIdentity> _enrichZfIdentityIfIncomplete(
    StudentIdentity current,
  ) async {
    var out = current;
    if (out.name.isEmpty) {
      try {
        final card = await _fetch('$_effectiveRoot$_userCardPath');
        await _acceptCookies(card);
        if (card.response.status == 200 && !Html.isLoginPage(card.text)) {
          out = out.merge(ZhengfangIdentity.parse(card.text, _effectiveRoot));
        }
      } catch (_) {
        // 最小化夹具未录制该端点时忽略。
      }
    }
    return out;
  }

  Future<_PageVerdict> _inspect(
    String url,
    String host,
    List<String> findings,
  ) async {
    var loaded = await _fetch(url);
    await _acceptCookies(loaded);
    _updateRootIfDiscovered(loaded);

    // 跟随同源 `<meta http-equiv="refresh" content="...url=/jwglxt">`。
    final refreshTarget =
        Html.metaRefreshTarget(loaded.text, loaded.response.finalUrl);
    if (refreshTarget != null &&
        refreshTarget != url &&
        _isSameSite(host, Urls.parseUrl(refreshTarget)?.host ?? '')) {
      try {
        final redirected = await _fetch(refreshTarget);
        await _acceptCookies(redirected);
        _updateRootIfDiscovered(redirected);
        loaded = redirected;
      } catch (_) {
        // 忽略无效跳转目标，继续分析当前页。
      }
    }

    final direct = _verdictFor(loaded);
    if (direct is! _PageInconclusive) {
      if (direct is _PageStillLoginForm) {
        findings.add(_observation(url, loaded, '仍是登录页'));
      }
      return direct;
    }

    final frames = Html.frameUrls(loaded.text, loaded.response.finalUrl)
        .where((f) => _isSameSite(host, Urls.parseUrl(f)?.host ?? ''))
        .toList();
    if (frames.isEmpty) {
      findings.add(_observation(url, loaded, '没有已登录特征'));
      return const _PageInconclusive();
    }

    for (final frame in frames) {
      final sub = await _fetch(frame);
      await _acceptCookies(sub);
      final verdict = _verdictFor(sub);
      switch (verdict) {
        case _PageIdentified():
        case _PageSignedIn():
          return verdict;
        case _PageStillLoginForm():
          findings.add(_observation(frame, sub, '子框架仍是登录页'));
        case _PageInconclusive():
          findings.add(_observation(frame, sub, '子框架也没有已登录特征'));
      }
    }
    findings.add(
      _observation(url, loaded, '是框架页，但 ${frames.length} 个子框架里都没有已登录特征'),
    );
    return const _PageInconclusive();
  }

  void _updateRootIfDiscovered(_LoadedPage loaded) {
    final meta = ZhengfangHomeParser.parse(loaded.text);
    if (meta.currentTerm != null || meta.currentWeek != null) {
      _session.zfHomeMetadata = meta;
    }
    if (!_hasNoContextPath(_effectiveRoot)) return;
    final origin = StudyTransport.originOfUrl(_effectiveRoot);
    if (origin == null) return;
    final ctx = Html.jwglxtContextPath(loaded.text, loaded.response.finalUrl);
    if (ctx != null && ctx.isNotEmpty) {
      _effectiveRoot = '$origin$ctx';
      _session.updateBaseUrl(_effectiveRoot);
    }
  }

  _PageVerdict _verdictFor(_LoadedPage loaded) {
    final initial = _verdictIn(loaded.text, loaded.response.finalUrl);
    if (initial != null) return initial;
    for (final candidate in _retryDecodings(loaded)) {
      final retried = _verdictIn(candidate, loaded.response.finalUrl);
      if (retried != null) return retried;
    }
    return const _PageInconclusive();
  }

  static _PageVerdict? _verdictIn(String text, String url) {
    if (Html.isLoginPage(text)) return const _PageStillLoginForm();
    final identity = ZhengfangIdentity.parse(text, url);
    if (!identity.isEmpty) return _PageIdentified(identity);
    if (AuthenticatedPage.looksAuthenticated(text)) {
      return const _PageSignedIn();
    }
    return null;
  }

  List<String> _retryDecodings(_LoadedPage loaded) {
    final body = loaded.response.body;
    if (body.isEmpty) return const <String>[];
    final out = <String>[];
    for (final name in const [PageCharset.utf8Charset, _gbk, _big5]) {
      if (name == loaded.charset) continue;
      final decoded = _decoder.decode(body, name);
      if (decoded != loaded.text) out.add(decoded);
    }
    return out;
  }

  static List<String> _pagesToInspect(
    String primary,
    String host,
    String? browserUrl,
  ) {
    final landed = browserUrl?.trim() ?? '';
    if (landed.isEmpty) return <String>[primary];
    final other = Urls.parseUrl(landed);
    if (other == null || !_isSameSite(host, other.host)) {
      return <String>[primary];
    }
    return primary == landed ? <String>[primary] : <String>[primary, landed];
  }

  static bool _isSameSite(String host, String other) {
    final left = _stripDots(host.toLowerCase());
    final right = _stripDots(other.toLowerCase());
    if (left.isEmpty || right.isEmpty) return false;
    return left == right ||
        left.endsWith('.$right') ||
        right.endsWith('.$left');
  }

  static String _stripDots(String value) {
    var out = value;
    while (out.startsWith('.')) {
      out = out.substring(1);
    }
    while (out.endsWith('.')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  String _verificationUrl(String? homePath) {
    final path = homePath?.trim() ?? '';
    if (path.isEmpty) return _effectiveRoot;
    final lower = path.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return path;
    }
    var trimmed = path;
    while (trimmed.startsWith('/')) {
      trimmed = trimmed.substring(1);
    }
    return Urls.resolve('$_effectiveRoot/', trimmed);
  }

  static String _observation(String url, _LoadedPage loaded, String reason) {
    final frames = Html.hasFrames(loaded.text) ? '，且是框架页' : '';
    return '$url → HTTP ${loaded.response.status} / ${loaded.response.body.length} 字节$frames：$reason';
  }

  static String _pendingMessage(List<String> findings) {
    final detail = findings.isEmpty ? '' : '已检查：${findings.join("；")}。';
    final hint = findings.any((f) => f.contains('框架页'))
        ? '该地址是框架页，登录后的信息在子框架里没有被识别到：可以在登录表单的「会话校验页」填写登录后首页的路径后重试。'
        : '如果「教务地址」填的是登录页，请改成登录后首页的地址。';
    return '无法确认浏览器中的登录状态（这些页面既不是登录页，也没有已登录的特征）：'
        '请确认已在网页中成功登录，并检查教务地址是否填对。$detail$hint'
        '会话仍会被接管，接下来用课表读取做一次真实请求来确认它能不能用。';
  }

  Future<void> _acceptCookies(_LoadedPage loaded) async {
    final parsed = loaded.url;
    if (parsed != null) {
      await _session.cookies.save(parsed, loaded.response.cookies);
    }
  }

  Future<_LoadedPage> _fetch(String url) async {
    final parsed = Urls.parseUrl(url);
    final headers = <String, String>{
      'User-Agent': StudyTransport.desktopUserAgent,
    };
    if (parsed != null) {
      final cookie = await _session.cookies.cookieHeaderForParsedUrl(parsed);
      if (cookie.isNotEmpty) {
        headers['Cookie'] = cookie;
      }
    }
    final request = HttpRequest(
      method: HttpMethod.get,
      url: url,
      headers: headers,
    );
    return _decode(await _engine.execute(request));
  }

  _LoadedPage _decode(HttpResponse response) {
    String? contentType;
    for (final entry in response.headers.entries) {
      if (entry.key.toLowerCase() == 'content-type' && entry.value.isNotEmpty) {
        contentType = entry.value.first;
        break;
      }
    }
    final charset = PageCharset.detect(contentType, response.body);
    final text = charset == PageCharset.utf8Charset
        ? utf8.decode(response.body, allowMalformed: true)
        : _decoder.decode(response.body, charset);
    return _LoadedPage(response, charset, text);
  }

  static String _trimTrailingSlash(String url) {
    var out = url;
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }
}

class _LoadedPage {
  const _LoadedPage(this.response, this.charset, this.text);
  final HttpResponse response;
  final String charset;
  final String text;
  ParsedUrl? get url => Urls.parseUrl(response.finalUrl);
}

sealed class _PageVerdict {
  const _PageVerdict();
}

final class _PageIdentified extends _PageVerdict {
  const _PageIdentified(this.identity);
  final StudentIdentity identity;
}

final class _PageSignedIn extends _PageVerdict {
  const _PageSignedIn();
}

final class _PageStillLoginForm extends _PageVerdict {
  const _PageStillLoginForm();
}

final class _PageInconclusive extends _PageVerdict {
  const _PageInconclusive();
}

sealed class _ScanResult {
  const _ScanResult();
}

final class _ScanAccepted extends _ScanResult {
  const _ScanAccepted(this.identity, this.note);
  final StudentIdentity identity;
  final String note;
}

final class _ScanStillLoginForm extends _ScanResult {
  const _ScanStillLoginForm(this.url);
  final String url;
}

final class _ScanNoSignal extends _ScanResult {
  const _ScanNoSignal();
}
