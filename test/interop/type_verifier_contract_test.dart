@TestOn('vm')
library;

import 'dart:io';
import 'package:test/test.dart';

void main() {
  test(
      'static fixture verifier handles wrapped calls and fails when rejection disappears',
      () async {
    final directory =
        Directory('.dart_tool').createTempSync('types-selfcheck-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final fixture = File('${directory.path}/negative.dart');
    fixture.writeAsStringSync('''
void main() {
  // expect-error: undefined_named_parameter
  Duration(
    milliseconds: 1,
    nonexistent: true,
  );
}
''');
    Future<ProcessResult> verify() => Process.run(Platform.resolvedExecutable,
        ['run', 'tool/verify_types.dart', directory.path]);
    final rejected = await verify();
    expect(rejected.exitCode, 0,
        reason: '${rejected.stdout}${rejected.stderr}');
    fixture.writeAsStringSync(fixture
        .readAsStringSync()
        .replaceFirst('    nonexistent: true,\n', ''));
    final accepted = await verify();
    expect(accepted.exitCode, 1);
    expect(accepted.stderr,
        contains('missing expected UNDEFINED_NAMED_PARAMETER'));
  });
}
