@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../../tool/analyzer_command.dart';

void main() {
  test('modern chat requires a string thread ID', () {
    final file = File('.dart_tool/chat_identity_type_fixture.dart')
      ..writeAsStringSync('''
import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';
void main() {
  ChatClient(connection: stream((_) => const Stream.empty()));
  ChatClient(connection: stream((_) => const Stream.empty()), threadId: 42);
}
''');
    try {
      final result = Process.runSync(Platform.resolvedExecutable,
          analyzerArguments(['--format=machine', file.path]));
      expect(result.exitCode, isNot(0));
      expect(result.stdout, contains('MISSING_REQUIRED_ARGUMENT'));
      expect(result.stdout, contains('ARGUMENT_TYPE_NOT_ASSIGNABLE'));
    } finally {
      file.deleteSync();
    }
  });
}
