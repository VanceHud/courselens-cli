/// 学业进度与培养方案分类节点（来自 `xsxy/xsxyqk_cxXsxyqkIndex.html`）。
class CreditCategoryNode {
  const CreditCategoryNode({
    required this.id,
    required this.name,
    this.parentId = '',
    this.isLeaf = false,
    this.earnedCredits,
    this.requiredCredits,
    this.remainingCredits,
    this.passed = false,
  });

  final String id;
  final String parentId;
  final String name;
  final bool isLeaf;
  final double? earnedCredits;
  final double? requiredCredits;
  final double? remainingCredits;
  final bool passed;

  double get completionRatio {
    final req = requiredCredits;
    final earned = earnedCredits;
    if (req == null || req <= 0 || earned == null) return 0.0;
    final ratio = earned / req;
    if (ratio < 0.0) return 0.0;
    if (ratio > 1.0) return 1.0;
    return ratio;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'parentId': parentId,
        'name': name,
        'isLeaf': isLeaf,
        if (earnedCredits != null) 'earnedCredits': earnedCredits,
        if (requiredCredits != null) 'requiredCredits': requiredCredits,
        if (remainingCredits != null) 'remainingCredits': remainingCredits,
        'passed': passed,
      };

  factory CreditCategoryNode.fromJson(Map<String, dynamic> json) =>
      CreditCategoryNode(
        id: json['id'] as String? ?? '',
        parentId: json['parentId'] as String? ?? '',
        name: json['name'] as String? ?? '',
        isLeaf: json['isLeaf'] == true,
        earnedCredits: (json['earnedCredits'] as num?)?.toDouble(),
        requiredCredits: (json['requiredCredits'] as num?)?.toDouble(),
        remainingCredits: (json['remainingCredits'] as num?)?.toDouble(),
        passed: json['passed'] == true,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CreditCategoryNode &&
          id == other.id &&
          parentId == other.parentId &&
          name == other.name &&
          isLeaf == other.isLeaf &&
          earnedCredits == other.earnedCredits &&
          requiredCredits == other.requiredCredits &&
          remainingCredits == other.remainingCredits &&
          passed == other.passed;

  @override
  int get hashCode => Object.hash(
        id,
        parentId,
        name,
        isLeaf,
        earnedCredits,
        requiredCredits,
        remainingCredits,
        passed,
      );
}

/// 学业情况查询总览（学校权威 GPA、计划课程门数统计与模块学分树）。
class AcademicProgressReport {
  AcademicProgressReport({
    this.officialGpa = '',
    this.totalCourses = 0,
    this.passedCourses = 0,
    this.failedCourses = 0,
    this.unstudiedCourses = 0,
    this.inProgressCourses = 0,
    this.outsidePlanPassedCourses = 0,
    this.studentId = '',
    this.cjlrxn = '',
    this.cjlrxq = '',
    Map<String, String> hiddenParams = const <String, String>{},
    List<CreditCategoryNode> categories = const <CreditCategoryNode>[],
  })  : hiddenParams = Map.unmodifiable(hiddenParams),
        categories = List.unmodifiable(categories);

  final String officialGpa;
  final int totalCourses;
  final int passedCourses;
  final int failedCourses;
  final int unstudiedCourses;
  final int inProgressCourses;
  final int outsidePlanPassedCourses;
  final String studentId;
  final String cjlrxn;
  final String cjlrxq;
  final Map<String, String> hiddenParams;
  final List<CreditCategoryNode> categories;

  List<CreditCategoryNode> get leafCategories =>
      categories.where((c) => c.isLeaf).toList(growable: false);

  Map<String, Object?> toJson() => <String, Object?>{
        'officialGpa': officialGpa,
        'totalCourses': totalCourses,
        'passedCourses': passedCourses,
        'failedCourses': failedCourses,
        'unstudiedCourses': unstudiedCourses,
        'inProgressCourses': inProgressCourses,
        'outsidePlanPassedCourses': outsidePlanPassedCourses,
        'studentId': studentId,
        'cjlrxn': cjlrxn,
        'cjlrxq': cjlrxq,
        'hiddenParams': hiddenParams,
        'categories': categories.map((c) => c.toJson()).toList(growable: false),
      };

  factory AcademicProgressReport.fromJson(Map<String, dynamic> json) {
    final rawHidden = json['hiddenParams'];
    final hidden = <String, String>{};
    if (rawHidden is Map) {
      for (final entry in rawHidden.entries) {
        hidden[entry.key.toString()] = entry.value?.toString() ?? '';
      }
    }
    final rawCats = json['categories'];
    final cats = <CreditCategoryNode>[];
    if (rawCats is List) {
      for (final item in rawCats) {
        if (item is Map) {
          cats.add(
            CreditCategoryNode.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    return AcademicProgressReport(
      officialGpa: json['officialGpa'] as String? ?? '',
      totalCourses: (json['totalCourses'] as num?)?.toInt() ?? 0,
      passedCourses: (json['passedCourses'] as num?)?.toInt() ?? 0,
      failedCourses: (json['failedCourses'] as num?)?.toInt() ?? 0,
      unstudiedCourses: (json['unstudiedCourses'] as num?)?.toInt() ?? 0,
      inProgressCourses: (json['inProgressCourses'] as num?)?.toInt() ?? 0,
      outsidePlanPassedCourses:
          (json['outsidePlanPassedCourses'] as num?)?.toInt() ?? 0,
      studentId: json['studentId'] as String? ?? '',
      cjlrxn: json['cjlrxn'] as String? ?? '',
      cjlrxq: json['cjlrxq'] as String? ?? '',
      hiddenParams: hidden,
      categories: cats,
    );
  }
}

/// 培养方案课程修读状态（对应 `XDZT`：4=已通过、1=在读、2=未通过、3=未修）。
enum PlanCourseStatus {
  passed('4', '已通过'),
  inProgress('1', '在读'),
  failed('2', '未通过'),
  unstudied('3', '未修'),
  unknown('', '未知');

  const PlanCourseStatus(this.code, this.label);

  final String code;
  final String label;

  static PlanCourseStatus fromCode(String raw) => switch (raw.trim()) {
        '4' => PlanCourseStatus.passed,
        '1' => PlanCourseStatus.inProgress,
        '2' => PlanCourseStatus.failed,
        '3' => PlanCourseStatus.unstudied,
        _ => PlanCourseStatus.unknown,
      };
}

/// 培养方案模块下的单门计划课程（来自 `xsxy/xsxyqk_cxJxzxjhxfyqKcxx.html`）。
class PlanCourseEntry {
  const PlanCourseEntry({
    required this.courseCode,
    required this.courseName,
    this.credits = '',
    this.category = '',
    this.courseType = '',
    this.status = PlanCourseStatus.unknown,
    this.recommendedTerm = '',
    this.maxScore = '',
    this.score = '',
    this.makeupScore = '',
    this.retakeScore = '',
    this.gpa = '',
  });

  final String courseCode;
  final String courseName;
  final String credits;
  final String category;
  final String courseType;
  final PlanCourseStatus status;
  final String recommendedTerm;
  final String maxScore;
  final String score;
  final String makeupScore;
  final String retakeScore;
  final String gpa;

  Map<String, Object?> toJson() => <String, Object?>{
        'courseCode': courseCode,
        'courseName': courseName,
        'credits': credits,
        'category': category,
        'courseType': courseType,
        'statusCode': status.code,
        'recommendedTerm': recommendedTerm,
        'maxScore': maxScore,
        'score': score,
        'makeupScore': makeupScore,
        'retakeScore': retakeScore,
        'gpa': gpa,
      };

  factory PlanCourseEntry.fromJson(Map<String, dynamic> json) =>
      PlanCourseEntry(
        courseCode: json['courseCode'] as String? ?? '',
        courseName: json['courseName'] as String? ?? '',
        credits: json['credits'] as String? ?? '',
        category: json['category'] as String? ?? '',
        courseType: json['courseType'] as String? ?? '',
        status: PlanCourseStatus.fromCode(json['statusCode'] as String? ?? ''),
        recommendedTerm: json['recommendedTerm'] as String? ?? '',
        maxScore: json['maxScore'] as String? ?? '',
        score: json['score'] as String? ?? '',
        makeupScore: json['makeupScore'] as String? ?? '',
        retakeScore: json['retakeScore'] as String? ?? '',
        gpa: json['gpa'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlanCourseEntry &&
          courseCode == other.courseCode &&
          courseName == other.courseName &&
          credits == other.credits &&
          category == other.category &&
          courseType == other.courseType &&
          status == other.status &&
          recommendedTerm == other.recommendedTerm &&
          maxScore == other.maxScore &&
          score == other.score &&
          makeupScore == other.makeupScore &&
          retakeScore == other.retakeScore &&
          gpa == other.gpa;

  @override
  int get hashCode => Object.hash(
        courseCode,
        courseName,
        credits,
        category,
        courseType,
        status,
        recommendedTerm,
        maxScore,
        score,
        makeupScore,
        retakeScore,
        gpa,
      );
}

/// 校区选项（空教室/课表作息共用）。
class CampusOption {
  const CampusOption({required this.id, required this.name});

  final String id;
  final String name;

  Map<String, Object?> toJson() => <String, Object?>{'id': id, 'name': name};

  factory CampusOption.fromJson(Map<String, dynamic> json) => CampusOption(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CampusOption && id == other.id && name == other.name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// 教室类型选项。
class RoomTypeOption {
  const RoomTypeOption({required this.id, required this.name});

  final String id;
  final String name;

  Map<String, Object?> toJson() => <String, Object?>{'id': id, 'name': name};

  factory RoomTypeOption.fromJson(Map<String, dynamic> json) => RoomTypeOption(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RoomTypeOption && id == other.id && name == other.name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// 从教务空教室入口页动态解析得到的校区与教室类型元数据。
class EmptyClassroomFilterOptions {
  EmptyClassroomFilterOptions({
    List<CampusOption> campuses = const <CampusOption>[],
    List<RoomTypeOption> roomTypes = const <RoomTypeOption>[],
  })  : campuses = List.unmodifiable(campuses),
        roomTypes = List.unmodifiable(roomTypes);

  final List<CampusOption> campuses;
  final List<RoomTypeOption> roomTypes;

  bool get isEmpty => campuses.isEmpty && roomTypes.isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
        'campuses': campuses.map((c) => c.toJson()).toList(growable: false),
        'roomTypes': roomTypes.map((r) => r.toJson()).toList(growable: false),
      };

  factory EmptyClassroomFilterOptions.fromJson(Map<String, dynamic> json) {
    final rawCampuses = json['campuses'];
    final campuses = <CampusOption>[];
    if (rawCampuses is List) {
      for (final item in rawCampuses) {
        if (item is Map) {
          campuses.add(CampusOption.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    final rawTypes = json['roomTypes'];
    final roomTypes = <RoomTypeOption>[];
    if (rawTypes is List) {
      for (final item in rawTypes) {
        if (item is Map) {
          roomTypes
              .add(RoomTypeOption.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return EmptyClassroomFilterOptions(
      campuses: campuses,
      roomTypes: roomTypes,
    );
  }
}

/// 空闲教室查询参数（自动将教学周与节次闭区间编码为正方 `zcd` / `jcd` 位掩码）。
class EmptyClassroomQuery {
  const EmptyClassroomQuery({
    this.campusId = '',
    this.termId,
    this.week = 1,
    this.weeks = const <int>[],
    this.dayOfWeek = 1,
    this.daysOfWeek = const <int>[],
    this.startPeriod = 1,
    this.endPeriod = 2,
    this.building = '',
    this.roomTypeId = '',
    this.roomNameKeyword = '',
    this.minSeats,
    this.maxSeats,
    this.pageSize = 100,
    this.page = 1,
  });

  /// 通用高校默认校区选项（当教务未提供校区下拉或离线无预设时使用）。
  static const List<CampusOption> genericCampuses = <CampusOption>[
    CampusOption(id: '', name: '全部校区'),
  ];

  /// 通用新正方教室类型选项。
  static const List<RoomTypeOption> genericRoomTypes = <RoomTypeOption>[
    RoomTypeOption(id: '', name: '全部类型'),
    RoomTypeOption(id: '001', name: '多媒体教室'),
    RoomTypeOption(id: '006', name: '普通教室'),
    RoomTypeOption(id: '002', name: '机房'),
    RoomTypeOption(id: '003', name: '实验室'),
    RoomTypeOption(id: '007', name: '语音室'),
  ];

  /// 青岛科技大学预设校区列表（保留供 QUST 预设与历史测试兼容）。
  static const List<CampusOption> qustCampuses = <CampusOption>[
    CampusOption(id: '1', name: '四方校区'),
    CampusOption(id: '2', name: '崂山校区'),
    CampusOption(id: '3', name: '高密校区'),
    CampusOption(id: '6', name: '中德校区'),
    CampusOption(id: '4', name: '青岛两校区'),
    CampusOption(id: '5', name: '青科云校区'),
    CampusOption(id: 'F47F8EB55D6B9F4BE055000000000001', name: '淄博基地'),
  ];

  /// 青岛科技大学预设教室类型列表（保留供 QUST 预设与历史测试兼容）。
  static const List<RoomTypeOption> qustRoomTypes = <RoomTypeOption>[
    RoomTypeOption(id: '', name: '全部类型'),
    RoomTypeOption(id: '001', name: '多媒体教室'),
    RoomTypeOption(id: '006', name: '普通教室'),
    RoomTypeOption(id: '002', name: '机房'),
    RoomTypeOption(id: '003', name: '实验室'),
    RoomTypeOption(id: '007', name: '语音室'),
    RoomTypeOption(id: '008', name: '制图教室'),
    RoomTypeOption(id: '009', name: '录播室'),
    RoomTypeOption(id: '32B824CC53686E53E0630100007F356C', name: '考研自习室'),
  ];

  final String campusId;
  final String? termId;
  final int week;
  final List<int> weeks;
  final int dayOfWeek;
  final List<int> daysOfWeek;
  final int startPeriod;
  final int endPeriod;
  final String building;
  final String roomTypeId;
  final String roomNameKeyword;
  final int? minSeats;
  final int? maxSeats;
  final int pageSize;
  final int page;

  /// `zcd` 周次位掩码：$\sum 2^{\text{week}-1}$（采用 [BigInt] 避免 Web JS 32 位移位溢出）。
  String get zcdBitmask {
    final activeWeeks = weeks.isNotEmpty ? weeks : <int>[week];
    var mask = BigInt.zero;
    for (final w in activeWeeks) {
      if (w >= 1 && w <= 60) {
        mask |= BigInt.one << (w - 1);
      }
    }
    if (mask == BigInt.zero) {
      mask = BigInt.one;
    }
    return mask.toString();
  }

  /// `jcd` 节次位掩码：$\sum_{p=\text{start}}^{\text{end}} 2^{p-1}$。
  String get jcdBitmask {
    final lo = startPeriod.clamp(1, 30);
    final hi = endPeriod.clamp(lo, 30);
    var mask = BigInt.zero;
    for (var p = lo; p <= hi; p++) {
      mask |= BigInt.one << (p - 1);
    }
    return mask.toString();
  }

  /// `xqj` 星期参数（1..7，多天用逗号拼接）。
  String get xqjParam {
    final days = (daysOfWeek.isNotEmpty ? daysOfWeek : <int>[dayOfWeek])
        .where((d) => d >= 1 && d <= 7)
        .toSet()
        .toList()
      ..sort();
    if (days.isEmpty) return '1';
    return days.join(',');
  }
}

/// 一间空闲教室记录（来自 `cdjy/cdjy_cxKxcdlb.html`）。
class EmptyClassroom {
  const EmptyClassroom({
    required this.id,
    required this.code,
    required this.name,
    this.building = '',
    this.type = '',
    this.seats,
    this.examSeats,
    this.campus = '',
    this.department = '',
  });

  final String id;
  final String code;
  final String name;
  final String building;
  final String type;
  final int? seats;
  final int? examSeats;
  final String campus;
  final String department;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EmptyClassroom &&
          id == other.id &&
          code == other.code &&
          name == other.name &&
          building == other.building &&
          type == other.type &&
          seats == other.seats &&
          examSeats == other.examSeats &&
          campus == other.campus &&
          department == other.department;

  @override
  int get hashCode => Object.hash(
        id,
        code,
        name,
        building,
        type,
        seats,
        examSeats,
        campus,
        department,
      );
}

/// 全天候已选/配课名单条目（来自 `xkcx/xkmdcx_cxXkmdcxIndex.html`，严格剔除任何个人敏感字段）。
class EnrolledCourseEntry {
  const EnrolledCourseEntry({
    required this.courseCode,
    required this.courseName,
    this.teachingClass = '',
    this.jxbId = '',
    this.teacher = '',
    this.credits = '',
    this.scheduleText = '',
    this.location = '',
    this.campus = '',
    this.weeksText = '',
    this.category = '',
    this.courseType = '',
    this.selectionStatus = '',
    this.isRetake = false,
    this.termId = '',
  });

  final String courseCode;
  final String courseName;
  final String teachingClass;
  final String jxbId;
  final String teacher;
  final String credits;
  final String scheduleText;
  final String location;
  final String campus;
  final String weeksText;
  final String category;
  final String courseType;
  final String selectionStatus;
  final bool isRetake;
  final String termId;

  Map<String, Object?> toJson() => <String, Object?>{
        'courseCode': courseCode,
        'courseName': courseName,
        'teachingClass': teachingClass,
        'jxbId': jxbId,
        'teacher': teacher,
        'credits': credits,
        'scheduleText': scheduleText,
        'location': location,
        'campus': campus,
        'weeksText': weeksText,
        'category': category,
        'courseType': courseType,
        'selectionStatus': selectionStatus,
        'isRetake': isRetake,
        'termId': termId,
      };

  factory EnrolledCourseEntry.fromJson(Map<String, dynamic> json) =>
      EnrolledCourseEntry(
        courseCode: json['courseCode'] as String? ?? '',
        courseName: json['courseName'] as String? ?? '',
        teachingClass: json['teachingClass'] as String? ?? '',
        jxbId: json['jxbId'] as String? ?? '',
        teacher: json['teacher'] as String? ?? '',
        credits: json['credits'] as String? ?? '',
        scheduleText: json['scheduleText'] as String? ?? '',
        location: json['location'] as String? ?? '',
        campus: json['campus'] as String? ?? '',
        weeksText: json['weeksText'] as String? ?? '',
        category: json['category'] as String? ?? '',
        courseType: json['courseType'] as String? ?? '',
        selectionStatus: json['selectionStatus'] as String? ?? '',
        isRetake: json['isRetake'] == true,
        termId: json['termId'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EnrolledCourseEntry &&
          courseCode == other.courseCode &&
          courseName == other.courseName &&
          teachingClass == other.teachingClass &&
          jxbId == other.jxbId &&
          teacher == other.teacher &&
          credits == other.credits &&
          scheduleText == other.scheduleText &&
          location == other.location &&
          campus == other.campus &&
          weeksText == other.weeksText &&
          category == other.category &&
          courseType == other.courseType &&
          selectionStatus == other.selectionStatus &&
          isRetake == other.isRetake &&
          termId == other.termId;

  @override
  int get hashCode => Object.hash(
        courseCode,
        courseName,
        teachingClass,
        jxbId,
        teacher,
        credits,
        scheduleText,
        location,
        campus,
        weeksText,
        category,
        courseType,
        selectionStatus,
        isRetake,
        termId,
      );
}
