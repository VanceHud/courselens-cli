import 'dart:convert';

import '../core/courselens_core.dart';
import '../data/http/worker_gateway_models.dart';
import 'cli_args.dart';
import 'store/cli_session_record.dart';

/// 单堂课在 `today` 日报中的紧凑视图。
class CliDailyClassView {
  const CliDailyClassView({
    required this.courseName,
    required this.teacher,
    required this.location,
    required this.day,
    required this.startPeriod,
    required this.endPeriod,
    required this.startTime,
    required this.endTime,
    required this.weeksText,
  });

  final String courseName;
  final String teacher;
  final String location;
  final int day;
  final int startPeriod;
  final int endPeriod;
  final String startTime;
  final String endTime;
  final String weeksText;

  String get periodLabel => startPeriod == endPeriod
      ? '第$startPeriod节'
      : '第$startPeriod-$endPeriod节';

  String get timeRange =>
      (startTime.isNotEmpty && endTime.isNotEmpty) ? '$startTime-$endTime' : '';

  Map<String, Object?> toJson() => <String, Object?>{
        'name': courseName,
        'teacher': teacher,
        'location': location,
        'day': day,
        'startPeriod': startPeriod,
        'endPeriod': endPeriod,
        'startTime': startTime,
        'endTime': endTime,
        'weeksText': weeksText,
      };
}

/// 考试倒计时条目视图。
class CliExamCountdownView {
  const CliExamCountdownView({
    required this.entry,
    required this.daysUntil,
    required this.countdownText,
  });

  final ExamEntry entry;
  final int? daysUntil;
  final String countdownText;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': entry.name,
        'examName': entry.examName,
        'time': entry.time,
        'examDate': entry.examDate,
        'startTime': entry.startTime,
        'endTime': entry.endTime,
        'campus': entry.campus,
        'location': entry.location,
        'seat': entry.seat,
        'teacher': entry.teacher,
        'termId': entry.termId,
        'daysUntil': daysUntil,
        'countdown': countdownText,
      };
}

/// 课表时间冲突可读描述。
class CliConflictDetail {
  const CliConflictDetail({
    required this.day,
    required this.firstCourse,
    required this.secondCourse,
    required this.startPeriod,
    required this.endPeriod,
    required this.weeks,
  });

  final int day;
  final String firstCourse;
  final String secondCourse;
  final int startPeriod;
  final int endPeriod;
  final List<int> weeks;

  String get summary =>
      '${CliFormatters.weekdayLabel(day)} 第$startPeriod-$endPeriod节：$firstCourse 与 $secondCourse 冲突（第${weeks.join("、")}周）';

  Map<String, Object?> toJson() => <String, Object?>{
        'day': day,
        'weekday': CliFormatters.weekdayLabel(day),
        'firstCourse': firstCourse,
        'secondCourse': secondCourse,
        'startPeriod': startPeriod,
        'endPeriod': endPeriod,
        'weeks': weeks,
        'summary': summary,
      };
}

/// 紧凑 Markdown / 结构化 JSON 双模输出格式化器。
class CliFormatters {
  const CliFormatters._();

  static const JsonEncoder _prettyJson = JsonEncoder.withIndent('  ');

  static String encodeJson(Object? data) => _prettyJson.convert(data);

  static String weekdayLabel(int day) => switch (day) {
        1 => '周一',
        2 => '周二',
        3 => '周三',
        4 => '周四',
        5 => '周五',
        6 => '周六',
        7 => '周日',
        _ => '周$day',
      };

  static String _cell(String text) {
    final cleaned = text
        .replaceAll('\r\n', ' ')
        .replaceAll('\n', ' ')
        .replaceAll('|', r'\|')
        .trim();
    return cleaned.isEmpty ? '-' : cleaned;
  }

  static Map<String, Object?> studentToJson(StudentIdentity identity) =>
      <String, Object?>{
        'name': identity.name,
        'studentId': identity.studentId,
        'department': identity.department,
        'major': identity.major,
        'className': identity.className,
        'grade': identity.grade,
      };

  static String formatVersion({required bool json}) {
    if (json) {
      return encodeJson(<String, Object?>{
        'name': 'courselens',
        'version': CliArgs.cliVersion,
      });
    }
    return 'courselens ${CliArgs.cliVersion}';
  }

  static String formatHelp({String? topic, required bool json}) {
    if (json) {
      return encodeJson(<String, Object?>{
        'name': 'courselens',
        'version': CliArgs.cliVersion,
        'topic': topic,
        'globalFlags': const <String>[
          '--demo',
          '--json',
          '--term <term>',
          '--relay <url>',
          '--worker <name|workerUrl>',
          '--store <auto|keychain|file|env>',
          '--session-file <path>',
          '-h, --help',
          '--version',
        ],
        'commands': const <Map<String, String>>[
          {
            'command': 'whoami / auth status [--offline]',
            'description': '查看存储后端、教务地址、系统类型、学生信息与在线探活状态',
          },
          {
            'command':
                'auth login --url <baseUrl> --user <id> [--password-stdin | --password-env <VAR>] [--system <auto|ZF|ZF_OLD|QZ|QZ_OLD>]',
            'description': '安全登录教务系统并持久化会话（严禁 --password 明文参数）',
          },
          {
            'command':
                'auth worker (--url <workerUrl> [--name <alias>] [--api-key-stdin | --api-key-env <VAR>] [--no-verify] | --list | --use <name|url> | --remove <name|url>)',
            'description': '绑定、保存、列出或切换有状态 Cloudflare Worker 会话网关（API Key 鉴权）',
          },
          {
            'command':
                'auth import-cookie --url <baseUrl> (--cookie <header> | --cookie-stdin | --har <file.har>) [--user <id>] [--system <auto|...>] [--no-verify]',
            'description': '从 Cookie 头或 .har 抓包导入会话并可选在线验证',
          },
          {
            'command': 'auth logout [--keep-workers]',
            'description': '执行 session.retire() 封口内存 CookieJar 并清理本地会话存储（--keep-workers 保留已存网关）',
          },
          {
            'command':
                'worker tasks [list | show <taskId> | enable <taskId> [--interval <sec>] | disable <taskId> | run <taskId> [--confirm] | delete <taskId>]',
            'description': '查看云端任务列表、任务详情、独立定时开关（默认全部关闭）与即时执行',
          },
          {
            'command':
                'worker push-cookies (--cookie <header> | --cookie-stdin | --har <file.har>) [--url <portalUrl>] [--user <id>] [--system <auto|...>] [--interval <sec>]',
            'description': '向有状态 Worker 动态注入扫码/CAS/SSO 会话 Cookie',
          },
          {
            'command':
                'worker webhook [status | set --url <https://...> [--provider <auto|bark|feishu|dingtalk|wecom|telegram|generic>] [--secret-stdin | --secret-env <VAR>] | test | clear]',
            'description': '配置云端抢课成功与成绩/考试变动的多通道 Webhook 通知',
          },
          {
            'command':
                'worker monitor [status | set [--grades <on|off>] [--exams <on|off>] [--interval <sec>] [--reset-baseline] | check [--kind <all|grades|exams>]]',
            'description': '查看或配置云端成绩/考试定时巡检（默认全部关闭，零干扰懒保活）',
          },
          {
            'command': 'today [--date YYYY-MM-DD]',
            'description': '高密度单次聚合日报：教学周、今日/明日课程与近期考试倒计时',
          },
          {
            'command': 'schedule [--week <1..30>] [--ics <out.ics>]',
            'description': '查询周课表、实践课与冲突预警，支持导出 RFC 5545 .ics 日历',
          },
          {
            'command': 'grades [--stats]',
            'description': '查询成绩单与加权均分、必修 GPA、分类学分统计',
          },
          {
            'command': 'exams',
            'description': '查询考试安排、校区考场、座位号与倒计时',
          },
          {
            'command': 'plan',
            'description': '查询培养方案与学业修读进度树（N105515）',
          },
          {
            'command':
                'rooms [--campus <id>] [--day <1..7>] [--weeks <spec>] [--sections <spec>]',
            'description': '查询空闲教室（N2155，支持 1-16 或 1,3,5 规格）',
          },
          {
            'command': 'courses [--query <kw>]',
            'description': '查询全天候已选课程名单（N255010）与可选课程列表',
          },
          {
            'command':
                'select --course-id <id> [--class-id <jxbId>] [--confirm]',
            'description': '两步确认制选课（不带 --confirm 仅零写包预检并返回退出码 2）',
          },
          {
            'command': 'drop --course-id <id> [--class-id <jxbId>] [--confirm]',
            'description': '两步确认制退课（不带 --confirm 仅零写包预检并返回退出码 2）',
          },
          {
            'command': 'update [--check] [--cli] [--skill] [--worker] [--all]',
            'description': '检查或更新 CLI 本体、Agent Skill 与已部署的会话网关 Worker（不带组件开关默认全部；--check 只报告不修改）',
          },
        ],
        'exitCodes': const <String, String>{
          '0': '执行成功',
          '1': '参数错误、未登录/过期、STORAGE_UNAVAILABLE 或网络/业务失败',
          '2': 'select/drop 或云端抢课干跑预检完成（未传 --confirm，零写网络发包）',
        },
      });
    }

    return '''
CourseLens Native CLI (v${CliArgs.cliVersion}) — 高校教务命令行与 AI Agent 工具

用法:
  courselens [全局参数] <命令> [子命令参数]

全局参数 (可在任意位置传入):
  --demo                              离线运行内置脱敏演示夹具（无需网络或本地配置）
  --json                              向 stdout 输出纯净 JSON（诊断与错误输出至 stderr）
  --term <term>                       指定学年学期（如 2025-2026-1）
  --relay <url>                       指定无状态 HTTP 转发网关地址
  --worker <name|workerUrl>           指定已保存网关别名或有状态 Cloudflare Worker 地址
  --store <auto|keychain|file|env>    指定会话存储后端（默认 auto）
  --session-file <path>               指定 0600 会话文件路径（启用 file 后端）
  -h, --help                          显示帮助说明
  --version                           显示版本号

身份与会话命令:
  whoami                              auth status 的顶层快捷别名
  auth status [--offline]             查看存储后端、教务地址、系统类型、学籍与会话存活状态
  auth login --url <baseUrl> --user <id> [--password-stdin | --password-env <VAR>] [--system <auto|ZF|ZF_OLD|QZ|QZ_OLD>]
                                      安全登录并保存会话（拒绝 --password 明文参数以防 ps 泄露）
  auth worker --url <workerUrl> [--name <alias>] [--api-key-stdin | --api-key-env <VAR>] [--no-verify]
  auth worker --list | --use <name|url> | --remove <name|url>
                                      保存、查看、切换或移除有状态 Cloudflare Worker 网关与 API Key
  auth import-cookie --url <baseUrl> (--cookie <header> | --cookie-stdin | --har <file.har>) [--user <id>] [--system <auto|...>] [--no-verify]
                                      从 Cookie 或 .har 抓包导入会话
  auth logout [--keep-workers]        调用 session.retire() 封口会话并清理已存凭据（--keep-workers 保留已保存网关）

云端有状态 Worker 网关控制命令:
  worker tasks [list]                 查看云端任务列表（默认关闭的成绩/考试巡检与主动心跳）
  worker tasks show <taskId>          查看单个云端任务详情、指标、变动记录与执行日志
  worker tasks enable <taskId> [--interval <sec>] [--reset-baseline]
  worker tasks disable <taskId>       单独开启或关闭云端任务（关闭时零后台唤醒，不影响懒保活）
  worker tasks run <taskId> [--confirm]
                                      立即触发单次任务（写类任务必须带 --confirm）
  worker tasks delete <taskId>        删除云端任务
  worker push-cookies (--cookie <hdr> | --cookie-stdin | --har <file.har>) [--url <portalUrl>]
                                      向云端 Durable Object 动态推送扫码/CAS/SSO 登录后的 Cookie
  worker webhook [status | set | test | clear]
                                      配置 Bark/飞书/钉钉/企微/Telegram/通用 JSON 推送通知
  worker monitor [status | set | check]
                                      配置云端成绩/考试巡检开关（默认关闭）或手动执行一次巡检

只读教务查询命令:
  today [--date YYYY-MM-DD]           单次聚合日报：教学周、今日与明日课表、近期考试倒计时
  schedule [--week <1..30>] [--ics <out.ics>]
                                      周课表、实践课与撞课冲突检测（可选导出 RFC 5545 .ics）
  grades [--stats]                    成绩单列表及加权均分 / 必修 GPA / 分类学分汇总
  exams                               考试时间、考场地点、座位号与倒计时
  plan                                学业修读进度与培养方案学分树（N105515）
  rooms [--campus <id>] [--day <1..7>] [--weeks <spec>] [--sections <spec>]
                                      空教室查询（N2155，支持 1-16 或 1,3,5）
  courses [--query <kw>]              已选课程名单（N255010）与可选课程查询

维护命令:
  update [--check] [--cli] [--skill] [--worker] [--all]
                                      检查或更新 CLI 本体、已安装的 Agent Skill 与已部署会话网关 Worker
                                      （不带组件开关默认全部；--check 只报告版本状态，不做任何修改）

受控写操作命令 (红线 #2 & #3):
  select --course-id <id> [--class-id <jxbId>] [--confirm]
  drop   --course-id <id> [--class-id <jxbId>] [--confirm]
    * 未传 --confirm：零写网络发包，执行冲突与目标预检，打印确认命令并以退出码 2 退出
    * 传入 --confirm：发送单次写请求；若遇 RESULT_UNKNOWN 超时绝不盲目重发，自动只读核实已选名单''';
  }

  static String formatError({
    required String code,
    required String message,
  }) =>
      encodeJson(<String, Object?>{
        'ok': false,
        'error': message,
        'code': code,
      });

  static String formatAuthStatus({
    required bool json,
    required bool demo,
    required String storeBackend,
    required bool authenticated,
    required bool offline,
    required bool? alive,
    required String? baseUrl,
    required String? systemType,
    required String? username,
    required StudentIdentity identity,
    required int cookieCount,
    required String? relayUrl,
    String? workerUrl,
    required DateTime? updatedAt,
    required String message,
  }) {
    final normalizedSys = (systemType == null || systemType.trim().isEmpty)
        ? null
        : systemType.trim().toUpperCase();
    final hasWorker = workerUrl != null && workerUrl.trim().isNotEmpty;
    if (json) {
      return encodeJson(<String, Object?>{
        'ok': authenticated && (alive != false),
        'demo': demo,
        'authenticated': authenticated,
        'offline': offline,
        'alive': alive,
        'mode': hasWorker ? 'worker' : (demo ? 'demo' : 'local'),
        'storeBackend': storeBackend,
        'baseUrl': baseUrl,
        'systemType': normalizedSys,
        'username': username,
        'student': studentToJson(identity),
        'cookieCount': cookieCount,
        'relayUrl': relayUrl,
        if (hasWorker) 'workerUrl': workerUrl,
        'updatedAt': updatedAt?.toUtc().toIso8601String(),
        'message': message,
      });
    }

    final livenessLabel = !authenticated
        ? '未登录 (UNAUTHENTICATED)'
        : offline
            ? '离线跳过探活 (--offline)'
            : (alive == true
                ? '在线有效 (ACTIVE)'
                : (alive == false ? '已失效 (SESSION_EXPIRED)' : '未验证'));
    final buf = StringBuffer()
      ..writeln('# CourseLens 会话状态')
      ..writeln('- **存储后端**: $storeBackend')
      ..writeln('- **会话状态**: $livenessLabel')
      ..writeln('- **教务地址**: ${(baseUrl != null && baseUrl.isNotEmpty) ? baseUrl : "-"}')
      ..writeln('- **系统类型**: ${normalizedSys ?? "-"}')
      ..writeln('- **账号/学号**: ${identity.studentId.isNotEmpty ? identity.studentId : (username ?? "-")}')
      ..writeln('- **学生姓名**: ${identity.name.isNotEmpty ? identity.name : "-"}');
    if (identity.department.isNotEmpty || identity.className.isNotEmpty) {
      buf.writeln(
        '- **院系班级**: ${[identity.department, identity.className].where((s) => s.isNotEmpty).join(" / ")}',
      );
    }
    if (hasWorker) {
      buf.writeln('- **有状态 Worker**: $workerUrl (API Key 托管，本地零 Cookie)');
    }
    if (relayUrl != null && relayUrl.isNotEmpty) {
      buf.writeln('- **转发网关**: $relayUrl');
    }
    buf.write('- **摘要**: $message');
    return buf.toString();
  }

  static String formatAuthSaved({
    required bool json,
    required String title,
    required String storeBackend,
    required String baseUrl,
    required String? systemType,
    required String? username,
    required StudentIdentity identity,
    required int cookieCount,
    required bool verified,
    String? workerUrl,
    required String message,
  }) {
    final normalizedSys = (systemType == null || systemType.trim().isEmpty)
        ? 'AUTO'
        : systemType.trim().toUpperCase();
    final hasWorker = workerUrl != null && workerUrl.trim().isNotEmpty;
    if (json) {
      return encodeJson(<String, Object?>{
        'ok': true,
        'verified': verified,
        'mode': hasWorker ? 'worker' : 'local',
        'storeBackend': storeBackend,
        'baseUrl': baseUrl,
        if (hasWorker) 'workerUrl': workerUrl,
        'systemType': normalizedSys,
        'username': username,
        'student': studentToJson(identity),
        'cookieCount': cookieCount,
        'message': message,
      });
    }
    final buf = StringBuffer()
      ..writeln('# $title')
      ..writeln('- **存储后端**: $storeBackend');
    if (hasWorker) {
      buf.writeln('- **有状态 Worker**: $workerUrl');
    }
    buf
      ..writeln('- **教务地址**: ${baseUrl.isNotEmpty ? baseUrl : "-"}')
      ..writeln('- **系统类型**: $normalizedSys')
      ..writeln('- **账号/学号**: ${identity.studentId.isNotEmpty ? identity.studentId : (username ?? "-")}')
      ..writeln('- **学生姓名**: ${identity.name.isNotEmpty ? identity.name : "-"}');
    if (!hasWorker) {
      buf.writeln('- **Cookie 数**: $cookieCount');
    }
    buf
      ..writeln('- **在线核验**: ${verified ? "已通过" : "已跳过 (--no-verify)"}')
      ..write('- **结果**: $message');
    return buf.toString();
  }

  static String formatAuthLogout({
    required bool json,
    required String storeBackend,
    required bool sessionRetired,
    required String message,
  }) {
    if (json) {
      return encodeJson(<String, Object?>{
        'ok': true,
        'retired': sessionRetired,
        'storeBackend': storeBackend,
        'message': message,
      });
    }
    return '# 已安全退出会话\n'
        '- **存储后端**: $storeBackend\n'
        '- **内存会话封口**: ${sessionRetired ? "已执行 session.retire()" : "无活动会话"}\n'
        '- **结果**: $message';
  }

  static String formatToday({
    required bool json,
    required String date,
    required int weekday,
    required String term,
    required int? academicWeek,
    required String tomorrowDate,
    required int tomorrowWeekday,
    required int? tomorrowAcademicWeek,
    required List<CliDailyClassView> todayClasses,
    required List<CliDailyClassView> tomorrowClasses,
    required List<CliExamCountdownView> upcomingExams,
  }) {
    if (json) {
      return encodeJson(<String, Object?>{
        'date': date,
        'weekday': weekdayLabel(weekday),
        'dayOfWeek': weekday,
        'term': term,
        'academicWeek': academicWeek,
        'inSession': academicWeek != null,
        'todayClasses': todayClasses.map((c) => c.toJson()).toList(),
        'tomorrowDate': tomorrowDate,
        'tomorrowWeekday': weekdayLabel(tomorrowWeekday),
        'tomorrowDayOfWeek': tomorrowWeekday,
        'tomorrowAcademicWeek': tomorrowAcademicWeek,
        'tomorrowClasses': tomorrowClasses.map((c) => c.toJson()).toList(),
        'upcomingExams': upcomingExams.map((e) => e.toJson()).toList(),
      });
    }

    final weekText = academicWeek != null ? '第 $academicWeek 周' : '非教学周/假期';
    final tmrWeekText = tomorrowAcademicWeek != null
        ? '第 $tomorrowAcademicWeek 周'
        : '非教学周/假期';

    final buf = StringBuffer()
      ..writeln(
        '# 今日教务概览 ($date ${weekdayLabel(weekday)} · ${term.isEmpty ? "当前学期" : term} · $weekText)',
      )
      ..writeln()
      ..writeln('## 今日课程 ($date ${weekdayLabel(weekday)} · ${todayClasses.length} 门)');
    _appendDailyClassTable(buf, todayClasses);

    buf
      ..writeln()
      ..writeln(
        '## 明日课程 ($tomorrowDate ${weekdayLabel(tomorrowWeekday)} · $tmrWeekText · ${tomorrowClasses.length} 门)',
      );
    _appendDailyClassTable(buf, tomorrowClasses);

    buf
      ..writeln()
      ..writeln('## 考试倒计时 (${upcomingExams.length} 场)');
    if (upcomingExams.isEmpty) {
      buf.write('暂无近期考试安排。');
    } else {
      buf
        ..writeln('| 倒计时 | 课程 | 时间 | 考场 | 座位 |')
        ..writeln('| --- | --- | --- | --- | --- |');
      for (final exam in upcomingExams) {
        final venue = [exam.entry.campus, exam.entry.location]
            .where((s) => s.trim().isNotEmpty)
            .join(' ');
        buf.writeln(
          '| ${_cell(exam.countdownText)} | ${_cell(exam.entry.name)} | ${_cell(exam.entry.time)} | ${_cell(venue)} | ${_cell(exam.entry.seat)} |',
        );
      }
    }
    return buf.toString().trimRight();
  }

  static void _appendDailyClassTable(
    StringBuffer buf,
    List<CliDailyClassView> classes,
  ) {
    if (classes.isEmpty) {
      buf.writeln('无排课。');
      return;
    }
    buf
      ..writeln('| 节次 | 时间 | 课程 | 教师 | 教室 |')
      ..writeln('| --- | --- | --- | --- | --- |');
    for (final c in classes) {
      buf.writeln(
        '| ${_cell(c.periodLabel)} | ${_cell(c.timeRange)} | ${_cell(c.courseName)} | ${_cell(c.teacher)} | ${_cell(c.location)} |',
      );
    }
  }

  static String formatSchedule({
    required bool json,
    required String term,
    required int? weekFilter,
    required int totalWeeks,
    required SemesterStart semesterStart,
    required List<ScheduleEntry> entries,
    required List<PracticalCourse> practicalCourses,
    required List<CliConflictDetail> conflicts,
    required List<PeriodTime> periodTimes,
    String? icsPath,
  }) {
    final periodMap = <int, PeriodTime>{
      for (final p in periodTimes) p.period: p,
    };

    if (json) {
      return encodeJson(<String, Object?>{
        'term': term,
        'week': weekFilter,
        'totalWeeks': totalWeeks,
        'semesterStart': semesterStart.toString(),
        'count': entries.length,
        'entries': entries
            .map(
              (e) => <String, Object?>{
                'name': e.name,
                'courseCode': e.courseCode,
                'teachingClass': e.teachingClass,
                'teacher': e.teacher,
                'location': e.location,
                'campus': e.campus,
                'day': e.day,
                'weekday': weekdayLabel(e.day),
                'startPeriod': e.period.start,
                'endPeriod': e.period.end,
                'startTime': periodMap[e.period.start]?.start ?? '',
                'endTime': periodMap[e.period.end]?.end ?? '',
                'weeks': (e.weeks.weeks.toList()..sort()),
                'weeksText': e.weeks.text,
                'credits': e.credits,
                'category': e.courseCategory,
              },
            )
            .toList(),
        'practicalCourses': practicalCourses
            .map(
              (p) => <String, Object?>{
                'name': p.name,
                'courseCode': p.courseCode,
                'teacher': p.teacher,
                'credits': p.credits,
                'weeksText': p.weeksText,
                'category': p.category,
                'summary': p.summary,
              },
            )
            .toList(),
        'conflicts': conflicts.map((c) => c.toJson()).toList(),
        'icsPath': ?icsPath,
      });
    }

    final scopeLabel = weekFilter != null ? '第 $weekFilter 周' : '全学期';
    final buf = StringBuffer()
      ..writeln(
        '# 课表 (${term.isEmpty ? "当前学期" : term} · $scopeLabel · 开学周一 $semesterStart)',
      )
      ..writeln();

    if (entries.isEmpty) {
      buf.writeln('当前范围内暂无常规排课。');
    } else {
      buf
        ..writeln('| 星期 | 节次 | 时间 | 课程 | 教师 | 教室 | 周次 |')
        ..writeln('| --- | --- | --- | --- | --- | --- | --- |');
      for (final e in entries) {
        final pStart = periodMap[e.period.start]?.start ?? '';
        final pEnd = periodMap[e.period.end]?.end ?? '';
        final timeRange =
            (pStart.isNotEmpty && pEnd.isNotEmpty) ? '$pStart-$pEnd' : '-';
        buf.writeln(
          '| ${weekdayLabel(e.day)} | ${e.period.start}-${e.period.end}节 | ${_cell(timeRange)} | ${_cell(e.name)} | ${_cell(e.teacher)} | ${_cell(e.location)} | ${_cell(e.weeks.text)} |',
        );
      }
    }

    if (practicalCourses.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('## 实践与集中环节 (${practicalCourses.length} 门)')
        ..writeln('| 课程 | 教师 | 学分 | 周次 | 说明 |')
        ..writeln('| --- | --- | --- | --- | --- |');
      for (final p in practicalCourses) {
        buf.writeln(
          '| ${_cell(p.name)} | ${_cell(p.teacher)} | ${_cell(p.credits)} | ${_cell(p.weeksText)} | ${_cell(p.summary)} |',
        );
      }
    }

    if (conflicts.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('## 课表冲突预警 (${conflicts.length} 处)');
      for (final c in conflicts) {
        buf.writeln('- [CONFLICT] ${c.summary}');
      }
    }

    if (icsPath != null) {
      buf
        ..writeln()
        ..writeln('> 已导出 RFC 5545 日历文件: `$icsPath`');
    }

    return buf.toString().trimRight();
  }

  static String formatGrades({
    required bool json,
    required String? termFilter,
    required GradeReport report,
    required GradeSummary summary,
    required bool includeStats,
  }) {
    final byTerm = <String, List<GradeEntry>>{};
    for (final g in report.grades) {
      final key = g.term.trim().isEmpty ? '未标注学期' : g.term.trim();
      (byTerm[key] ??= <GradeEntry>[]).add(g);
    }
    final termStats = <String, Map<String, Object?>>{};
    final sortedTerms = byTerm.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final t in sortedTerms) {
      final subSummary = GradeMath.summarize(GradeReport(grades: byTerm[t]!));
      termStats[t] = <String, Object?>{
        'gpa': subSummary.gpaText,
        'weightedAverageScore': subSummary.weightedAverageScore,
        'compulsoryGpa': subSummary.compulsoryGpa,
        'earnedCredits': subSummary.earnedCredits,
        'attemptedCredits': subSummary.attemptedCredits,
        'courseCount': subSummary.courseCount,
      };
    }

    if (json) {
      return encodeJson(<String, Object?>{
        'term': termFilter,
        'count': report.grades.length,
        'summary': <String, Object?>{
          'gpa': summary.gpaText,
          'credits': summary.creditsText,
          'weightedAverageScore': summary.weightedAverageScore,
          'compulsoryGpa': summary.compulsoryGpa,
          'earnedCredits': summary.earnedCredits,
          'attemptedCredits': summary.attemptedCredits,
          'courseCount': summary.courseCount,
          if (includeStats) ...<String, Object?>{
            'distribution': <String, int>{
              'excellent': summary.excellent,
              'good': summary.good,
              'medium': summary.medium,
              'pass': summary.pass,
              'failing': summary.failing,
            },
            'creditsByCategory': summary.creditsByCategory,
            'byTerm': termStats,
          },
        },
        'grades': report.grades
            .map(
              (g) => <String, Object?>{
                'name': g.name,
                'courseCode': g.courseCode,
                'score': g.score,
                'numericScore': g.numericScore,
                'credits': g.credits,
                'gradePoint': g.gradePoint,
                'term': g.term,
                'category': g.category,
                'examNature': g.examNature,
                'teacher': g.teacher,
                'passed': GradeMath.isPassed(g),
              },
            )
            .toList(),
      });
    }

    final scope = (termFilter != null && termFilter.isNotEmpty)
        ? termFilter
        : '全部学期';
    final buf = StringBuffer()
      ..writeln('# 成绩单 ($scope · 共 ${report.grades.length} 条记录)')
      ..writeln(
        '- **平均学分绩点 (GPA)**: ${summary.gpaText} | **加权平均分**: ${summary.weightedAverageScore} | **必修 GPA**: ${summary.compulsoryGpa} | **已获/修读学分**: ${summary.creditsText} / ${GradeMath.formatFixed(summary.attemptedCredits, 1)}',
      );

    if (includeStats) {
      buf.writeln(
        '- **成绩分布 (去重 ${summary.courseCount} 门)**: 优(>=90) ${summary.excellent} · 良(80-89) ${summary.good} · 中(70-79) ${summary.medium} · 及格(60-69) ${summary.pass} · 未通过 ${summary.failing}',
      );
      if (summary.creditsByCategory.isNotEmpty) {
        final cats = summary.creditsByCategory.entries
            .map((e) => '${e.key}: ${GradeMath.formatFixed(e.value, 1)}')
            .join(' | ');
        buf.writeln('- **分类已获学分**: $cats');
      }
      if (sortedTerms.length > 1) {
        buf
          ..writeln()
          ..writeln('## 分学期统计')
          ..writeln('| 学期 | 门数 | GPA | 加权均分 | 必修 GPA | 已获学分 |')
          ..writeln('| --- | --- | --- | --- | --- | --- |');
        for (final t in sortedTerms) {
          final ts = termStats[t]!;
          buf.writeln(
            '| ${_cell(t)} | ${ts["courseCount"]} | ${ts["gpa"]} | ${ts["weightedAverageScore"]} | ${ts["compulsoryGpa"]} | ${GradeMath.formatFixed(ts["earnedCredits"] as double, 1)} |',
          );
        }
      }
    }

    buf.writeln();
    if (report.grades.isEmpty) {
      buf.writeln('暂无成绩记录。');
    } else {
      buf
        ..writeln('| 学期 | 课程名称 | 成绩 | 绩点 | 学分 | 性质 | 备注 |')
        ..writeln('| --- | --- | --- | --- | --- | --- | --- |');
      for (final g in report.grades) {
        buf.writeln(
          '| ${_cell(g.term)} | ${_cell(g.name)} | ${_cell(g.score)} | ${_cell(g.gradePoint)} | ${_cell(g.credits)} | ${_cell(g.category)} | ${_cell(g.examNature)} |',
        );
      }
    }
    return buf.toString().trimRight();
  }

  static String formatExams({
    required bool json,
    required String? termFilter,
    required String referenceDate,
    required List<CliExamCountdownView> exams,
  }) {
    if (json) {
      return encodeJson(<String, Object?>{
        'term': termFilter,
        'referenceDate': referenceDate,
        'count': exams.length,
        'exams': exams.map((e) => e.toJson()).toList(),
      });
    }

    final scope = (termFilter != null && termFilter.isNotEmpty)
        ? termFilter
        : '当前/全部学期';
    final buf = StringBuffer()
      ..writeln('# 考试安排 ($scope · 基准日 $referenceDate · ${exams.length} 场)')
      ..writeln();

    if (exams.isEmpty) {
      buf.writeln('暂无考试安排。');
    } else {
      buf
        ..writeln('| 倒计时 | 课程 | 场次 | 考试时间 | 校区/考场 | 座位 | 教师 |')
        ..writeln('| --- | --- | --- | --- | --- | --- | --- |');
      for (final item in exams) {
        final e = item.entry;
        final venue = [e.campus, e.location]
            .where((s) => s.trim().isNotEmpty)
            .join(' ');
        buf.writeln(
          '| ${_cell(item.countdownText)} | ${_cell(e.name)} | ${_cell(e.examName)} | ${_cell(e.time)} | ${_cell(venue)} | ${_cell(e.seat)} | ${_cell(e.teacher)} |',
        );
      }
    }
    return buf.toString().trimRight();
  }

  static String formatPlan({
    required bool json,
    required AcademicProgressReport report,
    required Map<String, List<PlanCourseEntry>> coursesByCategory,
  }) {
    if (json) {
      return encodeJson(<String, Object?>{
        'officialGpa': report.officialGpa,
        'studentId': report.studentId,
        'totalCourses': report.totalCourses,
        'passedCourses': report.passedCourses,
        'inProgressCourses': report.inProgressCourses,
        'failedCourses': report.failedCourses,
        'unstudiedCourses': report.unstudiedCourses,
        'outsidePlanPassedCourses': report.outsidePlanPassedCourses,
        'categories': report.categories
            .map(
              (c) => <String, Object?>{
                'id': c.id,
                'parentId': c.parentId,
                'name': c.name,
                'isLeaf': c.isLeaf,
                'earnedCredits': c.earnedCredits,
                'requiredCredits': c.requiredCredits,
                'remainingCredits': c.remainingCredits,
                'passed': c.passed,
                'completionRatio': c.completionRatio,
                'courses': (coursesByCategory[c.id] ?? const <PlanCourseEntry>[])
                    .map(
                      (p) => <String, Object?>{
                        'courseCode': p.courseCode,
                        'courseName': p.courseName,
                        'credits': p.credits,
                        'category': p.category,
                        'courseType': p.courseType,
                        'status': p.status.name,
                        'statusLabel': p.status.label,
                        'recommendedTerm': p.recommendedTerm,
                        'maxScore': p.maxScore,
                        'score': p.score,
                        'gpa': p.gpa,
                      },
                    )
                    .toList(),
              },
            )
            .toList(),
      });
    }

    final buf = StringBuffer()
      ..writeln('# 培养方案与学业修读进度')
      ..writeln(
        '- **学校权威 GPA**: ${report.officialGpa.isEmpty ? "-" : report.officialGpa} | **总计划门数**: ${report.totalCourses} (已通过 ${report.passedCourses} · 在读 ${report.inProgressCourses} · 未修 ${report.unstudiedCourses} · 未通过 ${report.failedCourses})',
      )
      ..writeln()
      ..writeln('## 模块学分树')
      ..writeln('| 模块分类 | 已获学分 | 要求学分 | 差额 | 状态 |')
      ..writeln('| --- | --- | --- | --- | --- |');

    final childrenByParent = <String, List<CreditCategoryNode>>{};
    final nodeIds = report.categories.map((c) => c.id).toSet();
    for (final node in report.categories) {
      final parentKey =
          (node.parentId.isEmpty || !nodeIds.contains(node.parentId))
              ? ''
              : node.parentId;
      (childrenByParent[parentKey] ??= <CreditCategoryNode>[]).add(node);
    }

    void renderTree(String parentId, int depth) {
      final list = childrenByParent[parentId];
      if (list == null) return;
      for (final node in list) {
        final indent = depth > 0 ? '${"  " * depth}└─ ' : '';
        final earned = node.earnedCredits?.toStringAsFixed(1) ?? '-';
        final req = node.requiredCredits?.toStringAsFixed(1) ?? '-';
        final rem = node.remainingCredits?.toStringAsFixed(1) ?? '-';
        final status = node.passed ||
                (node.remainingCredits != null && node.remainingCredits! <= 0)
            ? '已达标'
            : '修读中';
        buf.writeln(
          '| ${_cell("$indent${node.name}")} | $earned | $req | $rem | $status |',
        );
        renderTree(node.id, depth + 1);
      }
    }

    renderTree('', 0);

    for (final leaf in report.leafCategories) {
      final courses = coursesByCategory[leaf.id] ?? const <PlanCourseEntry>[];
      if (courses.isEmpty) continue;
      buf
        ..writeln()
        ..writeln('### ${leaf.name} (${courses.length} 门)')
        ..writeln('| 课程号 | 课程名称 | 学分 | 状态 | 建议学期 | 成绩/绩点 |')
        ..writeln('| --- | --- | --- | --- | --- | --- |');
      for (final c in courses) {
        final scorePart = c.maxScore.isNotEmpty
            ? c.maxScore
            : (c.score.isNotEmpty ? c.score : '');
        final scoreGpa = [scorePart, if (c.gpa.isNotEmpty) 'GPA ${c.gpa}']
            .where((s) => s.isNotEmpty)
            .join(' / ');
        buf.writeln(
          '| ${_cell(c.courseCode)} | ${_cell(c.courseName)} | ${_cell(c.credits)} | ${c.status.label} | ${_cell(c.recommendedTerm)} | ${_cell(scoreGpa)} |',
        );
      }
    }
    return buf.toString().trimRight();
  }

  static String formatRooms({
    required bool json,
    required String campusId,
    required int day,
    required List<int> weeks,
    required List<int> sections,
    required String zcdBitmask,
    required String jcdBitmask,
    required List<EmptyClassroom> rooms,
  }) {
    if (json) {
      return encodeJson(<String, Object?>{
        'query': <String, Object?>{
          'campus': campusId,
          'day': day,
          'weekday': weekdayLabel(day),
          'weeks': weeks,
          'sections': sections,
          'zcd': zcdBitmask,
          'jcd': jcdBitmask,
        },
        'count': rooms.length,
        'rooms': rooms
            .map(
              (r) => <String, Object?>{
                'id': r.id,
                'code': r.code,
                'name': r.name,
                'building': r.building,
                'type': r.type,
                'seats': r.seats,
                'examSeats': r.examSeats,
                'campus': r.campus,
                'department': r.department,
              },
            )
            .toList(),
      });
    }

    final buf = StringBuffer()
      ..writeln(
        '# 空闲教室查询 (校区 $campusId · ${weekdayLabel(day)} · 第${weeks.join(",")}周 · 第${sections.join(",")}节 · 共 ${rooms.length} 间)',
      )
      ..writeln();
    if (rooms.isEmpty) {
      buf.writeln('未找到符合条件的空闲教室。');
    } else {
      buf
        ..writeln('| 编号 | 教室名称 | 楼宇 | 类型 | 座位数 | 考试座位数 | 校区 |')
        ..writeln('| --- | --- | --- | --- | --- | --- | --- |');
      for (final r in rooms) {
        buf.writeln(
          '| ${_cell(r.code)} | ${_cell(r.name)} | ${_cell(r.building)} | ${_cell(r.type)} | ${r.seats ?? "-"} | ${r.examSeats ?? "-"} | ${_cell(r.campus)} |',
        );
      }
    }
    return buf.toString().trimRight();
  }

  static String formatCourses({
    required bool json,
    required String term,
    required String? query,
    required bool selectionRoundOpen,
    required String selectionClosedMessage,
    required List<EnrolledCourseEntry> enrolledCourses,
    required List<SelectedCourse> selectedCourses,
    required List<CourseOffer> selectableOffers,
    required Map<String, List<CourseSection>> sectionsByCourse,
  }) {
    if (json) {
      return encodeJson(<String, Object?>{
        'term': term,
        'query': query,
        'selectionRoundOpen': selectionRoundOpen,
        'selectionClosedMessage': selectionClosedMessage,
        'enrolledCourses': enrolledCourses
            .map(
              (e) => <String, Object?>{
                'courseCode': e.courseCode,
                'courseName': e.courseName,
                'teachingClass': e.teachingClass,
                'jxbId': e.jxbId,
                'teacher': e.teacher,
                'credits': e.credits,
                'scheduleText': e.scheduleText,
                'location': e.location,
                'category': e.category,
                'selectionStatus': e.selectionStatus,
                'termId': e.termId,
              },
            )
            .toList(),
        'selectedCourses': selectedCourses
            .map(
              (s) => <String, Object?>{
                'id': s.id,
                'courseId': s.courseId,
                'sectionId': s.sectionId,
                'name': s.name,
                'teacher': s.teacher,
                'time': s.time,
                'location': s.location,
              },
            )
            .toList(),
        'selectableCourses': selectableOffers
            .map(
              (o) => <String, Object?>{
                'id': o.id,
                'name': o.name,
                'teacher': o.teacher,
                'time': o.time,
                'location': o.location,
                'credit': o.credit,
                'capacity': o.capacity,
                'selected': o.selected,
                'remaining': o.remaining,
                'scopeId': o.scopeId,
                'sections':
                    (sectionsByCourse[o.id] ?? const <CourseSection>[])
                        .map(
                          (sec) => <String, Object?>{
                            'id': sec.id,
                            'courseId': sec.courseId,
                            'name': sec.name,
                            'teacher': sec.teacher,
                            'time': sec.time,
                            'location': sec.location,
                            'capacity': sec.capacity,
                            'selected': sec.selected,
                            'remaining': sec.remaining,
                          },
                        )
                        .toList(),
              },
            )
            .toList(),
      });
    }

    final queryLabel =
        (query != null && query.isNotEmpty) ? ' · 筛选 "$query"' : '';
    final buf = StringBuffer()
      ..writeln('# 课程名单与选课查询 (${term.isEmpty ? "当前学期" : term}$queryLabel)')
      ..writeln()
      ..writeln('## 已选课程名单 N255010 (${enrolledCourses.length} 门)');

    if (enrolledCourses.isEmpty) {
      buf.writeln('暂无已选课程名单记录。');
    } else {
      buf
        ..writeln('| 课程号 | 课程名称 | 教学班/ID | 教师 | 学分 | 上课时间 | 地点 | 状态 |')
        ..writeln('| --- | --- | --- | --- | --- | --- | --- | --- |');
      for (final c in enrolledCourses) {
        final cls = [c.teachingClass, if (c.jxbId.isNotEmpty) '(${c.jxbId})']
            .where((s) => s.isNotEmpty)
            .join(' ');
        buf.writeln(
          '| ${_cell(c.courseCode)} | ${_cell(c.courseName)} | ${_cell(cls)} | ${_cell(c.teacher)} | ${_cell(c.credits)} | ${_cell(c.scheduleText)} | ${_cell(c.location)} | ${_cell(c.selectionStatus)} |',
        );
      }
    }

    buf
      ..writeln()
      ..writeln('## 自主选课可选课程 (${selectableOffers.length} 门)');
    if (!selectionRoundOpen) {
      buf.writeln(
        '> 当前未处于自主选课开放阶段：${selectionClosedMessage.isEmpty ? "ROUND_CLOSED" : selectionClosedMessage}',
      );
    } else if (selectableOffers.isEmpty) {
      buf.writeln('未匹配到可选课程。');
    } else {
      buf
        ..writeln('| 课程号 | 课程名称 | 教学班 ID | 教师 | 学分 | 上课时间 | 余量/容量 |')
        ..writeln('| --- | --- | --- | --- | --- | --- | --- |');
      for (final o in selectableOffers) {
        final secs = sectionsByCourse[o.id] ?? const <CourseSection>[];
        if (secs.isEmpty) {
          final cap = (o.remaining != null && o.capacity != null)
              ? '${o.remaining}/${o.capacity}'
              : o.remainingText;
          buf.writeln(
            '| ${_cell(o.id)} | ${_cell(o.name)} | - | ${_cell(o.teacher)} | ${_cell(o.credit)} | ${_cell(o.time)} | ${_cell(cap)} |',
          );
        } else {
          for (final sec in secs) {
            final cap = (sec.remaining != null && sec.capacity != null)
                ? '${sec.remaining}/${sec.capacity}'
                : sec.remainingText;
            buf.writeln(
              '| ${_cell(o.id)} | ${_cell(o.name)} | ${_cell(sec.id)} | ${_cell(sec.teacher)} | ${_cell(o.credit)} | ${_cell(sec.time)} | ${_cell(cap)} |',
            );
          }
        }
      }
    }
    return buf.toString().trimRight();
  }

  static String formatMutationPreview({
    required bool json,
    required String action,
    required String courseId,
    required String? resolvedClassId,
    required String courseName,
    required String sectionName,
    required String teacher,
    required String time,
    required String location,
    required int? capacity,
    required int? selected,
    required int? remaining,
    required bool alreadySelected,
    required List<CliConflictDetail> conflicts,
    required List<CourseSection> candidateSections,
    required String confirmCommand,
    required String message,
  }) {
    if (json) {
      return encodeJson(<String, Object?>{
        'action': action,
        'confirmed': false,
        'previewOnly': true,
        'status': 'PREVIEW_ONLY',
        'courseId': courseId,
        'classId': resolvedClassId,
        'courseName': courseName,
        'sectionName': sectionName,
        'teacher': teacher,
        'time': time,
        'location': location,
        'capacity': capacity,
        'selected': selected,
        'remaining': remaining,
        'alreadySelected': alreadySelected,
        'conflicts': conflicts.map((c) => c.toJson()).toList(),
        'candidateSections': candidateSections
            .map(
              (s) => <String, Object?>{
                'id': s.id,
                'name': s.name,
                'teacher': s.teacher,
                'time': s.time,
                'location': s.location,
                'capacity': s.capacity,
                'selected': s.selected,
                'remaining': s.remaining,
              },
            )
            .toList(),
        'confirmCommand': confirmCommand,
        'message': message,
      });
    }

    final actionLabel = action == 'select' ? '选课' : '退课';
    final buf = StringBuffer()
      ..writeln('# $actionLabel干跑预检 (PREVIEW ONLY · 零写网络发包)')
      ..writeln('- **目标课程**: ${courseName.isEmpty ? courseId : "$courseName ($courseId)"}')
      ..writeln('- **目标教学班**: ${resolvedClassId ?? "请通过 --class-id 指定"}${sectionName.isNotEmpty ? " ($sectionName)" : ""}')
      ..writeln('- **授课教师**: ${teacher.isEmpty ? "-" : teacher}')
      ..writeln('- **上课时间**: ${time.isEmpty ? "-" : time}')
      ..writeln('- **上课地点**: ${location.isEmpty ? "-" : location}');
    if (capacity != null || remaining != null) {
      buf.writeln('- **名额余量**: ${remaining ?? "-"} / ${capacity ?? "-"}');
    }
    buf.writeln('- **当前已选状态**: ${alreadySelected ? "已在已选列表中" : "尚未选入"}');

    if (conflicts.isEmpty) {
      buf.writeln('- **课表冲突检测**: 无时间冲突');
    } else {
      buf.writeln('- **课表冲突检测**: 发现 ${conflicts.length} 处冲突！');
      for (final c in conflicts) {
        buf.writeln('  - [CONFLICT] ${c.summary}');
      }
    }

    if (candidateSections.length > 1) {
      buf
        ..writeln()
        ..writeln('## 可选教学班列表')
        ..writeln('| 教学班 ID | 班级名称 | 教师 | 时间 | 余量/容量 |')
        ..writeln('| --- | --- | --- | --- | --- |');
      for (final s in candidateSections) {
        final cap = (s.remaining != null && s.capacity != null)
            ? '${s.remaining}/${s.capacity}'
            : s.remainingText;
        buf.writeln(
          '| ${_cell(s.id)} | ${_cell(s.name)} | ${_cell(s.teacher)} | ${_cell(s.time)} | ${_cell(cap)} |',
        );
      }
    }

    buf
      ..writeln()
      ..writeln('> $message')
      ..writeln('> 确认执行命令:')
      ..write('`$confirmCommand`');
    return buf.toString();
  }

  static String formatMutationResult({
    required bool json,
    required bool ok,
    required String action,
    required AcademicStatus status,
    required String courseId,
    required String? classId,
    required String courseName,
    required String verificationState,
    required bool verifiedByReadOnlyCheck,
    required String message,
  }) {
    if (json) {
      return encodeJson(<String, Object?>{
        'ok': ok,
        'action': action,
        'confirmed': true,
        'previewOnly': false,
        'status': status.name,
        'verificationState': verificationState,
        'verifiedByReadOnlyCheck': verifiedByReadOnlyCheck,
        'courseId': courseId,
        'classId': classId,
        'courseName': courseName,
        'message': message,
      });
    }

    final actionLabel = action == 'select' ? '选课' : '退课';
    final buf = StringBuffer()
      ..writeln('# $actionLabel执行结果 (${status.name})')
      ..writeln('- **课程**: ${courseName.isEmpty ? courseId : "$courseName ($courseId)"}')
      ..writeln('- **教学班**: ${classId ?? "-"}')
      ..writeln('- **核验状态**: $verificationState${verifiedByReadOnlyCheck ? " (经只读已选列表核实，零重复发包)" : ""}')
      ..write('- **详情**: $message');
    return buf.toString();
  }

  // ---------------------------------------------------------------------------
  // 有状态 Worker 多网关管理与云端任务/抢课/推送/巡检格式化
  // ---------------------------------------------------------------------------

  static String formatSavedWorkersList({
    required bool json,
    required String storeBackend,
    required String? activeWorkerUrl,
    required List<CliSavedWorkerProfile> workers,
  }) {
    final normalizedActive = (activeWorkerUrl ?? '').trim().toLowerCase();
    if (json) {
      return encodeJson(<String, Object?>{
        'ok': true,
        'store': storeBackend,
        'activeWorkerUrl': activeWorkerUrl,
        'count': workers.length,
        'workers': workers
            .map(
              (w) => w.toPublicJson(
                active: normalizedActive.isNotEmpty &&
                    w.workerUrl.trim().toLowerCase() == normalizedActive,
              ),
            )
            .toList(),
      });
    }

    final buf = StringBuffer()
      ..writeln('# 已保存的有状态 Worker 网关 (${workers.length})')
      ..writeln('- **存储后端**: $storeBackend')
      ..writeln('- **当前激活网关**: ${activeWorkerUrl ?? "(未激活)"}');
    if (workers.isEmpty) {
      buf
        ..writeln()
        ..write('> 尚未保存任何有状态 Worker 网关。运行 `courselens auth worker --url <https://...> --name <alias>` 添加。');
      return buf.toString();
    }
    buf
      ..writeln()
      ..writeln('| 状态 | 别名 | Worker 地址 | 密钥尾号 | 教务账号 | 系统 |')
      ..writeln('| --- | --- | --- | --- | --- | --- |');
    for (final w in workers) {
      final isActive = normalizedActive.isNotEmpty &&
          w.workerUrl.trim().toLowerCase() == normalizedActive;
      buf.writeln(
        '| ${isActive ? "ACTIVE" : "-"} | ${_cell(w.name)} | ${_cell(w.workerUrl)} | ${_cell(w.keyHint)} | ${_cell(w.username ?? "-")} | ${_cell(w.systemType ?? "-")} |',
      );
    }
    return buf.toString().trimRight();
  }

  static String formatCloudTasksList({
    required bool json,
    required String workerUrl,
    required CloudTaskListSnapshot snapshot,
  }) {
    if (json) {
      return encodeJson(<String, Object?>{
        'workerUrl': workerUrl,
        ...snapshot.toJson(),
      });
    }

    final buf = StringBuffer()
      ..writeln('# 云端任务列表 (${snapshot.tasks.length} 项 · 激活 ${snapshot.activeTaskCount} 项)')
      ..writeln('- **Worker 网关**: $workerUrl')
      ..writeln(
        '- **按需懒保活**: ${snapshot.lazyKeepaliveActive ? "已就绪（不受定时任务关闭影响）" : "仅缓存会话模式（可通过 push-cookies 更新）"}',
      )
      ..writeln('- **Webhook 推送**: ${snapshot.webhookConfigured ? "已配置" : "未配置"}')
      ..writeln('- **下次后台唤醒**: ${snapshot.nextAlarmAt ?? "无定时唤醒（零后台开销）"}');

    if (snapshot.tasks.isEmpty) {
      buf
        ..writeln()
        ..write('> 当前没有云端任务。');
      return buf.toString();
    }

    buf
      ..writeln()
      ..writeln('| 任务 ID | 名称 | 类型 | 开关 | 状态 | 周期(秒) | 最近摘要 |')
      ..writeln('| --- | --- | --- | --- | --- | --- | --- |');
    for (final t in snapshot.tasks) {
      buf.writeln(
        '| ${_cell(t.taskId)} | ${_cell(t.title)} | ${_cell(t.type)} | ${t.enabled ? "ON" : "OFF"} | ${_cell(t.status)} | ${t.intervalSec > 0 ? t.intervalSec : "-"} | ${_cell(t.lastSummary)} |',
      );
    }
    buf
      ..writeln()
      ..write('> 查看单个任务详情与日志：`courselens worker tasks show <taskId>`');
    return buf.toString();
  }

  static String formatCloudTaskDetail({
    required bool json,
    required String workerUrl,
    required CloudTaskDetail detail,
    String? heading,
  }) {
    if (json) {
      return encodeJson(<String, Object?>{
        'ok': true,
        'workerUrl': workerUrl,
        ...detail.toJson(),
      });
    }

    final s = detail.summary;
    final m = detail.metrics;
    final buf = StringBuffer()
      ..writeln('# ${heading ?? "云端任务详情"}: ${s.title} (${s.taskId})')
      ..writeln('- **Worker 网关**: $workerUrl')
      ..writeln('- **任务类型**: ${s.type} · **模式**: ${s.mode}')
      ..writeln('- **独立开关**: ${s.enabled ? "ON (已开启)" : "OFF (默认关闭，零后台唤醒)"} · **状态**: ${s.status}')
      ..writeln('- **调度周期**: ${s.intervalSec > 0 ? "${s.intervalSec} 秒" : "-"}')
      ..writeln('- **上次运行**: ${s.lastRunAt ?? "-"} · **下次唤醒**: ${s.nextWakeAt ?? "未计划"}')
      ..writeln('- **运行指标**: 累计 ${m.totalRuns} 次 · 追踪 ${m.trackedItemCount} 项 · 变动 ${m.changeCount} 次${m.lastDurationMs != null ? " · 耗时 ${m.lastDurationMs} ms" : ""}')
      ..writeln('- **最新摘要**: ${s.lastSummary.isEmpty ? "-" : s.lastSummary}');
    if (m.lastError.isNotEmpty) {
      buf.writeln('- **最近错误**: ${m.lastError}');
    }

    if (detail.sessionInfo != null) {
      final si = detail.sessionInfo!;
      buf
        ..writeln()
        ..writeln('## 会话诊断')
        ..writeln('- **已建立 Cookie**: ${si.authenticated ? "是 (${si.cookieCount} 项)" : "否"}')
        ..writeln('- **按需懒保活**: ${si.lazyKeepaliveActive ? "可用（云端已配置账号密码，主动心跳关闭不影响懒重登）" : "未配置云端密码"}')
        ..writeln('- **上次验活**: ${si.lastVerifiedAt ?? "-"}');
    }

    if (detail.recentChanges.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('## 最近检测到的变动 (${detail.recentChanges.length})');
      for (final c in detail.recentChanges) {
        buf.writeln('- **[${c.changeType}]** ${c.summaryLine}');
      }
    }

    if (detail.logs.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('## 最近执行日志 (${detail.logs.length})');
      for (final l in detail.logs) {
        final ts = l.at ?? '-';
        final dur = l.durationMs != null ? ' (${l.durationMs}ms)' : '';
        buf.writeln('- `$ts` **[${l.status}]**$dur ${l.message}');
      }
    }

    return buf.toString().trimRight();
  }

  static String formatWorkerWebhookConfig({
    required bool json,
    required String workerUrl,
    required WorkerWebhookConfig config,
    String heading = '云端 Webhook 推送通知配置',
  }) {
    if (json) {
      return encodeJson(<String, Object?>{
        'ok': true,
        'workerUrl': workerUrl,
        'webhook': config.toJson(),
      });
    }

    final buf = StringBuffer()
      ..writeln('# $heading')
      ..writeln('- **Worker 网关**: $workerUrl')
      ..writeln('- **配置状态**: ${config.configured ? (config.enabled ? "已启用" : "已配置但禁用") : "未配置"}')
      ..writeln('- **推送通道**: ${config.provider} (识别为 ${config.resolvedProvider})')
      ..writeln('- **脱敏地址**: ${config.maskedUrl.isEmpty ? "-" : config.maskedUrl}')
      ..writeln('- **HMAC 签名密钥**: ${config.hasSecret ? "已加密保存" : "未设置"}')
      ..writeln('- **上次发送**: ${config.lastSentAt ?? "-"}');
    if (config.lastError.isNotEmpty) {
      buf.writeln('- **最近错误**: ${config.lastError}');
    }
    return buf.toString().trimRight();
  }

  static String formatWorkerMonitorStatus({
    required bool json,
    required String workerUrl,
    required WorkerMonitorStatus status,
    String heading = '云端成绩与考试巡检状态',
  }) {
    if (json) {
      return encodeJson(<String, Object?>{
        'workerUrl': workerUrl,
        ...status.toJson(),
      });
    }

    String describeItem(String label, WorkerSingleMonitorView item) {
      return '- **$label (${item.taskId})**: ${item.enabled ? "ON (每 ${item.intervalSec}s)" : "OFF (默认关闭，零后台唤醒)"} · 已追踪 ${item.trackedItemCount} 项 · 变动 ${item.changeCount} 次 · ${item.lastSummary}';
    }

    final buf = StringBuffer()
      ..writeln('# $heading')
      ..writeln('- **Worker 网关**: $workerUrl')
      ..writeln(describeItem('出分变动巡检', status.grades))
      ..write(describeItem('考场安排巡检', status.exams));
    return buf.toString();
  }
}
