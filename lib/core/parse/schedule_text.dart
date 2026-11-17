import '../model/schedule.dart';

/// 课表节次与周次文本解析。
class ScheduleText {
  const ScheduleText._();

  static const int _weekCeiling = 60;

  static final RegExp _periodSegment = RegExp(r'^(\d+)(?:\s*-\s*(\d+))?$');
  static final RegExp _periodInSentence = RegExp(
    r'(?:第|\[)?(\d+(?:\s*-\s*\d+)*(?:\s*[,，、]\s*\d+(?:\s*-\s*\d+)*)*)\s*节',
  );
  static final RegExp _weekInSentence = RegExp(
    r'(?:第)?(\d+(?:\s*-\s*\d+)*(?:\s*[,，、]\s*\d+(?:\s*-\s*\d+)*)*)\s*(?:\(?(单|双)周?\)?)?\s*周\s*(?:\(?(单|双)周?\)?)?',
  );
  static final RegExp _weekSegment = RegExp(r'^(\d+)(?:\s*-\s*(\d+))?$');

  static const Map<String, String> _punctuationRewrites = {
    '（': '(',
    '）': ')',
    '—': '-',
    '－': '-',
    '～': '-',
    '~': '-',
  };

  static const List<(String, String)> _wordRewrites = [
    ('(周)', '周'),
    ('(节)', '节'),
  ];

  static String _normalizePunctuation(String value) {
    var text = value;
    for (final entry in _punctuationRewrites.entries) {
      text = text.replaceAll(entry.key, entry.value);
    }
    for (final (from, to) in _wordRewrites) {
      text = text.replaceAll(from, to);
    }
    return text;
  }

  /// 解析节次文本，相邻节次合并为连续 [PeriodSpan]。
  static List<PeriodSpan> parsePeriods(String value) {
    final numbers = _collectPeriodNumbers(_normalizePunctuation(value));
    return numbers.isEmpty ? const <PeriodSpan>[] : _mergeAdjacent(numbers);
  }

  static List<int> _collectPeriodNumbers(String value) {
    final numbers = <int>{};
    for (final piece in value.split(RegExp(r'[,，、]'))) {
      final match = _periodSegment.firstMatch(piece.trim());
      if (match == null) continue;
      final first = int.tryParse(match.group(1) ?? '');
      if (first == null) continue;
      final lastGroup = match.group(2);
      final last =
          lastGroup == null ? first : int.tryParse(lastGroup) ?? -1;
      if (first >= 1 &&
          first <= PeriodSpan.maxPeriod &&
          last >= first &&
          last <= PeriodSpan.maxPeriod) {
        for (var n = first; n <= last; n++) {
          numbers.add(n);
        }
      }
    }
    final sorted = numbers.toList()..sort();
    return sorted;
  }

  static List<PeriodSpan> _mergeAdjacent(List<int> ordered) {
    final spans = <PeriodSpan>[];
    var runStart = ordered.first;
    var runEnd = runStart;
    for (var i = 1; i < ordered.length; i++) {
      final number = ordered[i];
      if (number == runEnd + 1) {
        runEnd = number;
        continue;
      }
      spans.add(PeriodSpan(runStart, runEnd));
      runStart = number;
      runEnd = number;
    }
    spans.add(PeriodSpan(runStart, runEnd));
    return spans;
  }

  /// 解析周次文本并展开为 [WeekPattern]，完全无法识别时返回 `null`。
  static WeekPattern? parseWeeks(String value) {
    final normalized = _normalizePunctuation(value);
    final weeks = <int>{};
    var sawUsableSegment = false;

    for (final mention in _weekInSentence.allMatches(normalized)) {
      final ranges = _weekSegments(mention.group(1) ?? '');
      if (ranges.isEmpty) continue;
      sawUsableSegment = true;
      final parity1 = mention.group(2) ?? '';
      final parity2 = mention.group(3) ?? '';
      final parity = parity1.isNotEmpty ? parity1 : parity2;
      for (final (first, last) in ranges) {
        for (var week = first; week <= last; week++) {
          if (week >= 1 &&
              week <= _weekCeiling &&
              _parityAccepts(parity, week)) {
            weeks.add(week);
          }
        }
      }
    }

    if (!sawUsableSegment || weeks.isEmpty) return null;
    return WeekPattern(weeks, value.trim());
  }

  static bool _parityAccepts(String parity, int week) => switch (parity) {
        '单' => week.isOdd,
        '双' => week.isEven,
        _ => true,
      };

  static List<(int, int)> _weekSegments(String body) {
    final ranges = <(int, int)>[];
    for (final piece in body.split(RegExp(r'[,，、]'))) {
      final match = _weekSegment.firstMatch(piece.trim());
      if (match == null) continue;
      final first = int.tryParse(match.group(1) ?? '');
      if (first == null) continue;
      final lastGroup = match.group(2);
      final last =
          lastGroup == null ? first : int.tryParse(lastGroup) ?? -1;
      if (first >= 1 &&
          first <= _weekCeiling &&
          last >= first &&
          last <= _weekCeiling) {
        ranges.add((first, last));
      }
    }
    return ranges;
  }

  static List<PeriodSpan> parsePeriodsFromAnywhere(String value) {
    final normalized = _normalizePunctuation(value);
    final captured = _periodInSentence.firstMatch(normalized)?.group(1) ?? '';
    return captured.isEmpty ? const <PeriodSpan>[] : parsePeriods(captured);
  }
}
