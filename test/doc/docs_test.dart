@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tool/docs.dart';

void main() {
  test('example regions require one matching pair and retain exact source', () {
    const source =
        '// #docregion sample\nvoid sample() {}\n// #enddocregion sample\n';
    expect(extractRegion(source, 'sample'), 'void sample() {}');
    expect(() => extractRegion(source, 'absent'), throwsFormatException);
    expect(
        () => extractRegion('$source$source', 'sample'), throwsFormatException);
  });

  test(
      'links resolve relative to the page and reject missing or escaping targets',
      () {
    final root = Directory('.dart_tool').createTempSync('docs-links-');
    addTearDown(() => root.deleteSync(recursive: true));
    Directory('${root.path}/doc').createSync();
    File('${root.path}/README.md').writeAsStringSync('# Root');
    expect(brokenLinks(root, 'doc/guide.md', '[Root](../README.md)'), isEmpty);
    expect(brokenLinks(root, 'doc/guide.md', '[Missing](missing.md)'),
        hasLength(1));
    expect(
        () => projectFile(root, '../../outside.dart'), throwsFormatException);
    expect(brokenLinks(root, 'doc/guide.md', '[External](https://example.com)'),
        isEmpty);
  });

  test(
      'generation is reproducible and check catches stale examples and LLM output',
      () async {
    final root = Directory('.dart_tool').createTempSync('docs-project-');
    addTearDown(() => root.deleteSync(recursive: true));
    final paths = [
      for (final (path, _, _, _) in documentation) path,
      'pubspec.yaml',
      'tool/upstream_api.json',
      'tool/upstream_tests.json',
      'tool/upstream_api_compatibility.json',
      'example/basic_chat.dart',
      'example/recipes.dart',
      'example/quickstart.dart',
      'LICENSE',
      'THIRD_PARTY_NOTICES',
      'CHANGELOG.md',
      'NEXT_STEPS.md',
      'validation/parity-summary.json',
      '.github/PULL_REQUEST_TEMPLATE.md',
      'test/interop/public_export_inventory_test.dart',
    ];
    // Links may target directories as well as files; mirror repository paths.
    for (final path in paths) {
      final target = File('${root.path}/$path');
      target.parent.createSync(recursive: true);
      target.writeAsStringSync(File(path).readAsStringSync());
    }
    expect(await processDocumentation(root, write: true), isEmpty);
    expect(await processDocumentation(root, write: false), isEmpty);
    File('${root.path}/llms.txt').writeAsStringSync('stale');
    expect(await processDocumentation(root, write: false),
        contains(contains('llms.txt is stale')));
    expect(await processDocumentation(root, write: true), isEmpty);
    final example = File('${root.path}/example/basic_chat.dart');
    example.writeAsStringSync(
        '${example.readAsStringSync()}\n// new example comment\n');
    expect(await processDocumentation(root, write: false),
        contains(contains('README.md is stale')));
    final manifest = File('${root.path}/tool/upstream_api.json');
    final content =
        jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
    content['commit'] = 'not-the-supported-commit';
    manifest.writeAsStringSync(jsonEncode(content));
    await expectLater(
        processDocumentation(root, write: false), throwsFormatException);
  });
}
