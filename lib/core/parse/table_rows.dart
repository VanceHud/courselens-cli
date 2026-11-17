import 'package:html/dom.dart';

import '../model/academic_status.dart';
import 'html.dart';

/// 一行的「表头 -> 单元格」映射。
class TableRow {
  TableRow(Map<String, String> values) : _values = Map.unmodifiable(values);

  final Map<String, String> _values;

  String value(List<String> names) {
    for (final name in names) {
      final v = _values[name];
      if (v != null && v.trim().isNotEmpty) return v;
    }
    return '';
  }

  Map<String, String> all() => _values;
}

/// 按表头名读 HTML 表格行，并在被省略号截断时回退到 `title` 属性。
class TableRows {
  const TableRows._();

  static const Set<String> _courseTitleHeaders = {
    '课程名称',
    '课程名',
    '课程代码',
    '课程编号',
  };
  static const String _primaryTitle = '课程名称';
  static const String _secondaryTitle = '课程名';

  static List<TableRow> rows(String html, String baseUrl) {
    if (Html.isLoginPage(html)) {
      throw const AcademicException(
        AcademicStatus.SESSION_EXPIRED,
        '登录状态已失效，请重新登录',
      );
    }
    final doc = Html.parse(html, baseUrl);
    final out = <TableRow>[];
    for (final table in doc.querySelectorAll('table')) {
      out.addAll(_dataRowsOf(table));
    }
    return out;
  }

  static List<TableRow> _dataRowsOf(Element table) {
    final ownedRows = table
        .querySelectorAll('tr')
        .where((tr) => identical(Html.closestTag(tr, 'table'), table))
        .toList();

    var titleRowIndex = -1;
    for (var i = 0; i < ownedRows.length; i++) {
      final hasHeader = ownedRows[i]
          .querySelectorAll('th,td')
          .any((c) => _courseTitleHeaders.contains(Html.textOf(c)));
      if (hasHeader) {
        titleRowIndex = i;
        break;
      }
    }
    if (titleRowIndex < 0) return const <TableRow>[];

    final titles = ownedRows[titleRowIndex]
        .querySelectorAll('th,td')
        .map((c) => Html.textOf(c).replaceAll(' ', ''))
        .toList();

    final out = <TableRow>[];
    for (var i = titleRowIndex + 1; i < ownedRows.length; i++) {
      final row = ownedRows[i];
      final cells = row
          .querySelectorAll('td')
          .where((td) => identical(Html.closestTag(td, 'tr'), row))
          .toList();
      if (cells.length < titles.length) continue;
      final values = <String, String>{};
      for (var col = 0; col < titles.length; col++) {
        values[titles[col]] = _cellValue(cells[col]);
      }
      var courseName = values[_primaryTitle] ?? '';
      if (courseName.trim().isEmpty) {
        courseName = values[_secondaryTitle] ?? '';
      }
      if (courseName.trim().isNotEmpty) {
        out.add(TableRow(values));
      }
    }
    return out;
  }

  static String _cellValue(Element cell) {
    final shown = Html.textOf(cell);
    var attribute = Html.attr(cell, 'title').trim();
    if (attribute.isEmpty) {
      final childWithTitle = cell.querySelector('[title]');
      if (childWithTitle != null) {
        attribute = Html.attr(childWithTitle, 'title').trim();
      }
    }
    final ellipsized = shown.endsWith('...') || shown.endsWith('…');
    final withoutEllipsis = _stripTrailingEllipsis(shown);
    final attributeIsFuller = attribute.length > withoutEllipsis.length &&
        attribute.startsWith(withoutEllipsis);
    return ((shown.isEmpty || ellipsized) && attributeIsFuller)
        ? attribute
        : shown;
  }

  static String _stripTrailingEllipsis(String text) {
    var end = text.length;
    while (end > 0) {
      final ch = text[end - 1];
      if (ch == '.' || ch == '…' || ch == ' ') {
        end--;
      } else {
        break;
      }
    }
    return text.substring(0, end);
  }
}
