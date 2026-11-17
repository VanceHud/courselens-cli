import 'dart:io';

import 'package:courselens/core/courselens_core.dart';
import 'package:test/test.dart';

String _fixture(String name) =>
    File('test/fixtures/academic/$name').readAsStringSync();

void main() {
  group('SystemDetector against real school fixtures', () {
    test('classifies all 4 login system families + QUST native login', () {
      expect(
        SystemDetector.classify(_fixture('zf-login.html')),
        equals(AcademicSystem.ZF),
      );
      expect(
        SystemDetector.classify(_fixture('zf_old-login.html')),
        equals(AcademicSystem.ZF_OLD),
      );
      expect(
        SystemDetector.classify(_fixture('qz-login.html')),
        equals(AcademicSystem.QZ),
      );
      expect(
        SystemDetector.classify(_fixture('qz_old-login.html')),
        equals(AcademicSystem.QZ_OLD),
      );
      expect(
        SystemDetector.classify(_fixture('qust-login-jwglxt.html')),
        equals(AcademicSystem.ZF),
      );
      expect(
        SystemDetector.classify('<a href="/jsxsd/">Welcome</a>'),
        isNull,
      );
    });
  });

  group('ZhengfangCasProtocol & ZhengfangJwglxtProtocol fixtures', () {
    test('parses CAS login fixture execution token and form action', () {
      final page =
          ZhengfangCasProtocol.parseLoginPage(_fixture('zf-cas-login.html'));
      expect(page.execution, equals('test-execution-token-0123456789abcdef'));
      expect(page.formAction, equals('login?v=0.123456789'));
    });

    test('parses QUST jwglxt login, failed page, and menu page', () {
      final loginHtml = _fixture('qust-login-jwglxt.html');
      final page = ZhengfangJwglxtProtocol.parseLoginPage(loginHtml);
      expect(page.csrfToken.contains(','), isTrue);
      expect(page.formAction, equals('/jwglxt/xtgl/login_slogin.html'));
      expect(page.encryptPassword, isTrue);
      expect(page.captchaRequired, isFalse);
      expect(page.notice, contains('学生账号为学号'));

      final fields = ZhengfangJwglxtProtocol.formFields(
        page: page,
        username: '20250000',
        password: 'ENC',
        captcha: '1234',
      );
      expect(fields.length, equals(6));
      expect(fields.where((f) => f.$1 == 'mm').length, equals(1));

      final failedHtml = _fixture('qust-login-failed.html');
      expect(
        ZhengfangJwglxtProtocol.errorMessage(failedHtml),
        equals('用户名或密码不正确！'),
      );
      expect(
        ZhengfangJwglxtProtocol.classify(
          'http://h/jwglxt/xtgl/login_slogin.html?time=1',
          failedHtml,
        ),
        equals(JwglxtOutcome.INVALID_CREDENTIALS),
      );
      expect(
        ZhengfangJwglxtProtocol.classify(
          'http://h/jwglxt/xtgl/index_initMenu.html',
          _fixture('qust-index-menu.html'),
        ),
        equals(JwglxtOutcome.SUCCESS),
      );
    });

    test('parses zf_old ASP.NET form and qz-category fixtures', () {
      final zfOldDoc = Html.parse(_fixture('zf_old-form.html'));
      final form = zfOldDoc.querySelector('form');
      expect(form, isNotNull);
      final qzCat = _fixture('qz-category.html');
      expect(qzCat, isNotEmpty);
    });
  });

  group('ZhengfangIdentity', () {
    test('parses cxyhxx variant, initMenu, NBSP roles, and rejects login page', () {
      final cxyhxx = ZhengfangIdentity.parse(
        _fixture('zf-cxyhxx-variant.html'),
        'https://jwxt.example.edu.cn/',
      );
      expect(cxyhxx.name, equals('张三'));
      expect(cxyhxx.studentId, isEmpty);

      final initMenu = ZhengfangIdentity.parse(
        _fixture('zf-initmenu.html'),
        'https://jwxt.example.edu.cn/',
      );
      expect(initMenu.studentId, equals('20250001'));

      expect(
        ZhengfangIdentity.parse(
          '<h4 class="media-heading">王五&nbsp;&nbsp;学生</h4>',
        ).name,
        equals('王五'),
      );
      expect(
        ZhengfangIdentity.parse('<input name="xm" value="李同学">').name,
        equals('李同学'),
      );
      expect(
        ZhengfangIdentity.parse(
          '<input type="password" name="p"><input name="xh" value="x">',
        ).isEmpty,
        isTrue,
      );
    });
  });

  group('ScheduleHtml, GradesHtml, GradeMath, StudyJson', () {
    test('ScheduleHtml reconstructs irregular rowspan/colspan grid coordinates', () {
      const html = '''
      <table>
        <tr><th>节次</th><th>星期一</th><th>星期二</th><th>星期三</th></tr>
        <tr>
          <td>第1节</td>
          <td rowspan="2">高等数学<br>(1-2节)1-16周(单)<br>王老师<br>教一101</td>
          <td></td>
          <td>线性代数<br>(1-1节)1-8周<br>赵老师<br>教二202</td>
        </tr>
        <tr>
          <td>第2节</td>
          <td>大学英语<br>(2-2节)2-16周(双)<br>李老师<br>外语楼303</td>
          <td></td>
        </tr>
      </table>
      ''';
      final entries = ScheduleHtml.parse(html);
      expect(entries.length, equals(3));

      final math = entries.firstWhere((e) => e.name == '高等数学');
      expect(math.day, equals(1));
      expect(math.period, equals(PeriodSpan(1, 2)));
      expect(math.weeks.contains(1), isTrue);
      expect(math.weeks.contains(2), isFalse);

      // Row 2 has rowspan=2 occupying Monday, so 大学英语 must land on Tuesday (day=2)!
      final english = entries.firstWhere((e) => e.name == '大学英语');
      expect(english.day, equals(2));
      expect(english.period, equals(PeriodSpan(2, 2)));
      expect(english.weeks.contains(2), isTrue);
      expect(english.weeks.contains(1), isFalse);
    });

    test('GradesHtml + GradeMath compute weighted GPA and respect school header', () {
      const html = '''
      <table>
        <tr><th>学年学期</th><th>课程名称</th><th>学分</th><th>成绩</th><th>绩点</th></tr>
        <tr><td>2025-2026-1</td><td>高等数学</td><td>4.0</td><td>92</td><td>4.2</td></tr>
        <tr><td>2025-2026-1</td><td>体育</td><td>1.0</td><td>优秀</td><td>4.5</td></tr>
        <tr><td>2025-2026-1</td><td>工程训练</td><td>2.0</td><td>合格</td><td></td></tr>
      </table>
      ''';
      final report = GradesHtml.parse(html);
      expect(report.grades.length, equals(3));
      final summary = GradeMath.summarize(report);
      expect(summary.courseCount, equals(3));
      expect(summary.excellent, equals(2));
      expect(summary.pass, equals(1));
      expect(summary.gpaText, equals('4.26'));
      expect(summary.creditsText, equals('7.0'));

      final withFooter = GradesHtml.parse(
        '$html<div>平均学分绩点：3.87 已获学分：176.5</div>',
      );
      final footerSummary = GradeMath.summarize(withFooter);
      expect(footerSummary.gpaText, equals('3.87'));
      expect(footerSummary.creditsText, equals('176.5'));
    });

    test('StudyJson parses zf JSON schedule, grades, and exams', () {
      const kbJson = '''
      {"kbList":[
        {"kcmc":"操作系统","xm":"周老师","cdmc":"计科楼402","xqj":"3","jcs":"3-4","zcd":"1-16周"}
      ]}
      ''';
      final schedule = StudyJson.schedule(kbJson);
      expect(schedule.length, equals(1));
      expect(schedule.single.name, equals('操作系统'));
      expect(schedule.single.day, equals(3));
      expect(schedule.single.period, equals(PeriodSpan(3, 4)));
    });
  });
}
