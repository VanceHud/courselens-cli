import '../model/grades.dart';
import '../parse/grades_html.dart';

/// 从成绩记录中反推学期列表（倒序）。
class StudyTerms {
  const StudyTerms._();

  static List<String> semesters(List<GradeEntry> grades) {
    final unique = <String>{};
    for (final g in grades) {
      final t = GradesHtml.term(g.term);
      if (t != null) unique.add(t);
    }
    final sorted = unique.toList()..sort((a, b) => b.compareTo(a));
    return sorted;
  }
}
