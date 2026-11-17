import 'dart:typed_data';

/// 安全存储不可用或操作失败。
///
/// [platformStatus] 保留底层系统状态码（如 Keychain OSStatus 或平台错误码），用于诊断排查。
class SecureStoreException implements Exception {
  const SecureStoreException(
    this.message, {
    this.platformStatus = 0,
    this.cause,
  });

  final String message;
  final int platformStatus;
  final Object? cause;

  @override
  String toString() =>
      'SecureStoreException(status=$platformStatus, message=$message)';
}

/// 平台级安全凭据存储端口（Keychain / Keystore / DPAPI / Web 会话内存隔离）。
///
/// 安全存储不可用时必须抛出 [SecureStoreException]，严禁降级为明文落盘。
abstract interface class SecureStore {
  Future<void> put(String key, Uint8List value);
  Future<Uint8List?> get(String key);
  Future<void> delete(String key);
}

/// 普通偏好设置与非敏感缓存存储端口。
abstract interface class KeyValueStore {
  String? getString(String key);
  Future<void> putString(String key, String value);
  Future<void> remove(String key);
  Future<void> clear();
}

/// 只存在于内存中的安全存储实现。
///
/// 用途：
/// 1. 演示模式（不污染真实系统钥匙串、不触发系统授权弹窗）；
/// 2. 单元测试与离线自检；
/// 3. Web 浏览器端会话级隔离（关闭或刷新标签页即销毁，绝不向 `localStorage` 明文落盘）。
class InMemorySecureStore implements SecureStore {
  final Map<String, Uint8List> _entries = <String, Uint8List>{};

  @override
  Future<void> put(String key, Uint8List value) async {
    _entries[key] = Uint8List.fromList(value);
  }

  @override
  Future<Uint8List?> get(String key) async {
    final stored = _entries[key];
    return stored == null ? null : Uint8List.fromList(stored);
  }

  @override
  Future<void> delete(String key) async {
    _entries.remove(key);
  }

  /// 当前条目数，供自检与断言使用。
  int count() => _entries.length;
}

/// 内存版键值存储，供测试与回退使用。
class InMemoryKeyValueStore implements KeyValueStore {
  final Map<String, String> _entries = <String, String>{};

  @override
  String? getString(String key) => _entries[key];

  @override
  Future<void> putString(String key, String value) async {
    _entries[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _entries.remove(key);
  }

  @override
  Future<void> clear() async {
    _entries.clear();
  }
}
