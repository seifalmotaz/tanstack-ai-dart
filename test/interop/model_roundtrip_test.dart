import 'dart:convert';
import 'dart:io';

import 'package:tanstack_ai_dart/src/chat/connection_transport.dart';
import 'package:tanstack_ai_dart/src/chat/message_snapshot.dart';
import 'package:tanstack_ai_dart/src/protocol.dart';
import 'package:test/test.dart';

dynamic _copy(dynamic value) =>
    value == null ? null : jsonDecode(jsonEncode(value));

List<Map<String, dynamic>> _partsFromFixture(Map<String, dynamic> fixture) {
  final parts = <Map<String, dynamic>>[];
  for (final key in <String>['uiToModel', 'uiToWire', 'snapshotWire']) {
    final cases = fixture[key];
    if (cases is! List) continue;
    for (final entry in cases) {
      final input = entry is Map ? entry['input'] : null;
      if (input is! List) continue;
      for (final message in input) {
        if (message is! Map) continue;
        final rawParts = message['parts'];
        if (rawParts is! List) continue;
        for (final part in rawParts) {
          if (part is Map) parts.add(Map<String, dynamic>.from(part));
        }
      }
    }
  }
  return parts;
}

void main() {
  final fixture = jsonDecode(
    File('test/processing/fixtures/message_converters.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final fixtureParts = _partsFromFixture(fixture);
  final seenTypes = <String>{};

  group('official UI part round-trip', () {
    for (var i = 0; i < fixtureParts.length; i++) {
      final part = fixtureParts[i];
      final type = part['type'] as String? ?? '';
      final label = 'part $i ($type)';
      test(label, () {
        final parsed = AssistantPart.fromJson(_copy(part));
        expect(parsed.toJson(), _copy(part));
      });
      seenTypes.add(type);
    }
  });

  test('fixture covers every modern UI part type', () {
    expect(
      seenTypes,
      containsAll(<String>[
        'text',
        'thinking',
        'tool-call',
        'tool-result',
        'structured-output',
        'subagent',
        'ui-resource',
        'activity',
        'image',
        'audio',
        'document',
      ]),
    );
  });

  group('mutated known fields are honored', () {
    test('text content', () {
      final part = AssistantPart.fromJson(<String, dynamic>{
        'type': 'text',
        'content': 'old',
        'metadata': {'detail': 'high'},
        'future': true,
      });
      part.content = 'new';
      part.metadata = {'detail': 'low'};
      expect(part.toJson(), <String, dynamic>{
        'type': 'text',
        'content': 'new',
        'metadata': {'detail': 'low'},
        'future': true,
      });
    });

    test('thinking signature and redaction', () {
      final part = AssistantPart.fromJson(<String, dynamic>{
        'type': 'thinking',
        'id': 'r1',
        'content': 'thinking',
        'signature': 'sig',
        'redacted': true,
        'future': 'kept',
      });
      expect(part.signature, 'sig');
      expect(part.redacted, isTrue);
      part.signature = 'sig-2';
      part.redacted = false;
      part.content = 'next';
      expect(part.toJson(), <String, dynamic>{
        'type': 'thinking',
        'id': 'r1',
        'content': 'next',
        'signature': 'sig-2',
        'redacted': false,
        'future': 'kept',
      });
    });

    test('tool-call input, output, state, arguments, approval and metadata',
        () {
      final part = AssistantPart.fromJson(<String, dynamic>{
        'type': 'tool-call',
        'id': 'tc',
        'name': 'lookup',
        'arguments': '{"a":1}',
        'state': 'input-complete',
        'input': {'a': 1},
        'output': null,
        'approval': {'id': 'ap', 'needsApproval': true},
        'metadata': {'thoughtSignature': 'sig'},
        'future': 1,
      });
      part.arguments = '{"a":2}';
      part.input = {'a': 2};
      part.output = {'ok': true};
      part.state = 'complete';
      part.approval!.approved = true;
      part.metadata = {'thoughtSignature': 'sig-2'};
      expect(part.toJson(), <String, dynamic>{
        'type': 'tool-call',
        'id': 'tc',
        'name': 'lookup',
        'arguments': '{"a":2}',
        'state': 'complete',
        'input': {'a': 2},
        'output': {'ok': true},
        'approval': {'id': 'ap', 'needsApproval': true, 'approved': true},
        'metadata': {'thoughtSignature': 'sig-2'},
        'future': 1,
      });
    });

    test('tool-result id, name, content, outcome and error', () {
      final part = AssistantPart.fromJson(<String, dynamic>{
        'type': 'tool-result',
        'id': 'r1',
        'name': 'lookup',
        'toolCallId': 'tc',
        'content': 'old',
        'state': 'complete',
        'outcome': 'denied',
        'error': 'old error',
        'createdAt': '2026-01-01T00:00:00.000Z',
        'future': true,
      });
      part.id = 'r2';
      part.name = 'lookup2';
      part.output = 'new';
      part.state = 'error';
      part.outcome = 'cancelled';
      part.error = 'new error';
      expect(part.toJson(), <String, dynamic>{
        'type': 'tool-result',
        'id': 'r2',
        'name': 'lookup2',
        'toolCallId': 'tc',
        'content': 'new',
        'state': 'error',
        'outcome': 'cancelled',
        'error': 'new error',
        'createdAt': '2026-01-01T00:00:00.000Z',
        'future': true,
      });
    });

    test('structured-output partial, reasoning, null data and error', () {
      final part = AssistantPart.fromJson(<String, dynamic>{
        'type': 'structured-output',
        'status': 'streaming',
        'raw': '{"a":',
        'partial': {'a': 1},
        'reasoning': 'why',
        'data': {'a': 1},
        'errorMessage': 'old',
        'future': 'kept',
      });
      part.structuredStatus = 'error';
      part.raw = '{"a":1}';
      part.partial = null;
      part.reasoning = 'because';
      part.data = null;
      part.content = 'new';
      expect(part.toJson(), <String, dynamic>{
        'type': 'structured-output',
        'status': 'error',
        'raw': '{"a":1}',
        'partial': null,
        'reasoning': 'because',
        'data': null,
        'errorMessage': 'new',
        'future': 'kept',
      });
    });

    test('activity content and type', () {
      final part = AssistantPart.fromJson(<String, dynamic>{
        'type': 'activity',
        'activityType': 'SEARCH',
        'content': {'query': 'one'},
        'subagentRunId': 'child',
        'future': true,
      });
      part.activityType = 'PLAN';
      part.activityContent = {'step': 2};
      expect(part.toJson(), <String, dynamic>{
        'type': 'activity',
        'activityType': 'PLAN',
        'content': {'step': 2},
        'subagentRunId': 'child',
        'future': true,
      });
    });

    test('subagent nested data', () {
      final part = AssistantPart.fromJson(<String, dynamic>{
        'type': 'subagent',
        'subagent': {
          'id': 'child',
          'name': 'Research',
          'status': 'running',
          'messages': <dynamic>[],
          'future': 'nested',
        },
        'future': true,
      });
      part.subagent = <String, dynamic>{
        ...part.subagent!,
        'status': 'finished',
        'messages': [
          {
            'id': 'm1',
            'role': 'assistant',
            'parts': [
              {'type': 'text', 'content': 'done'},
            ],
          },
        ],
      };
      expect(part.toJson()['subagent']['status'], 'finished');
      expect(part.toJson()['future'], true);
      expect(part.toJson()['subagent']['future'], 'nested');
    });

    test('modern and legacy ui-resource shapes stay distinct', () {
      final modern = AssistantPart.fromJson(<String, dynamic>{
        'type': 'ui-resource',
        'id': 'resource',
        'uri': 'ui://example',
        'mimeType': 'text/html',
        'content': 'hello',
        'future': true,
      });
      modern.id = 'resource-2';
      expect(modern.toJson(), <String, dynamic>{
        'type': 'ui-resource',
        'id': 'resource-2',
        'uri': 'ui://example',
        'mimeType': 'text/html',
        'content': 'hello',
        'future': true,
      });

      final legacy = AssistantPart(
        type: 'ui-resource',
        toolCallId: 'tc',
        name: 'widget',
        resource: {'uri': 'ui://widget', 'mimeType': 'text/html'},
      );
      expect(legacy.toJson(), <String, dynamic>{
        'type': 'ui-resource',
        'resource': {'uri': 'ui://widget', 'mimeType': 'text/html'},
        'toolCallId': 'tc',
        'toolName': 'widget',
      });
    });

    test('video source round-trips', () {
      final part = AssistantPart.fromJson(<String, dynamic>{
        'type': 'video',
        'source': {'type': 'url', 'value': 'https://example.com/a.mp4'},
        'metadata': {'duration': 3},
        'future': true,
      });
      expect(part.toJson(), <String, dynamic>{
        'type': 'video',
        'source': {'type': 'url', 'value': 'https://example.com/a.mp4'},
        'metadata': {'duration': 3},
        'future': true,
      });
    });

    test('media source and metadata', () {
      final part = AssistantPart.fromJson(<String, dynamic>{
        'type': 'image',
        'id': 'img',
        'source': {'type': 'url', 'value': 'https://example.com/a.png'},
        'metadata': {'detail': 'high'},
        'future': true,
      });
      part.source = {'type': 'url', 'value': 'https://example.com/b.png'};
      part.metadata = {'detail': 'low'};
      expect(part.toJson(), <String, dynamic>{
        'type': 'image',
        'id': 'img',
        'source': {'type': 'url', 'value': 'https://example.com/b.png'},
        'metadata': {'detail': 'low'},
        'future': true,
      });
    });
  });

  group('explicit null and absent values', () {
    test('input and output distinguish absent, null and present', () {
      final missing = AssistantPart.tool(id: 'tc', name: 'lookup');
      expect(missing.hasInput, isFalse);
      expect(missing.hasOutput, isFalse);
      expect(missing.toJson().containsKey('input'), isFalse);
      expect(missing.toJson().containsKey('output'), isFalse);

      final explicit = AssistantPart.tool(
        id: 'tc',
        name: 'lookup',
        input: null,
        output: null,
      );
      expect(explicit.hasInput, isTrue);
      expect(explicit.hasOutput, isTrue);
      expect(explicit.toJson().containsKey('input'), isTrue);
      expect(explicit.toJson().containsKey('output'), isTrue);
      expect(explicit.toJson()['input'], isNull);
      expect(explicit.toJson()['output'], isNull);

      final mutated = AssistantPart.tool(id: 'tc', name: 'lookup');
      mutated.input = null;
      mutated.output = null;
      expect(mutated.toJson()['input'], isNull);
      expect(mutated.toJson()['output'], isNull);
    });

    test('structured-output null data and partial survive parsing', () {
      final part = AssistantPart.fromJson(<String, dynamic>{
        'type': 'structured-output',
        'status': 'complete',
        'raw': 'null',
        'data': null,
        'partial': null,
      });
      expect(part.hasData, isTrue);
      expect(part.hasPartial, isTrue);
      expect(part.toJson().containsKey('data'), isTrue);
      expect(part.toJson()['data'], isNull);
      expect(part.toJson().containsKey('partial'), isTrue);
      expect(part.toJson()['partial'], isNull);
    });
  });

  group('unknown and future parts', () {
    test('unknown part type keeps its type and all fields', () {
      final raw = <String, dynamic>{
        'type': 'future-card',
        'id': 'f1',
        'content': {'x': 1},
        'extra': <String, dynamic>{'nested': true},
      };
      final part = AssistantPart.fromJson(raw);
      expect(part.type, 'future-card');
      expect(part.toJson(), raw);
    });

    test('unknown part type does not become a tool-call', () {
      final part = AssistantPart.fromJson(<String, dynamic>{'type': 'unknown'});
      expect(part.toJson(), <String, dynamic>{'type': 'unknown'});
    });
  });

  group('metadata and source snapshots', () {
    test('nested metadata and source values survive parse and clone', () {
      final raw = <String, dynamic>{
        'type': 'image',
        'source': {
          'type': 'data',
          'value': 'abc',
          'mimeType': 'image/png',
          'future': {'deep': true},
        },
        'metadata': {
          'provider': {
            'name': 'x',
            'options': [1, 2]
          },
        },
      };
      final part = AssistantPart.fromJson(raw);
      final clone = AssistantPart.fromJson(_copy(part.toJson()));
      expect(clone.toJson(), raw);
    });
  });

  group('processor bridge', () {
    test('assistantTurnsFromProcessor preserves modern part fields', () {
      final turns = assistantTurnsFromProcessor(<Map<String, dynamic>>[
        {
          'id': 'a1',
          'role': 'assistant',
          'parts': [
            {
              'type': 'thinking',
              'id': 'r1',
              'content': 'signed',
              'signature': 'sig',
              'redacted': true,
            },
            {
              'type': 'tool-result',
              'id': 'result-1',
              'name': 'lookup',
              'toolCallId': 'tc',
              'content': 'nope',
              'state': 'error',
              'outcome': 'denied',
              'error': 'Failed',
            },
            {
              'type': 'structured-output',
              'status': 'complete',
              'raw': 'null',
              'data': null,
              'partial': {'x': 1},
              'reasoning': 'why',
            },
          ],
        },
      ]);
      final parts = turns.single.parts;
      expect(parts[0].toJson(), {
        'type': 'thinking',
        'id': 'r1',
        'content': 'signed',
        'signature': 'sig',
        'redacted': true,
      });
      expect(parts[1].toJson(), {
        'type': 'tool-result',
        'id': 'result-1',
        'name': 'lookup',
        'toolCallId': 'tc',
        'content': 'nope',
        'state': 'error',
        'outcome': 'denied',
        'error': 'Failed',
      });
      expect(parts[2].toJson(), {
        'type': 'structured-output',
        'status': 'complete',
        'raw': 'null',
        'partial': {'x': 1},
        'reasoning': 'why',
        'data': null,
      });
    });
  });

  group('message snapshots', () {
    AssistantTurn snapshotTurn() {
      final part = AssistantPart.fromJson(<String, dynamic>{
        'type': 'tool-call',
        'id': 'tc',
        'name': 'lookup',
        'arguments': '{}',
        'state': 'approval-requested',
        'input': {
          'nested': {'value': 1}
        },
        'output': null,
        'approval': {'id': 'ap', 'needsApproval': true, 'approved': null},
        'metadata': {
          'nested': {'x': 1}
        },
        'future': {
          'deep': [1, 2]
        },
      });
      return AssistantTurn(
        id: 'a1',
        role: 'assistant',
        parts: [part],
        metadata: {
          'nested': {'x': 1},
        },
      );
    }

    test('freezes turns, parts, nested maps and wire fields', () {
      final frozen = freezeAssistantTurn(snapshotTurn());
      final part = frozen.parts.single;
      expect(() => frozen.streaming = true, throwsUnsupportedError);
      expect(() => frozen.parts.add(part), throwsUnsupportedError);
      expect(() => part.content = 'x', throwsUnsupportedError);
      expect(() => part.input = null, throwsUnsupportedError);
      expect(() => part.output = null, throwsUnsupportedError);
      expect(() => part.hasInput = false, throwsUnsupportedError);
      expect(() => part.hasOutput = false, throwsUnsupportedError);
      expect(() => part.approval!.approved = false, throwsUnsupportedError);
      expect(() => part.metadata['x'] = 2, throwsUnsupportedError);
      expect(() => part.metadata['nested']['x'] = 2, throwsUnsupportedError);
      expect(() => part.input['nested']['value'] = 2, throwsUnsupportedError);
      expect(() => part.wireFields!['future'] = null, throwsUnsupportedError);
      expect(
        () => part.wireFields!['future']['deep'].add(3),
        throwsUnsupportedError,
      );
      expect(() => frozen.metadata!['x'] = 2, throwsUnsupportedError);
    });

    test('freezes structured partial and data maps', () {
      final turn = AssistantTurn(
        id: 'a1',
        role: 'assistant',
        parts: [
          AssistantPart.fromJson(<String, dynamic>{
            'type': 'structured-output',
            'status': 'complete',
            'raw': '{"x":1}',
            'partial': {'x': 1},
            'data': {
              'x': 1,
              'nested': {'y': 2},
            },
          }),
        ],
      );
      final part = freezeAssistantTurn(turn).parts.single;
      expect(() => part.partial = null, throwsUnsupportedError);
      expect(() => part.data = null, throwsUnsupportedError);
      expect(() => part.hasData = false, throwsUnsupportedError);
      expect(() => part.partial['x'] = 2, throwsUnsupportedError);
      expect(() => part.data['nested']['y'] = 3, throwsUnsupportedError);
      expect(() => part.reasoning = 'x', throwsUnsupportedError);
      expect(() => part.signature = 'x', throwsUnsupportedError);
      expect(() => part.redacted = true, throwsUnsupportedError);
      expect(() => part.outcome = 'denied', throwsUnsupportedError);
      expect(() => part.error = 'x', throwsUnsupportedError);
    });

    test('keeps output null and unknown fields visible', () {
      final frozen = freezeAssistantTurn(snapshotTurn());
      final part = frozen.parts.single;
      expect(part.hasOutput, isTrue);
      expect(part.toJson()['output'], isNull);
      expect(part.toJson()['future'], {
        'deep': [1, 2],
      });
      expect(part.wireFields!['future'], {
        'deep': [1, 2],
      });
    });

    test('preserves class instances and callback identity', () {
      final marker = Object();
      void callback() {}
      final turn = AssistantTurn(
        id: 'a1',
        role: 'assistant',
        metadata: {
          'marker': marker,
          'callback': callback,
          'nested': {'marker': marker},
        },
      );
      final frozen = freezeAssistantTurn(turn);
      expect(identical(frozen.metadata!['marker'], marker), isTrue);
      expect(identical(frozen.metadata!['callback'], callback), isTrue);
      expect(
        identical(frozen.metadata!['nested']['marker'], marker),
        isTrue,
      );
    });
  });
}
