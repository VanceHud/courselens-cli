import 'dart:convert';
import 'dart:typed_data';

import '../port/http.dart';
import '../port/storage.dart';

/// 一个已保存的账号元数据（不含密码与 API Key）。
class SavedAccount {
  const SavedAccount({
    required this.schoolId,
    required this.accountKey,
    required this.protocol,
    required this.baseUrl,
    this.casBaseUrl = '',
    this.workerUrl = '',
    this.username = '',
    this.systemId = '',
    this.schedulePath = '',
    this.gradesPath = '',
    this.scheduleTermId = '',
  });

  final String schoolId;
  final String accountKey;
  final String protocol;
  final String baseUrl;
  final String casBaseUrl;
  final String workerUrl;
  final String username;
  final String systemId;
  final String schedulePath;
  final String gradesPath;
  final String scheduleTermId;

  String get key => '$schoolId|$accountKey';

  String get displayName => username.trim().isEmpty ? accountKey : username;

  SavedAccount copyWith({
    String? schoolId,
    String? accountKey,
    String? protocol,
    String? baseUrl,
    String? casBaseUrl,
    String? workerUrl,
    String? username,
    String? systemId,
    String? schedulePath,
    String? gradesPath,
    String? scheduleTermId,
  }) =>
      SavedAccount(
        schoolId: schoolId ?? this.schoolId,
        accountKey: accountKey ?? this.accountKey,
        protocol: protocol ?? this.protocol,
        baseUrl: baseUrl ?? this.baseUrl,
        casBaseUrl: casBaseUrl ?? this.casBaseUrl,
        workerUrl: workerUrl ?? this.workerUrl,
        username: username ?? this.username,
        systemId: systemId ?? this.systemId,
        schedulePath: schedulePath ?? this.schedulePath,
        gradesPath: gradesPath ?? this.gradesPath,
        scheduleTermId: scheduleTermId ?? this.scheduleTermId,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schoolId': schoolId,
        'accountKey': accountKey,
        'protocol': protocol,
        'baseUrl': baseUrl,
        'casBaseUrl': casBaseUrl,
        if (workerUrl.isNotEmpty) 'workerUrl': workerUrl,
        'username': username,
        'systemId': systemId,
        'schedulePath': schedulePath,
        'gradesPath': gradesPath,
        'scheduleTermId': scheduleTermId,
      };

  factory SavedAccount.fromJson(Map<String, dynamic> json) => SavedAccount(
        schoolId: json['schoolId'] as String? ?? '',
        accountKey: json['accountKey'] as String? ?? '',
        protocol: json['protocol'] as String? ?? '',
        baseUrl: json['baseUrl'] as String? ?? '',
        casBaseUrl: json['casBaseUrl'] as String? ?? '',
        workerUrl: json['workerUrl'] as String? ?? '',
        username: json['username'] as String? ?? '',
        systemId: json['systemId'] as String? ?? '',
        schedulePath: json['schedulePath'] as String? ?? '',
        gradesPath: json['gradesPath'] as String? ?? '',
        scheduleTermId: json['scheduleTermId'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SavedAccount &&
          schoolId == other.schoolId &&
          accountKey == other.accountKey &&
          protocol == other.protocol &&
          baseUrl == other.baseUrl &&
          casBaseUrl == other.casBaseUrl &&
          workerUrl == other.workerUrl &&
          username == other.username &&
          systemId == other.systemId &&
          schedulePath == other.schedulePath &&
          gradesPath == other.gradesPath &&
          scheduleTermId == other.scheduleTermId;

  @override
  int get hashCode => Object.hash(
        schoolId,
        accountKey,
        protocol,
        baseUrl,
        casBaseUrl,
        workerUrl,
        username,
        systemId,
        schedulePath,
        gradesPath,
        scheduleTermId,
      );
}

/// 已保存会话的归档（存于 [SecureStore]，上限 [maxAccounts] 个账号）。
class SessionArchive {
  SessionArchive({
    required SecureStore store,
    required String service,
  })  : _store = store,
        _service = service;

  static const int maxAccounts = 3;

  final SecureStore _store;
  final String _service;

  String get _storeKey => 'sessions.v1.$_service';

  Future<bool> save(SavedAccount account, List<StoredCookie> cookies) async {
    final blob = await _loadBlob();
    final alreadyStored = blob.sessions.any((s) => s.account.key == account.key);
    if (!alreadyStored && blob.sessions.length >= maxAccounts) return false;

    final refreshed = _PersistedSession(
      account: account,
      cookies: List<StoredCookie>.unmodifiable(cookies),
    );
    final updated = <_PersistedSession>[
      ...blob.sessions.where((s) => s.account.key != account.key),
      refreshed,
    ];
    await _persistBlob(_ArchiveBlob(active: account.key, sessions: updated));
    return true;
  }

  Future<List<SavedAccount>> accounts() async {
    final blob = await _loadBlob();
    return blob.sessions.map((s) => s.account).toList(growable: false);
  }

  Future<List<StoredCookie>> cookiesFor(
    String schoolId,
    String accountKey,
  ) async {
    final target = _compositeKey(schoolId, accountKey);
    final blob = await _loadBlob();
    for (final s in blob.sessions) {
      if (s.account.key == target) {
        return s.cookies;
      }
    }
    return const <StoredCookie>[];
  }

  Future<SavedAccount?> activeAccount() async {
    final blob = await _loadBlob();
    for (final s in blob.sessions) {
      if (s.account.key == blob.active) {
        return s.account;
      }
    }
    return blob.sessions.isEmpty ? null : blob.sessions.first.account;
  }

  Future<bool> setActive(String schoolId, String accountKey) async {
    final blob = await _loadBlob();
    final target = _compositeKey(schoolId, accountKey);
    if (!blob.sessions.any((s) => s.account.key == target)) return false;
    await _persistBlob(_ArchiveBlob(active: target, sessions: blob.sessions));
    return true;
  }

  Future<void> remove(String schoolId, String accountKey) async {
    final blob = await _loadBlob();
    final target = _compositeKey(schoolId, accountKey);
    final remaining = blob.sessions
        .where((s) => s.account.key != target)
        .toList(growable: false);
    if (remaining.isEmpty) {
      await _store.delete(_storeKey);
      return;
    }
    final stillActive =
        blob.active == target ? remaining.first.account.key : blob.active;
    await _persistBlob(
      _ArchiveBlob(active: stillActive, sessions: remaining),
    );
  }

  Future<void> clear() => _store.delete(_storeKey);

  Future<int> count() async {
    final blob = await _loadBlob();
    return blob.sessions.length;
  }

  Future<_ArchiveBlob> _loadBlob() async {
    final bytes = await _store.get(_storeKey);
    if (bytes == null) return const _ArchiveBlob();
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return const _ArchiveBlob();
      return _ArchiveBlob.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return const _ArchiveBlob();
    }
  }

  Future<void> _persistBlob(_ArchiveBlob blob) async {
    final encoded = jsonEncode(blob.toJson());
    await _store.put(_storeKey, Uint8List.fromList(utf8.encode(encoded)));
  }

  static String _compositeKey(String schoolId, String accountKey) =>
      '$schoolId|$accountKey';
}

class _PersistedSession {
  const _PersistedSession({required this.account, required this.cookies});

  final SavedAccount account;
  final List<StoredCookie> cookies;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'account': account.toJson(),
        'cookies': cookies.map((c) => c.toJson()).toList(),
      };

  factory _PersistedSession.fromJson(Map<String, dynamic> json) {
    final rawAccount = json['account'];
    final account = rawAccount is Map
        ? SavedAccount.fromJson(Map<String, dynamic>.from(rawAccount))
        : const SavedAccount(
            schoolId: '',
            accountKey: '',
            protocol: '',
            baseUrl: '',
          );
    final rawCookies = json['cookies'];
    final cookies = <StoredCookie>[];
    if (rawCookies is List) {
      for (final item in rawCookies) {
        if (item is Map) {
          cookies.add(StoredCookie.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return _PersistedSession(
      account: account,
      cookies: List<StoredCookie>.unmodifiable(cookies),
    );
  }
}

class _ArchiveBlob {
  const _ArchiveBlob({
    this.active = '',
    this.sessions = const <_PersistedSession>[],
  });

  final String active;
  final List<_PersistedSession> sessions;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'active': active,
        'sessions': sessions.map((s) => s.toJson()).toList(),
      };

  factory _ArchiveBlob.fromJson(Map<String, dynamic> json) {
    final rawSessions = json['sessions'];
    final sessions = <_PersistedSession>[];
    if (rawSessions is List) {
      for (final item in rawSessions) {
        if (item is Map) {
          sessions.add(
            _PersistedSession.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    return _ArchiveBlob(
      active: json['active'] as String? ?? '',
      sessions: List<_PersistedSession>.unmodifiable(sessions),
    );
  }
}
