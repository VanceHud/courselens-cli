import 'dart:math' as math;
import 'dart:typed_data';

/// 页面编码判定（Content-Type 头 -> `<meta charset>` 嗅探 -> 兜底 UTF-8）。
class PageCharset {
  const PageCharset._();

  static const int _sniffLimit = 2048;
  static const String utf8Charset = 'utf-8';

  static final RegExp _headerCharset = RegExp(
    r'''charset\s*=\s*["']?([A-Za-z0-9_\-]+)''',
    caseSensitive: false,
  );

  static String detect(String? contentTypeHeader, Uint8List bytes) {
    if (contentTypeHeader != null) {
      final fromHeader = _headerCharset.firstMatch(contentTypeHeader)?.group(1);
      if (fromHeader != null) return normalize(fromHeader);
    }

    final sniff = _sniffPrefix(bytes);
    final fromMeta = _headerCharset.firstMatch(sniff)?.group(1);
    if (fromMeta != null) return normalize(fromMeta);

    return utf8Charset;
  }

  static String normalize(String raw) {
    final cleaned = raw.trim().toLowerCase().replaceAll('_', '-');
    return switch (cleaned) {
      'gb2312' ||
      'gb-2312' ||
      'gbk' ||
      'gb18030' ||
      'gb-18030' ||
      'x-gbk' ||
      'csgb2312' =>
        'gbk',
      'utf8' || 'utf-8' => utf8Charset,
      'big5' || 'big-5' => 'big5',
      _ => raw.trim().toLowerCase(),
    };
  }

  static String _sniffPrefix(Uint8List bytes) {
    final limit = math.min(bytes.length, _sniffLimit);
    final out = StringBuffer();
    for (var i = 0; i < limit; i++) {
      final v = bytes[i] & 0xFF;
      if ((v >= 0x20 && v <= 0x7E) || v == 0x09 || v == 0x0A || v == 0x0D) {
        out.writeCharCode(v);
      } else {
        out.write(' ');
      }
    }
    return out.toString();
  }
}
