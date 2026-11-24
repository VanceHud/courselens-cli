/// 已保存的有状态 Cloudflare Worker 网关元数据（不含明文 API Key）。
class SavedWorkerGateway {
  const SavedWorkerGateway({
    required this.id,
    required this.workerUrl,
    this.label = '',
    this.schoolId = '',
    this.schoolName = '',
    this.accountKey = '',
    this.studentName = '',
    this.keyHint = '',
    this.updatedAtEpochMs = 0,
  });

  final String id;
  final String workerUrl;
  final String label;
  final String schoolId;
  final String schoolName;
  final String accountKey;
  final String studentName;

  /// 脱敏尾号提示（如 `••••9f2a`），绝不落盘明文密钥。
  final String keyHint;
  final int updatedAtEpochMs;

  /// 基于规范化后的 `workerUrl` 生成稳定的 ASCII 标识符，用于跨平台凭据保险箱索引。
  static String deriveId(String normalizedWorkerUrl) {
    final clean = normalizedWorkerUrl.trim().toLowerCase();
    var hash = 0x811c9dc5;
    for (final codeUnit in clean.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    final hex = hash.toRadixString(16).padLeft(8, '0');
    final host = Uri.tryParse(clean)?.host.replaceAll(RegExp(r'[^a-z0-9.-]'), '_') ?? 'worker';
    return 'wg_${host}_$hex';
  }

  /// 生成仅展示末尾 4 位的脱敏提示（如 `••••9f2a`）。
  static String maskApiKeyHint(String rawApiKey) {
    final trimmed = rawApiKey.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.length <= 4) return '••••';
    return '••••${trimmed.substring(trimmed.length - 4)}';
  }

  String get displayTitle {
    if (label.trim().isNotEmpty) return label.trim();
    if (schoolName.trim().isNotEmpty) {
      if (studentName.trim().isNotEmpty) {
        return '${schoolName.trim()} · ${studentName.trim()}';
      }
      return schoolName.trim();
    }
    final host = Uri.tryParse(workerUrl)?.host ?? '';
    return host.isNotEmpty ? host : workerUrl;
  }

  String get displaySubtitle {
    final parts = <String>[
      if (schoolName.trim().isNotEmpty && label.trim().isNotEmpty)
        schoolName.trim(),
      if (accountKey.trim().isNotEmpty) accountKey.trim(),
      workerUrl,
    ];
    return parts.join(' · ');
  }

  SavedWorkerGateway copyWith({
    String? id,
    String? workerUrl,
    String? label,
    String? schoolId,
    String? schoolName,
    String? accountKey,
    String? studentName,
    String? keyHint,
    int? updatedAtEpochMs,
  }) =>
      SavedWorkerGateway(
        id: id ?? this.id,
        workerUrl: workerUrl ?? this.workerUrl,
        label: label ?? this.label,
        schoolId: schoolId ?? this.schoolId,
        schoolName: schoolName ?? this.schoolName,
        accountKey: accountKey ?? this.accountKey,
        studentName: studentName ?? this.studentName,
        keyHint: keyHint ?? this.keyHint,
        updatedAtEpochMs: updatedAtEpochMs ?? this.updatedAtEpochMs,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'workerUrl': workerUrl,
        if (label.isNotEmpty) 'label': label,
        if (schoolId.isNotEmpty) 'schoolId': schoolId,
        if (schoolName.isNotEmpty) 'schoolName': schoolName,
        if (accountKey.isNotEmpty) 'accountKey': accountKey,
        if (studentName.isNotEmpty) 'studentName': studentName,
        if (keyHint.isNotEmpty) 'keyHint': keyHint,
        'updatedAtEpochMs': updatedAtEpochMs,
      };

  factory SavedWorkerGateway.fromJson(Map<String, dynamic> json) {
    final workerUrl = _str(json, 'workerUrl');
    final rawId = _str(json, 'id');
    return SavedWorkerGateway(
      id: rawId.isNotEmpty ? rawId : deriveId(workerUrl),
      workerUrl: workerUrl,
      label: _str(json, 'label'),
      schoolId: _str(json, 'schoolId'),
      schoolName: _str(json, 'schoolName'),
      accountKey: _str(json, 'accountKey'),
      studentName: _str(json, 'studentName'),
      keyHint: _str(json, 'keyHint'),
      updatedAtEpochMs: _int(json, 'updatedAtEpochMs'),
    );
  }
}

/// 云端任务执行日志条目（适用于成绩/考试巡检与主动心跳）。
class CloudTaskLogEntry {
  const CloudTaskLogEntry({
    this.atMs,
    this.at,
    required this.status,
    this.durationMs,
    required this.message,
    this.taskId = '',
    this.taskName = '',
    this.targetId = '',
  });

  final int? atMs;
  final String? at;
  final String status;
  final int? durationMs;
  final String message;
  final String taskId;
  final String taskName;
  final String targetId;

  Map<String, Object?> toJson() => <String, Object?>{
        if (atMs != null) 'atMs': atMs,
        if (at != null) 'at': at,
        'status': status,
        if (durationMs != null) 'durationMs': durationMs,
        'message': message,
        if (taskId.isNotEmpty) 'taskId': taskId,
        if (taskName.isNotEmpty) 'taskName': taskName,
        if (targetId.isNotEmpty) 'targetId': targetId,
      };

  factory CloudTaskLogEntry.fromJson(Map<String, dynamic> json) =>
      CloudTaskLogEntry(
        atMs: _intOrNull(json, 'atMs'),
        at: _strOrNull(json, 'at'),
        status: _str(json, 'status', 'INFO'),
        durationMs: _intOrNull(json, 'durationMs'),
        message: _str(json, 'message'),
        taskId: _str(json, 'taskId'),
        taskName: _str(json, 'taskName'),
        targetId: _str(json, 'targetId'),
      );
}

/// 云端任务运行指标。
class CloudTaskMetrics {
  const CloudTaskMetrics({
    this.baselineInitialized = false,
    this.trackedItemCount = 0,
    this.totalRuns = 0,
    this.changeCount = 0,
    this.lastDurationMs,
    this.lastError = '',
  });

  final bool baselineInitialized;
  final int trackedItemCount;
  final int totalRuns;
  final int changeCount;
  final int? lastDurationMs;
  final String lastError;

  Map<String, Object?> toJson() => <String, Object?>{
        'baselineInitialized': baselineInitialized,
        'trackedItemCount': trackedItemCount,
        'totalRuns': totalRuns,
        'changeCount': changeCount,
        'lastDurationMs': lastDurationMs,
        'lastError': lastError,
      };

  factory CloudTaskMetrics.fromJson(Map<String, dynamic> json) =>
      CloudTaskMetrics(
        baselineInitialized: json['baselineInitialized'] == true,
        trackedItemCount: _int(json, 'trackedItemCount'),
        totalRuns: _int(json, 'totalRuns'),
        changeCount: _int(json, 'changeCount'),
        lastDurationMs: _intOrNull(json, 'lastDurationMs'),
        lastError: _str(json, 'lastError'),
      );
}

/// 成绩或考试巡检检测到的单条变动记录。
class WorkerMonitorChangeItem {
  const WorkerMonitorChangeItem({
    required this.changeType,
    this.detectedAt,
    this.term = '',
    this.courseCode = '',
    required this.courseName,
    this.score = '',
    this.gpa = '',
    this.credit = '',
    this.examName = '',
    this.time = '',
    this.location = '',
    this.seat = '',
  });

  final String changeType;
  final String? detectedAt;
  final String term;
  final String courseCode;
  final String courseName;
  final String score;
  final String gpa;
  final String credit;
  final String examName;
  final String time;
  final String location;
  final String seat;

  bool get isExamChange =>
      time.isNotEmpty ||
      location.isNotEmpty ||
      seat.isNotEmpty ||
      examName.isNotEmpty;

  String get summaryLine {
    if (isExamChange) {
      final parts = <String>[
        if (term.isNotEmpty) '[$term]',
        courseName,
        if (examName.isNotEmpty) examName,
        if (time.isNotEmpty) time,
        if (location.isNotEmpty) location,
        if (seat.isNotEmpty) '座号 $seat',
      ];
      return parts.join(' · ');
    }
    final parts = <String>[
      if (term.isNotEmpty) '[$term]',
      courseName,
      if (score.isNotEmpty) '成绩 $score',
      if (gpa.isNotEmpty) '绩点 $gpa',
      if (credit.isNotEmpty) '$credit 学分',
    ];
    return parts.join(' · ');
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'changeType': changeType,
        if (detectedAt != null) 'detectedAt': detectedAt,
        if (term.isNotEmpty) 'term': term,
        if (courseCode.isNotEmpty) 'courseCode': courseCode,
        'courseName': courseName,
        if (score.isNotEmpty) 'score': score,
        if (gpa.isNotEmpty) 'gpa': gpa,
        if (credit.isNotEmpty) 'credit': credit,
        if (examName.isNotEmpty) 'examName': examName,
        if (time.isNotEmpty) 'time': time,
        if (location.isNotEmpty) 'location': location,
        if (seat.isNotEmpty) 'seat': seat,
      };

  factory WorkerMonitorChangeItem.fromJson(Map<String, dynamic> json) =>
      WorkerMonitorChangeItem(
        changeType: _str(json, 'changeType', 'ADDED'),
        detectedAt: _strOrNull(json, 'detectedAt'),
        term: _str(json, 'term'),
        courseCode: _str(json, 'courseCode'),
        courseName: _str(json, 'courseName'),
        score: _str(json, 'score'),
        gpa: _str(json, 'gpa'),
        credit: _str(json, 'credit'),
        examName: _str(json, 'examName'),
        time: _str(json, 'time'),
        location: _str(json, 'location'),
        seat: _str(json, 'seat'),
      );
}

/// 统一云端任务列表中的单个任务摘要（`GET /v1/tasks`）。
class CloudTaskSummary {
  const CloudTaskSummary({
    required this.taskId,
    this.rawId = '',
    required this.type,
    required this.title,
    this.subtitle = '',
    required this.enabled,
    this.canToggleDirectly = true,
    this.requiresWriteConfirmToRun = false,
    required this.status,
    this.intervalSec = 0,
    this.mode = 'PERIODIC',
    this.startAtEpochSeconds,
    this.lastRunAt,
    this.nextWakeAt,
    this.lastSummary = '',
    this.trackedItemCount = 0,
    this.changeCount = 0,
  });

  final String taskId;
  final String rawId;

  /// `MONITOR_GRADES` | `MONITOR_EXAMS` | `SESSION_KEEPALIVE`
  final String type;
  final String title;
  final String subtitle;
  final bool enabled;
  final bool canToggleDirectly;
  final bool requiresWriteConfirmToRun;
  final String status;
  final int intervalSec;
  final String mode;
  final int? startAtEpochSeconds;
  final String? lastRunAt;
  final String? nextWakeAt;
  final String lastSummary;
  final int trackedItemCount;
  final int changeCount;

  bool get isScheduledCheck =>
      type == 'MONITOR_GRADES' ||
      type == 'MONITOR_EXAMS' ||
      type == 'SESSION_KEEPALIVE';

  Map<String, Object?> toJson() => <String, Object?>{
        'taskId': taskId,
        if (rawId.isNotEmpty) 'rawId': rawId,
        'type': type,
        'title': title,
        'subtitle': subtitle,
        'enabled': enabled,
        'canToggleDirectly': canToggleDirectly,
        'requiresWriteConfirmToRun': requiresWriteConfirmToRun,
        'status': status,
        'intervalSec': intervalSec,
        'mode': mode,
        if (startAtEpochSeconds != null)
          'startAtEpochSeconds': startAtEpochSeconds,
        'lastRunAt': lastRunAt,
        'nextWakeAt': nextWakeAt,
        'lastSummary': lastSummary,
        'trackedItemCount': trackedItemCount,
        'changeCount': changeCount,
      };

  factory CloudTaskSummary.fromJson(Map<String, dynamic> json) =>
      CloudTaskSummary(
        taskId: _str(json, 'taskId'),
        rawId: _str(json, 'rawId'),
        type: _str(json, 'type'),
        title: _str(json, 'title'),
        subtitle: _str(json, 'subtitle'),
        enabled: json['enabled'] == true,
        canToggleDirectly: json['canToggleDirectly'] != false,
        requiresWriteConfirmToRun: json['requiresWriteConfirmToRun'] == true,
        status: _str(json, 'status', 'DISABLED'),
        intervalSec: _int(json, 'intervalSec'),
        mode: _str(json, 'mode', 'PERIODIC'),
        startAtEpochSeconds: _intOrNull(json, 'startAtEpochSeconds'),
        lastRunAt: _strOrNull(json, 'lastRunAt'),
        nextWakeAt: _strOrNull(json, 'nextWakeAt'),
        lastSummary: _str(json, 'lastSummary'),
        trackedItemCount: _int(json, 'trackedItemCount'),
        changeCount: _int(json, 'changeCount'),
      );
}

/// `session:keepalive` 任务详情附带的云端会话诊断信息。
class CloudTaskSessionInfo {
  const CloudTaskSessionInfo({
    this.authenticated = false,
    this.hasPasswordAuth = false,
    this.lazyKeepaliveActive = false,
    this.cookieCount = 0,
    this.username = '',
    this.lastVerifiedAt,
  });

  final bool authenticated;
  final bool hasPasswordAuth;
  final bool lazyKeepaliveActive;
  final int cookieCount;
  final String username;
  final String? lastVerifiedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'authenticated': authenticated,
        'hasPasswordAuth': hasPasswordAuth,
        'lazyKeepaliveActive': lazyKeepaliveActive,
        'cookieCount': cookieCount,
        'username': username,
        'lastVerifiedAt': lastVerifiedAt,
      };

  factory CloudTaskSessionInfo.fromJson(Map<String, dynamic> json) =>
      CloudTaskSessionInfo(
        authenticated: json['authenticated'] == true,
        hasPasswordAuth: json['hasPasswordAuth'] == true,
        lazyKeepaliveActive: json['lazyKeepaliveActive'] == true,
        cookieCount: _int(json, 'cookieCount'),
        username: _str(json, 'username'),
        lastVerifiedAt: _strOrNull(json, 'lastVerifiedAt'),
      );
}

/// 单个云端任务的完整详情视图（`GET /v1/tasks/:taskId`）。
class CloudTaskDetail {
  const CloudTaskDetail({
    required this.summary,
    this.metrics = const CloudTaskMetrics(),
    this.sessionInfo,
    this.recentChanges = const <WorkerMonitorChangeItem>[],
    this.logs = const <CloudTaskLogEntry>[],
  });

  final CloudTaskSummary summary;
  final CloudTaskMetrics metrics;
  final CloudTaskSessionInfo? sessionInfo;
  final List<WorkerMonitorChangeItem> recentChanges;
  final List<CloudTaskLogEntry> logs;

  String get taskId => summary.taskId;
  String get type => summary.type;
  String get title => summary.title;
  bool get enabled => summary.enabled;
  String get status => summary.status;
  int get intervalSec => summary.intervalSec;

  Map<String, Object?> toJson() => <String, Object?>{
        ...summary.toJson(),
        'metrics': metrics.toJson(),
        if (sessionInfo != null) 'sessionInfo': sessionInfo!.toJson(),
        'recentChanges': recentChanges.map((c) => c.toJson()).toList(),
        'logs': logs.map((l) => l.toJson()).toList(),
      };

  factory CloudTaskDetail.fromJson(Map<String, dynamic> json) {
    final summary = CloudTaskSummary.fromJson(json);
    final rawMetrics = json['metrics'];
    final metrics = rawMetrics is Map
        ? CloudTaskMetrics.fromJson(Map<String, dynamic>.from(rawMetrics))
        : const CloudTaskMetrics();
    final rawSession = json['sessionInfo'];
    final sessionInfo = rawSession is Map
        ? CloudTaskSessionInfo.fromJson(Map<String, dynamic>.from(rawSession))
        : null;
    final recentChanges =
        _parseList(json['recentChanges'], WorkerMonitorChangeItem.fromJson);
    final logs = _parseList(json['logs'], CloudTaskLogEntry.fromJson);

    return CloudTaskDetail(
      summary: summary,
      metrics: metrics,
      sessionInfo: sessionInfo,
      recentChanges: recentChanges,
      logs: logs,
    );
  }
}

/// 统一云端任务列表快照（`GET /v1/tasks`）。
class CloudTaskListSnapshot {
  const CloudTaskListSnapshot({
    this.ok = true,
    this.lazyKeepaliveActive = false,
    this.hasPasswordAuth = false,
    this.webhookConfigured = false,
    this.activeTaskCount = 0,
    this.nextAlarmAt,
    this.tasks = const <CloudTaskSummary>[],
  });

  final bool ok;
  final bool lazyKeepaliveActive;
  final bool hasPasswordAuth;
  final bool webhookConfigured;
  final int activeTaskCount;
  final String? nextAlarmAt;
  final List<CloudTaskSummary> tasks;

  CloudTaskSummary? findTask(String taskId) {
    for (final t in tasks) {
      if (t.taskId == taskId) return t;
    }
    return null;
  }

  List<CloudTaskSummary> get scheduledCheckTasks =>
      tasks.where((t) => t.isScheduledCheck).toList(growable: false);

  Map<String, Object?> toJson() => <String, Object?>{
        'ok': ok,
        'lazyKeepaliveActive': lazyKeepaliveActive,
        'hasPasswordAuth': hasPasswordAuth,
        'webhookConfigured': webhookConfigured,
        'activeTaskCount': activeTaskCount,
        'nextAlarmAt': nextAlarmAt,
        'tasks': tasks.map((t) => t.toJson()).toList(),
      };

  factory CloudTaskListSnapshot.fromJson(Map<String, dynamic> json) {
    final tasks = _parseList(json['tasks'], CloudTaskSummary.fromJson);
    return CloudTaskListSnapshot(
      ok: json['ok'] != false,
      lazyKeepaliveActive: json['lazyKeepaliveActive'] == true,
      hasPasswordAuth: json['hasPasswordAuth'] == true,
      webhookConfigured: json['webhookConfigured'] == true,
      activeTaskCount: _int(json, 'activeTaskCount'),
      nextAlarmAt: _strOrNull(json, 'nextAlarmAt'),
      tasks: tasks,
    );
  }
}

/// Worker 云端推送 Webhook 配置状态（URL 自动脱敏、密钥不回传）。
class WorkerWebhookConfig {
  const WorkerWebhookConfig({
    this.configured = false,
    this.enabled = false,
    this.provider = 'auto',
    this.resolvedProvider = 'generic',
    this.maskedUrl = '',
    this.hasSecret = false,
    this.telegramChatId = '',
    this.onGradeChange = true,
    this.onExamChange = true,
    this.updatedAt,
    this.lastSentAt,
    this.lastError = '',
  });

  final bool configured;
  final bool enabled;
  final String provider;
  final String resolvedProvider;
  final String maskedUrl;
  final bool hasSecret;
  final String telegramChatId;
  final bool onGradeChange;
  final bool onExamChange;
  final String? updatedAt;
  final String? lastSentAt;
  final String lastError;

  Map<String, Object?> toJson() => <String, Object?>{
        'configured': configured,
        'enabled': enabled,
        'provider': provider,
        'resolvedProvider': resolvedProvider,
        'maskedUrl': maskedUrl,
        'hasSecret': hasSecret,
        'telegramChatId': telegramChatId,
        'onGradeChange': onGradeChange,
        'onExamChange': onExamChange,
        'updatedAt': updatedAt,
        'lastSentAt': lastSentAt,
        'lastError': lastError,
      };

  factory WorkerWebhookConfig.fromJson(Map<String, dynamic> json) =>
      WorkerWebhookConfig(
        configured: json['configured'] == true,
        enabled: json['enabled'] == true,
        provider: _str(json, 'provider', 'auto'),
        resolvedProvider: _str(json, 'resolvedProvider', 'generic'),
        maskedUrl: _str(json, 'maskedUrl'),
        hasSecret: json['hasSecret'] == true,
        telegramChatId: _str(json, 'telegramChatId'),
        onGradeChange: json['onGradeChange'] != false,
        onExamChange: json['onExamChange'] != false,
        updatedAt: _strOrNull(json, 'updatedAt'),
        lastSentAt: _strOrNull(json, 'lastSentAt'),
        lastError: _str(json, 'lastError'),
      );
}

/// 单个云端巡检子项（`grades` 或 `exams`）的状态快照。
class WorkerSingleMonitorView {
  const WorkerSingleMonitorView({
    required this.taskId,
    required this.kind,
    this.enabled = false,
    this.intervalSec = 1800,
    this.baselineInitialized = false,
    this.trackedItemCount = 0,
    this.totalRuns = 0,
    this.changeCount = 0,
    this.lastDurationMs,
    this.lastRunAt,
    this.nextWakeAt,
    this.lastError = '',
    this.lastSummary = '未开启（默认关闭）',
    this.recentChanges = const <WorkerMonitorChangeItem>[],
    this.logs = const <CloudTaskLogEntry>[],
  });

  final String taskId;
  final String kind;
  final bool enabled;
  final int intervalSec;
  final bool baselineInitialized;
  final int trackedItemCount;
  final int totalRuns;
  final int changeCount;
  final int? lastDurationMs;
  final String? lastRunAt;
  final String? nextWakeAt;
  final String lastError;
  final String lastSummary;
  final List<WorkerMonitorChangeItem> recentChanges;
  final List<CloudTaskLogEntry> logs;

  Map<String, Object?> toJson() => <String, Object?>{
        'taskId': taskId,
        'kind': kind,
        'enabled': enabled,
        'intervalSec': intervalSec,
        'baselineInitialized': baselineInitialized,
        'trackedItemCount': trackedItemCount,
        'totalRuns': totalRuns,
        'changeCount': changeCount,
        'lastDurationMs': lastDurationMs,
        'lastRunAt': lastRunAt,
        'nextWakeAt': nextWakeAt,
        'lastError': lastError,
        'lastSummary': lastSummary,
        'recentChanges': recentChanges.map((c) => c.toJson()).toList(),
        'logs': logs.map((l) => l.toJson()).toList(),
      };

  factory WorkerSingleMonitorView.fromJson(Map<String, dynamic> json) {
    final kind = _str(json, 'kind', 'grades');
    final changes =
        _parseList(json['recentChanges'], WorkerMonitorChangeItem.fromJson);
    final logs = _parseList(json['logs'], CloudTaskLogEntry.fromJson);
    return WorkerSingleMonitorView(
      taskId: _str(json, 'taskId', 'monitor:$kind'),
      kind: kind,
      enabled: json['enabled'] == true,
      intervalSec: _int(json, 'intervalSec', kind == 'exams' ? 3600 : 1800),
      baselineInitialized: json['baselineInitialized'] == true,
      trackedItemCount: _int(json, 'trackedItemCount'),
      totalRuns: _int(json, 'totalRuns'),
      changeCount: _int(json, 'changeCount'),
      lastDurationMs: _intOrNull(json, 'lastDurationMs'),
      lastRunAt: _strOrNull(json, 'lastRunAt'),
      nextWakeAt: _strOrNull(json, 'nextWakeAt'),
      lastError: _str(json, 'lastError'),
      lastSummary: _str(json, 'lastSummary', '未开启（默认关闭）'),
      recentChanges: changes,
      logs: logs,
    );
  }
}

/// 成绩与考试巡检状态响应（`GET /v1/monitor`）。
class WorkerMonitorStatus {
  const WorkerMonitorStatus({
    this.ok = true,
    required this.grades,
    required this.exams,
  });

  final bool ok;
  final WorkerSingleMonitorView grades;
  final WorkerSingleMonitorView exams;

  Map<String, Object?> toJson() => <String, Object?>{
        'ok': ok,
        'grades': grades.toJson(),
        'exams': exams.toJson(),
      };

  factory WorkerMonitorStatus.fromJson(Map<String, dynamic> json) {
    final rawGrades = json['grades'];
    final rawExams = json['exams'];
    return WorkerMonitorStatus(
      ok: json['ok'] != false,
      grades: rawGrades is Map
          ? WorkerSingleMonitorView.fromJson(
              Map<String, dynamic>.from(rawGrades),
            )
          : const WorkerSingleMonitorView(
              taskId: 'monitor:grades',
              kind: 'grades',
            ),
      exams: rawExams is Map
          ? WorkerSingleMonitorView.fromJson(
              Map<String, dynamic>.from(rawExams),
            )
          : const WorkerSingleMonitorView(
              taskId: 'monitor:exams',
              kind: 'exams',
              intervalSec: 3600,
            ),
    );
  }
}

/// 有状态 Worker 代理缓存的单个数据分类统计（来自 `GET /v1/cache`）。
class WorkerCacheCategoryStat {
  const WorkerCacheCategoryStat({
    required this.category,
    this.ttlSec = 0,
    this.activeEntries = 0,
    this.bytes = 0,
  });

  final String category;
  final int ttlSec;
  final int activeEntries;
  final int bytes;

  Map<String, Object?> toJson() => <String, Object?>{
        'category': category,
        'ttlSec': ttlSec,
        'activeEntries': activeEntries,
        'bytes': bytes,
      };

  factory WorkerCacheCategoryStat.fromJson(Map<String, dynamic> json) =>
      WorkerCacheCategoryStat(
        category: _str(json, 'category'),
        ttlSec: _int(json, 'ttlSec'),
        activeEntries: _int(json, 'activeEntries'),
        bytes: _int(json, 'bytes'),
      );
}

/// 有状态 Worker 代理缓存总览与命中统计（来自 `GET /v1/cache`）。
class WorkerCacheStats {
  const WorkerCacheStats({
    this.ok = true,
    this.enabled = true,
    this.entryCount = 0,
    this.totalBytes = 0,
    this.hits = 0,
    this.l1Hits = 0,
    this.l2Hits = 0,
    this.misses = 0,
    this.bypasses = 0,
    this.evictions = 0,
    this.categories = const <WorkerCacheCategoryStat>[],
  });

  final bool ok;
  final bool enabled;
  final int entryCount;
  final int totalBytes;
  final int hits;
  final int l1Hits;
  final int l2Hits;
  final int misses;
  final int bypasses;
  final int evictions;
  final List<WorkerCacheCategoryStat> categories;

  String get formattedSize {
    if (totalBytes <= 0) return '0 B';
    if (totalBytes < 1024) return '$totalBytes B';
    final kb = totalBytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(kb >= 10 ? 0 : 1)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(2)} MB';
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'ok': ok,
        'enabled': enabled,
        'entryCount': entryCount,
        'totalBytes': totalBytes,
        'formattedSize': formattedSize,
        'hits': hits,
        'l1Hits': l1Hits,
        'l2Hits': l2Hits,
        'misses': misses,
        'bypasses': bypasses,
        'evictions': evictions,
        'categories': categories.map((c) => c.toJson()).toList(),
      };

  factory WorkerCacheStats.fromJson(Map<String, dynamic> json) {
    final rawStats = json['stats'];
    final statsMap = rawStats is Map
        ? Map<String, dynamic>.from(rawStats)
        : json;
    return WorkerCacheStats(
      ok: json['ok'] != false,
      enabled: json['enabled'] != false,
      entryCount: _int(statsMap, 'entryCount'),
      totalBytes: _int(statsMap, 'totalBytes'),
      hits: _int(statsMap, 'hits'),
      l1Hits: _int(statsMap, 'l1Hits'),
      l2Hits: _int(statsMap, 'l2Hits'),
      misses: _int(statsMap, 'misses'),
      bypasses: _int(statsMap, 'bypasses'),
      evictions: _int(statsMap, 'evictions'),
      categories: _parseList(
        json['categories'],
        WorkerCacheCategoryStat.fromJson,
      ),
    );
  }
}

String? _scalarText(Object? value) => switch (value) {
      String() => value,
      num() || bool() => value.toString(),
      _ => null,
    };

/// 读取并 trim 字符串字段；数字/布尔值按文本读取，缺失或其他类型时回退为 [fallback]。
String _str(Map<String, dynamic> json, String key, [String fallback = '']) =>
    (_scalarText(json[key]) ?? fallback).trim();

/// 读取可空字符串字段（不 trim）；数字/布尔值按文本读取，其他类型视为缺失。
String? _strOrNull(Map<String, dynamic> json, String key) =>
    _scalarText(json[key]);

/// 读取整数字段；兼容数字字符串，缺失或无法解析时返回 null。
int? _intOrNull(Map<String, dynamic> json, String key) {
  final value = json[key];
  final number = value is String ? num.tryParse(value.trim()) : value;
  return number is num && number.isFinite ? number.toInt() : null;
}

int _int(Map<String, dynamic> json, String key, [int fallback = 0]) =>
    _intOrNull(json, key) ?? fallback;

/// 解析对象数组：非数组返回空列表，跳过非对象元素。
List<T> _parseList<T>(
  Object? raw,
  T Function(Map<String, dynamic> json) fromJson,
) =>
    raw is List
        ? raw
            .whereType<Map<dynamic, dynamic>>()
            .map((m) => fromJson(Map<String, dynamic>.from(m)))
            .toList(growable: false)
        : List<T>.unmodifiable(const []);
