export 'macos_keychain.dart' show CliKeychain;
export 'cli_credential_store.dart';
export 'cli_session_record.dart';
export 'cookie_har_parser.dart';

import 'cli_session_record.dart';

/// Credential/session storage backend selector for the CourseLens CLI.
enum CliStoreKind {
  auto,
  keychain,
  file,
  env;

  /// Parses [raw] case-insensitively, returning `null` if unrecognized.
  static CliStoreKind? tryParse(String? raw) {
    if (raw == null) return null;
    final normalized = raw.trim().toLowerCase();
    for (final candidate in CliStoreKind.values) {
      if (candidate.name == normalized) return candidate;
    }
    return null;
  }

  /// Parses [raw] case-insensitively or throws [FormatException].
  static CliStoreKind parse(String raw) {
    final parsed = tryParse(raw);
    if (parsed == null) {
      throw FormatException(
        'Invalid store kind "$raw": expected one of auto, keychain, file, env.',
      );
    }
    return parsed;
  }
}

/// Thrown when secure/configured CLI credential storage cannot be accessed
/// or violates security redlines (e.g. Keychain failure or world-readable file).
///
/// Per Security Redline #1, callers MUST fail fast rather than silently falling
/// back to an unencrypted or weaker plaintext location.
class CliStorageUnavailableException implements Exception {
  final String message;

  const CliStorageUnavailableException(this.message);

  @override
  String toString() => 'STORAGE_UNAVAILABLE: $message';
}

/// Persistence contract for CourseLens CLI sessions.
abstract interface class CliSessionStore {
  String get backendDescription;

  Future<CliSessionRecord?> load();

  Future<void> save(CliSessionRecord record);

  Future<void> clear();
}
