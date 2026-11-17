import 'package:html/dom.dart';

import '../model/academic_status.dart';
import '../model/course_query.dart';
import '../model/selection.dart';
import '../parse/academic_json.dart';
import '../parse/html.dart';
import '../study/study_transport.dart';

class _Scope {
  const _Scope({
    required this.id,
    required this.name,
    required this.term,
    required this.listUrl,
    required this.selectUrl,
    required this.params,
  });

  final String id;
  final String name;
  final String term;
  final String listUrl;
  final String selectUrl;
  final Map<String, String> params;
}

class _Offer {
  const _Offer(this.model, this.raw);

  final CourseOffer model;
  final Map<String, String> raw;
}

class _Section {
  const _Section(this.model, this.raw);

  final CourseSection model;
  final Map<String, String> raw;
}

class _Category {
  const _Category({
    required this.category,
    required this.round,
    required this.grade,
    required this.major,
    this.roundXh = '',
    this.label = '',
  });

  final String category;
  final String round;
  final String grade;
  final String major;
  final String roundXh;
  final String label;
}

/// 新正方（jwglxt v9.0）自主选课接口（读取轮次/分类、课程列表、教学班、已选列表与确认后选/退课）。
class ZhengfangSelection {
  ZhengfangSelection({
    required StudyTransport transport,
    required String courseGnmkdm,
  })  : _transport = transport,
        _courseGnmkdm = courseGnmkdm;

  /// 兼容 `queryCourse(this,'10','xkkz','2024','zyh','1')` 与 `queryCourse('10','xkkz','2024','zyh')` 两种调用。
  static final RegExp _categoryCall = RegExp(
    r'''queryCourse\s*\(\s*(?:this\s*,\s*)?['"]([^'"]+)['"]\s*,\s*['"]([^'"]+)['"]\s*,\s*['"]([^'"]*)['"]\s*,\s*['"]([^'"]*)['"](?:\s*,\s*['"]([^'"]*)['"])?''',
  );

  static const List<String> _courseListKeys = ['tmpList', 'courses', 'items'];
  static const List<String> _sectionListKeys = [
    'tmpList',
    'data',
    'courses',
    'jxbList',
  ];
  static const List<String> _selectedListKeys = [
    'tmpList',
    'courses',
    'items',
    'data',
  ];

  static const String _sectionPageSpan = '200';
  static const int _findPageSpanNum = 200;
  static const String _findPageSpan = '200';
  static const String _selectedPageSpan = '1000';

  static const String _indexPath = 'xsxk/zzxkyzb_cxZzxkYzbIndex.html';
  static const String _displayPath = 'xsxk/zzxkyzb_cxZzxkYzbDisplay.html';
  static const String _partListPath = 'xsxk/zzxkyzb_cxZzxkYzbPartDisplay.html';
  static const String _selectPath = 'xsxk/zzxkyzbjk_xkBcZyZzxkYzb.html';
  static const String _sectionListPath =
      'xsxk/zzxkyzbjk_cxJxbWithKchZzxkYzb.html';
  static const String _selectedListPath =
      'xsxk/zzxkyzb_cxZzxkYzbChoosedDisplay.html';
  static const String _dropPath = 'xsxk/zzxkyzb_tuikBcZzxkYzb.html';
  static const String _indexLayoutSuffix = '&layout=default';

  static const List<String> _controlFieldWhitelist = [
    'rwlx',
    'xklc',
    'xkly',
    'bklx_id',
    'sfkkjyxdxnxq',
    'kzkcgs',
    'xqh_id',
    'jg_id',
    'njdm_id_1',
    'zyh_id_1',
    'gnjkxdnj',
    'zyh_id',
    'zyfx_id',
    'njdm_id',
    'bh_id',
    'bjgkczxbbjwcx',
    'xbm',
    'xslbdm',
    'mzm',
    'xz',
    'ccdm',
    'xsbj',
    'sfkknj',
    'sfkkzy',
    'kzybkxy',
    'sfznkx',
    'zdkxms',
    'sfkxq',
    'bhbcyxkjxb',
    'sfkcfx',
    'kkbk',
    'kkbkdj',
    'bklbkcj',
    'sfkgbcx',
    'sfrxtgkcxd',
    'xkkz_xh',
    'tykczgxdcs',
    'xkxnm',
    'xkxqm',
    'kklxdm',
    'bbhzxjxb',
    'zxgbxkkg',
    'adzxk',
    'xkkz_id',
    'rlkz',
    'xkzgbj',
  ];

  static const List<(String, String)> _renamedControls = [
    ('jg_id_1', 'jg_id'),
  ];

  static const List<(String, String, String)> _switchedControls = [
    ('jxbzbkg', 'jxbzb', 'jxbzb'),
    ('jxbzhkg', 'jxbzh', 'zh'),
  ];

  final StudyTransport _transport;
  final String _courseGnmkdm;

  String get _indexReferer => '${_moduleUrl(_indexPath)}$_indexLayoutSuffix';

  Future<List<CourseScope>> scopes() async {
    final loaded = await _loadScopes();
    return loaded
        .map((s) => CourseScope(id: s.id, name: s.name, term: s.term))
        .toList(growable: false);
  }

  Future<List<_Scope>> _loadScopes() async {
    final index = await _indexPage();
    final doc = Html.parse(index.body, index.address);
    final indexFields = Html.hiddenFieldsByIdOrName(doc);

    final iskxk = (indexFields['iskxk'] ?? '').trim();
    if (iskxk == '0' ||
        index.body.contains('不属于选课阶段') ||
        index.body.contains('非选课阶段') ||
        index.body.contains('未到选课') ||
        index.body.contains('选课未开放')) {
      throw const AcademicException(
        AcademicStatus.ROUND_CLOSED,
        '当前不属于选课阶段',
      );
    }

    final listed = _categoriesIn(doc, index.body);
    final rows =
        listed.isNotEmpty ? listed : _firstVariantCategory(indexFields);
    final contexts = <Map<String, String>>[];
    if (rows.isNotEmpty) {
      for (final row in rows) {
        contexts.add(await _mergeDisplayFields(index, indexFields, row));
      }
    } else if (_hasSelectionControlContext(indexFields)) {
      contexts.add(indexFields);
    }
    final result = <_Scope>[];
    for (var i = 0; i < contexts.length; i++) {
      result.add(_scopeOf(i, contexts[i]));
    }
    if (result.isEmpty) {
      throw const AcademicException(
        AcademicStatus.ROUND_CLOSED,
        '当前不属于选课阶段',
      );
    }
    return result;
  }

  static bool _hasSelectionControlContext(Map<String, String> fields) =>
      (fields['xkkz_id'] ?? '').trim().isNotEmpty ||
      (fields['kklxdm'] ?? '').trim().isNotEmpty;

  Future<FetchedPage> _indexPage() async => _checked(
        await _transport.fetch(
          _indexReferer,
          ajax: false,
        ),
      );

  String _moduleUrl(String path) =>
      _transport.resolveUrl('$path?gnmkdm=$_courseGnmkdm');

  static List<_Category> _categoriesIn(Document doc, String html) {
    final out = <_Category>[];
    final seen = <String>{};

    for (final el in doc.querySelectorAll('[onclick*="queryCourse"]')) {
      final onclick = Html.attr(el, 'onclick');
      final m = _categoryCall.firstMatch(onclick);
      if (m == null) continue;
      final cat = m.group(1) ?? '';
      final round = m.group(2) ?? '';
      final key = '$cat|$round';
      if (!seen.add(key)) continue;
      out.add(
        _Category(
          category: cat,
          round: round,
          grade: m.group(3) ?? '',
          major: m.group(4) ?? '',
          roundXh: m.group(5) ?? '',
          label: Html.textOf(el).trim(),
        ),
      );
    }
    if (out.isNotEmpty) return out;

    for (final m in _categoryCall.allMatches(html)) {
      final cat = m.group(1) ?? '';
      final round = m.group(2) ?? '';
      if (!seen.add('$cat|$round')) continue;
      out.add(
        _Category(
          category: cat,
          round: round,
          grade: m.group(3) ?? '',
          major: m.group(4) ?? '',
          roundXh: m.group(5) ?? '',
        ),
      );
    }
    return out;
  }

  static List<_Category> _firstVariantCategory(Map<String, String> fields) {
    final category = (fields['firstKklxdm'] ?? '').trim();
    final round = (fields['firstXkkzId'] ?? '').trim();
    if (category.isEmpty || round.isEmpty) return const <_Category>[];
    final firstGrade = (fields['firstNjdmId'] ?? '').trim();
    final firstMajor = (fields['firstZyhId'] ?? '').trim();
    return <_Category>[
      _Category(
        category: category,
        round: round,
        grade: firstGrade.isNotEmpty ? firstGrade : (fields['njdm_id'] ?? ''),
        major: firstMajor.isNotEmpty ? firstMajor : (fields['zyh_id'] ?? ''),
        roundXh: (fields['firstXkkzXh'] ?? '').trim(),
        label: (fields['firstKklxmc'] ?? '').trim(),
      ),
    ];
  }

  Future<Map<String, String>> _mergeDisplayFields(
    FetchedPage index,
    Map<String, String> indexFields,
    _Category category,
  ) async {
    final fields = Map<String, String>.from(indexFields)
      ..['kklxdm'] = category.category
      ..['xkkz_id'] = category.round
      ..['njdm_id'] = category.grade
      ..['zyh_id'] = category.major;
    final display = _checked(
      await _transport.submitForm(
        _moduleUrl(_displayPath),
        [
          ('xkkz_id', category.round),
          ('kklxdm', category.category),
          ('xszxzt', '1'),
          ('njdm_id', category.grade),
          ('zyh_id', category.major),
          ('kspage', '0'),
          ('jspage', '0'),
        ],
        referer: index.address,
        ajax: true,
      ),
    );
    fields.addAll(
      Html.hiddenFieldsByIdOrName(Html.parse(display.body, display.address)),
    );

    if (category.roundXh.isNotEmpty) {
      fields['xkkz_xh'] = category.roundXh;
    } else if ((fields['xkkz_xh'] ?? '').trim().isEmpty) {
      final firstXh = (indexFields['firstXkkzXh'] ?? '').trim();
      if (firstXh.isNotEmpty) fields['xkkz_xh'] = firstXh;
    }

    // 保留每个选课页签自身的分类名称（kklxmc），绝不用 firstKklxmc 覆盖后续页签。
    if (category.label.isNotEmpty) {
      fields['kklxmc'] = category.label;
    } else if ((fields['kklxmc'] ?? '').trim().isEmpty &&
        category.category == (indexFields['firstKklxdm'] ?? '').trim()) {
      final firstMc = (indexFields['firstKklxmc'] ?? '').trim();
      if (firstMc.isNotEmpty) fields['kklxmc'] = firstMc;
    }

    return fields;
  }

  _Scope _scopeOf(int ordinal, Map<String, String> fields) {
    final rawCategory = (fields['kklxdm'] ?? '').trim();
    final category = rawCategory.isEmpty ? 'default' : rawCategory;
    final rawName = (fields['kklxmc'] ?? '').trim();
    return _Scope(
      id: 'zf-$ordinal-$category',
      name: rawName.isEmpty ? category : rawName,
      term: fields['xkxnm'] ?? '',
      listUrl: _moduleUrl(_partListPath),
      selectUrl: _moduleUrl(_selectPath),
      params: fields,
    );
  }

  Future<List<CourseOffer>> courses(String scopeId, CourseQuery query) async {
    final offers = <CourseOffer>[];
    final pageSpan = query.pageSize < 1 ? 1 : query.pageSize;
    for (final scope in _matching(await _loadScopes(), scopeId)) {
      final params = _queryControlFields(
        source: scope.params,
        keyword: query.keyword,
        fromPage: (query.start + 1).toString(),
        toPage: (query.start + pageSpan).toString(),
      );
      final response = _checked(
        await _transport.submitForm(
          scope.listUrl,
          params.entries.map((e) => (e.key, e.value)),
          referer: _indexReferer,
          ajax: true,
        ),
      );
      for (final row in AcademicJson.objects(response.body, _courseListKeys)) {
        final offer = _parseOffer(row, scope);
        if (offer.model.name.trim().isNotEmpty) offers.add(offer.model);
      }
    }
    final teacherFilter = query.teacher.trim().toLowerCase();
    if (teacherFilter.isEmpty) return offers;
    return offers
        .where((o) => o.teacher.toLowerCase().contains(teacherFilter))
        .toList(growable: false);
  }

  static _Offer _parseOffer(JsonMap row, _Scope scope) {
    final operation = AcademicJson.operationFields(row);
    final primaryId = AcademicJson.string(row, const ['kch_id', 'kch']);
    final id = primaryId.trim().isNotEmpty
        ? primaryId
        : AcademicJson.string(row, const ['kcid', 'jx0404id']);
    final model = CourseOffer(
      id: id,
      name: AcademicJson.string(
        row,
        const ['kcmc', 'kc_mc', 'fzmc', 'ktmc'],
      ),
      teacher: AcademicJson.string(
        row,
        const ['jsxm', 'skls', 'xm', 'jsxx'],
      ),
      time: AcademicJson.string(row, const ['sksj', 'sksjmc']),
      location: AcademicJson.string(row, const ['jxdd', 'skdd', 'skddyw']),
      credit: AcademicJson.string(row, const ['xf']),
      capacity: AcademicJson.integer(row, const ['jxbrl', 'capacity', 'xkrs']),
      selected: AcademicJson.integer(row, const ['yxzrs', 'yxrs', 'selected']),
      scopeId: scope.id,
    );
    final raw = <String, String>{...scope.params};
    for (final entry in operation.entries) {
      if (entry.value.trim().isNotEmpty) raw[entry.key] = entry.value;
    }
    return _Offer(model, raw);
  }

  Future<List<CourseSection>> sections(String courseId, String scopeId) async {
    final matched = _matching(await _loadScopes(), scopeId);
    if (matched.isEmpty) return const <CourseSection>[];
    final offer = await _findOffer(matched.first, courseId);
    if (offer == null) return const <CourseSection>[];
    final loaded = await _loadSections(offer);
    return loaded.map((s) => s.model).toList(growable: false);
  }

  Future<List<_Section>> _loadSections(_Offer offer) async {
    final params = _queryControlFields(
      source: offer.raw,
      keyword: '',
      fromPage: '1',
      toPage: _sectionPageSpan,
      extra: {'kch_id': offer.model.id},
    );
    final response = _checked(
      await _transport.submitForm(
        _moduleUrl(_sectionListPath),
        params.entries.map((e) => (e.key, e.value)),
        referer: _indexReferer,
        ajax: true,
      ),
    );
    return AcademicJson.objects(response.body, _sectionListKeys).map((row) {
      final model = CourseSection(
        id: AcademicJson.string(
          row,
          const ['do_jxb_id', 'jxb_id', 'jx0404id', 'jx02id', 'kcid', 'kch'],
        ),
        courseId: offer.model.id,
        name: AcademicJson.string(row, const ['jxbmc', 'ktmc', 'fzmc']),
        teacher: AcademicJson.string(
          row,
          const ['jsxm', 'skls', 'xm', 'jsxx'],
        ),
        time: AcademicJson.string(row, const ['sksj', 'sksjmc']),
        location: AcademicJson.string(row, const ['jxdd', 'skdd']),
        capacity: AcademicJson.integer(row, const ['jxbrl', 'capacity']),
        selected: AcademicJson.integer(
          row,
          const ['yxzrs', 'yxrs', 'selected'],
        ),
      );
      return _Section(model, AcademicJson.fields(row));
    }).toList(growable: false);
  }

  Future<SelectionOutcome> select({
    required String courseId,
    required String sectionId,
    required String scopeId,
    required bool confirmed,
  }) =>
      _submit(
        courseId: courseId,
        sectionId: sectionId,
        scopeId: scopeId,
        confirmed: confirmed,
        dropping: false,
      );

  Future<SelectionOutcome> drop({
    required String courseId,
    required String sectionId,
    required String scopeId,
    required bool confirmed,
  }) =>
      _submit(
        courseId: courseId,
        sectionId: sectionId,
        scopeId: scopeId,
        confirmed: confirmed,
        dropping: true,
      );

  Future<SelectionOutcome> _submit({
    required String courseId,
    required String sectionId,
    required String scopeId,
    required bool confirmed,
    required bool dropping,
  }) async {
    if (!confirmed) {
      return const SelectionOutcome(
        AcademicStatus.VALIDATION_FAILED,
        '需要先确认才能提交',
      );
    }
    final allScopes = await _loadScopes();
    final matched = _matching(allScopes, scopeId);
    final scope = matched.isNotEmpty ? matched.first : allScopes.first;

    final offer = await _findOffer(scope, courseId);
    _Section? section;
    if (offer != null) {
      final allSections = await _loadSections(offer);
      for (final s in allSections) {
        if (_matchesSection(s, sectionId)) {
          section = s;
          break;
        }
      }
    }

    if (dropping && (offer == null || section == null)) {
      return _dropFromChosenList(
        scope: scope,
        courseId: courseId,
        sectionId: sectionId,
        fallbackOffer: offer,
      );
    }

    if (offer == null) {
      return const SelectionOutcome(
        AcademicStatus.PAGE_CHANGED,
        '目标课程已不在当前可选列表中，请刷新后重试',
      );
    }
    if (section == null) {
      return const SelectionOutcome(
        AcademicStatus.PAGE_CHANGED,
        '目标教学班已不存在，请刷新后重试',
      );
    }

    final target = dropping ? _moduleUrl(_dropPath) : scope.selectUrl;
    final values = dropping
        ? _dropFields(offer, section)
        : _selectFields(offer, section);
    final response = _checked(
      await _transport.submitForm(
        target,
        values.entries.map((e) => (e.key, e.value)),
        referer: _indexReferer,
        ajax: true,
      ),
    );
    final status = AcademicJson.zfStatus(response.body, response.status);
    return SelectionOutcome(
      status,
      status == AcademicStatus.SUCCESS
          ? ''
          : AcademicJson.message(response.body),
      offer.model.name,
      _effectiveDoJxbId(section),
    );
  }

  Future<SelectionOutcome> _dropFromChosenList({
    required _Scope scope,
    required String courseId,
    required String sectionId,
    _Offer? fallbackOffer,
  }) async {
    final chosenRows = await _loadRawSelectedRows(scope);
    JsonMap? targetRow;
    for (final row in chosenRows) {
      final rowCourseId = AcademicJson.string(
        row,
        const ['kch_id', 'kcid', 'jx02id', 'kch'],
      );
      final doJxb = AcademicJson.string(row, const ['do_jxb_id']);
      final jxb = AcademicJson.string(
        row,
        const ['jxb_id', 'jx0404id', 'jx0501id'],
      );
      final idMatch = sectionId == doJxb || sectionId == jxb;
      if (idMatch && (courseId.isEmpty || rowCourseId == courseId)) {
        targetRow = row;
        break;
      }
    }

    if (targetRow == null) {
      return SelectionOutcome(
        AcademicStatus.PAGE_CHANGED,
        fallbackOffer == null
            ? '目标课程已不在已选或可选列表中，请刷新后重试'
            : '目标教学班已不存在，请刷新后重试',
      );
    }

    final doJxbId = AcademicJson.string(
      targetRow,
      const ['do_jxb_id', 'jxb_id', 'jx0404id', 'jx0501id'],
    );
    final resolvedCourseId = AcademicJson.string(
      targetRow,
      const ['kch_id', 'kcid', 'jx02id', 'kch'],
    );
    final courseName = AcademicJson.string(targetRow, const ['kcmc', 'kc_mc']);
    final values = <String, String>{
      'kch_id': resolvedCourseId.isNotEmpty ? resolvedCourseId : courseId,
      'jxb_ids': doJxbId.isNotEmpty ? doJxbId : sectionId,
      'xkxnm': scope.params['xkxnm'] ?? '',
      'xkxqm': scope.params['xkxqm'] ?? '',
      'txbsfrl': scope.params['txbsfrl'] ?? '0',
    };
    final response = _checked(
      await _transport.submitForm(
        _moduleUrl(_dropPath),
        values.entries.map((e) => (e.key, e.value)),
        referer: _indexReferer,
        ajax: true,
      ),
    );
    final status = AcademicJson.zfStatus(response.body, response.status);
    return SelectionOutcome(
      status,
      status == AcademicStatus.SUCCESS
          ? ''
          : AcademicJson.message(response.body),
      courseName,
      doJxbId.isNotEmpty ? doJxbId : sectionId,
    );
  }

  static bool _matchesSection(_Section section, String sectionId) =>
      section.model.id == sectionId ||
      section.raw['do_jxb_id'] == sectionId ||
      section.raw['jxb_id'] == sectionId;

  static String _effectiveDoJxbId(_Section section) {
    final doId = (section.raw['do_jxb_id'] ?? '').trim();
    return doId.isNotEmpty ? doId : section.model.id;
  }

  static Map<String, String> _dropFields(_Offer offer, _Section section) => {
        'kch_id': offer.model.id,
        'jxb_ids': _effectiveDoJxbId(section),
        'xkxnm': offer.raw['xkxnm'] ?? '',
        'xkxqm': offer.raw['xkxqm'] ?? '',
        'txbsfrl': offer.raw['txbsfrl'] ?? '0',
      };

  static Map<String, String> _selectFields(_Offer offer, _Section section) => {
        ...offer.raw,
        ...section.raw,
        'jxb_ids': _effectiveDoJxbId(section),
        'kch_id': offer.model.id,
        'kcmc': offer.model.name,
        'kklxdm': offer.raw['kklxdm'] ?? '',
        'xkkz_id': offer.raw['xkkz_id'] ?? '',
      };

  Future<List<SelectedCourse>> selected() async {
    final loaded = await _loadScopes();
    if (loaded.isEmpty) return const <SelectedCourse>[];
    final rows = await _loadRawSelectedRows(loaded.first);
    return rows
        .map(
          (row) => SelectedCourse(
            id: AcademicJson.string(
              row,
              const ['do_jxb_id', 'jxb_id', 'jx0404id', 'jx0501id', 'kch'],
            ),
            name: AcademicJson.string(row, const ['kcmc', 'kc_mc']),
            teacher: AcademicJson.string(row, const ['jsxm', 'skls', 'xm']),
            courseId: AcademicJson.string(
              row,
              const ['kch_id', 'kcid', 'jx02id', 'kch'],
            ),
            // 优先使用 do_jxb_id，确保与 CourseSection.id 及退课接口 jxb_ids 完全一致！
            sectionId: AcademicJson.string(
              row,
              const ['do_jxb_id', 'jxb_id', 'jx0404id', 'jx0501id'],
            ),
            time: AcademicJson.string(row, const ['sksj', 'sksjmc']),
            location: AcademicJson.string(row, const ['jxdd', 'skdd']),
          ),
        )
        .where((c) => c.name.trim().isNotEmpty)
        .toList(growable: false);
  }

  Future<List<JsonMap>> _loadRawSelectedRows(_Scope scope) async {
    final params = _queryControlFields(
      source: scope.params,
      keyword: '',
      fromPage: '1',
      toPage: _selectedPageSpan,
    );
    final response = _checked(
      await _transport.submitForm(
        _moduleUrl(_selectedListPath),
        params.entries.map((e) => (e.key, e.value)),
        referer: _indexReferer,
        ajax: true,
      ),
    );
    return AcademicJson.objects(response.body, _selectedListKeys);
  }

  Future<_Offer?> _findOffer(_Scope scope, String courseId) async {
    final targetId = courseId.trim();
    if (targetId.isEmpty) return null;

    final params = _queryControlFields(
      source: scope.params,
      keyword: '',
      fromPage: '1',
      toPage: _findPageSpan,
    );
    final response = _checked(
      await _transport.submitForm(
        scope.listUrl,
        params.entries.map((e) => (e.key, e.value)),
        referer: _indexReferer,
        ajax: true,
      ),
    );
    final firstPageRows =
        AcademicJson.objects(response.body, _courseListKeys);
    for (final row in firstPageRows) {
      final offer = _parseOffer(row, scope);
      if (offer.model.id == targetId) return offer;
    }

    // 当可选课程超过单页 200 条（如全校通选课轮次）时，附加 filter_list[0]=courseId 精确检索。
    if (firstPageRows.length >= _findPageSpanNum) {
      final filteredParams = _queryControlFields(
        source: scope.params,
        keyword: targetId,
        fromPage: '1',
        toPage: _findPageSpan,
      );
      final filteredResponse = _checked(
        await _transport.submitForm(
          scope.listUrl,
          filteredParams.entries.map((e) => (e.key, e.value)),
          referer: _indexReferer,
          ajax: true,
        ),
      );
      for (final row
          in AcademicJson.objects(filteredResponse.body, _courseListKeys)) {
        final offer = _parseOffer(row, scope);
        if (offer.model.id == targetId) return offer;
      }
    }

    return null;
  }

  static Map<String, String> _queryControlFields({
    required Map<String, String> source,
    required String keyword,
    required String fromPage,
    required String toPage,
    Map<String, String> extra = const {},
  }) {
    final params = <String, String>{};
    for (final key in _controlFieldWhitelist) {
      final val = source[key];
      if (val != null) params[key] = val;
    }
    for (final (from, to) in _renamedControls) {
      final val = source[from];
      if (val != null) params[to] = val;
    }
    for (final (toggle, field, target) in _switchedControls) {
      if (source[toggle] == '1') {
        params[target] = source[field] ?? '';
      }
    }
    if (keyword.trim().isNotEmpty) params['filter_list[0]'] = keyword;
    params['kspage'] = fromPage;
    params['jspage'] = toPage;
    params.addAll(extra);
    return params;
  }

  static List<_Scope> _matching(List<_Scope> scopes, String scopeId) {
    if (scopeId.trim().isEmpty) return scopes;
    return scopes.where((s) => s.id == scopeId).toList(growable: false);
  }

  static FetchedPage _checked(FetchedPage page) {
    if (Html.isLoginPage(page.body) ||
        AcademicJson.looksLikeSessionExpired(page.body)) {
      throw const AcademicException(
        AcademicStatus.SESSION_EXPIRED,
        '登录状态已失效，请重新登录',
      );
    }
    if (page.status < 200 || page.status > 299) {
      throw AcademicException(
        AcademicStatus.PAGE_CHANGED,
        '学校选课页面当前不可访问（HTTP ${page.status}）',
      );
    }
    return page;
  }
}
