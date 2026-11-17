import 'dart:convert';
import 'dart:typed_data';

import '../port/runtime.dart';
import 'base64_codec.dart';

/// 正方教务（jwglxt / `xtgl` 路径）登录口令加密：标准 RSA PKCS#1 v1.5。
class RsaPkcs1CryptoException implements Exception {
  const RsaPkcs1CryptoException(this.message);
  final String message;

  @override
  String toString() => 'RsaPkcs1CryptoException($message)';
}

class RsaPkcs1 {
  const RsaPkcs1._();

  static const int _minBlockSize = 11;
  static const int _bitsPerByte = 8;
  static const int _hexRadix = 16;
  static const int _lowByteMask = 0xFF;
  static const int _lowNibbleMask = 0x0F;
  static const String _hexAlphabet = '0123456789abcdef';

  /// 加密口令，返回定长块编码后的 Base64 密文。
  /// 任何失败都抛 [RsaPkcs1CryptoException]，绝不返回明文。
  static String encryptPassword({
    required String password,
    required String modulusBase64,
    required String exponentBase64,
    required SecureRandom random,
  }) {
    final modulus = _publicKeyComponent(modulusBase64, 'modulus');
    final exponent = _publicKeyComponent(exponentBase64, 'exponent');
    if (modulus <= BigInt.zero) {
      throw const RsaPkcs1CryptoException('modulus 不是正数');
    }
    if (exponent <= BigInt.zero) {
      throw const RsaPkcs1CryptoException('exponent 不是正数');
    }

    final blockSize = _blockSizeOf(modulus);
    final plainBytes = Uint8List.fromList(utf8.encode(password));
    _requireFitsInBlock(plainBytes, blockSize);

    final block = pkcs1Block(plainBytes, blockSize, random);
    final messageInt = BigInt.parse(_toHexDigits(block), radix: _hexRadix);
    final residue = messageInt.modPow(exponent, modulus);
    final cipherHex =
        residue.toRadixString(_hexRadix).padLeft(blockSize * 2, '0');
    return Base64Codec.encode(_fromHexDigits(cipherHex));
  }

  static int _blockSizeOf(BigInt modulus) {
    final bytes = (modulus.bitLength + _bitsPerByte - 1) ~/ _bitsPerByte;
    if (bytes < _minBlockSize) {
      throw RsaPkcs1CryptoException('模数过小（$bytes 字节），容不下 PKCS#1 填充');
    }
    return bytes;
  }

  static void _requireFitsInBlock(Uint8List plainBytes, int blockSize) {
    final limit = blockSize - _minBlockSize;
    if (plainBytes.isEmpty) {
      throw const RsaPkcs1CryptoException('口令为空');
    }
    if (plainBytes.length > limit) {
      throw RsaPkcs1CryptoException(
        '口令过长（${plainBytes.length} 字节，该密钥上限 $limit 字节）',
      );
    }
  }

  /// 按 PKCS#1 v1.5 组装 `00 || 02 || PS || 00 || M`，PS 为非零随机字节。
  static Uint8List pkcs1Block(
    Uint8List message,
    int blockSize,
    SecureRandom random,
  ) {
    final padLength = blockSize - message.length - 3;
    if (padLength < 8) {
      throw RsaPkcs1CryptoException(
        'PKCS#1 填充长度不足（$padLength 字节，规格要求至少 8）',
      );
    }

    final block = Uint8List(blockSize);
    block[0] = 0x00;
    block[1] = 0x02;
    _fillNonZeroRandom(block, offset: 2, length: padLength, random: random);
    block[2 + padLength] = 0x00;
    block.setRange(3 + padLength, blockSize, message);
    return block;
  }

  static void _fillNonZeroRandom(
    Uint8List block, {
    required int offset,
    required int length,
    required SecureRandom random,
  }) {
    var filled = 0;
    while (filled < length) {
      final drawn = random.bytes(length - filled);
      if (drawn.isEmpty) {
        throw const RsaPkcs1CryptoException('随机源未返回字节');
      }
      for (final byte in drawn) {
        if (byte == 0) continue;
        block[offset + filled] = byte;
        filled += 1;
        if (filled == length) break;
      }
    }
  }

  static BigInt _publicKeyComponent(String encoded, String label) {
    final compact = encoded.trim();
    if (compact.isEmpty) {
      throw RsaPkcs1CryptoException('公钥 $label 为空');
    }
    final bytes = Base64Codec.decode(compact);
    if (bytes == null) {
      throw RsaPkcs1CryptoException('公钥 $label 不是合法的 Base64');
    }
    if (bytes.isEmpty) {
      throw RsaPkcs1CryptoException('公钥 $label 解码后为空');
    }
    return BigInt.parse(_toHexDigits(bytes), radix: _hexRadix);
  }

  static String _toHexDigits(Uint8List bytes) {
    final out = StringBuffer();
    for (final byte in bytes) {
      final v = byte & _lowByteMask;
      out
        ..write(_hexAlphabet[v >> 4])
        ..write(_hexAlphabet[v & _lowNibbleMask]);
    }
    return out.toString();
  }

  static Uint8List _fromHexDigits(String hex) {
    if (hex.length.isOdd) {
      throw ArgumentError('十六进制串长度必须为偶数：${hex.length}');
    }
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final high = _hexValueAt(hex, i * 2);
      final low = _hexValueAt(hex, i * 2 + 1);
      out[i] = (high << 4) | low;
    }
    return out;
  }

  static int _hexValueAt(String hex, int index) {
    final code = hex.codeUnitAt(index);
    if (code >= 0x30 && code <= 0x39) return code - 0x30;
    if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10;
    if (code >= 0x41 && code <= 0x46) return code - 0x41 + 10;
    throw RsaPkcs1CryptoException('非法的十六进制字符：${hex[index]}');
  }
}
