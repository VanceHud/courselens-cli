/// 教务系统类型与部署前缀联合探测结果。
class StudySystemProbe {
  const StudySystemProbe({
    required this.systemId,
    required this.basePath,
    required this.baseUrl,
    required this.detectedFrom,
    required this.message,
  });

  final String systemId;
  final String basePath;
  final String baseUrl;
  final String detectedFrom;
  final String message;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StudySystemProbe &&
          systemId == other.systemId &&
          basePath == other.basePath &&
          baseUrl == other.baseUrl &&
          detectedFrom == other.detectedFrom &&
          message == other.message;

  @override
  int get hashCode =>
      Object.hash(systemId, basePath, baseUrl, detectedFrom, message);
}
