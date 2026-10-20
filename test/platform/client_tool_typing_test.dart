// Typing counterparts for packages/ai-client/tests/web-mcp-tools-types.test.ts.
//
// Dart has no conditional mapped types. `ClientTool<TInput, TOutput>` and
// `ClientToolExecute<TInput, TOutput>` provide the equivalent callback
// contract. Positive and negative fixtures are analyzed from
// `.dart_tool/platform_type_fixtures` so compile-time failures are verified
// rather than inferred from runtime equality.
import 'dart:io';

import 'package:tanstack_ai_dart/platform.dart';
import 'package:test/test.dart';

const _positiveFixture = '''
import 'package:tanstack_ai_dart/platform.dart';

class SearchInput {
  final String query;
  SearchInput(this.query);
}

class SearchOutput {
  final String query;
  SearchOutput(this.query);
}

void main() {
  final explicit = ClientTool<SearchInput, SearchOutput>(
    name: 'search_products',
    description: 'Search products',
    execute: (SearchInput input, ToolCallContext context) async =>
        SearchOutput(input.query),
  );
  final ClientToolExecute<SearchInput, SearchOutput> callback =
      (input, context) => SearchOutput(input.query);
  final assigned = ClientTool<SearchInput, SearchOutput>(
    name: 'assigned_callback',
    description: 'Assigned callback',
    execute: callback,
  );
  final inferred = ClientTool(
    name: 'inferred',
    description: 'Inferred callback types',
    execute: (SearchInput input, ToolCallContext context) async =>
        SearchOutput(input.query),
  );
  final ClientTool<SearchInput, SearchOutput> inferredCheck = inferred;
  final ClientTool raw = ClientTool(
    name: 'raw_untyped',
    description: 'Raw backward compatibility',
    execute: (input, context) => input,
  );
  print('\${explicit.name}\${assigned.name}\${inferredCheck.name}\${raw.name}');
}
''';

const _wrongInputFixture = '''
import 'package:tanstack_ai_dart/platform.dart';

class SearchInput {
  final String query;
  SearchInput(this.query);
}

class SearchOutput {
  final String query;
  SearchOutput(this.query);
}

void main() {
  ClientTool<SearchInput, SearchOutput>(
    name: 'bad_input',
    description: 'Bad input callback',
    execute: (int input, ToolCallContext context) => SearchOutput('\$input'),
  );
}
''';

const _wrongOutputFixture = '''
import 'package:tanstack_ai_dart/platform.dart';

class SearchInput {
  final String query;
  SearchInput(this.query);
}

class SearchOutput {
  final String query;
  SearchOutput(this.query);
}

void main() {
  ClientTool<SearchInput, SearchOutput>(
    name: 'bad_output',
    description: 'Bad output callback',
    execute: (SearchInput input, ToolCallContext context) async => 42,
  );
}
''';

const _missingSignalFixture = '''
import 'package:tanstack_ai_dart/platform.dart';

void main() {
  RegisterWebMCPToolsOptions();
}
''';

const _crossOriginFixture = '''
import 'package:tanstack_ai_dart/platform.dart';

void main() {
  RegisterWebMCPToolsOptions(
    signal: CancellationSignal(),
    exposedTo: ['https://agent.example'],
  );
}
''';

void main() {
  group('ClientTool typing fixtures', () {
    late Directory fixtureDir;

    setUpAll(() {
      final packageRoot = Directory.current;
      if (!File('${packageRoot.path}/pubspec.yaml').existsSync()) {
        throw StateError('Run this test from packages/tanstack_ai_dart.');
      }
      fixtureDir = Directory(
        '${packageRoot.path}/.dart_tool/platform_type_fixtures',
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

    test('typed callback input and output compile', () {
      final result = analyze('positive', _positiveFixture);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });

    test('rejects a callback input that is not TInput', () {
      final result = analyze('wrong_input', _wrongInputFixture);
      expect(result.exitCode, isNot(0));
      expect(
        '${result.stdout}${result.stderr}',
        contains('argument_type_not_assignable'),
      );
    });

    test('rejects a callback output that is not TOutput', () {
      final result = analyze('wrong_output', _wrongOutputFixture);
      expect(result.exitCode, isNot(0));
      expect(
        '${result.stdout}${result.stderr}',
        contains('return_of_invalid_type'),
      );
    });

    test('requires a lifecycle signal', () {
      final result = analyze('missing_signal', _missingSignalFixture);
      expect(result.exitCode, isNot(0));
      expect(
        '${result.stdout}${result.stderr}',
        contains('missing_required_argument'),
      );
    });

    test('does not expose cross-origin registration options', () {
      final result = analyze('cross_origin', _crossOriginFixture);
      expect(result.exitCode, isNot(0));
      expect(
        '${result.stdout}${result.stderr}',
        contains("named parameter 'exposedTo' isn't defined"),
      );
    });

    test('raw untyped ClientTool stays backward compatible', () {
      final ClientTool raw = ClientTool(
        name: 'raw',
        description: 'Raw',
        execute: (input, context) => input,
      );
      expect(raw, isA<ClientTool<dynamic, dynamic>>());
      expect(raw.hasExecute, isTrue);
    });
  });
}
