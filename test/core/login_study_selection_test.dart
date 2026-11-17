import 'package:courselens/cli/cli_demo_fixtures.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:courselens/core/courselens_core.dart';
import 'package:test/test.dart';

class _TestDecoder implements TextDecoder {
  const _TestDecoder();

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

class _CountingEngine implements HttpEngine {
  int requests = 0;
  final HttpEngine _delegate;
  _CountingEngine(this._delegate);

  @override
  Future<HttpResponse> execute(HttpRequest request) {
    requests++;
    return _delegate.execute(request);
  }
}

class _FailingStore implements SecureStore {
  @override
  Future<void> delete(String key) =>
      throw const SecureStoreException('unavailable', platformStatus: -25308);

  @override
  Future<Uint8List?> get(String key) =>
      throw const SecureStoreException('unavailable', platformStatus: -25308);

  @override
  Future<void> put(String key, Uint8List value) =>
      throw const SecureStoreException('unavailable', platformStatus: -25308);
}

void main() {
  group('Demo & QUST Native full fixture replay', () {
    test('replays demo.fixtures.json end-to-end (CAS -> 5 courses, 5 grades, 2 exams)', () async {
      final demoJson = CliDemoFixtures.demoFixturesJson;
      final client = AcademicClient(
        engine: GuardedHttpEngine(
          FixtureHttpEngine.fromJson(demoJson),
          requireSecure: true,
        ),
        decoder: const _TestDecoder(),
        secureStore: InMemorySecureStore(),
        clock: () => 1700000000,
        random: const _FixedRandom(),
      );

      final login = await client.loginCas(
        schoolId: 'demo',
        accountKey: '20250000',
        username: '20250000',
        password: 'demo-password',
        casBaseUrl: 'https://cas.demo-school.example.edu.cn',
        academicBaseUrl: 'https://jw.demo-school.example.edu.cn/jsxsd',
      );
      expect(login.status, equals(AcademicStatus.SUCCESS));
      expect(login.identity.name, equals('演示同学'));
      expect(login.identity.studentId, equals('20250000'));

      final schedule = await client.loadSchedule(
        schoolId: 'demo',
        accountKey: '20250000',
        path: 'xskbcx',
      );
      expect(schedule.length, equals(5));
      expect(
        schedule.any((e) => e.weeks.text.contains('单') || e.weeks.text.contains('双')),
        isTrue,
      );

      final grades = await client.loadGrades(
        schoolId: 'demo',
        accountKey: '20250000',
        path: 'cjcx',
      );
      expect(grades.grades.length, equals(5));
      final summary = client.summarize(grades);
      expect(summary.gpaText, equals('3.66'));
      expect(summary.creditsText, equals('16.5'));

      final exams = await client.loadExams(
        schoolId: 'demo',
        accountKey: '20250000',
        path: 'xskscx',
      );
      expect(exams.length, equals(2));
    });

    test('replays qust-native.fixtures.json end-to-end (jwglxt PKCS#1 login)', () async {
      final qustJson =
          File('test/fixtures/academic/qust-native.fixtures.json').readAsStringSync();
      final client = AcademicClient(
        engine: GuardedHttpEngine(
          FixtureHttpEngine.fromJson(qustJson),
          requireSecure: true,
        ),
        decoder: const _TestDecoder(),
        secureStore: InMemorySecureStore(),
        clock: () => 1700000000,
        random: const _FixedRandom(),
      );

      final login = await client.loginJwglxt(
        schoolId: 'qust',
        accountKey: '20250000',
        username: '20250000',
        password: 'demo-password',
        academicBaseUrl: 'https://jwglxt2.qust.edu.cn/jwglxt',
      );
      expect(login.status, equals(AcademicStatus.SUCCESS));
      expect(login.identity.name, equals('演示同学'));
      expect(login.identity.studentId, equals('20250000'));
    });
  });

  group('BrowserSessionImportFlow & ZhengfangSelection Hard Rules', () {
    test('BrowserSessionImportFlow supports provisional adoption when shell lacks identity', () async {
      final engine = FixtureHttpEngine([
        HttpFixture(
          url: 'https://jw.example.edu.cn/jwglxt',
          body: '<html><body><div id="shell">Loading SPA...</div></body></html>',
        ),
      ]);
      final client = AcademicClient(
        engine: engine,
        decoder: const _TestDecoder(),
        secureStore: InMemorySecureStore(),
        clock: () => 1700000000,
        random: const _FixedRandom(),
      );

      final result = await client.adoptBrowserSession(
        schoolId: 'test',
        accountKey: 'u1',
        academicBaseUrl: 'https://jw.example.edu.cn/jwglxt',
        cookies: const [
          StoredCookie(
            name: 'JSESSIONID',
            value: 's1',
            domain: 'jw.example.edu.cn',
            path: '/jwglxt',
            secure: true,
          ),
        ],
      );
      expect(result.isProvisional, isTrue);
      expect(await client.sessionEpoch('test', 'u1'), equals(1));
    });

    test('Hard Rule 2: selectCourse/dropCourse with confirmed=false sends ZERO packets', () async {
      final counter = _CountingEngine(
        FixtureHttpEngine([
          HttpFixture(
            url: 'https://jw.example.edu.cn/jwglxt',
            body: '<html><body><input name="xh" value="20250001"><input name="xm" value="张三"></body></html>',
          ),
        ]),
      );
      final client = AcademicClient(
        engine: counter,
        decoder: const _TestDecoder(),
        secureStore: InMemorySecureStore(),
        clock: () => 1700000000,
        random: const _FixedRandom(),
      );

      await client.adoptBrowserSession(
        schoolId: 's',
        accountKey: 'a',
        academicBaseUrl: 'https://jw.example.edu.cn/jwglxt',
        cookies: const [
          StoredCookie(
            name: 'JSESSIONID',
            value: 'ok',
            domain: 'jw.example.edu.cn',
            path: '/',
            secure: true,
          ),
        ],
      );
      final before = counter.requests;

      final sel = await client.selectCourse(
        schoolId: 's',
        accountKey: 'a',
        systemId: 'zf',
        courseId: 'c1',
        sectionId: 'jxb1',
        scopeId: 'zf-0-01',
        confirmed: false,
      );
      expect(sel.status, equals(AcademicStatus.VALIDATION_FAILED));
      expect(counter.requests, equals(before));

      final drp = await client.dropCourse(
        schoolId: 's',
        accountKey: 'a',
        systemId: 'zf',
        courseId: 'c1',
        sectionId: 'jxb1',
        scopeId: 'zf-0-01',
        confirmed: false,
      );
      expect(drp.status, equals(AcademicStatus.VALIDATION_FAILED));
      expect(counter.requests, equals(before));
    });
  });

  group('CredentialVault, SessionArchive (maxAccounts=3) & Hard Rule 1', () {
    test('Hard Rule 1: SecureStore failure surfaces STORAGE_UNAVAILABLE without plaintext fallback', () async {
      final client = AcademicClient(
        engine: FixtureHttpEngine(const []),
        decoder: const _TestDecoder(),
        secureStore: _FailingStore(),
        clock: () => 1700000000,
        random: const _FixedRandom(),
      );

      await expectLater(
        client.savedAccounts(),
        throwsA(
          isA<AcademicException>().having(
            (e) => e.status,
            'status',
            AcademicStatus.STORAGE_UNAVAILABLE,
          ),
        ),
      );
    });

    test('SessionArchive enforces maxAccounts = 3 and supports switching active account', () async {
      final store = InMemorySecureStore();
      final archive = SessionArchive(store: store, service: 'test');

      SavedAccount acc(int i) => SavedAccount(
            schoolId: 's$i',
            accountKey: 'u$i',
            protocol: 'jwglxt',
            baseUrl: 'https://jw$i.example.edu.cn',
          );

      expect(await archive.save(acc(1), const []), isTrue);
      expect(await archive.save(acc(2), const []), isTrue);
      expect(await archive.save(acc(3), const []), isTrue);
      // 4th distinct account must be rejected
      expect(await archive.save(acc(4), const []), isFalse);
      // Updating existing account still succeeds
      expect(await archive.save(acc(2), const []), isTrue);

      expect(await archive.setActive('s1', 'u1'), isTrue);
      expect((await archive.activeAccount())?.accountKey, equals('u1'));
    });
  });
}
