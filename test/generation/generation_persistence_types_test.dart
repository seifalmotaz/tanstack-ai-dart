@TestOn('vm')
library;

// Ported from `packages/ai-client/tests/generation-persistence-types.test.ts`.
//
// The analyzer fixtures verify required client identity and typed inputs.
import 'dart:async';
import 'dart:io';

import '../../tool/analyzer_command.dart';

import 'package:tanstack_ai_dart/connections.dart';
import 'package:tanstack_ai_dart/generation.dart';
import 'package:test/test.dart';

const _positiveFixture = r'''
import 'package:tanstack_ai_dart/generation.dart';
void main() {
  GenerationClient<String, int, int>.fetcher(
    threadId: 'product-123',
    persistence: const GenerationPersistenceOptions.persistent(),
    fetcher: (input, options) => const GenerationFetchResult.value(1),
  );
  VideoGenerationClient<VideoGenerateResult>.fetcher(
    threadId: 'video-9',
    fetcher: (input, options) => const GenerationFetchResult.value(VideoGenerateResult(jobId: 'job', url: 'https://example.test')),
  );
}
''';

const _missingThreadIdFixture = r'''
import 'package:tanstack_ai_dart/generation.dart';
void main() {
  GenerationClient<String, int, int>.fetcher(
    persistence: const GenerationPersistenceOptions.persistent(),
    fetcher: (input, options) => const GenerationFetchResult.value(1),
  );
  VideoGenerationClient<VideoGenerateResult>.fetcher(
    fetcher: (input, options) => const GenerationFetchResult.value(VideoGenerateResult(jobId: 'job', url: 'https://example.test')),
  );
  GenerationClient<String, int, int>.fetcher(
    fetcher: (input, options) => const GenerationFetchResult.value(1),
  );
  VideoGenerationClient<VideoGenerateResult>.fetcher(
    persistence: const GenerationPersistenceOptions.persistent(),
    fetcher: (input, options) => const GenerationFetchResult.value(VideoGenerateResult(jobId: 'job', url: 'https://example.test')),
  );
}
''';

const _clientIdFixture = r'''
import 'package:tanstack_ai_dart/connections.dart';
import 'package:tanstack_ai_dart/generation.dart';

void main() {
  GenerationClient<Map<String, dynamic>, Object?, Object?>.legacy(
    threadId: 'product-123-hero',
    connection: ConnectionAdapter.connect(connect: (messages, {data, signal, required runContext}) => const Stream.empty(),
    ),
    id: 'legacy',
  );
  VideoGenerationClient<Object?>.legacy(
    threadId: 'video-9-start-frame',
    connection: ConnectionAdapter.connect(connect: (messages, {data, signal, required runContext}) => const Stream.empty(),
    ),
    id: 'legacy',
  );
}
''';

const _optionsIdFixture = r'''
import 'package:tanstack_ai_dart/generation.dart';

void main() {
  const options = GenerationPersistenceOptions.persistent();
  final id = options.id;
  // ignore: avoid_print
  print(id);
}
''';

const _wrongInputFixture = r'''
import 'package:tanstack_ai_dart/generation.dart';

void main() {
  final client = GenerationClient<Map<String, dynamic>, Object?, Object?>.legacy(
    fetcher: (input, options) async => input,
  );
  client.generate('not-a-map');
}
''';

const _wrongOutputFixture = r'''
import 'package:tanstack_ai_dart/generation.dart';

void main() {
  GenerationClient<Map<String, dynamic>, Object?, String>.legacy(
    fetcher: (input, options) async => input,
    onResult: (result) => GenerationTransformOutcome.value(42),
  );
}
''';

void main() {
  group('GenerationClient persistence requires a threadId', () {
    late Directory fixtureDir;

    setUpAll(() {
      final packageRoot = Directory.current;
      if (!File('${packageRoot.path}/pubspec.yaml').existsSync()) {
        throw StateError('Run this test from packages/tanstack_ai_dart.');
      }
      fixtureDir = Directory(
        '${packageRoot.path}/.dart_tool/generation_type_fixtures',
      )..createSync(recursive: true);
    });

    tearDownAll(() {
      if (fixtureDir.existsSync()) fixtureDir.deleteSync(recursive: true);
    });

    ProcessResult analyze(String name, String source) {
      final file = File('${fixtureDir.path}/$name.dart')
        ..writeAsStringSync(source);
      return Process.runSync(
        Platform.resolvedExecutable,
        analyzerArguments(['--no-fatal-warnings', file.path]),
      );
    }

    void expectAnalyzerError(ProcessResult result, String code) {
      expect(result.exitCode, isNot(0),
          reason: '${result.stdout}\n${result.stderr}');
      expect('${result.stdout}${result.stderr}', contains(code));
    }

    test('rejects persistence: true without a threadId', () {
      final result = analyze('missing_thread_id', _missingThreadIdFixture);
      expectAnalyzerError(result, 'missing_required_argument');
      expect(
          RegExp('missing_required_argument')
              .allMatches('${result.stdout}')
              .length,
          4);
    });

    test('accepts persistence when a threadId is supplied', () {
      final result = analyze('persistent_with_thread_id', _positiveFixture);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });

    test('accepts an explicit threadId for ephemeral generations', () {
      final result = analyze('ephemeral', _positiveFixture);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });

    test('rejects `id` next to a required `threadId`', () {
      // Upstream rejects `id: 'legacy'` on both clients. Dart has no `id`
      // named parameter on either constructor.
      expectAnalyzerError(
        analyze('client_id', _clientIdFixture),
        'undefined_named_parameter',
      );
    });

    test('does not list `id` on generation persistence options', () {
      expectAnalyzerError(
        analyze('options_id', _optionsIdFixture),
        'undefined_getter',
      );
      final result = analyze('options_thread_id', _positiveFixture);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });
  });

  group('GenerationClient generic input and output', () {
    late Directory fixtureDir;

    setUpAll(() {
      final packageRoot = Directory.current;
      fixtureDir = Directory(
        '${packageRoot.path}/.dart_tool/generation_type_fixtures',
      )..createSync(recursive: true);
    });

    tearDownAll(() {
      if (fixtureDir.existsSync()) fixtureDir.deleteSync(recursive: true);
    });

    ProcessResult analyze(String name, String source) {
      final file = File('${fixtureDir.path}/$name.dart')
        ..writeAsStringSync(source);
      return Process.runSync(
        Platform.resolvedExecutable,
        analyzerArguments(['--no-fatal-warnings', file.path]),
      );
    }

    test('rejects an input that is not TInput', () {
      final result = analyze('wrong_input', _wrongInputFixture);
      expect(result.exitCode, isNot(0),
          reason: '${result.stdout}\n${result.stderr}');
      expect('${result.stdout}${result.stderr}',
          contains('argument_type_not_assignable'));
    });

    test('rejects a transform value that is not TOutput', () {
      final result = analyze('wrong_output', _wrongOutputFixture);
      expect(result.exitCode, isNot(0),
          reason: '${result.stdout}\n${result.stderr}');
      expect('${result.stdout}${result.stderr}',
          contains('argument_type_not_assignable'));
    });
  });

  group('GenerationClient runtime persistence warning', () {
    test('warns when persistence: true has no stable threadId', () {
      final messages = <String>[];
      runZoned(
        () {
          GenerationClient.legacy(
            connection: ConnectionAdapter.connect(
              connect: (messages, {data, signal, required runContext}) =>
                  const Stream.empty(),
            ),
            persistence: true,
          );
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => messages.add(line),
        ),
      );
      expect(
        messages.join('\n'),
        contains('`persistence` needs a stable `threadId`'),
      );
    });
  });
}
