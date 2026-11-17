/// 正方定制 CAS 单点登录页 `security.js`（David Shapiro RSA 变体）口令加密。
class ZhengfangRsaCryptoException implements Exception {
  const ZhengfangRsaCryptoException(this.message);
  final String message;

  @override
  String toString() => 'ZhengfangRsaCryptoException($message)';
}

class ZhengfangRsa {
  const ZhengfangRsa._();

  static const int _bitsPerUnit = 16;
  static const int _emptyUnit = 0;
  static const int _hexRadix = 16;
  static const String _blockSeparator = ' ';

  static String encryptPassword(
    String password,
    String modulusHex,
    String exponentHex,
  ) {
    final modulus = _parseHexInteger(modulusHex);
    if (modulus == null) {
      throw const ZhengfangRsaCryptoException('CAS 公钥模数不是合法的十六进制串');
    }
    final exponent = _parseHexInteger(exponentHex);
    if (exponent == null) {
      throw const ZhengfangRsaCryptoException('CAS 公钥指数不是合法的十六进制串');
    }
    if (modulus <= BigInt.zero || exponent <= BigInt.zero) {
      throw const ZhengfangRsaCryptoException('CAS 公钥的模数与指数都必须为正数');
    }

    final blockUnits = _blockUnitsFor(modulus);
    final padded = _reversedUnitsPaddedTo(password, blockUnits);
    final blocks = <String>[];
    for (var i = 0; i < padded.length; i += blockUnits) {
      final chunk = padded.sublist(i, i + blockUnits);
      blocks.add(_encryptBlock(chunk, modulus, exponent));
    }
    return blocks.join(_blockSeparator);
  }

  static int _blockUnitsFor(BigInt modulus) {
    final unitCount = (modulus.bitLength + _bitsPerUnit - 1) ~/ _bitsPerUnit;
    final units = 2 * (unitCount - 1);
    if (units <= 0) {
      throw const ZhengfangRsaCryptoException('CAS 模数过短，推不出分组长度');
    }
    return units;
  }

  /// 将口令的 UTF-16 码元倒序后补 0 对齐到 `unitsPerBlock` 的整数倍。
  static List<int> _reversedUnitsPaddedTo(String password, int unitsPerBlock) {
    final units = password.codeUnits.reversed.toList();
    final remainder = units.length % unitsPerBlock;
    if (remainder == 0) return units;
    final padCount = unitsPerBlock - remainder;
    return <int>[...units, ...List<int>.filled(padCount, _emptyUnit)];
  }

  static BigInt _blockInteger(List<int> block) {
    var accumulated = BigInt.zero;
    var pairIndex = block.length - 2;
    while (pairIndex >= 0) {
      final digit = block[pairIndex] + (block[pairIndex + 1] << 8);
      accumulated = (accumulated << _bitsPerUnit) + BigInt.from(digit);
      pairIndex -= 2;
    }
    return accumulated;
  }

  static String _encryptBlock(List<int> block, BigInt modulus, BigInt exponent) {
    return _blockInteger(block).modPow(exponent, modulus).toRadixString(_hexRadix);
  }

  static BigInt? _parseHexInteger(String digits) {
    if (digits.isEmpty) return null;
    for (var i = 0; i < digits.length; i++) {
      final c = digits.codeUnitAt(i);
      final isDigit = c >= 0x30 && c <= 0x39;
      final isLowerHex = c >= 0x61 && c <= 0x66;
      final isUpperHex = c >= 0x41 && c <= 0x46;
      if (!isDigit && !isLowerHex && !isUpperHex) return null;
    }
    return BigInt.parse(digits, radix: _hexRadix);
  }
}
