import 'html.dart';

/// 判定页面是否具有「登录后」特征（供内嵌浏览器会话接管使用）。
class AuthenticatedPage {
  const AuthenticatedPage._();

  static const List<String> _signs = [
    '欢迎您',
    '退出',
    '注销',
    'xsxxwh',
    'index_initMenu',
    'sessionUserKey',
    'xs_main.aspx',
    'xsMain',
    'xklc_list',
    'jx0502zbid',
    '学期理论课表',
    '选课结果',
    '个人课表',
    '我的课表',
    '学生选课',
  ];

  static bool looksAuthenticated(String html) {
    if (Html.isLoginPage(html)) return false;
    final lower = html.toLowerCase();
    return _signs.any((sign) => lower.contains(sign.toLowerCase()));
  }
}
