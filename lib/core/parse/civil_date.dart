/// 公历日期与自 `1970-01-01` 起天数的双向纯整数换算（Howard Hinnant 算法）。
class CivilDate {
  const CivilDate._();

  /// `(年, 月, 日)` -> 自 `1970-01-01` 起的天数（1970 年前为负）。
  static int daysFromCivil(int year, int month, int day) {
    final y = month <= 2 ? year - 1 : year;
    final era = (y >= 0 ? y : y - 399) ~/ 400;
    final yearOfEra = y - era * 400;
    final dayOfYear =
        (153 * (month > 2 ? month - 3 : month + 9) + 2) ~/ 5 + day - 1;
    final dayOfEra =
        yearOfEra * 365 + yearOfEra ~/ 4 - yearOfEra ~/ 100 + dayOfYear;
    return era * 146097 + dayOfEra - 719468;
  }

  /// 自 `1970-01-01` 起的天数 -> `(年, 月, 日)`。
  static (int, int, int) civilFromDays(int days) {
    final z = days + 719468;
    final era = (z >= 0 ? z : z - 146096) ~/ 146097;
    final dayOfEra = z - era * 146097;
    final yearOfEra =
        (dayOfEra - dayOfEra ~/ 1460 + dayOfEra ~/ 36524 - dayOfEra ~/ 146096) ~/
            365;
    final y = yearOfEra + era * 400;
    final dayOfYear =
        dayOfEra - (365 * yearOfEra + yearOfEra ~/ 4 - yearOfEra ~/ 100);
    final mp = (5 * dayOfYear + 2) ~/ 153;
    final day = dayOfYear - (153 * mp + 2) ~/ 5 + 1;
    final month = mp < 10 ? mp + 3 : mp - 9;
    final year = month <= 2 ? y + 1 : y;
    return (year, month, day);
  }

  /// `yyyyMMdd`（iCalendar `DATE` 值格式）。
  static String compactDate(int year, int month, int day) =>
      '${year.toString().padLeft(4, '0')}'
      '${month.toString().padLeft(2, '0')}'
      '${day.toString().padLeft(2, '0')}';

  /// 本地墙上时间 + 固定时区偏移（默认北京时间 `+08:00`）-> UTC epoch 秒。
  static int epochSecondsAt(
    int year,
    int month,
    int day,
    int hour,
    int minute, {
    int utcOffsetSeconds = 8 * 3600,
  }) =>
      daysFromCivil(year, month, day) * 86400 +
      hour * 3600 +
      minute * 60 -
      utcOffsetSeconds;

  /// `yyyyMMdd'T'HHmmss'Z'`（iCalendar UTC 时间戳格式）。
  static String compactUtcStamp(int epochSeconds) {
    final days = epochSeconds >= 0
        ? epochSeconds ~/ 86400
        : -((-epochSeconds + 86399) ~/ 86400);
    final secondOfDay = epochSeconds - days * 86400;
    final (year, month, day) = civilFromDays(days);
    final hour = secondOfDay ~/ 3600;
    final minute = (secondOfDay % 3600) ~/ 60;
    final second = secondOfDay % 60;
    return '${compactDate(year, month, day)}T'
        '${hour.toString().padLeft(2, '0')}'
        '${minute.toString().padLeft(2, '0')}'
        '${second.toString().padLeft(2, '0')}Z';
  }
}
