import 'dart:async';

import '../model/academic_status.dart';
import '../model/qust_modules.dart';
import '../net/async_mutex.dart';
import '../net/cookie_jar.dart';
import '../parse/urls.dart';
import '../parse/zhengfang_home.dart';

const String _sessionReplacedReason = '会话已被替换';
final Object _protocolLockZoneKey = Object();

/// 会话标识：学校 + 账号。
class SessionKey {
  const SessionKey(this.schoolId, this.accountKey);

  final String schoolId;
  final String accountKey;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionKey &&
          schoolId == other.schoolId &&
          accountKey == other.accountKey;

  @override
  int get hashCode => Object.hash(schoolId, accountKey);
}

/// 一个 `(学校, 账号)` 的会话对象，维护 `epoch` 世代号、Cookie 容器与基于 `Zone` 的可重入协议锁。
class AccountSession {
  AccountSession({
    required this.key,
    required String baseUrl,
    required int Function() clock,
  })  : _baseUrl = baseUrl,
        cookies = CookieJar(clock: clock);

  final SessionKey key;
  String _baseUrl;
  final CookieJar cookies;

  String get baseUrl => _baseUrl;

  /// 当探测到裸域名自动跳转到 `/jwglxt` 等上下文前缀时更新会话基准地址。
  void updateBaseUrl(String nextBaseUrl) {
    final trimmed = nextBaseUrl.trim();
    if (trimmed.isNotEmpty) {
      _baseUrl = trimmed;
    }
  }

  final AsyncMutex _protocolMutex = AsyncMutex();
  final AsyncMutex _generationMutex = AsyncMutex();

  int _epoch = 1;
  bool _isRetired = false;
  String username = '';
  ZhengfangHomeMetadata? zfHomeMetadata;
  AcademicProgressReport? cachedAcademicProgress;
  EmptyClassroomFilterOptions? cachedClassroomFilters;

  int get epoch => _epoch;
  bool get isRetired => _isRetired;

  /// 作废当前世代：`epoch` 自增并清空 Cookie，会话仍可继续使用。
  Future<void> invalidate() async {
    await _generationMutex.withLock(_advanceGeneration);
    await cookies.clear();
  }

  /// 永久退役该会话对象：此后 [requireActive] 抛 [SessionCancelledException]，且 Cookie 容器永久拒收写入。
  Future<void> retire() async {
    await _generationMutex.withLock(() {
      _isRetired = true;
      _advanceGeneration();
    });
    await cookies.retire();
  }

  /// 调用方须持有 [_generationMutex]。
  void _advanceGeneration() {
    _epoch += 1;
    zfHomeMetadata = null;
    cachedAcademicProgress = null;
    cachedClassroomFilters = null;
  }

  void requireActive() => _throwIfRetired();

  Future<String> cookieHeader() => cookieHeaderFor(baseUrl);

  Future<String> cookieHeaderFor(String url) async {
    final parsed = Urls.parseUrl(url);
    if (parsed == null) return '';
    return cookies.cookieHeaderForParsedUrl(parsed);
  }

  /// 在本会话的可重入协议锁内执行 [action]。
  Future<T> withProtocolLock<T>(Future<T> Function() action) async {
    _throwIfRetired();
    final held = Zone.current[_protocolLockZoneKey] as Set<AccountSession>?;
    if (held != null && held.contains(this)) {
      return action();
    }
    return _protocolMutex.withLock(() {
      _throwIfRetired();
      final nextHeld = <AccountSession>{...?held, this};
      return runZoned(
        action,
        zoneValues: <Object?, Object?>{_protocolLockZoneKey: nextHeld},
      );
    });
  }

  void _throwIfRetired() {
    if (_isRetired) {
      throw const SessionCancelledException(_sessionReplacedReason);
    }
  }
}

/// 按 `(schoolId, accountKey)` 原子管理会话，并在表锁外退役旧会话。
class SessionStore {
  SessionStore({required int Function() clock}) : _clock = clock;

  final int Function() _clock;
  final Map<SessionKey, AccountSession> _sessions =
      <SessionKey, AccountSession>{};
  final AsyncMutex _lock = AsyncMutex();

  Future<AccountSession> session(
    String schoolId,
    String accountKey,
    String baseUrl,
  ) async {
    final key = SessionKey(schoolId, accountKey);
    AccountSession? superseded;
    final live = await _lock.withLock(() {
      final existing = _sessions[key];
      if (existing != null && existing.baseUrl == baseUrl) {
        return existing;
      }
      superseded = existing;
      final created = AccountSession(
        key: key,
        baseUrl: baseUrl,
        clock: _clock,
      );
      _sessions[key] = created;
      return created;
    });
    if (superseded != null) {
      await superseded!.retire();
    }
    return live;
  }

  Future<AccountSession> replace(
    String schoolId,
    String accountKey,
    String baseUrl,
  ) async {
    final fresh = AccountSession(
      key: SessionKey(schoolId, accountKey),
      baseUrl: baseUrl,
      clock: _clock,
    );
    final superseded = await _lock.withLock(() => _install(fresh));
    if (superseded != null) {
      await superseded.retire();
    }
    return fresh;
  }

  Future<void> invalidate(String schoolId, String accountKey) async {
    final removed = await _lock.withLock(
      () => _sessions.remove(SessionKey(schoolId, accountKey)),
    );
    if (removed != null) {
      await removed.retire();
    }
  }

  Future<void> clear() async {
    final snapshot = await _lock.withLock(() {
      final all = _sessions.values.toList(growable: false);
      _sessions.clear();
      return all;
    });
    for (final s in snapshot) {
      await s.retire();
    }
  }

  Future<int> activeCount() => _lock.withLock(() => _sessions.length);

  Future<AccountSession> requireActive(
    String schoolId,
    String accountKey,
  ) async {
    final s = await _lock.withLock(
      () => _sessions[SessionKey(schoolId, accountKey)],
    );
    if (s == null) {
      throw const AcademicException(
        AcademicStatus.SESSION_EXPIRED,
        '会话不存在',
      );
    }
    s.requireActive();
    return s;
  }

  Future<AccountSession?> find(String schoolId, String accountKey) async {
    final s = await _lock.withLock(
      () => _sessions[SessionKey(schoolId, accountKey)],
    );
    if (s == null || s.isRetired) return null;
    return s;
  }

  AccountSession? _install(AccountSession replacement) {
    final previous = _sessions[replacement.key];
    _sessions[replacement.key] = replacement;
    return previous;
  }
}
