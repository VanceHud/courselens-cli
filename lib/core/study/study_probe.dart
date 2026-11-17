import '../model/academic_status.dart';
import '../model/academic_system.dart';
import '../parse/html.dart';
import '../parse/system_detector.dart';
import '../parse/urls.dart';
import '../port/http.dart';
import '../port/runtime.dart';
import '../session/session.dart';
import 'study_system_probe.dart';
import 'study_transport.dart';

/// 无状态登录页探测（找出教务系统类型与部署上下文前缀，兼容 HTTP 302 与 `<meta http-equiv="refresh">`）。
class StudyProbe {
  StudyProbe({
    required HttpEngine engine,
    required TextDecoder decoder,
    required int Function() clock,
  })  : _engine = engine,
        _decoder = decoder,
        _clock = clock;

  static const List<String> _candidateEntryPaths = [
    '',
    'framework/xsMainV.htmlx',
    'xk/LoginToXk',
    'xtgl/login_slogin.html',
    'default2.aspx',
  ];
  static const String _rootPrefix = '';
  static const String _legacyQzPrefix = '/jsxsd';
  static const String _zfPrefix = '/jwglxt';
  static const int _maxMetaRefreshHops = 2;

  final HttpEngine _engine;
  final TextDecoder _decoder;
  final int Function() _clock;

  Future<StudySystemProbe?> detect({
    required String schoolId,
    required String accountKey,
    required String academicBaseUrl,
  }) async {
    final parsed = Urls.parseUrl(academicBaseUrl);
    if (parsed == null) return null;
    final origin = _originOf(parsed);
    var typedPath = parsed.path;
    while (typedPath.endsWith('/')) {
      typedPath = typedPath.substring(0, typedPath.length - 1);
    }
    if (typedPath == '/') typedPath = '';

    final dynamicPrefixes = <String>[];
    final visitedPrefixes = <String>{};
    final queue = <String>[..._probePrefixes(typedPath)];

    while (queue.isNotEmpty) {
      final root = queue.removeAt(0);
      if (!visitedPrefixes.add(root)) continue;
      final baseUrl = '$origin$root';
      final session = AccountSession(
        key: SessionKey(schoolId, '$accountKey-detection'),
        baseUrl: baseUrl,
        clock: _clock,
      );
      final transport = StudyTransport(
        session: session,
        engine: _engine,
        decoder: _decoder,
      );
      for (final candidate in _candidateEntryPaths) {
        final hit = await _probeCandidate(
          transport,
          origin,
          candidate,
          dynamicPrefixes,
        );
        for (final discovered in dynamicPrefixes) {
          if (!visitedPrefixes.contains(discovered) &&
              !queue.contains(discovered)) {
            queue.insert(0, discovered);
          }
        }
        dynamicPrefixes.clear();
        if (hit == null) continue;

        final resolvedPrefix = _resolveEffectivePrefix(
          system: hit.$1,
          configuredRoot: root,
          candidate: candidate,
          finalPage: hit.$3,
        );
        final resolvedBaseUrl = '$origin$resolvedPrefix';
        return StudySystemProbe(
          systemId: hit.$1.id,
          basePath: resolvedPrefix,
          baseUrl: resolvedBaseUrl,
          detectedFrom: hit.$2,
          message: '识别为${_systemName(hit.$1)}（$resolvedBaseUrl）',
        );
      }
    }
    return null;
  }

  Future<(AcademicSystem, String, FetchedPage)?> _probeCandidate(
    StudyTransport transport,
    String origin,
    String candidate,
    List<String> discoveredPrefixes,
  ) async {
    var currentUrl = transport.resolveUrl(candidate);
    for (var hop = 0; hop <= _maxMetaRefreshHops; hop++) {
      final FetchedPage response;
      try {
        response = await transport.fetch(currentUrl);
      } on SessionCancelledException {
        rethrow;
      } on AcademicException {
        return null;
      }
      if (response.status < 200 || response.status > 299) return null;

      final detected = SystemDetector.classify(response.body);
      if (detected != null) {
        return (detected, response.address, response);
      }

      final ctx = Html.jwglxtContextPath(response.body, response.address);
      if (ctx != null && ctx.isNotEmpty) {
        discoveredPrefixes.add(ctx);
      }

      final refreshTarget =
          Html.metaRefreshTarget(response.body, response.address);
      if (refreshTarget == null || refreshTarget == currentUrl) {
        return null;
      }
      final parsedTarget = Urls.parseUrl(refreshTarget);
      if (parsedTarget == null || _originOf(parsedTarget) != origin) {
        return null;
      }
      currentUrl = refreshTarget;
    }
    return null;
  }

  static String _resolveEffectivePrefix({
    required AcademicSystem system,
    required String configuredRoot,
    required String candidate,
    required FetchedPage finalPage,
  }) {
    if (system == AcademicSystem.ZF) {
      final zfCtx = Html.jwglxtContextPath(finalPage.body, finalPage.address);
      if (zfCtx != null) return zfCtx;
    }
    final finalPath = Urls.parseUrl(finalPage.address)?.path ?? '';
    if (candidate.isNotEmpty) {
      final suffix = '/$candidate';
      final idx = finalPath.toLowerCase().indexOf(suffix.toLowerCase());
      if (idx > 0) {
        return finalPath.substring(0, idx);
      }
    }
    for (final known in const ['/jwglxt', '/jsxsd']) {
      if (finalPath == known || finalPath.startsWith('$known/')) {
        return known;
      }
    }
    return configuredRoot;
  }

  static String _originOf(ParsedUrl parsed) {
    final out = StringBuffer('${parsed.scheme}://${parsed.host}');
    if (parsed.hasExplicitPort && parsed.port > 0) {
      out.write(':${parsed.port}');
    }
    return out.toString();
  }

  static List<String> _probePrefixes(String typedPath) => <String>{
        typedPath,
        _rootPrefix,
        _legacyQzPrefix,
        _zfPrefix,
      }.toList(growable: false);

  static String _systemName(AcademicSystem system) => switch (system) {
        AcademicSystem.ZF => '正方教务 v9.0',
        AcademicSystem.ZF_OLD => '旧版正方（ASP.NET 表单）',
        AcademicSystem.QZ => '强智教务',
        AcademicSystem.QZ_OLD => '旧版强智教务',
        AcademicSystem.AUTO => '未知教务',
      };
}
