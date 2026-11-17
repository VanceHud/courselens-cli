/// 明文 HTTP 直连的编译期开关（ADR-006）。
class TransportPolicy {
  const TransportPolicy._();

  /// 是否允许明文 HTTP 走直连通道（默认 `true` = 放开）。
  static const bool allowInsecureHttp = true;

  /// [allowInsecureHttp] 的反面（`true` = 必须 HTTPS）。
  static const bool requireSecurePolicy = !allowInsecureHttp;

  static bool requireSecure() => requireSecurePolicy;
}
