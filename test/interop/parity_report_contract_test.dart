@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';

void main() {
  group('parity audit explicit mapping verification', () {
    late Map<String, dynamic> manifest;
    late String upstreamName;
    late String upstreamTitle;

    setUp(() {
      manifest = Map<String, dynamic>.from(
        jsonDecode(File('tool/upstream_tests.json').readAsStringSync()) as Map,
      );
      upstreamName = manifest['files'][0]['tests'][0]['name'] as String;
      upstreamTitle = manifest['files'][0]['tests'][0]['title'] as String;
    });

    test('passed mapping is verified; loading/hidden/skipped never count',
        () async {
      final result = await _runAudit(
        mapping: _mapping(upstreamName),
        tests: <_TestEvent>[
          _TestEvent(0, upstreamName, 'success'),
          _TestEvent(1, upstreamName, 'success', hidden: true),
          _TestEvent(2, upstreamName, 'success', skipped: true),
        ],
      );
      expect(result.report['dartPassed'], 1);
      expect(result.report['verifiedRuntime'], 1);
      expect(result.report['mappedRuntime'], 1);
      expect(result.report['mappedButSkipped'], 0);
      expect(result.report['mappedButFailed'], 0);
      expect(result.report['mappedButMissing'], 0);
      expect(result.report['unmapped'], (manifest['runtimeTests'] as int) - 1);
      expect(result.exitCode, 1,
          reason: 'Unmapped cases keep audit incomplete');
    });

    test('mapped but failed cannot count verified', () async {
      final result = await _runAudit(
        mapping: _mapping(upstreamName),
        tests: <_TestEvent>[
          _TestEvent(0, upstreamName, 'error'),
        ],
      );
      expect(result.report['verifiedRuntime'], 0);
      expect(result.report['mappedButFailed'], 1);
      expect(result.report['gaps']['mappedButFailed'], hasLength(1));
    });

    test('mapped but skipped cannot count verified', () async {
      final result = await _runAudit(
        mapping: _mapping(upstreamName),
        tests: <_TestEvent>[
          _TestEvent(0, upstreamName, 'success', skipped: true),
        ],
      );
      expect(result.report['verifiedRuntime'], 0);
      expect(result.report['mappedButSkipped'], 1);
    });

    test('mapped but missing cannot count verified', () async {
      final result = await _runAudit(
        mapping: _mapping(upstreamName),
        tests: <_TestEvent>[],
      );
      expect(result.report['verifiedRuntime'], 0);
      expect(result.report['mappedButMissing'], 1);
    });

    test('title-only match is a review candidate, never verified coverage',
        () async {
      final result = await _runAudit(
        mapping: const <String, dynamic>{},
        tests: <_TestEvent>[
          _TestEvent(0, upstreamTitle, 'success'),
        ],
      );
      expect(result.report['verifiedRuntime'], 0);
      expect(result.report['mappedRuntime'], 0);
      expect(result.report['titleOnlyReviewCandidates'], 1);
      expect(
        (result.report['titleOnlyCandidateDetails'] as List)
            .single['dartTestName'],
        upstreamTitle,
      );
    });

    test('matching every title without mappings still fails the audit',
        () async {
      var id = 0;
      final result = await _runAudit(
        mapping: const {},
        tests: [
          for (final file in manifest['files'])
            for (final item in file['tests'])
              _TestEvent(id++, item['name'] as String, 'success')
        ],
      );
      expect(result.report['verifiedRuntime'], 0);
      expect(result.report['unmapped'], manifest['runtimeTests']);
      expect(result.exitCode, 1);
    });

    test('compile, adaptation, and not-representable stay separate', () async {
      final secondName = manifest['files'][0]['tests'][1]['name'] as String;
      final mapping = <String, dynamic>{
        'cases': [
          {
            'upstreamFile': manifest['files'][0]['file'],
            'upstreamName': upstreamName,
            'dartFile': 'test/example.dart',
            'dartTestName': upstreamName,
            'status': 'implemented',
          },
          {
            'upstreamFile': manifest['files'][0]['file'],
            'upstreamName': secondName,
            'dartFile': 'lib/src/protocol.dart',
            'status': 'not-representable',
            'adaptation': 'no Dart equivalent',
          },
          {
            'upstreamFile': 'ui-types.test-d.ts',
            'upstreamAssertion': 'A compile-only assertion',
            'dartFile': 'test/types/ui_types_positive.dart',
            'status': 'ported-static-adapted',
          },
          {
            'upstreamFile': 'infer-chat-messages.test.ts',
            'upstreamAssertion': 'A runtime adaptation',
            'dartFile': 'test/example.dart',
            'dartTestName': upstreamName,
            'status': 'runtime-preserved',
          },
        ],
      };
      final result = await _runAudit(
        mapping: mapping,
        tests: <_TestEvent>[_TestEvent(0, upstreamName, 'success')],
      );
      expect(result.report['verifiedRuntime'], 1);
      expect(result.report['compileCases'], 1);
      expect(result.report['adaptations'], 1);
      expect(result.report['notRepresentable'], 1);
      expect(result.report['orphanMappings'], 0);
    });
  });
}

Map<String, dynamic> _mapping(String upstreamName) => <String, dynamic>{
      'cases': [
        {
          'upstreamFile': 'activity-types.test.ts',
          'upstreamName': upstreamName,
          'dartFile': 'test/example.dart',
          'dartTestName': upstreamName,
          'status': 'implemented',
        },
      ],
    };

class _TestEvent {
  final int id;
  final String name;
  final String result;
  final bool skipped;
  final bool hidden;

  const _TestEvent(
    this.id,
    this.name,
    this.result, {
    this.skipped = false,
    this.hidden = false,
  });
}

Future<_AuditResult> _runAudit({
  required Map<String, dynamic> mapping,
  required List<_TestEvent> tests,
}) async {
  final temp = Directory('.dart_tool').createTempSync('parity-contract-');
  addTearDown(() => temp.deleteSync(recursive: true));
  final mappingDir = Directory('${temp.path}/mappings')..createSync();
  File('${mappingDir.path}/case_mapping.json')
      .writeAsStringSync(jsonEncode(mapping));
  final input = File('${temp.path}/input.jsonl');
  final report = File('${temp.path}/report.json');
  final markdown = File('${temp.path}/remaining.md');
  final events = <Map<String, dynamic>>[
    {
      'type': 'suite',
      'suite': {
        'id': 0,
        'path': '${Directory.current.path}/test/example.dart',
      },
    },
    for (final test in tests) ...[
      {
        'type': 'testStart',
        'test': {
          'id': test.id,
          'suiteID': 0,
          'name': test.name,
        },
      },
      {
        'type': 'testDone',
        'testID': test.id,
        'result': test.result,
        'skipped': test.skipped,
        'hidden': test.hidden,
      },
    ],
  ];
  input.writeAsStringSync(events.map(jsonEncode).join('\n'));
  final result = await Process.run(Platform.resolvedExecutable, [
    'run',
    'tool/parity_audit.dart',
    input.path,
    report.path,
    mappingDir.path,
    markdown.path,
  ]);
  return _AuditResult(
    result.exitCode,
    jsonDecode(report.readAsStringSync()) as Map<String, dynamic>,
    markdown.existsSync() ? markdown.readAsStringSync() : '',
  );
}

class _AuditResult {
  final int exitCode;
  final Map<String, dynamic> report;
  final String markdown;
  const _AuditResult(this.exitCode, this.report, this.markdown);
}
