/// Immutable saved Stateful Cloudflare Worker gateway profile in the CLI store.
class CliSavedWorkerProfile {
  CliSavedWorkerProfile({
    required this.name,
    required this.workerUrl,
    required this.apiKey,
    this.baseUrl = '',
    this.username,
    this.systemType,
    DateTime? updatedAt,
  }) : updatedAt = (updatedAt ?? DateTime.now()).toUtc();

  final String name;
  final String workerUrl;
  final String apiKey;
  final String baseUrl;
  final String? username;
  final String? systemType;
  final DateTime updatedAt;

  /// Masked tail hint (e.g. `••••9f2a`) safe for CLI status/list display.
  String get keyHint {
    final trimmed = apiKey.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.length <= 4) return '••••';
    return '••••${trimmed.substring(trimmed.length - 4)}';
  }

  /// Derives a default profile alias when `--name` is omitted.
  static String deriveDefaultName(String normalizedWorkerUrl) {
    final host = Uri.tryParse(normalizedWorkerUrl)?.host ?? '';
    if (host.isEmpty) return 'default';
    final firstLabel = host.split('.').first.trim();
    return firstLabel.isEmpty ? host : firstLabel;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'workerUrl': workerUrl,
        'apiKey': apiKey,
        if (baseUrl.isNotEmpty) 'baseUrl': baseUrl,
        'username': ?username,
        'systemType': ?systemType,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  /// Safe public JSON representation that strips plaintext [apiKey].
  Map<String, Object?> toPublicJson({bool active = false}) => <String, Object?>{
        'name': name,
        'workerUrl': workerUrl,
        'keyHint': keyHint,
        'active': active,
        if (baseUrl.isNotEmpty) 'baseUrl': baseUrl,
        'username': ?username,
        'systemType': ?systemType,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  factory CliSavedWorkerProfile.fromJson(Map<String, Object?> json) {
    final rawUrl = (json['workerUrl'] as String? ?? '').trim();
    final rawKey = (json['apiKey'] as String? ?? '').trim();
    if (rawUrl.isEmpty || rawKey.isEmpty) {
      throw const FormatException(
        'Invalid CliSavedWorkerProfile: workerUrl and apiKey must be non-empty.',
      );
    }
    final rawName = (json['name'] as String? ?? '').trim();
    final rawUpdated = json['updatedAt'];
    final updatedAt = rawUpdated is String && rawUpdated.trim().isNotEmpty
        ? DateTime.parse(rawUpdated.trim()).toUtc()
        : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return CliSavedWorkerProfile(
      name: rawName.isNotEmpty ? rawName : deriveDefaultName(rawUrl),
      workerUrl: rawUrl,
      apiKey: rawKey,
      baseUrl: (json['baseUrl'] as String? ?? '').trim(),
      username: CliSessionRecord._readOptionalString(json, 'username'),
      systemType: CliSessionRecord._readOptionalString(json, 'systemType'),
      updatedAt: updatedAt,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CliSavedWorkerProfile) return false;
    return name == other.name &&
        workerUrl == other.workerUrl &&
        apiKey == other.apiKey &&
        baseUrl == other.baseUrl &&
        username == other.username &&
        systemType == other.systemType &&
        updatedAt.isAtSameMomentAs(other.updatedAt);
  }

  @override
  int get hashCode => Object.hash(
        name,
        workerUrl,
        apiKey,
        baseUrl,
        username,
        systemType,
        updatedAt.millisecondsSinceEpoch,
      );
}

/// Immutable snapshot of a persisted or environment-injected CLI session.
///
/// [password] is an ephemeral in-memory field populated ONLY by the read-only
/// `env` store (`COURSELENS_PASSWORD`) so `auth login` / stateless runs can
/// authenticate without exposing argv flags; [toJson] intentionally never
/// serializes [password] to persistent payloads.
class CliSessionRecord {
  CliSessionRecord({
    required this.baseUrl,
    this.username,
    this.password,
    this.systemType,
    Map<String, String> cookies = const <String, String>{},
    this.relayUrl,
    this.workerUrl,
    this.apiKey,
    List<CliSavedWorkerProfile> savedWorkers = const <CliSavedWorkerProfile>[],
    DateTime? updatedAt,
    this.backendName = 'unknown',
  })  : cookies = Map<String, String>.unmodifiable(cookies),
        savedWorkers = List<CliSavedWorkerProfile>.unmodifiable(savedWorkers),
        updatedAt = (updatedAt ?? DateTime.now()).toUtc();

  final String baseUrl;
  final String? username;
  final String? password;
  final String? systemType;
  final Map<String, String> cookies;
  final String? relayUrl;
  final String? workerUrl;
  final String? apiKey;
  final List<CliSavedWorkerProfile> savedWorkers;
  final DateTime updatedAt;
  final String backendName;

  /// Whether this session delegates portal authentication to a stateful Cloudflare Worker.
  bool get isWorkerMode =>
      workerUrl != null &&
      workerUrl!.trim().isNotEmpty &&
      apiKey != null &&
      apiKey!.trim().isNotEmpty;

  /// Formats [cookies] as a single `Cookie` request header value.
  String get cookieHeader =>
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  /// Looks up a saved Worker profile by exact alias (case-insensitive) or normalized URL.
  CliSavedWorkerProfile? findSavedWorker(String nameOrUrl) {
    final target = nameOrUrl.trim();
    if (target.isEmpty) return null;
    final lower = target.toLowerCase();
    var normalizedTarget = lower;
    while (normalizedTarget.endsWith('/')) {
      normalizedTarget =
          normalizedTarget.substring(0, normalizedTarget.length - 1);
    }
    for (final item in savedWorkers) {
      var itemUrl = item.workerUrl.trim().toLowerCase();
      while (itemUrl.endsWith('/')) {
        itemUrl = itemUrl.substring(0, itemUrl.length - 1);
      }
      if (item.name.toLowerCase() == lower || itemUrl == normalizedTarget) {
        return item;
      }
    }
    return null;
  }

  /// Returns an updated [savedWorkers] list with [entry] inserted at the head.
  List<CliSavedWorkerProfile> upsertSavedWorker(CliSavedWorkerProfile entry) {
    final lowerName = entry.name.toLowerCase();
    final lowerUrl = entry.workerUrl.trim().toLowerCase();
    return <CliSavedWorkerProfile>[
      entry,
      ...savedWorkers.where(
        (w) =>
            w.name.toLowerCase() != lowerName &&
            w.workerUrl.trim().toLowerCase() != lowerUrl,
      ),
    ];
  }

  /// Returns an updated [savedWorkers] list excluding entries matching [nameOrUrl].
  List<CliSavedWorkerProfile> removeSavedWorker(String nameOrUrl) {
    final matched = findSavedWorker(nameOrUrl);
    if (matched == null) return savedWorkers;
    return savedWorkers
        .where(
          (w) =>
              w.name.toLowerCase() != matched.name.toLowerCase() &&
              w.workerUrl.trim().toLowerCase() !=
                  matched.workerUrl.trim().toLowerCase(),
        )
        .toList(growable: false);
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'baseUrl': baseUrl,
        'username': username,
        'systemType': systemType,
        'cookies': Map<String, String>.from(cookies),
        'relayUrl': relayUrl,
        'workerUrl': ?workerUrl,
        'apiKey': ?apiKey,
        if (savedWorkers.isNotEmpty)
          'savedWorkers': savedWorkers.map((w) => w.toJson()).toList(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'backendName': backendName,
      };

  factory CliSessionRecord.fromJson(Map<String, Object?> json) {
    final workerUrl = _readOptionalString(json, 'workerUrl');
    final apiKey = _readOptionalString(json, 'apiKey');

    final rawSavedWorkers = json['savedWorkers'];
    final parsedSavedWorkers = <CliSavedWorkerProfile>[];
    if (rawSavedWorkers != null) {
      if (rawSavedWorkers is! List<Object?>) {
        throw const FormatException(
          'Invalid CliSessionRecord: "savedWorkers" must be a JSON array.',
        );
      }
      for (final item in rawSavedWorkers) {
        if (item is! Map<Object?, Object?>) {
          throw const FormatException(
            'Invalid CliSessionRecord: savedWorkers items must be JSON objects.',
          );
        }
        parsedSavedWorkers.add(
          CliSavedWorkerProfile.fromJson(Map<String, Object?>.from(item)),
        );
      }
    }

    final rawBaseUrl = json['baseUrl'];
    final hasWorker = (workerUrl != null && workerUrl.isNotEmpty) ||
        parsedSavedWorkers.isNotEmpty;
    if (rawBaseUrl is! String || (rawBaseUrl.trim().isEmpty && !hasWorker)) {
      throw const FormatException(
        'Invalid CliSessionRecord: "baseUrl" must be a non-empty string.',
      );
    }

    final username = _readOptionalString(json, 'username');
    final systemType = _readOptionalString(json, 'systemType');
    final relayUrl = _readOptionalString(json, 'relayUrl');
    final backendName = _readOptionalString(json, 'backendName') ?? 'unknown';

    final rawCookies = json['cookies'];
    final parsedCookies = <String, String>{};
    if (rawCookies != null) {
      if (rawCookies is! Map<Object?, Object?>) {
        throw const FormatException(
          'Invalid CliSessionRecord: "cookies" must be a JSON object.',
        );
      }
      for (final entry in rawCookies.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || value is! String) {
          throw const FormatException(
            'Invalid CliSessionRecord: cookie names and values must be strings.',
          );
        }
        final trimmedKey = key.trim();
        if (trimmedKey.isNotEmpty) {
          parsedCookies[trimmedKey] = value;
        }
      }
    }

    final rawUpdatedAt = json['updatedAt'];
    final DateTime parsedUpdatedAt;
    if (rawUpdatedAt == null) {
      parsedUpdatedAt = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    } else if (rawUpdatedAt is String && rawUpdatedAt.trim().isNotEmpty) {
      parsedUpdatedAt = DateTime.parse(rawUpdatedAt.trim()).toUtc();
    } else {
      throw const FormatException(
        'Invalid CliSessionRecord: "updatedAt" must be an ISO-8601 string.',
      );
    }

    return CliSessionRecord(
      baseUrl: rawBaseUrl.trim(),
      username: username,
      systemType: systemType,
      cookies: parsedCookies,
      relayUrl: relayUrl,
      workerUrl: workerUrl,
      apiKey: apiKey,
      savedWorkers: parsedSavedWorkers,
      updatedAt: parsedUpdatedAt,
      backendName: backendName,
    );
  }

  CliSessionRecord copyWith({
    String? baseUrl,
    String? username,
    String? password,
    String? systemType,
    Map<String, String>? cookies,
    String? relayUrl,
    String? workerUrl,
    String? apiKey,
    List<CliSavedWorkerProfile>? savedWorkers,
    DateTime? updatedAt,
    String? backendName,
    bool clearUsername = false,
    bool clearPassword = false,
    bool clearSystemType = false,
    bool clearRelayUrl = false,
    bool clearWorkerUrl = false,
    bool clearApiKey = false,
  }) =>
      CliSessionRecord(
        baseUrl: baseUrl ?? this.baseUrl,
        username: clearUsername ? null : (username ?? this.username),
        password: clearPassword ? null : (password ?? this.password),
        systemType: clearSystemType ? null : (systemType ?? this.systemType),
        cookies: cookies ?? this.cookies,
        relayUrl: clearRelayUrl ? null : (relayUrl ?? this.relayUrl),
        workerUrl: clearWorkerUrl ? null : (workerUrl ?? this.workerUrl),
        apiKey: clearApiKey ? null : (apiKey ?? this.apiKey),
        savedWorkers: savedWorkers ?? this.savedWorkers,
        updatedAt: updatedAt ?? this.updatedAt,
        backendName: backendName ?? this.backendName,
      );

  static String? _readOptionalString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! String) {
      throw FormatException(
        'Invalid CliSessionRecord: "$key" must be a string or null.',
      );
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CliSessionRecord) return false;
    return baseUrl == other.baseUrl &&
        username == other.username &&
        password == other.password &&
        systemType == other.systemType &&
        relayUrl == other.relayUrl &&
        workerUrl == other.workerUrl &&
        apiKey == other.apiKey &&
        updatedAt.isAtSameMomentAs(other.updatedAt) &&
        backendName == other.backendName &&
        _mapsEqual(cookies, other.cookies) &&
        _listsEqual(savedWorkers, other.savedWorkers);
  }

  @override
  int get hashCode => Object.hash(
        baseUrl,
        username,
        password,
        systemType,
        relayUrl,
        workerUrl,
        apiKey,
        updatedAt.millisecondsSinceEpoch,
        backendName,
        Object.hashAllUnordered(
          cookies.entries.map((e) => Object.hash(e.key, e.value)),
        ),
        Object.hashAll(savedWorkers),
      );

  @override
  String toString() => 'CliSessionRecord('
      'baseUrl: $baseUrl, '
      'username: $username, '
      'systemType: $systemType, '
      'cookies: ${cookies.length}, '
      'relayUrl: $relayUrl, '
      'workerUrl: $workerUrl, '
      'hasApiKey: ${apiKey != null && apiKey!.isNotEmpty}, '
      'savedWorkers: ${savedWorkers.length}, '
      'backendName: $backendName)';

  static bool _mapsEqual(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  static bool _listsEqual<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
