import '../core/courselens_core.dart';

/// 内嵌脱敏演示夹具与沙盒数据。
///
/// 使得 `dart compile exe tools/courselens_cli.dart` 编译出的独立二进制文件
/// 在任意工作目录下运行 `--demo` 时均无需读取仓库 `assets/fixtures/demo.fixtures.json`。
class CliDemoFixtures {
  const CliDemoFixtures._();

  static const String demoSchoolId = 'demo';
  static const String demoSchoolName = '演示高校';
  static const String demoAccountKey = '20250000';
  static const String demoCasBase = 'https://cas.demo-school.example.edu.cn';
  static const String demoAcademicBase =
      'https://jw.demo-school.example.edu.cn/jsxsd';
  static const String demoDefaultTerm = '2025-2026-1';

  /// 与 `assets/fixtures/demo.fixtures.json` 保持 100% 等价的 HTTP 回放夹具载荷。
  static const String demoFixturesJson = r'''
[
  {
    "url": "https://cas.demo-school.example.edu.cn/cas/login",
    "method": "GET",
    "status": 200,
    "headers": {
      "Content-Type": [
        "text/html; charset=UTF-8"
      ],
      "Set-Cookie": [
        "JSESSIONID=demo-session; Path=/cas; Secure; HttpOnly"
      ]
    },
    "body": "<!-- 正方定制 CAS 登录页的最小形态。\n     要点：真正的口令框是隐藏的 `#password`（可见的 `#ppassword` 只是给人看的），\n     提交还要带上 execution 令牌与 _eventId；表单地址自带一个版本号查询参数。 -->\n<!DOCTYPE html>\n<html lang=\"zh-CN\">\n  <head>\n    <meta charset=\"utf-8\" />\n    <title>统一身份认证平台</title>\n  </head>\n  <body id=\"login_new\">\n    <div class=\"login-page\">\n      <div class=\"login-container\">\n        <div class=\"login-form\" id=\"qcode\">\n          <form id=\"fm1\" method=\"post\" action=\"login?v=0.123456789 \">\n            <input name=\"username\" id=\"username\" type=\"text\" class=\"form-control\" autocomplete=\"off\" value=\"\" />\n            <input id=\"ppassword\" type=\"password\" class=\"form-control\" autocomplete=\"off\" value=\"\" />\n            <input name=\"password\" id=\"password\" type=\"password\" style=\"display: none;\" value=\"\" />\n            <input name=\"authcode\" id=\"authcode\" type=\"text\" class=\"form-control\" value=\"\" />\n            <input name=\"execution\" type=\"hidden\" value=\"test-execution-token-0123456789abcdef\" />\n            <input name=\"_eventId\" type=\"hidden\" value=\"submit\" />\n            <p id=\"errormsg\" class=\"error text-left\"></p>\n          </form>\n        </div>\n      </div>\n    </div>\n  </body>\n</html>\n"
  },
  {
    "url": "https://cas.demo-school.example.edu.cn/cas/login?service=https%3A%2F%2Fjw.demo-school.example.edu.cn%2Fjsxsd",
    "method": "GET",
    "status": 200,
    "headers": {
      "Content-Type": [
        "text/html; charset=UTF-8"
      ],
      "Set-Cookie": [
        "JSESSIONID=demo-session; Path=/cas; Secure; HttpOnly"
      ]
    },
    "body": "<!-- 正方定制 CAS 登录页的最小形态。\n     要点：真正的口令框是隐藏的 `#password`（可见的 `#ppassword` 只是给人看的），\n     提交还要带上 execution 令牌与 _eventId；表单地址自带一个版本号查询参数。 -->\n<!DOCTYPE html>\n<html lang=\"zh-CN\">\n  <head>\n    <meta charset=\"utf-8\" />\n    <title>统一身份认证平台</title>\n  </head>\n  <body id=\"login_new\">\n    <div class=\"login-page\">\n      <div class=\"login-container\">\n        <div class=\"login-form\" id=\"qcode\">\n          <form id=\"fm1\" method=\"post\" action=\"login?v=0.123456789 \">\n            <input name=\"username\" id=\"username\" type=\"text\" class=\"form-control\" autocomplete=\"off\" value=\"\" />\n            <input id=\"ppassword\" type=\"password\" class=\"form-control\" autocomplete=\"off\" value=\"\" />\n            <input name=\"password\" id=\"password\" type=\"password\" style=\"display: none;\" value=\"\" />\n            <input name=\"authcode\" id=\"authcode\" type=\"text\" class=\"form-control\" value=\"\" />\n            <input name=\"execution\" type=\"hidden\" value=\"test-execution-token-0123456789abcdef\" />\n            <input name=\"_eventId\" type=\"hidden\" value=\"submit\" />\n            <p id=\"errormsg\" class=\"error text-left\"></p>\n          </form>\n        </div>\n      </div>\n    </div>\n  </body>\n</html>\n"
  },
  {
    "url": "https://cas.demo-school.example.edu.cn/cas/v2/getPubKey",
    "method": "GET",
    "status": 200,
    "headers": {
      "Content-Type": [
        "application/json"
      ]
    },
    "body": "{\"modulus\": \"b1d2af160ebaa47adfef6e4f98a6f1045bd6dc5bfba4bf427c9a653307424d955bf9bbe79a6f5444b7bb04dc8fd4d4c36063d67fbab5c6732b6a2ed6bbf6f45d\", \"exponent\": \"10001\"}"
  },
  {
    "url": "https://cas.demo-school.example.edu.cn/cas/v2/getKaptchaStatus",
    "method": "GET",
    "status": 200,
    "headers": {
      "Content-Type": [
        "text/plain"
      ]
    },
    "body": "false"
  },
  {
    "url": "https://cas.demo-school.example.edu.cn/cas/login?v=0.123456789",
    "method": "POST",
    "status": 302,
    "headers": {
      "Location": [
        "https://cas.demo-school.example.edu.cn/cas/login?service=https%3A%2F%2Fjw.demo-school.example.edu.cn%2Fjsxsd"
      ],
      "Set-Cookie": [
        "iPlanetDirectoryPro=SSO; Path=/; Secure"
      ]
    }
  },
  {
    "url": "https://cas.demo-school.example.edu.cn/cas/login?service=https%3A%2F%2Fjw.demo-school.example.edu.cn%2Fjsxsd",
    "method": "GET",
    "status": 302,
    "headers": {
      "Location": [
        "https://jw.demo-school.example.edu.cn/jsxsd"
      ]
    }
  },
  {
    "url": "https://jw.demo-school.example.edu.cn/jsxsd",
    "method": "GET",
    "status": 200,
    "headers": {
      "Content-Type": [
        "text/html; charset=UTF-8"
      ],
      "Set-Cookie": [
        "JSESSIONID=academic; Path=/jsxsd; Secure"
      ]
    },
    "body": "<input name=\"xh\" value=\"20250000\"><input name=\"xm\" value=\"演示同学\">"
  },
  {
    "url": "https://jw.demo-school.example.edu.cn/jsxsd/xskbcx",
    "method": "GET",
    "status": 200,
    "headers": {
      "Content-Type": [
        "text/html; charset=UTF-8"
      ]
    },
    "body": "<table>\n  <tr><th>节次</th><th>星期一</th><th>星期二</th><th>星期三</th><th>星期四</th><th>星期五</th></tr>\n  <tr><td>1-2</td>\n      <td>高等数学<br>周一第1-2节{第1-16周}<br>王老师<br>教一101</td>\n      <td>大学物理<br>周二第1-2节{第1-16周(单)}<br>李老师<br>教二202</td>\n      <td></td><td></td><td></td></tr>\n  <tr><td>3-4</td>\n      <td></td>\n      <td></td>\n      <td>程序设计<br>周三第3-4节{第1-8周}<br>张老师<br>机房301</td>\n      <td>大学英语<br>周四第3-4节{第1-16周}<br>赵老师<br>教三105</td>\n      <td></td></tr>\n  <tr><td>5-6</td>\n      <td></td><td></td><td></td>\n      <td>体育<br>周四第5-6节{第1-16周(双)}<br>孙老师<br>体育馆</td>\n      <td></td></tr>\n</table>"
  },
  {
    "url": "https://jw.demo-school.example.edu.cn/jsxsd/cjcx",
    "method": "GET",
    "status": 200,
    "headers": {
      "Content-Type": [
        "text/html; charset=UTF-8"
      ]
    },
    "body": "<table>\n  <tr><th>课程名称</th><th>学分</th><th>成绩</th><th>绩点</th><th>学年学期</th></tr>\n  <tr><td>高等数学</td><td>5.0</td><td>92</td><td>4.2</td><td>2025-2026-1</td></tr>\n  <tr><td>大学物理</td><td>3.5</td><td>85</td><td>3.5</td><td>2025-2026-1</td></tr>\n  <tr><td>程序设计</td><td>4.0</td><td>78</td><td>2.8</td><td>2025-2026-1</td></tr>\n  <tr><td>大学英语</td><td>3.0</td><td>优秀</td><td>4.5</td><td>2025-2026-1</td></tr>\n  <tr><td>体育</td><td>1.0</td><td>合格</td><td>3.0</td><td>2025-2026-1</td></tr>\n</table>\n<div>平均学分绩点：3.66 已获学分：16.5</div>"
  },
  {
    "url": "https://jw.demo-school.example.edu.cn/jsxsd/xskscx",
    "method": "GET",
    "status": 200,
    "headers": {
      "Content-Type": [
        "text/html; charset=UTF-8"
      ]
    },
    "body": "<table>\n  <tr><th>课程名称</th><th>考试场次</th><th>考试时间</th><th>考试校区</th><th>考场</th><th>座位号</th><th>授课教师</th></tr>\n  <tr><td>高等数学</td><td>期末考试</td><td>2026-01-05 09:00-11:00</td><td>主校区</td><td>教一101</td><td>12</td><td>王老师</td></tr>\n  <tr><td>程序设计</td><td>期末考试</td><td>2026-01-07 14:00-16:00</td><td>主校区</td><td>机房301</td><td>7</td><td>张老师</td></tr>\n</table>"
  }
]
''';

  static const StudentIdentity fallbackIdentity = StudentIdentity(
    name: '演示同学',
    studentId: demoAccountKey,
    department: '信息科学技术学院',
    major: '计算机科学与技术',
    className: '计科241',
    grade: '2024',
  );

  static const List<PracticalCourse> practicalCourses = <PracticalCourse>[
    PracticalCourse(
      name: '软件工程综合课程设计',
      courseCode: 'SE390',
      teacher: '林峰副教授',
      credits: '2.0',
      weeksText: '第17-18周',
      category: '集中实践环节',
      assessment: '考查',
      summary: '软件工程综合课程设计(林峰副教授) 第17-18周 集中上机验收',
    ),
  ];

  static const List<EnrolledCourseEntry> enrolledCourses =
      <EnrolledCourseEntry>[
    EnrolledCourseEntry(
      courseCode: 'CS301',
      courseName: '编译原理与实践',
      teachingClass: '编译原理01班',
      jxbId: 'CS301-01',
      teacher: '周维教授',
      credits: '3.5',
      scheduleText: '星期二第3-4节{1-16周}',
      location: '信息楼305',
      category: '专业核心课',
      selectionStatus: '已选',
      termId: '2025-2026-2',
    ),
    EnrolledCourseEntry(
      courseCode: 'SE390',
      courseName: '软件工程综合课程设计',
      teachingClass: '软工实践01班',
      jxbId: 'SE390-01',
      teacher: '林峰副教授',
      credits: '2.0',
      scheduleText: '集中实践（第17-18周）',
      location: '智算中心',
      category: '集中实践环节',
      selectionStatus: '置课',
      termId: '2025-2026-2',
    ),
  ];

  static final AcademicProgressReport academicProgress = AcademicProgressReport(
    officialGpa: '3.66',
    totalCourses: 42,
    passedCourses: 24,
    inProgressCourses: 6,
    unstudiedCourses: 12,
    failedCourses: 0,
    outsidePlanPassedCourses: 2,
    studentId: demoAccountKey,
    categories: const <CreditCategoryNode>[
      CreditCategoryNode(
        id: 'demo-major',
        name: '主修培养方案总学分',
        earnedCredits: 98.5,
        requiredCredits: 165.0,
        remainingCredits: 66.5,
      ),
      CreditCategoryNode(
        id: 'demo-compulsory',
        parentId: 'demo-major',
        name: '专业必修课',
        isLeaf: true,
        earnedCredits: 64.0,
        requiredCredits: 90.0,
        remainingCredits: 26.0,
      ),
      CreditCategoryNode(
        id: 'demo-elective',
        parentId: 'demo-major',
        name: '专业选修课',
        isLeaf: true,
        earnedCredits: 18.5,
        requiredCredits: 24.0,
        remainingCredits: 5.5,
      ),
      CreditCategoryNode(
        id: 'demo-ge',
        parentId: 'demo-major',
        name: '通识选修模块',
        isLeaf: true,
        earnedCredits: 16.0,
        requiredCredits: 16.0,
        remainingCredits: 0.0,
        passed: true,
      ),
    ],
  );

  static const Map<String, List<PlanCourseEntry>> planCoursesByCategory =
      <String, List<PlanCourseEntry>>{
    'demo-compulsory': <PlanCourseEntry>[
      PlanCourseEntry(
        courseCode: 'CS201',
        courseName: '数据结构与算法',
        credits: '4.0',
        category: '专业必修课',
        status: PlanCourseStatus.passed,
        recommendedTerm: '2025-2026-1',
        maxScore: '93',
        score: '93',
        gpa: '4.00',
      ),
      PlanCourseEntry(
        courseCode: 'CS301',
        courseName: '编译原理与实践',
        credits: '3.5',
        category: '专业必修课',
        status: PlanCourseStatus.inProgress,
        recommendedTerm: '2025-2026-2',
      ),
      PlanCourseEntry(
        courseCode: 'CS401',
        courseName: '分布式系统原理',
        credits: '3.0',
        category: '专业必修课',
        status: PlanCourseStatus.unstudied,
        recommendedTerm: '2026-2027-1',
      ),
    ],
    'demo-elective': <PlanCourseEntry>[
      PlanCourseEntry(
        courseCode: 'AI402',
        courseName: '深度学习与大模型系统',
        credits: '3.0',
        category: '专业选修课',
        status: PlanCourseStatus.unstudied,
        recommendedTerm: '2026-2027-1',
      ),
    ],
    'demo-ge': <PlanCourseEntry>[
      PlanCourseEntry(
        courseCode: 'GE108',
        courseName: '音乐审美与数字声学',
        credits: '2.0',
        category: '通识选修课',
        status: PlanCourseStatus.passed,
        recommendedTerm: '2025-2026-1',
        maxScore: '91',
        score: '91',
        gpa: '4.00',
      ),
    ],
  };

  static const List<EmptyClassroom> emptyClassrooms = <EmptyClassroom>[
    EmptyClassroom(
      id: 'r-101',
      code: 'QF-103',
      name: '群芳楼103',
      building: '群芳楼',
      type: '多媒体教室',
      seats: 120,
      examSeats: 60,
      campus: '四方校区',
    ),
    EmptyClassroom(
      id: 'r-202',
      code: 'HG-305',
      name: '弘毅楼B305',
      building: '弘毅楼',
      type: '多媒体教室',
      seats: 90,
      examSeats: 45,
      campus: '崂山校区',
    ),
    EmptyClassroom(
      id: 'r-303',
      code: 'ZX-201',
      name: '东苑自习室201',
      building: '东苑教学楼',
      type: '考研自习室',
      seats: 160,
      examSeats: 80,
      campus: '四方校区',
    ),
  ];

  static const List<CourseScope> courseScopes = <CourseScope>[
    CourseScope(id: 'demo-core', name: '主修/专业选修（演示沙盒）', term: '2025-2026-2'),
    CourseScope(id: 'demo-ge', name: '通识选修课（演示沙盒）', term: '2025-2026-2'),
  ];

  static const List<CourseOffer> courseOffers = <CourseOffer>[
    CourseOffer(
      id: 'CS301',
      name: '编译原理与实践',
      teacher: '周维教授 / 林峰副教授',
      time: '星期二第3-4节',
      location: '信息楼305',
      credit: '3.5',
      capacity: 60,
      selected: 52,
      scopeId: 'demo-core',
    ),
    CourseOffer(
      id: 'AI402',
      name: '深度学习与大模型系统',
      teacher: '沈思远教授',
      time: '星期四第5-6节',
      location: '智算中心201',
      credit: '3.0',
      capacity: 80,
      selected: 80,
      scopeId: 'demo-core',
    ),
    CourseOffer(
      id: 'GE108',
      name: '音乐审美与数字声学',
      teacher: '苏晴老师',
      time: '星期五第7-8节',
      location: '艺术楼102',
      credit: '2.0',
      capacity: 120,
      selected: 96,
      scopeId: 'demo-ge',
    ),
  ];

  static const Map<String, List<CourseSection>> sectionsByCourse =
      <String, List<CourseSection>>{
    'CS301': <CourseSection>[
      CourseSection(
        id: 'CS301-01',
        courseId: 'CS301',
        name: '编译原理01班',
        teacher: '周维教授',
        time: '星期二第3-4节{1-16周}',
        location: '信息楼305',
        capacity: 60,
        selected: 52,
      ),
      CourseSection(
        id: 'CS301-02',
        courseId: 'CS301',
        name: '编译原理02班',
        teacher: '林峰副教授',
        time: '星期三第1-2节{1-16周}',
        location: '信息楼308',
        capacity: 60,
        selected: 60,
      ),
    ],
    'AI402': <CourseSection>[
      CourseSection(
        id: 'AI402-01',
        courseId: 'AI402',
        name: '大模型系统实验班',
        teacher: '沈思远教授',
        time: '星期四第5-6节{1-16周}',
        location: '智算中心201',
        capacity: 80,
        selected: 80,
      ),
    ],
    'GE108': <CourseSection>[
      CourseSection(
        id: 'GE108-01',
        courseId: 'GE108',
        name: '通识晚间班',
        teacher: '苏晴老师',
        time: '星期五第7-8节{2-16周(双)}',
        location: '艺术楼102',
        capacity: 120,
        selected: 96,
      ),
    ],
  };

  static const List<SelectedCourse> initialSelectedCourses = <SelectedCourse>[
    SelectedCourse(
      id: 'sel-1',
      courseId: 'CS301',
      sectionId: 'CS301-01',
      name: '编译原理与实践',
      teacher: '周维教授',
      time: '星期二第3-4节{1-16周}',
      location: '信息楼305',
    ),
  ];

  /// 启动全链路离线演示回放：真正经过 `FixtureHttpEngine`、`ZhengfangCasLoginFlow`、
  /// `ScheduleHtml`、`GradesHtml`、`GradeMath` 与 `StudyHtml` 解析。
  static Future<CliDemoSnapshot> bootstrap({
    required int Function() clock,
  }) async {
    final engine = GuardedHttpEngine(
      FixtureHttpEngine.fromJson(demoFixturesJson),
      requireSecure: true,
    );
    final client = AcademicClient(
      engine: engine,
      decoder: const CharsetTextDecoder(),
      secureStore: InMemorySecureStore(),
      clock: clock,
      random: SystemSecureRandom(),
    );

    final login = await client.loginCas(
      schoolId: demoSchoolId,
      accountKey: demoAccountKey,
      username: demoAccountKey,
      password: 'demo-password',
      casBaseUrl: demoCasBase,
      academicBaseUrl: demoAcademicBase,
    );
    final identity = login.identity.merge(fallbackIdentity);

    final entries = await client.loadSchedule(
      schoolId: demoSchoolId,
      accountKey: demoAccountKey,
      path: 'xskbcx',
    );
    final schedule = Schedule(
      entries: entries,
      practicalCourses: practicalCourses,
      studentInfo: identity,
      termId: '2025-2026-2',
    );
    final gradeReport = await client.loadGrades(
      schoolId: demoSchoolId,
      accountKey: demoAccountKey,
      path: 'cjcx',
    );
    final gradeSummary = client.summarize(gradeReport);
    final exams = await client.loadExams(
      schoolId: demoSchoolId,
      accountKey: demoAccountKey,
      path: 'xskscx',
    );

    return CliDemoSnapshot(
      client: client,
      identity: identity,
      schedule: schedule,
      gradeReport: gradeReport,
      gradeSummary: gradeSummary,
      exams: exams,
      selectedCourses: List<SelectedCourse>.from(initialSelectedCourses),
    );
  }
}

/// 一次演示模式运行期的内存数据快照。
class CliDemoSnapshot {
  CliDemoSnapshot({
    required this.client,
    required this.identity,
    required this.schedule,
    required this.gradeReport,
    required this.gradeSummary,
    required this.exams,
    required this.selectedCourses,
  });

  final AcademicClient client;
  final StudentIdentity identity;
  final Schedule schedule;
  final GradeReport gradeReport;
  final GradeSummary gradeSummary;
  final List<ExamEntry> exams;
  final List<SelectedCourse> selectedCourses;
}
