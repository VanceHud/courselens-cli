import 'dart:convert';
import 'dart:typed_data';

import '../port/storage.dart';

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
    final passwords = await _read();
    passwords[_entryKey(schoolId, account)] = password;
    await _write(passwords);
  }

  Future<String?> load(String schoolId, String account) async {
    final passwords = await _read();
    return passwords[_entryKey(schoolId, account)];
  }

  Future<bool> has(String schoolId, String account) async {
    final passwords = await _read();
    return passwords.containsKey(_entryKey(schoolId, account));
  }

  Future<int> count() async {
    final passwords = await _read();
    return passwords.length;
  }

  Future<void> forget(String schoolId, String account) async {
    final passwords = await _read();
    passwords.remove(_entryKey(schoolId, account));
    if (passwords.isEmpty) {
      await _store.delete(_key);
    } else {
      await _write(passwords);
    }
  }

  Future<void> forgetAll() => _store.delete(_key);

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

  Future<Map<String, String>> _read() async {
    final bytes = await _store.get(_key);
    if (bytes == null) return <String, String>{};
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return <String, String>{};
      final rawPasswords = decoded['passwords'];
      if (rawPasswords is! Map) return <String, String>{};
      final out = <String, String>{};
      for (final entry in rawPasswords.entries) {
        if (entry.value is String) {
          out[entry.key.toString()] = entry.value as String;
        }
      }
      return out;
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<void> _write(Map<String, String> passwords) async {
    final encoded = jsonEncode(<String, dynamic>{'passwords': passwords});
    await _store.put(_key, Uint8List.fromList(utf8.encode(encoded)));
  }

  static String _entryKey(String schoolId, String account) =>
      '$schoolId|$account';
}
