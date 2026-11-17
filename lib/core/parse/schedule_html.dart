import 'dart:collection';

import 'package:html/dom.dart';

import '../model/academic_status.dart';
import '../model/schedule.dart';
import 'html.dart';
import 'schedule_text.dart';

/// 课表 HTML 表格解析（含不规则 `rowspan` / `colspan` 坐标网格还原）。
class ScheduleHtml {
  const ScheduleHtml._();

  static const int _maxRowspan = 40;
  static const int _maxColspan = 20;

  static const List<String> _dayLabels = ['一', '二', '三', '四', '五', '六', '日'];
  static const Set<String> _weekdayHeaders = {'星期一', '周一'};
  static const Set<String> _cellTags = {'td', 'th'};
  static const Set<String> _placeholders = {'', '-', '—', '－', '﹣', '\u00A0'};
  static const Set<String> _skippedContent = {'-', '—'};

  static final RegExp _periodLine = RegExp(r'\d.*节');
  static final RegExp _brTag = RegExp(r'<br\s*/?>', caseSensitive: false);
  static final RegExp _blockSeparator = RegExp(
    r'(?:<br\s*/?>\s*){2,}|<hr[^>]*>',
    caseSensitive: false,
  );
  static final RegExp _nestedTable = RegExp(
    r'<table\b.*?</table>',
    caseSensitive: false,
    dotAll: true,
  );

  static List<ScheduleEntry> parse(String html, [String baseUrl = '']) {
    if (Html.isLoginPage(html)) {
      throw const AcademicException(
        AcademicStatus.SESSION_EXPIRED,
        '登录状态已失效，请重新登录',
      );
    }
    final document = Html.parse(html, baseUrl);
    final table = _findScheduleTable(document);
    if (table == null) {
      throw const AcademicException(
        AcademicStatus.PAGE_CHANGED,
        '响应里没有可识别的课表',
      );
    }

    final cells = _cellGrid(table);
    final headingRow = _headingRowOf(cells);
    if (headingRow == null) {
      throw const AcademicException(
        AcademicStatus.PAGE_CHANGED,
        '课表没有星期表头',
      );
    }
    final dayOfColumn = _dayOfColumn(cells, headingRow);
    final entries = _collectEntries(cells, headingRow, dayOfColumn);

    if (entries.isEmpty &&
        _hasUnreadableContent(cells, headingRow, dayOfColumn)) {
      throw const AcademicException(
        AcademicStatus.PAGE_CHANGED,
        '课表格式已变化，读不出节次',
      );
    }
    return LinkedHashSet<ScheduleEntry>.of(entries).toList(growable: false);
  }

  static Element? _findScheduleTable(Document document) {
    Element? found;
    for (final table in document.querySelectorAll('table')) {
      final hasWeekday = _directRows(table)
          .expand((r) => r.children)
          .any((cell) => _weekdayHeaders.contains(Html.textOf(cell)));
      if (hasWeekday) found = table;
    }
    return found;
  }

  static List<Element> _directRows(Element table) => table
      .querySelectorAll('tr')
      .where((row) => identical(Html.closestTag(row, 'table'), table))
      .toList();

  static List<_GridCell> _cellGrid(Element table) {
    final occupied = <(int, int)>{};
    final grid = <_GridCell>[];
    final rows = _directRows(table);
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      var column = 0;
      for (final cell in rows[rowIndex].children) {
        if (!_cellTags.contains(cell.localName)) continue;
        while (occupied.contains((rowIndex, column))) {
          column++;
        }
        grid.add(_GridCell(rowIndex, column, cell));
        final rowSpan = (int.tryParse(Html.attr(cell, 'rowspan')) ?? 1)
            .clamp(1, _maxRowspan);
        final colSpan = (int.tryParse(Html.attr(cell, 'colspan')) ?? 1)
            .clamp(1, _maxColspan);
        for (var r = rowIndex; r < rowIndex + rowSpan; r++) {
          for (var c = column; c < column + colSpan; c++) {
            occupied.add((r, c));
          }
        }
        column += colSpan;
      }
    }
    return grid;
  }

  static int? _headingRowOf(List<_GridCell> cells) {
    for (final cell in cells) {
      final text = Html.textOf(cell.node);
      if (_dayLabels.any((l) => text == '星期$l' || text == '周$l')) {
        return cell.row;
      }
    }
    return null;
  }

  static Map<int, int> _dayOfColumn(List<_GridCell> cells, int headingRow) {
    final map = <int, int>{};
    for (final cell in cells) {
      if (cell.row != headingRow) continue;
      final text = Html.textOf(cell.node).replaceAll('天', '日');
      for (var i = 0; i < _dayLabels.length; i++) {
        final label = _dayLabels[i];
        if (text == '星期$label' || text == '周$label') {
          map[cell.column] = i + 1;
          break;
        }
      }
    }
    return map;
  }

  static List<ScheduleEntry> _collectEntries(
    List<_GridCell> cells,
    int headingRow,
    Map<int, int> dayOfColumn,
  ) {
    final entries = <ScheduleEntry>[];
    for (final cell in cells) {
      if (cell.row <= headingRow) continue;
      final day = dayOfColumn[cell.column];
      if (day == null) continue;
      for (final block in _courseBlocks(cell.node)) {
        entries.addAll(_entriesOf(block, day));
      }
    }
    return entries;
  }

  static bool _hasUnreadableContent(
    List<_GridCell> cells,
    int headingRow,
    Map<int, int> dayOfColumn,
  ) =>
      cells.any(
        (cell) =>
            cell.row > headingRow &&
            dayOfColumn.containsKey(cell.column) &&
            !_isPlaceholder(Html.textOf(cell.node)),
      );

  static List<Element> _courseBlocks(Element cell) {
    final qzItems = cell.querySelectorAll('.courselists-item');
    if (qzItems.isNotEmpty) return qzItems;
    final kbItems = cell.querySelectorAll('.kbcontent');
    if (kbItems.isNotEmpty) return kbItems;

    final cleaned = cell.innerHtml.replaceAll(_nestedTable, '');
    final out = <Element>[];
    for (final fragment in cleaned.split(_blockSeparator)) {
      if (fragment.trim().isEmpty) continue;
      final body = Html.parse(fragment).body;
      if (body != null && Html.textOf(body).isNotEmpty) {
        out.add(body);
      }
    }
    return out;
  }

  static List<ScheduleEntry> _entriesOf(Element block, int day) {
    final lines = _blockLines(block);
    final content = lines.join('\n');
    if (content.trim().isEmpty || _skippedContent.contains(content.trim())) {
      return const <ScheduleEntry>[];
    }

    final periods = ScheduleText.parsePeriodsFromAnywhere(content);
    if (periods.isEmpty) return const <ScheduleEntry>[];

    final labelledTime = _labelled(content, const ['时间']);
    final weeksSource = labelledTime.isNotEmpty ? labelledTime : content;
    final weeks = ScheduleText.parseWeeks(weeksSource);
    if (weeks == null) return const <ScheduleEntry>[];

    final name = _nameOf(block, lines);
    final teacher = _teacherOf(block, content, lines);
    final location = _locationOf(block, content, lines);

    return periods
        .map(
          (span) => ScheduleEntry(
            name: name,
            teacher: teacher,
            location: location,
            day: day,
            period: span,
            weeks: weeks,
          ),
        )
        .toList();
  }

  static List<String> _blockLines(Element block) {
    final abbreviation = block.querySelector('.qz-hasCourse-abbrinfo');
    if (abbreviation != null) {
      return <String>[
        Html.textOf(block.querySelector('.qz-hasCourse-title')),
        Html.textOf(abbreviation),
      ];
    }
    return _textLines(block);
  }

  static String _nameOf(Element block, List<String> lines) {
    final qzTitle = Html.textOf(block.querySelector('.qz-hasCourse-title'));
    if (qzTitle.isNotEmpty) return qzTitle;
    return lines.isEmpty ? '' : lines.first.trim();
  }

  static String _teacherOf(
    Element block,
    String content,
    List<String> lines,
  ) {
    var teacher = _labelled(content, const ['老师', '教师']);
    if (teacher.isEmpty) {
      teacher = block
          .querySelectorAll('[title=老师],[title=教师]')
          .map(Html.textOf)
          .where((s) => s.isNotEmpty)
          .join(' ');
    }
    if (teacher.isEmpty) {
      teacher = _lineAfterPeriods(lines, offset: 1);
    }
    if (teacher.endsWith('未定义')) {
      teacher = teacher.substring(0, teacher.length - 3);
    }
    return teacher.trim();
  }

  static String _locationOf(
    Element block,
    String content,
    List<String> lines,
  ) {
    var location = _labelled(content, const ['地点', '教室']);
    if (location.isEmpty) {
      location = block
          .querySelectorAll('[title=教室],[title=上课地点]')
          .map(Html.textOf)
          .where((s) => s.isNotEmpty)
          .join(' ');
    }
    if (location.isEmpty) {
      location = _lineAfterPeriods(lines, offset: 2);
    }
    return location.trim();
  }

  static String _lineAfterPeriods(List<String> lines, {required int offset}) {
    final periodIndex = lines.indexWhere(_periodLine.hasMatch);
    if (periodIndex < 0) return '';
    final targetIndex = periodIndex + offset;
    return (targetIndex >= 0 && targetIndex < lines.length)
        ? lines[targetIndex]
        : '';
  }

  static List<String> _textLines(Element block) {
    final replaced = block.innerHtml.replaceAll(_brTag, '\n');
    final whole = Html.wholeTextOf(Html.parse(replaced).body);
    return whole
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  static bool _isPlaceholder(String text) =>
      _placeholders.contains(text.trim());

  static String _labelled(String content, List<String> labels) {
    final escaped = labels.map(RegExp.escape).join('|');
    final pattern = RegExp('(?:$escaped)[:：]\\s*([^;；\\n]+)');
    return (pattern.firstMatch(content)?.group(1) ?? '').trim();
  }
}

class _GridCell {
  const _GridCell(this.row, this.column, this.node);
  final int row;
  final int column;
  final Element node;
}
