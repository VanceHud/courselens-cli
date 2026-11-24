import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'storage.dart';

/// 持久化数据的读取状态：区分“不存在”与“存在但无法完整解码（已损坏）”。
enum StoredLoadState { absent, ok, corrupt }

/// 持久化数据的读取结果。
///
/// 读路径可直接使用 [value]（不存在或损坏时为空值或尽力解码出的部分数据）；
/// 写路径在 [isCorrupt] 时必须先把原始数据备份到 [corruptBackupKey]，
/// 再执行读-改-写覆盖，避免把无法解码的数据静默清空。
class StoredLoad<T> {
  const StoredLoad.absent(this.value)
    : state = StoredLoadState.absent,
      error = null;

  const StoredLoad.ok(this.value) : state = StoredLoadState.ok, error = null;

  const StoredLoad.corrupt(this.value, this.error)
    : state = StoredLoadState.corrupt;

  final StoredLoadState state;
  final T value;
  final Object? error;

  bool get isCorrupt => state == StoredLoadState.corrupt;
}

/// 解码已持久化的 JSON 文本：[raw] 为 null 视为不存在；
/// JSON 解析或 [parse] 抛出的任何异常均视为已损坏，并以 [empty] 作为回退值。
StoredLoad<T> decodeStoredJson<T>(
  String? raw, {
  required T Function() empty,
  required T Function(Object? json) parse,
}) {
  if (raw == null) return StoredLoad<T>.absent(empty());
  try {
    return StoredLoad<T>.ok(parse(jsonDecode(raw)));
  } catch (error) {
    return StoredLoad<T>.corrupt(empty(), error);
  }
}

/// [decodeStoredJson] 的 UTF-8 字节版本（用于 [SecureStore]）。
StoredLoad<T> decodeStoredJsonBytes<T>(
  Uint8List? bytes, {
  required T Function() empty,
  required T Function(Object? json) parse,
}) {
  if (bytes == null) return StoredLoad<T>.absent(empty());
  final String text;
  try {
    text = utf8.decode(bytes);
  } catch (error) {
    return StoredLoad<T>.corrupt(empty(), error);
  }
  return decodeStoredJson<T>(text, empty: empty, parse: parse);
}

/// 损坏数据的备份键名。
String corruptBackupKey(String key) => '$key.corrupt';

/// 写路径覆盖 [SecureStore] 中的 [key] 之前调用：若 [load] 为损坏状态，
/// 将原始字节备份到 [corruptBackupKey] 并记录日志。
Future<void> backupCorruptSecureEntry(
  SecureStore store,
  String key,
  StoredLoad<Object?> load,
) async {
  if (!load.isCorrupt) return;
  final raw = await store.get(key);
  if (raw == null) return;
  await store.put(corruptBackupKey(key), raw);
  _logCorruptBackup(key, load.error);
}

/// 写路径覆盖 [KeyValueStore] 中的 [key] 之前调用：若 [load] 为损坏状态，
/// 将原始文本备份到 [corruptBackupKey] 并记录日志。
Future<void> backupCorruptKeyValueEntry(
  KeyValueStore store,
  String key,
  StoredLoad<Object?> load,
) async {
  if (!load.isCorrupt) return;
  final raw = store.getString(key);
  if (raw == null) return;
  await store.putString(corruptBackupKey(key), raw);
  _logCorruptBackup(key, load.error);
}

// 只记录异常类型：解析异常的 toString() 可能包含原始文本（密码、Cookie 等）。
void _logCorruptBackup(String key, Object? error) {
  developer.log(
    '持久化数据 "$key" 无法完整解码（${error.runtimeType}），'
    '已备份原始数据到 "${corruptBackupKey(key)}" 后再覆盖写入',
    name: 'courselens.storage',
    level: 900,
  );
}
