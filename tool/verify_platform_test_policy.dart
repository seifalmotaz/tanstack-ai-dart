import 'dart:io';

const _header = "@TestOn('vm')";

void main() {
  final tests = Directory('test')
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final failures = <String>[];
  final vmFiles = <String>[];

  for (final file in tests) {
    final source = file.readAsStringSync();
    final importsIo = RegExp(
      r'''^\s*import\s+['"]dart:io['"]''',
      multiLine: true,
    ).hasMatch(source);
    final firstLine = source.split('\n').first.trim();

    if (importsIo) {
      vmFiles.add(file.path);
      if (firstLine != _header) {
        failures.add(
          '${file.path}: imports dart:io but first line is '
          '"$firstLine" (expected $_header)',
        );
      }
    }
  }

  for (final path in vmFiles) {
    stdout.writeln('vm-only: $path');
  }
  stdout.writeln(
    'checked ${tests.length} test files; ${vmFiles.length} direct dart:io files',
  );

  if (failures.isNotEmpty) {
    stderr.writeln('Platform test policy failures:');
    for (final failure in failures) {
      stderr.writeln('  $failure');
    }
    exitCode = 1;
    return;
  }

  stdout.writeln('Platform test policy OK.');
}
