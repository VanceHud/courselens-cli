import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;

import 'package:http/http.dart' as http;

import '../data/http/worker_session_http_engine.dart';
import 'cli_args.dart';
import 'store/cli_session_store.dart';

/// 单个组件（cli / skill / worker）的更新检查或执行结果。
class CliUpdateComponentResult {
  const CliUpdateComponentResult({
    required this.status,
    required this.detail,
  });

  /// `up-to-date` | `updated` | `update-available` | `skipped` | `error`
  final String status;
  final String detail;

  String get statusLabel => switch (status) {
        'up-to-date' => '已是最新',
        'updated' => '已更新',
        'update-available' => '有可用更新',
        'skipped' => '已跳过',
        'error' => '失败',
        _ => status,
      };

  Map<String, Object?> toJson() => <String, Object?>{
        'status': status,
        'detail': detail,
      };
}

/// `courselens update` 的三组件汇总报告。
class CliUpdateReport {
  CliUpdateReport(this.components);

  /// 键固定为 `cli` / `skill` / `worker`（仅包含本次被选中的组件）。
  final Map<String, CliUpdateComponentResult> components;

  bool get hasError =>
      components.values.any((c) => c.status == 'error');

  Map<String, Object?> toJson() => <String, Object?>{
        for (final entry in components.entries) entry.key: entry.value.toJson(),
      };

  List<String> textLines() {
    const labels = <String, String>{
      'cli': 'CLI',
      'skill': 'Skill',
      'worker': 'Worker 网关',
    };
    final lines = <String>[];
    for (final entry in components.entries) {
      final label = labels[entry.key] ?? entry.key;
      final detailLines = entry.value.detail.split('\n');
      lines.add(
        '$label：${entry.value.statusLabel} — ${detailLines.first}',
      );
      for (final extra in detailLines.skip(1)) {
        lines.add('  $extra');
      }
    }
    return lines;
  }
}

/// `courselens update` 的全部更新逻辑：CLI 本体、Agent Skill、会话网关 Worker。
///
/// 更新来源仓库默认为 [defaultUpdateRepo]，可用环境变量
/// `COURSELENS_UPDATE_REPO` 覆盖（便于镜像或自建分发）。
class CliUpdater {
  CliUpdater({
    required Map<String, String> environment,
    http.Client? httpClient,
  })  : _environment = environment,
        _httpClient = httpClient;

  static const String defaultUpdateRepo = 'VanceHud/courselens-cli';

  /// 与 Worker 源码 `workers/session_gateway/src/index.js` 中的
  /// `GATEWAY_VERSION` 常量保持同步；有源码检出时以源码常量为准。
  static const String gatewayVersion = '1.1.8';

  final Map<String, String> _environment;
  final http.Client? _httpClient;

  String get _repoSlug {
    final override = _envValue('COURSELENS_UPDATE_REPO')?.trim();
    return (override != null && override.isNotEmpty)
        ? override
        : defaultUpdateRepo;
  }

  String? _envValue(String key) =>
      _environment[key] ?? io.Platform.environment[key];

  Map<String, String> get _processEnv => <String, String>{
        ...io.Platform.environment,
        ..._environment,
        'GIT_TERMINAL_PROMPT': '0',
      };

  String get _homeDir =>
      _envValue('HOME') ?? io.Platform.environment['HOME'] ?? '';

  /// 执行更新流程（`inv.updateCheck` 为真时只检查不修改）。
  Future<CliUpdateReport> run(ParsedCliInvocation inv) async {
    final targets = inv.updateTargets;
    bool wanted(String name) => targets.isEmpty || targets.contains(name);

    final checkout = _locateCheckout();
    final components = <String, CliUpdateComponentResult>{};

    if (wanted('cli')) {
      components['cli'] = await _updateCli(
        checkOnly: inv.updateCheck,
        checkout: checkout,
      );
    }
    if (wanted('skill')) {
      components['skill'] = await _updateSkill(
        checkOnly: inv.updateCheck,
        checkout: checkout,
      );
    }
    if (wanted('worker')) {
      components['worker'] = await _updateWorker(
        inv: inv,
        checkOnly: inv.updateCheck,
        checkout: checkout,
      );
    }
    return CliUpdateReport(components);
  }

  // ---------------------------------------------------------------------------
  // 源码检出定位
  // ---------------------------------------------------------------------------

  bool _isCheckout(io.Directory dir) {
    final gitEntity = io.FileSystemEntity.typeSync(
      '${dir.path}${io.Platform.pathSeparator}.git',
      followLinks: false,
    );
    if (gitEntity == io.FileSystemEntityType.notFound) return false;
    final pubspec = io.File(
      '${dir.path}${io.Platform.pathSeparator}pubspec.yaml',
    );
    final toolEntry = io.File(
      '${dir.path}${io.Platform.pathSeparator}tools'
      '${io.Platform.pathSeparator}courselens_cli.dart',
    );
    if (!pubspec.existsSync() || !toolEntry.existsSync()) return false;
    try {
      final content = pubspec.readAsStringSync();
      return RegExp(
        r'^name:\s*courselens\s*$',
        multiLine: true,
      ).hasMatch(content);
    } catch (_) {
      return false;
    }
  }

  io.Directory? _locateCheckout() {
    final sep = io.Platform.pathSeparator;

    final envDir = _envValue('COURSELENS_REPO_DIR')?.trim();
    if (envDir != null && envDir.isNotEmpty) {
      final candidate = io.Directory(envDir);
      if (_isCheckout(candidate)) return candidate;
    }

    // 可执行文件形如 <repo>/build/courselens 时，其父目录即检出根。
    final exeDir = io.File(io.Platform.resolvedExecutable).parent;
    if (exeDir.path.split(sep).last == 'build') {
      final candidate = exeDir.parent;
      if (_isCheckout(candidate)) return candidate;
    }

    // 从当前工作目录逐级向上查找。
    var dir = io.Directory.current;
    while (true) {
      if (_isCheckout(dir)) return dir;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }

    final fallback = io.Directory(
      '$_homeDir$sep.local${sep}share${sep}courselens-cli',
    );
    if (_isCheckout(fallback)) return fallback;

    return null;
  }

  // ---------------------------------------------------------------------------
  // 进程与版本小工具
  // ---------------------------------------------------------------------------

  Future<({int exitCode, String stdout, String stderr})> _runProcess(
    String executable,
    List<String> args, {
    String? workingDirectory,
  }) async {
    final result = await io.Process.run(
      executable,
      args,
      workingDirectory: workingDirectory,
      environment: _processEnv,
      runInShell: io.Platform.isWindows && executable.endsWith('.cmd'),
    );
    return (
      exitCode: result.exitCode,
      stdout: '${result.stdout}',
      stderr: '${result.stderr}',
    );
  }

  static int compareVersions(String a, String b) {
    List<int> parse(String raw) {
      var text = raw.trim();
      if (text.startsWith('v') || text.startsWith('V')) {
        text = text.substring(1);
      }
      final core = text.split(RegExp(r'[-+]')).first;
      return core
          .split('.')
          .map((part) => int.tryParse(part.trim()) ?? 0)
          .toList();
    }

    final pa = parse(a);
    final pb = parse(b);
    final length = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < length; i++) {
      final va = i < pa.length ? pa[i] : 0;
      final vb = i < pb.length ? pb[i] : 0;
      if (va != vb) return va.compareTo(vb);
    }
    return 0;
  }

  String? _findDart() {
    final sep = io.Platform.pathSeparator;
    final exeName = io.Platform.isWindows ? 'dart.exe' : 'dart';
    final pathEnv = _envValue('PATH') ?? '';
    for (final dir in pathEnv.split(io.Platform.isWindows ? ';' : ':')) {
      if (dir.trim().isEmpty) continue;
      final candidate = io.File('${dir.trim()}$sep$exeName');
      if (candidate.existsSync()) return candidate.path;
    }
    final sdkDart = io.File(
      '$_homeDir$sep.local${sep}share${sep}dart-sdk${sep}bin$sep$exeName',
    );
    if (sdkDart.existsSync()) return sdkDart.path;
    return null;
  }

  String? _readCheckoutVersion(String root) {
    final sep = io.Platform.pathSeparator;
    final pubspec = io.File('$root${sep}pubspec.yaml');
    if (!pubspec.existsSync()) return null;
    try {
      final match = RegExp(
        r'^version:\s*([^\s#]+)',
        multiLine: true,
      ).firstMatch(pubspec.readAsStringSync());
      return match?.group(1)?.trim();
    } catch (_) {
      return null;
    }
  }

  /// 把 [source] 产物安全替换到 [targetPath]：先备份 `.bak`，
  /// 经同目录临时文件 + rename 落地（兼容 Windows 运行中 `.exe` 改名替换），失败时原文件保持不动。
  Future<void> _replaceExecutableFile(io.File source, String targetPath) async {
    final targetFile = io.File(targetPath);
    final backup = io.File('$targetPath.bak');
    final tempFile = io.File('$targetPath.new');
    var movedOriginalOnWindows = false;

    try {
      if (tempFile.existsSync()) tempFile.deleteSync();
      source.copySync(tempFile.path);
      if (!io.Platform.isWindows) {
        await io.Process.run('chmod', <String>['+x', tempFile.path]);
      }
      if (targetFile.existsSync()) {
        if (backup.existsSync()) {
          try {
            backup.deleteSync();
          } catch (_) {
            // Windows 上若上次 .bak 仍被句柄占用，回退 .bak.old
          }
        }
        if (io.Platform.isWindows) {
          targetFile.renameSync(backup.path);
          movedOriginalOnWindows = true;
        } else {
          targetFile.copySync(backup.path);
        }
      }
      tempFile.renameSync(targetPath);
    } catch (_) {
      if (movedOriginalOnWindows &&
          !io.File(targetPath).existsSync() &&
          backup.existsSync()) {
        try {
          backup.renameSync(targetPath);
        } catch (_) {
          // 忽略恢复异常
        }
      }
      try {
        if (tempFile.existsSync()) tempFile.deleteSync();
      } catch (_) {
        // 忽略清理失败
      }
      rethrow;
    }
  }

  Future<void> _replaceCurrentExecutable(io.File source) =>
      _replaceExecutableFile(source, io.Platform.resolvedExecutable);

  // ---------------------------------------------------------------------------
  // 1. CLI 本体更新
  // ---------------------------------------------------------------------------

  Future<CliUpdateComponentResult> _updateCli({
    required bool checkOnly,
    required io.Directory? checkout,
  }) async {
    if (checkout != null) {
      return _updateCliFromCheckout(checkOnly: checkOnly, checkout: checkout);
    }
    return _updateCliFromRelease(checkOnly: checkOnly);
  }

  Future<CliUpdateComponentResult> _updateCliFromCheckout({
    required bool checkOnly,
    required io.Directory checkout,
  }) async {
    final root = checkout.path;
    final sep = io.Platform.pathSeparator;
    final builtName = io.Platform.isWindows ? 'courselens.exe' : 'courselens';
    final built = io.File('$root${sep}build$sep$builtName');
    try {
      final fetch = await _runProcess(
        'git',
        <String>['fetch', '--quiet', 'origin'],
        workingDirectory: root,
      );
      if (fetch.exitCode != 0) {
        return CliUpdateComponentResult(
          status: 'error',
          detail: 'git fetch 失败：${_tail(fetch.stderr)}',
        );
      }
      final branchResult = await _runProcess(
        'git',
        <String>['rev-parse', '--abbrev-ref', 'HEAD'],
        workingDirectory: root,
      );
      final branch = branchResult.stdout.trim();
      if (branchResult.exitCode != 0 || branch.isEmpty || branch == 'HEAD') {
        return const CliUpdateComponentResult(
          status: 'error',
          detail: '无法确定源码检出当前分支（游离 HEAD），请手动处理后重试。',
        );
      }
      final upstreamResult = await _runProcess(
        'git',
        <String>['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}'],
        workingDirectory: root,
      );
      final remoteRef = upstreamResult.exitCode == 0 &&
              upstreamResult.stdout.trim().isNotEmpty
          ? upstreamResult.stdout.trim()
          : 'origin/$branch';
      final behindResult = await _runProcess(
        'git',
        <String>['rev-list', '--count', 'HEAD..$remoteRef'],
        workingDirectory: root,
      );
      final behind = int.tryParse(behindResult.stdout.trim()) ?? 0;
      final headResult = await _runProcess(
        'git',
        <String>['rev-parse', '--short', 'HEAD'],
        workingDirectory: root,
      );
      final headShort = headResult.stdout.trim();
      final checkoutVersion = _readCheckoutVersion(root);
      final versionOutdated = checkoutVersion != null &&
          compareVersions(CliArgs.cliVersion, checkoutVersion) < 0;
      final binaryMissing = !built.existsSync();

      if (behind == 0 && !versionOutdated && !binaryMissing) {
        return CliUpdateComponentResult(
          status: 'up-to-date',
          detail: '源码检出 $root 已与 $remoteRef 同步（HEAD $headShort，'
              'CLI ${CliArgs.cliVersion}）。',
        );
      }
      if (checkOnly) {
        if (behind > 0) {
          return CliUpdateComponentResult(
            status: 'update-available',
            detail: '源码检出 $root 落后 $remoteRef $behind 个提交'
                '（当前 HEAD $headShort）。运行 courselens update --cli 拉取并重编译。',
          );
        }
        return CliUpdateComponentResult(
          status: 'update-available',
          detail: '源码检出 $root 已同步（HEAD $headShort），但本地编译产物待更新'
              '（当前运行 ${CliArgs.cliVersion}'
              '${checkoutVersion != null ? "，检出版本 $checkoutVersion" : ""}）。'
              '运行 courselens update --cli 重编译。',
        );
      }

      if (behind > 0) {
        final statusResult = await _runProcess(
          'git',
          <String>['status', '--porcelain'],
          workingDirectory: root,
        );
        if (statusResult.stdout.trim().isNotEmpty) {
          return CliUpdateComponentResult(
            status: 'skipped',
            detail: '源码检出 $root 工作区有未提交改动，已中止 CLI 更新；'
                '请先提交或暂存这些改动后重试。',
          );
        }
        final pull = await _runProcess(
          'git',
          <String>['pull', '--ff-only'],
          workingDirectory: root,
        );
        if (pull.exitCode != 0) {
          return CliUpdateComponentResult(
            status: 'error',
            detail: 'git pull --ff-only 失败：${_tail(pull.stderr)}',
          );
        }
      }

      final dart = _findDart();
      if (dart == null) {
        return const CliUpdateComponentResult(
          status: 'error',
          detail: '已同步最新源码，但未找到 Dart SDK（PATH 与 '
              '~/.local/share/dart-sdk 均无 dart），无法重编译。',
        );
      }
      var pubGet = await _runProcess(
        dart,
        <String>['pub', 'get', '--offline'],
        workingDirectory: root,
      );
      if (pubGet.exitCode != 0) {
        pubGet = await _runProcess(
          dart,
          <String>['pub', 'get'],
          workingDirectory: root,
        );
      }
      if (pubGet.exitCode != 0) {
        return CliUpdateComponentResult(
          status: 'error',
          detail: 'dart pub get 失败：${_tail(pubGet.stderr)}',
        );
      }
      final buildDir = io.Directory('$root${sep}build');
      if (!buildDir.existsSync()) buildDir.createSync(recursive: true);
      final stagedBuilt = io.File('$root${sep}build$sep$builtName.stage');
      if (stagedBuilt.existsSync()) stagedBuilt.deleteSync();
      final compile = await _runProcess(
        dart,
        <String>[
          'compile',
          'exe',
          'tools${sep}courselens_cli.dart',
          '-o',
          'build$sep$builtName.stage',
        ],
        workingDirectory: root,
      );
      if (compile.exitCode != 0) {
        return CliUpdateComponentResult(
          status: 'error',
          detail: '重编译失败：${_tail(compile.stderr)}',
        );
      }
      try {
        await _replaceExecutableFile(stagedBuilt, built.path);
      } finally {
        if (stagedBuilt.existsSync()) {
          try {
            stagedBuilt.deleteSync();
          } catch (_) {}
        }
      }

      final pullSummary = behind > 0 ? '已拉取 $behind 个提交并重编译' : '已基于当前检出重编译';

      // 处理当前正在运行的可执行文件与新产物的关系。
      final exePath = io.Platform.resolvedExecutable;
      final exeType = io.FileSystemEntity.typeSync(
        exePath,
        followLinks: false,
      );
      if (exeType == io.FileSystemEntityType.link) {
        final resolvedTarget = io.File(exePath).resolveSymbolicLinksSync();
        if (resolvedTarget == built.absolute.path) {
          return CliUpdateComponentResult(
            status: 'updated',
            detail: '$pullSummary；当前运行文件是软链，'
                '指向检出产物 ${built.path}，即为最新。',
          );
        }
        return CliUpdateComponentResult(
          status: 'updated',
          detail: '$pullSummary检出产物 ${built.path}；'
              '当前运行文件是软链（→ $resolvedTarget），未改写软链目标。',
        );
      }
      if (io.File(exePath).absolute.path == built.absolute.path) {
        return CliUpdateComponentResult(
          status: 'updated',
          detail: '$pullSummary，当前运行的正是检出产物 '
              '${built.path}。',
        );
      }
      try {
        await _replaceCurrentExecutable(built);
      } catch (error) {
        return CliUpdateComponentResult(
          status: 'error',
          detail: '已重编译 ${built.path}，但覆盖当前运行文件 $exePath 失败'
              '（$error）；原文件未被破坏，备份保留在 $exePath.bak。',
        );
      }
      return CliUpdateComponentResult(
        status: 'updated',
        detail: '$pullSummary，并把新产物安装到 $exePath'
            '（旧版本备份在 $exePath.bak）。',
      );
    } on io.ProcessException catch (error) {
      return CliUpdateComponentResult(
        status: 'error',
        detail: '执行外部命令失败：${error.message}',
      );
    }
  }

  Future<CliUpdateComponentResult> _updateCliFromRelease({
    required bool checkOnly,
  }) async {
    final client = _httpClient ?? http.Client();
    final closeClient = _httpClient == null;
    try {
      final headers = <String, String>{
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'courselens-cli',
      };
      final token = _envValue('GITHUB_TOKEN')?.trim();
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
      final uri = Uri.parse(
        'https://api.github.com/repos/$_repoSlug/releases/latest',
      );
      http.Response response;
      try {
        response = await client
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 30));
      } catch (error) {
        return CliUpdateComponentResult(
          status: 'skipped',
          detail: '无法访问 GitHub Release 接口（$error），本次未检查 CLI 更新。',
        );
      }
      if (response.statusCode == 404) {
        return CliUpdateComponentResult(
          status: 'skipped',
          detail: '暂无 Release 版本，请用源码检出方式安装后更新：'
              'git clone https://github.com/$_repoSlug.git 后在检出目录内运行本 CLI。',
        );
      }
      if (response.statusCode != 200) {
        return CliUpdateComponentResult(
          status: 'skipped',
          detail: 'GitHub Release 接口返回 HTTP ${response.statusCode}，'
              '本次未检查 CLI 更新。',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const CliUpdateComponentResult(
          status: 'skipped',
          detail: 'GitHub Release 接口返回格式异常，本次未检查 CLI 更新。',
        );
      }
      final tag = (decoded['tag_name'] as String? ?? '').trim();
      final latest = tag.replaceFirst(RegExp(r'^[vV]'), '');
      if (latest.isEmpty) {
        return const CliUpdateComponentResult(
          status: 'skipped',
          detail: '最新 Release 缺少 tag_name，本次未检查 CLI 更新。',
        );
      }
      if (compareVersions(latest, CliArgs.cliVersion) <= 0) {
        return CliUpdateComponentResult(
          status: 'up-to-date',
          detail: '当前 CLI ${CliArgs.cliVersion}，最新 Release 为 $tag，'
              '已是最新。',
        );
      }
      if (checkOnly) {
        return CliUpdateComponentResult(
          status: 'update-available',
          detail: '当前 CLI ${CliArgs.cliVersion}，最新 Release 为 $tag。'
              '运行 courselens update --cli 下载安装。',
        );
      }

      final assetName = _releaseAssetName();
      if (assetName == null) {
        return CliUpdateComponentResult(
          status: 'skipped',
          detail: '最新 Release 为 $tag，但当前平台 '
              '${ffi.Abi.current()} 无预编译产物命名规则，请改用源码检出方式更新。',
        );
      }
      final assets = decoded['assets'];
      String? downloadUrl;
      if (assets is List) {
        for (final asset in assets) {
          if (asset is Map<String, dynamic> && asset['name'] == assetName) {
            downloadUrl = asset['browser_download_url'] as String?;
            break;
          }
        }
      }
      if (downloadUrl == null || downloadUrl.isEmpty) {
        return CliUpdateComponentResult(
          status: 'skipped',
          detail: '最新 Release $tag 未提供当前平台产物 $assetName，'
              '请改用源码检出方式更新。',
        );
      }

      final tempFile = io.File(
        '${io.Directory.systemTemp.path}${io.Platform.pathSeparator}'
        'courselens-update-${DateTime.now().millisecondsSinceEpoch}',
      );
      try {
        final request = http.Request('GET', Uri.parse(downloadUrl));
        final streamed = await client
            .send(request)
            .timeout(const Duration(seconds: 120));
        if (streamed.statusCode != 200) {
          return CliUpdateComponentResult(
            status: 'skipped',
            detail: '下载 Release 产物 $assetName 失败（HTTP '
                '${streamed.statusCode}），当前二进制未改动。',
          );
        }
        final sink = tempFile.openWrite();
        await streamed.stream.pipe(sink);
      } catch (error) {
        return CliUpdateComponentResult(
          status: 'skipped',
          detail: '下载 Release 产物 $assetName 失败（$error），当前二进制未改动。',
        );
      }
      try {
        await _replaceCurrentExecutable(tempFile);
      } catch (error) {
        return CliUpdateComponentResult(
          status: 'error',
          detail: '替换当前二进制失败（$error）；原文件未被破坏，'
              '备份保留在 ${io.Platform.resolvedExecutable}.bak。',
        );
      } finally {
        try {
          if (tempFile.existsSync()) tempFile.deleteSync();
        } catch (_) {
          // 忽略临时文件清理失败
        }
      }
      return CliUpdateComponentResult(
        status: 'updated',
        detail: '已从 Release $tag 下载 $assetName 并安装到 '
            '${io.Platform.resolvedExecutable}'
            '（旧版本备份在 ${io.Platform.resolvedExecutable}.bak）。',
      );
    } finally {
      if (closeClient) client.close();
    }
  }

  String? _releaseAssetName() {
    return switch (ffi.Abi.current()) {
      ffi.Abi.linuxX64 => 'courselens-linux-x64',
      ffi.Abi.linuxArm64 => 'courselens-linux-arm64',
      ffi.Abi.macosX64 => 'courselens-macos-x64',
      ffi.Abi.macosArm64 => 'courselens-macos-arm64',
      ffi.Abi.windowsX64 => 'courselens-windows-x64.exe',
      ffi.Abi.windowsArm64 => 'courselens-windows-arm64.exe',
      _ => null,
    };
  }

  // ---------------------------------------------------------------------------
  // 2. Agent Skill 更新
  // ---------------------------------------------------------------------------

  Future<CliUpdateComponentResult> _updateSkill({
    required bool checkOnly,
    required io.Directory? checkout,
  }) async {
    final sep = io.Platform.pathSeparator;

    // 取最新 SKILL.md 内容。
    String? latestContent;
    String latestSource;
    if (checkout != null) {
      final sourceFile = io.File(
        '${checkout.path}$sep.agents${sep}skills${sep}courselens-cli'
        '${sep}SKILL.md',
      );
      latestSource = sourceFile.path;
      if (!sourceFile.existsSync()) {
        return CliUpdateComponentResult(
          status: 'skipped',
          detail: '源码检出 ${checkout.path} 内缺少 SKILL.md'
              '（.agents/skills/courselens-cli/SKILL.md），无法更新 Skill。',
        );
      }
      try {
        latestContent = sourceFile.readAsStringSync();
      } catch (error) {
        return CliUpdateComponentResult(
          status: 'skipped',
          detail: '读取检出内 SKILL.md 失败（$error），无法更新 Skill。',
        );
      }
    } else {
      latestSource =
          'https://raw.githubusercontent.com/$_repoSlug/main/.agents/skills/courselens-cli/SKILL.md';
      final client = _httpClient ?? http.Client();
      final closeClient = _httpClient == null;
      try {
        final response = await client
            .get(Uri.parse(latestSource))
            .timeout(const Duration(seconds: 30));
        if (response.statusCode != 200) {
          return CliUpdateComponentResult(
            status: 'skipped',
            detail: '下载最新 SKILL.md 失败（HTTP ${response.statusCode}），'
                'Skill 未改动。',
          );
        }
        latestContent = response.body;
      } catch (error) {
        return CliUpdateComponentResult(
          status: 'skipped',
          detail: '下载最新 SKILL.md 失败（$error），Skill 未改动。',
        );
      } finally {
        if (closeClient) client.close();
      }
    }

    // 枚举已安装位置。
    final candidateDirs = <String>[];
    final envSkillDir = _envValue('COURSELENS_SKILL_DIR')?.trim();
    if (envSkillDir != null && envSkillDir.isNotEmpty) {
      candidateDirs.add(envSkillDir);
    }
    candidateDirs.addAll(<String>[
      '$_homeDir$sep.claude${sep}skills${sep}courselens-cli',
      '$_homeDir$sep.codex${sep}skills${sep}courselens-cli',
      '$_homeDir$sep.agents${sep}skills${sep}courselens-cli',
    ]);

    final details = <String>[];
    var found = 0;
    var updatedCount = 0;
    var outdatedRemaining = 0;
    for (final dir in candidateDirs) {
      final skillFile = io.File('$dir${sep}SKILL.md');
      if (!skillFile.existsSync()) continue;
      found++;
      final type = io.FileSystemEntity.typeSync(
        skillFile.path,
        followLinks: false,
      );
      String currentContent;
      try {
        currentContent = skillFile.readAsStringSync();
      } catch (error) {
        details.add('$dir：读取失败（$error）');
        outdatedRemaining++;
        continue;
      }
      final isLatest = currentContent == latestContent;
      if (type == io.FileSystemEntityType.link) {
        final linkTarget = io.Link(skillFile.path).targetSync();
        if (isLatest) {
          details.add('$dir：软链 → $linkTarget，已是最新');
        } else {
          details.add(
            '$dir：软链 → $linkTarget，待更新'
            '（软链指向源码检出时，检出 git pull 后即为最新；未改写软链）',
          );
          outdatedRemaining++;
        }
        continue;
      }
      if (isLatest) {
        details.add('$dir：已是最新');
      } else if (checkOnly) {
        details.add('$dir：有可用更新（--check 模式未写入）');
        outdatedRemaining++;
      } else {
        try {
          final backup = io.File('${skillFile.path}.bak');
          if (backup.existsSync()) backup.deleteSync();
          skillFile.copySync(backup.path);
          skillFile.writeAsStringSync(latestContent);
          details.add('$dir：已更新（旧版备份在 SKILL.md.bak）');
          updatedCount++;
        } catch (error) {
          details.add('$dir：更新失败（$error）');
          outdatedRemaining++;
        }
      }
    }

    if (found == 0) {
      return CliUpdateComponentResult(
        status: 'skipped',
        detail: '未发现已安装的 Skill（已检查 COURSELENS_SKILL_DIR、'
            '~/.claude/skills、~/.codex/skills、~/.agents/skills 下的 '
            'courselens-cli 目录）。',
      );
    }
    final summary = details.join('\n');
    if (updatedCount > 0) {
      return CliUpdateComponentResult(status: 'updated', detail: summary);
    }
    if (outdatedRemaining > 0) {
      return CliUpdateComponentResult(
        status: 'update-available',
        detail: summary,
      );
    }
    return CliUpdateComponentResult(status: 'up-to-date', detail: summary);
  }

  // ---------------------------------------------------------------------------
  // 3. 会话网关 Worker 更新
  // ---------------------------------------------------------------------------

  Future<String?> _resolveBoundWorkerUrl(ParsedCliInvocation inv) async {
    final explicit = inv.global.workerUrl?.trim();
    CliSessionRecord? record;
    try {
      final store = CliCredentialStore.resolve(
        kind: CliStoreKind.parse(inv.global.store),
        sessionFilePath: inv.global.sessionFile,
        environment: _environment,
      );
      record = await store.load();
    } catch (_) {
      record = null;
    }

    if (explicit != null && explicit.isNotEmpty) {
      final profile = record?.findSavedWorker(explicit);
      if (profile != null) {
        return WorkerSessionHttpEngine.normalizeWorkerBaseUrl(
          profile.workerUrl,
        );
      }
      if (explicit.contains('://')) {
        return WorkerSessionHttpEngine.normalizeWorkerBaseUrl(explicit);
      }
      return null;
    }
    final saved = record?.workerUrl?.trim();
    if (saved != null && saved.isNotEmpty) {
      return WorkerSessionHttpEngine.normalizeWorkerBaseUrl(saved);
    }
    final envUrl = _envValue(CliCredentialStore.envWorkerUrl)?.trim();
    if (envUrl != null && envUrl.isNotEmpty) {
      return WorkerSessionHttpEngine.normalizeWorkerBaseUrl(envUrl);
    }
    return null;
  }

  String _latestGatewayVersion(io.Directory? checkout) {
    if (checkout != null) {
      final sep = io.Platform.pathSeparator;
      final indexFile = io.File(
        '${checkout.path}${sep}workers${sep}session_gateway${sep}src'
        '${sep}index.js',
      );
      if (indexFile.existsSync()) {
        try {
          final match = RegExp(r'GATEWAY_VERSION\s*=\s*"([^"]+)"')
              .firstMatch(indexFile.readAsStringSync());
          if (match != null) return match.group(1)!;
        } catch (_) {
          // 读取失败时回退内置常量
        }
      }
    }
    return gatewayVersion;
  }

  Future<({bool ok, String? version, String detail})> _fetchGatewayHealth(
    http.Client client,
    String workerUrl,
  ) async {
    try {
      final response = await client
          .get(Uri.parse('$workerUrl/health'))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        return (
          ok: false,
          version: null,
          detail: 'GET /health 返回 HTTP ${response.statusCode}',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final version = decoded['version'];
        return (
          ok: true,
          version: version is String && version.trim().isNotEmpty
              ? version.trim()
              : null,
          detail: '',
        );
      }
      return (ok: true, version: null, detail: '');
    } catch (error) {
      return (ok: false, version: null, detail: '$error');
    }
  }

  Future<CliUpdateComponentResult> _updateWorker({
    required ParsedCliInvocation inv,
    required bool checkOnly,
    required io.Directory? checkout,
  }) async {
    final workerUrl = await _resolveBoundWorkerUrl(inv);
    if (workerUrl == null) {
      return const CliUpdateComponentResult(
        status: 'skipped',
        detail: '未绑定网关（先运行 courselens auth worker 绑定，'
            '或设置环境变量 COURSELENS_WORKER_URL）。',
      );
    }

    final latest = _latestGatewayVersion(checkout);
    final client = _httpClient ?? http.Client();
    final closeClient = _httpClient == null;
    try {
      final health = await _fetchGatewayHealth(client, workerUrl);
      if (!health.ok) {
        return CliUpdateComponentResult(
          status: 'skipped',
          detail: '无法访问已绑定网关 $workerUrl 的 /health'
              '（${health.detail}），本次未检查网关版本。',
        );
      }
      final deployedLabel = health.version ?? '无版本号（旧版）';
      if (health.version != null &&
          compareVersions(health.version!, latest) >= 0) {
        return CliUpdateComponentResult(
          status: 'up-to-date',
          detail: '网关 $workerUrl 版本 ${health.version}，已是最新。',
        );
      }
      if (checkOnly) {
        return CliUpdateComponentResult(
          status: 'update-available',
          detail: '网关 $workerUrl 当前为 $deployedLabel，最新版本 $latest。'
              '运行 courselens update --worker 部署更新。',
        );
      }

      if (checkout == null) {
        return CliUpdateComponentResult(
          status: 'skipped',
          detail: '网关 $workerUrl 当前为 $deployedLabel，最新版本 $latest；'
              '但本机无源码检出，无法部署 Worker 更新'
              '（请先 git clone https://github.com/$_repoSlug.git 并在检出内运行）。',
        );
      }
      final sep = io.Platform.pathSeparator;
      final workerDir = io.Directory(
        '${checkout.path}${sep}workers${sep}session_gateway',
      );
      String? wranglerConfigName;
      for (final candidate in const <String>[
        'wrangler.toml',
        'wrangler.jsonc',
        'wrangler.json',
      ]) {
        if (io.File('${workerDir.path}$sep$candidate').existsSync()) {
          wranglerConfigName = candidate;
          break;
        }
      }
      if (wranglerConfigName == null) {
        final example = io.File('${workerDir.path}${sep}wrangler.toml.example');
        final hint = example.existsSync()
            ? '请先检查 wrangler.jsonc 是否完整，或把 wrangler.toml.example 复制为 '
                'wrangler.toml 并按注释填入配置，然后重新运行 courselens update --worker。'
            : '请先在该目录放置 wrangler.jsonc 或 wrangler.toml，然后重新运行 '
                'courselens update --worker。';
        return CliUpdateComponentResult(
          status: 'skipped',
          detail: '网关当前为 $deployedLabel，最新版本 $latest；'
              '但 ${workerDir.path} 下未找到 wrangler.jsonc / wrangler.toml，已中止部署。$hint',
        );
      }

      final npxExe = io.Platform.isWindows ? 'npx.cmd' : 'npx';
      ({int exitCode, String stdout, String stderr}) deploy;
      try {
        deploy = await _runProcess(
          npxExe,
          <String>['wrangler', 'deploy', '--config', wranglerConfigName],
          workingDirectory: workerDir.path,
        );
      } on io.ProcessException catch (error) {
        return CliUpdateComponentResult(
          status: 'error',
          detail: '无法启动 npx wrangler deploy（${error.message}）；'
              '请先安装 Node.js 并执行 npx wrangler login 登录 Cloudflare。',
        );
      }
      if (deploy.exitCode != 0) {
        return CliUpdateComponentResult(
          status: 'error',
          detail: 'wrangler deploy 失败（退出码 ${deploy.exitCode}）。'
              '部署不会动已注入的 Secrets（COURSELENS_API_KEY、PORTAL_PASSWORD '
              '保存在 Cloudflare 侧）。输出尾部：\n'
              '${_tail('${deploy.stdout}\n${deploy.stderr}', lines: 15)}',
        );
      }

      final after = await _fetchGatewayHealth(client, workerUrl);
      if (after.ok &&
          after.version != null &&
          compareVersions(after.version!, latest) >= 0) {
        return CliUpdateComponentResult(
          status: 'updated',
          detail: '网关 $workerUrl 已部署更新并确认版本 ${after.version}。'
              '部署不会动已注入的 Secrets（COURSELENS_API_KEY、PORTAL_PASSWORD '
              '保存在 Cloudflare 侧）。',
        );
      }
      return CliUpdateComponentResult(
        status: 'error',
        detail: 'wrangler deploy 已执行，但重新检查 $workerUrl/health 后版本为 '
            '${after.version ?? '无版本号（旧版）'}（预期 $latest）；'
            '请确认 wrangler 部署目标与该网关地址一致。',
      );
    } finally {
      if (closeClient) client.close();
    }
  }

  static String _tail(String text, {int lines = 5}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return '（无输出）';
    final split = trimmed.split('\n');
    if (split.length <= lines) return trimmed;
    return split.sublist(split.length - lines).join('\n');
  }
}
