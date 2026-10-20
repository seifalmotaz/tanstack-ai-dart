import 'dart:io';

/// Verify positive fixtures and every `expect-error: CODE` negative assertion.
/// Unlike runtime type checks, this invokes the Dart static analyzer.
Future<void> main(List<String> args) async {
  final directory = Directory(args.isEmpty ? 'test/types' : args.single);
  var assertions = 0;
  for (final file in directory.listSync(recursive: true).whereType<File>()) {
    if (!file.path.endsWith('.dart')) continue;
    final lines = file.readAsLinesSync();
    final expected = <int, Set<String>>{};
    final statementEnd = <int, int>{};
    for (var index = 0; index < lines.length; index++) {
      final match =
          RegExp(r'expect-error:\s*([A-Za-z_]+)').firstMatch(lines[index]);
      if (match == null) continue;
      final comment = lines[index].indexOf('//');
      var target =
          comment > 0 && lines[index].substring(0, comment).trim().isNotEmpty
              ? index
              : index + 1;
      while (target < lines.length &&
          (lines[target].trim().isEmpty ||
              lines[target].trim().startsWith('//'))) {
        target++;
      }
      var end = target;
      while (end < lines.length - 1 && !lines[end].contains(';')) {
        end++;
      }
      statementEnd[target + 1] = end + 1;
      expected
          .putIfAbsent(target + 1, () => {})
          .add(match.group(1)!.toUpperCase());
    }
    final result = await Process.run(Platform.resolvedExecutable,
        ['analyze', '--format', 'machine', file.path]);
    final actual = <int, Set<String>>{};
    for (final diagnostic in '${result.stdout}\n${result.stderr}'.split('\n')) {
      final fields = diagnostic.split('|');
      if (fields.length < 8 || fields.first != 'ERROR') continue;
      final line = int.parse(fields[4]);
      actual.putIfAbsent(line, () => {}).add(fields[2]);
    }
    if (result.exitCode != 0 && actual.isEmpty) {
      stderr.writeln(
          'Analyzer failed for ${file.path}: ${result.stdout}${result.stderr}');
      exitCode = 1;
      continue;
    }
    for (final entry in expected.entries) {
      assertions += entry.value.length;
      for (final code in entry.value) {
        final found = actual.entries.any((diagnostic) =>
            diagnostic.key >= entry.key &&
            diagnostic.key <= statementEnd[entry.key]! &&
            diagnostic.value.contains(code));
        if (!found) {
          stderr.writeln('${file.path}:${entry.key}: missing expected $code');
          exitCode = 1;
        }
      }
    }
    for (final entry in actual.entries) {
      if (!expected.keys.any(
          (start) => entry.key >= start && entry.key <= statementEnd[start]!)) {
        stderr.writeln(
            '${file.path}:${entry.key}: unexpected ${entry.value.join(', ')}');
        exitCode = 1;
      }
    }
    stdout.writeln(
        '${file.path}: ${expected.isEmpty ? 'positive fixture' : '${expected.length} negative lines'}');
  }
  if (assertions == 0) {
    stderr.writeln('No negative analyzer assertions found.');
    exitCode = 1;
  }
  stdout.writeln('$assertions static rejection assertions checked.');
}
