/// `HH:mm` 时钟文本的统一严格解析规则。
abstract final class ClockText {
  /// 严格解析两位小时、两位分钟的 `HH:mm`（00:00..23:59），返回当日分钟数；
  /// 不合规返回 `null`。
  static int? parseMinutes(String value) {
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
}
