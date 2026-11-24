/// 教务系统族。
///
/// [serial] 表示该教务系统只允许同一账号串行发起请求。
enum AcademicSystem {
  /// 新正方（jwglxt / xtgl 路径，CSRF token + 公钥登录）。
  ZF('zf', serial: false),

  /// 旧正方（default2.aspx，ASP.NET ViewState 表单）。
  ZF_OLD('zf_old', serial: true),

  /// 新强智（jsxsd，轮次上下文 + sAjaxSource 脚本）。
  QZ('qz', serial: true),

  /// 旧强智（jsxsd，flag=sess + EncodeInp）。
  QZ_OLD('qz_old', serial: true),

  /// 尚未识别的配置占位；登录页探测前使用。
  AUTO('auto', serial: true);

  const AcademicSystem(this.id, {required this.serial});

  final String id;
  final bool serial;

  static AcademicSystem? fromId(String? id) {
    if (id == null) return null;
    final normalized = id.trim().toLowerCase();
    for (final entry in AcademicSystem.values) {
      if (entry.id == normalized || entry.name.toLowerCase() == normalized) {
        return entry;
      }
    }
    return null;
  }

  /// 解析外部来源（CLI 参数、持久化记录、网关响应）的系统标识；
  /// 缺失或无法识别时统一回落为 [AUTO]，交由探测流程判定。
  static AcademicSystem fromIdOrAuto(String? id) => fromId(id) ?? AUTO;
}
