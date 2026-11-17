import 'dart:convert';
import 'dart:typed_data';

import 'package:courselens/core/courselens_core.dart';
import 'package:test/test.dart';

class _StubEngine implements HttpEngine {
  _StubEngine(this._handler);
  final Future<HttpResponse> Function(HttpRequest) _handler;

  @override
  Future<HttpResponse> execute(HttpRequest request) => _handler(request);
}

void main() {
  group('Urls & HostPolicy (5 security rules)', () {
    const hosts = ['jw.example.edu.cn', 'https://cas.example.edu.cn:8443'];

    test('enforces scheme, userinfo, HTTPS requirement, port, and exact host', () {
      expect(
        HostPolicy.isAllowed('https://jw.example.edu.cn/login', hosts, true),
        isTrue,
      );
      // Rule 1: non-http(s) rejected
      expect(
        HostPolicy.isAllowed('javascript:alert(1)', hosts, false),
        isFalse,
      );
      // Rule 2: userinfo phishing rejected
      expect(
        HostPolicy.isAllowed(
          'https://jw.example.edu.cn@evil.example.com/',
          hosts,
          true,
        ),
        isFalse,
      );
      // Rule 3: HTTP downgrade rejected when requireSecure = true
      expect(
        HostPolicy.isAllowed('http://jw.example.edu.cn/login', hosts, true),
        isFalse,
      );
      expect(
        HostPolicy.isAllowed('http://jw.example.edu.cn/login', hosts, false),
        isTrue,
      );
      // Rule 4: port mismatch rejected
      expect(
        HostPolicy.isAllowed('https://cas.example.edu.cn/cas', hosts, true),
        isFalse,
      );
      expect(
        HostPolicy.isAllowed(
          'https://cas.example.edu.cn:8443/cas',
          hosts,
          true,
        ),
        isTrue,
      );
      // Rule 5: subdomain wildcard rejected
      expect(
        HostPolicy.isAllowed(
          'https://sub.jw.example.edu.cn/login',
          hosts,
          true,
        ),
        isFalse,
      );
    });

    test('Urls resolves relative paths and dot-segments cleanly', () {
      expect(
        Urls.resolve(
          'https://jw.example.edu.cn/jwglxt/xtgl/login_slogin.html',
          '../kbcx/xskbcx.html',
        ),
        equals('https://jw.example.edu.cn/jwglxt/kbcx/xskbcx.html'),
      );
    });
  });

  group('TransportSecurity & HostGuardedHttpEngine', () {
    test('GuardedHttpEngine blocks plaintext HTTP when requireSecure is true', () async {
      final guarded = GuardedHttpEngine(
        _StubEngine(
          (req) async => HttpResponse(
            status: 200,
            headers: const {},
            body: Uint8List(0),
            finalUrl: req.url,
          ),
        ),
        requireSecure: true,
      );
      await expectLater(
        guarded.execute(
          HttpRequest(
            method: HttpMethod.get,
            url: 'http://jw.example.edu.cn/',
          ),
        ),
        throwsA(
          isA<AcademicException>().having(
            (e) => e.status,
            'status',
            AcademicStatus.INSECURE_TRANSPORT,
          ),
        ),
      );
    });

    test('HostGuardedHttpEngine rejects off-whitelist request and blocked redirect', () async {
      final engine = HostGuardedHttpEngine(
        _StubEngine(
          (req) async => HttpResponse(
            status: 302,
            headers: const {
              HostGuardedHttpEngine.blockedRedirectHeader: [
                'https://evil.example.com/steal',
              ],
            },
            body: Uint8List(0),
            finalUrl: req.url,
          ),
        ),
        allowedHosts: const ['jw.example.edu.cn'],
        requireSecure: true,
      );

      await expectLater(
        engine.execute(
          HttpRequest(
            method: HttpMethod.get,
            url: 'https://other.example.edu.cn/',
          ),
        ),
        throwsA(
          isA<AcademicException>().having(
            (e) => e.status,
            'status',
            AcademicStatus.UNTRUSTED_URL,
          ),
        ),
      );

      await expectLater(
        engine.execute(
          HttpRequest(
            method: HttpMethod.get,
            url: 'https://jw.example.edu.cn/start',
          ),
        ),
        throwsA(
          isA<AcademicException>().having(
            (e) => e.status,
            'status',
            AcademicStatus.UNTRUSTED_URL,
          ),
        ),
      );
    });
  });

  group('SetCookie, CookieJar & retire() write-seal', () {
    test('enforces domain/path boundaries, expiry, and retire() seal', () async {
      var now = 1000;
      final jar = CookieJar(clock: () => now);
      final source = Urls.parseUrl('https://jw.example.edu.cn/jwglxt/xtgl/a')!;

      await jar.saveFromResponse(source, const [
        'JSESSIONID=abc123; Path=/jwglxt; Secure; HttpOnly',
        'TEMP=1; Path=/jwglxt; Max-Age=10',
      ]);

      expect(
        await jar.cookieHeaderFor('https://jw.example.edu.cn/jwglxt/kbcx'),
        equals('JSESSIONID=abc123; TEMP=1'),
      );
      // Path boundary check: /jwglxt2 must NOT match /jwglxt
      expect(
        await jar.cookieHeaderFor('https://jw.example.edu.cn/jwglxt2/kbcx'),
        isEmpty,
      );
      // Domain boundary check: eviljw.example.edu.cn must NOT match
      expect(
        await jar.cookieHeaderFor('https://eviljw.example.edu.cn/jwglxt/kbcx'),
        isEmpty,
      );
      // Secure flag check: http must NOT receive Secure cookie
      expect(
        await jar.cookieHeaderFor('http://jw.example.edu.cn/jwglxt/kbcx'),
        equals('TEMP=1'),
      );

      // Advance clock past Max-Age=10
      now = 1015;
      expect(
        await jar.cookieHeaderFor('https://jw.example.edu.cn/jwglxt/kbcx'),
        equals('JSESSIONID=abc123'),
      );

      // Hard Rule 5: retire() permanently seals CookieJar against late writes
      await jar.retire();
      expect(await jar.cookieHeaderFor('https://jw.example.edu.cn/jwglxt/kbcx'), isEmpty);
      await jar.saveFromResponse(source, const ['JSESSIONID=late_leak; Path=/']);
      expect(await jar.snapshot(), isEmpty);
    });

    test('coexists dual JSESSIONID across / and /jwglxt and sorts longer path first (RFC 6265 §5.4)', () async {
      var now = 1763180000;
      final jar = CookieJar(clock: () => now);
      final rootUrl = Urls.parseUrl('https://jwglxt.qust.edu.cn/')!;
      final loginUrl = Urls.parseUrl(
        'https://jwglxt.qust.edu.cn/jwglxt/xtgl/login_slogin.html',
      )!;
      final scheduleUrl = Urls.parseUrl(
        'https://jwglxt.qust.edu.cn/jwglxt/kbcx/xskbcx_cxXsgrkb.html',
      )!;

      // Step 1: Root / sets sticky route + unauthenticated root JSESSIONID
      await jar.saveFromResponse(rootUrl, const [
        'route=sticky01; Path=/',
        'JSESSIONID=root_unauth; Path=/; HttpOnly',
      ]);

      // Step 2: /jwglxt sets servlet-context JSESSIONID
      await jar.saveFromResponse(loginUrl, const [
        'JSESSIONID=jw_prelogin; Path=/jwglxt; HttpOnly',
      ]);

      expect(await jar.size(), equals(3));
      expect(
        await jar.cookieHeaderForParsedUrl(loginUrl),
        equals('JSESSIONID=jw_prelogin; route=sticky01; JSESSIONID=root_unauth'),
      );

      // Step 3: Login rotates ONLY Path=/jwglxt JSESSIONID
      now += 2;
      await jar.saveFromResponse(loginUrl, const [
        'JSESSIONID=jw_authenticated; Path=/jwglxt; HttpOnly',
      ]);

      expect(await jar.size(), equals(3));
      expect(
        await jar.cookieHeaderForParsedUrl(scheduleUrl),
        equals(
          'JSESSIONID=jw_authenticated; route=sticky01; JSESSIONID=root_unauth',
        ),
      );
      expect(
        await jar.cookieHeaderForParsedUrl(rootUrl),
        equals('route=sticky01; JSESSIONID=root_unauth'),
      );

      final loaded = await jar.loadForParsedUrl(scheduleUrl);
      expect(
        loaded.map((c) => '${c.path}:${c.name}=${c.value}').toList(),
        equals(const <String>[
          '/jwglxt:JSESSIONID=jw_authenticated',
          '/:route=sticky01',
          '/:JSESSIONID=root_unauth',
        ]),
      );
    });

    test('deletes matching (domain, path, name) on Max-Age<=0, expired Expires, and deleteMe', () async {
      const now = 1763180000;
      final jar = CookieJar(clock: () => now);
      final rootUrl = Urls.parseUrl('https://jwglxt.qust.edu.cn/')!;
      final jwUrl = Urls.parseUrl(
        'https://jwglxt.qust.edu.cn/jwglxt/xtgl/login_slogin.html',
      )!;

      await jar.saveFromResponse(rootUrl, const [
        'JSESSIONID=root_keep; Path=/; HttpOnly',
      ]);
      await jar.saveFromResponse(jwUrl, const [
        'JSESSIONID=jw_temp; Path=/jwglxt; HttpOnly',
        'rememberMe=token_abc; Path=/jwglxt; HttpOnly',
        'NEGATIVE=1; Path=/jwglxt',
        'EXPIRED_DATE=1; Path=/jwglxt',
      ]);
      expect(await jar.size(), equals(5));

      await jar.saveFromResponse(jwUrl, const [
        'rememberMe=deleteMe; Path=/jwglxt; HttpOnly',
        'NEGATIVE=gone; Path=/jwglxt; Max-Age=-10',
        'EXPIRED_DATE=gone; Path=/jwglxt; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
        'JSESSIONID=gone; Path=/jwglxt; Max-Age=0',
      ]);

      // Only Path=/ JSESSIONID survives; Path=/jwglxt cookies were cleanly deleted
      expect(await jar.size(), equals(1));
      expect(
        await jar.cookieHeaderForParsedUrl(jwUrl),
        equals('JSESSIONID=root_keep'),
      );
    });

    test('PageCharset detects header charset and HTML meta GBK', () {
      expect(
        PageCharset.detect('text/html; charset=GBK', Uint8List(0)),
        equals('gbk'),
      );
      final htmlBytes = Uint8List.fromList(
        ascii.encode('<html><head><meta charset="gb2312"></head></html>'),
      );
      expect(PageCharset.detect('text/html', htmlBytes), equals('gbk'));
    });

    test('SetCookie rejects public-suffix supercookies and control chars; HostPolicy blocks explicit https downgrade', () async {
      final reqUrl = Urls.parseUrl('https://jwglxt.qust.edu.cn/jwglxt/login')!;
      expect(
        SetCookie.parse('SUPER=1; Domain=edu.cn; Path=/', reqUrl, 1763180000),
        isNull,
      );
      expect(
        SetCookie.parse('BAD=val\r\nevil; Path=/', reqUrl, 1763180000),
        isNull,
      );
      final validSub = SetCookie.parse(
        'SSO=ok; Domain=qust.edu.cn; Path=/',
        reqUrl,
        1763180000,
      );
      expect(validSub, isNotNull);
      expect(validSub!.domain, equals('qust.edu.cn'));

      expect(
        HostPolicy.isAllowed(
          'http://cas.example.edu.cn:443/cas',
          const ['https://cas.example.edu.cn'],
          false,
        ),
        isFalse,
      );
      expect(
        HostPolicy.isAllowed(
          'https://any.example.com/',
          const ['*'],
          false,
        ),
        isFalse,
      );
    });
  });
}
