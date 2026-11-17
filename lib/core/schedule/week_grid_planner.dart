import 'ics_export.dart';

/// 一门课在周视图里的泳道落位。
class WeekGridPlacement {
  const WeekGridPlacement({
    required this.index,
    required this.day,
    required this.startPeriod,
    required this.endPeriod,
    required this.lane,
    required this.laneCount,
  });

  final int index;
  final int day;
  final int startPeriod;
  final int endPeriod;
  final int lane;
  final int laneCount;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WeekGridPlacement &&
          index == other.index &&
          day == other.day &&
          startPeriod == other.startPeriod &&
          endPeriod == other.endPeriod &&
          lane == other.lane &&
          laneCount == other.laneCount;

  @override
  int get hashCode => Object.hash(
        index,
        day,
        startPeriod,
        endPeriod,
        lane,
        laneCount,
      );
}

/// 周视图区间图贪心泳道布局（纯函数）。
class WeekGridPlanner {
  const WeekGridPlanner._();

  static List<WeekGridPlacement> place(List<IcsEntry> entries) {
    final result = <WeekGridPlacement>[];
    for (var day = 1; day <= 7; day++) {
      final indices = <int>[
        for (var i = 0; i < entries.length; i++)
          if (entries[i].day == day) i,
      ];
      if (indices.isEmpty) continue;
      indices.sort((a, b) {
        final cmpStart = entries[a].startPeriod.compareTo(entries[b].startPeriod);
        if (cmpStart != 0) return cmpStart;
        final cmpEnd = entries[a].endPeriod.compareTo(entries[b].endPeriod);
        if (cmpEnd != 0) return cmpEnd;
        return a.compareTo(b);
      });
      for (final cluster in _clustersOf(entries, indices)) {
        result.addAll(_assignLanes(entries, day, cluster));
      }
    }
    result.sort((a, b) => a.index.compareTo(b.index));
    return result;
  }

  static List<List<int>> _clustersOf(List<IcsEntry> entries, List<int> ordered) {
    final clusters = <List<int>>[];
    var current = <int>[];
    var reach = -1;
    for (final index in ordered) {
      final entry = entries[index];
      if (current.isNotEmpty && entry.startPeriod > reach) {
        clusters.add(current);
        current = <int>[];
        reach = -1;
      }
      current.add(index);
      if (entry.endPeriod > reach) reach = entry.endPeriod;
    }
    if (current.isNotEmpty) clusters.add(current);
    return clusters;
  }

  static List<WeekGridPlacement> _assignLanes(
    List<IcsEntry> entries,
    int day,
    List<int> cluster,
  ) {
    final laneEnds = <int>[];
    final lanes = <int>[];
    for (final index in cluster) {
      final entry = entries[index];
      var free = -1;
      for (var i = 0; i < laneEnds.length; i++) {
        if (laneEnds[i] < entry.startPeriod) {
          free = i;
          break;
        }
      }
      final lane = free >= 0 ? free : laneEnds.length;
      if (lane == laneEnds.length) {
        laneEnds.add(entry.endPeriod);
      } else {
        laneEnds[lane] = entry.endPeriod;
      }
      lanes.add(lane);
    }
    final laneCount = laneEnds.length;
    return <WeekGridPlacement>[
      for (var pos = 0; pos < cluster.length; pos++)
        WeekGridPlacement(
          index: cluster[pos],
          day: day,
          startPeriod: entries[cluster[pos]].startPeriod,
          endPeriod: entries[cluster[pos]].endPeriod,
          lane: lanes[pos],
          laneCount: laneCount,
        ),
    ];
  }
}
