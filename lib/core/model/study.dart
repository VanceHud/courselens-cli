/// 一条考试安排（保留学校原始文本，并提供结构化日期与起止时间）。
class ExamEntry {
  const ExamEntry({
    required this.name,
    required this.time,
    required this.location,
    this.seat = '',
    this.examName = '',
    this.teacher = '',
    this.termId = '',
    this.campus = '',
    this.examMethod = '',
    this.credits = '',
    this.courseCode = '',
    this.examDate = '',
    this.startTime = '',
    this.endTime = '',
  });

  final String name;
  final String time;
  final String location;
  final String seat;
  final String examName;
  final String teacher;
  final String termId;
  final String campus;
  final String examMethod;
  final String credits;
  final String courseCode;
  final String examDate;
  final String startTime;
  final String endTime;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'time': time,
        'location': location,
        'seat': seat,
        'examName': examName,
        'teacher': teacher,
        'termId': termId,
        'campus': campus,
        'examMethod': examMethod,
        'credits': credits,
        'courseCode': courseCode,
        'examDate': examDate,
        'startTime': startTime,
        'endTime': endTime,
      };

  factory ExamEntry.fromJson(Map<String, dynamic> json) => ExamEntry(
        name: json['name'] as String? ?? '',
        time: json['time'] as String? ?? '',
        location: json['location'] as String? ?? '',
        seat: json['seat'] as String? ?? '',
        examName: json['examName'] as String? ?? '',
        teacher: json['teacher'] as String? ?? '',
        termId: json['termId'] as String? ?? '',
        campus: json['campus'] as String? ?? '',
        examMethod: json['examMethod'] as String? ?? '',
        credits: json['credits'] as String? ?? '',
        courseCode: json['courseCode'] as String? ?? '',
        examDate: json['examDate'] as String? ?? '',
        startTime: json['startTime'] as String? ?? '',
        endTime: json['endTime'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExamEntry &&
          name == other.name &&
          time == other.time &&
          location == other.location &&
          seat == other.seat &&
          examName == other.examName &&
          teacher == other.teacher &&
          termId == other.termId &&
          campus == other.campus &&
          examMethod == other.examMethod &&
          credits == other.credits &&
          courseCode == other.courseCode &&
          examDate == other.examDate &&
          startTime == other.startTime &&
          endTime == other.endTime;

  @override
  int get hashCode => Object.hash(
        name,
        time,
        location,
        seat,
        examName,
        teacher,
        termId,
        campus,
        examMethod,
        credits,
        courseCode,
        examDate,
        startTime,
        endTime,
      );
}
