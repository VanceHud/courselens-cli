import 'academic_status.dart';

/// 选课轮次/分类。
class CourseScope {
  const CourseScope({
    required this.id,
    required this.name,
    this.term = '',
  });

  final String id;
  final String name;
  final String term;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CourseScope &&
          id == other.id &&
          name == other.name &&
          term == other.term;

  @override
  int get hashCode => Object.hash(id, name, term);
}

/// 一门可选课程。
///
/// [capacity] 与 [selected] 采用可空类型严格区分「0 人余量」与「学校未提供余量字段」。
class CourseOffer {
  const CourseOffer({
    required this.id,
    required this.name,
    this.teacher = '',
    this.time = '',
    this.location = '',
    this.credit = '',
    this.capacity,
    this.selected,
    this.scopeId = '',
  });

  final String id;
  final String name;
  final String teacher;
  final String time;
  final String location;
  final String credit;
  final int? capacity;
  final int? selected;
  final String scopeId;

  int? get remaining =>
      capacity != null && selected != null ? capacity! - selected! : null;

  bool get isFull => remaining != null && remaining! <= 0;

  String get remainingText => remaining?.toString() ?? '未知';
}

/// 一门课的一个教学班（选课提交的真正目标）。
class CourseSection {
  const CourseSection({
    required this.id,
    required this.courseId,
    this.name = '',
    this.teacher = '',
    this.time = '',
    this.location = '',
    this.capacity,
    this.selected,
  });

  final String id;
  final String courseId;
  final String name;
  final String teacher;
  final String time;
  final String location;
  final int? capacity;
  final int? selected;

  int? get remaining =>
      capacity != null && selected != null ? capacity! - selected! : null;

  bool get isFull => remaining != null && remaining! <= 0;

  String get remainingText => remaining?.toString() ?? '未知';

  String get label {
    final parts = [teacher, time, name]
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return parts.isEmpty ? id : parts.join(' · ');
  }
}

/// 一条已选课程。
class SelectedCourse {
  const SelectedCourse({
    required this.id,
    required this.name,
    this.teacher = '',
    this.courseId = '',
    this.sectionId = '',
    this.time = '',
    this.location = '',
  });

  final String id;
  final String name;
  final String teacher;
  final String courseId;
  final String sectionId;
  final String time;
  final String location;
}

/// 一次选课/退课的结局。
class SelectionOutcome {
  const SelectionOutcome(
    this.status, [
    this.message = '',
    this.courseName = '',
    this.sectionId = '',
  ]);

  final AcademicStatus status;
  final String message;
  final String courseName;
  final String sectionId;

  bool get isSuccess =>
      status == AcademicStatus.SUCCESS ||
      status == AcademicStatus.ALREADY_SELECTED;

  bool get blocksFurtherActions => const {
        AcademicStatus.SESSION_EXPIRED,
        AcademicStatus.INVALID_CREDENTIALS,
        AcademicStatus.CAPTCHA_REQUIRED,
        AcademicStatus.HUMAN_VERIFICATION_REQUIRED,
        AcademicStatus.RESULT_UNKNOWN,
        AcademicStatus.UNTRUSTED_URL,
        AcademicStatus.PAGE_CHANGED,
        AcademicStatus.UNSUPPORTED,
      }.contains(status);
}
