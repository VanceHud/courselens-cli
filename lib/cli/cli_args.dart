import '../core/courselens_core.dart';

/// CLI 参数解析或安全策略拒绝异常。
class CliUsageException implements Exception {
  const CliUsageException(
    this.message, {
    this.isSecurityViolation = false,
  });

  final String message;
  final bool isSecurityViolation;

  @override
  String toString() => message;
}

/// CLI 支持的全部顶层与二级命令枚举。
enum CliCommandKind {
  help,
  version,
  authStatus,
  authLogin,
  authWorker,
  authImportCookie,
  authLogout,
  workerTasksList,
  workerTasksShow,
  workerTasksEnable,
  workerTasksDisable,
  workerTasksRun,
  workerTasksDelete,
  workerPushCookies,
  workerWebhookStatus,
  workerWebhookSet,
  workerWebhookTest,
  workerWebhookClear,
  workerMonitorStatus,
  workerMonitorSet,
  workerMonitorCheck,
  today,
  schedule,
  grades,
  exams,
  plan,
  rooms,
  courses,
  select,
  drop,
  update,
}

/// 全局 CLI 选项（可在任意子命令前、中、后传入）。
class CliGlobalOptions {
  const CliGlobalOptions({
    this.demo = false,
    this.json = false,
    this.term,
    this.relayUrl,
    this.workerUrl,
    this.store = 'auto',
    this.sessionFile,
    this.help = false,
    this.version = false,
  });

  final bool demo;
  final bool json;
  final String? term;
  final String? relayUrl;
  final String? workerUrl;
  final String store;
  final String? sessionFile;
  final bool help;
  final bool version;
}

/// 解析并完成静态校验后的 CLI 调用描述。
class ParsedCliInvocation {
  const ParsedCliInvocation({
    required this.command,
    required this.global,
    this.helpTopic,
    this.offline = false,
    this.url,
    this.casUrl,
    this.user,
    this.passwordStdin = false,
    this.passwordEnv,
    this.apiKeyStdin = false,
    this.apiKeyEnv,
    this.name,
    this.listWorkers = false,
    this.useWorker,
    this.removeWorker,
    this.keepWorkers = false,
    this.system = 'auto',
    this.cookie,
    this.cookieStdin = false,
    this.harPath,
    this.noVerify = false,
    this.taskId,
    this.intervalSec,
    this.webhookProvider,
    this.secretStdin = false,
    this.secretEnv,
    this.chatId,
    this.monitorGrades,
    this.monitorExams,
    this.resetBaseline = false,
    this.monitorKind = 'all',
    this.date,
    this.parsedDate,
    this.week,
    this.icsPath,
    this.stats = false,
    this.campus,
    this.day,
    this.weeksSpec,
    this.weeks,
    this.sectionsSpec,
    this.sections,
    this.query,
    this.courseId,
    this.classId,
    this.confirm = false,
    this.updateCheck = false,
    this.updateTargets = const <String>{},
  });

  final CliCommandKind command;
  final CliGlobalOptions global;
  final String? helpTopic;

  // auth status / whoami
  final bool offline;

  // auth login / auth worker / auth import-cookie / auth logout
  final String? url;
  final String? casUrl;
  final String? user;
  final bool passwordStdin;
  final String? passwordEnv;
  final bool apiKeyStdin;
  final String? apiKeyEnv;
  final String? name;
  final bool listWorkers;
  final String? useWorker;
  final String? removeWorker;
  final bool keepWorkers;
  final String system;
  final String? cookie;
  final bool cookieStdin;
  final String? harPath;
  final bool noVerify;

  // worker tasks / webhook / monitor
  final String? taskId;
  final int? intervalSec;
  final String? webhookProvider;
  final bool secretStdin;
  final String? secretEnv;
  final String? chatId;
  final bool? monitorGrades;
  final bool? monitorExams;
  final bool resetBaseline;
  final String monitorKind;

  // today
  final String? date;
  final (int year, int month, int day)? parsedDate;

  // schedule
  final int? week;
  final String? icsPath;

  // grades
  final bool stats;

  // rooms
  final String? campus;
  final int? day;
  final String? weeksSpec;
  final List<int>? weeks;
  final String? sectionsSpec;
  final List<int>? sections;

  // courses
  final String? query;

  // select / drop
  final String? courseId;
  final String? classId;
  final bool confirm;

  // update
  final bool updateCheck;

  /// 目标组件集合（元素为 `cli` / `skill` / `worker`）；空集表示全部组件。
  final Set<String> updateTargets;
}

/// 零第三方依赖的 CLI 参数解析器与安全校验器。
class CliArgs {
  const CliArgs._();

  static const String cliVersion = '1.1.0';

  static const Set<String> validStores = <String>{
    'auto',
    'keychain',
    'file',
    'env',
  };

  static const Set<String> validSystems = <String>{
    'auto',
    'zf',
    'zf_old',
    'qz',
    'qz_old',
  };

  static const Set<String> validWebhookProviders = <String>{
    'auto',
    'bark',
    'feishu',
    'dingtalk',
    'wecom',
    'telegram',
    'generic',
  };

  static const Set<String> validMonitorKinds = <String>{
    'all',
    'grades',
    'exams',
  };

  /// 解析命令行参数。
  ///
  /// 红线 #1：一旦检测到 `--password`、`--api-key`、`--webhook-secret` 或 `--secret` 立即拒绝，防止 `ps` 泄露明文凭据。
  static ParsedCliInvocation parse(List<String> argv) {
    // 第一遍：优先拦截任何位置的明文凭据参数（即使伴随 --help 也拒绝泄密习惯）
    for (final raw in argv) {
      if (raw == '--') break;
      if (raw == '--password' || raw.startsWith('--password=')) {
        throw const CliUsageException(
          'SECURITY_REFUSED: 严禁通过命令行参数 --password 传递明文密码（会暴露于 ps 进程列表与 Shell 历史记录）。'
          '请改用交互式终端隐藏输入、--password-stdin 或 --password-env <VAR>。',
          isSecurityViolation: true,
        );
      }
      if (raw == '--api-key' || raw.startsWith('--api-key=')) {
        throw const CliUsageException(
          'SECURITY_REFUSED: 严禁通过命令行参数 --api-key 传递明文密钥（会暴露于 ps 进程列表与 Shell 历史记录）。'
          '请改用交互式终端隐藏输入、--api-key-stdin、--api-key-env <VAR> 或环境变量 COURSELENS_API_KEY。',
          isSecurityViolation: true,
        );
      }
      if (raw == '--webhook-secret' ||
          raw.startsWith('--webhook-secret=') ||
          raw == '--secret' ||
          raw.startsWith('--secret=')) {
        throw const CliUsageException(
          'SECURITY_REFUSED: 严禁通过命令行参数传递明文 Webhook 签名密钥（会暴露于 ps 进程列表与 Shell 历史记录）。'
          '请改用 --secret-stdin 或 --secret-env <VAR>。',
          isSecurityViolation: true,
        );
      }
    }

    var demo = false;
    var json = false;
    String? term;
    String? relayUrl;
    String? workerUrl;
    var store = 'auto';
    String? sessionFile;
    var help = false;
    var version = false;

    var offline = false;
    String? url;
    String? casUrl;
    String? user;
    var passwordStdin = false;
    String? passwordEnv;
    var apiKeyStdin = false;
    String? apiKeyEnv;
    String? name;
    var listWorkers = false;
    String? useWorker;
    String? removeWorker;
    var keepWorkers = false;
    var system = 'auto';
    var systemProvided = false;
    String? cookie;
    var cookieStdin = false;
    String? harPath;
    var noVerify = false;
    String? taskId;
    int? intervalSec;
    String? webhookProvider;
    var secretStdin = false;
    String? secretEnv;
    String? chatId;
    bool? monitorGrades;
    bool? monitorExams;
    var resetBaseline = false;
    var monitorKind = 'all';
    String? date;
    int? week;
    String? icsPath;
    var stats = false;
    String? campus;
    int? day;
    String? weeksSpec;
    String? sectionsSpec;
    String? query;
    String? courseId;
    String? classId;
    var confirm = false;
    var updateCheck = false;
    var updateAll = false;
    final updateTargets = <String>{};

    final positionals = <String>[];
    final usedSubFlags = <String>{};

    String takeValue(int index, String flagName, String? inlineValue, List<String> args, void Function() advance) {
      if (inlineValue != null) {
        if (inlineValue.trim().isEmpty) {
          throw CliUsageException('参数 $flagName 的值不能为空。');
        }
        return inlineValue;
      }
      if (index + 1 >= args.length) {
        throw CliUsageException('参数 $flagName 缺少必填值。');
      }
      final next = args[index + 1];
      advance();
      if (next.trim().isEmpty) {
        throw CliUsageException('参数 $flagName 的值不能为空。');
      }
      return next;
    }

    for (var i = 0; i < argv.length; i++) {
      final token = argv[i];
      if (token == '--') {
        positionals.addAll(argv.sublist(i + 1));
        break;
      }
      if (!token.startsWith('-') || token == '-') {
        positionals.add(token);
        continue;
      }

      String flagName = token;
      String? inlineValue;
      final eq = token.indexOf('=');
      if (eq > 0) {
        flagName = token.substring(0, eq);
        inlineValue = token.substring(eq + 1);
      }

      void rejectInlineBool() {
        if (inlineValue != null) {
          throw CliUsageException('布尔开关 $flagName 不接受参数值（收到 "$inlineValue"）。');
        }
      }

      switch (flagName) {
        case '--demo':
          rejectInlineBool();
          demo = true;
        case '--json':
          rejectInlineBool();
          json = true;
        case '-h':
        case '--help':
          rejectInlineBool();
          help = true;
        case '-v':
        case '--version':
          rejectInlineBool();
          version = true;
        case '--term':
          term = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
        case '--relay':
          relayUrl = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
        case '--worker':
          // `courselens update --worker` 中的 --worker 是组件选择开关（无值形式，
          // 且后随参数为另一个 flag 或已到末尾）；其余场景仍是全局网关地址参数。
          if (inlineValue == null &&
              positionals.isNotEmpty &&
              positionals.first.toLowerCase() == 'update' &&
              (i + 1 >= argv.length || argv[i + 1].startsWith('-'))) {
            updateTargets.add('worker');
            usedSubFlags.add('--worker');
          } else {
            workerUrl = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          }
        case '--store':
          final rawStore =
              takeValue(i, flagName, inlineValue, argv, () => i++).trim().toLowerCase();
          if (!validStores.contains(rawStore)) {
            throw CliUsageException(
              '无效的 --store 后端 "$rawStore"（可选值：auto | keychain | file | env）。',
            );
          }
          store = rawStore;
        case '--session-file':
          sessionFile = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
        case '--offline':
          rejectInlineBool();
          offline = true;
          usedSubFlags.add('--offline');
        case '--url':
          url = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          usedSubFlags.add('--url');
        case '--cas-url':
          casUrl = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          usedSubFlags.add('--cas-url');
        case '--user':
          user = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          usedSubFlags.add('--user');
        case '--password-stdin':
          rejectInlineBool();
          passwordStdin = true;
          usedSubFlags.add('--password-stdin');
        case '--password-env':
          passwordEnv = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          usedSubFlags.add('--password-env');
        case '--api-key-stdin':
          rejectInlineBool();
          apiKeyStdin = true;
          usedSubFlags.add('--api-key-stdin');
        case '--api-key-env':
          apiKeyEnv = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          usedSubFlags.add('--api-key-env');
        case '--name':
          name = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          usedSubFlags.add('--name');
        case '--list':
          rejectInlineBool();
          listWorkers = true;
          usedSubFlags.add('--list');
        case '--use':
          useWorker = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          usedSubFlags.add('--use');
        case '--remove':
          removeWorker =
              takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          usedSubFlags.add('--remove');
        case '--keep-workers':
          rejectInlineBool();
          keepWorkers = true;
          usedSubFlags.add('--keep-workers');
        case '--system':
          final rawSys = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          if (!validSystems.contains(rawSys.toLowerCase())) {
            throw CliUsageException(
              '无效的 --system 教务类型 "$rawSys"（可选值：auto | ZF | ZF_OLD | QZ | QZ_OLD）。',
            );
          }
          system = rawSys.toLowerCase() == 'auto' ? 'auto' : rawSys.toUpperCase();
          systemProvided = true;
          usedSubFlags.add('--system');
        case '--cookie':
          // 保留原始 Cookie 值，仅检查非空
          if (inlineValue != null) {
            if (inlineValue.trim().isEmpty) {
              throw const CliUsageException('参数 --cookie 的值不能为空。');
            }
            cookie = inlineValue;
          } else {
            if (i + 1 >= argv.length) {
              throw const CliUsageException('参数 --cookie 缺少必填值。');
            }
            cookie = argv[++i];
            if (cookie.trim().isEmpty) {
              throw const CliUsageException('参数 --cookie 的值不能为空。');
            }
          }
          usedSubFlags.add('--cookie');
        case '--cookie-stdin':
          rejectInlineBool();
          cookieStdin = true;
          usedSubFlags.add('--cookie-stdin');
        case '--har':
          harPath = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          usedSubFlags.add('--har');
        case '--no-verify':
          rejectInlineBool();
          noVerify = true;
          usedSubFlags.add('--no-verify');
        case '--task-id':
          taskId = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          usedSubFlags.add('--task-id');
        case '--interval':
          final rawIv =
              takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          final parsedIv = int.tryParse(rawIv);
          if (parsedIv == null || parsedIv < 1 || parsedIv > 86400) {
            throw CliUsageException(
              '参数 --interval 必须是 1..86400 之间的秒数整数（收到 "$rawIv"）。',
            );
          }
          intervalSec = parsedIv;
          usedSubFlags.add('--interval');
        case '--provider':
          final rawProv = takeValue(i, flagName, inlineValue, argv, () => i++)
              .trim()
              .toLowerCase();
          if (!validWebhookProviders.contains(rawProv)) {
            throw CliUsageException(
              '无效的 --provider 推送通道 "$rawProv"（可选值：auto | bark | feishu | dingtalk | wecom | telegram | generic）。',
            );
          }
          webhookProvider = rawProv;
          usedSubFlags.add('--provider');
        case '--secret-stdin':
          rejectInlineBool();
          secretStdin = true;
          usedSubFlags.add('--secret-stdin');
        case '--secret-env':
          secretEnv =
              takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          usedSubFlags.add('--secret-env');
        case '--chat-id':
          chatId = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          usedSubFlags.add('--chat-id');
        case '--grades':
          final rawG =
              takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          monitorGrades = _parseOnOff(rawG, '--grades');
          usedSubFlags.add('--grades');
        case '--exams':
          final rawE =
              takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          monitorExams = _parseOnOff(rawE, '--exams');
          usedSubFlags.add('--exams');
        case '--reset-baseline':
          rejectInlineBool();
          resetBaseline = true;
          usedSubFlags.add('--reset-baseline');
        case '--kind':
          final rawK = takeValue(i, flagName, inlineValue, argv, () => i++)
              .trim()
              .toLowerCase();
          if (!validMonitorKinds.contains(rawK)) {
            throw CliUsageException(
              '无效的 --kind 巡检类型 "$rawK"（可选值：all | grades | exams）。',
            );
          }
          monitorKind = rawK;
          usedSubFlags.add('--kind');
        case '--date':
          date = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          usedSubFlags.add('--date');
        case '--week':
          final rawWeek = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          final parsedW = int.tryParse(rawWeek);
          if (parsedW == null || parsedW < 1 || parsedW > 30) {
            throw CliUsageException('参数 --week 必须是 1..30 之间的整数（收到 "$rawWeek"）。');
          }
          week = parsedW;
          usedSubFlags.add('--week');
        case '--ics':
          icsPath = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          usedSubFlags.add('--ics');
        case '--stats':
          rejectInlineBool();
          stats = true;
          usedSubFlags.add('--stats');
        case '--campus':
          campus = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          usedSubFlags.add('--campus');
        case '--day':
          final rawDay = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          final parsedD = int.tryParse(rawDay);
          if (parsedD == null || parsedD < 1 || parsedD > 7) {
            throw CliUsageException('参数 --day 必须是 1..7 之间的星期整数（收到 "$rawDay"）。');
          }
          day = parsedD;
          usedSubFlags.add('--day');
        case '--weeks':
          weeksSpec = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          usedSubFlags.add('--weeks');
        case '--sections':
          sectionsSpec = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          usedSubFlags.add('--sections');
        case '--query':
          query = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          usedSubFlags.add('--query');
        case '--course-id':
          courseId = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          usedSubFlags.add('--course-id');
        case '--class-id':
          classId = takeValue(i, flagName, inlineValue, argv, () => i++).trim();
          usedSubFlags.add('--class-id');
        case '--confirm':
          rejectInlineBool();
          confirm = true;
          usedSubFlags.add('--confirm');
        case '--check':
          rejectInlineBool();
          updateCheck = true;
          usedSubFlags.add('--check');
        case '--cli':
          rejectInlineBool();
          updateTargets.add('cli');
          usedSubFlags.add('--cli');
        case '--skill':
          rejectInlineBool();
          updateTargets.add('skill');
          usedSubFlags.add('--skill');
        case '--all':
          rejectInlineBool();
          updateAll = true;
          usedSubFlags.add('--all');
        default:
          throw CliUsageException('未知命令行参数：$flagName（运行 courselens --help 查看支持的选项）。');
      }
    }

    final global = CliGlobalOptions(
      demo: demo,
      json: json,
      term: term,
      relayUrl: relayUrl,
      workerUrl: workerUrl,
      store: store,
      sessionFile: sessionFile,
      help: help,
      version: version,
    );

    if (version) {
      return ParsedCliInvocation(
        command: CliCommandKind.version,
        global: global,
      );
    }

    if (positionals.isEmpty) {
      return ParsedCliInvocation(
        command: CliCommandKind.help,
        global: global,
      );
    }

    final primary = positionals.first.toLowerCase();
    if (primary == 'help') {
      final topic = positionals.length > 1 ? positionals.sublist(1).join(' ') : null;
      return ParsedCliInvocation(
        command: CliCommandKind.help,
        global: global,
        helpTopic: topic,
      );
    }

    if (primary == 'version') {
      return ParsedCliInvocation(
        command: CliCommandKind.version,
        global: global,
      );
    }

    if (help) {
      return ParsedCliInvocation(
        command: CliCommandKind.help,
        global: global,
        helpTopic: positionals.join(' '),
      );
    }

    late final CliCommandKind command;
    switch (primary) {
      case 'whoami':
        if (positionals.length > 1) {
          throw CliUsageException('whoami 不接受额外位置参数：${positionals.sublist(1).join(" ")}');
        }
        command = CliCommandKind.authStatus;
      case 'auth':
        if (positionals.length < 2) {
          throw const CliUsageException(
            'auth 需要指定子命令：status | login | worker | import-cookie | logout。',
          );
        }
        final sub = positionals[1].toLowerCase();
        if (positionals.length > 2) {
          throw CliUsageException(
            'auth $sub 不接受额外位置参数：${positionals.sublist(2).join(" ")}',
          );
        }
        command = switch (sub) {
          'status' => CliCommandKind.authStatus,
          'login' => CliCommandKind.authLogin,
          'worker' => CliCommandKind.authWorker,
          'import-cookie' => CliCommandKind.authImportCookie,
          'logout' => CliCommandKind.authLogout,
          _ => throw CliUsageException(
              '未知 auth 子命令 "$sub"（支持：status | login | worker | import-cookie | logout）。',
            ),
        };
      case 'worker':
        if (positionals.length < 2) {
          throw const CliUsageException(
            'worker 需要指定子命令：tasks | push-cookies | webhook | monitor。',
          );
        }
        final group = positionals[1].toLowerCase();
        switch (group) {
          case 'tasks':
            final action =
                positionals.length >= 3 ? positionals[2].toLowerCase() : 'list';
            if (action == 'list') {
              if (positionals.length > 3) {
                throw CliUsageException(
                  'worker tasks list 不接受额外位置参数：${positionals.sublist(3).join(" ")}',
                );
              }
              command = CliCommandKind.workerTasksList;
            } else if (action == 'show' ||
                action == 'enable' ||
                action == 'disable' ||
                action == 'run' ||
                action == 'delete') {
              if (positionals.length > 4) {
                throw CliUsageException(
                  'worker tasks $action 参数过多：${positionals.sublist(4).join(" ")}',
                );
              }
              if (positionals.length == 4) {
                if (taskId != null && taskId.isNotEmpty) {
                  throw const CliUsageException(
                    '位置参数 <taskId> 与 --task-id 不能重复指定。',
                  );
                }
                taskId = positionals[3].trim();
              }
              command = switch (action) {
                'show' => CliCommandKind.workerTasksShow,
                'enable' => CliCommandKind.workerTasksEnable,
                'disable' => CliCommandKind.workerTasksDisable,
                'run' => CliCommandKind.workerTasksRun,
                _ => CliCommandKind.workerTasksDelete,
              };
            } else {
              throw CliUsageException(
                '未知 worker tasks 子命令 "$action"（支持：list | show | enable | disable | run | delete）。',
              );
            }
          case 'push-cookies':
            if (positionals.length > 2) {
              throw CliUsageException(
                'worker push-cookies 不接受额外位置参数：${positionals.sublist(2).join(" ")}',
              );
            }
            command = CliCommandKind.workerPushCookies;
          case 'webhook':
            final action = positionals.length >= 3
                ? positionals[2].toLowerCase()
                : 'status';
            if (positionals.length > 3) {
              throw CliUsageException(
                'worker webhook $action 不接受额外位置参数：${positionals.sublist(3).join(" ")}',
              );
            }
            command = switch (action) {
              'status' => CliCommandKind.workerWebhookStatus,
              'set' => CliCommandKind.workerWebhookSet,
              'test' => CliCommandKind.workerWebhookTest,
              'clear' => CliCommandKind.workerWebhookClear,
              _ => throw CliUsageException(
                  '未知 worker webhook 子命令 "$action"（支持：status | set | test | clear）。',
                ),
            };
          case 'monitor':
            final action = positionals.length >= 3
                ? positionals[2].toLowerCase()
                : 'status';
            if (positionals.length > 3) {
              throw CliUsageException(
                'worker monitor $action 不接受额外位置参数：${positionals.sublist(3).join(" ")}',
              );
            }
            command = switch (action) {
              'status' => CliCommandKind.workerMonitorStatus,
              'set' => CliCommandKind.workerMonitorSet,
              'check' => CliCommandKind.workerMonitorCheck,
              _ => throw CliUsageException(
                  '未知 worker monitor 子命令 "$action"（支持：status | set | check）。',
                ),
            };
          default:
            throw CliUsageException(
              '未知 worker 子命令 "$group"（支持：tasks | push-cookies | webhook | monitor）。',
            );
        }
      case 'today':
        _ensureNoExtraPositionals('today', positionals);
        command = CliCommandKind.today;
      case 'schedule':
        _ensureNoExtraPositionals('schedule', positionals);
        command = CliCommandKind.schedule;
      case 'grades':
        _ensureNoExtraPositionals('grades', positionals);
        command = CliCommandKind.grades;
      case 'exams':
        _ensureNoExtraPositionals('exams', positionals);
        command = CliCommandKind.exams;
      case 'plan':
      case 'progress':
        _ensureNoExtraPositionals(positionals.first, positionals);
        command = CliCommandKind.plan;
      case 'rooms':
        _ensureNoExtraPositionals('rooms', positionals);
        command = CliCommandKind.rooms;
      case 'courses':
        _ensureNoExtraPositionals('courses', positionals);
        command = CliCommandKind.courses;
      case 'select':
        _ensureNoExtraPositionals('select', positionals);
        command = CliCommandKind.select;
      case 'drop':
        _ensureNoExtraPositionals('drop', positionals);
        command = CliCommandKind.drop;
      case 'update':
        _ensureNoExtraPositionals('update', positionals);
        command = CliCommandKind.update;
      default:
        throw CliUsageException(
          '未知命令 "${positionals.first}"（运行 courselens --help 查看全部可用命令）。',
        );
    }

    _validateAllowedSubFlags(command, usedSubFlags);

    (int, int, int)? parsedDate;
    if (date != null) {
      parsedDate = parseIsoDate(date);
    }

    List<int>? weeks;
    if (weeksSpec != null) {
      weeks = parseIntSpec(weeksSpec, min: 1, max: 60, flagName: '--weeks');
    }

    List<int>? sections;
    if (sectionsSpec != null) {
      sections = parseIntSpec(
        sectionsSpec,
        min: 1,
        max: PeriodSpan.maxPeriod,
        flagName: '--sections',
      );
    }

    switch (command) {
      case CliCommandKind.authLogin:
        if ((url == null || url.isEmpty) && !demo) {
          throw const CliUsageException('auth login 缺少必填参数 --url <baseUrl>。');
        }
        if ((user == null || user.isEmpty) && !demo) {
          throw const CliUsageException('auth login 缺少必填参数 --user <id>。');
        }
        if (passwordStdin && passwordEnv != null) {
          throw const CliUsageException(
            '--password-stdin 与 --password-env 不能同时指定。',
          );
        }
        if (url != null) _validateHttpUrl(url, '--url');
        if (casUrl != null) _validateHttpUrl(casUrl, '--cas-url');
      case CliCommandKind.authWorker:
        final actionCount = (listWorkers ? 1 : 0) +
            (useWorker != null ? 1 : 0) +
            (removeWorker != null ? 1 : 0);
        if (actionCount > 1) {
          throw const CliUsageException(
            'auth worker 的 --list、--use 与 --remove 只能三选一。',
          );
        }
        if (actionCount == 0) {
          if ((url == null || url.isEmpty) &&
              workerUrl != null &&
              workerUrl.isNotEmpty) {
            url = workerUrl;
          }
          if (url == null || url.isEmpty) {
            throw const CliUsageException(
              'auth worker 缺少必填参数 --url <workerUrl>（或使用 --list / --use <name> / --remove <name> 管理已保存网关）。',
            );
          }
          if (apiKeyStdin && apiKeyEnv != null) {
            throw const CliUsageException(
              '--api-key-stdin 与 --api-key-env 不能同时指定。',
            );
          }
          _validateHttpUrl(url, '--url');
        }
      case CliCommandKind.authImportCookie:
        if (url == null || url.isEmpty) {
          throw const CliUsageException(
            'auth import-cookie 缺少必填参数 --url <baseUrl>。',
          );
        }
        _validateHttpUrl(url, '--url');
        final sourceCount = (cookie != null ? 1 : 0) +
            (cookieStdin ? 1 : 0) +
            (harPath != null ? 1 : 0);
        if (sourceCount == 0) {
          throw const CliUsageException(
            'auth import-cookie 需要指定一个输入源：--cookie <header> | --cookie-stdin | --har <file.har>。',
          );
        }
        if (sourceCount > 1) {
          throw const CliUsageException(
            '--cookie、--cookie-stdin 与 --har 只能三选一，不可同时传入。',
          );
        }
      case CliCommandKind.workerTasksShow:
      case CliCommandKind.workerTasksEnable:
      case CliCommandKind.workerTasksDisable:
      case CliCommandKind.workerTasksRun:
      case CliCommandKind.workerTasksDelete:
        if (taskId == null || taskId.isEmpty) {
          throw const CliUsageException(
            'worker tasks 子命令缺少必填的任务 ID（例如 monitor:grades、monitor:exams、session:keepalive）。',
          );
        }
      case CliCommandKind.workerPushCookies:
        if (url != null && url.isNotEmpty) {
          _validateHttpUrl(url, '--url');
        }
        final sourceCount = (cookie != null ? 1 : 0) +
            (cookieStdin ? 1 : 0) +
            (harPath != null ? 1 : 0);
        if (sourceCount == 0) {
          throw const CliUsageException(
            'worker push-cookies 需要指定一个输入源：--cookie <header> | --cookie-stdin | --har <file.har>。',
          );
        }
        if (sourceCount > 1) {
          throw const CliUsageException(
            '--cookie、--cookie-stdin 与 --har 只能三选一，不可同时传入。',
          );
        }
      case CliCommandKind.workerWebhookSet:
        if (url == null || url.isEmpty) {
          throw const CliUsageException(
            'worker webhook set 缺少必填参数 --url <https://...>。',
          );
        }
        _validateHttpUrl(url, '--url');
        if (secretStdin && secretEnv != null) {
          throw const CliUsageException(
            '--secret-stdin 与 --secret-env 不能同时指定。',
          );
        }
      case CliCommandKind.workerMonitorSet:
        if (monitorGrades == null &&
            monitorExams == null &&
            intervalSec == null &&
            !resetBaseline) {
          throw const CliUsageException(
            'worker monitor set 至少需要传入 --grades <on|off>、--exams <on|off>、--interval <sec> 或 --reset-baseline 之一。',
          );
        }
      case CliCommandKind.select:
      case CliCommandKind.drop:
        final label = command == CliCommandKind.select ? 'select' : 'drop';
        if (courseId == null || courseId.isEmpty) {
          throw CliUsageException('$label 缺少必填参数 --course-id <id>。');
        }
      case CliCommandKind.help:
      case CliCommandKind.version:
      case CliCommandKind.authStatus:
      case CliCommandKind.authLogout:
      case CliCommandKind.workerTasksList:
      case CliCommandKind.workerWebhookStatus:
      case CliCommandKind.workerWebhookTest:
      case CliCommandKind.workerWebhookClear:
      case CliCommandKind.workerMonitorStatus:
      case CliCommandKind.workerMonitorCheck:
      case CliCommandKind.today:
      case CliCommandKind.schedule:
      case CliCommandKind.grades:
      case CliCommandKind.exams:
      case CliCommandKind.plan:
      case CliCommandKind.rooms:
      case CliCommandKind.courses:
      case CliCommandKind.update:
        break;
    }

    if (relayUrl != null) {
      _validateHttpUrl(relayUrl, '--relay');
    }
    if (workerUrl != null) {
      _validateWorkerUrlOrAlias(workerUrl, '--worker');
    }

    return ParsedCliInvocation(
      command: command,
      global: global,
      offline: offline,
      url: url,
      casUrl: casUrl,
      user: user,
      passwordStdin: passwordStdin,
      passwordEnv: passwordEnv,
      apiKeyStdin: apiKeyStdin,
      apiKeyEnv: apiKeyEnv,
      name: name,
      listWorkers: listWorkers,
      useWorker: useWorker,
      removeWorker: removeWorker,
      keepWorkers: keepWorkers,
      system: systemProvided ? system : 'auto',
      cookie: cookie,
      cookieStdin: cookieStdin,
      harPath: harPath,
      noVerify: noVerify,
      taskId: taskId,
      intervalSec: intervalSec,
      webhookProvider: webhookProvider,
      secretStdin: secretStdin,
      secretEnv: secretEnv,
      chatId: chatId,
      monitorGrades: monitorGrades,
      monitorExams: monitorExams,
      resetBaseline: resetBaseline,
      monitorKind: monitorKind,
      date: date,
      parsedDate: parsedDate,
      week: week,
      icsPath: icsPath,
      stats: stats,
      campus: campus,
      day: day,
      weeksSpec: weeksSpec,
      weeks: weeks,
      sectionsSpec: sectionsSpec,
      sections: sections,
      query: query,
      courseId: courseId,
      classId: classId,
      confirm: confirm,
      updateCheck: updateCheck,
      updateTargets: updateAll
          ? const <String>{}
          : Set<String>.unmodifiable(updateTargets),
    );
  }

  static bool _parseOnOff(String raw, String flagName) {
    switch (raw.toLowerCase()) {
      case 'on':
      case 'true':
      case '1':
      case 'enable':
      case 'enabled':
        return true;
      case 'off':
      case 'false':
      case '0':
      case 'disable':
      case 'disabled':
        return false;
      default:
        throw CliUsageException(
          '参数 $flagName 仅接受 on 或 off（收到 "$raw"）。',
        );
    }
  }

  static void _ensureNoExtraPositionals(String cmd, List<String> positionals) {
    if (positionals.length > 1) {
      throw CliUsageException(
        '$cmd 不接受额外位置参数：${positionals.sublist(1).join(" ")}',
      );
    }
  }

  static void _validateAllowedSubFlags(
    CliCommandKind command,
    Set<String> used,
  ) {
    final allowed = switch (command) {
      CliCommandKind.authStatus => const <String>{'--offline'},
      CliCommandKind.authLogin => const <String>{
          '--url',
          '--cas-url',
          '--user',
          '--password-stdin',
          '--password-env',
          '--system',
        },
      CliCommandKind.authWorker => const <String>{
          '--url',
          '--name',
          '--list',
          '--use',
          '--remove',
          '--api-key-stdin',
          '--api-key-env',
          '--no-verify',
        },
      CliCommandKind.authImportCookie => const <String>{
          '--url',
          '--cookie',
          '--cookie-stdin',
          '--har',
          '--user',
          '--system',
          '--no-verify',
        },
      CliCommandKind.authLogout => const <String>{'--keep-workers'},
      CliCommandKind.workerTasksList => const <String>{},
      CliCommandKind.workerTasksShow ||
      CliCommandKind.workerTasksDisable ||
      CliCommandKind.workerTasksDelete =>
        const <String>{'--task-id'},
      CliCommandKind.workerTasksEnable => const <String>{
          '--task-id',
          '--interval',
          '--reset-baseline',
        },
      CliCommandKind.workerTasksRun => const <String>{
          '--task-id',
          '--confirm',
        },
      CliCommandKind.workerPushCookies => const <String>{
          '--url',
          '--cookie',
          '--cookie-stdin',
          '--har',
          '--user',
          '--system',
          '--interval',
        },
      CliCommandKind.workerWebhookStatus ||
      CliCommandKind.workerWebhookTest ||
      CliCommandKind.workerWebhookClear =>
        const <String>{},
      CliCommandKind.workerWebhookSet => const <String>{
          '--url',
          '--provider',
          '--secret-stdin',
          '--secret-env',
          '--chat-id',
        },
      CliCommandKind.workerMonitorStatus => const <String>{},
      CliCommandKind.workerMonitorSet => const <String>{
          '--grades',
          '--exams',
          '--interval',
          '--reset-baseline',
        },
      CliCommandKind.workerMonitorCheck => const <String>{'--kind'},
      CliCommandKind.today => const <String>{'--date'},
      CliCommandKind.schedule => const <String>{'--week', '--ics'},
      CliCommandKind.grades => const <String>{'--stats'},
      CliCommandKind.exams => const <String>{},
      CliCommandKind.plan => const <String>{},
      CliCommandKind.rooms => const <String>{
          '--campus',
          '--day',
          '--weeks',
          '--sections',
        },
      CliCommandKind.courses => const <String>{'--query'},
      CliCommandKind.select || CliCommandKind.drop => const <String>{
          '--course-id',
          '--class-id',
          '--confirm',
        },
      CliCommandKind.update => const <String>{
          '--check',
          '--cli',
          '--skill',
          '--worker',
          '--all',
        },
      CliCommandKind.help || CliCommandKind.version => used,
    };

    for (final flag in used) {
      if (!allowed.contains(flag)) {
        throw CliUsageException('选项 $flag 不适用于当前子命令。');
      }
    }
  }

  static void _validateWorkerUrlOrAlias(String raw, String flagName) {
    final trimmed = raw.trim();
    if (trimmed.contains('://') ||
        trimmed.contains('/') ||
        trimmed.contains('@') ||
        trimmed.startsWith('http:')) {
      _validateHttpUrl(trimmed, flagName);
      return;
    }
    if (trimmed.isEmpty || RegExp(r'\s').hasMatch(trimmed)) {
      throw CliUsageException(
        '参数 $flagName 必须是合法的 Worker URL 或已保存网关别名（收到 "$raw"）。',
      );
    }
  }

  static void _validateHttpUrl(String raw, String flagName) {
    final parsed = Urls.parseUrl(raw);
    if (parsed == null ||
        (parsed.scheme != 'http' && parsed.scheme != 'https') ||
        parsed.host.isEmpty) {
      throw CliUsageException(
        '参数 $flagName 必须是合法的 http:// 或 https:// 地址（收到 "$raw"）。',
      );
    }
    if (parsed.userInfo != null) {
      throw CliUsageException(
        '参数 $flagName 严禁包含 userinfo 凭据段（收到 "$raw"）。',
      );
    }
  }

  /// 解析 `YYYY-MM-DD` 日期并校验日历合法性。
  static (int year, int month, int day) parseIsoDate(String raw) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw.trim());
    if (match == null) {
      throw CliUsageException(
        '参数 --date 格式必须为 YYYY-MM-DD（收到 "$raw"）。',
      );
    }
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) {
      throw CliUsageException('参数 --date 日期越界："$raw"。');
    }
    final days = CivilDate.daysFromCivil(year, month, day);
    final roundTrip = CivilDate.civilFromDays(days);
    if (roundTrip != (year, month, day)) {
      throw CliUsageException('参数 --date 不是真实存在的日历日期："$raw"。');
    }
    return (year, month, day);
  }

  /// 解析形如 `1-16`、`1,3,5` 或 `1-4,6,8` 的正整数集合表达式。
  static List<int> parseIntSpec(
    String spec, {
    required int min,
    required int max,
    required String flagName,
  }) {
    final normalized = spec
        .trim()
        .replaceAll('，', ',')
        .replaceAll('、', ',')
        .replaceAll('～', '-')
        .replaceAll('~', '-')
        .replaceAll('—', '-')
        .replaceAll('－', '-');
    if (normalized.isEmpty) {
      throw CliUsageException('参数 $flagName 不能为空。');
    }

    final result = <int>{};
    for (final part in normalized.split(',')) {
      final token = part.trim();
      if (token.isEmpty) {
        throw CliUsageException('参数 $flagName 格式无效："$spec"。');
      }
      final rangeMatch = RegExp(r'^(\d+)\s*-\s*(\d+)$').firstMatch(token);
      if (rangeMatch != null) {
        final start = int.tryParse(rangeMatch.group(1)!);
        final end = int.tryParse(rangeMatch.group(2)!);
        if (start == null ||
            end == null ||
            start < min ||
            end > max ||
            end < start) {
          throw CliUsageException(
            '参数 $flagName 区间 "$token" 越界（允许范围 $min..$max 且起止递增）。',
          );
        }
        for (var v = start; v <= end; v++) {
          result.add(v);
        }
        continue;
      }

      final single = int.tryParse(token);
      if (single == null || single < min || single > max) {
        throw CliUsageException(
          '参数 $flagName 数值 "$token" 无效（允许范围 $min..$max，支持如 1-16 或 1,3,5）。',
        );
      }
      result.add(single);
    }

    final sorted = result.toList()..sort();
    return List<int>.unmodifiable(sorted);
  }
}
