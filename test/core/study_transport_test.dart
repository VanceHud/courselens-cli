import 'package:courselens/core/courselens_core.dart';
import 'package:test/test.dart';

class _RecordingEngine implements HttpEngine {
  final List<HttpRequest> requests = <HttpRequest>[];

  @override
  Future<HttpResponse> execute(HttpRequest request) async {
    requests.add(request);
    return HttpResponse(status: 200, finalUrl: request.url);
  }
}

Future<String?> _fallbackReferer(String? defaultRefererPath) async {
  final engine = _RecordingEngine();
  final transport = StudyTransport(
    session: AccountSession(
      key: SessionKey('school', 'account'),
      baseUrl: 'https://jw.example.edu.cn/jwglxt',
      clock: () => 0,
    ),
    engine: engine,
    decoder: const CharsetTextDecoder(),
    defaultRefererPath: defaultRefererPath,
  );
  await transport.submitForm(
    transport.resolveUrl('xsxk/zzxkyzb_cxZzxkYzbIndex.html'),
    const <(String, String)>[],
    ajax: true,
  );
  return engine.requests.single.headers['Referer'];
}

void main() {
  test('新正方缺省 Referer 指向首页菜单', () async {
    expect(
      StudyReader.defaultRefererPathFor(AcademicSystem.ZF),
      ZhengfangHomeParser.initMenuPath,
    );
    expect(
      await _fallbackReferer(
        StudyReader.defaultRefererPathFor(AcademicSystem.ZF),
      ),
      'https://jw.example.edu.cn/jwglxt/xtgl/index_initMenu.html?jsdm=xs',
    );
  });

  test('非新正方系统缺省 Referer 退回请求 origin', () async {
    for (final system in <AcademicSystem>[
      AcademicSystem.ZF_OLD,
      AcademicSystem.QZ,
      AcademicSystem.QZ_OLD,
    ]) {
      expect(StudyReader.defaultRefererPathFor(system), isNull);
    }
    expect(await _fallbackReferer(null), 'https://jw.example.edu.cn');
  });
}
