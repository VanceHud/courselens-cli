import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:courselens/core/courselens_core.dart';
import 'package:courselens/data/http/worker_session_http_engine.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

class _Utf8Decoder implements TextDecoder {
  const _Utf8Decoder();
  @override
  String decode(Uint8List bytes, String charset) =>
      utf8.decode(bytes, allowMalformed: true);
}

class _TestRandom implements SecureRandom {
  final Random _rng = Random(42);
  @override
  Uint8List bytes(int length) =>
      Uint8List.fromList(List<int>.generate(length, (_) => _rng.nextInt(256)));
}
void main() {
  group('WorkerSessionHttpEngine & AcademicClient Worker Mode', () {
    test('normalizeWorkerBaseUrl enforces HTTPS on public hosts and allows loopback HTTP', () {
      expect(
        WorkerSessionHttpEngine.normalizeWorkerBaseUrl(
          'https://courselens-session.example.workers.dev/',
        ),
        equals('https://courselens-session.example.workers.dev'),
      );
      expect(
        WorkerSessionHttpEngine.normalizeWorkerBaseUrl(
          'https://courselens-session.example.workers.dev/v1/proxy',
        ),
        equals('https://courselens-session.example.workers.dev'),
      );
      expect(
        WorkerSessionHttpEngine.normalizeWorkerBaseUrl(
          'http://127.0.0.1:8788/health',
        ),
        equals('http://127.0.0.1:8788'),
      );
      expect(
        WorkerSessionHttpEngine.normalizeWorkerBaseUrl(
          'http://localhost:8788/',
        ),
        equals('http://localhost:8788'),
      );

      // Redline #5: Refuse plaintext HTTP to non-loopback Worker gateway
      expect(
        () => WorkerSessionHttpEngine.normalizeWorkerBaseUrl(
          'http://insecure-worker.example.com',
        ),
        throwsA(
          isA<AcademicException>().having(
            (e) => e.status,
            'status',
            AcademicStatus.UNTRUSTED_URL,
          ),
        ),
      );

      // Refuse embedded userInfo and non-http(s) schemes
      for (final malicious in const <String>[
        'https://worker.example.workers.dev@evil.example.com',
        'javascript:alert(1)',
        'ftp://worker.example.workers.dev',
      ]) {
        expect(
          () => WorkerSessionHttpEngine.normalizeWorkerBaseUrl(malicious),
          throwsA(
            isA<AcademicException>().having(
              (e) => e.status,
              'status',
              AcademicStatus.UNTRUSTED_URL,
            ),
          ),
        );
      }
    });

    test('probeUrl distinguishes stateful session gateway from stateless Web relay', () async {
      final statefulClient = MockClient((req) async {
        expect(req.url.toString(), 'https://session.example.workers.dev/health');
        return http.Response(
          jsonEncode(<String, Object?>{
            'ok': true,
            'service': 'courselens-session-gateway',
            'mode': 'stateful-session',
            'version': 1,
          }),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });

      final okStatus = await WorkerSessionHttpEngine.probeUrl(
        'https://session.example.workers.dev',
        client: statefulClient,
      );
      expect(okStatus.ok, isTrue);
      expect(okStatus.service, equals('courselens-session-gateway'));

      final statelessRelayClient = MockClient((req) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'ok': true,
            'service': 'courselens-relay',
            'version': 1,
          }),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });

      final wrongService = await WorkerSessionHttpEngine.probeUrl(
        'https://relay.example.workers.dev',
        client: statelessRelayClient,
      );
      expect(wrongService.ok, isFalse);
      expect(wrongService.message, contains('无状态'));
    });

    test('fetchRemoteSession authenticates with Bearer API Key and maps 401 errors', () async {
      final client = MockClient((req) async {
        final auth = req.headers['authorization'] ?? '';
        if (auth != 'Bearer cl_live_key_123') {
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
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'ok': true,
              'authenticated': true,
              'systemId': 'zf',
              'baseUrl': 'https://jwglxt.qust.edu.cn/jwglxt',
              'casBaseUrl': '',
              'username': '2428050113',
              'identity': <String, String>{
                'name': '测试同学',
                'studentId': '2428050113',
                'department': '生物工程学院',
                'className': '合生241',
              },
            }),
          ),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      });

      final info = await WorkerSessionHttpEngine.fetchRemoteSession(
        workerBaseUrl: 'https://session.example.workers.dev',
        apiKey: 'cl_live_key_123',
        client: client,
      );
      expect(info.authenticated, isTrue);
      expect(info.system, equals(AcademicSystem.ZF));
      expect(info.baseUrl, equals('https://jwglxt.qust.edu.cn/jwglxt'));
      expect(info.identity.name, equals('测试同学'));
      expect(info.identity.studentId, equals('2428050113'));
      expect(info.keepaliveMode, equals('lazy'));
      expect(info.keepaliveIntervalSec, equals(0));

      await expectLater(
        WorkerSessionHttpEngine.fetchRemoteSession(
          workerBaseUrl: 'https://session.example.workers.dev',
          apiKey: 'wrong_key',
          client: client,
        ),
        throwsA(
          isA<AcademicException>().having(
            (e) => e.status,
            'status',
            AcademicStatus.INVALID_CREDENTIALS,
          ),
        ),
      );
    });

    test('WorkerRemoteSessionInfo.fromJson parses systemId into AcademicSystem with AUTO fallback', () {
      AcademicSystem parse(String? raw) => WorkerRemoteSessionInfo.fromJson(
            <String, dynamic>{'systemId': ?raw},
          ).system;

      expect(parse('ZF'), AcademicSystem.ZF);
      expect(parse('zf_old'), AcademicSystem.ZF_OLD);
      expect(parse(' QZ '), AcademicSystem.QZ);
      expect(parse('QZ_OLD'), AcademicSystem.QZ_OLD);
      expect(parse(null), AcademicSystem.AUTO);
      expect(parse(''), AcademicSystem.AUTO);
      expect(parse('unknown'), AcademicSystem.AUTO);
    });

    test('execute strips Cookie/Set-Cookie, sends Bearer key, and enforces Redlines #3 and #4', () async {
      Map<String, Object?>? capturedProxyPayload;
      String? capturedAuthHeader;

      final mockClient = MockClient((req) async {
        capturedAuthHeader = req.headers['authorization'];
        final body = jsonDecode(req.body) as Map<String, Object?>;
        capturedProxyPayload = body;
        final targetUrl = body['url'] as String;

        if (targetUrl.contains('timeout-post')) {
          throw TimeoutException('upstream read timeout');
        }
        if (targetUrl.contains('ssrf-blocked')) {
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': false,
              'status': 'UNTRUSTED_URL',
              'error': 'Target host is outside portal whitelist',
            }),
            403,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }

        return http.Response(
          jsonEncode(<String, Object?>{
            'ok': true,
            'status': 200,
            'finalUrl': targetUrl,
            'headers': <String, List<String>>{
              'content-type': <String>['application/json; charset=utf-8'],
              'set-cookie': <String>['JSESSIONID=SHOULD_BE_STRIPPED; HttpOnly'],
            },
            'bodyBase64': base64Encode(utf8.encode('{"kbList":[]}')),
          }),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });

      final rawEngine = WorkerSessionHttpEngine(
        workerBaseUrlProvider: () => 'https://session.example.workers.dev',
        apiKeyProvider: () => 'cl_secret_abc',
        client: mockClient,
      );
      final guarded = HostGuardedHttpEngine(
        rawEngine,
        allowedHosts: const <String>['jwglxt.qust.edu.cn'],
        requireSecure: true,
      );

      final resp = await guarded.execute(
        HttpRequest(
          method: HttpMethod.post,
          url: 'https://jwglxt.qust.edu.cn/jwglxt/kbcx/xskbcx_cxXsgrkb.html',
          headers: const <String, String>{
            'Cookie': 'JSESSIONID=LEAK_ATTEMPT',
            'Authorization': 'Basic bGVhaw==',
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: Uint8List.fromList(utf8.encode('xnm=2026&xqm=3')),
        ),
      );

      expect(capturedAuthHeader, equals('Bearer cl_secret_abc'));
      final forwardedHeaders =
          capturedProxyPayload!['headers'] as Map<String, Object?>;
      expect(forwardedHeaders.containsKey('Cookie'), isFalse);
      expect(forwardedHeaders.containsKey('Authorization'), isFalse);
      expect(
        forwardedHeaders['Content-Type'],
        equals('application/x-www-form-urlencoded'),
      );
      expect(resp.status, equals(200));
      expect(resp.cookies, isEmpty);
      expect(
        resp.headers.keys.any((k) => k.toLowerCase() == 'set-cookie'),
        isFalse,
      );
      expect(utf8.decode(resp.body), equals('{"kbList":[]}'));

      // Redline #3: POST timeout maps to RESULT_UNKNOWN (never retried automatically)
      await expectLater(
        guarded.execute(
          HttpRequest(
            method: HttpMethod.post,
            url: 'https://jwglxt.qust.edu.cn/jwglxt/timeout-post',
            body: Uint8List.fromList(utf8.encode('do_jxb_id=1')),
          ),
        ),
        throwsA(
          isA<AcademicException>().having(
            (e) => e.status,
            'status',
            AcademicStatus.RESULT_UNKNOWN,
          ),
        ),
      );

      // Redline #4 (Worker side): 403 UNTRUSTED_URL maps to UNTRUSTED_URL
      await expectLater(
        guarded.execute(
          HttpRequest(
            method: HttpMethod.get,
            url: 'https://jwglxt.qust.edu.cn/jwglxt/ssrf-blocked',
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

      // Redline #4 (Client side): HostGuardedHttpEngine blocks off-whitelist host locally
      await expectLater(
        guarded.execute(
          HttpRequest(
            method: HttpMethod.get,
            url: 'https://phishing.example.com/steal',
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

    test('AcademicClient stores Worker API Key in SecureStore and restores zero-cookie worker session', () async {
      final secureStore = InMemorySecureStore();
      final mockClient = MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, Object?>;
        return http.Response(
          jsonEncode(<String, Object?>{
            'ok': true,
            'status': 200,
            'finalUrl': body['url'],
            'headers': <String, List<String>>{
              'content-type': <String>['text/html; charset=utf-8'],
            },
            'bodyBase64': base64Encode(
              utf8.encode('<input id="xh_id" value="2428050113"/>'),
            ),
          }),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });

      AcademicClient buildClient() => AcademicClient(
            engine: WorkerSessionHttpEngine(
              workerBaseUrlProvider: () =>
                  'https://session.example.workers.dev',
              apiKeyProvider: () => 'cl_vault_key_999',
              client: mockClient,
            ),
            decoder: const _Utf8Decoder(),
            secureStore: secureStore,
            clock: () => 1800000000,
            random: _TestRandom(),
          );

      final writer = buildClient();
      await writer.saveWorkerApiKey('qust', '2428050113', 'cl_vault_key_999');
      await writer.bindRemoteManagedSession(
        schoolId: 'qust',
        accountKey: '2428050113',
        academicBaseUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
        username: '2428050113',
      );
      await writer.persistSession(
        const SavedAccount(
          schoolId: 'qust',
          accountKey: '2428050113',
          protocol: 'worker',
          baseUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
          workerUrl: 'https://session.example.workers.dev',
          username: '2428050113',
          systemId: 'zf',
        ),
      );

      // Simulate cold restart with fresh AcademicClient sharing SecureStore
      final reader = buildClient();
      final restored = await reader.restoreSavedSessions();
      expect(restored, hasLength(1));
      expect(restored.single.protocol, equals('worker'));
      expect(
        restored.single.workerUrl,
        equals('https://session.example.workers.dev'),
      );
      expect(
        await reader.loadWorkerApiKey('qust', '2428050113'),
        equals('cl_vault_key_999'),
      );
      expect(
        await reader.activeSessionBaseUrl('qust', '2428050113'),
        equals('https://jwglxt.qust.edu.cn/jwglxt'),
      );

      // Sign-out clears API key from SecureStore
      await reader.signOut('qust', '2428050113');
      expect(await reader.hasWorkerApiKey('qust', '2428050113'), isFalse);
    });
    test('SavedWorkerGateway masks API key hints and derives deterministic IDs', () {
      const urlA = 'https://gateway-a.example.workers.dev';
      const urlB = 'https://gateway-b.example.workers.dev';
      final gwA = SavedWorkerGateway(
        id: SavedWorkerGateway.deriveId(urlA),
        workerUrl: urlA,
        label: '主网关',
        schoolName: '青岛科技大学',
        accountKey: '2428050113',
        keyHint: SavedWorkerGateway.maskApiKeyHint('cl_secret_key_9f2a'),
        updatedAtEpochMs: 1700000001,
      );
      final gwB = SavedWorkerGateway(
        id: SavedWorkerGateway.deriveId(urlB),
        workerUrl: urlB,
        label: '备用网关',
        keyHint: SavedWorkerGateway.maskApiKeyHint('cl_secret_key_77bc'),
        updatedAtEpochMs: 1700000002,
      );
      expect(gwA.keyHint, equals('••••9f2a'));
      expect(gwB.keyHint, equals('••••77bc'));
      expect(gwA.id, isNot(equals(gwB.id)));
      expect(SavedWorkerGateway.fromJson(gwA.toJson()).workerUrl, equals(urlA));
    });

    test('Cloud tasks, cookies, webhook, and monitor parse and serialize cleanly', () async {
      final seenRequests = <String>[];
      final mockClient = MockClient((req) async {
        seenRequests.add('${req.method} ${req.url.path}');
        if (req.url.path == '/v1/tasks' && req.method == 'GET') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': true,
              'lazyKeepaliveActive': true,
              'hasPasswordAuth': true,
              'grabRunning': false,
              'webhookConfigured': true,
              'activeTaskCount': 0,
              'nextAlarmAt': null,
              'tasks': <Map<String, Object?>>[
                <String, Object?>{
                  'taskId': 'monitor:grades',
                  'type': 'MONITOR_GRADES',
                  'title': '成绩变动定时检测',
                  'enabled': false,
                  'status': 'DISABLED',
                  'intervalSec': 1800,
                  'lastSummary': '未开启（默认关闭）',
                },
                <String, Object?>{
                  'taskId': 'monitor:exams',
                  'type': 'MONITOR_EXAMS',
                  'title': '考场安排定时检测',
                  'enabled': false,
                  'status': 'DISABLED',
                  'intervalSec': 3600,
                  'lastSummary': '未开启（默认关闭）',
                },
                <String, Object?>{
                  'taskId': 'session:keepalive',
                  'type': 'SESSION_KEEPALIVE',
                  'title': '纯 Cookie 会话主动心跳',
                  'enabled': false,
                  'status': 'DISABLED',
                  'intervalSec': 900,
                  'lastSummary': '未开启（默认按需懒保活）',
                },
              ],
            }),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }
        if (req.url.path == '/v1/tasks/monitor%3Agrades' &&
            req.method == 'PATCH') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': true,
              'taskId': 'monitor:grades',
              'type': 'MONITOR_GRADES',
              'title': '成绩变动定时检测',
              'enabled': body['enabled'] == true,
              'status': body['enabled'] == true ? 'SCHEDULED' : 'DISABLED',
              'intervalSec': body['intervalSec'] ?? 1800,
              'metrics': <String, Object?>{
                'totalRuns': 1,
                'trackedItemCount': 12,
                'changeCount': 1,
              },
              'recentChanges': <Map<String, Object?>>[
                <String, Object?>{
                  'changeType': 'ADDED',
                  'courseName': '编译原理',
                  'score': '95',
                  'gpa': '4.50',
                },
              ],
              'logs': <Map<String, Object?>>[
                <String, Object?>{
                  'at': '2026-11-16T00:00:00Z',
                  'status': 'CHANGED',
                  'message': '检测到 1 门新出分课程',
                },
              ],
            }),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }
        if (req.url.path == '/v1/session/cookies' && req.method == 'POST') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': true,
              'authenticated': true,
              'alive': true,
              'injectedCookieCount': 2,
              'systemId': 'ZF',
              'baseUrl': 'https://jwglxt.qust.edu.cn/jwglxt',
              'username': '2428050113',
            }),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }
        if (req.url.path == '/v1/webhook' && req.method == 'PUT') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': true,
              'configured': true,
              'enabled': true,
              'provider': 'feishu',
              'resolvedProvider': 'feishu',
              'maskedUrl': 'https://open.feishu.cn/••••hook',
              'hasSecret': true,
            }),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }
        return http.Response('Not Found', 404);
      });

      const workerUrl = 'https://session.example.workers.dev';
      const apiKey = 'cl_live_key_123';

      // 1. Default OFF scheduled tasks + lazyKeepaliveActive
      final listSnap = await WorkerSessionHttpEngine.fetchCloudTasks(
        workerBaseUrl: workerUrl,
        apiKey: apiKey,
        client: mockClient,
      );
      expect(listSnap.lazyKeepaliveActive, isTrue);
      expect(listSnap.nextAlarmAt, isNull);
      expect(listSnap.tasks, hasLength(3));
      expect(listSnap.tasks.every((t) => !t.enabled), isTrue);

      // 2. Patch task & inspect detail
      final patched = await WorkerSessionHttpEngine.patchCloudTask(
        workerBaseUrl: workerUrl,
        apiKey: apiKey,
        taskId: 'monitor:grades',
        patch: const <String, Object?>{'enabled': true, 'intervalSec': 900},
        client: mockClient,
      );
      expect(patched.enabled, isTrue);
      expect(patched.intervalSec, equals(900));
      expect(patched.recentChanges.single.courseName, equals('编译原理'));
      expect(patched.logs.single.status, equals('CHANGED'));

      // 5. Dynamic cookie push & Webhook save
      final cookieInfo = await WorkerSessionHttpEngine.pushSessionCookies(
        workerBaseUrl: workerUrl,
        apiKey: apiKey,
        cookies: const <String, String>{'JSESSIONID': 'abc', 'route': 'r1'},
        portalUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
        client: mockClient,
      );
      expect(cookieInfo.injectedCookieCount, equals(2));

      final webhook = await WorkerSessionHttpEngine.saveWebhookConfig(
        workerBaseUrl: workerUrl,
        apiKey: apiKey,
        payload: const <String, Object?>{
          'enabled': true,
          'url': 'https://open.feishu.cn/open-apis/bot/v2/hook/secret',
          'provider': 'feishu',
          'secret': 'hmac-sec',
        },
        client: mockClient,
      );
      expect(webhook.configured, isTrue);
      expect(webhook.hasSecret, isTrue);
      expect(webhook.maskedUrl, contains('••••'));
    });

    test('HttpCacheScope.runBypassingCache propagates bypassCache without leaking headers, and /v1/cache APIs parse stats & clear', () async {
      expect(
        WorkerSessionHttpEngine.normalizeWorkerBaseUrl(
          'https://session.example.workers.dev/v1/cache',
        ),
        equals('https://session.example.workers.dev'),
      );
      expect(
        WorkerSessionHttpEngine.normalizeWorkerBaseUrl(
          'https://session.example.workers.dev/v1/selection',
        ),
        equals('https://session.example.workers.dev'),
      );

      final capturedProxyBodies = <Map<String, Object?>>[];
      final capturedSelectionBodies = <Map<String, Object?>>[];
      final seenControlCalls = <String>[];

      final mockClient = MockClient((req) async {
        if (req.url.path == '/v1/proxy' && req.method == 'POST') {
          final body = jsonDecode(req.body) as Map<String, Object?>;
          capturedProxyBodies.add(body);
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': true,
              'status': 200,
              'finalUrl': body['url'],
              'headers': const <String, List<String>>{
                'content-type': <String>['application/json'],
              },
              'bodyBase64': base64Encode(utf8.encode('{"kbList":[]}')),
            }),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }
        if (req.url.path == '/v1/selection' && req.method == 'POST') {
          final body = jsonDecode(req.body) as Map<String, Object?>;
          capturedSelectionBodies.add(body);
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': true,
              'status': 200,
              'finalUrl': body['url'],
              'headers': const <String, List<String>>{
                'content-type': <String>['application/json'],
              },
              'bodyBase64': base64Encode(utf8.encode('{"flag":"1"}')),
            }),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }
        if (req.url.path == '/v1/cache' && req.method == 'GET') {
          seenControlCalls.add('GET ${req.url.path}');
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': true,
              'enabled': true,
              'stats': const <String, Object?>{
                'entryCount': 3,
                'totalBytes': 4096,
                'hits': 12,
                'l1Hits': 9,
                'l2Hits': 3,
                'misses': 4,
                'bypasses': 1,
                'evictions': 0,
              },
              'categories': const <Map<String, Object?>>[
                <String, Object?>{
                  'category': 'schedule',
                  'ttlSec': 1800,
                  'activeEntries': 1,
                  'bytes': 2048,
                },
                <String, Object?>{
                  'category': 'grades',
                  'ttlSec': 300,
                  'activeEntries': 2,
                  'bytes': 2048,
                },
              ],
            }),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }
        if (req.url.path == '/v1/cache' && req.method == 'DELETE') {
          final query = req.url.query.isEmpty ? '' : '?${req.url.query}';
          seenControlCalls.add('DELETE ${req.url.path}$query');
          final isGrades = req.url.queryParameters['category'] == 'grades';
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': true,
              'clearedCount': isGrades ? 2 : 3,
            }),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }
        return http.Response('Not Found', 404);
      });

      const workerUrl = 'https://session.example.workers.dev';
      const apiKey = 'cl_cache_test_key';
      final engine = WorkerSessionHttpEngine(
        workerBaseUrlProvider: () => workerUrl,
        apiKeyProvider: () => apiKey,
        client: mockClient,
      );

      final request = HttpRequest(
        method: HttpMethod.post,
        url: 'https://jwglxt.qust.edu.cn/jwglxt/kbcx/xskbcx_cxXsgrkb.html',
        headers: const <String, String>{
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: Uint8List.fromList(utf8.encode('xnm=2026&xqm=3')),
      );

      // 1. Normal call omits bypassCache
      expect(HttpCacheScope.isBypassCache, isFalse);
      await engine.execute(request);
      expect(capturedProxyBodies, hasLength(1));
      expect(capturedProxyBodies.last.containsKey('bypassCache'), isFalse);

      // 2. Scoped bypass call sets bypassCache: true without mutating upstream headers
      await HttpCacheScope.runBypassingCache(() async {
        expect(HttpCacheScope.isBypassCache, isTrue);
        await engine.execute(request);
      });
      expect(HttpCacheScope.isBypassCache, isFalse);
      expect(capturedProxyBodies, hasLength(2));
      expect(capturedProxyBodies.last['bypassCache'], isTrue);
      final forwardedHeaders =
          capturedProxyBodies.last['headers'] as Map<String, Object?>;
      expect(
        forwardedHeaders.keys
            .any((k) => k.toLowerCase().contains('courselens')),
        isFalse,
      );

      // 3. confirmedSelection routes to /v1/selection with confirmed: true
      await engine.execute(
        HttpRequest(
          method: HttpMethod.post,
          url:
              'https://jwglxt.qust.edu.cn/jwglxt/xsxk/zzxkyzbjk_xkBcZyZzxkYzb.html',
          headers: const <String, String>{
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: Uint8List.fromList(utf8.encode('jxb_ids=JXB1')),
          confirmedSelection: true,
        ),
      );
      expect(capturedSelectionBodies, hasLength(1));
      expect(capturedSelectionBodies.single['confirmed'], isTrue);

      // 4. GET /v1/cache & DELETE /v1/cache
      final stats = await WorkerSessionHttpEngine.fetchCacheStats(
        workerBaseUrl: workerUrl,
        apiKey: apiKey,
        client: mockClient,
      );
      expect(stats.enabled, isTrue);
      expect(stats.entryCount, equals(3));
      expect(stats.totalBytes, equals(4096));
      expect(stats.formattedSize, equals('4.0 KB'));
      expect(stats.hits, equals(12));
      expect(stats.l1Hits, equals(9));
      expect(stats.l2Hits, equals(3));
      expect(stats.misses, equals(4));
      expect(stats.bypasses, equals(1));
      expect(stats.categories, hasLength(2));
      expect(stats.categories.first.category, equals('schedule'));
      expect(stats.categories.first.ttlSec, equals(1800));

      final clearedGrades = await WorkerSessionHttpEngine.clearRemoteCache(
        workerBaseUrl: workerUrl,
        apiKey: apiKey,
        category: 'grades',
        client: mockClient,
      );
      expect(clearedGrades, equals(2));

      final clearedAll = await WorkerSessionHttpEngine.clearRemoteCache(
        workerBaseUrl: workerUrl,
        apiKey: apiKey,
        client: mockClient,
      );
      expect(clearedAll, equals(3));
      expect(
        seenControlCalls,
        equals(const <String>[
          'GET /v1/cache',
          'DELETE /v1/cache?category=grades',
          'DELETE /v1/cache',
        ]),
      );
    });
  });
}
