import 'package:courselens/core/courselens_core.dart';
import 'package:test/test.dart';

void main() {
  group('ClockText.parseMinutes', () {
    test('parses strict HH:mm into minutes of day', () {
      expect(ClockText.parseMinutes('00:00'), 0);
      expect(ClockText.parseMinutes('08:05'), 8 * 60 + 5);
      expect(ClockText.parseMinutes('23:59'), 23 * 60 + 59);
    });

    test('rejects non-padded, out-of-range and malformed text', () {
      for (final raw in <String>[
        '8:05',
        '08:5',
        '24:00',
        '25:99',
        '08:60',
        ' 08:00',
        '08:00:00',
        '0800',
        'ab:cd',
        '',
      ]) {
        expect(ClockText.parseMinutes(raw), isNull, reason: raw);
      }
    });

    test('IcsExport.isClockText follows the same rule', () {
      expect(IcsExport.isClockText('08:00'), isTrue);
      expect(IcsExport.isClockText('8:00'), isFalse);
      expect(IcsExport.isClockText('24:00'), isFalse);
    });
  });

  group('ExamDates', () {
    ExamEntry exam({String examDate = '', String time = ''}) => ExamEntry(
      name: '高等数学',
      time: time,
      location: 'A101',
      examDate: examDate,
    );

    test('parses -, /, . and 年/月 separators embedded in text', () {
      expect(ExamDates.parse('2026-01-05'), (2026, 1, 5));
      expect(ExamDates.parse('2026/1/5 09:00-11:00'), (2026, 1, 5));
      expect(ExamDates.parse('第18周 2026.12.31'), (2026, 12, 31));
      expect(ExamDates.parse('2026年1月5日(星期一) 09:00'), (2026, 1, 5));
    });

    test('returns null for missing or impossible calendar dates', () {
      expect(ExamDates.parse('时间待定'), isNull);
      expect(ExamDates.parse(''), isNull);
      expect(ExamDates.parse('2026-02-30'), isNull);
      expect(ExamDates.parse('2026-13-01'), isNull);
      expect(ExamDates.parse('2026-00-10'), isNull);
    });

    test('of prefers examDate and falls back to time', () {
      expect(
        ExamDates.of(exam(examDate: '2026-01-06', time: '2026-01-05 09:00')),
        (2026, 1, 6),
      );
      expect(ExamDates.of(exam(examDate: '  ', time: '2026年01月05日 09:00')), (
        2026,
        1,
        5,
      ));
      expect(
        ExamDates.of(exam(examDate: '待定', time: '2026年01月05日 09:00')),
        (2026, 1, 5),
      );
      expect(ExamDates.of(exam(time: '待定')), isNull);
    });
  });
}
