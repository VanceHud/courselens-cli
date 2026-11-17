import '../model/schedule.dart';
import 'ics_export.dart';

/// 大课间：特定两节之间的课间时长覆盖（替换普通课间时长）。
class PeriodBreakOverride {
  const PeriodBreakOverride({
    required this.afterPeriod,
    required this.breakMinutes,
  });

  final int afterPeriod;
  final int breakMinutes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeriodBreakOverride &&
          afterPeriod == other.afterPeriod &&
          breakMinutes == other.breakMinutes;

  @override
  int get hashCode => Object.hash(afterPeriod, breakMinutes);
}

/// 一键生成作息表的配置输入。
class PeriodScheduleSpec {
  const PeriodScheduleSpec({
    this.firstStart = '08:00',
    this.lessonMinutes = 45,
    this.breakMinutes = 10,
    this.morningPeriods = 4,
    this.noonBreakMinutes = 120,
    this.afternoonPeriods = 4,
    this.eveningBreakMinutes = 100,
    this.periodCount = 12,
    this.breakOverrides = const <PeriodBreakOverride>[],
  });

  final String firstStart;
  final int lessonMinutes;
  final int breakMinutes;
  final int morningPeriods;
  final int noonBreakMinutes;
  final int afternoonPeriods;
  final int eveningBreakMinutes;
  final int periodCount;
  final List<PeriodBreakOverride> breakOverrides;
}

/// 由 [PeriodScheduleSpec] 推导完整节次时间表（不越过 `24:00`）。
class PeriodScheduleBuilder {
  const PeriodScheduleBuilder._();

  static const int _minutesPerDay = 24 * 60;
  static const int _maxOverrideBreak = 4 * 60;

  /// 青岛科技大学四方校区（`xqh_id=1`）与崂山校区（`xqh_id=2`）官方 11 节作息规格。
  static const PeriodScheduleSpec qustSifangLaoshanSpec = PeriodScheduleSpec(
    firstStart: '08:00',
    lessonMinutes: 45,
    breakMinutes: 10,
    morningPeriods: 4,
    noonBreakMinutes: 100,
    afternoonPeriods: 4,
    eveningBreakMinutes: 40,
    periodCount: 11,
    breakOverrides: <PeriodBreakOverride>[
      PeriodBreakOverride(afterPeriod: 2, breakMinutes: 20),
      PeriodBreakOverride(afterPeriod: 6, breakMinutes: 20),
    ],
  );

  /// 青岛科技大学高密校区（`xqh_id=3`）官方 11 节作息规格。
  static const PeriodScheduleSpec qustGaomiSpec = PeriodScheduleSpec(
    firstStart: '08:30',
    lessonMinutes: 45,
    breakMinutes: 5,
    morningPeriods: 4,
    noonBreakMinutes: 85,
    afternoonPeriods: 4,
    eveningBreakMinutes: 55,
    periodCount: 11,
    breakOverrides: <PeriodBreakOverride>[
      PeriodBreakOverride(afterPeriod: 2, breakMinutes: 20),
      PeriodBreakOverride(afterPeriod: 6, breakMinutes: 20),
    ],
  );

  /// 青岛科技大学四方 / 崂山校区 11 节标准作息表（`08:00-08:45` .. `19:50-20:35`）。
  static List<PeriodTime> qustSifangLaoshanPreset() =>
      build(qustSifangLaoshanSpec);

  /// 青岛科技大学高密校区 11 节标准作息表（`08:30-09:15` .. `19:40-20:25`）。
  static List<PeriodTime> qustGaomiPreset() => build(qustGaomiSpec);

  static List<PeriodTime> build(PeriodScheduleSpec spec) {
    final first = _parseClock(spec.firstStart);
    if (first == null) return const <PeriodTime>[];

    final lesson = spec.lessonMinutes.clamp(1, 180);
    final shortBreak = spec.breakMinutes.clamp(0, 120);
    final total = spec.periodCount.clamp(1, PeriodSpan.maxPeriod);
    final morning = spec.morningPeriods.clamp(0, total);
    final afternoon = spec.afternoonPeriods.clamp(0, total - morning);
    final noonBreak = spec.noonBreakMinutes.clamp(0, 10 * 60);
    final eveningBreak = spec.eveningBreakMinutes.clamp(0, 10 * 60);

    final overrides = <int, int>{};
    for (final item in spec.breakOverrides) {
      if (item.afterPeriod >= 1 && item.afterPeriod < total) {
        overrides[item.afterPeriod] =
            item.breakMinutes.clamp(0, _maxOverrideBreak);
      }
    }

    final result = <PeriodTime>[];
    var cursor = first;
    for (var period = 1; period <= total; period++) {
      if (morning >= 1 && morning < total && period == morning + 1) {
        cursor += noonBreak;
      }
      if (afternoon >= 1 && period == morning + afternoon + 1) {
        cursor += eveningBreak;
      }
      if (cursor + lesson > _minutesPerDay) break;
      result.add(
        PeriodTime(
          period,
          _formatClock(cursor),
          _formatClock(cursor + lesson),
        ),
      );
      cursor += lesson + (overrides[period] ?? shortBreak);
    }
    return result;
  }

  static int? _parseClock(String value) {
    final parts = value.split(':');
    if (parts.length != 2 || parts[0].length != 2 || parts[1].length != 2) {
      return null;
    }
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return hour * 60 + minute;
  }

  static String _formatClock(int minutes) {
    final hour = minutes ~/ 60;
    final minute = minutes % 60;
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }
}
