import 'dart:convert';

import 'package:courselens/core/courselens_core.dart';
import 'dart:typed_data';

import 'package:courselens/data/http/gateway_response_decoder.dart';
import 'package:courselens/data/http/http_policy_provider.dart';
import 'package:courselens/data/http/relay_http_engine.dart';
import 'package:courselens/data/http/uncertain_write.dart';
import 'package:courselens/data/http/worker_session_http_engine.dart';
import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const decoder = GatewayResponseDecoder(
    unexpectedResponsePrefix: '测试网关返回了非预期响应',
    requestFailedPrefix: '测试网关请求失败',
  );

  Matcher throwsStatus(AcademicStatus status) => throwsA(
    isA<AcademicException>().having((e) => e.status, 'status', status),
  );

  http.Response json(Object payload, int status) =>
      http.Response.bytes(utf8.encode(jsonEncode(payload)), status);

  group('uncertainWriteStatus', () {
    test(
      'maps possibly committed writes to RESULT_UNKNOWN, others to NETWORK_RETRYABLE',
      () {
        expect(
          uncertainWriteStatus(mayHaveCommitted: true),
          AcademicStatus.RESULT_UNKNOWN,
        );
        expect(
          uncertainWriteStatus(mayHaveCommitted: false),
          AcademicStatus.NETWORK_RETRYABLE,
        );
      },
    );
  });

  group('GatewayResponseDecoder', () {
    test('decodeOrThrow returns the JSON object for 2xx responses', () {
      final decoded = decoder.decodeOrThrow(
        json(<String, Object?>{'ok': true, 'status': 200}, 200),
        mayHaveCommitted: true,
      );
      expect(decoded['status'], 200);
    });

    test(
      'non-JSON bodies are RESULT_UNKNOWN only for writes that may have reached upstream',
      () {
        final truncated = http.Response('{"ok":tr', 200);
        final badGateway = http.Response('<html>502</html>', 502);
        final edgeRejected = http.Response('<html>413</html>', 413);

        expect(
          () => decoder.decodeOrThrow(truncated, mayHaveCommitted: true),
          throwsStatus(AcademicStatus.RESULT_UNKNOWN),
        );
        expect(
          () => decoder.decodeOrThrow(badGateway, mayHaveCommitted: true),
          throwsStatus(AcademicStatus.RESULT_UNKNOWN),
        );
        expect(
          () => decoder.decodeOrThrow(edgeRejected, mayHaveCommitted: true),
          throwsStatus(AcademicStatus.NETWORK_RETRYABLE),
        );
        expect(
          () => decoder.decodeOrThrow(badGateway, mayHaveCommitted: false),
          throwsStatus(AcademicStatus.NETWORK_RETRYABLE),
        );
      },
    );

    test('maps gateway error codes and falls back to the HTTP status', () {
      AcademicStatus statusOf(Map<String, Object?> body, int httpStatus) =>
          decoder.mapError(httpStatus, body).status;

      expect(
        statusOf(<String, Object?>{'status': 'SESSION_EXPIRED'}, 401),
        AcademicStatus.SESSION_EXPIRED,
      );
      expect(
        statusOf(<String, Object?>{}, 401),
        AcademicStatus.INVALID_CREDENTIALS,
      );
      expect(
        statusOf(<String, Object?>{'status': 'FORBIDDEN_ORIGIN'}, 403),
        AcademicStatus.UNTRUSTED_URL,
      );
      expect(
        statusOf(<String, Object?>{'status': 'RESULT_UNKNOWN'}, 504),
        AcademicStatus.RESULT_UNKNOWN,
      );
      expect(
        statusOf(<String, Object?>{'status': 'VALIDATION_FAILED'}, 400),
        AcademicStatus.VALIDATION_FAILED,
      );
      expect(
        statusOf(<String, Object?>{'status': 'NETWORK_ERROR'}, 502),
        AcademicStatus.NETWORK_RETRYABLE,
      );
      expect(
        decoder.mapError(500, <String, Object?>{}).message,
        '测试网关请求失败（HTTP 500）',
      );
      expect(
        decoder
            .mapError(500, <String, Object?>{'error': 'internal'},
                mayHaveCommitted: true)
            .status,
        AcademicStatus.RESULT_UNKNOWN,
      );
      expect(
        decoder
            .mapError(502, <String, Object?>{'status': 'NETWORK_ERROR'},
                mayHaveCommitted: true)
            .status,
        AcademicStatus.NETWORK_RETRYABLE,
      );
      expect(
        decoder
            .mapError(429, <String, Object?>{'error': 'rate limited'},
                mayHaveCommitted: true)
            .status,
        AcademicStatus.NETWORK_RETRYABLE,
      );
    });

    test('parseHeaders flattens values and optionally drops Set-Cookie', () {
      final raw = <String, Object?>{
        'Content-Type': 'text/html',
        'Set-Cookie': <Object?>['a=1', 'b=2'],
        'X-Null': null,
      };
      expect(GatewayResponseDecoder.parseHeaders(raw), <String, List<String>>{
        'Content-Type': <String>['text/html'],
        'Set-Cookie': <String>['a=1', 'b=2'],
      });
      expect(
        GatewayResponseDecoder.parseHeaders(raw, skipSetCookie: true),
        <String, List<String>>{
          'Content-Type': <String>['text/html'],
        },
      );
      expect(GatewayResponseDecoder.parseHeaders('oops'), isEmpty);
    });

    test('decodeBody handles base64, empty and missing bodies', () {
      expect(
        utf8.decode(
          GatewayResponseDecoder.decodeBody(base64Encode(utf8.encode('hi'))),
        ),
        'hi',
      );
      expect(GatewayResponseDecoder.decodeBody(''), isEmpty);
      expect(GatewayResponseDecoder.decodeBody(null), isEmpty);
    });
  });

  group('Gateway transports classify post-send failures (Redline #3)', () {
    final postRequest = HttpRequest(
      method: HttpMethod.post,
      url: 'https://jwglxt.qust.edu.cn/jwglxt/xsxk/zzxkyzb_xkBcZyZzxkYzb.html',
      body: Uint8List.fromList(utf8.encode('jxb_ids=1')),
    );
    final getRequest = HttpRequest(
      method: HttpMethod.get,
      url: 'https://jwglxt.qust.edu.cn/jwglxt/xtgl/index_initMenu.html',
    );

    MockClient connectionReset() => MockClient(
      (_) async => throw http.ClientException('Connection reset by peer'),
    );

    WorkerSessionHttpEngine workerEngine(http.Client client) =>
        WorkerSessionHttpEngine(
          workerBaseUrlProvider: () => 'https://session.example.workers.dev',
          apiKeyProvider: () => 'cl_secret_abc',
          client: client,
        );

    RelayHttpEngine relayEngine(http.Client client) => RelayHttpEngine(
      policyProvider: () => const HttpPolicySnapshot(
        relayBaseUrl: 'https://relay.example.workers.dev',
      ),
      client: client,
    );

    test('WorkerSessionHttpEngine.execute', () async {
      final engine = workerEngine(connectionReset());
      await expectLater(
        engine.execute(postRequest),
        throwsStatus(AcademicStatus.RESULT_UNKNOWN),
      );
      await expectLater(
        engine.execute(getRequest),
        throwsStatus(AcademicStatus.NETWORK_RETRYABLE),
      );
    });

    test('WorkerSessionHttpEngine confirmed selection writes and control-plane reads', () async {
      final selectionRequest = HttpRequest(
        method: HttpMethod.post,
        url:
            'https://jwglxt.example.edu.cn/jwglxt/xsxk/zzxkyzbjk_xkBcZyZzxkYzb.html',
        body: Uint8List.fromList(utf8.encode('jxb_ids=JXB1')),
        confirmedSelection: true,
      );
      await expectLater(
        workerEngine(connectionReset()).execute(selectionRequest),
        throwsStatus(AcademicStatus.RESULT_UNKNOWN),
      );
      await expectLater(
        WorkerSessionHttpEngine.fetchRemoteSession(
          workerBaseUrl: 'https://session.example.workers.dev',
          apiKey: 'cl_secret_abc',
          client: connectionReset(),
        ),
        throwsStatus(AcademicStatus.NETWORK_RETRYABLE),
      );
      await expectLater(
        WorkerSessionHttpEngine.fetchCacheStats(
          workerBaseUrl: 'https://session.example.workers.dev',
          apiKey: 'cl_secret_abc',
          client: connectionReset(),
        ),
        throwsStatus(AcademicStatus.NETWORK_RETRYABLE),
      );
    });

    test('RelayHttpEngine.execute', () async {
      final engine = relayEngine(connectionReset());
      await expectLater(
        engine.execute(postRequest),
        throwsStatus(AcademicStatus.RESULT_UNKNOWN),
      );
      await expectLater(
        engine.execute(getRequest),
        throwsStatus(AcademicStatus.NETWORK_RETRYABLE),
      );
    });

    test('RelayHttpEngine uses the shared gateway error mapping', () async {
      final engine = relayEngine(
        MockClient(
          (_) async => json(<String, Object?>{
            'status': 'SESSION_EXPIRED',
            'error': '会话过期',
          }, 401),
        ),
      );
      await expectLater(
        engine.execute(getRequest),
        throwsStatus(AcademicStatus.SESSION_EXPIRED),
      );
    });
  });
}
