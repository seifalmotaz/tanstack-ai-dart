import 'dart:convert';
import 'dart:io';

const rawBase =
    'https://raw.githubusercontent.com/seifalmotaz/tanstack-ai-dart/main/';
const browserBase =
    'https://github.com/seifalmotaz/tanstack-ai-dart/blob/main/';

const documentation = <(String, String, String, String)>[
  (
    'README.md',
    'Package overview',
    'Installation and the shortest chat example.',
    'Guides'
  ),
  (
    'doc/README.md',
    'Documentation index',
    'Choose an application or maintainer guide.',
    'Guides'
  ),
  (
    'doc/getting-started.md',
    'Getting started',
    'Backend requirements, first request, ownership, and Flutter.',
    'Guides'
  ),
  (
    'doc/chat.md',
    'Chat and rendering',
    'State streams, message parts, queues, and cancellation.',
    'Guides'
  ),
  (
    'doc/connections.md',
    'Connections and authentication',
    'HTTP, WebSocket, custom fetchers, and credential refresh.',
    'Guides'
  ),
  (
    'doc/persistence.md',
    'Persistence and resume',
    'Server history, application storage, and replay.',
    'Guides'
  ),
  (
    'doc/tools-and-interrupts.md',
    'Tools and interrupts',
    'Typed tools, validation, approval, and continuation.',
    'Guides'
  ),
  (
    'doc/generation.md',
    'Generation and video',
    'Typed results, restoration, and snapshot copiers.',
    'Guides'
  ),
  (
    'doc/platform-support.md',
    'Platform support',
    'Host implementations, Flutter integration, and BYOK.',
    'Guides'
  ),
  (
    'doc/api-reference.md',
    'API reference map',
    'Public imports and common operations.',
    'Guides'
  ),
  (
    'doc/troubleshooting.md',
    'Troubleshooting',
    'Diagnose common setup and runtime failures.',
    'Guides'
  ),
  (
    'MIGRATION.md',
    'Migration to 0.3',
    'Breaking Dart API changes and explicit legacy paths.',
    'Compatibility'
  ),
  (
    'API_COMPATIBILITY.md',
    'API compatibility',
    'Upstream exports, Dart adaptations, and host limits.',
    'Compatibility'
  ),
  (
    'PARITY.md',
    'Parity methodology',
    'Pinned source and assertion-level verification.',
    'Compatibility'
  ),
  (
    'VALIDATION.md',
    'Validation evidence',
    'Executed checks and their practical limits.',
    'Compatibility'
  ),
  (
    'CONTRIBUTING.md',
    'Contribution rules',
    'Development setup, tests, and reviewed pull requests.',
    'Optional'
  ),
  (
    'doc/maintainers/upstream-updates.md',
    'Update the TypeScript port',
    'Review new upstream commits, assertions, and protocol changes.',
    'Optional'
  ),
  (
    'doc/maintainers/releasing.md',
    'Release the Dart package',
    'Manual checks and publication responsibilities.',
    'Optional'
  ),
];

final _example = RegExp(
  r'<!-- example: ([^\s]+) -->\n```dart\n[\s\S]*?\n```\n<!-- /example -->',
);
final _link = RegExp(r'\]\(([^\s)]+)\)');

File projectFile(Directory root, String path) {
  final base = root.absolute.uri;
  final target = base.resolve(path).normalizePath();
  if (!target.toString().startsWith(base.toString())) {
    throw FormatException('Path escapes the repository: $path');
  }
  final file = File.fromUri(target);
  if (file.existsSync()) {
    final canonicalRoot = root.resolveSymbolicLinksSync();
    final canonical = file.resolveSymbolicLinksSync();
    if (!canonical.startsWith('$canonicalRoot${Platform.pathSeparator}')) {
      throw FormatException('Symlink escapes the repository: $path');
    }
  }
  return file;
}

String extractRegion(String source, String? region) {
  if (region == null) return source.trimRight();
  final start =
      RegExp('^// #docregion ${RegExp.escape(region)}\$', multiLine: true);
  final end =
      RegExp('^// #enddocregion ${RegExp.escape(region)}\$', multiLine: true);
  final starts = start.allMatches(source).toList();
  final ends = end.allMatches(source).toList();
  if (starts.length != 1 ||
      ends.length != 1 ||
      ends.single.start < starts.single.end) {
    throw FormatException('Expected one complete example region: $region');
  }
  return source.substring(starts.single.end, ends.single.start).trim();
}

String refreshExamples(String text, Directory root) {
  final starts = '<!-- example:'.allMatches(text).length;
  if (_example.allMatches(text).length != starts) {
    throw const FormatException('Malformed generated example block');
  }
  return text.replaceAllMapped(_example, (match) {
    final spec = match[1]!;
    final pieces = spec.split('#');
    if (!pieces.first.startsWith('example/') || pieces.length > 2) {
      throw FormatException('Example must name an example/ source file: $spec');
    }
    final source = projectFile(root, pieces.first).readAsStringSync();
    final snippet =
        extractRegion(source, pieces.length == 2 ? pieces[1] : null);
    return '<!-- example: $spec -->\n```dart\n$snippet\n```\n<!-- /example -->';
  });
}

List<String> brokenLinks(Directory root, String page, String markdown) {
  final errors = <String>[];
  final text = markdown.replaceAll(RegExp(r'```[\s\S]*?```'), '');
  for (final match in _link.allMatches(text)) {
    var target = match[1]!;
    if (target.startsWith(rawBase)) {
      target = target.substring(rawBase.length);
    } else if (target.startsWith(browserBase)) {
      target = target.substring(browserBase.length);
    } else if (Uri.parse(target).hasScheme || target.startsWith('#')) {
      continue;
    } else {
      target = Uri.parse(page).resolve(target).toString();
    }
    final path = Uri.parse(target).path;
    try {
      final file = projectFile(root, path);
      if (!file.existsSync() && !Directory(file.path).existsSync()) {
        errors.add('$page: missing link target $target');
      }
    } on FormatException catch (error) {
      errors.add('$page: $error');
    }
  }
  return errors;
}

String absoluteLinks(String page, String text) =>
    text.replaceAllMapped(_link, (match) {
      final target = match[1]!;
      if (target.startsWith(browserBase)) {
        return ']($rawBase${target.substring(browserBase.length)})';
      }
      if (Uri.parse(target).hasScheme) return match[0]!;
      return '](${Uri.parse(rawBase).resolve(Uri.parse(page).resolve(target).toString())})';
    });

Future<List<String>> processDocumentation(Directory root,
    {required bool write}) async {
  final errors = <String>[];
  final api =
      jsonDecode(projectFile(root, 'tool/upstream_api.json').readAsStringSync())
          as Map;
  final tests = jsonDecode(
      projectFile(root, 'tool/upstream_tests.json').readAsStringSync()) as Map;
  final compatibility = jsonDecode(
      projectFile(root, 'tool/upstream_api_compatibility.json')
          .readAsStringSync()) as Map;
  final target = compatibility['target'] as Map;
  if (api['commit'] != tests['commit'] ||
      api['commit'] != target['commit'] ||
      api['version'] != tests['version'] ||
      api['version'] != target['aiClient']) {
    throw const FormatException(
        'Upstream manifests disagree; review the compatibility pin');
  }
  final pubspec = projectFile(root, 'pubspec.yaml').readAsLinesSync();
  final version = pubspec
      .firstWhere((line) => line.startsWith('version:'))
      .split(':')
      .last
      .trim();
  final sdk = pubspec
      .firstWhere((line) => line.trimLeft().startsWith('sdk:'))
      .split(':')
      .last
      .trim()
      .replaceAll('"', '')
      .replaceAll("'", '');
  final summary =
      'Dart API $version; Dart SDK $sdk; @tanstack/ai-client ${target['aiClient']}; @tanstack/ai ${target['ai']}; upstream commit ${target['commit']}.';
  final pages = <String, String>{};
  void output(String path, String expected) {
    final file = projectFile(root, path);
    if (write) {
      file.writeAsStringSync(expected);
    } else if (!file.existsSync() || file.readAsStringSync() != expected) {
      errors.add('$path is stale; run dart run tool/docs.dart generate');
    }
  }

  for (final (path, _, _, _) in documentation) {
    final original = projectFile(root, path).readAsStringSync();
    var expected = refreshExamples(original, root);
    if (path == 'README.md') {
      final block =
          '<!-- compatibility:start -->\n| Compatibility | Supported target |\n| --- | --- |\n| Dart package API | `$version` |\n| Dart SDK | `$sdk` |\n| Official client | `@tanstack/ai-client ${target['aiClient']}` |\n| Official core protocol | `@tanstack/ai ${target['ai']}` |\n| Upstream source | [`${target['commit']}`](https://github.com/TanStack/ai/tree/${target['commit']}) |\n<!-- compatibility:end -->';
      final marker = RegExp(
          r'<!-- compatibility:start -->[\s\S]*?<!-- compatibility:end -->');
      if (!marker.hasMatch(expected)) {
        throw const FormatException('README lacks compatibility markers');
      }
      expected = expected.replaceFirst(marker, block);
    }
    // Application guide snippets must come from source analyzed by dart analyze.
    if (path == 'README.md' ||
        path.startsWith('doc/') && !path.startsWith('doc/maintainers/')) {
      if ('```dart'.allMatches(expected).length !=
          _example.allMatches(expected).length) {
        errors.add('$path: Dart snippets must use generated example blocks');
      }
    }
    pages[path] = expected;
    output(path, expected);
  }
  final index = StringBuffer(
      '# tanstack_ai_dart\n\n> Unofficial Dart client for TanStack AI chat and generation.\n\n$summary\n\nUse Dart constructors, enums, typed fetcher variants, and state streams.\nThe package is not published to pub.dev yet. Server/provider adapters and\nreal device host implementations are outside this client package.\n\n');
  for (final group in ['Guides', 'Compatibility', 'Optional']) {
    index.writeln('## $group\n');
    for (final (path, title, description, section) in documentation) {
      if (section == group) {
        index.writeln('- [$title]($rawBase$path): $description');
      }
    }
    if (group == 'Optional') {
      index.writeln(
          '- [Combined reference](${rawBase}llms-full.txt): Generated full documentation in one file.');
    }
    index.writeln();
  }
  output('llms.txt', '${index.toString().trimRight()}\n');
  final full = StringBuffer(
      '# tanstack_ai_dart documentation\n\n> Generated by `dart run tool/docs.dart generate`. Edit the linked source files.\n\n$summary\n\n');
  for (final (path, title, _, _) in documentation) {
    full.writeln('## $title\n\nSource: [$path]($rawBase$path)\n');
    final content = absoluteLinks(path, pages[path]!).replaceAllMapped(
        RegExp(r'^(#{1,5}) ', multiLine: true), (m) => '#${m[1]} ');
    full.writeln('$content\n');
  }
  output('llms-full.txt', '${full.toString().trimRight()}\n');
  for (final entry in pages.entries) {
    errors.addAll(brokenLinks(root, entry.key, entry.value));
  }
  return errors;
}

Future<void> main(List<String> args) async {
  if (args.length != 1 || !['generate', 'check'].contains(args.single)) {
    stderr.writeln('Usage: dart run tool/docs.dart generate|check');
    exitCode = 64;
    return;
  }
  try {
    final errors = await processDocumentation(Directory.current,
        write: args.single == 'generate');
    for (final error in errors) {
      stderr.writeln(error);
    }
    if (errors.isNotEmpty) {
      exitCode = 1;
    } else {
      stdout.writeln(
          'Documentation ${args.single} passed (${documentation.length} source pages).');
    }
  } on Object catch (error) {
    stderr.writeln('Documentation ${args.single} failed: $error');
    exitCode = 1;
  }
}
