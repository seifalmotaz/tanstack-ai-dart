@TestOn('vm')
library;

// Ported from `packages/ai-client/tests/generation-persistence-types.test.ts`.
//
// The upstream assertions are pure TypeScript type checks. Dart cannot express
// a conditional "required when persistence is true" parameter, so
// `GenerationPersistenceOptions.persistent()` carries that contract at the type
// level. These tests run the analyzer on fixtures instead of asserting the
// contract at runtime: a title-only or runtime stand-in would pass even if the
// constructor stopped requiring `threadId`.
//
// The `GenerationClient` constructor keeps the JavaScript-style
// `persistence: true` flag for API parity; it warns at runtime when no stable
// `threadId` was supplied (there is no Dart type-level way to reject that
// call for callers that bypass the typed options).
import 'dart:async';
import 'dart:io';

import 'package:tanstack_ai_dart/connections.dart';
import 'package:tanstack_ai_dart/generation.dart';
import 'package:test/test.dart';

const _positiveFixture = r'''
import 'package:tanstack_ai_dart/generation.dart';

void main() {
  const persistent = GenerationPersistenceOptions.persistent(
    threadId: 'product-123-hero',
  );
  const videoPersistent = GenerationPersistenceOptions.persistent(
    threadId: 'video-9-start-frame',
  );
  const ephemeral = GenerationPersistenceOptions.ephemeral();
  const ephemeralWithId = GenerationPersistenceOptions.ephemeral(
    threadId: 'product-123-hero',
  );
  final String? a = persistent.threadId;
  final String? b = videoPersistent.threadId;
  final String? c = ephemeral.threadId;
  final String? d = ephemeralWithId.threadId;
  // ignore: avoid_print
  print([a, b, c, d]);
}
''';

const _missingThreadIdFixture = r'''
import 'package:tanstack_ai_dart/generation.dart';

const options = GenerationPersistenceOptions.persistent();
''';

const _clientIdFixture = r'''
import 'package:tanstack_ai_dart/connections.dart';
import 'package:tanstack_ai_dart/generation.dart';

void main() {
  GenerationClient<Map<String, dynamic>, Object?, Object?>(
    threadId: 'product-123-hero',
    connection: ConnectionAdapter(
      connect: (messages, {data, signal, runContext}) => const Stream.empty(),
    ),
    id: 'legacy',
  );
  VideoGenerationClient<Object?>(
    threadId: 'video-9-start-frame',
    connection: ConnectionAdapter(
      connect: (messages, {data, signal, runContext}) => const Stream.empty(),
    ),
    id: 'legacy',
  );
}
''';

const _optionsIdFixture = r'''
import 'package:tanstack_ai_dart/generation.dart';

void main() {
  const options = GenerationPersistenceOptions.persistent(
    threadId: 'product-123-hero',
  );
  final id = options.id;
  // ignore: avoid_print
  print(id);
}
''';

const _wrongInputFixture = r'''
import 'package:tanstack_ai_dart/generation.dart';

void main() {
  final client = GenerationClient<Map<String, dynamic>, Object?, Object?>(
    fetcher: (input, options) async => input,
  );
  client.generate('not-a-map');
}
''';

const _wrongOutputFixture = r'''
import 'package:tanstack_ai_dart/generation.dart';

void main() {
  GenerationClient<Map<String, dynamic>, Object?, String>(
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
        ['analyze', '--no-fatal-warnings', file.path],
      );
    }

    void expectAnalyzerError(ProcessResult result, String code) {
      expect(result.exitCode, isNot(0),
          reason: '${result.stdout}\n${result.stderr}');
      expect('${result.stdout}${result.stderr}', contains(code));
    }

    test('rejects persistence: true without a threadId', () {
      // Upstream `@ts-expect-error` on
      // `new GenerationClient({ connection, persistence: true })` and the same
      // call for VideoGenerationClient. Dart's typed equivalent is
      // `GenerationPersistenceOptions.persistent()`, which requires the key.
      expectAnalyzerError(
        analyze('missing_thread_id', _missingThreadIdFixture),
        'missing_required_argument',
      );
    });

    test('accepts persistence when a threadId is supplied', () {
      final result = analyze('persistent_with_thread_id', _positiveFixture);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });

    test('leaves threadId optional for ephemeral generations', () {
      // Covered by `_positiveFixture`: both `ephemeral()` and
      // `ephemeral(threadId: ...)` compile, matching the four upstream calls.
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

    test('does not list `id` on generation option types. `threadId` is present',
        () {
      // Upstream indexes GenerationClientOptions['id'] (a type error) and
      // assigns GenOpts['threadId'] to a string. The Dart port has no
      // GenerationClientOptions type; GenerationPersistenceOptions is the
      // equivalent identity carrier.
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
        ['analyze', '--no-fatal-warnings', file.path],
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
          GenerationClient(
            connection: ConnectionAdapter(
              connect: (messages, {data, signal, runContext}) =>
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
