import 'dart:convert';

import '../../core/net/set_cookie.dart';

/// Extracts academic session cookies from raw `Cookie:` headers, JSON cookie
/// maps, or browser `.har` packet captures while enforcing institutional
/// domain boundaries (e.g. `.edu.cn` two-label public suffixes).
class CookieHarParser {
  const CookieHarParser._();

  static const Set<String> _twoLabelPublicSuffixes = <String>{
    'edu.cn',
    'ac.cn',
    'gov.cn',
    'org.cn',
    'com.cn',
    'net.cn',
    'mil.cn',
    'edu.hk',
    'org.hk',
    'com.hk',
    'gov.hk',
    'net.hk',
    'edu.mo',
    'gov.mo',
    'org.mo',
    'com.mo',
    'edu.tw',
    'org.tw',
    'com.tw',
    'gov.tw',
    'net.tw',
    'ac.uk',
    'co.uk',
    'org.uk',
    'gov.uk',
    'edu.au',
    'com.au',
    'org.au',
    'gov.au',
    'ac.jp',
    'co.jp',
    'or.jp',
    'go.jp',
    'edu.sg',
    'com.sg',
    'edu.my',
    'com.my',
  };

  static final RegExp _ipv4Literal = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
  static final RegExp _cookiePrefix = RegExp(
    r'^cookie\s*:\s*',
    caseSensitive: false,
  );
  static final RegExp _setCookiePrefix = RegExp(
    r'^set-cookie\s*:\s*',
    caseSensitive: false,
  );

  /// Extracts cookies for [targetBaseUri] from [cookieHeader] and/or [harContent].
  ///
  /// Supported formats:
  /// - Raw header: `Cookie: JSESSIONID=abc; route=1` or `JSESSIONID=abc; route=1`
  /// - JSON object: `{"JSESSIONID": "abc", "route": "1"}`
  /// - Cookie-Editor JSON array: `[{"name": "JSESSIONID", "value": "abc", ...}]`
  /// - HAR 1.2 JSON (`harContent` or `cookieHeader` containing `{"log":{"entries":...}}`):
  ///   collects request cookies (`Cookie` header & `request.cookies`) and
  ///   response cookies (`Set-Cookie` headers & `response.cookies`) matching
  ///   [targetBaseUri]'s host, parent domain, or shared registrable
  ///   institutional domain (such as `sso.qust.edu.cn` <-> `jwglxt.qust.edu.cn`),
  ///   where newest entries win and direct target-host cookies take precedence
  ///   over sibling-subdomain cookies of the same name.
  static Map<String, String> extract({
    String? cookieHeader,
    String? harContent,
    required Uri targetBaseUri,
  }) {
    final targetHost = _normalizeHost(targetBaseUri.host);
    if (targetHost.isEmpty) {
      throw ArgumentError.value(
        targetBaseUri,
        'targetBaseUri',
        'targetBaseUri must include a valid host.',
      );
    }

    final merged = <String, String>{};

    final trimmedHar = harContent?.trim() ?? '';
    if (trimmedHar.isNotEmpty) {
      merged.addAll(_extractFromHarJson(trimmedHar, targetHost));
    }

    final trimmedHeader = cookieHeader?.trim() ?? '';
    if (trimmedHeader.isNotEmpty) {
      merged.addAll(_extractFromCookieInput(trimmedHeader, targetHost));
    }

    return Map<String, String>.unmodifiable(merged);
  }

  /// Computes the registrable institutional root domain of [rawHost]
  /// (e.g. `jwglxt.qust.edu.cn` -> `qust.edu.cn`), returning `null` for
  /// `localhost`, IP literals, or bare public suffixes like `edu.cn`.
  static String? registrableInstitutionalDomain(String rawHost) {
    final host = _normalizeHost(rawHost);
    if (host.isEmpty ||
        host == 'localhost' ||
        host.contains(':') ||
        host.startsWith('[') ||
        _ipv4Literal.hasMatch(host)) {
      return null;
    }

    final labels = host.split('.');
    if (labels.length < 2 || labels.any((l) => l.isEmpty)) {
      return null;
    }

    final lastTwo = '${labels[labels.length - 2]}.${labels.last}';
    if (_twoLabelPublicSuffixes.contains(lastTwo)) {
      if (labels.length < 3) return null;
      return '${labels[labels.length - 3]}.$lastTwo';
    }
    return lastTwo;
  }

  static Map<String, String> _extractFromCookieInput(
    String input,
    String targetHost,
  ) {
    if (input.startsWith('{') || input.startsWith('[')) {
      final Object? decoded;
      try {
        decoded = jsonDecode(input);
      } on FormatException catch (e) {
        throw FormatException('Invalid JSON cookie payload: ${e.message}');
      }
      if (decoded is Map<Object?, Object?>) {
        if (decoded.containsKey('log') && decoded['log'] is Map<Object?, Object?>) {
          return _extractFromDecodedHar(decoded, targetHost);
        }
        final out = <String, String>{};
        for (final entry in decoded.entries) {
          final key = entry.key;
          final value = entry.value;
          if (key is! String || value == null) {
            throw const FormatException(
              'JSON cookie object must map string cookie names to string values.',
            );
          }
          if (value is! String) {
            throw FormatException(
              'Cookie "$key" in JSON object must have a string value.',
            );
          }
          final name = key.trim();
          if (_isValidCookieName(name)) {
            out[name] = _unquote(value.trim());
          }
        }
        return out;
      }
      if (decoded is List<Object?>) {
        return _extractFromCookieObjectList(decoded, targetHost);
      }
      throw const FormatException('Unsupported JSON cookie structure.');
    }

    final out = <String, String>{};
    final lines = input
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty);

    for (final line in lines) {
      if (_setCookiePrefix.hasMatch(line)) {
        final rawSetCookie = line.replaceFirst(_setCookiePrefix, '').trim();
        final parsed = _parseSetCookieHeader(rawSetCookie, targetHost);
        if (parsed != null &&
            _isDomainAccepted(parsed.domain, targetHost)) {
          if (parsed.isDeleted) {
            out.remove(parsed.name);
          } else {
            out[parsed.name] = parsed.value;
          }
        }
        continue;
      }

      final stripped = line.replaceFirst(_cookiePrefix, '').trim();
      _parseCookiePairString(stripped, out);
    }
    return out;
  }

  static Map<String, String> _extractFromCookieObjectList(
    List<Object?> list,
    String targetHost,
  ) {
    final buckets = _TieredCookieCollector(targetHost);
    for (final item in list) {
      if (item is! Map<Object?, Object?>) continue;
      _absorbCookieObject(
        item,
        fallbackHost: targetHost,
        targetHost: targetHost,
        collector: buckets,
        enforceOriginDomainMatch: false,
      );
    }
    return buckets.build();
  }

  static Map<String, String> _extractFromHarJson(
    String harContent,
    String targetHost,
  ) {
    final Object? decoded;
    try {
      decoded = jsonDecode(harContent);
    } on FormatException catch (e) {
      throw FormatException('Invalid HAR JSON: ${e.message}');
    }
    if (decoded is! Map<Object?, Object?>) {
      throw const FormatException('Invalid HAR payload: root must be an object.');
    }
    return _extractFromDecodedHar(decoded, targetHost);
  }

  static Map<String, String> _extractFromDecodedHar(
    Map<Object?, Object?> root,
    String targetHost,
  ) {
    final log = root['log'];
    if (log is! Map<Object?, Object?>) {
      throw const FormatException('Invalid HAR payload: missing "log" object.');
    }
    final rawEntries = log['entries'];
    if (rawEntries is! List<Object?>) {
      throw const FormatException(
        'Invalid HAR payload: "log.entries" must be an array.',
      );
    }

    final indexedEntries = <_IndexedHarEntry>[];
    for (var i = 0; i < rawEntries.length; i++) {
      final item = rawEntries[i];
      if (item is! Map<Object?, Object?>) continue;
      DateTime? startedAt;
      final rawStarted = item['startedDateTime'];
      if (rawStarted is String && rawStarted.trim().isNotEmpty) {
        startedAt = DateTime.tryParse(rawStarted.trim())?.toUtc();
      }
      indexedEntries.add(_IndexedHarEntry(index: i, startedAt: startedAt, map: item));
    }

    // Sort chronologically when startedDateTime is present on both entries;
    // otherwise preserve capture order so later entries always win ("newest wins").
    indexedEntries.sort((a, b) {
      if (a.startedAt != null && b.startedAt != null) {
        final cmp = a.startedAt!.compareTo(b.startedAt!);
        if (cmp != 0) return cmp;
      }
      return a.index.compareTo(b.index);
    });

    final collector = _TieredCookieCollector(targetHost);

    for (final entry in indexedEntries) {
      final request = entry.map['request'];
      if (request is! Map<Object?, Object?>) continue;
      final rawUrl = request['url'];
      if (rawUrl is! String || rawUrl.trim().isEmpty) continue;
      final entryUri = Uri.tryParse(rawUrl.trim());
      if (entryUri == null || entryUri.host.isEmpty) continue;

      final entryHost = _normalizeHost(entryUri.host);
      if (!_isDomainAccepted(entryHost, targetHost)) {
        continue;
      }

      // 1. Request headers (Cookie) & request.cookies
      final reqHeaders = request['headers'];
      if (reqHeaders is List<Object?>) {
        for (final header in reqHeaders) {
          if (header is! Map<Object?, Object?>) continue;
          final hName = header['name'];
          final hValue = header['value'];
          if (hName is String &&
              hValue is String &&
              hName.trim().toLowerCase() == 'cookie') {
            final pairs = <String, String>{};
            _parseCookiePairString(hValue, pairs);
            for (final kv in pairs.entries) {
              collector.put(
                name: kv.key,
                value: kv.value,
                effectiveDomain: entryHost,
              );
            }
          }
        }
      }

      final reqCookies = request['cookies'];
      if (reqCookies is List<Object?>) {
        for (final c in reqCookies) {
          if (c is Map<Object?, Object?>) {
            _absorbCookieObject(
              c,
              fallbackHost: entryHost,
              targetHost: targetHost,
              collector: collector,
            );
          }
        }
      }

      // 2. Response headers (Set-Cookie) & response.cookies (newer than request)
      final response = entry.map['response'];
      if (response is! Map<Object?, Object?>) continue;

      final resHeaders = response['headers'];
      if (resHeaders is List<Object?>) {
        for (final header in resHeaders) {
          if (header is! Map<Object?, Object?>) continue;
          final hName = header['name'];
          final hValue = header['value'];
          if (hName is String &&
              hValue is String &&
              hName.trim().toLowerCase() == 'set-cookie') {
            for (final line in hValue.split(RegExp(r'\r?\n'))) {
              final trimmed = line.trim();
              if (trimmed.isEmpty) continue;
              final parsed = _parseSetCookieHeader(trimmed, entryHost);
              if (parsed == null) continue;
              if (!_isDomainAccepted(parsed.domain, targetHost)) continue;
              if (parsed.isDeleted) {
                collector.delete(
                  name: parsed.name,
                  effectiveDomain: parsed.domain,
                );
              } else {
                collector.put(
                  name: parsed.name,
                  value: parsed.value,
                  effectiveDomain: parsed.domain,
                );
              }
            }
          }
        }
      }

      final resCookies = response['cookies'];
      if (resCookies is List<Object?>) {
        for (final c in resCookies) {
          if (c is Map<Object?, Object?>) {
            _absorbCookieObject(
              c,
              fallbackHost: entryHost,
              targetHost: targetHost,
              collector: collector,
              checkDeletion: true,
            );
          }
        }
      }
    }

    return collector.build();
  }

  static void _absorbCookieObject(
    Map<Object?, Object?> item, {
    required String fallbackHost,
    required String targetHost,
    required _TieredCookieCollector collector,
    bool checkDeletion = false,
    bool enforceOriginDomainMatch = true,
  }) {
    final rawName = item['name'];
    final rawValue = item['value'];
    if (rawName is! String || rawValue is! String) return;
    final name = rawName.trim();
    if (!_isValidCookieName(name)) return;

    final rawDomain = item['domain'];
    final cleanDomain = rawDomain is String && rawDomain.trim().isNotEmpty
        ? _normalizeDomainAttribute(rawDomain)
        : fallbackHost;
    if (cleanDomain.isEmpty) return;

    // RFC 6265 domain check relative to the entry host when coming from an HTTP entry.
    if (enforceOriginDomainMatch &&
        cleanDomain != fallbackHost &&
        !SetCookie.domainMatch(fallbackHost, cleanDomain)) {
      return;
    }
    if (!_isDomainAccepted(cleanDomain, targetHost)) return;

    final value = _unquote(rawValue.trim());
    if (checkDeletion && _isCookieObjectDeleted(item, value)) {
      collector.delete(name: name, effectiveDomain: cleanDomain);
      return;
    }
    collector.put(name: name, value: value, effectiveDomain: cleanDomain);
  }

  static bool _isCookieObjectDeleted(Map<Object?, Object?> item, String value) {
    if (value.isEmpty || value.toLowerCase() == 'deleteme') return true;
    final rawMaxAge = item['maxAge'];
    if (rawMaxAge is num && rawMaxAge <= 0) return true;
    if (rawMaxAge is String) {
      final parsed = int.tryParse(rawMaxAge.trim());
      if (parsed != null && parsed <= 0) return true;
    }
    final rawExpires = item['expires'];
    if (rawExpires is String && rawExpires.trim().isNotEmpty) {
      final parsedIso = DateTime.tryParse(rawExpires.trim());
      if (parsedIso != null && parsedIso.millisecondsSinceEpoch <= 0) {
        return true;
      }
      final parsedHttp = SetCookie.parseHttpDate(rawExpires.trim());
      if (parsedHttp != null && parsedHttp <= 0) {
        return true;
      }
    }
    return false;
  }

  static _ParsedSetCookie? _parseSetCookieHeader(
    String rawHeader,
    String requestHost,
  ) {
    final semicolon = rawHeader.indexOf(';');
    final head = semicolon < 0 ? rawHeader : rawHeader.substring(0, semicolon);
    final eq = head.indexOf('=');
    if (eq <= 0) return null;

    final name = head.substring(0, eq).trim();
    if (!_isValidCookieName(name)) return null;
    final value = _unquote(head.substring(eq + 1).trim());

    String? domainAttr;
    int? maxAge;
    int? expiresEpoch;

    if (semicolon >= 0) {
      final attrs = rawHeader.substring(semicolon + 1).split(';');
      for (final segment in attrs) {
        final attrEq = segment.indexOf('=');
        final attrName =
            (attrEq < 0 ? segment : segment.substring(0, attrEq))
                .trim()
                .toLowerCase();
        final attrVal =
            attrEq < 0 ? '' : segment.substring(attrEq + 1).trim();
        switch (attrName) {
          case 'domain':
            final normalized = _normalizeDomainAttribute(attrVal);
            if (normalized.isNotEmpty) {
              domainAttr = normalized;
            }
          case 'max-age':
            maxAge = int.tryParse(attrVal);
          case 'expires':
            expiresEpoch = SetCookie.parseHttpDate(attrVal);
        }
      }
    }

    final effectiveDomain = domainAttr ?? requestHost;
    if (domainAttr != null &&
        !SetCookie.domainMatch(requestHost, effectiveDomain)) {
      return null;
    }

    final isDeleted = value.isEmpty ||
        value.toLowerCase() == 'deleteme' ||
        (maxAge != null && maxAge <= 0) ||
        (expiresEpoch != null && expiresEpoch <= 0);

    return _ParsedSetCookie(
      name: name,
      value: value,
      domain: effectiveDomain,
      isDeleted: isDeleted,
    );
  }

  static void _parseCookiePairString(String raw, Map<String, String> target) {
    for (final segment in raw.split(';')) {
      final trimmed = segment.trim();
      if (trimmed.isEmpty) continue;
      final eq = trimmed.indexOf('=');
      if (eq <= 0) continue;
      final name = trimmed.substring(0, eq).trim();
      if (!_isValidCookieName(name)) continue;
      final value = _unquote(trimmed.substring(eq + 1).trim());
      target[name] = value;
    }
  }

  /// Returns true if [candidateHostOrDomain] is [targetHost], a parent domain
  /// of [targetHost], a subdomain of [targetHost], or shares the same
  /// registrable institutional root domain (e.g. `*.qust.edu.cn`).
  static bool _isDomainAccepted(
    String candidateHostOrDomain,
    String targetHost,
  ) {
    final candidate = _normalizeDomainAttribute(candidateHostOrDomain);
    if (candidate.isEmpty) return false;
    if (candidate == targetHost) return true;

    final targetRoot = registrableInstitutionalDomain(targetHost);
    final candidateRoot = registrableInstitutionalDomain(candidate);
    if (targetRoot != null && candidateRoot != null) {
      return targetRoot == candidateRoot;
    }

    // For single-label or non-PSL intranet hosts without a registrable root,
    // only allow exact match (IPs/localhost never wildcard).
    return false;
  }

  static bool _isValidCookieName(String name) =>
      name.isNotEmpty && !name.startsWith(r'$');

  static String _normalizeHost(String raw) {
    var host = raw.trim().toLowerCase();
    while (host.endsWith('.')) {
      host = host.substring(0, host.length - 1);
    }
    return host;
  }

  static String _normalizeDomainAttribute(String raw) {
    var domain = _normalizeHost(raw);
    while (domain.startsWith('.')) {
      domain = domain.substring(1);
    }
    return domain;
  }

  static String _unquote(String raw) {
    if (raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')) {
      return raw.substring(1, raw.length - 1);
    }
    return raw;
  }
}

class _IndexedHarEntry {
  const _IndexedHarEntry({
    required this.index,
    required this.startedAt,
    required this.map,
  });

  final int index;
  final DateTime? startedAt;
  final Map<Object?, Object?> map;
}

class _ParsedSetCookie {
  const _ParsedSetCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.isDeleted,
  });

  final String name;
  final String value;
  final String domain;
  final bool isDeleted;
}

/// Separates cookies directly applicable to [targetHost] (exact host or parent
/// domain like `.qust.edu.cn`) from sibling-subdomain cookies (like
/// `sso.qust.edu.cn`) so a sibling host's `JSESSIONID` cannot clobber the
/// academic server's own `JSESSIONID` while SSO cookies (`CASTGC`, etc.) are
/// still preserved with newest-wins semantics.
class _TieredCookieCollector {
  _TieredCookieCollector(this.targetHost);

  final String targetHost;
  final Map<String, String> _direct = <String, String>{};
  final Map<String, String> _sibling = <String, String>{};

  bool _isDirectForTarget(String effectiveDomain) =>
      SetCookie.domainMatch(targetHost, effectiveDomain);

  void put({
    required String name,
    required String value,
    required String effectiveDomain,
  }) {
    if (_isDirectForTarget(effectiveDomain)) {
      _direct[name] = value;
    } else {
      _sibling[name] = value;
    }
  }

  void delete({
    required String name,
    required String effectiveDomain,
  }) {
    if (_isDirectForTarget(effectiveDomain)) {
      _direct.remove(name);
    } else {
      _sibling.remove(name);
    }
  }

  Map<String, String> build() => <String, String>{
        ..._sibling,
        ..._direct,
      };
}
