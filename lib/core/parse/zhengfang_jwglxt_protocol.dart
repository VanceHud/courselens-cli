import 'dart:convert';

import 'package:html/dom.dart';

import '../crypto/rsa_pkcs1.dart';
import '../port/runtime.dart';
import 'html.dart';
import 'urls.dart';

class JwglxtProtocolException implements Exception {
  const JwglxtProtocolException(this.message, [this.cause]);
  final String message;
  final Object? cause;

  @override
  String toString() => 'JwglxtProtocolException($message)';
}

class JwglxtLoginPage {
  const JwglxtLoginPage({
    required this.csrfToken,
    required this.formAction,
    required this.language,
    required this.encryptPassword,
    required this.captchaRequired,
    required this.notice,
  });

  final String csrfToken;
  final String? formAction;
  final String language;
  final bool encryptPassword;
  final bool captchaRequired;
  final String notice;
}

class JwglxtPublicKey {
  const JwglxtPublicKey({
    required this.modulusBase64,
    required this.exponentBase64,
  });

  final String modulusBase64;
  final String exponentBase64;
}

enum JwglxtOutcome {
  SUCCESS,
  INVALID_CREDENTIALS,
  CAPTCHA_REQUIRED,
  HUMAN_VERIFICATION_REQUIRED,
  ACCOUNT_LOCKED,
  FAILED,
  PAGE_CHANGED,
}

/// 正方教务 v9.0 原生登录协议（`xtgl/login_slogin.html`）解析、加密与结局判定。
class ZhengfangJwglxtProtocol {
  const ZhengfangJwglxtProtocol._();

  static const String loginPath = '/xtgl/login_slogin.html';
  static const String publicKeyPath = '/xtgl/login_getPublicKey.html';
  static const String kaptchaPath = '/kaptcha';
  static const String captchaField = 'yzm';
  static const String successPath = '/xtgl/index_initMenu.html';
  static const String _mobileSuccessPath = '/auth/auth_loginSuccess.html';
  static const String _loginFileName = 'login_slogin.html';

  static const String _csrfField = 'csrftoken';
  static const String _passwordField = 'mm';
  static const String _usernameField = 'yhm';
  static const String _languageField = 'language';
  static const String _userTypeField = 'ydType';
  static const String _encryptFlagField = 'mmsfjm';
  static const String _captchaFlagField = 'dlsfbxyzm';
  static const String _tipsElementId = 'tips';
  static const String _fallbackErrorElementId = 'errormsg';
  static const String _captchaMarker = '验证码';

  static final RegExp _noticeInScript = RegExp(r'var\s+dlktsxx\s*=\s*"([^"]*)"');
  static final RegExp _loginJsRedirect = RegExp(
    r'''(?:top\.|window\.|parent\.)?location(?:\.href)?\s*=\s*['"][^'"]*login_slogin''',
    caseSensitive: false,
  );

  static const List<String> _manualChallengePhrases = [
    '短信',
    '动态码',
    '手机验证',
    '手机号',
    '二次验证',
    '二次确认',
    '扫码',
    '人脸',
    'OTP',
    'otp',
    'token 有效期',
  ];

  static const List<String> _lockPhrases = ['锁定', '已冻结', '暂时无法登录'];

  static const List<String> _rejectedCredentialPhrases = [
    '用户名或密码不正确',
    '用户名或密码错误',
    '账号或密码不正确',
    '账号或密码错误',
    '密码错误',
    '用户不存在',
    '用户名不存在',
  ];

  static JwglxtLoginPage parseLoginPage(String html) {
    final document = Html.parse(html);
    final csrf = _csrfElement(document);
    final token = csrf == null ? '' : Html.attr(csrf, 'value').trim();
    if (token.isEmpty) {
      throw const JwglxtProtocolException('登录页里找不到 csrftoken 字段');
    }

    return JwglxtLoginPage(
      csrfToken: token,
      formAction: _readFormAction(document, csrf),
      language: _readLanguage(document),
      encryptPassword: _readHiddenValue(document, _encryptFlagField) != '0',
      captchaRequired: _isCaptchaRequired(document),
      notice: (_noticeInScript.firstMatch(html)?.group(1) ?? '').trim(),
    );
  }

  static bool _isCaptchaRequired(Document document) {
    if (_readHiddenValue(document, _captchaFlagField) == '1') return true;
    final yzmInput =
        document.querySelector('input[name=$captchaField], input#yzm');
    if (yzmInput != null && Html.isEnabledControl(yzmInput)) return true;
    final yzmDiv = document.getElementById('yzmDiv');
    if (yzmDiv != null && Html.isEnabledControl(yzmDiv)) {
      final inner = yzmDiv.querySelector('input');
      if (inner == null || Html.isEnabledControl(inner)) return true;
    }
    return false;
  }

  static Element? _csrfElement(Document document) =>
      document.querySelector('input[name=$_csrfField]') ??
      document.getElementById(_csrfField);

  static String? _readFormAction(Document document, Element? csrf) {
    Element? form;
    if (csrf != null) {
      form = Html.closestTag(csrf, 'form');
    }
    if (form == null) {
      for (final candidate in document.querySelectorAll('form')) {
        if (candidate.querySelector('input[name=$_csrfField]') != null) {
          form = candidate;
          break;
        }
      }
    }
    if (form == null) return null;
    final val = Html.attr(form, 'action').trim();
    return val.isEmpty ? null : val;
  }

  static String _readLanguage(Document document) {
    final el = document.querySelector('input[name=$_languageField]');
    final val = el == null ? '' : Html.attr(el, 'value').trim();
    return val.isEmpty ? 'zh_CN' : val;
  }

  static JwglxtPublicKey parsePublicKey(String jsonText) {
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map) {
        throw const FormatException('not a JSON object');
      }
      final modulus = decoded['modulus']?.toString().trim() ?? '';
      final exponent = decoded['exponent']?.toString().trim() ?? '';
      if (modulus.isEmpty || exponent.isEmpty) {
        throw const FormatException('missing modulus/exponent');
      }
      return JwglxtPublicKey(
        modulusBase64: modulus,
        exponentBase64: exponent,
      );
    } catch (error) {
      throw JwglxtProtocolException('公钥响应无法解析', error);
    }
  }

  static String encryptPassword(
    String password,
    JwglxtPublicKey key,
    SecureRandom random,
  ) {
    try {
      return RsaPkcs1.encryptPassword(
        password: password,
        modulusBase64: key.modulusBase64,
        exponentBase64: key.exponentBase64,
        random: random,
      );
    } on RsaPkcs1CryptoException {
      throw const JwglxtProtocolException('口令的 RSA 加密没有成功');
    }
  }

  static List<(String, String)> formFields({
    required JwglxtLoginPage page,
    required String username,
    required String password,
    String? captcha,
  }) {
    final fields = <(String, String)>[
      (_csrfField, page.csrfToken),
      (_languageField, page.language),
      (_userTypeField, ''),
      (_usernameField, username),
      (_passwordField, password),
    ];
    if (captcha != null && captcha.trim().isNotEmpty) {
      fields.add((captchaField, captcha));
    }
    return fields;
  }

  static bool containsLoginForm(String html) {
    final document = Html.parse(html);
    final hasToken =
        document.querySelector('input[name=$_csrfField]') != null;
    final hasPassword =
        document.querySelector('input[name=$_passwordField]') != null;
    return hasToken && hasPassword;
  }

  static String errorMessage(String html) {
    final document = Html.parse(html);
    final tips = Html.textOf(document.getElementById(_tipsElementId));
    if (tips.isNotEmpty) return tips;
    return Html.textOf(document.getElementById(_fallbackErrorElementId));
  }

  static bool indicatesInvalidCredentials(String text) =>
      _rejectedCredentialPhrases.any(text.contains);

  static bool indicatesAccountLocked(String text) =>
      _lockPhrases.any(text.contains);

  static bool indicatesCaptchaProblem(String text) =>
      text.contains(_captchaMarker);

  static bool indicatesHumanVerification(String text) =>
      _manualChallengePhrases.any(text.contains);

  static JwglxtOutcome classify(String finalUrl, String html) {
    final reported = errorMessage(html);
    if (reported.isNotEmpty) return _classifyFailure(reported);

    if (_loginJsRedirect.hasMatch(html)) return JwglxtOutcome.FAILED;

    if (containsLoginForm(html)) {
      return _isLoginPageUrl(finalUrl)
          ? JwglxtOutcome.FAILED
          : JwglxtOutcome.PAGE_CHANGED;
    }

    if (html.contains(successPath) || html.contains(_mobileSuccessPath)) {
      return JwglxtOutcome.SUCCESS;
    }

    return _isLoginPageUrl(finalUrl)
        ? JwglxtOutcome.PAGE_CHANGED
        : JwglxtOutcome.SUCCESS;
  }

  static bool _isLoginPageUrl(String url) {
    var path = Urls.parseUrl(url)?.path ?? '';
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    final slash = path.lastIndexOf('/');
    final lastSegment = slash < 0 ? path : path.substring(slash + 1);
    return lastSegment == _loginFileName;
  }

  static JwglxtOutcome _classifyFailure(String text) {
    if (indicatesAccountLocked(text)) return JwglxtOutcome.ACCOUNT_LOCKED;
    if (indicatesHumanVerification(text)) {
      return JwglxtOutcome.HUMAN_VERIFICATION_REQUIRED;
    }
    if (indicatesCaptchaProblem(text)) return JwglxtOutcome.CAPTCHA_REQUIRED;
    if (indicatesInvalidCredentials(text)) {
      return JwglxtOutcome.INVALID_CREDENTIALS;
    }
    return JwglxtOutcome.FAILED;
  }

  static String _readHiddenValue(Document document, String name) {
    final el = document.querySelector('input[name=$name]');
    return el == null ? '' : Html.attr(el, 'value').trim();
  }
}
