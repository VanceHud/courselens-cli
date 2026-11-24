/// 学生身份与学籍卡片信息。
class StudentIdentity {
  const StudentIdentity({
    this.name = '',
    this.studentId = '',
    this.department = '',
    this.major = '',
    this.className = '',
    this.grade = '',
  });

  final String name;
  final String studentId;
  final String department;
  final String major;
  final String className;
  final String grade;

  bool get isEmpty => name.trim().isEmpty && studentId.trim().isEmpty;

  /// 由 [grade] 或学号前缀推导四位入学年份（如 `2400000000` -> `2024`）。
  int? inferredEnrollmentYear({int? maxYear}) {
    final explicit = int.tryParse(grade.trim());
    if (explicit != null && explicit >= 1990 && explicit <= 2100) {
      if (maxYear == null || explicit <= maxYear) return explicit;
    }
    final id = studentId.trim();
    if (id.length >= 4) {
      final four = int.tryParse(id.substring(0, 4));
      if (four != null && four >= 2000 && four <= (maxYear ?? 2099)) {
        return four;
      }
    }
    if (id.length >= 10 && RegExp(r'^\d+$').hasMatch(id)) {
      final two = int.tryParse(id.substring(0, 2));
      if (two != null) {
        final candidate = 2000 + two;
        final upper = maxYear ?? 2099;
        if (candidate >= 2000 &&
            candidate <= upper &&
            (maxYear == null || candidate >= maxYear - 8)) {
          return candidate;
        }
      }
    }
    return null;
  }

  StudentIdentity merge(StudentIdentity fallback) => StudentIdentity(
        name: name.trim().isNotEmpty ? name : fallback.name,
        studentId: studentId.trim().isNotEmpty ? studentId : fallback.studentId,
        department:
            department.trim().isNotEmpty ? department : fallback.department,
        major: major.trim().isNotEmpty ? major : fallback.major,
        className:
            className.trim().isNotEmpty ? className : fallback.className,
        grade: grade.trim().isNotEmpty ? grade : fallback.grade,
      );

  StudentIdentity copyWith({
    String? name,
    String? studentId,
    String? department,
    String? major,
    String? className,
    String? grade,
  }) =>
      StudentIdentity(
        name: name ?? this.name,
        studentId: studentId ?? this.studentId,
        department: department ?? this.department,
        major: major ?? this.major,
        className: className ?? this.className,
        grade: grade ?? this.grade,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'studentId': studentId,
        'department': department,
        'major': major,
        'className': className,
        'grade': grade,
      };

  factory StudentIdentity.fromJson(Map<String, dynamic> json) =>
      StudentIdentity(
        name: json['name'] as String? ?? '',
        studentId: json['studentId'] as String? ?? '',
        department: json['department'] as String? ?? '',
        major: json['major'] as String? ?? '',
        className: json['className'] as String? ?? '',
        grade: json['grade'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StudentIdentity &&
          name == other.name &&
          studentId == other.studentId &&
          department == other.department &&
          major == other.major &&
          className == other.className &&
          grade == other.grade;

  @override
  int get hashCode => Object.hash(
        name,
        studentId,
        department,
        major,
        className,
        grade,
      );

  @override
  String toString() =>
      'StudentIdentity(name: $name, studentId: $studentId, department: $department, className: $className, grade: $grade)';
}
