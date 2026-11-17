import 'dart:typed_data';

/// Base64 编解码（RFC 4648 标准字母表，带 `=` 填充）。
///
/// 解码容忍缺失填充、换行与空白，严格拒绝表外字符、填充位置错误、填充数量错误、
/// 填充后仍有非空字符、以及非零尾部残余位。
class Base64Codec {
  const Base64Codec._();

  static const String _symbolTable =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  static const int _bitsPerSymbol = 6;
  static const int _bitsPerByte = 8;
  static const int _sextetMask = 0x3F;
  static const int _lowByteMask = 0xFF;
  static const int _asciiLimit = 128;
  static const int _paddingCode = 0x3D; // '='
  static const int _maxPadding = 2;
  static const int _noPaddingSeen = -1;

  static final List<int> _symbolIndex = () {
    final table = List<int>.filled(_asciiLimit, -1);
    for (var i = 0; i < _symbolTable.length; i++) {
      table[_symbolTable.codeUnitAt(i)] = i;
    }
    return table;
  }();

  static String encode(Uint8List bytes) {
    if (bytes.isEmpty) return '';
    final out = StringBuffer();
    var cursor = 0;
    while (cursor + 2 < bytes.length) {
      final b0 = bytes[cursor] & _lowByteMask;
      final b1 = bytes[cursor + 1] & _lowByteMask;
      final b2 = bytes[cursor + 2] & _lowByteMask;
      out
        ..write(_symbolTable[b0 >> 2])
        ..write(_symbolTable[((b0 << 4) | (b1 >> 4)) & _sextetMask])
        ..write(_symbolTable[((b1 << 2) | (b2 >> 6)) & _sextetMask])
        ..write(_symbolTable[b2 & _sextetMask]);
      cursor += 3;
    }
    final remaining = bytes.length - cursor;
    if (remaining == 1) {
      final b0 = bytes[cursor] & _lowByteMask;
      out
        ..write(_symbolTable[b0 >> 2])
        ..write(_symbolTable[(b0 << 4) & _sextetMask])
        ..write('==');
    } else if (remaining == 2) {
      final b0 = bytes[cursor] & _lowByteMask;
      final b1 = bytes[cursor + 1] & _lowByteMask;
      out
        ..write(_symbolTable[b0 >> 2])
        ..write(_symbolTable[((b0 << 4) | (b1 >> 4)) & _sextetMask])
        ..write(_symbolTable[(b1 << 2) & _sextetMask])
        ..write('=');
    }
    return out.toString();
  }

  /// 解码失败返回 `null`。
  static Uint8List? decode(String text) {
    final output = <int>[];
    var window = 0;
    var pendingBits = 0;
    var paddingCount = 0;
    var bitsBeforePadding = _noPaddingSeen;

    for (var i = 0; i < text.length; i++) {
      final code = text.codeUnitAt(i);
      if (code == _paddingCode) {
        if (paddingCount == 0) bitsBeforePadding = pendingBits;
        paddingCount += 1;
        if (paddingCount > _maxPadding) return null;
        continue;
      }
      if (_isIgnorableSpacing(code)) continue;
      if (paddingCount > 0) return null;

      final sextet = _sextetOf(code);
      if (sextet == null) return null;
      window = (window << _bitsPerSymbol) | sextet;
      pendingBits += _bitsPerSymbol;
      if (pendingBits >= _bitsPerByte) {
        pendingBits -= _bitsPerByte;
        output.add((window >> pendingBits) & _lowByteMask);
      }
    }

    if (_hasUnusableTail(window, pendingBits)) return null;
    if (paddingCount > 0 &&
        !_paddingIsConsistent(paddingCount, bitsBeforePadding, pendingBits)) {
      return null;
    }
    return Uint8List.fromList(output);
  }

  static bool _hasUnusableTail(int window, int pendingBits) {
    if (pendingBits >= _bitsPerSymbol) return true;
    if (pendingBits == 0) return false;
    final tailMask = (1 << pendingBits) - 1;
    return (window & tailMask) != 0;
  }

  static bool _paddingIsConsistent(
    int paddingCount,
    int bitsBeforePadding,
    int tailBits,
  ) {
    if (bitsBeforePadding != tailBits) return false;
    final expected = switch (bitsBeforePadding) {
      4 => 2,
      2 => 1,
      _ => -1,
    };
    if (expected < 0) return false;
    return paddingCount == expected;
  }

  static int? _sextetOf(int code) {
    if (code >= _asciiLimit || code < 0) return null;
    final index = _symbolIndex[code];
    return index < 0 ? null : index;
  }

  static bool _isIgnorableSpacing(int code) =>
      code == 0x0A || code == 0x0D || code == 0x20 || code == 0x09;
}
