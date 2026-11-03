import 'package:tanstack_ai_dart/src/processing/processor.dart';
import 'package:test/test.dart';

Map<String, dynamic> chunk(
  String type, [
  Map<String, dynamic>? fields,
]) =>
    <String, dynamic>{
      'type': type,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      ...?fields,
    };

Map<String, dynamic> runStarted([String runId = 'run-1']) =>
    chunk('RUN_STARTED', {'runId': runId, 'threadId': 'thread-1'});

Map<String, dynamic> runFinished([String runId = 'run-1']) =>
    chunk('RUN_FINISHED', {
      'runId': runId,
      'threadId': 'thread-1',
      'metadata': {
        'tanstack': {'finishReason': 'stop'},
      },
    });

Map<String, dynamic> textStart(String messageId) => chunk(
      'TEXT_MESSAGE_START',
      {'messageId': messageId, 'role': 'assistant'},
    );

Map<String, dynamic> textContent(String delta, String messageId) =>
    chunk('TEXT_MESSAGE_CONTENT', {'messageId': messageId, 'delta': delta});

Map<String, dynamic> textEnd(String messageId) =>
    chunk('TEXT_MESSAGE_END', {'messageId': messageId});

Map<String, dynamic> attributed(
  Map<String, dynamic> event,
  String subagentRunId,
) =>
    <String, dynamic>{...event, 'subagentRunId': subagentRunId};

Map<String, dynamic> started(
  String id, [
  String? parentSubagentRunId,
]) =>
    chunk('SUBAGENT_STARTED', {
      'subagentRunId': id,
      'name': id,
      if (parentSubagentRunId != null)
        'parentSubagentRunId': parentSubagentRunId,
    });

Map<String, dynamic> finished(String id) =>
    chunk('SUBAGENT_FINISHED', {'subagentRunId': id});

Map<String, dynamic> error(String id, String message) =>
    chunk('SUBAGENT_ERROR', {'subagentRunId': id, 'message': message});

Map<String, dynamic> toolChunk(Map<String, dynamic> fields) =>
    chunk('TOOL_CALL_CHUNK', fields);

Map<String, dynamic> toolResult(String toolCallId, String content) =>
    chunk('TOOL_CALL_RESULT', {
      'toolCallId': toolCallId,
      'messageId': 'result-$toolCallId',
      'content': content,
    });

List<Map<String, dynamic>> partsOf(StreamProcessor p) => p
    .getMessages()
    .expand((message) => (message['parts'] as List))
    .whereType<Map>()
    .map((part) => part.cast<String, dynamic>())
    .toList();

List<Map<String, dynamic>> recursiveParts(
  List<Map<String, dynamic>> messages,
) {
  final result = <Map<String, dynamic>>[];
  for (final part in messages
      .expand((message) => (message['parts'] as List))
      .whereType<Map>()
      .map((part) => part.cast<String, dynamic>())) {
    if (part['type'] == 'subagent') {
      result.addAll(recursiveParts(
        (part['subagent']['messages'] as List)
            .map((message) => <String, dynamic>{
                  ...(message as Map).cast<String, dynamic>(),
                })
            .toList(),
      ));
    } else {
      result.add(part);
    }
  }
  return result;
}

List<String> toolCallArguments(StreamProcessor p) =>
    recursiveParts(p.getMessages())
        .where((part) => part['type'] == 'tool-call')
        .map((part) => part['arguments'] as String)
        .toList();

List<String> textContents(StreamProcessor p) => recursiveParts(p.getMessages())
    .where((part) => part['type'] == 'text')
    .map((part) => part['content'] as String)
    .toList();

void main() {
  group('StreamProcessor subagent parts', () {
    test('nests attributed text under a type subagent part', () {
      final p = StreamProcessor();
      p.processChunk(runStarted());
      p.processChunk(chunk('SUBAGENT_STARTED', {
        'subagentRunId': 'sub-1',
        'name': 'researcher',
        'description': 'Looks up facts',
      }));
      p.processChunk(attributed(textStart('child-msg'), 'sub-1'));
      p.processChunk(attributed(textContent('Paris', 'child-msg'), 'sub-1'));
      p.processChunk(attributed(textEnd('child-msg'), 'sub-1'));
      p.processChunk(finished('sub-1'));
      p.processChunk(runFinished());

      final assistant = p
          .getMessages()
          .firstWhere((message) => message['role'] == 'assistant');
      final part = (assistant['parts'] as List)
          .firstWhere((part) => part['type'] == 'subagent');
      expect(part['subagent']['id'], 'sub-1');
      expect(part['subagent']['name'], 'researcher');
      expect(part['subagent']['status'], 'finished');
      expect(part['subagent']['messages'][0]['parts'], [
        {'type': 'text', 'content': 'Paris'},
      ]);
    });

    test(
        'keeps status error when SUBAGENT_FINISHED arrives after SUBAGENT_ERROR',
        () {
      final p = StreamProcessor();
      p.processChunk(runStarted());
      p.processChunk(chunk('SUBAGENT_STARTED', {
        'subagentRunId': 'sub-1',
        'name': 'researcher',
      }));
      p.processChunk(error('sub-1', 'Stopped'));
      p.processChunk(attributed(textStart('late-msg'), 'sub-1'));
      p.processChunk(attributed(textContent('late', 'late-msg'), 'sub-1'));
      p.processChunk(finished('sub-1'));

      final assistant = p
          .getMessages()
          .firstWhere((message) => message['role'] == 'assistant');
      final part = (assistant['parts'] as List)
          .firstWhere((entry) => entry['type'] == 'subagent');
      expect(part['subagent']['status'], 'error');
      expect(part['subagent']['error'], {'message': 'Stopped'});
      expect(part['subagent']['messages'], isEmpty);
    });

    for (final start in <Map<String, dynamic>>[
      {
        'type': 'TOOL_CALL_START',
        'toolCallId': 'child-tool',
        'toolCallName': 'lookup',
      },
      {
        'type': 'TOOL_CALL_CHUNK',
        'toolCallId': 'child-tool',
        'toolCallName': 'lookup',
        'delta': '{}',
      },
    ]) {
      test(
          'routes an untagged result to the child that started the call with ${start['type']}',
          () {
        final p = StreamProcessor();
        p.processChunk(runStarted());
        p.processChunk(chunk('SUBAGENT_STARTED', {
          'subagentRunId': 'sub-1',
          'name': 'researcher',
        }));
        p.processChunk(
            attributed(chunk(start['type'] as String, start), 'sub-1'));
        p.processChunk(toolResult('child-tool', '"found"'));

        final part =
            partsOf(p).firstWhere((entry) => entry['type'] == 'subagent');
        final tool = (part['subagent']['messages'] as List)
            .expand((message) => message['parts'] as List)
            .firstWhere((entry) => entry['type'] == 'tool-call');
        expect(tool['id'], 'child-tool');
        expect(tool['output'], 'found');
      });
    }

    group('an untagged chunk with no id', () {
      test('continues the only open stream of a child', () {
        final p = StreamProcessor();
        p.processChunk(runStarted());
        p.processChunk(started('sub-1'));
        p.processChunk(attributed(
            toolChunk({
              'toolCallId': 'tc-1',
              'toolCallName': 'a',
              'delta': '{"q":',
            }),
            'sub-1'));
        p.processChunk(toolChunk({'delta': '1}'}));
        expect(toolCallArguments(p), ['{"q":1}']);
      });

      test('continues the only open stream of a nested child', () {
        final p = StreamProcessor();
        p.processChunk(runStarted());
        p.processChunk(started('sub-1'));
        p.processChunk(started('sub-2', 'sub-1'));
        p.processChunk(attributed(
            toolChunk({
              'toolCallId': 'tc-2',
              'toolCallName': 'b',
              'delta': '{"q":',
            }),
            'sub-2'));
        p.processChunk(toolChunk({'delta': '2}'}));
        expect(toolCallArguments(p), ['{"q":2}']);
      });

      test('continues the open stream of this processor first', () {
        final p = StreamProcessor();
        p.processChunk(runStarted());
        p.processChunk(started('sub-1'));
        p.processChunk(toolChunk({
          'toolCallId': 'tc-p',
          'toolCallName': 'p',
          'delta': '{"p":',
        }));
        p.processChunk(attributed(
            toolChunk({
              'toolCallId': 'tc-1',
              'toolCallName': 'a',
              'delta': '{}',
            }),
            'sub-1'));
        p.processChunk(toolChunk({'delta': '1}'}));
        expect(toolCallArguments(p), ['{}', '{"p":1}']);
      });

      test('does not guess between two open child streams', () {
        final p = StreamProcessor();
        p.processChunk(runStarted());
        p.processChunk(started('sub-1'));
        p.processChunk(started('sub-2'));
        p.processChunk(attributed(
            toolChunk({
              'toolCallId': 'tc-1',
              'toolCallName': 'a',
              'delta': '{',
            }),
            'sub-1'));
        p.processChunk(attributed(
            toolChunk({
              'toolCallId': 'tc-2',
              'toolCallName': 'b',
              'delta': '{',
            }),
            'sub-2'));
        p.processChunk(toolChunk({'delta': '}'}));
        expect(toolCallArguments(p), ['{', '{']);
      });

      test('closes a child chunk stream when the run finishes', () {
        final p = StreamProcessor();
        p.processChunk(runStarted());
        p.processChunk(started('sub-1'));
        p.processChunk(attributed(
          chunk('TEXT_MESSAGE_CHUNK', {'messageId': 'c-1', 'delta': 'hi'}),
          'sub-1',
        ));
        p.processChunk(runFinished());
        p.processChunk(chunk('TEXT_MESSAGE_CHUNK', {'delta': ' there'}));
        expect(textContents(p), ['hi']);
      });
    });

    test('routes a child tool result by toolCallId after a snapshot', () {
      final p = StreamProcessor();
      p.processChunk(runStarted());
      p.processChunk(started('sub-1'));
      p.processChunk(attributed(
          chunk('TOOL_CALL_START', {
            'toolCallId': 'child-tool',
            'toolCallName': 'lookup',
          }),
          'sub-1'));
      p.processChunk(attributed(
        chunk('TOOL_CALL_ARGS', {
          'toolCallId': 'child-tool',
          'delta': '{"q":"x"}',
        }),
        'sub-1',
      ));
      p.processChunk(toolResult('child-tool', '{"ok":true}'));
      final part =
          partsOf(p).firstWhere((entry) => entry['type'] == 'subagent');
      final tool = (part['subagent']['messages'] as List)
          .expand((message) => message['parts'] as List)
          .firstWhere((entry) => entry['type'] == 'tool-call');
      expect(tool['output'], {'ok': true});
    });

    test('nested subagent cards survive a snapshot', () {
      final p = StreamProcessor();
      p.processChunk(runStarted());
      p.processChunk(started('sub-1'));
      p.processChunk(started('sub-2', 'sub-1'));
      p.processChunk(attributed(textStart('grandchild'), 'sub-2'));
      p.processChunk(attributed(textContent('hello', 'grandchild'), 'sub-2'));
      p.processChunk(attributed(textEnd('grandchild'), 'sub-2'));
      p.processChunk(finished('sub-2'));
      p.processChunk(finished('sub-1'));

      final outer = partsOf(p).firstWhere((part) => part['type'] == 'subagent');
      expect(outer['subagent']['id'], 'sub-1');
      final inner = (outer['subagent']['messages'] as List)
          .expand((message) => message['parts'] as List)
          .firstWhere((part) => part['type'] == 'subagent');
      expect(inner['subagent']['id'], 'sub-2');
      expect(inner['subagent']['messages'][0]['parts'][0]['content'], 'hello');
    });

    test('preserves SUBAGENT_STARTED metadata on the card', () {
      final p = StreamProcessor();
      p.processChunk(runStarted());
      p.processChunk(chunk('SUBAGENT_STARTED', {
        'subagentRunId': 'sub-1',
        'name': 'researcher',
        'description': 'Looks up facts',
        'parentToolCallId': 'call-1',
        'metadata': {'model': 'gpt-5.5'},
      }));
      final part =
          partsOf(p).firstWhere((entry) => entry['type'] == 'subagent');
      expect(part['subagent']['description'], 'Looks up facts');
      expect(part['subagent']['parentToolCallId'], 'call-1');
      expect(part['subagent']['metadata'], {'model': 'gpt-5.5'});
    });

    test('marks a suspended child and preserves its interrupt ids', () {
      final p = StreamProcessor();
      p.processChunk(runStarted());
      p.processChunk(started('sub-1'));
      p.processChunk(chunk('SUBAGENT_FINISHED', {
        'subagentRunId': 'sub-1',
        'outcome': {
          'type': 'suspended',
          'interruptIds': ['i-1', 'i-2']
        },
      }));
      final part =
          partsOf(p).firstWhere((entry) => entry['type'] == 'subagent');
      expect(part['subagent']['status'], 'suspended');
      expect(part['subagent']['interruptIds'], ['i-1', 'i-2']);
    });

    test('restores a subagent card from snapshot wire metadata', () {
      final p = StreamProcessor();
      p.processChunk(chunk('MESSAGES_SNAPSHOT', {
        'messages': [
          {
            'id': 'host',
            'role': 'assistant',
            'content': 'parent',
          },
          {
            'id': 'child-1',
            'role': 'assistant',
            'content': 'child text',
            'subagentRunId': 'sub-1',
            'metadata': {
              'tanstack': {
                'subagent': {
                  'name': 'researcher',
                  'status': 'finished',
                  'description': 'Looks up facts',
                  'parentToolCallId': 'call-1',
                  'metadata': {'model': 'gpt-5.5'},
                },
              },
            },
          },
        ],
      }));
      final assistant = p.getMessages().firstWhere(
            (message) => (message['parts'] as List)
                .any((part) => part['type'] == 'subagent'),
          );
      final part = (assistant['parts'] as List)
          .firstWhere((entry) => entry['type'] == 'subagent');
      expect(part['subagent']['id'], 'sub-1');
      expect(part['subagent']['name'], 'researcher');
      expect(part['subagent']['status'], 'finished');
      expect(part['subagent']['description'], 'Looks up facts');
      expect(part['subagent']['parentToolCallId'], 'call-1');
      expect(part['subagent']['metadata'], {'model': 'gpt-5.5'});
      expect(part['subagent']['messages'][0]['parts'], [
        {'type': 'text', 'content': 'child text'},
      ]);
    });
  });
}
