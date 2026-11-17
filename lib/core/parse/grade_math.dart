import '../model/grades.dart';

/// 成绩的等级换算、多轮修读去重、加权绩点/加权平均分与分类学分统计（定点 HALF_UP 舍入）。
class GradeMath {
  const GradeMath._();

  static const double _passMark = 60.0;

  static const Map<String, double> _levelValues = {
    '优秀': 95.0,
    '优': 95.0,
    '良好': 85.0,
    '良': 85.0,
    '中等': 75.0,
    '中': 75.0,
    '及格': 60.0,
    '合格': 60.0,
    '通过': 60.0,
    '不及格': 0.0,
    '不合格': 0.0,
    '未通过': 0.0,
  };

  static double? score(String value) {
    final trimmed = value.trim();
    return double.tryParse(trimmed) ?? _levelValues[trimmed];
  }

  static double? effectiveScore(GradeEntry entry) {
    final numeric = entry.numericScore.trim();
    if (numeric.isNotEmpty) {
      final parsed = double.tryParse(numeric);
      if (parsed != null) return parsed;
    }
    return score(entry.score);
  }

  static bool isPassed(GradeEntry entry) {
    final s = effectiveScore(entry);
    if (s != null) return s >= _passMark;
    final gp = double.tryParse(entry.gradePoint.trim());
    return gp != null && gp > 0.0;
  }

  /// 按 `courseCode` 对同一门课的初修/补考/重修去重，保留最优有效记录；
  /// 无 `courseCode` 的记录（如 HTML 表格或最小化测试夹具）保持逐行独立。
  static List<GradeEntry> deduplicateCourses(List<GradeEntry> grades) {
    if (grades.isEmpty) return const <GradeEntry>[];
    final result = <GradeEntry>[];
    final indexByCode = <String, int>{};

    for (final entry in grades) {
      final code = entry.courseCode.trim();
      if (code.isEmpty) {
        result.add(entry);
        continue;
      }
      final existingIndex = indexByCode[code];
      if (existingIndex == null) {
        indexByCode[code] = result.length;
        result.add(entry);
      } else if (_isBetterAttempt(entry, result[existingIndex])) {
        result[existingIndex] = entry;
      }
    }
    return result;
  }

  static bool _isBetterAttempt(GradeEntry candidate, GradeEntry current) {
    final candPass = isPassed(candidate);
    final currPass = isPassed(current);
    if (candPass != currPass) return candPass;

    final candGp = double.tryParse(candidate.gradePoint.trim()) ?? -1.0;
    final currGp = double.tryParse(current.gradePoint.trim()) ?? -1.0;
    if (candGp != currGp) return candGp > currGp;

    final candScore = effectiveScore(candidate) ?? -1.0;
    final currScore = effectiveScore(current) ?? -1.0;
    return candScore > currScore;
  }

  /// 为 [GradeReport] 补全加权平均分、必修绩点、已获/修读学分与分类学分统计。
  static GradeReport enrichReport(GradeReport report) {
    final summary = summarize(report);
    return GradeReport(
      grades: report.grades,
      gradePointAverageRaw: report.gradePointAverageRaw,
      totalCreditsRaw: report.totalCreditsRaw,
      weightedAverageScore: summary.weightedAverageScore,
      compulsoryGpa: summary.compulsoryGpa,
      earnedCredits: summary.earnedCredits,
      attemptedCredits: summary.attemptedCredits,
      creditsByCategory: summary.creditsByCategory,
    );
  }

  static GradeSummary summarize(GradeReport report) {
    final deduped = deduplicateCourses(report.grades);

    final weightedPoints = <(double, double)>[];
    final compulsoryPoints = <(double, double)>[];
    final weightedScores = <(double, double)>[];
    final distribution = <double>[];
    final creditsByCategory = <String, double>{};
    var earnedCredits = 0.0;
    var attemptedCredits = 0.0;

    for (final entry in deduped) {
      final credits = double.tryParse(entry.credits.trim());
      final point = double.tryParse(entry.gradePoint.trim());
      final s = effectiveScore(entry);
      final passed = isPassed(entry);

      if (s != null) distribution.add(s);

      if (credits != null && credits > 0) {
        attemptedCredits += credits;
        if (point != null) {
          weightedPoints.add((credits, point));
          if (entry.category.contains('必修')) {
            compulsoryPoints.add((credits, point));
          }
        }
        if (s != null) {
          weightedScores.add((credits, s));
        }
        if (passed) {
          earnedCredits += credits;
          final category = entry.category.trim();
          if (category.isNotEmpty) {
            creditsByCategory[category] =
                (creditsByCategory[category] ?? 0.0) + credits;
          }
        }
      }
    }

    return GradeSummary(
      gpaText: _reportedOrComputedGpa(report, weightedPoints),
      creditsText: _reportedOrComputedCredits(report, earnedCredits, deduped),
      courseCount: deduped.length,
      excellent: distribution.where((s) => s >= 90).length,
      good: distribution.where((s) => s >= 80 && s < 90).length,
      medium: distribution.where((s) => s >= 70 && s < 80).length,
      pass: distribution.where((s) => s >= _passMark && s < 70).length,
      weightedAverageScore: _weightedMeanText(weightedScores, 2),
      compulsoryGpa: _weightedMeanText(compulsoryPoints, 2),
      earnedCredits: earnedCredits,
      attemptedCredits: attemptedCredits,
      creditsByCategory: Map<String, double>.unmodifiable(creditsByCategory),
    );
  }

  static String _weightedMeanText(
    List<(double, double)> pairs,
    int digits,
  ) {
    var totalCredits = 0.0;
    var weightedSum = 0.0;
    for (final (c, v) in pairs) {
      totalCredits += c;
      weightedSum += c * v;
    }
    if (totalCredits <= 0.0) return '--';
    return formatFixed(weightedSum / totalCredits, digits);
  }

  static String _reportedOrComputedGpa(
    GradeReport report,
    List<(double, double)> weighted,
  ) {
    final raw = report.gradePointAverageRaw.trim();
    if (raw.isNotEmpty) return raw;
    return _weightedMeanText(weighted, 2);
  }

  static String _reportedOrComputedCredits(
    GradeReport report,
    double earnedCredits,
    List<GradeEntry> deduped,
  ) {
    final raw = report.totalCreditsRaw.trim();
    if (raw.isNotEmpty) return raw;
    final hasAnyPassedCredit = deduped.any(
      (entry) =>
          isPassed(entry) && (double.tryParse(entry.credits.trim()) ?? 0) > 0,
    );
    if (!hasAnyPassedCredit) return '--';
    return formatFixed(earnedCredits, 1);
  }

  /// 定点 HALF_UP 格式化，等价于 Java `%.{digits}f`。
  static String formatFixed(double value, int digits) {
    if (value.isNaN || value.isInfinite) return '--';
    final scale = _powerOfTen(digits);
    final negative = value < 0;
    final ticks = (value.abs() * scale + 0.5).floor();
    final whole = ticks ~/ scale;
    final sign = (negative && ticks != 0) ? '-' : '';
    if (digits <= 0) return '$sign$whole';
    final fraction = (ticks % scale).toString().padLeft(digits, '0');
    return '$sign$whole.$fraction';
  }

  static int _powerOfTen(int exponent) {
    var scale = 1;
    for (var i = 0; i < exponent; i++) {
      scale *= 10;
    }
    return scale;
  }
}
