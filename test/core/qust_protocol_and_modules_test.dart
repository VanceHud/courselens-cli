import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:courselens/core/courselens_core.dart';
import 'package:test/test.dart';

class _Utf8Decoder implements TextDecoder {
  const _Utf8Decoder();

  @override
  String decode(Uint8List bytes, String charset) =>
      utf8.decode(bytes, allowMalformed: true);
}

class _FixedRandom implements SecureRandom {
  const _FixedRandom();

  @override
  Uint8List bytes(int length) =>
      Uint8List.fromList(List<int>.filled(length, 0x42));
}

typedef _RouteHandler = HttpResponse Function(HttpRequest request);

class _MockQustEngine implements HttpEngine {
  _MockQustEngine(this._handler);

  final _RouteHandler _handler;
  final List<HttpRequest> recorded = <HttpRequest>[];

  @override
  Future<HttpResponse> execute(HttpRequest request) async {
    recorded.add(request);
    return _handler(request);
  }
}

HttpResponse _htmlResponse(
  String url,
  String body, {
  int status = 200,
  String? finalUrl,
  List<String> setCookies = const <String>[],
}) =>
    HttpResponse(
      status: status,
      headers: <String, List<String>>{
        'Content-Type': const <String>['text/html; charset=utf-8'],
        if (setCookies.isNotEmpty) 'Set-Cookie': setCookies,
      },
      body: Uint8List.fromList(utf8.encode(body)),
      finalUrl: finalUrl ?? url,
    );

HttpResponse _jsonResponse(
  String url,
  String body, {
  int status = 200,
  List<String> setCookies = const <String>[],
}) =>
    HttpResponse(
      status: status,
      headers: <String, List<String>>{
        'Content-Type': const <String>['application/json; charset=utf-8'],
        if (setCookies.isNotEmpty) 'Set-Cookie': setCookies,
      },
      body: Uint8List.fromList(utf8.encode(body)),
      finalUrl: url,
    );

String _fixture(String name) =>
    File('test/fixtures/academic/$name').readAsStringSync();

Map<String, String> _formBodyMap(HttpRequest req) {
  final raw = req.body == null ? '' : utf8.decode(req.body!);
  final out = <String, String>{};
  for (final pair in raw.split('&')) {
    if (pair.isEmpty) continue;
    final idx = pair.indexOf('=');
    if (idx < 0) {
      out[Uri.decodeQueryComponent(pair)] = '';
    } else {
      out[Uri.decodeQueryComponent(pair.substring(0, idx))] =
          Uri.decodeQueryComponent(pair.substring(idx + 1));
    }
  }
  return out;
}

/// 2026-11-15T12:00:00Z epoch seconds
const int _qustReconEpoch = 1794744000;

void main() {
  group('1. QUST Context Path Discovery, Login Flow, Dynamic CAPTCHA & Session Expiry', () {
    test('StudyProbe discovers /jwglxt from bare root meta-refresh and 302 redirect', () async {
      final metaEngine = _MockQustEngine((req) {
        if (req.url == 'https://jwglxt.qust.edu.cn' ||
            req.url == 'https://jwglxt.qust.edu.cn/') {
          return _htmlResponse(req.url, _fixture('qust-root-meta-refresh.html'));
        }
        if (req.url == 'https://jwglxt.qust.edu.cn/jwglxt' ||
            req.url == 'https://jwglxt.qust.edu.cn/jwglxt/') {
          return _htmlResponse(
            req.url,
            _fixture('qust-login-jwglxt.html'),
            finalUrl: 'https://jwglxt.qust.edu.cn/jwglxt/xtgl/login_slogin.html',
          );
        }
        return _htmlResponse(req.url, 'Not Found', status: 404);
      });

      final client = AcademicClient(
        engine: metaEngine,
        decoder: const _Utf8Decoder(),
        secureStore: InMemorySecureStore(),
        clock: () => _qustReconEpoch,
        random: const _FixedRandom(),
      );

      final probe = await client.probeStudySystem(
        schoolId: 'qust',
        academicBaseUrl: 'https://jwglxt.qust.edu.cn/',
      );
      expect(probe, isNotNull);
      expect(probe!.systemId, equals('zf'));
      expect(probe.basePath, equals('/jwglxt'));

      final redirectEngine = _MockQustEngine((req) {
        return _htmlResponse(
          req.url,
          _fixture('qust-login-jwglxt.html'),
          finalUrl: 'https://jwglxt.qust.edu.cn/jwglxt/xtgl/login_slogin.html',
        );
      });
      final redirectClient = AcademicClient(
        engine: redirectEngine,
        decoder: const _Utf8Decoder(),
        secureStore: InMemorySecureStore(),
        clock: () => _qustReconEpoch,
        random: const _FixedRandom(),
      );
      final probe302 = await redirectClient.probeStudySystem(
        schoolId: 'qust',
        academicBaseUrl: 'https://jwglxt.qust.edu.cn',
      );
      expect(probe302?.basePath, equals('/jwglxt'));
    });

    test('loginJwglxt resolves bare root, calls getPublicKey ONCE, sends Chrome headers, and enriches identity + calendar', () async {
      var publicKeyCalls = 0;
      final engine = _MockQustEngine((req) {
        final uri = Uri.parse(req.url);
        if (uri.path == '' || uri.path == '/') {
          return _htmlResponse(
            req.url,
            _fixture('qust-root-meta-refresh.html'),
            setCookies: const <String>[
              'route=lb1; Path=/',
              'JSESSIONID=ROOT_UNAUTH; Path=/; HttpOnly',
            ],
          );
        }
        if (uri.path == '/jwglxt/xtgl/login_slogin.html' &&
            req.method == HttpMethod.get) {
          return _htmlResponse(
            req.url,
            _fixture('qust-login-jwglxt.html'),
            setCookies: const <String>[
              'JSESSIONID=JW_PRELOGIN; Path=/jwglxt; HttpOnly',
            ],
          );
        }
        if (uri.path == '/jwglxt/xtgl/login_getPublicKey.html') {
          publicKeyCalls++;
          return _jsonResponse(
            req.url,
            _fixture('qust-publickey.json'),
            setCookies: const <String>[
              'PUBKEY_MARK=ok; Path=/jwglxt',
            ],
          );
        }
        if (uri.path == '/jwglxt/xtgl/login_slogin.html' &&
            req.method == HttpMethod.post) {
          expect(req.headers['Origin'], equals('https://jwglxt.qust.edu.cn'));
          expect(
            req.headers['Referer'],
            startsWith('https://jwglxt.qust.edu.cn/jwglxt/xtgl/login_slogin.html'),
          );
          expect(req.headers['User-Agent'], contains('Chrome/131.0.0.0'));
          return _htmlResponse(
            req.url,
            _fixture('qust-init-menu-v9.html'),
            status: 302,
            finalUrl: 'https://jwglxt.qust.edu.cn/jwglxt/xtgl/index_initMenu.html',
            setCookies: const <String>[
              'JSESSIONID=JW_AUTHED; Path=/jwglxt; HttpOnly',
            ],
          );
        }
        if (uri.path == '/jwglxt/xtgl/index_initMenu.html') {
          return _htmlResponse(req.url, _fixture('qust-init-menu-v9.html'));
        }
        if (uri.path == '/jwglxt/xtgl/index_cxYhxxIndex.html') {
          return _htmlResponse(req.url, _fixture('qust-user-card.html'));
        }
        return _htmlResponse(req.url, 'Not Found: ${req.url}', status: 404);
      });

      final client = AcademicClient(
        engine: engine,
        decoder: const _Utf8Decoder(),
        secureStore: InMemorySecureStore(),
        clock: () => _qustReconEpoch,
        random: const _FixedRandom(),
      );

      final result = await client.loginJwglxt(
        schoolId: 'qust',
        accountKey: '2428050113',
        username: '2428050113',
        password: 'test-password',
        academicBaseUrl: 'https://jwglxt.qust.edu.cn/',
      );

      expect(result.status, equals(AcademicStatus.SUCCESS));
      expect(publicKeyCalls, equals(1));
      expect(
        await client.activeSessionBaseUrl('qust', '2428050113'),
        equals('https://jwglxt.qust.edu.cn/jwglxt'),
      );
      expect(result.identity.studentId, equals('2428050113'));
      expect(result.identity.name, equals('测试同学'));
      expect(result.identity.department, equals('生物工程学院'));
      expect(result.identity.className, equals('合生241'));
      expect(result.identity.grade, equals('2024'));

      final catalog = await client.loadStudyCatalog(
        schoolId: 'qust',
        accountKey: '2428050113',
        systemId: 'zf',
        username: '2428050113',
      );
      expect(catalog.currentTerm.id, equals('2026-2027-1'));
      expect(catalog.currentWeek, equals(11));
      expect(catalog.serverDate, equals('2026-11-15'));
      expect(
        catalog.semesterStart,
        equals(SemesterStart(2026, 8, 31)),
      );
      expect(catalog.totalWeeks, equals(20));
      expect(
        catalog.terms.map((t) => t.id).toList(),
        equals(const <String>[
          '2026-2027-1',
          '2025-2026-2',
          '2025-2026-1',
          '2024-2025-2',
          '2024-2025-1',
        ]),
      );
    });

    test('dynamic #yzmDiv CAPTCHA detection & submit-time CAPTCHA_REQUIRED loads challenge image', () async {
      // 1) Initial visible #yzmDiv even when dlsfbxyzm=0
      const visibleYzmLogin = '''
      <html><body>
        <input type="hidden" id="mmsfjm" value="1">
        <input type="hidden" id="dlsfbxyzm" value="0">
        <form action="/jwglxt/xtgl/login_slogin.html" method="post">
          <input type="hidden" id="csrftoken" name="csrftoken" value="t1,t2">
          <input type="text" name="yhm">
          <input type="password" name="mm">
          <div id="yzmDiv"><input type="text" name="yzm"><img id="yzmPic" src="/jwglxt/kaptcha"></div>
        </form>
      </body></html>
      ''';
      final parsedVisible = ZhengfangJwglxtProtocol.parseLoginPage(visibleYzmLogin);
      expect(parsedVisible.captchaRequired, isTrue);

      // Hidden #yzmDiv must NOT trigger captchaRequired when dlsfbxyzm=0
      const hiddenYzmLogin = '''
      <html><body>
        <input type="hidden" id="dlsfbxyzm" value="0">
        <form action="/jwglxt/xtgl/login_slogin.html" method="post">
          <input type="hidden" id="csrftoken" name="csrftoken" value="t1,t2">
          <div id="yzmDiv" style="display:none"><input type="text" name="yzm"></div>
        </form>
      </body></html>
      ''';
      expect(
        ZhengfangJwglxtProtocol.parseLoginPage(hiddenYzmLogin).captchaRequired,
        isFalse,
      );

      // 2) Submit returns CAPTCHA_REQUIRED -> flow fetches /kaptcha and populates LoginResult.captcha
      var kaptchaFetched = 0;
      final engine = _MockQustEngine((req) {
        final uri = Uri.parse(req.url);
        if (uri.path == '/jwglxt/xtgl/login_slogin.html' &&
            req.method == HttpMethod.get) {
          return _htmlResponse(req.url, _fixture('qust-login-jwglxt.html'));
        }
        if (uri.path == '/jwglxt/xtgl/login_getPublicKey.html') {
          return _jsonResponse(req.url, _fixture('qust-publickey.json'));
        }
        if (uri.path == '/jwglxt/xtgl/login_slogin.html' &&
            req.method == HttpMethod.post) {
          return _htmlResponse(
            req.url,
            '<html><body><p id="tips">请输入验证码！</p>'
            '<form action="/jwglxt/xtgl/login_slogin.html"><input name="yhm"><input name="mm">'
            '<div id="yzmDiv"><input name="yzm"></div></form></body></html>',
          );
        }
        if (uri.path == '/jwglxt/kaptcha') {
          kaptchaFetched++;
          return HttpResponse(
            status: 200,
            headers: const <String, List<String>>{
              'Content-Type': <String>['image/jpeg'],
              'Set-Cookie': <String>['KAPTCHA_SESSION_KEY=ABCD; Path=/jwglxt'],
            },
            body: Uint8List.fromList(const <int>[0xFF, 0xD8, 0xFF, 0xD9]),
            finalUrl: req.url,
          );
        }
        return _htmlResponse(req.url, 'Not Found', status: 404);
      });

      final client = AcademicClient(
        engine: engine,
        decoder: const _Utf8Decoder(),
        secureStore: InMemorySecureStore(),
        clock: () => _qustReconEpoch,
        random: const _FixedRandom(),
      );
      final res = await client.loginJwglxt(
        schoolId: 'qust',
        accountKey: '2428050113',
        username: '2428050113',
        password: 'wrong',
        academicBaseUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
      );
      expect(res.status, equals(AcademicStatus.CAPTCHA_REQUIRED));
      expect(kaptchaFetched, equals(1));
      expect(res.captcha, isNotNull);
      expect(res.captcha!.image, isNotEmpty);
    });

    test('BrowserSessionImportFlow upgrades bare root to /jwglxt and HTTP 901 / sessionOut maps to SESSION_EXPIRED', () async {
      var trigger901 = false;
      var triggerSessionOutBody = false;

      final engine = _MockQustEngine((req) {
        final uri = Uri.parse(req.url);
        if (trigger901) {
          return _htmlResponse(req.url, '', status: 901);
        }
        if (triggerSessionOutBody) {
          return _htmlResponse(req.url, 'sessionOut');
        }
        if (uri.path == '/jwglxt/xtgl/index_initMenu.html') {
          return _htmlResponse(req.url, _fixture('qust-init-menu-v9.html'));
        }
        if (uri.path == '/jwglxt/xtgl/index_cxYhxxIndex.html') {
          return _htmlResponse(req.url, _fixture('qust-user-card.html'));
        }
        return _htmlResponse(req.url, 'Not Found', status: 404);
      });

      final client = AcademicClient(
        engine: engine,
        decoder: const _Utf8Decoder(),
        secureStore: InMemorySecureStore(),
        clock: () => _qustReconEpoch,
        random: const _FixedRandom(),
      );

      final imported = await client.adoptBrowserSession(
        schoolId: 'qust',
        accountKey: '2428050113',
        academicBaseUrl: 'https://jwglxt.qust.edu.cn/',
        browserUrl:
            'https://jwglxt.qust.edu.cn/jwglxt/xtgl/index_initMenu.html?jsdm=xs',
        cookies: const <StoredCookie>[
          StoredCookie(
            name: 'JSESSIONID',
            value: 'AUTHED_COOKIE',
            domain: 'jwglxt.qust.edu.cn',
            path: '/jwglxt',
            secure: true,
          ),
        ],
      );
      expect(imported.status, equals(AcademicStatus.SUCCESS));
      expect(imported.identity.studentId, equals('2428050113'));
      expect(imported.identity.name, equals('测试同学'));
      expect(
        await client.activeSessionBaseUrl('qust', '2428050113'),
        equals('https://jwglxt.qust.edu.cn/jwglxt'),
      );

      trigger901 = true;
      await expectLater(
        client.fetchExams(schoolId: 'qust', accountKey: '2428050113'),
        throwsA(
          isA<AcademicException>().having(
            (e) => e.status,
            'status',
            AcademicStatus.SESSION_EXPIRED,
          ),
        ),
      );

      trigger901 = false;
      triggerSessionOutBody = true;
      await expectLater(
        client.fetchExams(schoolId: 'qust', accountKey: '2428050113'),
        throwsA(
          isA<AcademicException>().having(
            (e) => e.status,
            'status',
            AcademicStatus.SESSION_EXPIRED,
          ),
        ),
      );
    });

    test('hydrates split live-QUST initMenu + AJAX AreaOne/AreaSix/AreaFive fragments and derives semesterStart on merge', () async {
      // 1) Pure merge unit check: AreaOne has #dqzc=11, AreaSix only has #dqrq=2026-11-15 -> merge derives 2026-08-31
      final shellMeta = ZhengfangHomeParser.parse(
        '<input type="hidden" id="sessionUserKey" value="2428050113"/>'
        '<a onclick="clickMenu(\'N2151\',\'/kbcx/xskbcx_cxXskbcxIndex.html\')">课表</a>',
      );
      final areaOneOnly = ZhengfangHomeParser.parse(
        '<input type="hidden" id="xnm" value="2026"/>'
        '<input type="hidden" id="xqm" value="3"/>'
        '<input type="hidden" id="dqzc" value="11"/>',
      );
      final areaDateOnly = ZhengfangHomeParser.parse(
        '<input type="hidden" id="dqrq" value="2026-11-15"/>',
      );
      final mergedDerived = areaDateOnly.merge(areaOneOnly.merge(shellMeta));
      expect(mergedDerived.studentId, equals('2428050113'));
      expect(mergedDerived.currentTerm?.id, equals('2026-2027-1'));
      expect(mergedDerived.currentWeek, equals(11));
      expect(mergedDerived.serverDate, equals('2026-11-15'));
      expect(mergedDerived.semesterStart, equals(SemesterStart(2026, 8, 31)));
      expect(mergedDerived.menuPathsByGnmkdm['N2151'], isNotEmpty);

      // 2) End-to-end split live-QUST HTML containers via loginJwglxt AND adoptBrowserSession -> loadStudyCatalog
      var useAreaFiveFallback = false;
      var areaOnePosts = 0;
      var areaSixPosts = 0;
      var areaFivePosts = 0;

      const bareInitMenuHtml = '''
      <!doctype html><html><body>
        <input type="hidden" id="sessionUserKey" value="2428050113"/>
        <div id="area_one"></div>
        <div id="area_six"></div>
      </body></html>
      ''';
      const areaOneHtml = '''
      <div>
        <input type="hidden" id="xnm" name="xnm" value="2026"/>
        <input type="hidden" id="xqm" name="xqm" value="3"/>
        <input type="hidden" id="dqzc" name="dqzc" value="11"/>
      </div>
      ''';
      const areaCalendarHtml = '''
      <div>
        <input type="hidden" id="dqrq" name="dqrq" value="2026-11-15"/>
        <div id="xlyq">2026-2027学年1学期(2026-08-31至2027-01-17)</div>
      </div>
      ''';

      final engine = _MockQustEngine((req) {
        final uri = Uri.parse(req.url);
        if (uri.path == '/jwglxt/xtgl/login_slogin.html' &&
            req.method == HttpMethod.get) {
          return _htmlResponse(req.url, _fixture('qust-login-jwglxt.html'));
        }
        if (uri.path == '/jwglxt/xtgl/login_getPublicKey.html') {
          return _jsonResponse(req.url, _fixture('qust-publickey.json'));
        }
        if (uri.path == '/jwglxt/xtgl/login_slogin.html' &&
            req.method == HttpMethod.post) {
          return _htmlResponse(
            req.url,
            bareInitMenuHtml,
            status: 302,
            finalUrl: 'https://jwglxt.qust.edu.cn/jwglxt/xtgl/index_initMenu.html',
          );
        }
        if (uri.path == '/jwglxt/xtgl/index_initMenu.html') {
          return _htmlResponse(req.url, bareInitMenuHtml);
        }
        if (uri.path == '/jwglxt/xtgl/index_cxYhxxIndex.html') {
          return _htmlResponse(req.url, _fixture('qust-user-card.html'));
        }
        if (uri.path == '/jwglxt/xtgl/index_cxAreaOne.html' &&
            req.method == HttpMethod.post) {
          expect(req.headers['X-Requested-With'], equals('XMLHttpRequest'));
          areaOnePosts++;
          return _htmlResponse(req.url, areaOneHtml);
        }
        if (uri.path == '/jwglxt/xtgl/index_cxAreaSix.html' &&
            req.method == HttpMethod.post) {
          expect(req.headers['X-Requested-With'], equals('XMLHttpRequest'));
          areaSixPosts++;
          return _htmlResponse(
            req.url,
            useAreaFiveFallback ? '<div>暂无校历</div>' : areaCalendarHtml,
          );
        }
        if (uri.path == '/jwglxt/xtgl/index_cxAreaFive.html' &&
            req.method == HttpMethod.post) {
          expect(req.headers['X-Requested-With'], equals('XMLHttpRequest'));
          areaFivePosts++;
          return _htmlResponse(req.url, areaCalendarHtml);
        }
        return _htmlResponse(req.url, 'Not Found', status: 404);
      });

      final client = AcademicClient(
        engine: engine,
        decoder: const _Utf8Decoder(),
        secureStore: InMemorySecureStore(),
        clock: () => _qustReconEpoch,
        random: const _FixedRandom(),
      );

      // Path A: loginJwglxt populates AreaOne + AreaSix immediately
      final login = await client.loginJwglxt(
        schoolId: 'qust',
        accountKey: '2428050113',
        username: '2428050113',
        password: 'pw',
        academicBaseUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
      );
      expect(login.status, equals(AcademicStatus.SUCCESS));
      expect(areaOnePosts, equals(1));
      expect(areaSixPosts, equals(1));
      expect(areaFivePosts, equals(0));

      final catAfterLogin = await client.loadStudyCatalog(
        schoolId: 'qust',
        accountKey: '2428050113',
        systemId: 'zf',
        username: '2428050113',
      );
      expect(catAfterLogin.currentTerm.id, equals('2026-2027-1'));
      expect(catAfterLogin.currentWeek, equals(11));
      expect(catAfterLogin.serverDate, equals('2026-11-15'));
      expect(catAfterLogin.semesterStart, equals(SemesterStart(2026, 8, 31)));
      expect(catAfterLogin.totalWeeks, equals(20));
      // Cached from login -> zero duplicate AreaOne/AreaSix calls
      expect(areaOnePosts, equals(1));
      expect(areaSixPosts, equals(1));

      // Path B: adoptBrowserSession (where initMenu only has studentId) + AreaFive fallback in loadStudyCatalog
      useAreaFiveFallback = true;
      await client.adoptBrowserSession(
        schoolId: 'qust',
        accountKey: '2428050114',
        academicBaseUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
        cookies: const <StoredCookie>[
          StoredCookie(
            name: 'JSESSIONID',
            value: 'S2',
            domain: 'jwglxt.qust.edu.cn',
            path: '/jwglxt',
            secure: true,
          ),
        ],
      );
      final catAfterImport = await client.loadStudyCatalog(
        schoolId: 'qust',
        accountKey: '2428050114',
        systemId: 'zf',
        username: '2428050114',
      );
      expect(catAfterImport.currentTerm.id, equals('2026-2027-1'));
      expect(catAfterImport.currentWeek, equals(11));
      expect(catAfterImport.serverDate, equals('2026-11-15'));
      expect(catAfterImport.semesterStart, equals(SemesterStart(2026, 8, 31)));
      expect(catAfterImport.totalWeeks, equals(20));
      expect(areaFivePosts, equals(1));
    });
  });

  group('2 & 3. QUST Timetable, sjkList Practical Courses, Term Mapping & Campus Bell Schedule', () {
    test('StudyJson maps xqmmc before xqmc and supports xqm 3/12/16/32', () {
      expect(StudyJson.normalizeTermParts('2026', '3'), equals('2026-2027-1'));
      expect(StudyJson.normalizeTermParts('2025', '12'), equals('2025-2026-2'));
      expect(StudyJson.normalizeTermParts('2025', '16'), equals('2025-2026-3'));
      expect(StudyJson.normalizeTermParts('2025', '32'), equals('2025-2026-4'));

      // Row where xqm is absent and xqmc is campus name ("四方校区"), while xqmmc is "1"
      final grades = StudyJson.gradeRows(const <Map<String, Object?>>[
        <String, Object?>{
          'xnm': '2026',
          'xqmc': '四方校区',
          'xqmmc': '1',
          'kcmc': '合成生物学导论',
          'cj': '91',
          'xf': '2.0',
          'jd': '4.10',
        },
      ]);
      expect(grades.single.term, equals('2026-2027-1'));
    });

    test('loadStudyScheduleBundle parses N2151 kbList + sjkList + dateless kbList without crash & fetches live bell times', () async {
      final engine = _MockQustEngine((req) {
        final uri = Uri.parse(req.url);
        expect(req.url.contains('??'), isFalse);
        if (uri.path == '/jwglxt/xtgl/index_initMenu.html') {
          return _htmlResponse(req.url, _fixture('qust-init-menu-v9.html'));
        }
        if (uri.path == '/jwglxt/xtgl/index_cxYhxxIndex.html') {
          return _htmlResponse(req.url, _fixture('qust-user-card.html'));
        }
        if (uri.path == '/jwglxt/kbcx/xskbcx_cxXsgrkb.html') {
          expect(uri.queryParameters['gnmkdm'], equals('N2151'));
          expect(req.headers['X-Requested-With'], equals('XMLHttpRequest'));
          final form = _formBodyMap(req);
          expect(form['xnm'], equals('2026'));
          expect(form['xqm'], equals('3'));
          expect(form['kzlx'], equals('ck'));
          return _jsonResponse(req.url, _fixture('qust-timetable-2026-1.json'));
        }
        if (uri.path == '/jwglxt/kbcx/xskbcx_cxRjc.html') {
          final form = _formBodyMap(req);
          final body = form['xqh_id'] == '3'
              ? _fixture('qust-bell-campus3.json')
              : _fixture('qust-bell-campus1.json');
          return _jsonResponse(req.url, body);
        }
        return _htmlResponse(req.url, 'Not Found', status: 404);
      });

      final client = AcademicClient(
        engine: engine,
        decoder: const _Utf8Decoder(),
        secureStore: InMemorySecureStore(),
        clock: () => _qustReconEpoch,
        random: const _FixedRandom(),
      );
      await client.adoptBrowserSession(
        schoolId: 'qust',
        accountKey: '2428050113',
        academicBaseUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
        cookies: const <StoredCookie>[
          StoredCookie(
            name: 'JSESSIONID',
            value: 'S1',
            domain: 'jwglxt.qust.edu.cn',
            path: '/jwglxt',
            secure: true,
          ),
        ],
      );

      final bundle = await client.loadStudyScheduleBundle(
        schoolId: 'qust',
        accountKey: '2428050113',
        systemId: 'zf',
        termId: '2026-2027-1',
      );

      expect(bundle.termId, equals('2026-2027-1'));
      expect(bundle.studentInfo?.major, equals('合成生物学'));
      expect(bundle.studentInfo?.grade, equals('2024'));
      expect(bundle.entries, isNotEmpty);

      // Verify *基因编辑技术 enriched metadata
      final geneEdit =
          bundle.entries.firstWhere((e) => e.name == '*基因编辑技术');
      expect(geneEdit.courseCode, equals('D219031900'));
      expect(geneEdit.courseCategory, equals('专选(必选)'));
      expect(geneEdit.campus, equals('四方校区'));
      expect(geneEdit.credits, equals('2.0'));

      // Verify 5-instructor same-slot 抗体工程 entries & QUST zcd week patterns
      final antibody =
          bundle.entries.where((e) => e.name == '抗体工程').toList();
      expect(antibody.length, equals(5));

      final commaWeeks = ScheduleText.parseWeeks('6周,11周,16周')!;
      expect(commaWeeks.contains(6), isTrue);
      expect(commaWeeks.contains(11), isTrue);
      expect(commaWeeks.contains(16), isTrue);
      expect(commaWeeks.contains(7), isFalse);

      final singleDiWeek = ScheduleText.parseWeeks('第11周')!;
      expect(singleDiWeek.contains(11), isTrue);
      expect(singleDiWeek.contains(10), isFalse);

      final mixedOddWeeks = ScheduleText.parseWeeks('5-7周(单),10周,13-15周')!;
      expect(mixedOddWeeks.contains(5), isTrue);
      expect(mixedOddWeeks.contains(6), isFalse);
      expect(mixedOddWeeks.contains(7), isTrue);
      expect(mixedOddWeeks.contains(10), isTrue);
      expect(mixedOddWeeks.contains(14), isTrue);

      // Verify 未排地点 preserved
      expect(
        bundle.entries.any((e) => e.location.contains('未排地点')),
        isTrue,
      );

      // Verify sjkList (4 items) + 1 dateless kbList item -> 5 practicalCourses without crash
      expect(bundle.practicalCourses.length, equals(5));
      expect(
        bundle.practicalCourses.any(
          (p) => p.name == '劳动实践' && p.weeksText == '18-19周',
        ),
        isTrue,
      );
      expect(
        bundle.practicalCourses.any(
          (p) => p.name == '有机化学B' && p.isRetake && p.credits == '5.0',
        ),
        isTrue,
      );
      expect(
        bundle.practicalCourses.any((p) => p.name == '认识实习(无排课时间)'),
        isTrue,
      );

      // Verify live bell schedules match presets exactly (11 periods)
      final sifangBell = await client.fetchCampusBellSchedule(
        schoolId: 'qust',
        accountKey: '2428050113',
        campusId: '1',
      );
      expect(sifangBell, equals(PeriodScheduleBuilder.qustSifangLaoshanPreset()));
      expect(sifangBell.length, equals(11));
      expect(sifangBell.first.start, equals('08:00'));
      expect(sifangBell.last.end, equals('20:35'));

      final gaomiBell = await client.fetchCampusBellSchedule(
        schoolId: 'qust',
        accountKey: '2428050113',
        campusId: '3',
      );
      expect(gaomiBell, equals(PeriodScheduleBuilder.qustGaomiPreset()));
      expect(gaomiBell.length, equals(11));
      expect(gaomiBell.first.start, equals('08:30'));
      expect(gaomiBell.last.end, equals('20:25'));
    });

    test('loadStudySchedule falls back to N253508 xskbcx_cxXsKb.html when N2151 returns 404', () async {
      final engine = _MockQustEngine((req) {
        final uri = Uri.parse(req.url);
        if (uri.path == '/jwglxt/xtgl/index_initMenu.html') {
          return _htmlResponse(req.url, _fixture('qust-init-menu-v9.html'));
        }
        if (uri.path == '/jwglxt/kbcx/xskbcx_cxXsgrkb.html') {
          return _htmlResponse(req.url, 'Not Found', status: 404);
        }
        if (uri.path == '/jwglxt/kbcx/xskbcx_cxXsKb.html') {
          return _jsonResponse(
            req.url,
            '{"kbList":[{"kcmc":"回退课表测试","xm":"李老师","cdmc":"1教101","xqj":"1","jcs":"1-2","zcd":"1-16周"}]}',
          );
        }
        return _htmlResponse(req.url, 'Not Found', status: 404);
      });

      final client = AcademicClient(
        engine: engine,
        decoder: const _Utf8Decoder(),
        secureStore: InMemorySecureStore(),
        clock: () => _qustReconEpoch,
        random: const _FixedRandom(),
      );
      await client.adoptBrowserSession(
        schoolId: 'qust',
        accountKey: '2428050113',
        academicBaseUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
        cookies: const <StoredCookie>[
          StoredCookie(
            name: 'JSESSIONID',
            value: 'S1',
            domain: 'jwglxt.qust.edu.cn',
            path: '/jwglxt',
            secure: true,
          ),
        ],
      );

      final entries = await client.loadStudySchedule(
        schoolId: 'qust',
        accountKey: '2428050113',
        systemId: 'zf',
        termId: '2026-2027-1',
      );
      expect(entries.single.name, equals('回退课表测试'));
    });
  });

  group('4 & 5. QUST Grades (Makeup jd=1.00 Cap, Bulk Sub-Items, Deduplication) & Exams', () {
    test('loadStudyGrades preserves 补考一 jd=1.00, attaches bulk KccjList sub-items, deduplicates multi-attempt GPA, and parses modal subtab', () async {
      var xmcjEmpty = false;
      final engine = _MockQustEngine((req) {
        final uri = Uri.parse(req.url);
        if (uri.path == '/jwglxt/xtgl/index_initMenu.html') {
          return _htmlResponse(req.url, _fixture('qust-init-menu-v9.html'));
        }
        if (uri.path == '/jwglxt/cjcx/cjcx_cxXsgrcj.html') {
          final form = _formBodyMap(req);
          expect(form['queryModel.showCount'], equals('200'));
          return _jsonResponse(req.url, _fixture('qust-grades.json'));
        }
        if (uri.path == '/jwglxt/cjcx/cjcx_cxXsKccjList.html') {
          final form = _formBodyMap(req);
          expect(form['queryModel.showCount'], equals('300'));
          return _jsonResponse(req.url, _fixture('qust-grade-subitems.json'));
        }
        if (uri.path == '/jwglxt/cjcx/cjcx_cxXsXmcjList.html') {
          if (xmcjEmpty) {
            return _jsonResponse(req.url, '{"items":[]}');
          }
          final form = _formBodyMap(req);
          expect(form['jxb_id'], isNotEmpty);
          return _jsonResponse(
            req.url,
            '{"items":[{"xmblmc":"作业(50%)","xmcj":"88.1"},{"xmblmc":"期末(50%)","xmcj":"21"}]}',
          );
        }
        if (uri.path == '/jwglxt/cjcx/cjcx_cxCjxqGjh.html') {
          return _htmlResponse(req.url, _fixture('qust-grade-modal.html'));
        }
        return _htmlResponse(req.url, 'Not Found', status: 404);
      });

      final client = AcademicClient(
        engine: engine,
        decoder: const _Utf8Decoder(),
        secureStore: InMemorySecureStore(),
        clock: () => _qustReconEpoch,
        random: const _FixedRandom(),
      );
      await client.adoptBrowserSession(
        schoolId: 'qust',
        accountKey: '2428050113',
        academicBaseUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
        cookies: const <StoredCookie>[
          StoredCookie(
            name: 'JSESSIONID',
            value: 'S1',
            domain: 'jwglxt.qust.edu.cn',
            path: '/jwglxt',
            secure: true,
          ),
        ],
      );

      final report = await client.loadStudyGrades(
        schoolId: 'qust',
        accountKey: '2428050113',
        systemId: 'zf',
      );
      expect(report.grades, isNotEmpty);

      // CRITICAL QUST RULE: 化工原理C 补考一 score 75 MUST keep jd="1.00" (NOT 2.50 or xfjd 3.00!)
      final makeupChemEng = report.grades.firstWhere(
        (g) => g.courseCode == 'D201010130' && g.examNature == '补考一',
      );
      expect(makeupChemEng.score, equals('75'));
      expect(makeupChemEng.gradePoint, equals('1.00'));
      expect(makeupChemEng.isMakeup, isTrue);

      // Retake 基础化学原理B1 gets full uncapped GPA 3.70
      final retakeChem = report.grades.firstWhere(
        (g) => g.courseCode == 'D202010121' && g.examNature == '重修',
      );
      expect(retakeChem.score, equals('87'));
      expect(retakeChem.gradePoint, equals('3.70'));
      expect(retakeChem.isRetake, isTrue);

      // Bulk sub-items attached to initial 化工原理C (2025-2026-2)
      final initialChemEng = report.grades.firstWhere(
        (g) => g.courseCode == 'D201010130' && g.examNature == '正常考试',
      );
      expect(initialChemEng.subItems, isNotEmpty);
      expect(
        initialChemEng.subItems.any(
          (s) => s.name == '作业(50%)' && s.score == '88.1',
        ),
        isTrue,
      );

      // Deduplication & enriched summary metrics
      final deduped = GradeMath.deduplicateCourses(report.grades);
      expect(
        deduped.where((g) => g.courseCode == 'D202010121').single.score,
        equals('87'),
      );
      final summary = client.summarize(report);
      expect(summary.earnedCredits, greaterThan(0));
      expect(summary.attemptedCredits, greaterThanOrEqualTo(summary.earnedCredits));
      expect(summary.weightedAverageScore, isNot(equals('--')));
      expect(summary.compulsoryGpa, isNot(equals('--')));
      expect(summary.creditsByCategory['必修'], greaterThan(0));

      // Per-course fetchGradeSubItems via XmcjList and HTML modal fallback
      final viaJson = await client.fetchGradeSubItems(
        initialChemEng,
        schoolId: 'qust',
        accountKey: '2428050113',
      );
      expect(viaJson.length, equals(2));

      xmcjEmpty = true;
      final viaModal = await client.fetchGradeSubItems(
        initialChemEng.copyWith(subItems: const <GradeSubItem>[]),
        schoolId: 'qust',
        accountKey: '2428050113',
      );
      expect(
        viaModal,
        equals(const <GradeSubItem>[
          GradeSubItem(name: '作业(50%)', score: '88.1'),
          GradeSubItem(name: '期末(50%)', score: '21'),
          GradeSubItem(name: '总评', score: '21'),
        ]),
      );

      // GradesHtml 学分绩点 vs 绩点 vs 学分 column disambiguation
      const trickyHtml = '''
      <table>
        <tr><th>学年学期</th><th>课程名称</th><th>学分</th><th>成绩</th><th>学分绩点</th><th>绩点</th></tr>
        <tr><td>2026-2027-1</td><td>化工原理C</td><td>3.0</td><td>75</td><td>3.00</td><td>1.00</td></tr>
      </table>
      ''';
      final parsedHtml = GradesHtml.parse(trickyHtml);
      expect(parsedHtml.grades.single.credits, equals('3.0'));
      expect(parsedHtml.grades.single.gradePoint, equals('1.00'));
    });

    test('fetchExams(allTerms: true) parses QUST date/time range, strips staff ID prefix, and keeps missing zwh empty', () async {
      Map<String, String>? capturedForm;
      final engine = _MockQustEngine((req) {
        final uri = Uri.parse(req.url);
        if (uri.path == '/jwglxt/xtgl/index_initMenu.html') {
          return _htmlResponse(req.url, _fixture('qust-init-menu-v9.html'));
        }
        if (uri.path == '/jwglxt/kwgl/kscx_cxXsksxxIndex.html') {
          capturedForm = _formBodyMap(req);
          return _jsonResponse(req.url, _fixture('qust-exams.json'));
        }
        return _htmlResponse(req.url, 'Not Found', status: 404);
      });

      final client = AcademicClient(
        engine: engine,
        decoder: const _Utf8Decoder(),
        secureStore: InMemorySecureStore(),
        clock: () => _qustReconEpoch,
        random: const _FixedRandom(),
      );
      await client.adoptBrowserSession(
        schoolId: 'qust',
        accountKey: '2428050113',
        academicBaseUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
        cookies: const <StoredCookie>[
          StoredCookie(
            name: 'JSESSIONID',
            value: 'S1',
            domain: 'jwglxt.qust.edu.cn',
            path: '/jwglxt',
            secure: true,
          ),
        ],
      );

      final exams = await client.fetchExams(
        schoolId: 'qust',
        accountKey: '2428050113',
        allTerms: true,
      );
      expect(capturedForm?['xnm'], equals(''));
      expect(capturedForm?['xqm'], equals(''));
      expect(capturedForm?['queryModel.showCount'], equals('200'));
      expect(exams, isNotEmpty);

      final dg = exams.firstWhere((e) => e.courseCode == 'D207050430');
      expect(dg.name, equals('电工电子学C'));
      expect(dg.termId, equals('2026-2027-1'));
      expect(dg.campus, equals('四方校区'));
      expect(dg.examMethod, equals('笔试'));
      expect(dg.examDate, equals('2026-08-29'));
      expect(dg.startTime, equals('16:10'));
      expect(dg.endTime, equals('18:00'));
      expect(dg.teacher, equals('王思民'));
      expect(dg.seat, equals(''));

      // Live QUST regression (#25): xm is student name, and 2024-2025-2 retake exams
      // return "未放开不可查" in cdxqmc/cdmc/zwh while xqmc="四方校区" and jsxx="03298/刘佳".
      final withheldExams = StudyJson.examRows(const <Map<String, Object?>>[
        <String, Object?>{
          'kch': 'D202010121',
          'kcmc': '基础化学原理B1',
          'ksmc': '2024-2025-2学期重修课考试',
          'kssj': '未放开不可查',
          'cdxqmc': '未放开不可查',
          'xqmc': '四方校区',
          'cdmc': '未放开不可查',
          'zwh': '未放开不可查',
          'xm': '测试同学',
          'jsxx': '03298/刘佳',
          'xnm': '2024',
          'xqm': '12',
        },
        <String, Object?>{
          'kch': 'D206020100',
          'kcmc': '线性代数',
          'kssj': '未放开不可查',
          'cdxqmc': '未放开不可查',
          'xqmc': '未放开不可查',
          'cdmc': '未放开不可查',
          'zwh': '未放开不可查',
          'xm': '测试同学',
          'jsxx': 'fs595/韩誉;01001/王芳',
          'xnm': '2024',
          'xqm': '12',
        },
      ]);
      expect(withheldExams[0].teacher, equals('刘佳'));
      expect(withheldExams[0].campus, equals('四方校区'));
      expect(withheldExams[0].location, equals('四方校区'));
      expect(withheldExams[0].seat, isEmpty);
      expect(withheldExams[0].examDate, isEmpty);

      expect(withheldExams[1].teacher, equals('韩誉,王芳'));
      expect(withheldExams[1].campus, isEmpty);
      expect(withheldExams[1].location, isEmpty);
      expect(withheldExams[1].seat, isEmpty);
    });
  });

  group('6. Three Year-Round QUST Modules: N105515 Academic Progress, N2155 Empty Classrooms, N255010 Enrolled Courses', () {
    test('N105515 fetchAcademicProgress & fetchAcademicProgressCourses parse inline-JS credit tree and XDZT plan courses', () async {
      Map<String, String>? courseReqForm;
      final engine = _MockQustEngine((req) {
        final uri = Uri.parse(req.url);
        if (uri.path == '/jwglxt/xtgl/index_initMenu.html') {
          return _htmlResponse(req.url, _fixture('qust-init-menu-v9.html'));
        }
        if (uri.path == '/jwglxt/xsxy/xsxyqk_cxXsxyqkIndex.html') {
          return _htmlResponse(req.url, _fixture('qust-xsxy-index.html'));
        }
        if (uri.path == '/jwglxt/xsxy/xsxyqk_cxJxzxjhxfyqKcxx.html') {
          courseReqForm = _formBodyMap(req);
          return _jsonResponse(req.url, _fixture('qust-xsxy-courses.json'));
        }
        return _htmlResponse(req.url, 'Not Found', status: 404);
      });

      final client = AcademicClient(
        engine: engine,
        decoder: const _Utf8Decoder(),
        secureStore: InMemorySecureStore(),
        clock: () => _qustReconEpoch,
        random: const _FixedRandom(),
      );
      await client.adoptBrowserSession(
        schoolId: 'qust',
        accountKey: '2428050113',
        academicBaseUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
        cookies: const <StoredCookie>[
          StoredCookie(
            name: 'JSESSIONID',
            value: 'S1',
            domain: 'jwglxt.qust.edu.cn',
            path: '/jwglxt',
            secure: true,
          ),
        ],
      );

      final progress = await client.fetchAcademicProgress(
        schoolId: 'qust',
        accountKey: '2428050113',
      );
      expect(progress.officialGpa, equals('2.77'));
      expect(progress.totalCourses, equals(86));
      expect(progress.passedCourses, equals(54));
      expect(progress.failedCourses, equals(0));
      expect(progress.unstudiedCourses, equals(20));
      expect(progress.inProgressCourses, equals(12));
      expect(progress.outsidePlanPassedCourses, equals(1));
      // 8 real credit categories (主修 + 7 leaf modules), empty non-credit shells excluded
      expect(progress.categories.length, equals(8));
      expect(progress.leafCategories.length, equals(7));

      final majorRoot = progress.categories.firstWhere((c) => c.name == '主修');
      expect(majorRoot.isLeaf, isFalse);
      expect(majorRoot.earnedCredits, equals(109.5));
      expect(majorRoot.requiredCredits, equals(175.0));

      final compulsory = progress.categories.firstWhere((c) => c.name == '必修');
      expect(compulsory.isLeaf, isTrue);
      expect(compulsory.earnedCredits, equals(69.5));
      expect(compulsory.requiredCredits, equals(88.5));

      final generalElective =
          progress.categories.firstWhere((c) => c.name == '通识任选');
      expect(generalElective.passed, isTrue);
      expect(generalElective.earnedCredits, equals(6.0));
      expect(generalElective.requiredCredits, equals(4.0));

      final planCourses = await client.fetchAcademicProgressCourses(
        compulsory.id,
        schoolId: 'qust',
        accountKey: '2428050113',
      );
      expect(courseReqForm?['xfyqjd_id'], equals(compulsory.id));
      expect(courseReqForm?['xh_id'], equals('2428050113'));
      expect(planCourses, isNotEmpty);

      final chemB1 =
          planCourses.firstWhere((c) => c.courseCode == 'D202010121');
      expect(chemB1.status, equals(PlanCourseStatus.passed));
      expect(chemB1.recommendedTerm, equals('2024-2025-1'));
      expect(chemB1.maxScore, equals('87'));
      expect(chemB1.makeupScore, equals('40'));
      expect(chemB1.retakeScore, equals('87'));
      expect(chemB1.gpa, equals('3.7'));
    });

    test('N2155 queryEmptyClassrooms encodes BigInt zcd/jcd bitmasks & N255010 fetchEnrolledCourses strips all PII', () async {
      // Bitmask math verification (including >32-bit week safety for Web JS)
      const qWeek11 = EmptyClassroomQuery(
        campusId: '1',
        week: 11,
        dayOfWeek: 1,
        startPeriod: 1,
        endPeriod: 2,
      );
      expect(qWeek11.zcdBitmask, equals('1024'));
      expect(qWeek11.jcdBitmask, equals('3'));

      const qPeriods34 = EmptyClassroomQuery(
        weeks: <int>[1, 40],
        daysOfWeek: <int>[1, 3],
        startPeriod: 3,
        endPeriod: 4,
      );
      expect(qPeriods34.jcdBitmask, equals('12'));
      expect(qPeriods34.xqjParam, equals('1,3'));
      expect(qPeriods34.zcdBitmask, equals('549755813889'));

      Map<String, String>? cdjyForm;
      final engine = _MockQustEngine((req) {
        final uri = Uri.parse(req.url);
        if (uri.path == '/jwglxt/xtgl/index_initMenu.html') {
          return _htmlResponse(req.url, _fixture('qust-init-menu-v9.html'));
        }
        if (uri.path == '/jwglxt/cdjy/cdjy_cxKxcdlb.html') {
          cdjyForm = _formBodyMap(req);
          return _jsonResponse(req.url, _fixture('qust-empty-classrooms.json'));
        }
        if (uri.path == '/jwglxt/xkcx/xkmdcx_cxXkmdcxIndex.html') {
          return _jsonResponse(req.url, _fixture('qust-enrolled-courses.json'));
        }
        return _htmlResponse(req.url, 'Not Found', status: 404);
      });

      final client = AcademicClient(
        engine: engine,
        decoder: const _Utf8Decoder(),
        secureStore: InMemorySecureStore(),
        clock: () => _qustReconEpoch,
        random: const _FixedRandom(),
      );
      await client.adoptBrowserSession(
        schoolId: 'qust',
        accountKey: '2428050113',
        academicBaseUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
        cookies: const <StoredCookie>[
          StoredCookie(
            name: 'JSESSIONID',
            value: 'S1',
            domain: 'jwglxt.qust.edu.cn',
            path: '/jwglxt',
            secure: true,
          ),
        ],
      );

      final rooms = await client.queryEmptyClassrooms(
        qWeek11,
        schoolId: 'qust',
        accountKey: '2428050113',
      );
      expect(cdjyForm?['fwzt'], equals('cx'));
      expect(cdjyForm?['xqh_id'], equals('1'));
      expect(cdjyForm?['zcd'], equals('1024'));
      expect(cdjyForm?['xqj'], equals('1'));
      expect(cdjyForm?['jcd'], equals('3'));
      expect(rooms, isNotEmpty);
      expect(rooms.first.name, equals('1教204'));
      expect(rooms.first.seats, equals(74));
      expect(rooms.first.examSeats, equals(37));
      expect(rooms.first.campus, equals('四方校区'));

      final enrolled = await client.fetchEnrolledCourses(
        schoolId: 'qust',
        accountKey: '2428050113',
      );
      expect(enrolled, isNotEmpty);
      final first = enrolled.firstWhere((c) => c.courseName == '*基因编辑技术');
      expect(first.courseCode, equals('D219031900'));
      expect(first.campus, equals('四方校区'));
      expect(first.termId, equals('2026-2027-1'));
      expect(first.selectionStatus, equals('配课'));

      // Verify StudyJson.enrolledCourses & gradeRows strictly ignore synthetic PII fields
      // AND never treat student-name `xm` as teacher when teacher fields are missing or in `jsxx`.
      final piiTest = StudyJson.enrolledCourses(const <Map<String, Object?>>[
        <String, Object?>{
          'kch_id': 'C001',
          'kcmc': '隐私防护测试课',
          'xm': '测试同学',
          'jsxx': 'BH247/孙长宁/无',
          'zjhm': 'SYNTHETIC_SENSITIVE_ID_999',
          'sjhm': 'SYNTHETIC_SENSITIVE_PHONE_888',
          'cxbj': '是',
          'xnm': '2026',
          'xqm': '3',
        },
      ]);
      expect(piiTest.single.isRetake, isTrue);
      expect(piiTest.single.teacher, equals('孙长宁'));
      expect(piiTest.single.toString(), isNot(contains('SYNTHETIC_SENSITIVE')));

      final gradeNoTeacher = StudyJson.gradeRows(const <Map<String, Object?>>[
        <String, Object?>{
          'kch': 'C002',
          'kcmc': '创新学分认定',
          'xm': '测试同学',
          'cj': '95',
          'jd': '4.50',
          'xf': '1.0',
          'xnm': '2026',
          'xqm': '3',
        },
      ]);
      expect(gradeNoTeacher.single.teacher, isEmpty);
    });
  });

  group('7. Autonomous Course Selection (N253512) Closed Window, queryCourse(this,...), do_jxb_id Drop & >200 Filter', () {
    test('iskxk=0 closed window throws AcademicStatus.ROUND_CLOSED immediately', () async {
      final engine = _MockQustEngine((req) {
        final uri = Uri.parse(req.url);
        if (uri.path == '/jwglxt/xtgl/index_initMenu.html') {
          return _htmlResponse(req.url, _fixture('qust-init-menu-v9.html'));
        }
        if (uri.path == '/jwglxt/xsxk/zzxkyzb_cxZzxkYzbIndex.html') {
          return _htmlResponse(req.url, _fixture('qust-zzxk-closed.html'));
        }
        return _htmlResponse(req.url, 'Not Found', status: 404);
      });

      final client = AcademicClient(
        engine: engine,
        decoder: const _Utf8Decoder(),
        secureStore: InMemorySecureStore(),
        clock: () => _qustReconEpoch,
        random: const _FixedRandom(),
      );
      await client.adoptBrowserSession(
        schoolId: 'qust',
        accountKey: '2428050113',
        academicBaseUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
        cookies: const <StoredCookie>[
          StoredCookie(
            name: 'JSESSIONID',
            value: 'S1',
            domain: 'jwglxt.qust.edu.cn',
            path: '/jwglxt',
            secure: true,
          ),
        ],
      );

      await expectLater(
        client.loadCourseScopes(
          schoolId: 'qust',
          accountKey: '2428050113',
          systemId: 'zf',
        ),
        throwsA(
          isA<AcademicException>().having(
            (e) => e.status,
            'status',
            AcademicStatus.ROUND_CLOSED,
          ),
        ),
      );
    });

    test('parses queryCourse(this,...) per-tab labels, drops via do_jxb_id from ChoosedDisplay, and retries >200 list with filter_list[0]', () async {
      Map<String, String>? dropForm;
      final partDisplayForms = <Map<String, String>>[];

      final engine = _MockQustEngine((req) {
        final uri = Uri.parse(req.url);
        if (uri.path == '/jwglxt/xtgl/index_initMenu.html') {
          return _htmlResponse(req.url, _fixture('qust-init-menu-v9.html'));
        }
        if (uri.path == '/jwglxt/xsxk/zzxkyzb_cxZzxkYzbIndex.html') {
          return _htmlResponse(
            req.url,
            '''
            <html><body>
              <input type="hidden" name="iskxk" id="iskxk" value="1"/>
              <input type="hidden" name="xkxnm" id="xkxnm" value="2026"/>
              <input type="hidden" name="xkxqm" id="xkxqm" value="3"/>
              <input type="hidden" name="rwlx" value="1"/>
              <input type="hidden" name="xkly" value="1"/>
              <ul class="nav-tabs">
                <li><a onclick="queryCourse(this,'01','XKKZ_MAJOR','2024','2805','1')">主修课程</a></li>
                <li><a onclick="queryCourse(this,'10','XKKZ_GEN','2024','2805','2')">通识选修课</a></li>
              </ul>
            </body></html>
            ''',
          );
        }
        if (uri.path == '/jwglxt/xsxk/zzxkyzb_cxZzxkYzbDisplay.html') {
          final form = _formBodyMap(req);
          return _htmlResponse(
            req.url,
            '<input type="hidden" name="rwlx" value="${form['xkkz_id'] == 'XKKZ_GEN' ? '2' : '1'}"/>'
            '<input type="hidden" name="txbsfrl" value="1"/>',
          );
        }
        if (uri.path == '/jwglxt/xsxk/zzxkyzb_cxZzxkYzbChoosedDisplay.html') {
          return _jsonResponse(
            req.url,
            jsonEncode(<Map<String, String>>[
              <String, String>{
                'kch_id': 'GEN999',
                'kcmc': '艺术审美导论',
                'jxb_id': 'SHORT_JXB_ID',
                'do_jxb_id': 'ENCRYPTED_DO_JXB_TOKEN_999',
                'jsxx': '01001/林老师/教授',
                'xf': '2.0',
              },
            ]),
          );
        }
        if (uri.path == '/jwglxt/xsxk/zzxkyzb_cxZzxkYzbPartDisplay.html') {
          final form = _formBodyMap(req);
          partDisplayForms.add(form);
          if (form['filter_list[0]'] == 'TARGET201') {
            return _jsonResponse(
              req.url,
              jsonEncode(<String, Object>{
                'tmpList': <Map<String, String>>[
                  <String, String>{
                    'kch_id': 'TARGET201',
                    'kcmc': '第201门目标课',
                    'xf': '2.0',
                  },
                ],
              }),
            );
          }
          // Generate 200 dummy courses (none matching GEN999 or TARGET201)
          final dummy = List<Map<String, String>>.generate(
            200,
            (i) => <String, String>{
              'kch_id': 'DUMMY_$i',
              'kcmc': '占位课程_$i',
              'xf': '1.0',
            },
          );
          return _jsonResponse(
            req.url,
            jsonEncode(<String, Object>{'tmpList': dummy}),
          );
        }
        if (uri.path == '/jwglxt/xsxk/zzxkyzbjk_cxJxbWithKchZzxkYzb.html') {
          return _jsonResponse(
            req.url,
            jsonEncode(<Map<String, String>>[
              <String, String>{
                'jxb_id': 'JXB_201',
                'do_jxb_id': 'DO_JXB_201',
                'jsxx': '02002/陈老师/副教授',
                'jxbrl': '60',
                'yxzrs': '55',
              },
            ]),
          );
        }
        if (uri.path == '/jwglxt/xsxk/zzxkyzb_tuikBcZzxkYzb.html') {
          dropForm = _formBodyMap(req);
          return _jsonResponse(req.url, '"1"');
        }
        return _htmlResponse(req.url, 'Not Found: ${req.url}', status: 404);
      });

      final client = AcademicClient(
        engine: engine,
        decoder: const _Utf8Decoder(),
        secureStore: InMemorySecureStore(),
        clock: () => _qustReconEpoch,
        random: const _FixedRandom(),
      );
      await client.adoptBrowserSession(
        schoolId: 'qust',
        accountKey: '2428050113',
        academicBaseUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
        cookies: const <StoredCookie>[
          StoredCookie(
            name: 'JSESSIONID',
            value: 'S1',
            domain: 'jwglxt.qust.edu.cn',
            path: '/jwglxt',
            secure: true,
          ),
        ],
      );

      final scopes = await client.loadCourseScopes(
        schoolId: 'qust',
        accountKey: '2428050113',
        systemId: 'zf',
      );
      expect(scopes.length, equals(2));
      expect(scopes[0].name, equals('主修课程'));
      expect(scopes[1].name, equals('通识选修课'));

      final selected = await client.loadSelectedCourses(
        schoolId: 'qust',
        accountKey: '2428050113',
        systemId: 'zf',
      );
      expect(selected.single.courseId, equals('GEN999'));
      expect(
        selected.single.sectionId,
        equals('ENCRYPTED_DO_JXB_TOKEN_999'),
      );

      // Even though GEN999 is absent from PartDisplay, dropCourse falls back to ChoosedDisplay and posts do_jxb_id!
      final dropOutcome = await client.dropCourse(
        schoolId: 'qust',
        accountKey: '2428050113',
        systemId: 'zf',
        courseId: 'GEN999',
        sectionId: selected.single.sectionId,
        scopeId: scopes[1].id,
        confirmed: true,
      );
      expect(dropOutcome.status, equals(AcademicStatus.SUCCESS));
      expect(dropForm?['kch_id'], equals('GEN999'));
      expect(dropForm?['jxb_ids'], equals('ENCRYPTED_DO_JXB_TOKEN_999'));

      // >200 courses in PartDisplay -> listCourseSections retries with filter_list[0]=TARGET201
      final sections = await client.listCourseSections(
        schoolId: 'qust',
        accountKey: '2428050113',
        systemId: 'zf',
        courseId: 'TARGET201',
        scopeId: scopes[1].id,
      );
      expect(sections.single.id, equals('DO_JXB_201'));
      expect(
        partDisplayForms.any((f) => f['filter_list[0]'] == 'TARGET201'),
        isTrue,
      );
    });
  });
}
