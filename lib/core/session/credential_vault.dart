import 'dart:convert';
import 'dart:typed_data';

import '../port/storage.dart';
import '../port/stored_load.dart';

/// [CredentialVault.selfCheck] 的结果。
class VaultSelfCheck {
  const VaultSelfCheck({
    required this.available,
    required this.roundTripOk,
    required this.detail,
  });

  final bool available;
  final bool roundTripOk;
  final String detail;
}

/// 教务凭据持久化金库（只存于 [SecureStore]，绝不降级明文落盘）。
class CredentialVault {
  CredentialVault({
    required SecureStore store,
    required String service,
  })  : _store = store,
        _service = service;

  final SecureStore _store;
  final String _service;

  String get _key => 'credentials.v1.$_service';

  Future<void> save(
    String schoolId,
    String account,
    String password,
  ) async {
    final load = await _read();
    final passwords = load.value;
    passwords[_entryKey(schoolId, account)] = password;
    await _write(load, passwords);
  }

  Future<String?> load(String schoolId, String account) async {
    final passwords = (await _read()).value;
    return passwords[_entryKey(schoolId, account)];
  }

  Future<bool> has(String schoolId, String account) async {
    final passwords = (await _read()).value;
    return passwords.containsKey(_entryKey(schoolId, account));
  }

  Future<int> count() async {
    final passwords = (await _read()).value;
    return passwords.length;
  }

  Future<void> forget(String schoolId, String account) async {
    final load = await _read();
    final passwords = load.value;
    passwords.remove(_entryKey(schoolId, account));
    if (passwords.isEmpty) {
      await backupCorruptSecureEntry(_store, _key, load);
      await _store.delete(_key);
    } else {
      await _write(load, passwords);
    }
  }

  Future<void> forgetAll() async {
    await _store.delete(_key);
    await _store.delete(corruptBackupKey(_key));
  }

  Future<VaultSelfCheck> selfCheck() async {
    const probeKey = 'selfcheck.probe';
    try {
      final payload = 'ok-${_service.length}';
      await _store.put(probeKey, Uint8List.fromList(utf8.encode(payload)));
      final rawRead = await _store.get(probeKey);
      final readBack = rawRead == null ? null : utf8.decode(rawRead);
      await _store.delete(probeKey);
      final readBackAfterDelete = await _store.get(probeKey);
      if (readBack != payload) {
        return VaultSelfCheck(
          available: true,
          roundTripOk: false,
          detail: '读回内容不一致：期望 $payload，实际 $readBack',
        );
      }
      if (readBackAfterDelete != null) {
        return const VaultSelfCheck(
          available: true,
          roundTripOk: false,
          detail: '删除后仍能读到值',
        );
      }
      return const VaultSelfCheck(
        available: true,
        roundTripOk: true,
        detail: '写入/读回/删除均正常',
      );
    } on SecureStoreException catch (error) {
      return VaultSelfCheck(
        available: false,
        roundTripOk: false,
        detail:
            '安全存储不可用（OSStatus=${error.platformStatus}）：${error.message}',
      );
    }
  }

  Future<StoredLoad<Map<String, String>>> _read() async {
    final bytes = await _store.get(_key);
    if (bytes == null) {
      return StoredLoad<Map<String, String>>.absent(<String, String>{});
    }
    final top = decodeStoredJsonBytes<Map<dynamic, dynamic>>(
      bytes,
      empty: () => const <dynamic, dynamic>{},
      parse: (decoded) {
        if (decoded is! Map) {
          throw const FormatException('凭据金库顶层不是 JSON 对象');
        }
        final rawPasswords = decoded['passwords'];
        if (rawPasswords is! Map) {
          throw const FormatException('凭据金库缺少 passwords 对象');
        }
        return rawPasswords;
      },
    );
    if (top.isCorrupt) {
      return StoredLoad<Map<String, String>>.corrupt(
        <String, String>{},
        top.error,
      );
    }
    final out = <String, String>{};
    Object? firstError;
    for (final entry in top.value.entries) {
      if (entry.value is String) {
        out[entry.key.toString()] = entry.value as String;
      } else {
        firstError ??= const FormatException('凭据金库包含非字符串密码条目');
      }
    }
    return firstError == null
        ? StoredLoad<Map<String, String>>.ok(out)
        : StoredLoad<Map<String, String>>.corrupt(out, firstError);
  }

  Future<void> _write(
    StoredLoad<Map<String, String>> previous,
    Map<String, String> passwords,
  ) async {
    await backupCorruptSecureEntry(_store, _key, previous);
    final encoded = jsonEncode(<String, dynamic>{'passwords': passwords});
    await _store.put(_key, Uint8List.fromList(utf8.encode(encoded)));
  }

  static String _entryKey(String schoolId, String account) =>
      '$schoolId|$account';
}
