import 'dart:convert';
import 'dart:io';

import 'package:courselens/cli/store/cli_session_store.dart';
import 'package:test/test.dart';

class _FakeKeychainBackend {
  final List<List<String>> invocations = <List<String>>[];
  final Map<String, String> items = <String, String>{};
  int? forcedExitCode;
  String forcedStderr = '';
  Object? thrownError;
  bool returnHexOnFind = false;

  Future<ProcessResult> run(String executable, List<String> args) async {
    expect(executable, KeychainCliSessionStore.securityExecutable);
    invocations.add(List<String>.unmodifiable(args));

    if (thrownError != null) {
      // ignore: only_throw_errors
      throw thrownError!;
    }
    if (forcedExitCode != null) {
      return ProcessResult(1, forcedExitCode!, '', forcedStderr);
    }

    final subcommand = args.first;
    final service = _argAfter(args, '-s') ?? '';
    final account = _argAfter(args, '-a') ?? '';
    final key = '$service|$account';

    switch (subcommand) {
      case 'find-generic-password':
        final secret = items[key];
        if (secret == null) {
          return ProcessResult(
            1,
            44,
            '',
            'security: SecKeychainSearchCopyNext: '
                'The specified item could not be found in the keychain.',
          );
        }
        if (returnHexOnFind) {
          final hex = utf8
              .encode(secret)
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
          return ProcessResult(1, 0, '$hex\n', '');
        }
        return ProcessResult(1, 0, '$secret\n', '');

      case 'add-generic-password':
        expect(args, contains('-U'));
        final secret = _argAfter(args, '-w');
        expect(secret, isNotNull);
        items[key] = secret!;
        return ProcessResult(1, 0, '', '');

      case 'delete-generic-password':
        final existed = items.remove(key) != null;
        if (!existed) {
          return ProcessResult(
            1,
            44,
            '',
            'security: SecKeychainSearchCopyNext: '
                'The specified item could not be found in the keychain.',
          );
        }
        return ProcessResult(1, 0, '', '');

      default:
        return ProcessResult(1, 2, '', 'Unknown subcommand $subcommand');
    }
  }

  static String? _argAfter(List<String> args, String flag) {
    final idx = args.indexOf(flag);
    if (idx < 0 || idx + 1 >= args.length) return null;
    return args[idx + 1];
  }
}

void main() {
  group('Pure Dart guard for lib/cli/store', () {
    test('contains zero package:flutter/ or web-only imports', () {
      final dir = Directory('lib/cli/store');
      expect(dir.existsSync(), isTrue);
      final files = dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      expect(files.length, greaterThanOrEqualTo(4));

      const forbidden = <String>[
        'package:flutter/',
        'dart:html',
        'dart:js_interop',
      ];
      for (final file in files) {
        final content = file.readAsStringSync();
        for (final token in forbidden) {
          expect(
            content.contains(token),
            isFalse,
            reason: '${file.path} must not import $token',
          );
        }
      }
    });
  });

  group('CliStoreKind, CliStorageUnavailableException & CliSessionRecord', () {
    test('parses CliStoreKind values and formats exception prefix', () {
      expect(CliStoreKind.values, <CliStoreKind>[
        CliStoreKind.auto,
        CliStoreKind.keychain,
        CliStoreKind.file,
        CliStoreKind.env,
      ]);
      expect(CliStoreKind.parse('KEYCHAIN'), CliStoreKind.keychain);
      expect(CliStoreKind.tryParse('  file '), CliStoreKind.file);
      expect(CliStoreKind.tryParse('invalid'), isNull);
      expect(() => CliStoreKind.parse('invalid'), throwsFormatException);

      const err = CliStorageUnavailableException('keychain locked');
      expect(err.message, 'keychain locked');
      expect(err.toString(), 'STORAGE_UNAVAILABLE: keychain locked');
    });

    test('serializes, deserializes, copies, and never persists password', () {
      final ts = DateTime.utc(2026, 9, 1, 8, 30, 0);
      final record = CliSessionRecord(
        baseUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
        username: '24000101',
        password: 'ephemeral-secret-password',
        systemType: 'ZF',
        cookies: <String, String>{'JSESSIONID': 'SID1', 'route': 'r1'},
        relayUrl: 'http://127.0.0.1:8787',
        updatedAt: ts,
        backendName: 'env',
      );

      expect(record.cookieHeader, 'JSESSIONID=SID1; route=r1');
      expect(() => record.cookies['x'] = 'y', throwsUnsupportedError);
      expect(record.toString(), isNot(contains('ephemeral-secret-password')));
      expect(record.toString(), isNot(contains('SID1')));

      final json = record.toJson();
      expect(json.containsKey('password'), isFalse);
      expect(json['baseUrl'], 'https://jwglxt.qust.edu.cn/jwglxt');
      expect(json['updatedAt'], '2026-09-01T08:30:00.000Z');

      final restored = CliSessionRecord.fromJson(json);
      expect(restored.baseUrl, record.baseUrl);
      expect(restored.username, '24000101');
      expect(restored.password, isNull);
      expect(restored.systemType, 'ZF');
      expect(restored.cookies, <String, String>{
        'JSESSIONID': 'SID1',
        'route': 'r1',
      });
      expect(restored.relayUrl, 'http://127.0.0.1:8787');
      expect(restored.updatedAt, ts);
      expect(restored.backendName, 'env');

      final updated = restored.copyWith(
        systemType: 'ZF_OLD',
        clearRelayUrl: true,
      );
      expect(updated.systemType, 'ZF_OLD');
      expect(updated.relayUrl, isNull);
      expect(updated.username, '24000101');

      expect(
        () => CliSessionRecord.fromJson(<String, Object?>{'baseUrl': '  '}),
        throwsFormatException,
      );
    });
  });

  group('CliCredentialStore.resolve & EnvCliSessionStore', () {
    test('auto-resolves env, macOS keychain, Linux file, and explicit file', () {
      final macDefault = CliCredentialStore.resolve(
        operatingSystem: 'macos',
        environment: <String, String>{'HOME': '/opt/tester'},
      );
      expect(macDefault, isA<KeychainCliSessionStore>());
      expect(CliCredentialStore.defaultKeychainService, 'dev.courselens.cli');

      final linuxDefault = CliCredentialStore.resolve(
        operatingSystem: 'linux',
        environment: <String, String>{'HOME': '/home/tester'},
      );
      expect(linuxDefault, isA<FileCliSessionStore>());
      expect(
        (linuxDefault as FileCliSessionStore).filePath,
        '/home/tester/.config/courselens/session.json',
      );

      final autoEnv = CliCredentialStore.resolve(
        operatingSystem: 'macos',
        environment: <String, String>{
          'HOME': '/opt/tester',
          'COURSELENS_BASE_URL': 'https://jwglxt.qust.edu.cn/jwglxt',
          'COURSELENS_COOKIES': 'JSESSIONID=env_sid',
        },
      );
      expect(autoEnv, isA<EnvCliSessionStore>());

      final explicitSessionFile = CliCredentialStore.resolve(
        operatingSystem: 'macos',
        sessionFilePath: '/tmp/custom-session.json',
        environment: <String, String>{
          'COURSELENS_BASE_URL': 'https://jwglxt.qust.edu.cn/jwglxt',
          'COURSELENS_COOKIES': 'JSESSIONID=env_sid',
        },
      );
      expect(explicitSessionFile, isA<FileCliSessionStore>());
      expect(
        (explicitSessionFile as FileCliSessionStore).filePath,
        '/tmp/custom-session.json',
      );
    });

    test('parses COURSELENS_* env vars and rejects save/clear as read-only',
        () async {
      final fixedTime = DateTime.utc(2026, 10, 12, 9, 0, 0);
      final store = CliCredentialStore.resolve(
        kind: CliStoreKind.env,
        now: () => fixedTime,
        environment: <String, String>{
          'COURSELENS_BASE_URL': 'https://jwglxt.qust.edu.cn/jwglxt',
          'COURSELENS_USERNAME': '2428050113',
          'COURSELENS_PASSWORD': 'my_password_!@#',
          'COURSELENS_COOKIES': 'Cookie: JSESSIONID=ABC123; route=node2',
          'COURSELENS_SCHOOL_TYPE': 'ZF',
          'COURSELENS_RELAY_URL': 'https://relay.example.workers.dev',
        },
      );

      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.baseUrl, 'https://jwglxt.qust.edu.cn/jwglxt');
      expect(loaded.username, '2428050113');
      expect(loaded.password, 'my_password_!@#');
      expect(loaded.systemType, 'ZF');
      expect(loaded.relayUrl, 'https://relay.example.workers.dev');
      expect(loaded.cookies, <String, String>{
        'JSESSIONID': 'ABC123',
        'route': 'node2',
      });
      expect(loaded.updatedAt, fixedTime);
      expect(loaded.backendName, 'env');

      await expectLater(
        store.save(loaded),
        throwsA(
          isA<CliStorageUnavailableException>().having(
            (e) => e.toString(),
            'toString',
            allOf(startsWith('STORAGE_UNAVAILABLE:'), contains('read-only')),
          ),
        ),
      );
      await expectLater(
        store.clear(),
        throwsA(
          isA<CliStorageUnavailableException>().having(
            (e) => e.message,
            'message',
            contains('read-only'),
          ),
        ),
      );
    });

    test('env store returns null when incomplete and rejects invalid URL',
        () async {
      final emptyEnv = CliCredentialStore.resolve(
        kind: CliStoreKind.env,
        environment: const <String, String>{
          'COURSELENS_BASE_URL': 'https://jwglxt.qust.edu.cn/jwglxt',
        },
      );
      expect(await emptyEnv.load(), isNull);

      final invalidUrlEnv = CliCredentialStore.resolve(
        kind: CliStoreKind.env,
        environment: const <String, String>{
          'COURSELENS_BASE_URL': 'not-a-valid-url',
          'COURSELENS_USERNAME': '24001',
        },
      );
      await expectLater(
        invalidUrlEnv.load(),
        throwsA(isA<CliStorageUnavailableException>()),
      );
    });
  });

  group('KeychainCliSessionStore (mocked security + Redline #1)', () {
    test('saves, loads (including Unicode & hex), and clears Keychain item',
        () async {
      final fake = _FakeKeychainBackend();
      final store = CliCredentialStore.resolve(
        kind: CliStoreKind.keychain,
        operatingSystem: 'macos',
        processRunner: fake.run,
      );

      // Missing item returns null, clear on missing item is idempotent.
      expect(await store.load(), isNull);
      await store.clear();

      final record = CliSessionRecord(
        baseUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
        username: '演示同学_2401',
        systemType: 'ZF',
        cookies: const <String, String>{'JSESSIONID': 'KC_999'},
        updatedAt: DateTime.utc(2026, 11, 15, 12, 0),
      );
      await store.save(record);

      final savedKey =
          '${CliCredentialStore.defaultKeychainService}|${CliCredentialStore.defaultKeychainAccount}';
      expect(fake.items.containsKey(savedKey), isTrue);
      // Stored payload must be pure printable ASCII JSON so `security -w` never mangles it.
      final rawStored = fake.items[savedKey]!;
      expect(rawStored.startsWith('{'), isTrue);
      expect(
        rawStored.codeUnits.every((c) => c >= 0x20 && c <= 0x7E),
        isTrue,
      );

      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.username, '演示同学_2401');
      expect(loaded.cookies, const <String, String>{'JSESSIONID': 'KC_999'});
      expect(loaded.backendName, 'keychain');

      // Also decode hex output when `security -w` emits hex bytes.
      fake.returnHexOnFind = true;
      final loadedFromHex = await store.load();
      expect(loadedFromHex, isNotNull);
      expect(loadedFromHex!.username, '演示同学_2401');

      await store.clear();
      expect(await store.load(), isNull);
    });

    test(
        'Redline #1: Keychain failures throw CliStorageUnavailableException '
        'and NEVER fall back to plaintext session.json', () async {
      final tempHome = await Directory.systemTemp.createTemp('courselens_kc_');
      addTearDown(() async {
        if (await tempHome.exists()) {
          await tempHome.delete(recursive: true);
        }
      });

      final fake = _FakeKeychainBackend()
        ..forcedExitCode = 36
        ..forcedStderr =
            'security: SecKeychainItemCopyContent: User interaction is not allowed.';

      final store = CliCredentialStore.resolve(
        kind: CliStoreKind.auto,
        operatingSystem: 'macos',
        environment: <String, String>{'HOME': tempHome.path},
        processRunner: fake.run,
      );
      expect(store, isA<KeychainCliSessionStore>());

      await expectLater(
        store.load(),
        throwsA(
          isA<CliStorageUnavailableException>().having(
            (e) => e.toString(),
            'toString',
            allOf(
              startsWith('STORAGE_UNAVAILABLE:'),
              contains('User interaction is not allowed'),
            ),
          ),
        ),
      );

      final sample = CliSessionRecord(
        baseUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
        cookies: const <String, String>{'JSESSIONID': 'SECRET'},
      );
      await expectLater(
        store.save(sample),
        throwsA(isA<CliStorageUnavailableException>()),
      );
      await expectLater(
        store.clear(),
        throwsA(isA<CliStorageUnavailableException>()),
      );

      // Verify zero silent fallback files were created under $HOME/.config.
      final fallbackFile =
          File('${tempHome.path}/.config/courselens/session.json');
      expect(await fallbackFile.exists(), isFalse);

      // Process launch failure also maps to CliStorageUnavailableException.
      final brokenStore = KeychainCliSessionStore(
        operatingSystem: 'macos',
        processRunner: (_, _) async =>
            throw const ProcessException('/usr/bin/security', <String>[]),
      );
      await expectLater(
        brokenStore.load(),
        throwsA(isA<CliStorageUnavailableException>()),
      );

      // Non-macOS invocation of Keychain store fails closed.
      final linuxKeychain = KeychainCliSessionStore(
        operatingSystem: 'linux',
        processRunner: fake.run,
      );
      await expectLater(
        linuxKeychain.load(),
        throwsA(isA<CliStorageUnavailableException>()),
      );
    });
  });

  group('FileCliSessionStore (POSIX 0700/0600 enforcement)', () {
    test('creates 0700 parent dir and 0600 session file, loads, and clears',
        () async {
      final tempRoot =
          await Directory.systemTemp.createTemp('courselens_file_store_');
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final sessionPath = '${tempRoot.path}/nested/courselens/session.json';
      final store = CliCredentialStore.resolve(
        kind: CliStoreKind.file,
        sessionFilePath: sessionPath,
        operatingSystem: 'linux',
      );

      expect(await store.load(), isNull);

      final record = CliSessionRecord(
        baseUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
        username: '2428050113',
        systemType: 'ZF',
        cookies: const <String, String>{'JSESSIONID': 'FILE_SID_1'},
        updatedAt: DateTime.utc(2026, 11, 15, 10, 0),
      );
      await store.save(record);

      final dirStat = await Directory('${tempRoot.path}/nested/courselens').stat();
      final fileStat = await File(sessionPath).stat();
      expect(dirStat.mode & 0x1ff, 0x1c0); // 0700
      expect(fileStat.mode & 0x1ff, 0x180); // 0600
      expect(fileStat.mode & 0x3f, 0);

      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.baseUrl, record.baseUrl);
      expect(loaded.username, '2428050113');
      expect(loaded.cookies, const <String, String>{'JSESSIONID': 'FILE_SID_1'});
      expect(loaded.backendName, 'file');

      await store.clear();
      expect(await File(sessionPath).exists(), isFalse);
      expect(await store.load(), isNull);
    });

    test(
        'Redline #1: refuses 0644 / group-readable session files and instructs '
        'user to run chmod 600', () async {
      final tempRoot =
          await Directory.systemTemp.createTemp('courselens_bad_perm_');
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final sessionPath = '${tempRoot.path}/session.json';
      final store = CliCredentialStore.resolve(
        kind: CliStoreKind.file,
        sessionFilePath: sessionPath,
        operatingSystem: 'linux',
      );

      await store.save(
        CliSessionRecord(
          baseUrl: 'https://jwglxt.qust.edu.cn/jwglxt',
          cookies: const <String, String>{'JSESSIONID': 'LEAKED_IF_READ'},
        ),
      );

      // Widen permissions to 0644 and verify load() refuses immediately.
      final chmodRes =
          await Process.run('chmod', <String>['0644', sessionPath]);
      expect(chmodRes.exitCode, 0);

      await expectLater(
        store.load(),
        throwsA(
          isA<CliStorageUnavailableException>().having(
            (e) => e.toString(),
            'toString',
            allOf(
              startsWith('STORAGE_UNAVAILABLE:'),
              contains('0644'),
              contains('chmod 600'),
            ),
          ),
        ),
      );

      // Also reject 0640 (group-readable only).
      await Process.run('chmod', <String>['0640', sessionPath]);
      await expectLater(
        store.load(),
        throwsA(
          isA<CliStorageUnavailableException>().having(
            (e) => e.message,
            'message',
            contains('chmod 600'),
          ),
        ),
      );
    });
  });

  group('CookieHarParser.extract', () {
    final qustUri = Uri.parse('https://jwglxt.qust.edu.cn/jwglxt');

    test('extracts raw Cookie headers, Set-Cookie lines, and Base64 values', () {
      final cookies = CookieHarParser.extract(
        cookieHeader:
            'Cookie: JSESSIONID=ABCDEF123; CASTGC="TGT-99-xyz=="; route=node1',
        targetBaseUri: qustUri,
      );
      expect(cookies, <String, String>{
        'JSESSIONID': 'ABCDEF123',
        'CASTGC': 'TGT-99-xyz==',
        'route': 'node1',
      });

      final fromSetCookie = CookieHarParser.extract(
        cookieHeader:
            'Set-Cookie: JSESSIONID=NEW_SID; Path=/jwglxt; HttpOnly; Secure',
        targetBaseUri: qustUri,
      );
      expect(fromSetCookie, <String, String>{'JSESSIONID': 'NEW_SID'});
    });

    test('extracts JSON object and Cookie-Editor JSON array', () {
      final fromMap = CookieHarParser.extract(
        cookieHeader: '{"JSESSIONID": "J_SID", "route": "2"}',
        targetBaseUri: qustUri,
      );
      expect(fromMap, <String, String>{'JSESSIONID': 'J_SID', 'route': '2'});

      final fromArray = CookieHarParser.extract(
        cookieHeader: jsonEncode(<Map<String, Object?>>[
          <String, Object?>{
            'name': 'JSESSIONID',
            'value': 'ARR_SID',
            'domain': 'jwglxt.qust.edu.cn',
          },
          <String, Object?>{
            'name': 'other_school',
            'value': 'bad',
            'domain': 'jwglxt.pku.edu.cn',
          },
        ]),
        targetBaseUri: qustUri,
      );
      expect(fromArray, <String, String>{'JSESSIONID': 'ARR_SID'});
    });

    test(
        'extracts .har cookies across same .edu.cn registrable institution, '
        'rejects cross-school/third-party hosts, and enforces newest-wins', () {
      final har = jsonEncode(<String, Object?>{
        'log': <String, Object?>{
          'version': '1.2',
          'entries': <Map<String, Object?>>[
            // 1. Pre-login stale cookie on target host + deleted via Max-Age=0
            <String, Object?>{
              'startedDateTime': '2026-09-01T10:00:00.000Z',
              'request': <String, Object?>{
                'url': 'https://jwglxt.qust.edu.cn/jwglxt/xtgl/login_slogin.html',
                'headers': <Map<String, String>>[
                  <String, String>{
                    'name': 'Cookie',
                    'value': 'JSESSIONID=STALE_0; temp_tok=gone',
                  },
                ],
                'cookies': <Object?>[],
              },
              'response': <String, Object?>{
                'headers': <Map<String, String>>[
                  <String, String>{
                    'name': 'Set-Cookie',
                    'value': 'temp_tok=deleteMe; Path=/; Max-Age=0',
                  },
                ],
                'cookies': <Object?>[],
              },
            },
            // 2. Institutional SSO subdomain (sso.qust.edu.cn) sets CASTGC & its own JSESSIONID
            <String, Object?>{
              'startedDateTime': '2026-09-01T10:00:02.000Z',
              'request': <String, Object?>{
                'url': 'https://sso.qust.edu.cn/cas/login',
                'headers': <Object?>[],
                'cookies': <Object?>[],
              },
              'response': <String, Object?>{
                'headers': <Map<String, String>>[
                  <String, String>{
                    'name': 'Set-Cookie',
                    'value': 'CASTGC=TGT-OLD; Path=/cas; Secure; HttpOnly',
                  },
                  <String, String>{
                    'name': 'Set-Cookie',
                    'value':
                        'portal_token=PT_1; Domain=.qust.edu.cn; Path=/; Secure',
                  },
                ],
                'cookies': <Object?>[],
              },
            },
            // 3. Target host establishes authenticated JSESSIONID=LIVE_1, then LIVE_2
            <String, Object?>{
              'startedDateTime': '2026-09-01T10:00:03.000Z',
              'request': <String, Object?>{
                'url':
                    'https://jwglxt.qust.edu.cn/jwglxt/sso/ticket?ticket=ST-1',
                'headers': <Object?>[],
                'cookies': <Object?>[],
              },
              'response': <String, Object?>{
                'headers': <Map<String, String>>[
                  <String, String>{
                    'name': 'Set-Cookie',
                    'value': 'JSESSIONID=LIVE_1; Path=/jwglxt; HttpOnly',
                  },
                ],
                'cookies': <Object?>[],
              },
            },
            <String, Object?>{
              'startedDateTime': '2026-09-01T10:00:05.000Z',
              'request': <String, Object?>{
                'url':
                    'https://jwglxt.qust.edu.cn/jwglxt/xtgl/index_initMenu.html',
                'headers': <Map<String, String>>[
                  <String, String>{
                    'name': 'cookie',
                    'value': 'JSESSIONID=LIVE_1; route=backend_a',
                  },
                ],
                'cookies': <Object?>[],
              },
              'response': <String, Object?>{
                'headers': <Map<String, String>>[
                  <String, String>{
                    'name': 'set-cookie',
                    'value': 'JSESSIONID=LIVE_2; Path=/jwglxt; HttpOnly',
                  },
                ],
                'cookies': <Map<String, Object?>>[
                  <String, Object?>{
                    'name': 'route',
                    'value': 'backend_b',
                    'domain': 'jwglxt.qust.edu.cn',
                  },
                ],
              },
            },
            // 4. Later SSO ping updates CASTGC and sends SSO's own JSESSIONID
            //    (must update CASTGC to TGT-NEW without clobbering jwglxt's JSESSIONID=LIVE_2!)
            <String, Object?>{
              'startedDateTime': '2026-09-01T10:00:06.000Z',
              'request': <String, Object?>{
                'url': 'https://sso.qust.edu.cn/cas/status',
                'headers': <Map<String, String>>[
                  <String, String>{
                    'name': 'Cookie',
                    'value': 'JSESSIONID=CAS_ONLY_SID; CASTGC=TGT-NEW',
                  },
                ],
                'cookies': <Object?>[],
              },
              'response': <String, Object?>{
                'headers': <Object?>[],
                'cookies': <Object?>[],
              },
            },
            // 5. Unrelated .edu.cn university & third-party analytics must be ignored
            <String, Object?>{
              'startedDateTime': '2026-09-01T10:00:07.000Z',
              'request': <String, Object?>{
                'url': 'https://jwglxt.tsinghua.edu.cn/jwglxt/index',
                'headers': <Map<String, String>>[
                  <String, String>{
                    'name': 'Cookie',
                    'value': 'JSESSIONID=WRONG_SCHOOL; leak=1',
                  },
                ],
                'cookies': <Object?>[],
              },
              'response': <String, Object?>{
                'headers': <Map<String, String>>[
                  <String, String>{
                    'name': 'Set-Cookie',
                    'value': 'super=bad; Domain=.edu.cn; Path=/',
                  },
                ],
                'cookies': <Object?>[],
              },
            },
            <String, Object?>{
              'startedDateTime': '2026-09-01T10:00:08.000Z',
              'request': <String, Object?>{
                'url': 'https://hm.baidu.com/hm.js',
                'headers': <Map<String, String>>[
                  <String, String>{'name': 'Cookie', 'value': 'HMACCOUNT=999'},
                ],
                'cookies': <Object?>[],
              },
              'response': <String, Object?>{
                'headers': <Object?>[],
                'cookies': <Object?>[],
              },
            },
          ],
        },
      });

      final extracted = CookieHarParser.extract(
        harContent: har,
        targetBaseUri: qustUri,
      );

      expect(extracted, <String, String>{
        'JSESSIONID': 'LIVE_2',
        'route': 'backend_b',
        'CASTGC': 'TGT-NEW',
        'portal_token': 'PT_1',
      });
      expect(extracted.containsKey('temp_tok'), isFalse);
      expect(extracted.containsKey('leak'), isFalse);
      expect(extracted.containsKey('super'), isFalse);
      expect(extracted.containsKey('HMACCOUNT'), isFalse);
    });

    test('IP literal target only accepts exact IP host in HAR', () {
      final har = jsonEncode(<String, Object?>{
        'log': <String, Object?>{
          'entries': <Map<String, Object?>>[
            <String, Object?>{
              'request': <String, Object?>{
                'url': 'http://10.10.2.15:8080/jwglxt/',
                'headers': <Map<String, String>>[
                  <String, String>{'name': 'Cookie', 'value': 'sid=ok'},
                ],
              },
              'response': <String, Object?>{},
            },
            <String, Object?>{
              'request': <String, Object?>{
                'url': 'http://10.10.2.16:8080/jwglxt/',
                'headers': <Map<String, String>>[
                  <String, String>{'name': 'Cookie', 'value': 'sid=wrong_ip'},
                ],
              },
              'response': <String, Object?>{},
            },
          ],
        },
      });

      final extracted = CookieHarParser.extract(
        harContent: har,
        targetBaseUri: Uri.parse('http://10.10.2.15:8080/jwglxt'),
      );
      expect(extracted, <String, String>{'sid': 'ok'});
    });
  });
}
