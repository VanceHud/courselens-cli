import 'package:html/dom.dart';

import '../model/academic_status.dart';
import '../model/grades.dart';
import 'html.dart';

/// 学期标识归一与成绩页 HTML 表格按列名解析。
class GradesHtml {
  const GradesHtml._();

  static const Map<String, List<String>> _headerFields = {
    'name': ['课程名称', '课程名', '课程'],
    'score': ['成绩', '总评成绩', '总成绩', '最终成绩', '综合成绩'],
    'credits': ['学分', '课程学分'],
    'point': ['绩点', '课程绩点', '平均绩点'],
    'term': ['学年学期', '学期', '开课学期'],
    'year': ['学年', '开课学年'],
  };

  static const List<(String, List<String>)> _componentColumns = [
    ('平时', ['平时成绩']),
    ('期中', ['期中成绩']),
    ('期末', ['期末成绩']),
    ('实验', ['实验成绩']),
    ('实践', ['实践成绩']),
  ];

  static final RegExp _numericTerm = RegExp(
    r'(\d{4})\D+(\d{4})\D+([123])(?:\D|$)',
  );
  static final RegExp _chineseTerm = RegExp(
    r'(\d{4})\D+(\d{4})\D*第?([一二三])',
  );
  static const Map<String, int> _chineseNumerals = {
    '一': 1,
    '二': 2,
    '三': 3,
  };

  static const Set<String> _yearFields = {'xnm', 'xnd', 'ddlXN', 'xn'};
  static const Set<String> _termFields = {'xqm', 'xqd', 'ddlXQ', 'xq'};
  static final RegExp _yearInText = RegExp(r'(\d{4})');

  static const List<String> _gpaLabels = ['平均学分绩点', '平均绩点', '绩点'];
  static const List<String> _creditLabels = ['已获学分', '总学分', '获得学分'];
  static const Set<String> _cellTags = {'td', 'th'};
  static const int _maxColspan = 20;

  static String? term(String value) =>
      _matchedTerm(value, _numericTerm, (digit) => digit) ??
      _matchedTerm(
        value,
        _chineseTerm,
        (numeral) => _chineseNumerals[numeral]?.toString(),
      );

  static String? _matchedTerm(
    String value,
    RegExp pattern,
    String? Function(String) semester,
  ) {
    final found = pattern.firstMatch(value);
    if (found == null) return null;
    final part = semester(found.group(3) ?? '');
    if (part == null) return null;
    return '${found.group(1)}-${found.group(2)}-$part';
  }

  static int? _semesterNumber(String fieldName, String rawValue) {
    final trimmed = rawValue.trim();
    if (fieldName == 'xqm') {
      return switch (trimmed) {
        '1' || '3' => 1,
        '2' || '12' => 2,
        '16' => 3,
        '32' => 4,
        _ => null,
      };
    }
    final parsed = int.tryParse(trimmed);
    return (parsed != null && parsed >= 1 && parsed <= 4) ? parsed : null;
  }

  static List<String> terms(String html) {
    final document = Html.parse(html);
    final direct = <String>{};
    for (final select in document.querySelectorAll('select')) {
      for (final option in select.querySelectorAll('option')) {
        if (Html.hasAttr(option, 'disabled')) continue;
        final t = term(Html.attr(option, 'value')) ?? term(Html.textOf(option));
        if (t != null) direct.add(t);
      }
    }
    if (direct.isNotEmpty) return direct.toList(growable: false);

    final selects = document.querySelectorAll('select[name]');
    final years = <int>{};
    final semesters = <int>{};
    for (final select in selects) {
      final field = _fieldNameOf(select);
      if (_yearFields.contains(field)) {
        for (final option in select.querySelectorAll('option')) {
          if (Html.hasAttr(option, 'disabled')) continue;
          final raw = Html.attr(option, 'value');
          final prefix = raw.length >= 4 ? raw.substring(0, 4) : raw;
          final y = int.tryParse(prefix);
          if (y != null) years.add(y);
        }
      }
      if (_termFields.contains(field)) {
        for (final option in select.querySelectorAll('option')) {
          if (Html.hasAttr(option, 'disabled')) continue;
          final s = _semesterNumber(field, Html.attr(option, 'value'));
          if (s != null) semesters.add(s);
        }
      }
    }
    final out = <String>[];
    for (final year in years) {
      for (final part in semesters) {
        out.add('$year-${year + 1}-$part');
      }
    }
    return out;
  }

  static String? selectedTerm(String html) {
    final document = Html.parse(html);
    for (final option in document.querySelectorAll('select option[selected]')) {
      final t = term(Html.attr(option, 'value')) ?? term(Html.textOf(option));
      if (t != null) return t;
    }

    final yearField = _namedField(document, _yearFields);
    if (yearField == null) return null;
    final rawYear = _selectedValue(yearField);
    final year = int.tryParse(
      rawYear.length >= 4 ? rawYear.substring(0, 4) : rawYear,
    );
    if (year == null) return null;

    final termField = _namedField(document, _termFields);
    if (termField == null) return null;
    final part = _semesterNumber(
      _fieldNameOf(termField),
      _selectedValue(termField),
    );
    if (part == null) return null;
    return '$year-${year + 1}-$part';
  }

  static String _fieldNameOf(Element element) {
    final raw = Html.attr(element, 'name');
    final dollar = raw.lastIndexOf(r'$');
    return dollar < 0 ? raw : raw.substring(dollar + 1);
  }

  static Element? _namedField(Document document, Set<String> names) {
    for (final element
        in document.querySelectorAll('select[name],input[name]')) {
      if (names.contains(_fieldNameOf(element))) return element;
    }
    return null;
  }

  static String _selectedValue(Element element) {
    if (element.localName == 'select') {
      final selected = element.querySelector('option[selected]') ??
          element.querySelector('option');
      return selected == null ? '' : Html.attr(selected, 'value');
    }
    return Html.attr(element, 'value');
  }

  static GradeReport parse(String html, [String baseUrl = '']) {
    if (Html.isLoginPage(html)) {
      throw const AcademicException(
        AcademicStatus.SESSION_EXPIRED,
        '登录状态已失效，请重新登录',
      );
    }
    final document = Html.parse(html, baseUrl);
    Element? table;
    for (final t in document.querySelectorAll('table')) {
      final text = Html.textOf(t);
      if (text.contains('课程名称') || text.contains('课程名')) {
        table = t;
      }
    }
    if (table == null) {
      throw const AcademicException(
        AcademicStatus.PAGE_CHANGED,
        '响应里没有可识别的成绩表',
      );
    }

    final rows = table
        .querySelectorAll('tr')
        .where((tr) => identical(Html.closestTag(tr, 'table'), table))
        .toList();
    final headerIndex =
        rows.indexWhere((row) => Html.textOf(row).contains('课程名'));
    if (headerIndex < 0) {
      throw const AcademicException(
        AcademicStatus.PAGE_CHANGED,
        '成绩表缺少表头',
      );
    }

    final headerCells = _flattenCells(rows[headerIndex]);
    final componentColumns = _claimedComponentColumns(headerCells);
    final taken = componentColumns.map((c) => c.$2).toSet();
    final columnOf = _fieldColumns(headerCells, taken);
    final nameColumn = columnOf['name'];
    if (nameColumn == null) {
      throw const AcademicException(
        AcademicStatus.PAGE_CHANGED,
        '成绩表缺少课程名称列',
      );
    }

    final entries = <GradeEntry>[];
    for (var i = headerIndex + 1; i < rows.length; i++) {
      final entry = _gradeEntryOf(
        rows[i],
        columnOf,
        nameColumn,
        componentColumns,
      );
      if (entry != null) entries.add(entry);
    }

    if (entries.isEmpty && rows.any((r) => Html.textOf(r).contains('分'))) {
      throw const AcademicException(
        AcademicStatus.PAGE_CHANGED,
        '成绩表结构已变化，未能读取到任何记录',
      );
    }

    // 移除表头行后再抓取汇总数字，避免表头末列「绩点」与首行学年「2025-...」跨行粘连。
    rows[headerIndex].remove();
    final pageText = Html.textOf(document);
    return GradeReport(
      grades: entries,
      gradePointAverageRaw: _labelledNumber(pageText, _gpaLabels),
      totalCreditsRaw: _labelledNumber(pageText, _creditLabels),
    );
  }

  static List<(String, int)> _claimedComponentColumns(
    List<(int, String)> headerCells,
  ) {
    final out = <(String, int)>[];
    for (final (label, aliases) in _componentColumns) {
      final index = headerCells.indexWhere(
        (cell) => aliases.any(cell.$2.contains),
      );
      if (index >= 0) out.add((label, index));
    }
    return out;
  }

  static Map<String, int> _fieldColumns(
    List<(int, String)> headerCells,
    Set<int> taken,
  ) {
    final columns = <String, int>{};
    final used = <int>{...taken};
    for (final entry in _headerFields.entries) {
      final isCreditOrPoint = entry.key == 'credits' || entry.key == 'point';
      int matched = -1;
      for (final alias in entry.value) {
        matched = headerCells.indexWhere(
          (cell) => !used.contains(cell.$1) && cell.$2.trim() == alias,
        );
        if (matched >= 0) break;
      }
      if (matched < 0) {
        for (final alias in entry.value) {
          matched = headerCells.indexWhere((cell) {
            if (used.contains(cell.$1)) return false;
            final text = cell.$2.trim();
            if (isCreditOrPoint && text.contains('学分绩点')) return false;
            return text.contains(alias);
          });
          if (matched >= 0) break;
        }
      }
      if (matched >= 0) {
        final colIndex = headerCells[matched].$1;
        columns[entry.key] = colIndex;
        used.add(colIndex);
      }
    }
    return columns;
  }

  static GradeEntry? _gradeEntryOf(
    Element row,
    Map<String, int> columnOf,
    int nameColumn,
    List<(String, int)> componentColumns,
  ) {
    final cells = _flattenCells(row).map((c) => c.$2).toList();
    final name =
        nameColumn < cells.length ? cells[nameColumn].trim() : '';
    if (name.isEmpty) return null;

    String cellAt(String key) {
      final col = columnOf[key];
      if (col == null || col >= cells.length) return '';
      return cells[col].trim();
    }

    final score = cellAt('score');
    final termText = cellAt('term');
    final yearText = cellAt('year');
    final details = <String>[];
    for (final (label, index) in componentColumns) {
      if (index < cells.length) {
        final v = cells[index].trim();
        if (v.isNotEmpty) details.add('$label: $v');
      }
    }

    return GradeEntry(
      name: name,
      score: score,
      credits: cellAt('credits'),
      gradePoint: cellAt('point'),
      term: term(termText) ?? _combinedTerm(yearText, termText) ?? termText,
      detail: details.join(' | '),
    );
  }

  static String? _combinedTerm(String yearText, String termText) {
    final year = int.tryParse(_yearInText.firstMatch(yearText)?.group(1) ?? '');
    if (year == null) return null;
    final semester = int.tryParse(termText.trim());
    if (semester == null || semester < 1 || semester > 3) return null;
    return '$year-${year + 1}-$semester';
  }

  static List<(int, String)> _flattenCells(Element row) {
    final cells = <(int, String)>[];
    var column = 0;
    for (final cell in row.children) {
      if (!_cellTags.contains(cell.localName)) continue;
      final span = (int.tryParse(Html.attr(cell, 'colspan')) ?? 1)
          .clamp(1, _maxColspan);
      final text = Html.textOf(cell);
      for (var offset = 0; offset < span; offset++) {
        cells.add((column + offset, text));
      }
      column += span;
    }
    return cells;
  }

  static String _labelledNumber(String pageText, List<String> labels) {
    for (final label in labels) {
      final match = RegExp(
        '${RegExp.escape(label)}[:：]?\\s*([0-9]+(?:\\.[0-9]+)?)',
      ).firstMatch(pageText);
      if (match != null) return match.group(1) ?? '';
    }
    return '';
  }
}
