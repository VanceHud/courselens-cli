import 'dart:convert';
import 'dart:typed_data';

import '../model/academic_status.dart';
import '../net/page_charset.dart';
import '../parse/html.dart';
import '../parse/urls.dart';
import '../parse/zhengfang_home.dart';
import '../parse/zhengfang_identity.dart';
import '../parse/zhengfang_jwglxt_protocol.dart';
import '../port/http.dart';
import '../port/runtime.dart';
import '../session/login_result.dart';
import '../session/session.dart';
import '../study/study_transport.dart';

/// 正方教务 v9.0 原生登录（`xtgl/login_slogin.html`）编排。
///
/// 关键协议保证：
/// 1. 兼容裸根地址 `https://jwglxt.qust.edu.cn/`（自动探测 `302` 与 `<meta http-equiv="refresh" content="...url=/jwglxt">` 并修正 `session.baseUrl`）。
/// 2. 单次提交至多调用一次 `login_getPublicKey.html`（防止服务端覆盖会话 RSA 私钥），且保存其下发的 Cookie。
/// 3. 动态识别 `#yzmDiv` / `input[name=yzm]` 验证码与服务端 `CAPTCHA_REQUIRED` 响应，自动拉取 `/kaptcha` 挑战图。
/// 4. 登录成功后优先读取 `xtgl/index_initMenu.html?jsdm=xs` 与 `xtgl/index_cxYhxxIndex.html` 提取权威校历周次与学生院系/班级信息，避免裸根跳转回登录页冲掉身份。
class ZhengfangJwglxtLoginFlow {
  ZhengfangJwglxtLoginFlow({
    required AccountSession session,
    required HttpEngine engine,
    required TextDecoder decoder,
    required SecureRandom random,
    required String baseUrl,
    required int Function() clock,
  })  : _session = session,
        _engine = engine,
        _decoder = decoder,
        _random = random,
        _effectiveRoot = _trimTrailingSlash(baseUrl),
        _clock = clock;

  static const String _userCardPath =
      '/xtgl/index_cxYhxxIndex.html?xt=jw&localeKey=zh_CN&gnmkdm=index';

  final AccountSession _session;
  final HttpEngine _engine;
  final TextDecoder _decoder;
  final SecureRandom _random;
  String _effectiveRoot;
  final int Function() _clock;

  int _requestCounter = 0;

  Future<LoginResult> login(
    String username,
    String password, {
    String? captcha,
  }) =>
      _session.withProtocolLock(() async {
        final generation = _session.epoch;
        try {
          final result = await _run(username, password, captcha);
          if (_session.epoch != generation) {
            return const LoginResult(
              AcademicStatus.SESSION_EXPIRED,
              message: '会话在登录过程中被替换，结果已丢弃',
            );
          }
          return result;
        } on Exception {
          if (_session.epoch != generation) {
            return const LoginResult(
              AcademicStatus.SESSION_EXPIRED,
              message: '会话在登录过程中被替换',
            );
          }
          rethrow;
        }
      });

  Future<LoginResult> _run(
    String username,
    String password,
    String? captcha,
  ) async {
    final JwglxtLoginPage page;
    try {
      page = await _readLoginPage();
    } on JwglxtProtocolException catch (error) {
      return LoginResult(
        AcademicStatus.PAGE_CHANGED,
        message: '教务登录页结构与预期不符：${error.message}',
      );
    }

    // 先检查验证码要求，避免未填验证码时白白轮换服务端 RSA 私钥。
    if (page.captchaRequired && (captcha == null || captcha.trim().isEmpty)) {
      return LoginResult(
        AcademicStatus.CAPTCHA_REQUIRED,
        message: '该账号需要图片验证码',
        captcha: await _loadCaptchaChallenge(),
      );
    }

    final String submittedPassword;
    if (page.encryptPassword) {
      final JwglxtPublicKey key;
      try {
        key = await _readPublicKey();
      } on JwglxtProtocolException catch (error) {
        return LoginResult(
          AcademicStatus.PAGE_CHANGED,
          message: error.message,
        );
      }
      try {
        submittedPassword = ZhengfangJwglxtProtocol.encryptPassword(
          password,
          key,
          _random,
        );
      } on JwglxtProtocolException catch (error) {
        return LoginResult(
          AcademicStatus.PAGE_CHANGED,
          message: error.message,
        );
      }
    } else {
      submittedPassword = password;
    }

    final action = Urls.resolve(
      '$_effectiveRoot${ZhengfangJwglxtProtocol.loginPath}',
      page.formAction ?? '',
    );
    final submitResponse = await _submitForm(
      url: '$action?time=${_cacheBuster()}',
      form: ZhengfangJwglxtProtocol.formFields(
        page: page,
        username: username,
        password: submittedPassword,
        captcha: captcha,
      ),
    );
    await _acceptCookies(submitResponse);
    _adoptDiscoveredContextPath(submitResponse.text, submitResponse.response.finalUrl);

    final outcome = ZhengfangJwglxtProtocol.classify(
      submitResponse.response.finalUrl,
      submitResponse.text,
    );
    if (outcome != JwglxtOutcome.SUCCESS) {
      final challenge = outcome == JwglxtOutcome.CAPTCHA_REQUIRED
          ? await _loadCaptchaChallenge()
          : null;
      return LoginResult(
        _toAcademicStatus(outcome),
        message: _describeOutcome(outcome, submitResponse.text),
        captcha: challenge,
      );
    }

    return _completePostLogin(submitResponse, username);
  }

  Future<JwglxtLoginPage> _readLoginPage() async {
    final firstStamp = _cacheBuster();
    _JwglxtExchange? initial;
    try {
      initial = await _acceptCookies(
        await _fetch(
          '$_effectiveRoot${ZhengfangJwglxtProtocol.loginPath}?time=$firstStamp',
        ),
      );
    } on AcademicException {
      if (!_hasNoContextPath(_effectiveRoot)) rethrow;
    }

    if (initial != null && initial.response.status == 200) {
      _adoptDiscoveredContextPath(initial.text, initial.response.finalUrl);
      try {
        return ZhengfangJwglxtProtocol.parseLoginPage(initial.text);
      } on JwglxtProtocolException {
        if (!_hasNoContextPath(_effectiveRoot)) rethrow;
      }
    } else if (!_hasNoContextPath(_effectiveRoot)) {
      if (initial != null) {
        return ZhengfangJwglxtProtocol.parseLoginPage(initial.text);
      }
    }

    // 裸根地址兜底：探测 `/` 的 302 或 `<meta http-equiv="refresh" content="...url=/jwglxt">`。
    await _discoverContextFromRoot();
    final retry = await _acceptCookies(
      await _fetch(
        '$_effectiveRoot${ZhengfangJwglxtProtocol.loginPath}?time=${_cacheBuster()}',
      ),
    );
    _adoptDiscoveredContextPath(retry.text, retry.response.finalUrl);
    return ZhengfangJwglxtProtocol.parseLoginPage(retry.text);
  }

  Future<void> _discoverContextFromRoot() async {
    final parsed = Urls.parseUrl(_effectiveRoot);
    if (parsed == null) return;
    final origin = StudyTransport.originOfUrl(_effectiveRoot);
    if (origin == null) return;

    var discovered = '/jwglxt';
    try {
      final rootPage = await _acceptCookies(await _fetch('$origin/'));
      final ctx = Html.jwglxtContextPath(
        rootPage.text,
        rootPage.response.finalUrl,
      );
      if (ctx != null && ctx.isNotEmpty) {
        discovered = ctx;
      }
    } catch (_) {
      // 探测失败时默认回退到标准 `/jwglxt` 前缀。
    }
    _effectiveRoot = '$origin$discovered';
    _session.updateBaseUrl(_effectiveRoot);
  }

  void _adoptDiscoveredContextPath(String body, String finalUrl) {
    if (!_hasNoContextPath(_effectiveRoot)) return;
    final origin = StudyTransport.originOfUrl(_effectiveRoot);
    if (origin == null) return;
    final ctx = Html.jwglxtContextPath(body, finalUrl);
    if (ctx != null && ctx.isNotEmpty) {
      _effectiveRoot = '$origin$ctx';
      _session.updateBaseUrl(_effectiveRoot);
    }
  }

  static bool _hasNoContextPath(String url) {
    final path = Urls.parseUrl(url)?.path ?? '';
    return path.isEmpty || path == '/';
  }

  Future<JwglxtPublicKey> _readPublicKey() async {
    final exchange = await _acceptCookies(
      await _fetch(
        '$_effectiveRoot${ZhengfangJwglxtProtocol.publicKeyPath}?time=${_cacheBuster()}',
        referer: '$_effectiveRoot${ZhengfangJwglxtProtocol.loginPath}',
        ajax: true,
      ),
    );
    return ZhengfangJwglxtProtocol.parsePublicKey(exchange.text);
  }

  Future<LoginResult> _completePostLogin(
    _JwglxtExchange submitResponse,
    String username,
  ) async {
    var identity = ZhengfangIdentity.parse(submitResponse.text, _effectiveRoot);
    var homeMeta = ZhengfangHomeParser.parse(submitResponse.text);

    // 1. 拉取 index_initMenu.html?jsdm=xs 获取 #sessionUserKey、菜单及可能内联的校历字段。
    if (homeMeta.currentTerm == null || homeMeta.studentId.isEmpty) {
      try {
        final menuPage = await _acceptCookies(
          await _fetch(
            '$_effectiveRoot/${ZhengfangHomeParser.initMenuPath}',
            referer: submitResponse.response.finalUrl,
          ),
        );
        if (menuPage.response.status == 200 &&
            !Html.isLoginPage(menuPage.text)) {
          identity = identity.merge(
            ZhengfangIdentity.parse(menuPage.text, _effectiveRoot),
          );
          final parsedMeta = ZhengfangHomeParser.parse(menuPage.text);
          if (!parsedMeta.isEmpty) {
            homeMeta = parsedMeta.merge(homeMeta);
          }
        }
      } catch (_) {
        // 最小化离线夹具中可能未录制 index_initMenu.html?jsdm=xs，安全忽略。
      }
    }

    // 1b. 新正方 v9.0 真实服务端首页通过异步 POST AreaOne / AreaSix / AreaFive 加载 #xnm/#xqm/#dqzc 与 #dqrq/#xlyq。
    if (homeMeta.currentTerm == null || homeMeta.currentWeek == null) {
      final areaOne =
          await _postOptionalHomeArea(ZhengfangHomeParser.areaOnePath);
      if (areaOne != null) {
        homeMeta = areaOne.merge(homeMeta);
      }
    }
    if (homeMeta.semesterStart == null || homeMeta.serverDate.isEmpty) {
      final areaSix =
          await _postOptionalHomeArea(ZhengfangHomeParser.areaSixPath);
      if (areaSix != null) {
        homeMeta = areaSix.merge(homeMeta);
      }
      if (homeMeta.semesterStart == null) {
        final areaFive =
            await _postOptionalHomeArea(ZhengfangHomeParser.areaFivePath);
        if (areaFive != null) {
          homeMeta = areaFive.merge(homeMeta);
        }
      }
    }

    // 2. 拉取 index_cxYhxxIndex.html 获取学生姓名、院系与班级。
    try {
      final cardPage = await _acceptCookies(
        await _fetch(
          '$_effectiveRoot$_userCardPath',
          referer: '$_effectiveRoot/${ZhengfangHomeParser.initMenuPath}',
          ajax: true,
        ),
      );
      if (cardPage.response.status == 200 && !Html.isLoginPage(cardPage.text)) {
        identity = identity.merge(
          ZhengfangIdentity.parse(cardPage.text, _effectiveRoot),
        );
      }
    } catch (_) {
      // 最小化离线夹具中可能未录制 index_cxYhxxIndex.html，继续走兜底。
    }

    // 3. 仅在尚未拿到姓名时回退请求 _effectiveRoot（兼容 qust-native.fixtures.json 最小夹具）。
    if (identity.name.isEmpty) {
      try {
        final home = await _acceptCookies(await _fetch(_effectiveRoot));
        if (home.response.status == 200 && !Html.isLoginPage(home.text)) {
          identity = identity.merge(
            ZhengfangIdentity.parse(home.text, _effectiveRoot),
          );
          if (homeMeta.currentTerm == null) {
            final fallbackMeta = ZhengfangHomeParser.parse(home.text);
            if (!fallbackMeta.isEmpty) {
              homeMeta = fallbackMeta.merge(homeMeta);
            }
          }
        }
      } catch (_) {
        if (identity.isEmpty) {
          return const LoginResult(
            AcademicStatus.NETWORK_RETRYABLE,
            message: '登录后无法访问教务首页',
          );
        }
      }
    }

    if (identity.studentId.isEmpty && homeMeta.studentId.isNotEmpty) {
      identity = identity.copyWith(studentId: homeMeta.studentId);
    }
    if (identity.grade.isEmpty && identity.studentId.isNotEmpty) {
      final inferred = identity.inferredEnrollmentYear();
      if (inferred != null) {
        identity = identity.copyWith(grade: inferred.toString());
      }
    }

    if (identity.isEmpty) {
      return const LoginResult(
        AcademicStatus.SESSION_EXPIRED,
        message: '登录响应像是成功，但教务首页仍拿不到身份',
      );
    }

    if (!homeMeta.isEmpty) {
      _session.zfHomeMetadata = homeMeta;
    }
    _session.username = username;
    return LoginResult(
      AcademicStatus.SUCCESS,
      identity: identity,
      message: '登录成功',
    );
  }

  Future<CaptchaChallenge?> _loadCaptchaChallenge() async {
    try {
      final exchange = await _acceptCookies(
        await _fetch(
          '$_effectiveRoot${ZhengfangJwglxtProtocol.kaptchaPath}?time=${_cacheBuster()}',
          referer: '$_effectiveRoot${ZhengfangJwglxtProtocol.loginPath}',
        ),
      );
      if (exchange.response.status != 200) return null;
      return CaptchaChallenge(
        image: exchange.response.body,
        fieldName: ZhengfangJwglxtProtocol.captchaField,
        refreshUrl:
            '$_effectiveRoot${ZhengfangJwglxtProtocol.kaptchaPath}?time=',
      );
    } catch (_) {
      return null;
    }
  }

  static AcademicStatus _toAcademicStatus(JwglxtOutcome outcome) =>
      switch (outcome) {
        JwglxtOutcome.INVALID_CREDENTIALS => AcademicStatus.INVALID_CREDENTIALS,
        JwglxtOutcome.CAPTCHA_REQUIRED => AcademicStatus.CAPTCHA_REQUIRED,
        JwglxtOutcome.HUMAN_VERIFICATION_REQUIRED =>
          AcademicStatus.HUMAN_VERIFICATION_REQUIRED,
        JwglxtOutcome.ACCOUNT_LOCKED => AcademicStatus.VALIDATION_FAILED,
        JwglxtOutcome.PAGE_CHANGED => AcademicStatus.PAGE_CHANGED,
        JwglxtOutcome.FAILED => AcademicStatus.VALIDATION_FAILED,
        JwglxtOutcome.SUCCESS => AcademicStatus.SUCCESS,
      };

  static String _describeOutcome(JwglxtOutcome outcome, String html) {
    final detail = ZhengfangJwglxtProtocol.errorMessage(html);
    if (detail.isNotEmpty) {
      return detail.length <= 200 ? detail : detail.substring(0, 200);
    }
    return switch (outcome) {
      JwglxtOutcome.FAILED => '教务系统未接受本次登录，且未给出原因',
      JwglxtOutcome.PAGE_CHANGED => '登录响应无法判定，页面结构可能已变化',
      JwglxtOutcome.ACCOUNT_LOCKED => '账号已被锁定',
      _ => outcome.name,
    };
  }

  Future<_JwglxtExchange> _acceptCookies(_JwglxtExchange exchange) async {
    final parsed = exchange.url;
    if (parsed != null) {
      await _session.cookies.save(parsed, exchange.response.cookies);
    }
    return exchange;
  }

  Future<_JwglxtExchange> _fetch(
    String url, {
    String? referer,
    bool ajax = false,
  }) async {
    final parsed = Urls.parseUrl(url);
    final headers = <String, String>{
      'User-Agent': StudyTransport.desktopUserAgent,
      'Accept':
          'text/html,application/xhtml+xml,application/json,*/*;q=0.8',
    };
    if (referer != null && referer.isNotEmpty) {
      headers['Referer'] = referer;
    }
    if (ajax) {
      headers['X-Requested-With'] = 'XMLHttpRequest';
    }
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

  Future<ZhengfangHomeMetadata?> _postOptionalHomeArea(
    String relativePath,
  ) async {
    try {
      final page = await _acceptCookies(
        await _submitForm(
          url: '$_effectiveRoot/$relativePath',
          form: const <(String, String)>[],
          referer: '$_effectiveRoot/${ZhengfangHomeParser.initMenuPath}',
          ajax: true,
        ),
      );
      if (page.response.status == 200 && !Html.isLoginPage(page.text)) {
        final parsed = ZhengfangHomeParser.parse(page.text);
        if (!parsed.isEmpty) return parsed;
      }
    } catch (_) {
      // 最小化离线夹具或未启用该首页区域的学校可能无此端点，安全忽略。
    }
    return null;
  }

  Future<_JwglxtExchange> _submitForm({
    required String url,
    required List<(String, String)> form,
    String? referer,
    bool ajax = false,
  }) async {
    final parsed = Urls.parseUrl(url);
    final cookie = parsed == null
        ? ''
        : await _session.cookies.cookieHeaderForParsedUrl(parsed);
    final origin = StudyTransport.originOfUrl(url);
    final encodedBody = form
        .map(
          (pair) =>
              '${Urls.encodeComponent(pair.$1)}=${Urls.encodeComponent(pair.$2)}',
        )
        .join('&');
    final headers = <String, String>{
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': StudyTransport.desktopUserAgent,
      'Referer':
          referer ?? '$_effectiveRoot${ZhengfangJwglxtProtocol.loginPath}',
    };
    if (origin != null) headers['Origin'] = origin;
    if (ajax) headers['X-Requested-With'] = 'XMLHttpRequest';
    if (cookie.isNotEmpty) headers['Cookie'] = cookie;

    final request = HttpRequest(
      method: HttpMethod.post,
      url: url,
      headers: headers,
      body: Uint8List.fromList(utf8.encode(encodedBody)),
    );
    return _decode(await _engine.execute(request));
  }

  int _cacheBuster() {
    _requestCounter += 1;
    return _clock() * 1000 + _requestCounter;
  }

  _JwglxtExchange _decode(HttpResponse response) {
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
    return _JwglxtExchange(response, text);
  }

  static String _trimTrailingSlash(String url) {
    var out = url;
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }
}

class _JwglxtExchange {
  const _JwglxtExchange(this.response, this.text);
  final HttpResponse response;
  final String text;
  ParsedUrl? get url => Urls.parseUrl(response.finalUrl);
}
