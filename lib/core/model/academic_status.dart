/// 教务交互的结果分类。
///
/// 抢课引擎与登录流程的分支行为完全由本枚举驱动。
enum AcademicStatus {
  SUCCESS,

  /// 学校要求图片验证码，需要用户填写。
  CAPTCHA_REQUIRED,

  /// 学校要求人机验证或二次确认（短信/扫码/人脸），客户端无法代劳。
  HUMAN_VERIFICATION_REQUIRED,

  INVALID_CREDENTIALS,

  /// 会话失效，需要重新登录（或尝试续期）。
  SESSION_EXPIRED,

  /// 选课轮次未开放或已关闭。
  ROUND_CLOSED,

  /// 名额已满。
  NO_CAPACITY,

  /// 与已选课程时间冲突。
  CONFLICT,

  ALREADY_SELECTED,

  /// 学校页面结构与适配器预期不符，必须停止自动操作。
  PAGE_CHANGED,

  /// 网络层错误，可重试。
  NETWORK_RETRYABLE,

  /// 请求已发出但无法判定结果，必须查询确认，不可盲目重发。
  RESULT_UNKNOWN,

  /// 该校教务系统不支持该操作。
  UNSUPPORTED,

  /// 目标或重定向落到了未授权的域名，已在校外请求发出前中止。
  UNTRUSTED_URL,

  /// 请求协议不被直连接口接受。
  INSECURE_TRANSPORT,

  /// 安全存储不可用，凭据无法保存或读取。
  STORAGE_UNAVAILABLE,

  VALIDATION_FAILED,

  CREDIT_LIMIT,
}

/// 教务操作的统一受检业务异常。
class AcademicException implements Exception {
  const AcademicException(
    this.status,
    this.message, [
    this.cause,
  ]);

  final AcademicStatus status;
  final String message;
  final Object? cause;

  @override
  String toString() => 'AcademicException(${status.name}: $message)';
}

/// 会话被替换时的取消异常（语义上属于前提已不存在的取消，而非教务业务失败）。
class SessionCancelledException implements Exception {
  const SessionCancelledException([this.message = '会话已被替换']);

  final String message;

  @override
  String toString() => 'SessionCancelledException($message)';
}
