import 'dart:convert';
import 'dart:typed_data';

import '../model/academic_status.dart';
import '../net/page_charset.dart';
import '../parse/urls.dart';
import '../parse/zhengfang_cas_protocol.dart';
import '../parse/zhengfang_identity.dart';
import '../port/http.dart';
import '../port/runtime.dart';
import '../session/login_result.dart';
import '../session/session.dart';

/// 正方定制 CAS 统一身份认证登录编排。
class ZhengfangCasLoginFlow {
  ZhengfangCasLoginFlow({
    required AccountSession session,
    required HttpEngine engine,
    required TextDecoder decoder,
    required String casBaseUrl,
    required String academicBaseUrl,
  })  : _session = session,
        _engine = engine,
        _decoder = decoder,
        _casRoot = _trimTrailingSlash(casBaseUrl),
        _academicBaseUrl = academicBaseUrl;

  final AccountSession _session;
  final HttpEngine _engine;
  final TextDecoder _decoder;
  final String _casRoot;
  final String _academicBaseUrl;

  String get _serviceScopedLoginUrl =>
      '$_casRoot/cas/login?service=${Urls.encodeComponent(_academicBaseUrl)}';

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
    final CasLoginPage page;
    try {
      page = await _readLoginPage();
    } on CasProtocolException catch (error) {
      return LoginResult(
        AcademicStatus.PAGE_CHANGED,
        message: '统一认证登录页结构与预期不符：${error.message}',
      );
    }

    final CasPublicKey key;
    try {
      key = await _readPublicKey();
    } on CasProtocolException catch (error) {
      return LoginResult(
        AcademicStatus.PAGE_CHANGED,
        message: error.message,
      );
    }

    if (await _readCaptchaRequired() &&
        (captcha == null || captcha.trim().isEmpty)) {
      return LoginResult(
        AcademicStatus.CAPTCHA_REQUIRED,
        message: '该账号需要图片验证码',
        captcha: await _loadCaptchaChallenge(),
      );
    }

    final String encrypted;
    try {
      encrypted = ZhengfangCasProtocol.encryptPassword(password, key);
    } on CasProtocolException catch (error) {
      return LoginResult(
        AcademicStatus.PAGE_CHANGED,
        message: error.message,
      );
    }

    final submitResponse = await _submitForm(
      Urls.resolve('$_casRoot/cas/login', page.formAction ?? ''),
      _submissionFields(username, encrypted, page.execution, captcha),
    );
    await _acceptCookies(submitResponse);

    if (submitResponse.response.status < 300 ||
        submitResponse.response.status > 399) {
      final body = submitResponse.text;
      final err = ZhengfangCasProtocol.errorMessage(body);
      final errorText = err.trim().isEmpty ? body : err;
      return LoginResult(
        _failureStatus(errorText),
        message: errorText.length <= 200
            ? errorText
            : errorText.substring(0, 200),
      );
    }

    await _acceptCookies(await _fetch(_serviceScopedLoginUrl));
    final home = await _fetch(_academicBaseUrl);
    await _acceptCookies(home);
    return _completeWithIdentity(home.text, username);
  }

  Future<CasLoginPage> _readLoginPage() async {
    final exchange = await _acceptCookies(await _fetch(_serviceScopedLoginUrl));
    return ZhengfangCasProtocol.parseLoginPage(exchange.text);
  }

  Future<CasPublicKey> _readPublicKey() async {
    final exchange = await _fetch('$_casRoot/cas/v2/getPubKey');
    return ZhengfangCasProtocol.parsePublicKey(exchange.text);
  }

  Future<bool> _readCaptchaRequired() async {
    final exchange = await _fetch('$_casRoot/cas/v2/getKaptchaStatus');
    return ZhengfangCasProtocol.parseKaptchaStatus(exchange.text);
  }

  static List<(String, String)> _submissionFields(
    String username,
    String encryptedPassword,
    String execution,
    String? captcha,
  ) {
    final list = <(String, String)>[
      ('username', username),
      ('password', encryptedPassword),
      ('execution', execution),
      ('_eventId', 'submit'),
    ];
    if (captcha != null && captcha.trim().isNotEmpty) {
      list.add(('authcode', captcha));
    }
    return list;
  }

  LoginResult _completeWithIdentity(String html, String username) {
    final identity = ZhengfangIdentity.parse(html, _academicBaseUrl);
    if (identity.isEmpty) {
      return const LoginResult(
        AcademicStatus.SESSION_EXPIRED,
        message: '换取教务会话失败，页面仍是登录页',
      );
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
      final exchange =
          await _fetch('$_casRoot/cas/kaptcha?time=${_session.epoch}');
      if (exchange.response.status != 200) return null;
      return CaptchaChallenge(
        image: exchange.response.body,
        fieldName: 'authcode',
        refreshUrl: '$_casRoot/cas/kaptcha?time=',
      );
    } catch (_) {
      return null;
    }
  }

  static AcademicStatus _failureStatus(String text) {
    if (ZhengfangCasProtocol.indicatesInvalidCredentials(text)) {
      return AcademicStatus.INVALID_CREDENTIALS;
    }
    if (ZhengfangCasProtocol.indicatesHumanVerification(text)) {
      return AcademicStatus.HUMAN_VERIFICATION_REQUIRED;
    }
    if (ZhengfangCasProtocol.indicatesCaptchaProblem(text)) {
      return AcademicStatus.CAPTCHA_REQUIRED;
    }
    return AcademicStatus.VALIDATION_FAILED;
  }

  Future<_CasExchange> _acceptCookies(_CasExchange exchange) async {
    final parsed = exchange.url;
    if (parsed != null) {
      await _session.cookies.save(parsed, exchange.response.cookies);
    }
    return exchange;
  }

  Future<_CasExchange> _fetch(String url) async {
    final parsed = Urls.parseUrl(url);
    final headers = <String, String>{};
    if (parsed != null) {
      final cookie = await _session.cookies.cookieHeaderForParsedUrl(parsed);
      if (cookie.isNotEmpty) headers['Cookie'] = cookie;
    }
    final request = HttpRequest(
      method: HttpMethod.get,
      url: url,
      headers: headers,
    );
    return _decode(await _engine.execute(request));
  }

  Future<_CasExchange> _submitForm(
    String url,
    List<(String, String)> form,
  ) async {
    final parsed = Urls.parseUrl(url);
    final cookie = parsed == null
        ? ''
        : await _session.cookies.cookieHeaderForParsedUrl(parsed);
    final encodedBody = form
        .map(
          (pair) =>
              '${Urls.encodeComponent(pair.$1)}=${Urls.encodeComponent(pair.$2)}',
        )
        .join('&');
    final request = HttpRequest(
      method: HttpMethod.post,
      url: url,
      headers: <String, String>{
        'Content-Type': 'application/x-www-form-urlencoded',
        'Cookie': cookie,
      },
      body: Uint8List.fromList(utf8.encode(encodedBody)),
      followRedirects: false,
    );
    return _decode(await _engine.execute(request));
  }

  _CasExchange _decode(HttpResponse response) {
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
    return _CasExchange(response, text);
  }

  static String _trimTrailingSlash(String url) {
    var out = url;
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }
}

class _CasExchange {
  const _CasExchange(this.response, this.text);
  final HttpResponse response;
  final String text;
  ParsedUrl? get url => Urls.parseUrl(response.finalUrl);
}
