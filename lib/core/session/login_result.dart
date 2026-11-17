import 'dart:typed_data';

import '../model/academic_status.dart';
import '../model/student_identity.dart';

/// 需要用户填写的图片验证码挑战。
class CaptchaChallenge {
  CaptchaChallenge({
    required Uint8List image,
    required this.fieldName,
    this.refreshUrl,
  }) : image = Uint8List.fromList(image);

  final Uint8List image;
  final String fieldName;
  final String? refreshUrl;
}

/// 一次登录尝试的结果。
class LoginResult {
  const LoginResult(
    this.status, {
    this.identity = const StudentIdentity(),
    this.message = '',
    this.captcha,
    this.isProvisional = false,
  });

  final AcademicStatus status;
  final StudentIdentity identity;
  final String message;
  final CaptchaChallenge? captcha;
  final bool isProvisional;

  bool get isSuccess => status == AcademicStatus.SUCCESS;
}
