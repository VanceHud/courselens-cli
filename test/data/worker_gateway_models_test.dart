import 'package:courselens/data/http/worker_gateway_models.dart';
import 'package:test/test.dart';

void main() {
  group('Worker gateway model JSON parsing', () {
    test('well-typed payload parses fields, defaults and nested lists', () {
      final detail = CloudTaskDetail.fromJson(<String, dynamic>{
        'taskId': ' monitor:grades ',
        'type': 'MONITOR_GRADES',
        'title': ' 成绩变动巡检 ',
        'enabled': true,
        'intervalSec': 1800,
        'lastRunAt': ' 2026-01-01T00:00:00Z ',
        'metrics': <String, dynamic>{'totalRuns': 3, 'lastDurationMs': 12.7},
        'recentChanges': <Object?>[
          <String, dynamic>{
            'courseName': ' 高等数学 ',
            'score': ' 95 ',
          },
          'not-a-map',
          null,
        ],
        'logs': <Object?>[
          <String, dynamic>{'atMs': 5, 'message': ' ok '},
        ],
      });

      expect(detail.taskId, 'monitor:grades');
      expect(detail.title, '成绩变动巡检');
      expect(detail.status, 'DISABLED');
      expect(detail.intervalSec, 1800);
      expect(detail.summary.lastRunAt, ' 2026-01-01T00:00:00Z ');
      expect(detail.summary.startAtEpochSeconds, isNull);
      expect(detail.metrics.totalRuns, 3);
      expect(detail.metrics.lastDurationMs, 12);
      expect(detail.recentChanges, hasLength(1));
      expect(detail.recentChanges.single.courseName, '高等数学');
      expect(detail.recentChanges.single.score, '95');
      expect(detail.logs.single.status, 'INFO');
      expect(detail.logs.single.message, 'ok');
      expect(
        () => detail.recentChanges.add(detail.recentChanges.single),
        throwsUnsupportedError,
      );
    });

    test('defaults that depend on other fields are preserved', () {
      final exams = WorkerSingleMonitorView.fromJson(<String, dynamic>{
        'kind': 'exams',
      });
      expect(exams.taskId, 'monitor:exams');
      expect(exams.intervalSec, 3600);
      expect(exams.lastSummary, '未开启（默认关闭）');

      final stats = WorkerCacheStats.fromJson(<String, dynamic>{
        'ok': true,
        'enabled': true,
        'stats': <String, dynamic>{
          'entryCount': '4',
          'totalBytes': 2048,
          'hits': 10,
          'l1Hits': 7,
          'l2Hits': 3,
          'misses': 2,
          'bypasses': 1,
          'evictions': 0,
        },
        'categories': <Object?>[
          <String, dynamic>{
            'category': ' schedule ',
            'ttlSec': '1800',
            'activeEntries': 1,
            'bytes': 1024,
          },
          'ignored',
        ],
      });
      expect(stats.entryCount, 4);
      expect(stats.formattedSize, '2.0 KB');
      expect(stats.categories, hasLength(1));
      expect(stats.categories.single.category, 'schedule');
      expect(stats.categories.single.ttlSec, 1800);
      expect(stats.toJson()['formattedSize'], '2.0 KB');
    });

    test('non-string scalars and numeric strings no longer throw', () {
      final change = WorkerMonitorChangeItem.fromJson(<String, dynamic>{
        'courseName': 101,
        'score': 95,
        'gpa': 4.5,
        'credit': true,
        'detectedAt': 1700000000,
        'term': <String, dynamic>{'bad': 'shape'},
      });
      expect(change.courseName, '101');
      expect(change.score, '95');
      expect(change.gpa, '4.5');
      expect(change.credit, 'true');
      expect(change.detectedAt, '1700000000');
      expect(change.term, '');

      final metrics = CloudTaskMetrics.fromJson(<String, dynamic>{
        'trackedItemCount': ' 12 ',
        'totalRuns': 'n/a',
        'changeCount': 'NaN',
      });
      expect(metrics.trackedItemCount, 12);
      expect(metrics.totalRuns, 0);
      expect(metrics.changeCount, 0);
    });
  });
}
