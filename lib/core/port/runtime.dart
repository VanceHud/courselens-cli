import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:charset/charset.dart';

/// 密码学安全的随机字节源端口。
///
/// 正方教务（jwglxt）原生登录采用 RSA PKCS#1 v1.5，填充字节必须不可预测；
/// 单元测试可注入确定性实现以便逐字节对拍。
abstract interface class SecureRandom {
  Uint8List bytes(int length);
}

/// 基于 `Random.secure()` 的跨五端（含 Web WebCrypto）密码学安全随机源。
class SystemSecureRandom implements SecureRandom {
  SystemSecureRandom() : _random = Random.secure();

  final Random _random;

  @override
  Uint8List bytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }
}

/// 字节到文本的解码端口。
///
/// 国内部分高校教务（旧正方、强智）返回 GBK/GB18030，解码必须发生在 HTML/JSON 解析之前。
/// 不认识的编码名必须安全回退到 UTF-8，避免因学校拼错编码名中断流程。
abstract interface class TextDecoder {
  String decode(Uint8List bytes, String charsetName);
}

/// 基于纯 Dart `package:charset` 的多字符集解码器（全五端通用，支持 UTF-8 / GBK / Big5 / Latin-1）。
class CharsetTextDecoder implements TextDecoder {
  const CharsetTextDecoder();

  @override
  String decode(Uint8List bytes, String charsetName) {
    final normalized = charsetName.trim().toLowerCase().replaceAll('_', '-');
    try {
      switch (normalized) {
        case 'utf-8':
        case 'utf8':
          return utf8.decode(bytes, allowMalformed: true);
        case 'gbk':
        case 'gb2312':
        case 'gb-2312':
        case 'gb18030':
        case 'gb-18030':
        case 'x-gbk':
        case 'csgb2312':
          return gbk.decode(bytes);
        default:
          final codec = Charset.getByName(normalized);
          if (codec != null) {
            return codec.decode(bytes);
          }
          return utf8.decode(bytes, allowMalformed: true);
      }
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }
}

/// 时间端口。`sleepUntil` 只允许在驱动层使用，纯状态机引擎只接收注入的时间戳。
abstract interface class Clock {
  DateTime now();
  Future<void> sleepUntil(DateTime instant);
}

enum LogLevel { debug, info, warn, error }

abstract interface class Logger {
  void log(LogLevel level, String tag, String message, [Object? error]);
}

/// 本地通知端口。
abstract interface class Notifier {
  Future<void> post(String title, String body);
}
