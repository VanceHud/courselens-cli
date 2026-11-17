import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:courselens/cli/cli_args.dart';
import 'package:courselens/cli/cli_demo_fixtures.dart';
import 'package:courselens/cli/cli_runner.dart';
import 'package:courselens/cli/cli_updater.dart';
import 'package:courselens/cli/store/cli_session_store.dart';
import 'package:courselens/core/courselens_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

class _CliRunResult {
  const _CliRunResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  Map<String, dynamic> get jsonMap =>
      jsonDecode(stdout.trim()) as Map<String, dynamic>;
}

class _FailingSessionStore implements CliSessionStore {
  @override
  String get backendDescription => 'keychain (locked-test)';

  @override
  Future<CliSessionRecord?> load() async {
    throw const CliStorageUnavailableException('macOS Keychain is locked');
  }

  @override
  Future<void> save(CliSessionRecord record) async {
    throw const CliStorageUnavailableException('macOS Keychain is locked');
  }

  @override
  Future<void> clear() async {
    throw const CliStorageUnavailableException('macOS Keychain is locked');
  }
}

class _MockHttpEngine implements HttpEngine {
  _MockHttpEngine(this._handler);

  final Future<HttpResponse> Function(HttpRequest request) _handler;
  final List<HttpRequest> recorded = <HttpRequest>[];

  List<HttpRequest> get selectWrites => recorded
      .where((r) => r.url.contains('zzxkyzbjk_xkBcZyZzxkYzb.html'))
      .toList();

  List<HttpRequest> get dropWrites => recorded
      .where((r) => r.url.contains('zzxkyzb_tuikBcZzxkYzb.html'))
      .toList();

  @override
  Future<HttpResponse> execute(HttpRequest request) async {
    recorded.add(request);
    return _handler(request);
  }
}

HttpResponse _htmlResp(
  String url,
  String body, {
  int status = 200,
  String? finalUrl,
  Map<String, List<String>> extraHeaders = const <String, List<String>>{},
}) =>
    HttpResponse(
      status: status,
      finalUrl: finalUrl ?? url,
      headers: <String, List<String>>{
        'Content-Type': const <String>['text/html; charset=UTF-8'],
        ...extraHeaders,
      },
      body: Uint8List.fromList(utf8.encode(body)),
    );

HttpResponse _jsonResp(
  String url,
  Object payload, {
  int status = 200,
}) =>
    HttpResponse(
      status: status,
      finalUrl: url,
      headers: const <String, List<String>>{
        'Content-Type': <String>['application/json; charset=UTF-8'],
      },
      body: Uint8List.fromList(
        utf8.encode(payload is String ? payload : jsonEncode(payload)),
      ),
    );

Future<_CliRunResult> _invokeCli(
  List<String> argv, {
  CliSessionStore? store,
  String? stdinLine,
  String? stdinAll,
  String? hiddenPassword,
  Map<String, String>? env,
  DateTime? now,
  CliHttpEngineBuilder? engineBuilder,
  http.Client? workerHttpClient,
  void Function(AccountSession session)? onSessionRetired,
}) async {
  final outBuf = StringBuffer();
  final errBuf = StringBuffer();
  final runner = CliRunner(
    out: outBuf,
    err: errBuf,
    sessionStoreOverride: store,
    readStdinLine: stdinLine != null ? () async => stdinLine : null,
    readStdinAll: stdinAll != null ? () async => stdinAll : null,
    readHiddenPassword:
        hiddenPassword != null ? (_) async => hiddenPassword : null,
    environment: env ?? const <String, String>{},
    nowProvider: () => now ?? DateTime.utc(2025, 12, 29, 8, 0),
    httpEngineBuilder: engineBuilder,
    workerHttpClient: workerHttpClient,
    onSessionRetired: onSessionRetired,
  );
  final code = await runner.run(argv);
  return _CliRunResult(
    exitCode: code,
    stdout: outBuf.toString(),
    stderr: errBuf.toString(),
  );
}

/// 构造一套完整的正方 v9.0 自主选课与课表/学业只读 Mock 路由。
_MockHttpEngine _buildZhengfangSelectionMock({
  required List<Map<String, String>> Function() selectedRowsProvider,
  required Future<HttpResponse> Function(HttpRequest req) onSelectPost,
  required Future<HttpResponse> Function(HttpRequest req) onDropPost,
}) {
  return _MockHttpEngine((req) async {
    final uri = Uri.parse(req.url);
    if (uri.path.endsWith('/xtgl/index_initMenu.html') ||
        uri.path == '/jwglxt' ||
        uri.path == '/jwglxt/') {
      return _htmlResp(
        req.url,
        '<html><body><input name="xh" value="20250000"><input name="xm" value="测试同学"></body></html>',
      );
    }
    if (uri.path.endsWith('/kbcx/xskbcx_cxXsgrkb.html')) {
      return _jsonResp(req.url, <String, Object?>{
        'xsxx': <String, String>{'XH': '20250000', 'XM': '测试同学'},
        'kbList': <Map<String, String>>[
          <String, String>{
            'kcmc': '体育',
            'xm': '孙老师',
            'cdmc': '体育馆',
            'xqj': '4',
            'jcs': '5-6',
            'zcd': '2-16周(双)',
          },
        ],
        'sjkList': const <Object>[],
      });
    }
    if (uri.path.endsWith('/xsxk/zzxkyzb_cxZzxkYzbIndex.html')) {
      return _htmlResp(
        req.url,
        '''
        <html><body>
          <input type="hidden" name="iskxk" id="iskxk" value="1"/>
          <input type="hidden" name="xkxnm" id="xkxnm" value="2025"/>
          <input type="hidden" name="xkxqm" id="xkxqm" value="12"/>
          <input type="hidden" name="rwlx" value="1"/>
          <input type="hidden" name="xkly" value="1"/>
          <ul class="nav-tabs">
            <li><a onclick="queryCourse(this,'01','XKKZ_CORE','2024','0809','1')">主修选课</a></li>
          </ul>
        </body></html>
        ''',
      );
    }
    if (uri.path.endsWith('/xsxk/zzxkyzb_cxZzxkYzbDisplay.html')) {
      return _htmlResp(
        req.url,
        '<input type="hidden" name="rwlx" value="1"/><input type="hidden" name="txbsfrl" value="0"/>',
      );
    }
    if (uri.path.endsWith('/xsxk/zzxkyzb_cxZzxkYzbChoosedDisplay.html')) {
      return _jsonResp(req.url, selectedRowsProvider());
    }
    if (uri.path.endsWith('/xsxk/zzxkyzb_cxZzxkYzbPartDisplay.html')) {
      return _jsonResp(req.url, <String, Object?>{
        'tmpList': <Map<String, String>>[
          <String, String>{
            'kch_id': 'GE108',
            'kcmc': '音乐审美与数字声学',
            'xf': '2.0',
            'jxbrl': '120',
            'yxzrs': '96',
          },
          <String, String>{
            'kch_id': 'AI402',
            'kcmc': '深度学习与大模型系统',
            'xf': '3.0',
            'jxbrl': '80',
            'yxzrs': '70',
          },
          <String, String>{
            'kch_id': 'CS301',
            'kcmc': '编译原理与实践',
            'xf': '3.5',
            'jxbrl': '60',
            'yxzrs': '52',
          },
        ],
      });
    }
    if (uri.path.endsWith('/xsxk/zzxkyzbjk_cxJxbWithKchZzxkYzb.html')) {
      final bodyStr = req.body == null ? '' : utf8.decode(req.body!);
      if (bodyStr.contains('kch_id=AI402')) {
        return _jsonResp(req.url, <String, Object?>{
          'tmpList': <Map<String, String>>[
            <String, String>{
              'jxb_id': 'AI402-01',
              'do_jxb_id': 'AI402-01',
              'jxbmc': '大模型01班',
              'jsxx': '002/沈思远教授/教授',
              'sksj': '星期四第5-6节{1-16周}',
              'jxdd': '智算中心201',
              'jxbrl': '80',
              'yxzrs': '70',
            },
          ],
        });
      }
      if (bodyStr.contains('kch_id=CS301')) {
        return _jsonResp(req.url, <String, Object?>{
          'tmpList': <Map<String, String>>[
            <String, String>{
              'jxb_id': 'CS301-01',
              'do_jxb_id': 'CS301-01',
              'jxbmc': '编译原理01班',
              'jsxx': '003/周维教授/教授',
              'sksj': '星期二第3-4节{1-16周}',
              'jxdd': '信息楼305',
              'jxbrl': '60',
              'yxzrs': '52',
            },
          ],
        });
      }
      return _jsonResp(req.url, <String, Object?>{
        'tmpList': <Map<String, String>>[
          <String, String>{
            'jxb_id': 'GE108-01',
            'do_jxb_id': 'GE108-01',
            'jxbmc': '通识晚间班',
            'jsxx': '001/苏晴老师/讲师',
            'sksj': '星期五第7-8节{2-16周(双)}',
            'jxdd': '艺术楼102',
            'jxbrl': '120',
            'yxzrs': '96',
          },
        ],
      });
    }
    if (uri.path.endsWith('/xsxk/zzxkyzbjk_xkBcZyZzxkYzb.html')) {
      return onSelectPost(req);
    }
    if (uri.path.endsWith('/xsxk/zzxkyzb_tuikBcZzxkYzb.html')) {
      return onDropPost(req);
    }
    return _htmlResp(req.url, 'Not Found', status: 404);
  });
}

void main() {
  group('1. Pure-Dart Architectural Guard & Embedded Demo Fixtures', () {
    test('ZERO package:flutter/ or courselens_data.dart imports in lib/cli/ and tools/courselens_cli.dart', () {
      final cliDir = Directory('lib/cli');
      expect(cliDir.existsSync(), isTrue);

      final dartFiles = <File>[
        ...cliDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart')),
        File('tools/courselens_cli.dart'),
      ];
      expect(dartFiles, isNotEmpty);

      for (final file in dartFiles) {
        final src = file.readAsStringSync();
        expect(
          src.contains('package:flutter/'),
          isFalse,
          reason: '${file.path} must NOT import package:flutter/',
        );
        expect(
          src.contains('courselens_data.dart'),
          isFalse,
          reason:
              '${file.path} must NOT import courselens_data.dart (transitively pulls Flutter plugins)',
        );
      }
    });

    test('CliDemoFixtures.demoFixturesJson parses cleanly and bin/courselens.dart exists', () {
      final embeddedJson = jsonDecode(CliDemoFixtures.demoFixturesJson);
      expect(embeddedJson, isNotNull);
      expect(File('bin/courselens.dart').existsSync(), isTrue);
    });
  });

  group('2. Global Flags, Argument Validation & Security Redline #1', () {
    test('rejects --password and --password=... anywhere on argv to prevent ps leaks', () async {
      final plain = await _invokeCli(<String>[
        'auth',
        'login',
        '--url',
        'https://jw.example.edu.cn/jwglxt',
        '--user',
        '20250000',
        '--password',
        'leaked-secret',
      ]);
      expect(plain.exitCode, equals(1));
      expect(plain.stdout, isEmpty);
      expect(plain.stderr, contains('SECURITY_REFUSED'));

      final inlineJson = await _invokeCli(<String>[
        '--json',
        'auth',
        'login',
        '--url=https://jw.example.edu.cn/jwglxt',
        '--user=20250000',
        '--password=leaked-secret',
      ]);
      expect(inlineJson.exitCode, equals(1));
      expect(inlineJson.jsonMap['ok'], isFalse);
      expect(inlineJson.jsonMap['code'], equals('SECURITY_REFUSED'));
    });

    test('STORAGE_UNAVAILABLE fails closed with exit code 1 (never degrades to plaintext)', () async {
      final res = await _invokeCli(
        <String>['--json', 'whoami'],
        store: _FailingSessionStore(),
      );
      expect(res.exitCode, equals(1));
      expect(res.jsonMap['ok'], isFalse);
      expect(res.jsonMap['code'], equals('STORAGE_UNAVAILABLE'));
      expect(res.stderr, contains('STORAGE_UNAVAILABLE'));
    });

    test('supports --version, --help, global flag placement anywhere, and spec parsing', () async {
      final ver = await _invokeCli(<String>['--version']);
      expect(ver.exitCode, equals(0));
      expect(ver.stdout, contains('courselens ${CliArgs.cliVersion}'));

      final verJson = await _invokeCli(<String>['version', '--json']);
      expect(verJson.exitCode, equals(0));
      expect(verJson.jsonMap['version'], equals(CliArgs.cliVersion));

      final helpMd = await _invokeCli(<String>['--help']);
      expect(helpMd.exitCode, equals(0));
      expect(helpMd.stdout, contains('auth import-cookie'));
      expect(helpMd.stdout, contains('select --course-id'));

      expect(
        CliArgs.parseIntSpec('1-4, 6, 8', min: 1, max: 20, flagName: '--weeks'),
        equals(<int>[1, 2, 3, 4, 6, 8]),
      );
      expect(
        CliArgs.parseIntSpec('1,3,5', min: 1, max: 12, flagName: '--sections'),
        equals(<int>[1, 3, 5]),
      );

      final badDate = await _invokeCli(<String>[
        '--demo',
        'today',
        '--date',
        '2025-02-29',
      ]);
      expect(badDate.exitCode, equals(1));
      expect(badDate.stderr, contains('INVALID_ARGS'));
    });
  });

  group('3. All Read-Only Subcommands in Standalone --demo Mode (Markdown & --json)', () {
    test('whoami & auth status work in --demo and unauthenticated modes', () async {
      final demoWhoami = await _invokeCli(<String>['--demo', 'whoami', '--json']);
      expect(demoWhoami.exitCode, equals(0));
      expect(demoWhoami.jsonMap['authenticated'], isTrue);
      expect(demoWhoami.jsonMap['alive'], isTrue);
      expect(demoWhoami.jsonMap['student']['name'], equals('演示同学'));

      final unauth = await _invokeCli(
        <String>['auth', 'status', '--json'],
        store: InMemoryCliSessionStore(),
      );
      expect(unauth.exitCode, equals(1));
      expect(unauth.jsonMap['authenticated'], isFalse);
    });

    test('today aggregates academic week, today/tomorrow classes, and exam countdowns', () async {
      // 2025-10-13 is Monday of Week 7 in 2025-2026-1 (first Monday >= 2025-09-01 is 2025-09-01)
      final oct = await _invokeCli(
        <String>['today', '--demo', '--term', '2025-2026-1', '--date', '2025-10-13', '--json'],
        now: DateTime.utc(2025, 10, 13, 8, 0),
      );
      expect(oct.exitCode, equals(0));
      expect(oct.jsonMap['academicWeek'], equals(7));
      final todayClasses = oct.jsonMap['todayClasses'] as List<dynamic>;
      final tomorrowClasses = oct.jsonMap['tomorrowClasses'] as List<dynamic>;
      expect(todayClasses.single['name'], equals('高等数学'));
      // Week 7 is odd week -> Tuesday has 大学物理!
      expect(tomorrowClasses.single['name'], equals('大学物理'));
      final upcoming = oct.jsonMap['upcomingExams'] as List<dynamic>;
      expect(upcoming, hasLength(2));
      expect(upcoming.first['daysUntil'], greaterThan(0));

      final md = await _invokeCli(
        <String>['--demo', '--term', '2025-2026-1', 'today', '--date', '2025-12-29'],
        now: DateTime.utc(2025, 12, 29, 8, 0),
      );
      expect(md.exitCode, equals(0));
      expect(md.stdout, contains('还有 7 天'));
      expect(md.stdout, contains('高等数学'));
    });

    test('schedule filters by --week, includes practical courses, and exports RFC 5545 --ics', () async {
      final tmpDir = await Directory.systemTemp.createTemp('courselens_ics_test_');
      try {
        final icsFile = File('${tmpDir.path}/demo.ics');
        final sched = await _invokeCli(<String>[
          '--demo',
          'schedule',
          '--week',
          '2',
          '--ics',
          icsFile.path,
          '--json',
        ]);
        expect(sched.exitCode, equals(0));
        expect(sched.jsonMap['week'], equals(2));
        // Week 2 (even): 高等数学, 程序设计, 大学英语, 体育 (大学物理 is odd-only so excluded!)
        final entries = sched.jsonMap['entries'] as List<dynamic>;
        final names = entries.map((e) => (e as Map<String, dynamic>)['name']).toList();
        expect(names, containsAll(<String>['高等数学', '程序设计', '大学英语', '体育']));
        expect(names, isNot(contains('大学物理')));
        expect(sched.jsonMap['practicalCourses'], isNotEmpty);

        expect(icsFile.existsSync(), isTrue);
        final icsContent = icsFile.readAsStringSync();
        expect(icsContent, contains('BEGIN:VCALENDAR'));
        expect(icsContent, contains('BEGIN:VEVENT'));
        expect(icsContent, contains('SUMMARY:高等数学'));
        expect(icsContent, contains('END:VCALENDAR'));
      } finally {
        await tmpDir.delete(recursive: true);
      }
    });

    test('grades [--stats], exams, plan, rooms, and courses return structured Markdown & JSON', () async {
      final grades = await _invokeCli(<String>['--demo', 'grades', '--stats', '--json']);
      expect(grades.exitCode, equals(0));
      expect(grades.jsonMap['count'], equals(5));
      final summary = grades.jsonMap['summary'] as Map<String, dynamic>;
      expect(summary['gpa'], equals('3.66'));
      expect(summary['credits'], equals('16.5'));
      expect(summary['distribution'], isA<Map<String, dynamic>>());

      final exams = await _invokeCli(
        <String>['--demo', 'exams', '--json'],
        now: DateTime.utc(2026, 1, 4, 8, 0),
      );
      expect(exams.exitCode, equals(0));
      final examList = exams.jsonMap['exams'] as List<dynamic>;
      expect(examList, hasLength(2));
      expect(examList.first['countdown'], equals('明天'));
      expect(examList.first['seat'], equals('12'));

      final plan = await _invokeCli(<String>['--demo', 'plan', '--json']);
      expect(plan.exitCode, equals(0));
      expect(plan.jsonMap['officialGpa'], equals('3.66'));
      expect(plan.jsonMap['categories'], hasLength(4));

      // Non-contiguous --sections 1,3,5 -> jcd bitmask = 2^0 + 2^2 + 2^4 = 21
      final rooms = await _invokeCli(<String>[
        '--demo',
        'rooms',
        '--campus',
        '1',
        '--day',
        '3',
        '--weeks',
        '1-16',
        '--sections',
        '1,3,5',
        '--json',
      ]);
      expect(rooms.exitCode, equals(0));
      expect(rooms.jsonMap['query']['zcd'], equals('65535'));
      expect(rooms.jsonMap['query']['jcd'], equals('21'));
      final roomList = rooms.jsonMap['rooms'] as List<dynamic>;
      expect(roomList, hasLength(2)); // 2 rooms in 四方校区

      final courses = await _invokeCli(<String>[
        '--demo',
        'courses',
        '--query',
        '编译',
        '--json',
      ]);
      expect(courses.exitCode, equals(0));
      expect((courses.jsonMap['enrolledCourses'] as List<dynamic>).single['courseCode'], equals('CS301'));
      expect((courses.jsonMap['selectableCourses'] as List<dynamic>).single['id'], equals('CS301'));
    });
  });

  group('4. Auth Flows: Login, Import-Cookie (.har / header / stdin), Logout & Redlines #4/#5', () {
    test('auth import-cookie parses .har and Cookie header, verifies online, and auth logout calls session.retire()', () async {
      final memStore = InMemoryCliSessionStore();
      final tmpDir = await Directory.systemTemp.createTemp('courselens_har_test_');
      try {
        final harFile = File('${tmpDir.path}/capture.har');
        await harFile.writeAsString(
          jsonEncode(<String, Object?>{
            'log': <String, Object?>{
              'entries': <Map<String, Object?>>[
                <String, Object?>{
                  'startedDateTime': '2025-12-29T08:00:00.000Z',
                  'request': <String, Object?>{
                    'method': 'GET',
                    'url': 'https://jwglxt.qust.edu.cn/jwglxt/xtgl/index_initMenu.html',
                    'headers': <Map<String, String>>[
                      <String, String>{
                        'name': 'Cookie',
                        'value': 'JSESSIONID=HAR_SESSION_TOKEN; route=node2',
                      },
                    ],
                    'cookies': const <Object>[],
                  },
                  'response': <String, Object?>{
                    'status': 200,
                    'headers': const <Object>[],
                    'cookies': const <Object>[],
                  },
                },
              ],
            },
          }),
        );

        final mockEngine = _MockHttpEngine((req) async {
          return _htmlResp(
            req.url,
            '<html><body><input name="xh" value="2428050113"><input name="xm" value="王同学"></body></html>',
          );
        });

        final imported = await _invokeCli(
          <String>[
            'auth',
            'import-cookie',
            '--url',
            'https://jwglxt.qust.edu.cn/jwglxt',
            '--har',
            harFile.path,
            '--system',
            'ZF',
            '--json',
          ],
          store: memStore,
          engineBuilder: ({required policyProvider, required clock, relayUrl}) =>
              mockEngine,
        );
        expect(imported.exitCode, equals(0));
        expect(imported.jsonMap['ok'], isTrue);
        expect(imported.jsonMap['verified'], isTrue);
        expect(imported.jsonMap['student']['name'], equals('王同学'));

        final saved = await memStore.load();
        expect(saved, isNotNull);
        expect(saved!.cookies['JSESSIONID'], equals('HAR_SESSION_TOKEN'));

        // Verify offline status
        final offlineStatus = await _invokeCli(
          <String>['whoami', '--offline', '--json'],
          store: memStore,
        );
        expect(offlineStatus.exitCode, equals(0));
        expect(offlineStatus.jsonMap['offline'], isTrue);
        expect(offlineStatus.jsonMap['authenticated'], isTrue);

        // Redline #5: auth logout MUST call session.retire() AND clear persistent store
        AccountSession? retiredSession;
        final logout = await _invokeCli(
          <String>['auth', 'logout', '--json'],
          store: memStore,
          onSessionRetired: (s) => retiredSession = s,
        );
        expect(logout.exitCode, equals(0));
        expect(logout.jsonMap['retired'], isTrue);
        expect(retiredSession, isNotNull);
        expect(retiredSession!.isRetired, isTrue);
        expect(
          () => retiredSession!.requireActive(),
          throwsA(isA<SessionCancelledException>()),
        );
        expect(await memStore.load(), isNull);
      } finally {
        await tmpDir.delete(recursive: true);
      }
    });

    test('auth login supports --password-stdin and --password-env via CAS fixture', () async {
      final memStore = InMemoryCliSessionStore();
      final fixtureEngine = FixtureHttpEngine.fromJson(CliDemoFixtures.demoFixturesJson);

      final loginStdin = await _invokeCli(
        <String>[
          'auth',
          'login',
          '--url',
          CliDemoFixtures.demoAcademicBase,
          '--cas-url',
          CliDemoFixtures.demoCasBase,
          '--user',
          CliDemoFixtures.demoAccountKey,
          '--password-stdin',
          '--system',
          'QZ',
          '--json',
        ],
        store: memStore,
        stdinLine: 'demo-password\n',
        engineBuilder: ({required policyProvider, required clock, relayUrl}) =>
            fixtureEngine,
      );
      expect(loginStdin.exitCode, equals(0));
      expect(loginStdin.jsonMap['ok'], isTrue);
      final record = await memStore.load();
      expect(record, isNotNull);
      expect(record!.password, isNull); // Never persists plaintext password!
      expect(record.cookies, isNotEmpty);

      final memStore2 = InMemoryCliSessionStore();
      final fixtureEngine2 = FixtureHttpEngine.fromJson(CliDemoFixtures.demoFixturesJson);
      final loginEnv = await _invokeCli(
        <String>[
          'auth',
          'login',
          '--url',
          CliDemoFixtures.demoAcademicBase,
          '--cas-url',
          CliDemoFixtures.demoCasBase,
          '--user',
          CliDemoFixtures.demoAccountKey,
          '--password-env',
          'MY_EDU_PASS',
          '--system',
          'QZ',
          '--json',
        ],
        store: memStore2,
        env: const <String, String>{'MY_EDU_PASS': 'demo-password'},
        engineBuilder: ({required policyProvider, required clock, relayUrl}) =>
            fixtureEngine2,
      );
      expect(loginEnv.exitCode, equals(0));
      expect(loginEnv.jsonMap['ok'], isTrue);
    });

    test('Redline #4: HostGuardedHttpEngine blocks cross-origin phishing redirects with UNTRUSTED_URL', () async {
      final memStore = InMemoryCliSessionStore(
        CliSessionRecord(
          baseUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
          username: '20250000',
          systemType: 'ZF',
          cookies: const <String, String>{'JSESSIONID': 'S1'},
        ),
      );
      final evilRedirectEngine = _MockHttpEngine((req) async {
        return _htmlResp(
          req.url,
          '',
          status: 302,
          extraHeaders: const <String, List<String>>{
            HostGuardedHttpEngine.blockedRedirectHeader: <String>[
              'https://evil-phishing.example.com/steal',
            ],
          },
        );
      });

      final res = await _invokeCli(
        <String>['exams', '--json'],
        store: memStore,
        engineBuilder: ({required policyProvider, required clock, relayUrl}) =>
            evilRedirectEngine,
      );
      expect(res.exitCode, equals(1));
      expect(res.jsonMap['code'], equals('UNTRUSTED_URL'));
    });
  });

  group('5. Controlled Course Mutations: Redline #2 (Two-Step Confirm) & Redline #3 (RESULT_UNKNOWN Read-Only Check)', () {
    test('Redline #2 (--demo): select & drop without --confirm exit with code 2, detect conflicts, and print --confirm command', () async {
      // Conflict preview: AI402 clashes with 体育 on Thursday periods 5-6 (even weeks)
      final conflictPreview = await _invokeCli(<String>[
        '--demo',
        'select',
        '--course-id',
        'AI402',
        '--json',
      ]);
      expect(conflictPreview.exitCode, equals(2));
      expect(conflictPreview.jsonMap['confirmed'], isFalse);
      expect(conflictPreview.jsonMap['previewOnly'], isTrue);
      final conflicts = conflictPreview.jsonMap['conflicts'] as List<dynamic>;
      expect(conflicts, isNotEmpty);
      expect(conflicts.first['summary'], contains('体育'));
      expect(
        conflictPreview.jsonMap['confirmCommand'],
        contains('--confirm'),
      );

      // Clean preview -> exit 2
      final gePreview = await _invokeCli(<String>[
        '--demo',
        'select',
        '--course-id',
        'GE108',
        '--json',
      ]);
      expect(gePreview.exitCode, equals(2));
      expect(gePreview.jsonMap['confirmed'], isFalse);
      expect(gePreview.jsonMap['previewOnly'], isTrue);
      expect(gePreview.jsonMap['conflicts'], isEmpty);

      // Confirmed select -> exit 0
      final geConfirm = await _invokeCli(<String>[
        '--demo',
        'select',
        '--course-id',
        'GE108',
        '--confirm',
        '--json',
      ]);
      expect(geConfirm.exitCode, equals(0));
      expect(geConfirm.jsonMap['ok'], isTrue);
      expect(geConfirm.jsonMap['confirmed'], isTrue);
      expect(geConfirm.jsonMap['previewOnly'], isFalse);

      // Drop preview -> exit 2, Drop confirm -> exit 0
      final dropPreview = await _invokeCli(<String>[
        '--demo',
        'drop',
        '--course-id',
        'CS301',
        '--json',
      ]);
      expect(dropPreview.exitCode, equals(2));
      expect(dropPreview.jsonMap['previewOnly'], isTrue);

      final dropConfirm = await _invokeCli(<String>[
        '--demo',
        'drop',
        '--course-id',
        'CS301',
        '--confirm',
        '--json',
      ]);
      expect(dropConfirm.exitCode, equals(0));
      expect(dropConfirm.jsonMap['ok'], isTrue);
    });

    test('Redline #2 (live mock): select & drop WITHOUT --confirm send ZERO write POST packets', () async {
      final store = InMemoryCliSessionStore(
        CliSessionRecord(
          baseUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
          username: '20250000',
          systemType: 'ZF',
          cookies: const <String, String>{'JSESSIONID': 'LIVE_OK'},
        ),
      );

      final mock = _buildZhengfangSelectionMock(
        selectedRowsProvider: () => <Map<String, String>>[
          <String, String>{
            'kch_id': 'CS301',
            'kcmc': '编译原理与实践',
            'jxb_id': 'CS301-01',
            'do_jxb_id': 'CS301-01',
            'jsxx': '003/周维教授/教授',
            'sksj': '星期二第3-4节{1-16周}',
          },
        ],
        onSelectPost: (req) async => _jsonResp(req.url, <String, String>{'flag': '1'}),
        onDropPost: (req) async => _jsonResp(req.url, <String, String>{'flag': '1'}),
      );

      final selectDryRun = await _invokeCli(
        <String>['select', '--course-id', 'GE108', '--json'],
        store: store,
        engineBuilder: ({required policyProvider, required clock, relayUrl}) =>
            mock,
      );
      expect(selectDryRun.exitCode, equals(2));
      expect(selectDryRun.jsonMap['confirmed'], isFalse);
      expect(selectDryRun.jsonMap['previewOnly'], isTrue);
      expect(mock.selectWrites, isEmpty);
      expect(mock.dropWrites, isEmpty);

      final dropDryRun = await _invokeCli(
        <String>['drop', '--course-id', 'CS301', '--json'],
        store: store,
        engineBuilder: ({required policyProvider, required clock, relayUrl}) =>
            mock,
      );
      expect(dropDryRun.exitCode, equals(2));
      expect(dropDryRun.jsonMap['confirmed'], isFalse);
      expect(dropDryRun.jsonMap['previewOnly'], isTrue);
      expect(mock.selectWrites, isEmpty);
      expect(mock.dropWrites, isEmpty);
    });

    test('Redline #3: on RESULT_UNKNOWN timeout, select/drop --confirm NEVER re-POST and verify via read-only selected list', () async {
      final store = InMemoryCliSessionStore(
        CliSessionRecord(
          baseUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
          username: '20250000',
          systemType: 'ZF',
          cookies: const <String, String>{'JSESSIONID': 'LIVE_OK'},
        ),
      );

      // Case A: select write POST times out (RESULT_UNKNOWN), but server enrolled GE108-01!
      var enrolledOnServer = false;
      final mockVerifiedApplied = _buildZhengfangSelectionMock(
        selectedRowsProvider: () => <Map<String, String>>[
          if (enrolledOnServer)
            <String, String>{
              'kch_id': 'GE108',
              'kcmc': '音乐审美与数字声学',
              'jxb_id': 'GE108-01',
              'do_jxb_id': 'GE108-01',
              'jsxx': '001/苏晴老师/讲师',
              'sksj': '星期五第7-8节{2-16周(双)}',
            },
        ],
        onSelectPost: (_) async {
          enrolledOnServer = true;
          throw const AcademicException(
            AcademicStatus.RESULT_UNKNOWN,
            'POST read timeout after transmission',
          );
        },
        onDropPost: (req) async => _jsonResp(req.url, '1'),
      );

      final resApplied = await _invokeCli(
        <String>[
          'select',
          '--course-id',
          'GE108',
          '--class-id',
          'GE108-01',
          '--confirm',
          '--json',
        ],
        store: store,
        engineBuilder: ({required policyProvider, required clock, relayUrl}) =>
            mockVerifiedApplied,
      );
      expect(resApplied.exitCode, equals(0));
      expect(mockVerifiedApplied.selectWrites, hasLength(1)); // NEVER re-POSTed!
      expect(resApplied.jsonMap['ok'], isTrue);
      expect(resApplied.jsonMap['status'], equals('RESULT_UNKNOWN'));
      expect(resApplied.jsonMap['verificationState'], equals('VERIFIED_SELECTED'));
      expect(resApplied.jsonMap['verifiedByReadOnlyCheck'], isTrue);

      // Case B: select write POST times out (RESULT_UNKNOWN), and server did NOT enroll GE108-01
      final mockVerifiedNotApplied = _buildZhengfangSelectionMock(
        selectedRowsProvider: () => const <Map<String, String>>[],
        onSelectPost: (_) async {
          throw const AcademicException(
            AcademicStatus.RESULT_UNKNOWN,
            'POST read timeout before server commit',
          );
        },
        onDropPost: (req) async => _jsonResp(req.url, '1'),
      );

      final resNotApplied = await _invokeCli(
        <String>[
          'select',
          '--course-id',
          'GE108',
          '--class-id',
          'GE108-01',
          '--confirm',
          '--json',
        ],
        store: store,
        engineBuilder: ({required policyProvider, required clock, relayUrl}) =>
            mockVerifiedNotApplied,
      );
      expect(resNotApplied.exitCode, equals(1));
      expect(mockVerifiedNotApplied.selectWrites, hasLength(1)); // NEVER re-POSTed!
      expect(resNotApplied.jsonMap['ok'], isFalse);
      expect(resNotApplied.jsonMap['verificationState'], equals('VERIFIED_NOT_SELECTED'));
      expect(resNotApplied.jsonMap['verifiedByReadOnlyCheck'], isTrue);

      // Case C: drop write POST times out (RESULT_UNKNOWN), and server dropped CS301-01
      var stillSelected = true;
      final mockDropVerified = _buildZhengfangSelectionMock(
        selectedRowsProvider: () => <Map<String, String>>[
          if (stillSelected)
            <String, String>{
              'kch_id': 'CS301',
              'kcmc': '编译原理与实践',
              'jxb_id': 'CS301-01',
              'do_jxb_id': 'CS301-01',
              'jsxx': '003/周维教授/教授',
              'sksj': '星期二第3-4节{1-16周}',
            },
        ],
        onSelectPost: (req) async => _jsonResp(req.url, <String, String>{'flag': '1'}),
        onDropPost: (_) async {
          stillSelected = false;
          throw const AcademicException(
            AcademicStatus.RESULT_UNKNOWN,
            'drop response socket reset',
          );
        },
      );

      final dropVerified = await _invokeCli(
        <String>[
          'drop',
          '--course-id',
          'CS301',
          '--class-id',
          'CS301-01',
          '--confirm',
          '--json',
        ],
        store: store,
        engineBuilder: ({required policyProvider, required clock, relayUrl}) =>
            mockDropVerified,
      );
      expect(dropVerified.exitCode, equals(0));
      expect(mockDropVerified.dropWrites, hasLength(1)); // NEVER re-POSTed!
      expect(dropVerified.jsonMap['ok'], isTrue);
      expect(dropVerified.jsonMap['verificationState'], equals('VERIFIED_DROPPED'));
      expect(dropVerified.jsonMap['verifiedByReadOnlyCheck'], isTrue);
    });
  });

  group('courselens CLI Stateful Cloudflare Worker API Key Mode', () {
    const validKey = 'cl_worker_secret_key_2026';
    const workerUrl = 'https://courselens-session.example.workers.dev';

    (MockClient, List<String>) buildMockWorkerGateway() {
      final proxiedUrls = <String>[];
      final portalMock = _buildZhengfangSelectionMock(
        selectedRowsProvider: () => const <Map<String, String>>[],
        onSelectPost: (req) async =>
            _jsonResp(req.url, <String, String>{'flag': '1'}),
        onDropPost: (req) async =>
            _jsonResp(req.url, <String, String>{'flag': '1'}),
      );

      final client = MockClient((req) async {
        final auth = req.headers['authorization'] ?? '';
        if (auth != 'Bearer $validKey') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': false,
              'status': 'INVALID_API_KEY',
              'error': 'Invalid API key',
            }),
            401,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }

        if (req.url.path == '/v1/session') {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'ok': true,
                'authenticated': true,
                'systemId': 'zf',
                'baseUrl': 'https://jwglxt.qust.edu.cn/jwglxt',
                'casBaseUrl': '',
                'username': '20250000',
                'identity': <String, String>{
                  'name': '测试同学',
                  'studentId': '20250000',
                  'department': '信息科学技术学院',
                  'className': '计科241',
                },
              }),
            ),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }

        if (req.url.path == '/v1/proxy' && req.method == 'POST') {
          final payload = jsonDecode(req.body) as Map<String, Object?>;
          final targetUrl = payload['url'] as String;
          proxiedUrls.add(targetUrl);
          final methodStr = (payload['method'] as String? ?? 'GET').toUpperCase();
          final bodyB64 = payload['bodyBase64'] as String?;

          if (targetUrl.contains('cjcx_cxXsgrcj.html')) {
            final gradesJson = jsonEncode(<String, Object?>{
              'items': <Map<String, String>>[
                <String, String>{
                  'xnmmc': '2025-2026',
                  'xqmmc': '1',
                  'kcmc': '数据结构与算法',
                  'kch_id': 'CS201',
                  'xf': '4.0',
                  'cj': '93',
                  'jd': '4.00',
                  'kcxzmc': '专业必修课',
                },
              ],
            });
            return http.Response(
              jsonEncode(<String, Object?>{
                'ok': true,
                'status': 200,
                'finalUrl': targetUrl,
                'headers': <String, List<String>>{
                  'content-type': <String>['application/json; charset=utf-8'],
                },
                'bodyBase64': base64Encode(utf8.encode(gradesJson)),
              }),
              200,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
            );
          }

          final innerResp = await portalMock.execute(
            HttpRequest(
              method: methodStr == 'POST' ? HttpMethod.post : HttpMethod.get,
              url: targetUrl,
              body: bodyB64 != null && bodyB64.isNotEmpty
                  ? base64Decode(bodyB64)
                  : null,
            ),
          );
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': true,
              'status': innerResp.status,
              'finalUrl': innerResp.finalUrl,
              'headers': innerResp.headers,
              'bodyBase64': base64Encode(innerResp.body),
            }),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }

        return http.Response('Not Found', 404);
      });

      return (client, proxiedUrls);
    }

    test('rejects --api-key and --webhook-secret/--secret on argv to prevent process list / shell history leakage', () async {
      for (final badArgv in <List<String>>[
        <String>['auth', 'worker', '--url', workerUrl, '--api-key', 'secret', '--json'],
        <String>['today', '--worker', workerUrl, '--api-key=secret', '--json'],
        <String>['worker', 'webhook', 'set', '--url', 'https://hooks.example.com/a', '--webhook-secret', 'shh', '--json'],
        <String>['worker', 'webhook', 'set', '--url', 'https://hooks.example.com/a', '--secret=shh', '--json'],
      ]) {
        final res = await _invokeCli(badArgv);
        expect(res.exitCode, equals(1));
        expect(res.jsonMap['code'], equals('SECURITY_REFUSED'));
      }
    });

    test('auth worker --api-key-stdin persists 0600 session.json with zero cookies and redacted toString', () async {
      final tmpDir = await Directory.systemTemp.createTemp('cl_worker_cli_');
      addTearDown(() => tmpDir.delete(recursive: true));
      final sessionPath = '${tmpDir.path}/session.json';
      final fileStore = FileCliSessionStore(filePath: sessionPath);
      final (workerClient, proxiedUrls) = buildMockWorkerGateway();

      final authRes = await _invokeCli(
        <String>[
          'auth',
          'worker',
          '--url',
          workerUrl,
          '--api-key-stdin',
          '--json',
        ],
        store: fileStore,
        stdinLine: validKey,
        workerHttpClient: workerClient,
      );

      expect(authRes.exitCode, equals(0), reason: authRes.stderr);
      expect(authRes.jsonMap['ok'], isTrue);
      expect(authRes.jsonMap['mode'], equals('worker'));
      expect(authRes.jsonMap['workerUrl'], equals(workerUrl));
      expect(authRes.jsonMap['cookieCount'], equals(0));

      final savedFile = File(sessionPath);
      expect(savedFile.existsSync(), isTrue);
      if (!Platform.isWindows) {
        final mode = savedFile.statSync().mode & 0x1FF;
        expect(mode, equals(0x180)); // 0600
      }

      final loaded = await fileStore.load();
      expect(loaded, isNotNull);
      expect(loaded!.isWorkerMode, isTrue);
      expect(loaded.cookies, isEmpty);
      expect(loaded.toString(), isNot(contains(validKey)));
      expect(loaded.toString(), contains('hasApiKey: true'));

      // Logout clears local file without firing remote /logout on shared Worker
      final logoutRes = await _invokeCli(
        <String>['auth', 'logout', '--json'],
        store: fileStore,
        workerHttpClient: workerClient,
      );
      expect(logoutRes.exitCode, equals(0));
      expect(logoutRes.jsonMap['ok'], isTrue);
      expect(proxiedUrls.where((u) => u.contains('logout')), isEmpty);
      expect(await fileStore.load(), isNull);
    });

    test('multi-gateway auth worker (--name/--list/--use) + alias routing + logout --keep-workers', () async {
      final tmpDir = await Directory.systemTemp.createTemp('cl_multi_worker_');
      addTearDown(() => tmpDir.delete(recursive: true));
      final sessionPath = '${tmpDir.path}/session.json';
      final fileStore = FileCliSessionStore(filePath: sessionPath);
      final (workerClient, _) = buildMockWorkerGateway();
      const backupUrl = 'https://courselens-backup.example.workers.dev';
      const backupKey = 'clwk_backup_secret_key_9f2a';

      final saveMain = await _invokeCli(
        <String>[
          'auth',
          'worker',
          '--url',
          workerUrl,
          '--name',
          'main',
          '--api-key-stdin',
          '--json',
        ],
        store: fileStore,
        stdinLine: validKey,
        workerHttpClient: workerClient,
      );
      expect(saveMain.exitCode, equals(0), reason: saveMain.stderr);

      final saveBackup = await _invokeCli(
        <String>[
          'auth',
          'worker',
          '--url',
          backupUrl,
          '--name',
          'backup',
          '--api-key-stdin',
          '--no-verify',
          '--json',
        ],
        store: fileStore,
        stdinLine: backupKey,
        workerHttpClient: workerClient,
      );
      expect(saveBackup.exitCode, equals(0), reason: saveBackup.stderr);

      final listRes = await _invokeCli(
        <String>['auth', 'worker', '--list', '--json'],
        store: fileStore,
        workerHttpClient: workerClient,
      );
      expect(listRes.exitCode, equals(0), reason: listRes.stderr);
      expect(listRes.jsonMap['count'], equals(2));
      expect(listRes.stdout, isNot(contains(validKey)));
      expect(listRes.stdout, isNot(contains(backupKey)));
      final workers = (listRes.jsonMap['workers'] as List)
          .cast<Map<String, dynamic>>();
      for (final w in workers) {
        expect((w['keyHint'] as String).startsWith('••••'), isTrue);
      }

      // Currently active is backup; route explicitly via `--worker main` alias
      final aliasWhoami = await _invokeCli(
        <String>['--worker', 'main', 'whoami', '--json'],
        store: fileStore,
        workerHttpClient: workerClient,
      );
      expect(aliasWhoami.exitCode, equals(0), reason: aliasWhoami.stderr);
      expect(aliasWhoami.jsonMap['workerUrl'], equals(workerUrl));

      // Switch active worker back to `main` via `--use`
      final useMain = await _invokeCli(
        <String>['auth', 'worker', '--use', 'main', '--json'],
        store: fileStore,
        workerHttpClient: workerClient,
      );
      expect(useMain.exitCode, equals(0), reason: useMain.stderr);
      expect(useMain.jsonMap['workerUrl'], equals(workerUrl));

      // `auth logout --keep-workers` retires active session while preserving savedWorkers
      final keepLogout = await _invokeCli(
        <String>['auth', 'logout', '--keep-workers', '--json'],
        store: fileStore,
        workerHttpClient: workerClient,
      );
      expect(keepLogout.exitCode, equals(0), reason: keepLogout.stderr);
      final afterKeepLogout = await fileStore.load();
      expect(afterKeepLogout, isNotNull);
      expect(afterKeepLogout!.isWorkerMode, isFalse);
      expect(afterKeepLogout.savedWorkers.length, equals(2));
    });

    test('worker tasks (list/show/enable) & worker monitor set scoping (--grades/--exams/--interval/--reset-baseline)', () async {
      var gradesEnabled = false;
      var gradesInterval = 1800;
      Map<String, Object?>? lastMonitorPatch;

      Map<String, Object?> buildMonitorGradesSummary() => <String, Object?>{
            'taskId': 'monitor:grades',
            'type': 'MONITOR_GRADES',
            'title': '成绩变动定时检测',
            'subtitle': '定期检测新出分与成绩变更',
            'enabled': gradesEnabled,
            'status': gradesEnabled ? 'SCHEDULED' : 'DISABLED',
            'mode': 'PERIODIC',
            'intervalSec': gradesInterval,
            'lastSummary': gradesEnabled ? '已建立基线（12 门课）' : '默认关闭（零后台唤醒）',
            'trackedItemCount': 12,
            'changeCount': 0,
            'requiresWriteConfirmToRun': false,
          };

      Map<String, Object?> buildMonitorGradesDetail() => <String, Object?>{
            ...buildMonitorGradesSummary(),
            'metrics': <String, Object?>{
              'totalRuns': gradesEnabled ? 1 : 0,
              'trackedItemCount': 12,
              'changeCount': 0,
              'baselineInitialized': gradesEnabled,
              'lastDurationMs': 180,
              'lastError': '',
            },
            'recentChanges': const <Object?>[],
            'logs': <Map<String, Object?>>[
              <String, Object?>{
                'at': '2026-03-01T08:00:00Z',
                'status': 'OK',
                'message': '静默建立成绩指纹基线（12 门）',
                'durationMs': 180,
              },
            ],
          };

      final cloudClient = MockClient((req) async {
        if (req.headers['authorization'] != 'Bearer $validKey') {
          return http.Response('{"ok":false}', 401);
        }
        final p = req.url.path;
        if (p == '/v1/tasks' && req.method == 'GET') {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'ok': true,
                'lazyKeepaliveActive': true,
                'webhookConfigured': false,
                'nextAlarmAt': gradesEnabled ? '2026-03-01T08:15:00Z' : null,
                'activeTaskCount': gradesEnabled ? 1 : 0,
                'tasks': <Map<String, Object?>>[
                  buildMonitorGradesSummary(),
                  <String, Object?>{
                    'taskId': 'monitor:exams',
                    'type': 'MONITOR_EXAMS',
                    'title': '考场安排定时检测',
                    'enabled': false,
                    'status': 'DISABLED',
                    'mode': 'PERIODIC',
                    'intervalSec': 3600,
                    'lastSummary': '默认关闭',
                  },
                  <String, Object?>{
                    'taskId': 'session:keepalive',
                    'type': 'SESSION_KEEPALIVE',
                    'title': '纯 Cookie 会话主动心跳',
                    'enabled': false,
                    'status': 'DISABLED',
                    'mode': 'PERIODIC',
                    'intervalSec': 900,
                    'lastSummary': '默认关闭（密码模式自动按需懒保活）',
                  },
                ],
              }),
            ),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        if (p == '/v1/tasks/monitor%3Agrades' || p == '/v1/tasks/monitor:grades') {
          if (req.method == 'PATCH') {
            final patch = jsonDecode(req.body) as Map<String, Object?>;
            if (patch['enabled'] is bool) {
              gradesEnabled = patch['enabled'] as bool;
            }
            if (patch['intervalSec'] is int) {
              gradesInterval = patch['intervalSec'] as int;
            }
          }
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'ok': true,
                ...buildMonitorGradesDetail(),
              }),
            ),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        if (p == '/v1/monitor' && req.method == 'PATCH') {
          lastMonitorPatch = jsonDecode(req.body) as Map<String, Object?>;
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'ok': true,
                'grades': <String, Object?>{
                  'taskId': 'monitor:grades',
                  'kind': 'grades',
                  'enabled': true,
                  'intervalSec': 600,
                },
                'exams': <String, Object?>{
                  'taskId': 'monitor:exams',
                  'kind': 'exams',
                  'enabled': false,
                  'intervalSec': 3600,
                },
              }),
            ),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        return http.Response('Not Found: $p', 404);
      });

      const workerEnv = <String, String>{
        CliCredentialStore.envWorkerUrl: workerUrl,
        CliCredentialStore.envApiKey: validKey,
      };

      final tasksList = await _invokeCli(
        <String>['worker', 'tasks', 'list', '--json'],
        env: workerEnv,
        workerHttpClient: cloudClient,
      );
      expect(tasksList.exitCode, equals(0), reason: tasksList.stderr);
      expect(tasksList.jsonMap['lazyKeepaliveActive'], isTrue);
      expect(tasksList.jsonMap['activeTaskCount'], equals(0));

      final taskShow = await _invokeCli(
        <String>['worker', 'tasks', 'show', 'monitor:grades', '--json'],
        env: workerEnv,
        workerHttpClient: cloudClient,
      );
      expect(taskShow.exitCode, equals(0), reason: taskShow.stderr);
      expect(taskShow.jsonMap['taskId'], equals('monitor:grades'));

      final taskEnable = await _invokeCli(
        <String>[
          'worker',
          'tasks',
          'enable',
          'monitor:grades',
          '--interval',
          '900',
          '--json',
        ],
        env: workerEnv,
        workerHttpClient: cloudClient,
      );
      expect(taskEnable.exitCode, equals(0), reason: taskEnable.stderr);
      expect(taskEnable.jsonMap['enabled'], isTrue);
      expect(taskEnable.jsonMap['intervalSec'], equals(900));

      // Regression check: `--grades on --interval 600` MUST NOT touch `exams`
      final scopedSet = await _invokeCli(
        <String>[
          'worker',
          'monitor',
          'set',
          '--grades',
          'on',
          '--interval',
          '600',
          '--json',
        ],
        env: workerEnv,
        workerHttpClient: cloudClient,
      );
      expect(scopedSet.exitCode, equals(0), reason: scopedSet.stderr);
      expect(lastMonitorPatch, isNotNull);
      expect(lastMonitorPatch!.containsKey('grades'), isTrue);
      expect(lastMonitorPatch!.containsKey('exams'), isFalse);

      // Regression check: `--reset-baseline` alone resets both sub-monitors explicitly
      final resetBoth = await _invokeCli(
        <String>['worker', 'monitor', 'set', '--reset-baseline', '--json'],
        env: workerEnv,
        workerHttpClient: cloudClient,
      );
      expect(resetBoth.exitCode, equals(0), reason: resetBoth.stderr);
      expect(
        (lastMonitorPatch!['grades'] as Map<String, dynamic>)['resetBaseline'],
        isTrue,
      );
      expect(
        (lastMonitorPatch!['exams'] as Map<String, dynamic>)['resetBaseline'],
        isTrue,
      );
    });

    test('progress alias routes to plan and update --check --worker compares gateway version', () async {
      final progressDemo = await _invokeCli(
        <String>['progress', '--demo', '--json'],
      );
      expect(progressDemo.exitCode, equals(0), reason: progressDemo.stderr);
      expect(progressDemo.jsonMap['totalCourses'], equals(42));

      final mockHealthClient = MockClient((req) async {
        if (req.url.path == '/health') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': true,
              'service': 'courselens-session-gateway',
              'version': '1.0.0',
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });

      final updater = CliUpdater(
        environment: const <String, String>{
          CliCredentialStore.envWorkerUrl: workerUrl,
        },
        httpClient: mockHealthClient,
      );
      final report = await updater.run(
        CliArgs.parse(const <String>['update', '--check', '--worker', '--json']),
      );
      expect(report.hasError, isFalse);
      expect(report.components['worker']?.status, equals('update-available'));
    });
    test('zero-persistence COURSELENS_WORKER_URL + COURSELENS_API_KEY drives whoami, grades --stats, and select preview', () async {
      final (workerClient, proxiedUrls) = buildMockWorkerGateway();
      const workerEnv = <String, String>{
        CliCredentialStore.envWorkerUrl: workerUrl,
        CliCredentialStore.envApiKey: validKey,
      };

      final whoamiRes = await _invokeCli(
        <String>['whoami', '--json'],
        env: workerEnv,
        workerHttpClient: workerClient,
      );
      expect(whoamiRes.exitCode, equals(0), reason: whoamiRes.stderr);
      expect(whoamiRes.jsonMap['mode'], equals('worker'));
      expect(whoamiRes.jsonMap['workerUrl'], equals(workerUrl));
      expect(
        (whoamiRes.jsonMap['student'] as Map<String, dynamic>)['name'],
        equals('测试同学'),
      );

      final gradesRes = await _invokeCli(
        <String>['grades', '--stats', '--json'],
        env: workerEnv,
        workerHttpClient: workerClient,
      );
      expect(gradesRes.exitCode, equals(0), reason: gradesRes.stderr);
      expect((gradesRes.jsonMap['grades'] as List).length, equals(1));
      expect(
        (gradesRes.jsonMap['summary'] as Map<String, dynamic>)['weightedAverageScore'],
        equals('93.00'),
      );

      final selectPreview = await _invokeCli(
        <String>['--worker', workerUrl, 'select', '--course-id', 'GE108', '--json'],
        env: workerEnv,
        workerHttpClient: workerClient,
      );
      expect(selectPreview.exitCode, equals(2));
      expect(selectPreview.jsonMap['previewOnly'], isTrue);
      expect(
        selectPreview.jsonMap['confirmCommand'] as String,
        contains('--worker $workerUrl'),
      );
      expect(
        proxiedUrls.where((u) => u.contains('zzxkyzbjk_xkBcZyZzxkYzb')),
        isEmpty,
      );
    });
  });
}

