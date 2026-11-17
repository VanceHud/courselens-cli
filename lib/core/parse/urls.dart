import 'dart:convert';

/// 已分解的 URL（RFC 3986）。
class ParsedUrl {
  const ParsedUrl({
    required this.scheme,
    required this.host,
    required this.port,
    required this.path,
    this.userInfo,
    this.hasExplicitPort = false,
  });

  final String scheme;
  final String host;
  final int port;
  final String path;
  final String? userInfo;
  final bool hasExplicitPort;

  bool get isSecure {
    final lower = scheme.toLowerCase();
    return lower == 'https' || lower == 'wss';
  }

  /// Cookie 的默认路径（RFC 6265 §5.1.4）。
  String get defaultCookiePath {
    if (path.isEmpty || path == '/') return '/';
    if (!path.startsWith('/')) return '/';
    final lastSlash = path.lastIndexOf('/');
    return lastSlash <= 0 ? '/' : path.substring(0, lastSlash);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ParsedUrl &&
          scheme == other.scheme &&
          host == other.host &&
          port == other.port &&
          path == other.path &&
          userInfo == other.userInfo &&
          hasExplicitPort == other.hasExplicitPort;

  @override
  int get hashCode => Object.hash(
        scheme,
        host,
        port,
        path,
        userInfo,
        hasExplicitPort,
      );
}

/// URL 分解、RFC 3986 §5.3 相对路径解析与 Java `URLEncoder` 等价百分号编码。
class Urls {
  const Urls._();

  static final RegExp _uriSyntax = RegExp(
    r'^(?:([A-Za-z][A-Za-z0-9+.\-]*):)?(?:(//)([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?$',
  );

  static const int _spaceCode = 0x20;
  static const String _hexDigits = '0123456789ABCDEF';

  static final Set<int> _keptLiterals = () {
    final s = <int>{};
    for (var c = 0x41; c <= 0x5A; c++) {
      s.add(c);
    }
    for (var c = 0x61; c <= 0x7A; c++) {
      s.add(c);
    }
    for (var c = 0x30; c <= 0x39; c++) {
      s.add(c);
    }
    s.addAll('-_.*'.codeUnits);
    return s;
  }();

  static ParsedUrl? parseUrl(String url) {
    final match = _uriSyntax.firstMatch(url);
    if (match == null) return null;
    final scheme = match.group(1);
    if (scheme == null || scheme.isEmpty) return null;
    if (match.group(2) != '//') return null;

    final rawAuthority = match.group(3) ?? '';
    final atIndex = rawAuthority.lastIndexOf('@');
    final userInfo = atIndex >= 0 ? rawAuthority.substring(0, atIndex) : null;
    final hostPart =
        atIndex >= 0 ? rawAuthority.substring(atIndex + 1) : rawAuthority;
    final hostAndPort = _splitHostPort(hostPart);
    if (hostAndPort == null) return null;

    final (host, portText) = hostAndPort;
    final parsedPort = portText == null ? null : int.tryParse(portText);
    if (portText != null && parsedPort == null) {
      // Kotlin uses toIntOrNull() ?: defaultPortOf(scheme)
      return ParsedUrl(
        scheme: scheme,
        host: host.toLowerCase(),
        port: _defaultPortOf(scheme),
        path: (match.group(4) == null || match.group(4)!.isEmpty)
            ? '/'
            : match.group(4)!,
        userInfo: userInfo,
        hasExplicitPort: true,
      );
    }
    final rawPath = match.group(4) ?? '';
    return ParsedUrl(
      scheme: scheme,
      host: host.toLowerCase(),
      port: parsedPort ?? _defaultPortOf(scheme),
      path: rawPath.isEmpty ? '/' : rawPath,
      userInfo: userInfo,
      hasExplicitPort: portText != null,
    );
  }

  static (String, String?)? _splitHostPort(String authority) {
    String host;
    String? port;
    if (authority.startsWith('[')) {
      final closing = authority.indexOf(']');
      if (closing < 0) return null;
      host = authority.substring(1, closing);
      var rest = authority.substring(closing + 1);
      if (rest.startsWith(':')) rest = rest.substring(1);
      port = rest.isEmpty ? null : rest;
    } else {
      final separator = authority.lastIndexOf(':');
      host = separator >= 0 ? authority.substring(0, separator) : authority;
      port = separator >= 0 ? authority.substring(separator + 1) : null;
    }
    return host.isEmpty ? null : (host, port);
  }

  static int _defaultPortOf(String scheme) => switch (scheme.toLowerCase()) {
        'https' || 'wss' => 443,
        'http' || 'ws' => 80,
        _ => -1,
      };

  /// 按 RFC 3986 §5.3 将 [reference] 解析到 [base] 之上。
  static String resolve(String base, String reference) {
    final target = _split(reference);
    final origin = _split(base);
    final resolved = _resolveComponents(target, origin);
    return _assemble(
      resolved.scheme,
      resolved.authority,
      resolved.path,
      resolved.query,
      target.fragment,
    );
  }

  static _Resolved _resolveComponents(_UrlParts target, _UrlParts origin) {
    if (target.scheme != null) {
      return _Resolved(
        target.scheme,
        target.authority,
        _stripDotSegments(target.path),
        target.query,
      );
    }
    if (target.hasAuthority) {
      return _Resolved(
        origin.scheme,
        target.authority,
        _stripDotSegments(target.path),
        target.query,
      );
    }
    if (target.path.isEmpty) {
      return _Resolved(
        origin.scheme,
        origin.authority,
        origin.path,
        target.query ?? origin.query,
      );
    }
    if (target.path.startsWith('/')) {
      return _Resolved(
        origin.scheme,
        origin.authority,
        _stripDotSegments(target.path),
        target.query,
      );
    }
    return _Resolved(
      origin.scheme,
      origin.authority,
      _stripDotSegments(_mergePath(origin, target.path)),
      target.query,
    );
  }

  /// 与 `URLEncoder.encode(value, "UTF-8").replace("+", "%20")` 等价。
  static String encodeComponent(String value) {
    final out = StringBuffer();
    for (final byte in utf8.encode(value)) {
      final b = byte & 0xFF;
      if (b == _spaceCode) {
        out.write('%20');
      } else if (_keptLiterals.contains(b)) {
        out.writeCharCode(b);
      } else {
        out
          ..write('%')
          ..write(_hexDigits[b >> 4])
          ..write(_hexDigits[b & 0x0F]);
      }
    }
    return out.toString();
  }

  static _UrlParts _split(String value) {
    final match = _uriSyntax.firstMatch(value);
    if (match == null) {
      return _UrlParts(
        scheme: null,
        hasAuthority: false,
        authority: null,
        path: value,
        query: null,
        fragment: null,
      );
    }
    final rawScheme = match.group(1);
    final hasAuthority = match.group(2) == '//';
    return _UrlParts(
      scheme: (rawScheme == null || rawScheme.isEmpty) ? null : rawScheme,
      hasAuthority: hasAuthority,
      authority: hasAuthority ? (match.group(3) ?? '') : null,
      path: match.group(4) ?? '',
      query: value.contains('?') ? (match.group(5) ?? '') : null,
      fragment: value.contains('#') ? (match.group(6) ?? '') : null,
    );
  }

  static String _mergePath(_UrlParts base, String relative) {
    if (base.hasAuthority && base.path.isEmpty) {
      return '/$relative';
    }
    final cut = base.path.lastIndexOf('/');
    return cut < 0 ? relative : '${base.path.substring(0, cut + 1)}$relative';
  }

  static String _stripDotSegments(String path) {
    var remaining = path;
    var resolved = '';
    while (remaining.isNotEmpty) {
      if (remaining.startsWith('../')) {
        remaining = remaining.substring(3);
      } else if (remaining.startsWith('./')) {
        remaining = remaining.substring(2);
      } else if (remaining.startsWith('/./')) {
        remaining = '/${remaining.substring(3)}';
      } else if (remaining == '/.') {
        remaining = '/';
      } else if (remaining.startsWith('/../')) {
        resolved = _withoutLastSegment(resolved);
        remaining = '/${remaining.substring(4)}';
      } else if (remaining == '/..') {
        resolved = _withoutLastSegment(resolved);
        remaining = '/';
      } else if (remaining == '.' || remaining == '..') {
        remaining = '';
      } else {
        final nextSlash = remaining.indexOf(
          '/',
          remaining.startsWith('/') ? 1 : 0,
        );
        final end = nextSlash < 0 ? remaining.length : nextSlash;
        resolved += remaining.substring(0, end);
        remaining = remaining.substring(end);
      }
    }
    return resolved;
  }

  static String _withoutLastSegment(String s) {
    final cut = s.lastIndexOf('/');
    return cut <= 0 ? '' : s.substring(0, cut);
  }

  static String _assemble(
    String? scheme,
    String? authority,
    String path,
    String? query,
    String? fragment,
  ) {
    final out = StringBuffer();
    if (scheme != null) {
      out
        ..write(scheme)
        ..write(':');
    }
    if (authority != null) {
      out
        ..write('//')
        ..write(authority);
    }
    out.write(path);
    if (query != null) {
      out
        ..write('?')
        ..write(query);
    }
    if (fragment != null) {
      out
        ..write('#')
        ..write(fragment);
    }
    return out.toString();
  }
}

class _Resolved {
  const _Resolved(this.scheme, this.authority, this.path, this.query);
  final String? scheme;
  final String? authority;
  final String path;
  final String? query;
}

class _UrlParts {
  const _UrlParts({
    required this.scheme,
    required this.hasAuthority,
    required this.authority,
    required this.path,
    required this.query,
    required this.fragment,
  });

  final String? scheme;
  final bool hasAuthority;
  final String? authority;
  final String path;
  final String? query;
  final String? fragment;
}
