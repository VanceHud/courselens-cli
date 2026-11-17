import '../model/academic_system.dart';

/// 登录页 HTML -> 教务系统族特征识别。
class SystemDetector {
  const SystemDetector._();

  static bool _isLegacyZhengfang(String page) =>
      page.contains('default2.aspx') &&
      (page.contains('txtkeymodulus') || page.contains('checkcode'));

  static bool _isNativeZhengfang(String page) =>
      page.contains('login_getpublickey') ||
      (page.contains('csrftoken') && page.contains('xtgl'));

  static bool _isModernQingzhi(String page) =>
      page.contains('var scode') &&
      page.contains('var sxh') &&
      page.contains('logintoxk');

  static bool _isLegacyQingzhi(String page) =>
      page.contains('flag=sess') ||
      (page.contains('encodeinp') && page.contains('%%%'));

  static AcademicSystem? classify(String html) {
    final page = html.toLowerCase();
    if (_isLegacyZhengfang(page)) return AcademicSystem.ZF_OLD;
    if (_isNativeZhengfang(page)) return AcademicSystem.ZF;
    if (_isModernQingzhi(page)) return AcademicSystem.QZ;
    if (_isLegacyQingzhi(page)) return AcademicSystem.QZ_OLD;
    return null;
  }
}
