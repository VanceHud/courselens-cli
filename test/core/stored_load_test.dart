import 'dart:convert';
import 'dart:typed_data';

import 'package:courselens/core/courselens_core.dart';
import 'package:test/test.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

SavedAccount _acc(int i) => SavedAccount(
      schoolId: 's$i',
      accountKey: 'u$i',
      protocol: 'jwglxt',
      baseUrl: 'https://jw$i.example.edu.cn',
    );

void main() {
  group('decodeStoredJson', () {
    test('distinguishes absent, ok and corrupt', () {
      Object? parse(Object? json) => json;
      expect(
        decodeStoredJson<Object?>(null, empty: () => null, parse: parse).state,
        StoredLoadState.absent,
      );
      expect(
        decodeStoredJson<Object?>('{}', empty: () => null, parse: parse).state,
        StoredLoadState.ok,
      );
      final corrupt = decodeStoredJson<Object?>(
        '{not json',
        empty: () => 0,
        parse: parse,
      );
      expect(corrupt.isCorrupt, isTrue);
      expect(corrupt.value, 0);
      expect(corrupt.error, isA<FormatException>());
      expect(
        decodeStoredJsonBytes<Object?>(
          Uint8List.fromList(<int>[0xff, 0xfe]),
          empty: () => null,
          parse: parse,
        ).isCorrupt,
        isTrue,
      );
    });
  });

  group('SessionArchive corrupt blob', () {
    const key = 'sessions.v1.test';

    test(
      'reads as empty but save backs up raw bytes before overwriting',
      () async {
        final store = InMemorySecureStore();
        await store.put(key, _bytes('{corrupt'));
        final archive = SessionArchive(store: store, service: 'test');

        expect(await archive.accounts(), isEmpty);
        expect(await archive.count(), 0);
        expect(await store.get(corruptBackupKey(key)), isNull);

        expect(await archive.save(_acc(1), const []), isTrue);
        expect(
          utf8.decode((await store.get(corruptBackupKey(key)))!),
          '{corrupt',
        );
        expect((await archive.accounts()).single.accountKey, 'u1');
      },
    );

    test(
      'remove of last account backs up a corrupt blob before deleting',
      () async {
        final store = InMemorySecureStore();
        await store.put(key, _bytes('[1,2]'));
        final archive = SessionArchive(store: store, service: 'test');

        await archive.remove('s1', 'u1');
        expect(await store.get(key), isNull);
        expect(utf8.decode((await store.get(corruptBackupKey(key)))!), '[1,2]');
      },
    );

    test('valid blob never creates a backup', () async {
      final store = InMemorySecureStore();
      final archive = SessionArchive(store: store, service: 'test');
      await archive.save(_acc(1), const []);
      await archive.save(_acc(2), const []);
      await archive.setActive('s1', 'u1');
      await archive.remove('s1', 'u1');
      await archive.remove('s2', 'u2');
      expect(store.count(), 0);
    });

    test('backs up non-list sessions field before saving', () async {
      final store = InMemorySecureStore();
      await store.put(key, _bytes('{"active":"","sessions":"bad"}'));
      final archive = SessionArchive(store: store, service: 'test');

      expect(await archive.accounts(), isEmpty);
      expect(await archive.save(_acc(1), const []), isTrue);
      expect(
        utf8.decode((await store.get(corruptBackupKey(key)))!),
        '{"active":"","sessions":"bad"}',
      );
    });
  });

  test('clear/forgetAll also erase corrupt backups', () async {
    final store = InMemorySecureStore();
    await store.put('sessions.v1.test', _bytes('bad'));
    await store.put('credentials.v1.test', _bytes('bad'));
    final archive = SessionArchive(store: store, service: 'test');
    final vault = CredentialVault(store: store, service: 'test');
    await archive.save(_acc(1), const []);
    await vault.save('s1', 'u1', 'pw');
    expect(store.count(), 4);

    await archive.clear();
    await vault.forgetAll();
    expect(store.count(), 0);
  });

  group('CredentialVault corrupt blob', () {
    const key = 'credentials.v1.test';

    test(
      'reads as empty but save backs up raw bytes before overwriting',
      () async {
        final store = InMemorySecureStore();
        await store.put(key, _bytes('{"passwords": "oops"}'));
        final vault = CredentialVault(store: store, service: 'test');

        expect(await vault.count(), 0);
        expect(await vault.load('s1', 'u1'), isNull);
        expect(await store.get(corruptBackupKey(key)), isNull);

        await vault.save('s1', 'u1', 'pw');
        expect(
          utf8.decode((await store.get(corruptBackupKey(key)))!),
          '{"passwords": "oops"}',
        );
        expect(await vault.load('s1', 'u1'), 'pw');
      },
    );

    test('forget on corrupt vault backs up before deleting', () async {
      final store = InMemorySecureStore();
      await store.put(key, _bytes('garbage'));
      final vault = CredentialVault(store: store, service: 'test');

      await vault.forget('s1', 'u1');
      expect(await store.get(key), isNull);
      expect(utf8.decode((await store.get(corruptBackupKey(key)))!), 'garbage');
    });

    test('keeps valid entries and backs up partial non-string corruption', () async {
      final store = InMemorySecureStore();
      const raw = '{"passwords":{"s1|u1":"pw1","s2|u2":42}}';
      await store.put(key, _bytes(raw));
      final vault = CredentialVault(store: store, service: 'test');

      expect(await vault.load('s1', 'u1'), 'pw1');
      await vault.save('s3', 'u3', 'pw3');
      expect(utf8.decode((await store.get(corruptBackupKey(key)))!), raw);
      expect(await vault.load('s1', 'u1'), 'pw1');
      expect(await vault.load('s3', 'u3'), 'pw3');
    });
  });
}
