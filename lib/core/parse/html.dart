import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'urls.dart';

/// 教务页面（HTML）的通用读取原语（基于纯 Dart `package:html`）。
class Html {
  const Html._();

  static const String _namedControls =
      'input[name], button[name], select[name], textarea[name]';
  static const String _loginControls =
      'input[type=password], input[name=mm], input[name=TextBox2]';
  static const String _hiddenInputs = 'input[type=hidden][name]';
  static const String _frameControls = 'frame[src], iframe[src]';

  static final RegExp _hiddenInStyle = RegExp(
    r'(?:^|;)\s*(?:display\s*:\s*none|visibility\s*:\s*hidden)\s*(?:!important)?\s*(?:;|$)',
    caseSensitive: false,
  );

  static final RegExp _redirectToLogin = RegExp(
    r'''(?:top\.|window\.|parent\.)?location(?:\.href)?\s*=\s*['"][^'"]*(?:login_slogin|default2\.aspx|LoginToXk)''',
    caseSensitive: false,
  );

  static final RegExp _frameTags = RegExp(
    r'<\s*(?:frameset|iframe)\b',
    caseSensitive: false,
  );

  static final RegExp _asciiWhitespaceRun = RegExp(r'[ \t\n\r\f]+');

  static const Set<String> _booleanInputs = {'checkbox', 'radio'};

  static Document parse(String html, [String baseUrl = '']) =>
      html_parser.parse(html);

  /// 与 Jsoup/Ksoup `element.text()` 对齐的折叠空白文本。
  static String textOf(Node? node) {
    if (node == null) return '';
    final out = StringBuffer();
    _appendText(node, out);
    return out.toString().replaceAll(_asciiWhitespaceRun, ' ').trim();
  }

  static void _appendText(Node node, StringBuffer out) {
    if (node is Text) {
      out.write(node.data);
      return;
    }
    if (node is Element) {
      final tag = node.localName ?? '';
      final isBlockLike = const {
        'br',
        'p',
        'div',
        'tr',
        'td',
        'th',
        'li',
        'ul',
        'ol',
        'table',
        'h1',
        'h2',
        'h3',
        'h4',
        'h5',
        'h6',
      }.contains(tag);
      if (tag == 'br') {
        out.write(' ');
        return;
      }
      if (isBlockLike && out.isNotEmpty) {
        out.write(' ');
      }
      for (final child in node.nodes) {
        _appendText(child, out);
      }
      if (isBlockLike && out.isNotEmpty) {
        out.write(' ');
      }
      return;
    }
    for (final child in node.nodes) {
      _appendText(child, out);
    }
  }

  /// 与 Jsoup/Ksoup `wholeText()` 对齐的保留换行原始文本。
  static String wholeTextOf(Node? node) => node?.text ?? '';

  static String attr(Element element, String name) =>
      element.attributes[name.toLowerCase()] ?? '';

  static bool hasAttr(Element element, String name) =>
      element.attributes.containsKey(name.toLowerCase());

  static List<Element> ancestors(Element element) {
    final out = <Element>[];
    var current = element.parent;
    while (current != null) {
      out.add(current);
      current = current.parent;
    }
    return out;
  }

  static Element? closestTag(Element element, String tagName) {
    final target = tagName.toLowerCase();
    Element? current = element;
    while (current != null) {
      if (current.localName == target) return current;
      current = current.parent;
    }
    return null;
  }

  static Element? nextElementSibling(Element element) {
    final parent = element.parent;
    if (parent == null) return null;
    final siblings = parent.children;
    final index = siblings.indexOf(element);
    if (index < 0 || index + 1 >= siblings.length) return null;
    return siblings[index + 1];
  }

  /// 控件是否可被点击（检查自身及祖先的 `disabled` / `hidden` / `display:none`）。
  static bool isEnabledControl(Element element) {
    final chain = <Element>[element, ...ancestors(element)];
    final blockedAncestor = chain.any(
      (node) =>
          hasAttr(node, 'disabled') ||
          hasAttr(node, 'hidden') ||
          attr(node, 'aria-disabled').toLowerCase() == 'true' ||
          _hiddenInStyle.hasMatch(attr(node, 'style')),
    );
    return !blockedAncestor && attr(element, 'type').toLowerCase() != 'hidden';
  }

  /// 判定当前页面是否为登录页（包含密码框/登录控件或跳登录脚本）。
  static bool isLoginPage(String html) {
    final doc = html_parser.parse(html);
    if (doc.querySelectorAll(_loginControls).isNotEmpty) return true;
    return _redirectToLogin.hasMatch(html);
  }

  static Map<String, String> hiddenFields(Document document) {
    final map = <String, String>{};
    for (final field in document.querySelectorAll(_hiddenInputs)) {
      map[attr(field, 'name')] = attr(field, 'value');
    }
    return map;
  }

  /// 读取所有 `input[type=hidden]`，同时按 `name` 和 `id` 建立索引（兼容仅有 `id="sessionUserKey"` 的正方页面）。
  static Map<String, String> hiddenFieldsByIdOrName(Document document) {
    final map = <String, String>{};
    for (final field in document.querySelectorAll('input[type=hidden]')) {
      final value = attr(field, 'value');
      final name = attr(field, 'name').trim();
      final id = attr(field, 'id').trim();
      if (name.isNotEmpty) map[name] = value;
      if (id.isNotEmpty) map.putIfAbsent(id, () => value);
    }
    return map;
  }

  /// 提取 `<meta http-equiv="refresh" content="1;url=/jwglxt">` 中的跳转目标。
  static String? metaRefreshTarget(String html, [String baseUrl = '']) {
    final doc = html_parser.parse(html);
    for (final meta in doc.querySelectorAll('meta')) {
      if (attr(meta, 'http-equiv').trim().toLowerCase() != 'refresh') continue;
      final content = attr(meta, 'content');
      final match = RegExp(
        r'''url\s*=\s*(?:['"]([^'"]+)['"]|([^\s;>]+))''',
        caseSensitive: false,
      ).firstMatch(content);
      final url = (match?.group(1) ?? match?.group(2) ?? '').trim();
      if (url.isNotEmpty) {
        return baseUrl.trim().isEmpty ? url : Urls.resolve(baseUrl, url);
      }
    }
    return null;
  }

  /// 识别新正方页面或重定向地址中的部署上下文路径（如 `/jwglxt`）。
  static String? jwglxtContextPath(String html, [String finalUrl = '']) {
    for (final scriptVar in const ['_path', '_systemPath']) {
      final v = firstScriptValue(html, scriptVar)?.trim() ?? '';
      final normalized = _normalizeContextPath(v);
      if (normalized != null) return normalized;
    }
    final refresh = metaRefreshTarget(html);
    if (refresh != null) {
      final refreshParsed = Urls.parseUrl(refresh);
      final candidatePath = refreshParsed != null ? refreshParsed.path : refresh;
      final normalized = _normalizeContextPath(candidatePath);
      if (normalized != null) return normalized;
    }
    final urlPath = Urls.parseUrl(finalUrl)?.path ?? '';
    return _extractContextBeforeModule(urlPath);
  }

  static String? _normalizeContextPath(String raw) {
    var p = raw.trim();
    if (p.isEmpty || p == '/') return null;
    final fromModule = _extractContextBeforeModule(p);
    if (fromModule != null) return fromModule;
    if (!p.startsWith('/')) p = '/$p';
    while (p.endsWith('/') && p.length > 1) {
      p = p.substring(0, p.length - 1);
    }
    if (p.contains('?') || p.contains('.html') || p.contains('.aspx')) {
      return null;
    }
    return p;
  }

  static String? _extractContextBeforeModule(String path) {
    if (path.isEmpty) return null;
    for (final marker in const [
      '/xtgl/',
      '/kbcx/',
      '/cjcx/',
      '/xsxk/',
      '/kwgl/',
      '/xsxy/',
      '/cdjy/',
      '/xkcx/',
    ]) {
      final idx = path.indexOf(marker);
      if (idx > 0) {
        return path.substring(0, idx);
      }
    }
    return null;
  }

  /// 控件提交值：`<option>` 缺 `value` 时用文本，勾选框缺 `value` 时用 `on`。
  static String controlValue(Element element) {
    final tag = element.localName ?? '';
    final type = attr(element, 'type').toLowerCase();
    if (tag == 'option' && !hasAttr(element, 'value')) {
      return textOf(element);
    }
    if (tag == 'input' &&
        _booleanInputs.contains(type) &&
        !hasAttr(element, 'value')) {
      return 'on';
    }
    return attr(element, 'value');
  }

  /// 收集一个表单应当提交的字段列表（模拟浏览器/ASP.NET 提交语义）。
  static List<(String, String)> formFields(
    Element form, {
    (String, String)? clickedSubmit,
  }) {
    final submitted = <(String, String)>[];
    for (final control in form.querySelectorAll(_namedControls)) {
      final fieldName = attr(control, 'name');
      if (fieldName.trim().isEmpty || hasAttr(control, 'disabled')) continue;
      final tag = control.localName ?? '';
      if (tag == 'select') {
        for (final option in _chosenOptions(control)) {
          submitted.add((fieldName, controlValue(option)));
        }
      } else if (tag == 'textarea') {
        submitted.add((fieldName, textOf(control)));
      } else {
        final pair = _inputSubmission(control, fieldName, clickedSubmit);
        if (pair != null) submitted.add(pair);
      }
    }
    return submitted;
  }

  static List<Element> _chosenOptions(Element select) {
    final marked = select.querySelectorAll('option[selected]');
    if (marked.isNotEmpty) {
      return marked.where(_isSelectable).toList();
    }
    if (hasAttr(select, 'multiple')) return const <Element>[];
    final size = int.tryParse(attr(select, 'size')) ?? 1;
    if (size > 1) return const <Element>[];
    final all = select.querySelectorAll('option');
    if (all.isEmpty) return const <Element>[];
    return <Element>[all.first].where(_isSelectable).toList();
  }

  static bool _isSelectable(Element option) =>
      !hasAttr(option, 'disabled') &&
      !(option.parent != null && hasAttr(option.parent!, 'disabled'));

  static (String, String)? _inputSubmission(
    Element control,
    String fieldName,
    (String, String)? clickedSubmit,
  ) {
    var type = attr(control, 'type').toLowerCase();
    if (type.trim().isEmpty) {
      type = control.localName == 'button' ? 'submit' : 'text';
    }
    if (type == 'submit' || type == 'button') {
      final candidate = (fieldName, attr(control, 'value'));
      return candidate == clickedSubmit ? candidate : null;
    }
    if ((type == 'checkbox' || type == 'radio') &&
        !hasAttr(control, 'checked')) {
      return null;
    }
    if (type == 'file' || type == 'reset') return null;
    return (fieldName, controlValue(control));
  }

  static String action(Element form, String baseUrl) {
    final declared = attr(form, 'action').trim();
    return Urls.resolve(baseUrl, declared.isEmpty ? baseUrl : declared);
  }

  /// 读取表单真实提交地址（支持识别静态 `document.forms['f'].action = '...'`，绝不执行 JS）。
  static String? queryFormAction(Element form, String html, String baseUrl) {
    final declared = attr(form, 'action').trim();
    final target = declared.isNotEmpty
        ? declared
        : _staticActionAssignment(form, html);
    return target == null ? null : Urls.resolve(baseUrl, target);
  }

  static String? _staticActionAssignment(Element form, String html) {
    var formName = attr(form, 'name').trim();
    if (formName.isEmpty) formName = form.id.trim();
    if (formName.isEmpty) return null;
    final pattern = RegExp(
      r'''document\.forms\s*\[\s*['"]''' +
          RegExp.escape(formName) +
          r'''['"]\s*\]\.action\s*=\s*['"]([^'"]+)['"]''',
    );
    return pattern.firstMatch(html)?.group(1);
  }

  static String? firstScriptValue(String html, String name) {
    final pattern = RegExp(
      '(?:var\\s+)?${RegExp.escape(name)}\\s*=\\s*[\'"]([^\'"]+)[\'"]',
    );
    return pattern.firstMatch(html)?.group(1);
  }

  static List<String> scriptUrls(Document document, String baseUrl) {
    final out = <String>[];
    for (final script in document.querySelectorAll('script[src]')) {
      final src = attr(script, 'src').trim();
      if (src.isEmpty) continue;
      final resolved = Urls.resolve(baseUrl, src);
      if (resolved.trim().isNotEmpty) out.add(resolved);
    }
    return out;
  }

  static bool hasFrames(String html) => _frameTags.hasMatch(html);

  static List<String> frameUrls(
    String html,
    String baseUrl, {
    int limit = 6,
  }) {
    final doc = html_parser.parse(html);
    final seen = <String>{};
    final out = <String>[];
    for (final frame in doc.querySelectorAll(_frameControls)) {
      final src = attr(frame, 'src').trim();
      if (src.isEmpty) continue;
      final resolved = Urls.resolve(baseUrl, src);
      if (!_isHttpAddress(resolved)) continue;
      if (seen.add(resolved)) {
        out.add(resolved);
        if (out.length >= limit) break;
      }
    }
    return out;
  }

  static bool _isHttpAddress(String url) {
    final scheme = Urls.parseUrl(url)?.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }
}
