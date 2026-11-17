import 'dart:convert';

import '../model/academic_status.dart';
import 'html.dart';

typedef JsonMap = Map<String, dynamic>;

/// 教务 JSON 响应的读取与业务状态归类原语。
class AcademicJson {
  const AcademicJson._();

  static const String _sessionExpiredMessage = '登录状态已失效，请重新登录';
  static const String _unreadableListMessage = '教务响应中没有可读取的列表，请重新进入页面';

  static const List<String> _containerAliases = [
    'data',
    'aaData',
    'rows',
    'list',
  ];
  static const Set<String> _successCodes = {'0', '200'};
  static const Set<String> _refusalFlags = {'false', '0'};

  static const List<String> _sessionKeywords = [
    '请先登录',
    '登录超时',
    '会话失效',
    '会话已过期',
    '登录已失效',
    '重新登录',
    'notLogin',
    'sessionOut',
  ];
  static const List<String> _credentialKeywords = [
    '密码错误',
    '用户名或密码',
    '账号或密码',
  ];
  static const List<String> _creditLimitKeywords = [
    '学分上限',
    '超过学分',
    '超出学分',
    '学分限制',
  ];
  static const List<String> _roundClosedKeywords = [
    '未开始',
    '未开放',
    '已结束',
    '选课时间已过',
    '不在选课时间',
    '不属于选课阶段',
    '非选课阶段',
    '未到选课',
    '选课未开放',
    '只可退课',
  ];
  static const List<String> _alreadySelectedKeywords = [
    '已选该',
    '已经选',
    '重复选课',
  ];
  static const List<String> _noCapacityKeywords = [
    '已满',
    '无余量',
    '名额不足',
    '容量不足',
  ];

  static final RegExp _operationCall = RegExp(r'xsxkFun\s*\(([^)]*)\)');
  static final RegExp _quotedArgument = RegExp(r'''['"]([^'"]*)['"]''');
  static const List<String> _operationArgumentFields = [
    'jx0404id',
    'kcid',
    'cfbs',
    'xqid',
  ];

  static List<JsonMap> objects(
    String body, [
    List<String> keys = const [],
  ]) {
    if (Html.isLoginPage(body)) {
      throw const AcademicException(
        AcademicStatus.SESSION_EXPIRED,
        _sessionExpiredMessage,
      );
    }
    final root = parse(body);
    final rows = _listContainer(root, keys);
    if (rows == null) {
      throw AcademicException(
        _unreadableListStatus(body),
        _unreadableListMessage,
      );
    }
    if (_refused(root)) {
      throw AcademicException(_refusalStatus(body), message(body));
    }
    final out = <JsonMap>[];
    for (final item in rows) {
      if (item is Map) {
        out.add(Map<String, dynamic>.from(item));
      }
    }
    return out;
  }

  static List<dynamic>? _listContainer(Object? root, List<String> keys) {
    if (root is List) return root;
    if (root is Map) {
      final rootMap = Map<String, dynamic>.from(root);
      final containers = <JsonMap>[
        rootMap,
        if (rootMap['data'] is Map)
          Map<String, dynamic>.from(rootMap['data'] as Map),
        if (rootMap['result'] is Map)
          Map<String, dynamic>.from(rootMap['result'] as Map),
      ];
      final names = <String>[...keys, ..._containerAliases];
      for (final container in containers) {
        for (final name in names) {
          final candidate = container[name];
          if (candidate is List) return candidate;
        }
      }
    }
    return null;
  }

  static bool _refused(Object? root) {
    if (root is! Map) return false;
    final map = Map<String, dynamic>.from(root);
    final successSaysNo =
        map.containsKey('success') && _booleanField(map, 'success') == false;
    final codeSaysNo = map.containsKey('code') &&
        !_successCodes.contains(string(map, const ['code']));
    final flagSaysNo = map.containsKey('flag') &&
        _refusalFlags.contains(string(map, const ['flag']));
    return successSaysNo || codeSaysNo || flagSaysNo;
  }

  static AcademicStatus _unreadableListStatus(String body) {
    final s = status(body);
    if (s == AcademicStatus.SUCCESS || s == AcademicStatus.VALIDATION_FAILED) {
      return AcademicStatus.PAGE_CHANGED;
    }
    return s;
  }

  static AcademicStatus _refusalStatus(String body) {
    final s = status(body);
    return s == AcademicStatus.SUCCESS ? AcademicStatus.VALIDATION_FAILED : s;
  }

  static String string(JsonMap row, List<String> names) {
    for (final name in names) {
      final v = _textOf(row[name]);
      if (v != null && v.trim().isNotEmpty && v != 'null') {
        return v;
      }
    }
    return '';
  }

  static int? integer(JsonMap row, List<String> names) {
    for (final name in names) {
      final v = _textOf(row[name])?.trim();
      if (v == null) continue;
      final parsed = int.tryParse(v);
      if (parsed != null) return parsed;
    }
    return null;
  }

  static Map<String, String> fields(JsonMap row) {
    final out = <String, String>{};
    for (final entry in row.entries) {
      out[entry.key] = _textOf(entry.value) ?? '';
    }
    return out;
  }

  static Map<String, String> operationFields(JsonMap row) {
    final result = fields(row);
    final args = _callArguments(
      string(row, const ['czOper', 'oper', 'operation']),
    );
    for (var i = 0;
        i < _operationArgumentFields.length && i < args.length;
        i++) {
      result[_operationArgumentFields[i]] = args[i];
    }
    return result;
  }

  static List<String> _callArguments(String script) {
    final inner = _operationCall.firstMatch(script)?.group(1);
    if (inner == null) return const <String>[];
    return _quotedArgument
        .allMatches(inner)
        .map((m) => m.group(1) ?? '')
        .toList();
  }

  static bool hasSuccess(String body) {
    final parsed = parse(body);
    if (parsed is! Map) return false;
    final json = Map<String, dynamic>.from(parsed);
    final successBool = _booleanField(json, 'success');
    if (successBool != null) return successBool;
    return string(json, const ['flag']) == '1' ||
        (json.containsKey('code') && string(json, const ['code']) == '0');
  }

  static AcademicStatus status(String body, [int code = 200]) {
    final transport = _transportStatus(code);
    if (transport != null) return transport;

    final lowerBody = body.toLowerCase();
    if (Html.isLoginPage(body) ||
        _sessionKeywords.any((k) => lowerBody.contains(k.toLowerCase()))) {
      return AcademicStatus.SESSION_EXPIRED;
    }
    final detail = message(body);
    final cred = _credentialStatus(detail);
    if (cred != null) return cred;
    if (_conflictDetected(body, detail)) return AcademicStatus.CONFLICT;
    final refusal = _refusalKeywordStatus(detail);
    if (refusal != null) return refusal;
    if (code < 200 || code > 299) return AcademicStatus.VALIDATION_FAILED;
    return hasSuccess(body)
        ? AcademicStatus.SUCCESS
        : AcademicStatus.VALIDATION_FAILED;
  }

  static bool looksLikeSessionExpired(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return false;
    final lower = trimmed.toLowerCase();
    if (lower == 'sessionout' || lower == 'notlogin' || lower == 'timeout') {
      return true;
    }
    // 仅在短提示文本或无业务数据的超时响应中按关键词判定，避免误伤正文中含「重新登录」字样的正常长页面。
    if (trimmed.length <= 512) {
      return const [
        '请先登录',
        '登录超时',
        '会话失效',
        '会话已过期',
        '登录已失效',
        'sessionout',
        'notlogin',
      ].any((k) => lower.contains(k));
    }
    return false;
  }

  static AcademicStatus? _transportStatus(int code) {
    if (code == 401 || code == 403 || code == 901) {
      return AcademicStatus.SESSION_EXPIRED;
    }
    if (code == 429) return AcademicStatus.NETWORK_RETRYABLE;
    if (code >= 500) return AcademicStatus.RESULT_UNKNOWN;
    return null;
  }

  static AcademicStatus? _credentialStatus(String detail) {
    if (_credentialKeywords.any(detail.contains)) {
      return AcademicStatus.INVALID_CREDENTIALS;
    }
    if (detail.contains('验证码') ||
        detail.toLowerCase().contains('verifycode')) {
      return AcademicStatus.HUMAN_VERIFICATION_REQUIRED;
    }
    return null;
  }

  static bool _conflictDetected(String body, String detail) {
    if (detail.contains('冲突')) return true;
    final parsed = parse(body);
    if (parsed is Map) {
      final conflictId = string(
        Map<String, dynamic>.from(parsed),
        const ['yxjx0404id'],
      );
      return conflictId.isNotEmpty && conflictId != 'null';
    }
    return false;
  }

  static AcademicStatus? _refusalKeywordStatus(String detail) {
    if (_creditLimitKeywords.any(detail.contains)) {
      return AcademicStatus.CREDIT_LIMIT;
    }
    if (_roundClosedKeywords.any(detail.contains)) {
      return AcademicStatus.ROUND_CLOSED;
    }
    if (_alreadySelectedKeywords.any(detail.contains)) {
      return AcademicStatus.ALREADY_SELECTED;
    }
    if (_noCapacityKeywords.any(detail.contains)) {
      return AcademicStatus.NO_CAPACITY;
    }
    return null;
  }

  static AcademicStatus zfStatus(String body, [int code = 200]) {
    var trimmed = body.trim();
    while (trimmed.startsWith('"')) {
      trimmed = trimmed.substring(1);
    }
    while (trimmed.endsWith('"')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    if (trimmed == '1' && code >= 200 && code <= 299) {
      return AcademicStatus.SUCCESS;
    }
    return status(body, code);
  }

  static String message(String body) {
    String fromJson = '';
    final parsed = parse(body);
    if (parsed is Map) {
      fromJson = string(
        Map<String, dynamic>.from(parsed),
        const ['message', 'msg', 'msgContent', 'error'],
      );
    }
    final visible = fromJson.trim().isNotEmpty
        ? fromJson
        : Html.textOf(Html.parse(body));
    return visible.length <= 180 ? visible : visible.substring(0, 180);
  }

  static Object? parse(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  static String? _textOf(Object? element) {
    if (element == null) return null;
    if (element is String) return element;
    if (element is num || element is bool) return element.toString();
    return jsonEncode(element);
  }

  static bool? _booleanField(JsonMap json, String name) {
    final v = json[name];
    if (v is bool) return v;
    if (v is String) {
      final lower = v.trim().toLowerCase();
      if (lower == 'true') return true;
      if (lower == 'false') return false;
    }
    return null;
  }
}
