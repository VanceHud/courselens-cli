import '../parse/urls.dart';

/// 「允许在哪个域名上发请求」的安全白名单判定。
///
/// 五条规则：
/// 1. 协议只认 `http`/`https`；
/// 2. 不允许 `userinfo`（防 `https://jw.example.edu.cn@evil.com/` 钓鱼）；
/// 3. `requireSecure` 为真时不许降级到 `http`；
/// 4. 端口必须一致；
/// 5. 主机必须完全相等，不做子域通配。
class HostPolicy {
  const HostPolicy._();

  static const Set<String> _transportSchemes = {'http', 'https'};

  static bool isAllowed(
    String value,
    Iterable<String> hosts,
    bool requireSecure,
  ) {
    final target = Urls.parseUrl(value);
    if (target == null) return false;
    final scheme = target.scheme.toLowerCase();
    if (!_transportSchemes.contains(scheme)) return false;
    if (target.userInfo != null) return false;
    if (requireSecure && scheme != 'https') return false;

    for (final configured in hosts) {
      if (_pointsAtSameHostAndPort(target, configured, scheme)) {
        return true;
      }
    }
    return false;
  }

  static bool _pointsAtSameHostAndPort(
    ParsedUrl target,
    String configured,
    String targetScheme,
  ) {
    final trimmed = configured.trim();
    if (trimmed.isEmpty || trimmed.contains('*') || trimmed.contains('@')) {
      return false;
    }
    final hasExplicitScheme = trimmed.contains('://');
    final expanded = hasExplicitScheme ? trimmed : '$targetScheme://$trimmed';
    final single = Urls.parseUrl(expanded);
    if (single == null || single.userInfo != null || single.host.isEmpty) {
      return false;
    }
    final singleScheme = single.scheme.toLowerCase();
    if (!_transportSchemes.contains(singleScheme)) return false;
    if (hasExplicitScheme &&
        singleScheme == 'https' &&
        targetScheme != 'https') {
      return false;
    }
    return single.host == target.host && single.port == target.port;
  }
}
