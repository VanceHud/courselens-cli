/// 课程查询条件。
class CourseQuery {
  const CourseQuery({
    this.keyword = '',
    this.teacher = '',
    this.start = 0,
    this.pageSize = 50,
    this.scopeId = '',
  });

  final String keyword;
  final String teacher;
  final int start;
  final int pageSize;
  final String scopeId;
}
