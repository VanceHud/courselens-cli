import 'dart:convert';
import 'dart:io' as io;

import 'package:courselens/cli/cli_runner.dart';

/// CourseLens 纯 Dart 原生 CLI 入口（支持 `dart run` 与 `dart compile exe`）。
///
/// 纯 Dart 零 Flutter UI/插件依赖；所有业务数据写入 `stdout`，所有交互提示与错误诊断写入 `stderr`。
Future<void> main(List<String> args) async {
  final runner = CliRunner(
    out: io.stdout,
    err: io.stderr,
    readStdinLine: () async => io.stdin.readLineSync(encoding: utf8),
    readStdinAll: () => utf8.decoder.bind(io.stdin).join(),
    readHiddenPassword: io.stdin.hasTerminal ? _promptHiddenPassword : null,
  );

  final code = await runner.run(args);
  await io.stdout.flush();
  await io.stderr.flush();
  io.exit(code);
}

Future<String?> _promptHiddenPassword(String prompt) async {
  io.stderr.write(prompt);
  final previousEcho = io.stdin.echoMode;
  try {
    io.stdin.echoMode = false;
    final line = io.stdin.readLineSync(encoding: utf8);
    io.stderr.writeln();
    return line;
  } finally {
    try {
      io.stdin.echoMode = previousEcho;
    } on io.StdinException {
      // 忽略终端句柄在退出前已关闭的场景
    }
  }
}
