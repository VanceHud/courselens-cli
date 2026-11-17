import '../parse/urls.dart';
import '../port/http.dart';

/// `Set-Cookie` 解析（RFC 6265 §5.2 / §5.3）。
class SetCookie {
  const SetCookie._();

  static const Map<String, int> _monthNumbers = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };

  static const int _secondsPerMinute = 60;
  static const int _secondsPerHour = 3600;
  static const int _secondsPerDay = 86400;

  static const Set<String> _multiPartPublicSuffixes = {
    'edu.cn',
    'ac.cn',
    'gov.cn',
    'org.cn',
    'com.cn',
    'net.cn',
    'mil.cn',
    'edu.hk',
    'edu.tw',
    'edu.mo',
    'ac.uk',
    'ac.jp',
    'edu.au',
    'edu.sg',
    'co.uk',
    'co.jp',
    'org.uk',
    'com.hk',
    'com.tw',
    'com.au',
    'com.sg',
    'github.io',
    'pages.dev',
    'workers.dev',
    'vercel.app',
    'netlify.app',
  };

  static final RegExp _ipv4LiteralPattern =
      RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$');

  static bool _isPublicSuffixOrInvalidCookieDomain(String domain) {
    final clean = domain.trim().toLowerCase().replaceAll(RegExp(r'^\.+|\.+$'), '');
    if (clean.isEmpty) return true;
    if (!clean.contains('.')) return true;
    if (clean == 'localhost' ||
        clean.endsWith('.localhost') ||
        clean.endsWith('.local') ||
        clean.endsWith('.internal')) {
      return true;
    }
    if (_ipv4LiteralPattern.hasMatch(clean) || clean.contains(':')) {
      return true;
    }
    return _multiPartPublicSuffixes.contains(clean);
  }

  static bool _hasControlChars(String input) {
    for (var i = 0; i < input.length; i++) {
      final code = input.codeUnitAt(i);
      if (code <= 0x1F || code == 0x7F) return true;
    }
    return false;
  }

  static bool _isValidCookieName(String name) {
    if (name.isEmpty || name.startsWith(r'$') || _hasControlChars(name)) {
      return false;
    }
    for (var i = 0; i < name.length; i++) {
      final c = name.codeUnitAt(i);
      // Reject whitespace, ';', ',', '=' in cookie token
      if (c == 0x20 || c == 0x3B || c == 0x2C || c == 0x3D) return false;
    }
    return true;
  }

  static StoredCookie? parse(
    String header,
    ParsedUrl requestUrl,
    int nowEpochSeconds,
  ) {
    final nameAndValue = _splitNameAndValue(header);
    if (nameAndValue == null) return null;
    final (name, value) = nameAndValue;
    final attributes = _readAttributes(header, nowEpochSeconds);

    var hostOnly = attributes.domain == null;
    var effectiveDomain = attributes.domain ?? requestUrl.host;
    if (!hostOnly) {
      if (_isPublicSuffixOrInvalidCookieDomain(effectiveDomain)) {
        if (effectiveDomain == requestUrl.host.toLowerCase()) {
          hostOnly = true;
          effectiveDomain = requestUrl.host;
        } else {
          return null;
        }
      } else if (!domainMatch(requestUrl.host, effectiveDomain)) {
        return null;
      }
    }

    return StoredCookie(
      name: name,
      value: value,
      domain: effectiveDomain,
      path: attributes.path ?? requestUrl.defaultCookiePath,
      secure: attributes.secureOnly,
      httpOnly: attributes.httpOnly,
      expiresAtEpochSeconds: attributes.expiryEpochSeconds,
      hostOnly: hostOnly,
    );
  }

  static (String, String)? _splitNameAndValue(String header) {
    final semicolon = header.indexOf(';');
    final head = semicolon < 0 ? header : header.substring(0, semicolon);
    final separator = head.indexOf('=');
    if (separator <= 0) return null;

    final name = head.substring(0, separator).trim();
    if (!_isValidCookieName(name)) return null;
    var value = head.substring(separator + 1).trim();
    if (_hasControlChars(value)) return null;
    while (value.startsWith('"')) {
      value = value.substring(1);
    }
    while (value.endsWith('"')) {
      value = value.substring(0, value.length - 1);
    }
    return (name, value);
  }

  static _CookieAttributes _readAttributes(String header, int nowEpochSeconds) {
    final attributes = _CookieAttributes();
    final parts = header.split(';');
    for (var i = 1; i < parts.length; i++) {
      attributes.accept(parts[i], nowEpochSeconds);
    }
    return attributes;
  }

  /// 域匹配（RFC 6265 §5.1.3）。
  static bool domainMatch(String host, String domain) {
    if (host == domain) return true;
    if (domain.isEmpty || host.length <= domain.length) return false;
    final boundary = host.length - domain.length - 1;
    return host.endsWith(domain) && host[boundary] == '.';
  }

  /// 路径匹配（RFC 6265 §5.1.4）。
  static bool pathMatch(String urlPath, String cookiePath) {
    if (urlPath == cookiePath) return true;
    if (!urlPath.startsWith(cookiePath)) return false;
    if (cookiePath.endsWith('/')) return true;
    return urlPath.length > cookiePath.length &&
        urlPath[cookiePath.length] == '/';
  }

  /// 解析 HTTP 日期（RFC 1123 / RFC 850 两位年份形态）。
  static int? parseHttpDate(String raw) {
    final comma = raw.indexOf(',');
    final datePart = (comma < 0 ? raw : raw.substring(comma + 1)).trim();
    final fields = datePart
        .split(RegExp(r'[ \-]'))
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (fields.length < 5) return null;

    final day = int.tryParse(fields[0]);
    if (day == null) return null;
    final month = _monthNumbers[fields[1].toLowerCase()];
    if (month == null) return null;
    final yearField = fields[2];
    final rawYear = int.tryParse(yearField);
    if (rawYear == null) return null;
    final year = yearField.length == 2
        ? rawYear + (rawYear <= 69 ? 2000 : 1900)
        : rawYear;

    final timeFields = fields[3].split(':');
    if (timeFields.length != 3) return null;
    final hour = int.tryParse(timeFields[0]);
    final minute = int.tryParse(timeFields[1]);
    final second = int.tryParse(timeFields[2]);
    if (hour == null || minute == null || second == null) return null;
    if (!_fitsClockRanges(month, day, hour, minute, second)) return null;

    return daysFromCivil(year, month, day) * _secondsPerDay +
        hour * _secondsPerHour +
        minute * _secondsPerMinute +
        second;
  }

  static bool _fitsClockRanges(
    int month,
    int day,
    int hour,
    int minute,
    int second,
  ) =>
      month >= 1 &&
      month <= 12 &&
      day >= 1 &&
      day <= 31 &&
      hour >= 0 &&
      hour <= 23 &&
      minute >= 0 &&
      minute <= 59 &&
      second >= 0 &&
      second <= 60;

  /// Howard Hinnant `days_from_civil`：公历日期自 `1970-01-01` 起的天数。
  static int daysFromCivil(int year, int month, int day) {
    final shiftedYear = month <= 2 ? year - 1 : year;
    final era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) ~/ 400;
    final yearInEra = shiftedYear - era * 400;
    final dayInYear =
        (153 * (month + (month > 2 ? -3 : 9)) + 2) ~/ 5 + day - 1;
    final dayInEra =
        yearInEra * 365 + yearInEra ~/ 4 - yearInEra ~/ 100 + dayInYear;
    return era * 146097 + dayInEra - 719468;
  }
}

class _CookieAttributes {
  String? domain;
  String? path;
  bool secureOnly = false;
  bool httpOnly = false;
  int? expiryEpochSeconds;

  void accept(String segment, int nowEpochSeconds) {
    final separator = segment.indexOf('=');
    final attributeName = (separator < 0
            ? segment
            : segment.substring(0, separator))
        .trim()
        .toLowerCase();
    final literal =
        separator < 0 ? '' : segment.substring(separator + 1).trim();

    switch (attributeName) {
      case 'domain':
        var cleaned = literal.startsWith('.') ? literal.substring(1) : literal;
        cleaned = cleaned.toLowerCase();
        domain = cleaned.isEmpty ? null : cleaned;
      case 'path':
        path = literal.startsWith('/') ? literal : null;
      case 'secure':
        secureOnly = true;
      case 'httponly':
        httpOnly = true;
      case 'max-age':
        final seconds = int.tryParse(literal);
        if (seconds != null) {
          expiryEpochSeconds =
              seconds <= 0 ? nowEpochSeconds - 1 : nowEpochSeconds + seconds;
        }
      case 'expires':
        expiryEpochSeconds ??= SetCookie.parseHttpDate(literal);
    }
  }
}
