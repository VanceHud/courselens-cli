import '../../core/courselens_core.dart';

/// 红线 #3：写请求在发出后若因超时、断连或响应截断而无法判定结果，必须归为
/// `RESULT_UNKNOWN`（只读核实、绝不盲目重发）；读请求或尚未发出的写请求才可归为
/// `NETWORK_RETRYABLE`。所有 HTTP 传输引擎统一经由此处分类。
AcademicStatus uncertainWriteStatus({required bool mayHaveCommitted}) =>
    mayHaveCommitted
    ? AcademicStatus.RESULT_UNKNOWN
    : AcademicStatus.NETWORK_RETRYABLE;
