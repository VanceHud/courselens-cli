import 'dart:convert';

import 'package:html/dom.dart';

import '../crypto/zhengfang_rsa.dart';
import 'html.dart';

class CasProtocolException implements Exception {
  const CasProtocolException(this.message, [this.cause]);
  final String message;
  final Object? cause;

  @override
  String toString() => 'CasProtocolException($message)';
}

class CasLoginPage {
  const CasLoginPage({required this.execution, this.formAction});
  final String execution;
  final String? formAction;
}

class CasPublicKey {
  const CasPublicKey({required this.modulusHex, required this.exponentHex});
  final String modulusHex;
  final String exponentHex;
}

/// 正方定制 CAS 统一身份认证协议解析与加密（不发起请求）。
class ZhengfangCasProtocol {
  const ZhengfangCasProtocol._();

  static const String _executionQuery = 'form input[name=execution]';
  static const String _loginFormQuery = 'form#fm1';
  static const String _errorNodeId = 'errormsg';

  static const List<String> _rejectedCredentialPhrases = [
    '用户名或密码不正确',
    '用户名或密码错误',
    '账号或密码不正确',
    '密码错误',
  ];

  static const List<(String, bool)> _imageChallengePhrases = [
    ('验证码', false),
    ('invalid captcha', true),
    ('captcha error', true),
    ('captcha required', true),
  ];

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

  static CasLoginPage parseLoginPage(String html) {
    final document = Html.parse(html);
    final execution = _readExecution(document);
    return CasLoginPage(
      execution: execution,
      formAction: _readFormAction(document),
    );
  }

  static String _readExecution(Document document) {
    final el = document.querySelector(_executionQuery);
    final val = el == null ? '' : Html.attr(el, 'value').trim();
    if (val.isEmpty) {
      throw const CasProtocolException('统一认证登录页未携带 execution 令牌');
    }
    return val;
  }

  static String? _readFormAction(Document document) {
    final el = document.querySelector(_loginFormQuery);
    if (el == null) return null;
    final val = Html.attr(el, 'action').trim();
    return val.isEmpty ? null : val;
  }

  static CasPublicKey parsePublicKey(String jsonText) {
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
      return CasPublicKey(modulusHex: modulus, exponentHex: exponent);
    } catch (error) {
      throw CasProtocolException('统一认证公钥响应无法解析', error);
    }
  }

  static bool parseKaptchaStatus(String body) =>
      body.trim().toLowerCase() == 'true';

  static String encryptPassword(String password, CasPublicKey key) {
    try {
      return ZhengfangRsa.encryptPassword(
        password,
        key.modulusHex,
        key.exponentHex,
      );
    } on ZhengfangRsaCryptoException {
      throw const CasProtocolException('统一认证口令加密没有成功');
    }
  }

  static String errorMessage(String html) =>
      Html.textOf(Html.parse(html).getElementById(_errorNodeId));

  static bool indicatesInvalidCredentials(String text) =>
      _rejectedCredentialPhrases.any(text.contains);

  static bool indicatesHumanVerification(String text) =>
      _manualChallengePhrases.any(text.contains);

  static bool indicatesCaptchaProblem(String text) {
    final lower = text.toLowerCase();
    for (final (phrase, ignoreCase) in _imageChallengePhrases) {
      if (ignoreCase) {
        if (lower.contains(phrase.toLowerCase())) return true;
      } else {
        if (text.contains(phrase)) return true;
      }
    }
    return false;
  }
}
