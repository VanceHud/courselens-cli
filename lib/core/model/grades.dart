/// 单项成绩分项明细（如 `作业(50%)` -> `88.1`）。
class GradeSubItem {
  const GradeSubItem({
    required this.name,
    required this.score,
  });

  final String name;
  final String score;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'score': score,
      };

  factory GradeSubItem.fromJson(Map<String, dynamic> json) => GradeSubItem(
        name: json['name'] as String? ?? '',
        score: json['score'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GradeSubItem && name == other.name && score == other.score;

  @override
  int get hashCode => Object.hash(name, score);

  @override
  String toString() => 'GradeSubItem($name: $score)';
}

/// 一条成绩记录（保留学校返回的原始文本与绩点，绝不二次覆盖补考封顶绩点）。
class GradeEntry {
  const GradeEntry({
    required this.name,
    required this.score,
    required this.credits,
    required this.gradePoint,
    required this.term,
    this.detail = '',
    this.courseCode = '',
    this.jxbId = '',
    this.numericScore = '',
    this.category = '',
    this.examNature = '',
    this.teacher = '',
    this.department = '',
    this.subItems = const <GradeSubItem>[],
  });

  final String name;
  final String score;
  final String credits;
  final String gradePoint;
  final String term;
  final String detail;
  final String courseCode;
  final String jxbId;
  final String numericScore;
  final String category;
  final String examNature;
  final String teacher;
  final String department;
  final List<GradeSubItem> subItems;

  bool get isMakeup => examNature.contains('补考');
  bool get isRetake => examNature.contains('重修');

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'score': score,
        'credits': credits,
        'gradePoint': gradePoint,
        'term': term,
        'detail': detail,
        'courseCode': courseCode,
        'jxbId': jxbId,
        'numericScore': numericScore,
        'category': category,
        'examNature': examNature,
        'teacher': teacher,
        'department': department,
        if (subItems.isNotEmpty)
          'subItems': subItems.map((s) => s.toJson()).toList(growable: false),
      };

  factory GradeEntry.fromJson(Map<String, dynamic> json) {
    final rawSub = json['subItems'];
    final subs = <GradeSubItem>[];
    if (rawSub is List) {
      for (final item in rawSub) {
        if (item is Map) {
          subs.add(GradeSubItem.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return GradeEntry(
      name: json['name'] as String? ?? '',
      score: json['score'] as String? ?? '',
      credits: json['credits'] as String? ?? '',
      gradePoint: json['gradePoint'] as String? ?? '',
      term: json['term'] as String? ?? '',
      detail: json['detail'] as String? ?? '',
      courseCode: json['courseCode'] as String? ?? '',
      jxbId: json['jxbId'] as String? ?? '',
      numericScore: json['numericScore'] as String? ?? '',
      category: json['category'] as String? ?? '',
      examNature: json['examNature'] as String? ?? '',
      teacher: json['teacher'] as String? ?? '',
      department: json['department'] as String? ?? '',
      subItems: List<GradeSubItem>.unmodifiable(subs),
    );
  }

  GradeEntry copyWith({
    String? name,
    String? score,
    String? credits,
    String? gradePoint,
    String? term,
    String? detail,
    String? courseCode,
    String? jxbId,
    String? numericScore,
    String? category,
    String? examNature,
    String? teacher,
    String? department,
    List<GradeSubItem>? subItems,
  }) =>
      GradeEntry(
        name: name ?? this.name,
        score: score ?? this.score,
        credits: credits ?? this.credits,
        gradePoint: gradePoint ?? this.gradePoint,
        term: term ?? this.term,
        detail: detail ?? this.detail,
        courseCode: courseCode ?? this.courseCode,
        jxbId: jxbId ?? this.jxbId,
        numericScore: numericScore ?? this.numericScore,
        category: category ?? this.category,
        examNature: examNature ?? this.examNature,
        teacher: teacher ?? this.teacher,
        department: department ?? this.department,
        subItems: subItems ?? this.subItems,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! GradeEntry) return false;
    if (name != other.name ||
        score != other.score ||
        credits != other.credits ||
        gradePoint != other.gradePoint ||
        term != other.term ||
        detail != other.detail ||
        courseCode != other.courseCode ||
        jxbId != other.jxbId ||
        numericScore != other.numericScore ||
        category != other.category ||
        examNature != other.examNature ||
        teacher != other.teacher ||
        department != other.department ||
        subItems.length != other.subItems.length) {
      return false;
    }
    for (var i = 0; i < subItems.length; i++) {
      if (subItems[i] != other.subItems[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        name,
        score,
        credits,
        gradePoint,
        term,
        detail,
        courseCode,
        jxbId,
        numericScore,
        category,
        examNature,
        teacher,
        department,
        Object.hashAll(subItems),
      );
}

/// 一个学期或全部学期的成绩集合及汇总指标。
class GradeReport {
  GradeReport({
    required List<GradeEntry> grades,
    this.gradePointAverageRaw = '',
    this.totalCreditsRaw = '',
    this.weightedAverageScore = '--',
    this.compulsoryGpa = '--',
    this.earnedCredits = 0.0,
    this.attemptedCredits = 0.0,
    Map<String, double> creditsByCategory = const <String, double>{},
  })  : grades = List.unmodifiable(grades),
        creditsByCategory = Map.unmodifiable(creditsByCategory);

  final List<GradeEntry> grades;
  final String gradePointAverageRaw;
  final String totalCreditsRaw;
  final String weightedAverageScore;
  final String compulsoryGpa;
  final double earnedCredits;
  final double attemptedCredits;
  final Map<String, double> creditsByCategory;

  Map<String, Object?> toJson() => <String, Object?>{
        'grades': grades.map((g) => g.toJson()).toList(growable: false),
        'gradePointAverageRaw': gradePointAverageRaw,
        'totalCreditsRaw': totalCreditsRaw,
        'weightedAverageScore': weightedAverageScore,
        'compulsoryGpa': compulsoryGpa,
        'earnedCredits': earnedCredits,
        'attemptedCredits': attemptedCredits,
        'creditsByCategory': creditsByCategory,
      };

  factory GradeReport.fromJson(Map<String, dynamic> json) {
    final rawGrades = json['grades'];
    final list = <GradeEntry>[];
    if (rawGrades is List) {
      for (final item in rawGrades) {
        if (item is Map) {
          list.add(GradeEntry.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    final rawCat = json['creditsByCategory'];
    final cats = <String, double>{};
    if (rawCat is Map) {
      for (final entry in rawCat.entries) {
        final v = (entry.value as num?)?.toDouble();
        if (v != null) cats[entry.key.toString()] = v;
      }
    }
    return GradeReport(
      grades: list,
      gradePointAverageRaw: json['gradePointAverageRaw'] as String? ?? '',
      totalCreditsRaw: json['totalCreditsRaw'] as String? ?? '',
      weightedAverageScore: json['weightedAverageScore'] as String? ?? '--',
      compulsoryGpa: json['compulsoryGpa'] as String? ?? '--',
      earnedCredits: (json['earnedCredits'] as num?)?.toDouble() ?? 0.0,
      attemptedCredits: (json['attemptedCredits'] as num?)?.toDouble() ?? 0.0,
      creditsByCategory: cats,
    );
  }
}

/// 成绩总览统计。
class GradeSummary {
  const GradeSummary({
    required this.gpaText,
    required this.creditsText,
    required this.courseCount,
    required this.excellent,
    required this.good,
    required this.medium,
    required this.pass,
    this.weightedAverageScore = '--',
    this.compulsoryGpa = '--',
    this.earnedCredits = 0.0,
    this.attemptedCredits = 0.0,
    this.creditsByCategory = const <String, double>{},
  });

  final String gpaText;
  final String creditsText;
  final int courseCount;
  final int excellent;
  final int good;
  final int medium;
  final int pass;
  final String weightedAverageScore;
  final String compulsoryGpa;
  final double earnedCredits;
  final double attemptedCredits;
  final Map<String, double> creditsByCategory;

  int get failing => courseCount - excellent - good - medium - pass;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GradeSummary &&
          gpaText == other.gpaText &&
          creditsText == other.creditsText &&
          courseCount == other.courseCount &&
          excellent == other.excellent &&
          good == other.good &&
          medium == other.medium &&
          pass == other.pass &&
          weightedAverageScore == other.weightedAverageScore &&
          compulsoryGpa == other.compulsoryGpa &&
          earnedCredits == other.earnedCredits &&
          attemptedCredits == other.attemptedCredits;

  @override
  int get hashCode => Object.hash(
        gpaText,
        creditsText,
        courseCount,
        excellent,
        good,
        medium,
        pass,
        weightedAverageScore,
        compulsoryGpa,
        earnedCredits,
        attemptedCredits,
      );
}
