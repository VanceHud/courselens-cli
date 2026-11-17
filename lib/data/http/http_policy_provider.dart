import '../../core/net/transport_policy.dart';

/// 运行时动态向底层传输层提供当前学校白名单与传输安全开关。
class HttpPolicySnapshot {
  const HttpPolicySnapshot({
    this.allowedHosts = const <String>[],
    this.requireSecure = TransportPolicy.requireSecurePolicy,
    this.relayBaseUrl = '',
  });

  final List<String> allowedHosts;
  final bool requireSecure;
  final String relayBaseUrl;
}

typedef HttpPolicyProvider = HttpPolicySnapshot Function();
