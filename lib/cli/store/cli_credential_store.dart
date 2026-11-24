import 'dart:convert';
import 'dart:io';

import 'cli_session_store.dart';
import 'macos_keychain.dart';

/// Injectable process execution signature for POSIX permission helpers.
typedef CliProcessRunner = Future<ProcessResult> Function(
    String executable, List<String> arguments);

/// Resolves the appropriate [CliSessionStore] implementation for the active OS,
/// CLI flags, and environment variables while strictly upholding Security
/// Redline #1 (never silently degrading to plaintext when secure storage fails).
class CliCredentialStore {
  const CliCredentialStore._();

  static const String defaultKeychainService = 'dev.courselens.cli';
  static const String defaultKeychainAccount = 'default';

  static const String envBaseUrl = 'COURSELENS_BASE_URL';
  static const String envUsername = 'COURSELENS_USERNAME';
  static const String envPassword = 'COURSELENS_PASSWORD';
  static const String envCookies = 'COURSELENS_COOKIES';
  static const String envSchoolType = 'COURSELENS_SCHOOL_TYPE';
  static const String envRelayUrl = 'COURSELENS_RELAY_URL';
  static const String envWorkerUrl = 'COURSELENS_WORKER_URL';
  static const String envApiKey = 'COURSELENS_API_KEY';

  static CliSessionStore resolve({
    CliStoreKind kind = CliStoreKind.auto,
    String? sessionFilePath,
    Map<String, String>? environment,
    String? operatingSystem,
    CliKeychain? keychain,
    CliProcessRunner? chmodRunner,
    String keychainService = defaultKeychainService,
    String keychainAccount = defaultKeychainAccount,
    DateTime Function()? now,
  }) {
    final env = environment ?? Platform.environment;
    final os =
        (operatingSystem ?? Platform.operatingSystem).trim().toLowerCase();
    final explicitPath = _nonEmptyOrNull(sessionFilePath);

    switch (kind) {
      case CliStoreKind.env:
        return EnvCliSessionStore(environment: env, now: now);

      case CliStoreKind.keychain:
        return KeychainCliSessionStore(
          operatingSystem: os,
          service: keychainService,
          account: keychainAccount,
          keychain: keychain,
        );

      case CliStoreKind.file:
        return FileCliSessionStore(
          filePath: explicitPath ?? _resolveDefaultSessionFilePath(env, os),
          operatingSystem: os,
          chmodRunner: chmodRunner,
        );

      case CliStoreKind.auto:
        if (explicitPath != null) {
          return FileCliSessionStore(
            filePath: explicitPath,
            operatingSystem: os,
            chmodRunner: chmodRunner,
          );
        }
        if (_hasAutoEnvCredentials(env)) {
          return EnvCliSessionStore(environment: env, now: now);
        }
        if (os == 'macos') {
          return KeychainCliSessionStore(
            operatingSystem: os,
            service: keychainService,
            account: keychainAccount,
            keychain: keychain,
          );
        }
        return FileCliSessionStore(
          filePath: _resolveDefaultSessionFilePath(env, os),
          operatingSystem: os,
          chmodRunner: chmodRunner,
        );
    }
  }

  static bool _hasAutoEnvCredentials(Map<String, String> env) {
    final workerUrl = _nonEmptyOrNull(env[envWorkerUrl]);
    final apiKey = _nonEmptyOrNull(env[envApiKey]);
    if (workerUrl != null && apiKey != null) return true;

    final baseUrl = _nonEmptyOrNull(env[envBaseUrl]);
    if (baseUrl == null) return false;
    final cookies = _nonEmptyOrNull(env[envCookies]);
    final username = _nonEmptyOrNull(env[envUsername]);
    return cookies != null || username != null;
  }

  static String _resolveDefaultSessionFilePath(
    Map<String, String> env,
    String os,
  ) {
    final home = _nonEmptyOrNull(env['HOME']) ??
        (os == 'windows' ? _nonEmptyOrNull(env['USERPROFILE']) : null);
    if (home == null) {
      throw const CliStorageUnavailableException(
        'Cannot determine default session file path because HOME is not set.',
      );
    }
    var trimmedHome = home;
    while (trimmedHome.length > 1 &&
        (trimmedHome.endsWith('/') || trimmedHome.endsWith(r'\'))) {
      trimmedHome = trimmedHome.substring(0, trimmedHome.length - 1);
    }
    final sep = os == 'windows' ? r'\' : '/';
    return '$trimmedHome$sep.config${sep}courselens${sep}session.json';
  }
}

/// Read-only session store backed by `COURSELENS_*` environment variables.
class EnvCliSessionStore implements CliSessionStore {
  EnvCliSessionStore({
    required Map<String, String> environment,
    DateTime Function()? now,
  })  : _environment = Map<String, String>.unmodifiable(environment),
        _now = now ?? DateTime.now;

  final Map<String, String> _environment;
  final DateTime Function() _now;

  @override
  String get backendDescription => 'env (COURSELENS_*)';

  @override
  Future<CliSessionRecord?> load() async {
    final workerUrl = _nonEmptyOrNull(
      _environment[CliCredentialStore.envWorkerUrl],
    );
    final apiKey = _nonEmptyOrNull(_environment[CliCredentialStore.envApiKey]);
    final baseUrl = _nonEmptyOrNull(
      _environment[CliCredentialStore.envBaseUrl],
    );
    final username = _nonEmptyOrNull(
      _environment[CliCredentialStore.envUsername],
    );
    final systemType = _nonEmptyOrNull(
      _environment[CliCredentialStore.envSchoolType],
    );
    final relayUrl = _nonEmptyOrNull(
      _environment[CliCredentialStore.envRelayUrl],
    );

    if (workerUrl != null && apiKey != null) {
      final workerUri = Uri.tryParse(workerUrl);
      if (workerUri == null || !workerUri.hasScheme || workerUri.host.isEmpty) {
        throw CliStorageUnavailableException(
          'Invalid ${CliCredentialStore.envWorkerUrl}: "$workerUrl" is not a valid HTTP(S) URL.',
        );
      }
      if (baseUrl != null) {
        final targetUri = Uri.tryParse(baseUrl);
        if (targetUri == null ||
            !targetUri.hasScheme ||
            targetUri.host.isEmpty) {
          throw CliStorageUnavailableException(
            'Invalid ${CliCredentialStore.envBaseUrl}: "$baseUrl" is not a valid HTTP(S) URL.',
          );
        }
      }
      return CliSessionRecord(
        baseUrl: baseUrl ?? '',
        username: username,
        systemType: systemType,
        workerUrl: workerUrl,
        apiKey: apiKey,
        relayUrl: relayUrl,
        updatedAt: _now().toUtc(),
        backendName: 'env',
      );
    }

    if (baseUrl == null) return null;

    final rawCookies = _nonEmptyOrNull(
      _environment[CliCredentialStore.envCookies],
    );
    if (rawCookies == null && username == null) {
      return null;
    }

    final rawPassword = _environment[CliCredentialStore.envPassword];
    final password =
        (rawPassword != null && rawPassword.isNotEmpty) ? rawPassword : null;

    final targetUri = Uri.tryParse(baseUrl);
    if (targetUri == null || !targetUri.hasScheme || targetUri.host.isEmpty) {
      throw CliStorageUnavailableException(
        'Invalid ${CliCredentialStore.envBaseUrl}: "$baseUrl" is not a valid HTTP(S) URL.',
      );
    }

    final Map<String, String> cookies;
    if (rawCookies == null) {
      cookies = const <String, String>{};
    } else {
      try {
        cookies = CookieHarParser.extract(
          cookieHeader: rawCookies,
          targetBaseUri: targetUri,
        );
      } on FormatException catch (e) {
        throw CliStorageUnavailableException(
          'Invalid ${CliCredentialStore.envCookies}: ${e.message}',
        );
      }
    }

    return CliSessionRecord(
      baseUrl: baseUrl,
      username: username,
      password: password,
      systemType: systemType,
      cookies: cookies,
      relayUrl: relayUrl,
      updatedAt: _now().toUtc(),
      backendName: 'env',
    );
  }

  @override
  Future<void> save(CliSessionRecord record) async {
    throw const CliStorageUnavailableException(
      'Environment credential store (COURSELENS_*) is read-only; '
      'unset COURSELENS_* or pass --store keychain/file to persist sessions.',
    );
  }

  @override
  Future<void> clear() async {
    throw const CliStorageUnavailableException(
      'Environment credential store (COURSELENS_*) is read-only; '
      'unset COURSELENS_* variables in your shell to clear the session.',
    );
  }
}

/// macOS Keychain store backed by Security.framework in the CLI process.
class KeychainCliSessionStore implements CliSessionStore {
  KeychainCliSessionStore({
    String? operatingSystem,
    this.service = CliCredentialStore.defaultKeychainService,
    this.account = CliCredentialStore.defaultKeychainAccount,
    CliKeychain? keychain,
  })  : _operatingSystem =
            (operatingSystem ?? Platform.operatingSystem).trim().toLowerCase(),
        _keychain = keychain;

  final String _operatingSystem;
  final String service;
  final String account;
  CliKeychain? _keychain;

  @override
  String get backendDescription => 'keychain ($service:$account)';

  T _access<T>(T Function(CliKeychain) operation) {
    if (_operatingSystem != 'macos') {
      throw const CliStorageUnavailableException(
        'macOS Keychain is unavailable on this platform.',
      );
    }
    try {
      return operation(_keychain ??= MacOsKeychain());
    } on CliStorageUnavailableException {
      rethrow;
    } on Object {
      throw const CliStorageUnavailableException(
        'macOS Keychain data or framework could not be accessed.',
      );
    }
  }

  @override
  Future<CliSessionRecord?> load() async => _access((keychain) {
        final payload = keychain.read(service, account);
        if (payload == null) return null;
        final json = jsonDecode(payload);
        if (json is! Map<String, dynamic>) {
          throw const FormatException('Keychain record must be a JSON object.');
        }
        return CliSessionRecord.fromJson(json)
            .copyWith(backendName: 'keychain');
      });

  @override
  Future<void> save(CliSessionRecord record) async => _access(
        (keychain) => keychain.write(
          service,
          account,
          jsonEncode(record.copyWith(backendName: 'keychain').toJson()),
        ),
      );

  @override
  Future<void> clear() async =>
      _access((keychain) => keychain.delete(service, account));
}

/// POSIX `0600`-enforced JSON session file store (`~/.config/courselens/session.json`).
///
/// On POSIX systems:
/// - [save] creates parent directories with mode `0700` and writes the session
///   file atomically with mode `0600`.
/// - [load] inspects `stat.mode` and refuses any file whose group or other
///   permission bits are non-zero (`mode & 0x3f != 0`), instructing the user
///   to run `chmod 600`.
class FileCliSessionStore implements CliSessionStore {
  FileCliSessionStore({
    required this.filePath,
    String? operatingSystem,
    CliProcessRunner? chmodRunner,
  })  : _operatingSystem =
            (operatingSystem ?? Platform.operatingSystem).trim().toLowerCase(),
        _chmodRunner = chmodRunner;

  final String filePath;
  final String _operatingSystem;
  final CliProcessRunner? _chmodRunner;

  bool get _isPosix => _operatingSystem != 'windows';

  @override
  String get backendDescription => 'file ($filePath)';

  @override
  Future<CliSessionRecord?> load() async {
    final file = File(filePath);
    final FileStat stat;
    try {
      stat = await file.stat();
    } on Object catch (e) {
      throw CliStorageUnavailableException(
        'Failed to stat session file "$filePath": $e',
      );
    }

    if (stat.type == FileSystemEntityType.notFound) {
      return null;
    }
    if (stat.type != FileSystemEntityType.file) {
      throw CliStorageUnavailableException(
        'Session path "$filePath" is not a regular file.',
      );
    }

    if (_isPosix && (stat.mode & 0x3f) != 0) {
      final octal = (stat.mode & 0x1ff).toRadixString(8).padLeft(4, '0');
      throw CliStorageUnavailableException(
        'Refusing to load session file "$filePath" with insecure permissions '
        '($octal): group/other bits must not be set. '
        'Fix permissions with: chmod 600 "$filePath"',
      );
    }

    final String rawContent;
    try {
      rawContent = await file.readAsString();
    } on FileSystemException catch (e) {
      throw CliStorageUnavailableException(
        'Failed to read session file "$filePath": ${e.message}',
      );
    }

    try {
      final decoded = jsonDecode(rawContent);
      if (decoded is! Map<Object?, Object?>) {
        throw const FormatException('Session JSON root must be an object.');
      }
      final typed = <String, Object?>{
        for (final e in decoded.entries) '${e.key}': e.value,
      };
      final parsed = CliSessionRecord.fromJson(typed);
      return parsed.backendName == 'file'
          ? parsed
          : parsed.copyWith(backendName: 'file');
    } on FormatException catch (e) {
      throw CliStorageUnavailableException(
        'Corrupted session file "$filePath": ${e.message}',
      );
    }
  }

  @override
  Future<void> save(CliSessionRecord record) async {
    final file = File(filePath);
    final parentDir = file.parent;

    try {
      final existed = await parentDir.exists();
      if (!existed) {
        await parentDir.create(recursive: true);
      }
    } on FileSystemException catch (e) {
      throw CliStorageUnavailableException(
        'Failed to create session directory "${parentDir.path}": ${e.message}',
      );
    }

    if (_isPosix) {
      await _chmod('0700', parentDir.path);
    }

    final stamped = record.backendName == 'file'
        ? record
        : record.copyWith(backendName: 'file');
    final encoded =
        '${const JsonEncoder.withIndent('  ').convert(stamped.toJson())}\n';

    final tempPath =
        '${file.path}.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}';
    final tempFile = File(tempPath);

    try {
      await tempFile.writeAsString(encoded, flush: true);
      if (_isPosix) {
        await _chmod('0600', tempFile.path);
      }
      await tempFile.rename(file.path);
      if (_isPosix) {
        await _chmod('0600', file.path);
      }
    } on CliStorageUnavailableException {
      await _bestEffortDelete(tempFile);
      rethrow;
    } on FileSystemException catch (e) {
      await _bestEffortDelete(tempFile);
      throw CliStorageUnavailableException(
        'Failed to write session file "$filePath": ${e.message}',
      );
    }
  }

  @override
  Future<void> clear() async {
    final file = File(filePath);
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException catch (e) {
      throw CliStorageUnavailableException(
        'Failed to delete session file "$filePath": ${e.message}',
      );
    }
  }

  Future<void> _chmod(String octalMode, String targetPath) async {
    final runner = _chmodRunner;
    if (runner != null) {
      final res = await runner('chmod', <String>[octalMode, targetPath]);
      if (res.exitCode != 0) {
        throw CliStorageUnavailableException(
          'chmod $octalMode "$targetPath" failed (exit ${res.exitCode}): '
          '${_formatProcessError(res)}',
        );
      }
      return;
    }

    ProcessResult result;
    try {
      result = await Process.run('chmod', <String>[octalMode, targetPath]);
    } on ProcessException {
      try {
        result = await Process.run('/bin/chmod', <String>[
          octalMode,
          targetPath,
        ]);
      } on Object catch (e) {
        throw CliStorageUnavailableException(
          'Unable to execute chmod $octalMode on "$targetPath": $e',
        );
      }
    }
    if (result.exitCode != 0) {
      throw CliStorageUnavailableException(
        'chmod $octalMode "$targetPath" failed (exit ${result.exitCode}): '
        '${_formatProcessError(result)}',
      );
    }
  }

  static Future<void> _bestEffortDelete(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on Object {
      // Best-effort cleanup of temporary file.
    }
  }
}

/// Ephemeral in-memory [CliSessionStore] for tests and `--demo` sandboxes.
class InMemoryCliSessionStore implements CliSessionStore {
  InMemoryCliSessionStore([this._record]);

  CliSessionRecord? _record;

  @override
  String get backendDescription => 'memory';

  @override
  Future<CliSessionRecord?> load() async => _record;

  @override
  Future<void> save(CliSessionRecord record) async {
    _record = record.backendName == 'memory'
        ? record
        : record.copyWith(backendName: 'memory');
  }

  @override
  Future<void> clear() async {
    _record = null;
  }
}

String? _nonEmptyOrNull(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String _formatProcessError(ProcessResult result) {
  final stderrText = '${result.stderr}'.trim();
  if (stderrText.isNotEmpty) return stderrText;
  final stdoutText = '${result.stdout}'.trim();
  if (stdoutText.isNotEmpty) return stdoutText;
  return 'unknown error';
}
