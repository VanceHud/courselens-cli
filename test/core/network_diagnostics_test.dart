import 'package:courselens/core/courselens_core.dart';
import 'package:test/test.dart';

void main() {
  group('NetworkDiagnostics', () {
    test('classifies DNS lookup and offline errors cleanly without OS noise', () {
      const err = AcademicException(
        AcademicStatus.NETWORK_RETRYABLE,
        "网络连接失败：Failed host lookup: 'jwglxt.qust.edu.cn' (OS Error: No address associated with hostname, errno = 7)",
      );
      expect(NetworkDiagnostics.isNetworkFailure(err), isTrue);
      final diag = NetworkDiagnostics.classify(err);
      expect(diag.kind, equals(NetworkFailureKind.deviceOffline));
      expect(diag.userMessage, contains('校园网 VPN'));
      expect(diag.technicalHint, isNot(contains('OS Error')));
      expect(diag.technicalHint, isNot(contains('NETWORK_RETRYABLE')));
    });

    test('distinguishes Web Relay unreachable from direct upstream timeout', () {
      const relayErr = AcademicException(
        AcademicStatus.NETWORK_RETRYABLE,
        '无法连接无状态中继 http://127.0.0.1:8787：Connection refused',
      );
      final relayDiag =
          NetworkDiagnostics.classify(relayErr, isWebRelay: true);
      expect(relayDiag.kind, equals(NetworkFailureKind.relayUnreachable));
      expect(relayDiag.userMessage, contains('无状态中继'));

      const timeoutErr = AcademicException(
        AcademicStatus.NETWORK_RETRYABLE,
        '请求教务服务器超时，请检查校园网或 VPN 连接',
      );
      final timeoutDiag = NetworkDiagnostics.classify(timeoutErr);
      expect(timeoutDiag.kind, equals(NetworkFailureKind.upstreamTimeout));
    });

    test('distinguishes Worker gateway offline from upstream 502 maintenance', () {
      const workerDown = AcademicException(
        AcademicStatus.NETWORK_RETRYABLE,
        "ClientException with SocketException: Failed host lookup: 'cl.workers.dev' (OS Error: Network is unreachable, errno = 101)",
      );
      final workerDiag =
          NetworkDiagnostics.classify(workerDown, isWorkerMode: true);
      expect(workerDiag.kind, equals(NetworkFailureKind.workerUnreachable));
      expect(workerDiag.userMessage, contains('Worker'));

      const upstream502 = AcademicException(
        AcademicStatus.NETWORK_RETRYABLE,
        '上游教务返回 HTTP 502 Bad Gateway',
      );
      final upstreamDiag =
          NetworkDiagnostics.classify(upstream502, isWorkerMode: true);
      expect(upstreamDiag.kind, equals(NetworkFailureKind.upstreamUnavailable));
      expect(upstreamDiag.userMessage, contains('教务服务器'));
    });

    test('classifies TLS handshake errors and formats cached fallback hint', () {
      const tlsErr = AcademicException(
        AcademicStatus.NETWORK_RETRYABLE,
        'TLS 证书握手失败：CERTIFICATE_VERIFY_FAILED',
      );
      final diag = NetworkDiagnostics.classify(tlsErr);
      expect(diag.kind, equals(NetworkFailureKind.tlsError));
      expect(diag.userMessage, contains('证书'));

      final formatted = NetworkDiagnostics.formatActionFailure(
        '同步课表',
        tlsErr,
        cachedAgeLabel: '5 分钟前更新',
      );
      expect(formatted, contains('同步课表暂未成功'));
      expect(formatted, contains('当前展示 5 分钟前更新 的本地缓存'));
      expect(formatted, isNot(contains('NETWORK_RETRYABLE')));
    });
  });
}
