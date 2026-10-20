import 'package:tanstack_ai_dart/src/processing/message_converters.dart';
import 'package:test/test.dart';

Map<String, dynamic> ui({
  String id = 'm1',
  String role = 'assistant',
  List<dynamic>? parts,
  Map<String, dynamic>? metadata,
  String? name,
  DateTime? createdAt,
}) =>
    <String, dynamic>{
      'id': id,
      'role': role,
      'parts': parts ?? <dynamic>[],
      if (metadata != null) 'metadata': metadata,
      if (name != null) 'name': name,
      if (createdAt != null) 'createdAt': createdAt,
    };

void main() {
  group('Message Converters', () {
    group('uiMessageToModelMessages', () {
      test('keeps the run id and drops the run timings', () {
        final result = uiMessageToModelMessages(ui(
          parts: [
            {'type': 'text', 'content': 'hi'},
          ],
          metadata: {
            'tanstack': {
              'run': {
                'id': 'run-1',
                'startedAt': 1,
                'finishedAt': 2,
              },
            },
          },
        )).single;
        expect(result['metadata'], {
          'tanstack': {
            'run': {'id': 'run-1'},
          },
        });
      });

      test('should convert simple text message', () {
        final result = uiMessageToModelMessages(ui(
          role: 'user',
          parts: [
            {'type': 'text', 'content': 'Hello'},
          ],
        ));
        expect(result, [
          {
            'id': 'm1',
            'role': 'user',
            'content': 'Hello',
          },
        ]);
      });

      test('should convert multiple text parts to single string', () {
        final result = uiMessageToModelMessages(ui(
          role: 'user',
          parts: [
            {'type': 'text', 'content': 'Hello '},
            {'type': 'text', 'content': 'world'},
          ],
        ));
        expect(result.single['content'], 'Hello world');
      });

      test('should convert multimodal message with image to ContentPart array',
          () {
        final result = uiMessageToModelMessages(ui(
          role: 'user',
          parts: [
            {'type': 'text', 'content': 'What is this?'},
            {
              'type': 'image',
              'source': {'type': 'url', 'value': 'https://example.com/a.png'},
            },
          ],
        ));
        final content = result.single['content'] as List;
        expect(content, hasLength(2));
        expect(content[0]['type'], 'text');
        expect(content[1]['type'], 'image');
      });

      for (final type in ['audio', 'video', 'document']) {
        test('should convert multimodal message with $type', () {
          final result = uiMessageToModelMessages(ui(
            role: 'user',
            parts: [
              {
                'type': type,
                'source': {'type': 'url', 'value': 'https://example.com/a'},
              },
            ],
          ));
          expect((result.single['content'] as List).single['type'], type);
        });
      }

      test('should preserve order of text and multimodal parts', () {
        final result = uiMessageToModelMessages(ui(
          role: 'user',
          parts: [
            {'type': 'text', 'content': 'before'},
            {
              'type': 'image',
              'source': {'type': 'url', 'value': 'https://example.com/a'},
            },
            {'type': 'text', 'content': 'after'},
          ],
        ));
        expect(
          (result.single['content'] as List)
              .map((part) => part['type'])
              .toList(),
          ['text', 'image', 'text'],
        );
      });

      test('should preserve thinking parts in conversion', () {
        final result = uiMessageToModelMessages(ui(
          parts: [
            {
              'type': 'thinking',
              'content': 'thinking',
              'signature': 'sig',
            },
            {'type': 'text', 'content': 'answer'},
          ],
        )).single;
        expect(result['thinking'], [
          {'content': 'thinking', 'signature': 'sig'},
        ]);
        expect(result['content'], 'answer');
      });

      test('should preserve thinking order around provider-executed tool calls',
          () {
        final result = uiMessageToModelMessages(ui(
          parts: [
            {
              'type': 'tool-call',
              'id': 'tc-1',
              'name': 'web_search',
              'arguments': '{}',
              'state': 'input-complete',
              'metadata': {'providerExecuted': true},
            },
            {'type': 'thinking', 'content': 'after', 'signature': 'sig'},
            {'type': 'text', 'content': 'Answer'},
          ],
        ));
        expect(result, hasLength(2));
        expect(result[0]['toolCalls'][0]['id'], 'tc-1');
        expect(result[1]['thinking'], [
          {'content': 'after', 'signature': 'sig'},
        ]);
        expect(result[1]['content'], 'Answer');
      });

      test(
          'should keep local tool calls and results in the same assistant turn',
          () {
        final result = uiMessageToModelMessages(ui(
          parts: [
            {'type': 'text', 'content': 'Checking'},
            {
              'type': 'tool-call',
              'id': 'tc-1',
              'name': 'x',
              'arguments': '{}',
              'state': 'complete',
            },
            {
              'type': 'tool-result',
              'toolCallId': 'tc-1',
              'content': '{"ok":true}',
              'state': 'complete',
            },
          ],
        ));
        expect(result.map((message) => message['role']).toList(),
            ['assistant', 'tool']);
        expect(result[0]['content'], 'Checking');
        expect(result[1]['content'], '{"ok":true}');
      });

      test('should skip system messages', () {
        expect(
          uiMessageToModelMessages(ui(
            role: 'system',
            parts: [
              {'type': 'text', 'content': 'system'},
            ],
          )),
          isEmpty,
        );
      });

      test(
          'should handle text-only message without multimodal parts as string content',
          () {
        final result = uiMessageToModelMessages(ui(
          role: 'user',
          parts: [
            {'type': 'text', 'content': 'text only'},
          ],
        ));
        expect(result.single['content'], 'text only');
      });

      test('should handle empty parts array', () {
        final result = uiMessageToModelMessages(ui());
        expect(result, hasLength(1));
        expect(result.single['role'], 'assistant');
        expect(result.single['content'], isNull);
      });

      test('should handle multimodal message with only image (no text)', () {
        final result = uiMessageToModelMessages(ui(
          role: 'user',
          parts: [
            {
              'type': 'image',
              'source': {'type': 'url', 'value': 'https://example.com/a'},
            },
          ],
        ));
        expect(result.single['content'], isA<List<dynamic>>());
      });

      test('should include metadata in multimodal parts', () {
        final result = uiMessageToModelMessages(ui(
          role: 'user',
          parts: [
            {
              'type': 'image',
              'source': {'type': 'url', 'value': 'https://example.com/a'},
              'metadata': {'detail': 'high'},
            },
          ],
        ));
        expect((result.single['content'] as List).single['metadata'],
            {'detail': 'high'});
      });

      test('should handle tool call parts', () {
        final result = uiMessageToModelMessages(ui(
          parts: [
            {
              'type': 'tool-call',
              'id': 'tc-1',
              'name': 'getWeather',
              'arguments': '{"city":"NYC"}',
              'state': 'input-complete',
              'input': {'city': 'NYC'},
            },
          ],
        )).single;
        expect(result['content'], isNull);
        expect(result['toolCalls'], [
          {
            'id': 'tc-1',
            'type': 'function',
            'function': {
              'name': 'getWeather',
              'arguments': '{"city":"NYC"}',
            },
          },
        ]);
      });

      test('should handle tool result parts', () {
        final result = uiMessageToModelMessages(ui(
          parts: [
            {
              'type': 'tool-result',
              'toolCallId': 'tc-1',
              'content': '{"temp":72}',
              'state': 'complete',
            },
          ],
        ));
        expect(result.map((message) => message['role']).toList(),
            ['assistant', 'tool']);
        expect(result.last['toolCallId'], 'tc-1');
      });

      test('keeps assistant identity off synthetic tool results', () {
        final result = uiMessageToModelMessages(ui(
          id: 'assistant-1',
          createdAt: DateTime.utc(2026),
          parts: [
            {
              'type': 'tool-call',
              'id': 'tc-1',
              'name': 'x',
              'arguments': '{}',
              'state': 'complete',
              'output': {'ok': true},
            },
          ],
        ));
        final tool = result.last;
        expect(tool['role'], 'tool');
        expect(tool.containsKey('id'), isFalse);
        expect(tool.containsKey('createdAt'), isFalse);
      });

      test('should preserve the UI message id on an empty assistant fallback',
          () {
        final result = uiMessageToModelMessages(ui(id: 'assistant-1'));
        expect(result.single['id'], 'assistant-1');
      });

      test('should preserve interleaving of text, tool calls, and tool results',
          () {
        final result = uiMessageToModelMessages(ui(
          parts: [
            {'type': 'text', 'content': 'text1'},
            {
              'type': 'tool-call',
              'id': 'tc-1',
              'name': 'one',
              'arguments': '{}',
              'state': 'input-complete',
            },
            {
              'type': 'tool-result',
              'toolCallId': 'tc-1',
              'content': 'r1',
              'state': 'complete',
            },
            {'type': 'text', 'content': 'text2'},
            {
              'type': 'tool-call',
              'id': 'tc-2',
              'name': 'two',
              'arguments': '{}',
              'state': 'input-complete',
            },
            {
              'type': 'tool-result',
              'toolCallId': 'tc-2',
              'content': 'r2',
              'state': 'complete',
            },
          ],
        ));
        expect(result.map((message) => message['role']).toList(),
            ['assistant', 'tool', 'assistant', 'tool']);
        expect(result[0]['content'], 'text1');
        expect(result[2]['content'], 'text2');
      });

      test('should handle multi-round tool flow', () {
        final result = uiMessageToModelMessages(ui(
          parts: [
            {'type': 'text', 'content': 'text1'},
            {
              'type': 'tool-call',
              'id': 'tc-1',
              'name': 'one',
              'arguments': '{}',
              'state': 'input-complete',
            },
            {
              'type': 'tool-result',
              'toolCallId': 'tc-1',
              'content': 'result1',
              'state': 'complete',
            },
            {'type': 'text', 'content': 'text2'},
            {
              'type': 'tool-call',
              'id': 'tc-2',
              'name': 'two',
              'arguments': '{}',
              'state': 'input-complete',
            },
            {
              'type': 'tool-result',
              'toolCallId': 'tc-2',
              'content': 'result2',
              'state': 'complete',
            },
          ],
        ));
        expect(result, hasLength(4));
        expect(result[1]['content'], 'result1');
        expect(result[3]['content'], 'result2');
      });

      test('should handle tool-call-only segment (no text before tool call)',
          () {
        final result = uiMessageToModelMessages(ui(
          parts: [
            {
              'type': 'tool-call',
              'id': 'tc-1',
              'name': 'one',
              'arguments': '{}',
              'state': 'input-complete',
            },
            {
              'type': 'tool-result',
              'toolCallId': 'tc-1',
              'content': 'ok',
              'state': 'complete',
            },
          ],
        ));
        expect(result[0]['role'], 'assistant');
        expect(result[0]['content'], isNull);
        expect(result[0]['toolCalls'], hasLength(1));
      });

      test(
          'should not create duplicate tool results when tool-call has output AND tool-result exists',
          () {
        final result = uiMessageToModelMessages(ui(
          parts: [
            {
              'type': 'tool-call',
              'id': 'tc-1',
              'name': 'x',
              'arguments': '{}',
              'state': 'complete',
              'output': {'ok': true},
            },
            {
              'type': 'tool-result',
              'toolCallId': 'tc-1',
              'content': '{"ok":true}',
              'state': 'complete',
            },
          ],
        ));
        expect(
          result.where((message) => message['role'] == 'tool'),
          hasLength(1),
        );
      });

      test('should emit pendingExecution marker for approved client tool', () {
        final result = uiMessageToModelMessages(ui(
          parts: [
            {
              'type': 'tool-call',
              'id': 'tc-1',
              'name': 'x',
              'arguments': '{}',
              'state': 'approval-responded',
              'approval': {'id': 'a', 'needsApproval': true, 'approved': true},
            },
          ],
        ));
        final tool = result.firstWhere((message) => message['role'] == 'tool');
        final content = tool['content'] as String;
        expect(content, contains('"pendingExecution":true'));
      });

      test('should emit declined message for denied client tool', () {
        final result = uiMessageToModelMessages(ui(
          parts: [
            {
              'type': 'tool-call',
              'id': 'tc-1',
              'name': 'x',
              'arguments': '{}',
              'state': 'approval-responded',
              'approval': {'id': 'a', 'needsApproval': true, 'approved': false},
            },
          ],
        ));
        final tool = result.firstWhere((message) => message['role'] == 'tool');
        expect(tool['content'], contains('User denied this action'));
        expect(tool['metadata']['tanstack']['toolResultOutcome'], 'denied');
      });
    });

    group('modelMessageToUIMessage', () {
      test('should convert simple text ModelMessage', () {
        final result = modelMessageToUIMessage({
          'role': 'user',
          'content': 'Hello',
        }, 'id-1');
        expect(result['id'], 'id-1');
        expect(result['role'], 'user');
        expect(result['parts'], [
          {'type': 'text', 'content': 'Hello'},
        ]);
      });

      test('should use provided id', () {
        expect(
          modelMessageToUIMessage({
            'role': 'assistant',
            'content': 'hi',
            'id': 'original',
          }, 'provided')['id'],
          'provided',
        );
      });

      test('should preserve message metadata', () {
        final result = modelMessageToUIMessage({
          'role': 'user',
          'content': 'hi',
          'metadata': {'author': 'dana'},
        });
        expect(result['metadata'], {'author': 'dana'});
      });

      test('should preserve multimodal content parts', () {
        final result = modelMessageToUIMessage({
          'role': 'user',
          'content': [
            {'type': 'text', 'content': 'hi'},
            {
              'type': 'image',
              'source': {'type': 'url', 'value': 'https://example.com/a'},
            },
          ],
        });
        expect(result['parts'].map((part) => part['type']).toList(),
            ['text', 'image']);
      });

      test('should handle tool message', () {
        final result = modelMessageToUIMessage({
          'role': 'tool',
          'toolCallId': 'tc-1',
          'content': '{"ok":true}',
        });
        expect(result['role'], 'assistant');
        expect(result['parts'], [
          {
            'type': 'tool-result',
            'toolCallId': 'tc-1',
            'content': '{"ok":true}',
            'state': 'complete',
          },
        ]);
      });

      test('should preserve a tool message error', () {
        final result = modelMessageToUIMessage({
          'role': 'tool',
          'toolCallId': 'tc-1',
          'content': 'boom',
          'error': 'boom',
        });
        expect(result['parts'].single['state'], 'error');
        expect(result['parts'].single['error'], 'boom');
      });

      test('should preserve a cancelled tool result outcome', () {
        final result = modelMessageToUIMessage({
          'role': 'tool',
          'toolCallId': 'tc-1',
          'content': 'cancelled',
          'metadata': {
            'tanstack': {'toolResultOutcome': 'cancelled'},
          },
        });
        expect(result['parts'].single['state'], 'error');
        expect(result['parts'].single['outcome'], 'cancelled');
      });

      test('does not infer a tool result outcome from arbitrary content', () {
        final result = modelMessageToUIMessage({
          'role': 'tool',
          'toolCallId': 'tc-1',
          'content': 'denied',
        });
        expect(result['parts'].single.containsKey('outcome'), isFalse);
      });

      test('should convert assistant message with toolCalls and text', () {
        final result = modelMessageToUIMessage({
          'role': 'assistant',
          'content': 'Calling',
          'toolCalls': [
            {
              'id': 'tc-1',
              'type': 'function',
              'function': {
                'name': 'getWeather',
                'arguments': '{"city":"NYC"}',
              },
            },
          ],
        });
        expect(result['parts'].map((part) => part['type']).toList(),
            ['text', 'tool-call']);
        expect(result['parts'][1]['input'], {'city': 'NYC'});
      });

      test('should convert assistant thinking into UIMessage parts', () {
        final result = modelMessageToUIMessage({
          'role': 'assistant',
          'content': 'Answer',
          'thinking': [
            {'content': 'thinking', 'signature': 'sig'},
          ],
        });
        expect(result['parts'][0], {
          'type': 'thinking',
          'content': 'thinking',
          'signature': 'sig',
        });
        expect(result['parts'][1]['content'], 'Answer');
      });

      test('should convert assistant message with toolCalls and null content',
          () {
        final result = modelMessageToUIMessage({
          'role': 'assistant',
          'content': null,
          'toolCalls': [
            {
              'id': 'tc-1',
              'type': 'function',
              'function': {'name': 'x', 'arguments': '{}'},
            },
          ],
        });
        expect(result['parts'], hasLength(1));
        expect(result['parts'].single['type'], 'tool-call');
      });

      test('should handle null content', () {
        final result = modelMessageToUIMessage({
          'role': 'assistant',
          'content': null,
        });
        expect(result['parts'], isEmpty);
      });

      test('should handle empty string content', () {
        final result = modelMessageToUIMessage({
          'role': 'assistant',
          'content': '',
        });
        expect(result['parts'], isEmpty);
      });

      test('should not produce redundant text part for tool messages', () {
        final result = modelMessageToUIMessage({
          'role': 'tool',
          'toolCallId': 'tc-1',
          'content': 'only result',
        });
        expect(result['parts'], hasLength(1));
        expect(result['parts'].single['type'], 'tool-result');
      });

      test('normalizes a standalone tool createdAt string on message and part',
          () {
        final result = modelMessageToUIMessage({
          'role': 'tool',
          'toolCallId': 'tc-1',
          'content': 'ok',
          'createdAt': '2026-08-20T00:00:00.000Z',
        });
        expect(result['createdAt'], isA<DateTime>());
        expect(result['parts'].single['createdAt'], isA<DateTime>());
      });

      test('removes an invalid standalone tool createdAt', () {
        final result = modelMessageToUIMessage({
          'role': 'tool',
          'toolCallId': 'tc-1',
          'content': 'ok',
          'createdAt': 'not-a-date',
        });
        expect(result.containsKey('createdAt'), isFalse);
        expect(result['parts'].single.containsKey('createdAt'), isFalse);
      });
    });

    group('modelMessagesToUIMessages', () {
      test('should convert simple user + assistant conversation', () {
        final result = modelMessagesToUIMessages([
          {'role': 'user', 'content': 'Hello'},
          {'role': 'assistant', 'content': 'Hi'},
        ]);
        expect(result, hasLength(2));
        expect(result[0]['role'], 'user');
        expect(result[1]['role'], 'assistant');
      });

      test('should merge tool result into preceding assistant message', () {
        final result = modelMessagesToUIMessages([
          {
            'role': 'assistant',
            'content': 'Calling',
            'toolCalls': [
              {
                'id': 'tc-1',
                'type': 'function',
                'function': {'name': 'x', 'arguments': '{}'},
              },
            ],
          },
          {
            'role': 'tool',
            'toolCallId': 'tc-1',
            'content': '{"ok":true}',
          },
        ]);
        expect(result, hasLength(1));
        expect(result.single['parts'].map((part) => part['type']).toList(),
            ['text', 'tool-call', 'tool-result']);
        expect(result.single['parts'][1]['output'], {'ok': true});
      });

      test('should handle multi-round tool flow with proper merging', () {
        final result = modelMessagesToUIMessages([
          {
            'role': 'assistant',
            'content': 'one',
            'toolCalls': [
              {
                'id': 'tc-1',
                'type': 'function',
                'function': {'name': 'x', 'arguments': '{}'},
              },
            ],
          },
          {
            'role': 'tool',
            'toolCallId': 'tc-1',
            'content': 'r1',
          },
          {
            'role': 'assistant',
            'content': 'two',
            'toolCalls': [
              {
                'id': 'tc-2',
                'type': 'function',
                'function': {'name': 'y', 'arguments': '{}'},
              },
            ],
          },
          {
            'role': 'tool',
            'toolCallId': 'tc-2',
            'content': 'r2',
          },
        ]);
        expect(result, hasLength(2));
        expect(result[1]['parts'].map((part) => part['type']).toList(),
            ['text', 'tool-call', 'tool-result']);
      });

      test('should create standalone message for orphan tool result', () {
        final result = modelMessagesToUIMessages([
          {'role': 'tool', 'toolCallId': 'tc-1', 'content': 'r'},
        ]);
        expect(result, hasLength(1));
        expect(result.single['parts'].single['type'], 'tool-result');
      });

      test('should not merge tool result across user messages', () {
        final result = modelMessagesToUIMessages([
          {'role': 'assistant', 'content': 'a'},
          {'role': 'user', 'content': 'u'},
          {'role': 'tool', 'toolCallId': 'tc-1', 'content': 'r'},
        ]);
        expect(result, hasLength(3));
        expect(result[2]['parts'].single['type'], 'tool-result');
      });
    });

    group('convertMessagesToModelMessages', () {
      test('should pass through ModelMessages unchanged', () {
        final messages = <dynamic>[
          {'role': 'user', 'content': 'Hello'},
        ];
        expect(convertMessagesToModelMessages(messages), [
          {'role': 'user', 'content': 'Hello'},
        ]);
      });

      test('should convert UIMessages to ModelMessages', () {
        final result = convertMessagesToModelMessages(<dynamic>[
          ui(
            role: 'user',
            parts: [
              {'type': 'text', 'content': 'Hello'},
            ],
          ),
        ]);
        expect(result.single['content'], 'Hello');
      });

      test('preserves an explicit model message createdAt over metadata', () {
        final date = DateTime.utc(2026);
        final result = convertMessagesToModelMessages(<dynamic>[
          {
            'role': 'user',
            'content': 'hi',
            'createdAt': date,
            'metadata': {
              'tanstack': {'createdAt': '2020-01-01T00:00:00.000Z'},
            },
          },
        ]);
        expect(result.single['createdAt'], date);
      });

      test('restores a valid metadata.tanstack.createdAt when absent', () {
        final result = convertMessagesToModelMessages(<dynamic>[
          {
            'role': 'user',
            'content': 'hi',
            'metadata': {
              'tanstack': {'createdAt': '2026-08-20T00:00:00.000Z'},
            },
          },
        ]);
        expect(result.single['createdAt'], isA<DateTime>());
      });

      test('coerces a JSON-revived createdAt string into a DateTime', () {
        final result = convertMessagesToModelMessages(<dynamic>[
          {
            'role': 'user',
            'content': 'hi',
            'createdAt': '2026-08-20T00:00:00.000Z',
          },
        ]);
        expect(result.single['createdAt'], isA<DateTime>());
      });

      test('drops an invalid createdAt string on the model message', () {
        final result = convertMessagesToModelMessages(<dynamic>[
          {'role': 'user', 'content': 'hi', 'createdAt': 'not-a-date'},
        ]);
        expect(result.single.containsKey('createdAt'), isFalse);
      });

      test('should preserve message metadata from UIMessages', () {
        final result = convertMessagesToModelMessages(<dynamic>[
          ui(
            role: 'user',
            parts: [
              {'type': 'text', 'content': 'hi'},
            ],
            metadata: {'author': 'dana'},
          ),
        ]);
        expect(result.single['metadata'], {'author': 'dana'});
      });

      test('should handle mixed UIMessage and ModelMessage array', () {
        final result = convertMessagesToModelMessages(<dynamic>[
          {'role': 'user', 'content': 'model'},
          ui(
            role: 'assistant',
            parts: [
              {'type': 'text', 'content': 'ui'},
            ],
          ),
        ]);
        expect(result.map((message) => message['content']).toList(),
            ['model', 'ui']);
      });

      test('should handle empty array', () {
        expect(convertMessagesToModelMessages(<dynamic>[]), isEmpty);
      });
    });

    group('normalizeToUIMessage', () {
      test('should pass through UIMessage with existing id and createdAt', () {
        final date = DateTime.utc(2026);
        final result = normalizeToUIMessage(
          ui(id: 'u1', createdAt: date),
          () => 'generated',
        );
        expect(result['id'], 'u1');
        expect(result['createdAt'], date);
      });

      test('should generate id for UIMessage without id', () {
        final result = normalizeToUIMessage(
          {'role': 'user', 'parts': <dynamic>[]},
          () => 'generated',
        );
        expect(result['id'], 'generated');
      });

      test('should convert ModelMessage to UIMessage', () {
        final result = normalizeToUIMessage(
          {'role': 'user', 'content': 'hi'},
          () => 'generated',
        );
        expect(result['role'], 'user');
        expect(result['id'], 'generated');
        expect(result['parts'].single['content'], 'hi');
      });

      test('should preserve createdAt when converting a ModelMessage', () {
        final date = DateTime.utc(2026);
        final result = normalizeToUIMessage(
          {'role': 'user', 'content': 'hi', 'createdAt': date},
          () => 'generated',
        );
        expect(result['createdAt'], date);
      });
    });

    group('Round-trip symmetry: UI -> Model -> UI', () {
      test('should round-trip simple text user message', () {
        final original = ui(
          id: 'u1',
          role: 'user',
          parts: [
            {'type': 'text', 'content': 'Hello'},
          ],
        );
        final round = modelMessagesToUIMessages(
          convertMessagesToModelMessages(<dynamic>[original]),
        );
        expect(round.single['parts'], original['parts']);
      });

      test('should round-trip assistant with tool-call + tool-result', () {
        final original = ui(
          id: 'a1',
          parts: [
            {'type': 'text', 'content': 'Calling'},
            {
              'type': 'tool-call',
              'id': 'tc-1',
              'name': 'x',
              'arguments': '{}',
              'state': 'complete',
            },
            {
              'type': 'tool-result',
              'toolCallId': 'tc-1',
              'content': '{"ok":true}',
              'state': 'complete',
            },
          ],
        );
        final round = modelMessagesToUIMessages(
          convertMessagesToModelMessages(<dynamic>[original]),
        );
        expect(round.single['parts'].map((part) => part['type']).toList(),
            ['text', 'tool-call', 'tool-result']);
        expect(round.single['parts'][1]['output'], {'ok': true});
      });

      test('should round-trip multimodal user message with image', () {
        final original = ui(
          role: 'user',
          parts: [
            {'type': 'text', 'content': 'Look'},
            {
              'type': 'image',
              'source': {'type': 'url', 'value': 'https://example.com/a'},
            },
          ],
        );
        final round = modelMessagesToUIMessages(
          convertMessagesToModelMessages(<dynamic>[original]),
        );
        expect(round.single['parts'].map((part) => part['type']).toList(),
            ['text', 'image']);
      });

      test('round-trips name, metadata, tool error, and ui-resource parts', () {
        final resource = {
          'type': 'ui-resource',
          'resource': {
            'uri': 'ui://widget',
            'mimeType': 'text/html',
          },
          'toolCallId': 'tc-1',
          'toolName': 'widget',
        };
        final original = ui(
          id: 'a1',
          name: 'Ada',
          metadata: {
            'author': {'id': '1'}
          },
          parts: [
            {
              'type': 'tool-call',
              'id': 'tc-1',
              'name': 'widget',
              'arguments': '{}',
              'state': 'error',
            },
            {
              'type': 'tool-result',
              'toolCallId': 'tc-1',
              'content': 'oops',
              'state': 'error',
              'error': 'oops',
            },
            resource,
          ],
        );
        final round = modelMessagesToUIMessages(
          convertMessagesToModelMessages(<dynamic>[original]),
        ).single;
        expect(round['name'], 'Ada');
        expect(round['metadata']['author'], {'id': '1'});
        final result = round['parts'].firstWhere(
          (part) => part['type'] == 'tool-result',
        );
        expect(result['error'], 'oops');
        expect(
          round['parts'].any((part) => part['type'] == 'ui-resource'),
          isTrue,
        );
      });
    });

    group('Round-trip symmetry: Model -> UI -> Model', () {
      test('should round-trip simple text messages', () {
        final original = <dynamic>[
          {'role': 'user', 'content': 'Hello'},
          {'role': 'assistant', 'content': 'Hi'},
        ];
        final round = convertMessagesToModelMessages(
          modelMessagesToUIMessages(
            original
                .map((message) => (message as Map).cast<String, dynamic>())
                .toList(),
          ),
        );
        expect(round.map((message) => message['role']).toList(),
            ['user', 'assistant']);
      });

      test('should round-trip assistant with toolCalls + tool result', () {
        final original = <Map<String, dynamic>>[
          {
            'role': 'assistant',
            'content': 'Calling',
            'toolCalls': [
              {
                'id': 'tc-1',
                'type': 'function',
                'function': {'name': 'x', 'arguments': '{}'},
              },
            ],
          },
          {
            'role': 'tool',
            'toolCallId': 'tc-1',
            'content': 'ok',
          },
        ];
        final round = convertMessagesToModelMessages(
          modelMessagesToUIMessages(original),
        );
        expect(round.map((message) => message['role']).toList(),
            ['assistant', 'tool']);
      });

      test('should round-trip multimodal content array', () {
        final original = <Map<String, dynamic>>[
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'content': 'Look'},
              {
                'type': 'image',
                'source': {'type': 'url', 'value': 'https://example.com/a'},
              },
            ],
          },
        ];
        final round = convertMessagesToModelMessages(
          modelMessagesToUIMessages(original),
        );
        expect(round.single['content'], hasLength(2));
      });
    });

    group('structured-output round-trip', () {
      test(
          'emits a complete structured-output part as assistant text using raw',
          () {
        final result = uiMessageToModelMessages(ui(
          parts: [
            {
              'type': 'structured-output',
              'status': 'complete',
              'raw': '{"a":1}',
              'data': {'a': 1},
            },
          ],
        )).single;
        expect(result['content'], '{"a":1}');
        expect(result['structuredOutput'], {
          'type': 'structured-output',
          'status': 'complete',
          'raw': '{"a":1}',
          'data': {'a': 1},
        });
      });

      test('falls back to JSON.stringify(data) when raw is empty', () {
        final result = uiMessageToModelMessages(ui(
          parts: [
            {
              'type': 'structured-output',
              'status': 'complete',
              'raw': '',
              'data': {'a': 1},
            },
          ],
        )).single;
        expect(result['content'], '{"a":1}');
      });

      test('skips streaming structured-output parts', () {
        final result = uiMessageToModelMessages(ui(
          parts: [
            {
              'type': 'structured-output',
              'status': 'streaming',
              'raw': '{"a"',
              'partial': {'a': null},
            },
          ],
        )).single;
        expect(result['content'], isNull);
      });

      test('skips errored structured-output parts', () {
        final result = uiMessageToModelMessages(ui(
          parts: [
            {
              'type': 'structured-output',
              'status': 'error',
              'raw': '{"a"',
              'errorMessage': 'boom',
            },
          ],
        )).single;
        expect(result['content'], isNull);
      });
    });

    group('block order', () {
      test('writes blockOrder when parts leave the default order', () {
        final result = uiMessageToModelMessages(ui(
          parts: [
            {'type': 'text', 'content': 'before'},
            {
              'type': 'tool-call',
              'id': 'tc-1',
              'name': 'x',
              'arguments': '{}',
              'state': 'input-complete',
            },
            {'type': 'thinking', 'content': 'after'},
            {'type': 'text', 'content': 'last'},
          ],
        )).single;
        expect(result['blockOrder'], [
          {'type': 'text', 'length': 6},
          {'type': 'tool-call', 'id': 'tc-1'},
          {'type': 'thinking', 'index': 0},
          {'type': 'text', 'length': 4},
        ]);
      });

      test('writes no blockOrder for parts in the default order', () {
        final result = uiMessageToModelMessages(ui(
          parts: [
            {'type': 'thinking', 'content': 'first'},
            {'type': 'text', 'content': 'then'},
            {
              'type': 'tool-call',
              'id': 'tc-1',
              'name': 'x',
              'arguments': '{}',
              'state': 'input-complete',
            },
          ],
        )).single;
        expect(result.containsKey('blockOrder'), isFalse);
      });

      test('builds UIMessage parts in map order', () {
        final result = modelMessageToUIMessage({
          'role': 'assistant',
          'content': 'beforelast',
          'thinking': [
            {'content': 'after'},
          ],
          'toolCalls': [
            {
              'id': 'tc-1',
              'type': 'function',
              'function': {'name': 'x', 'arguments': '{}'},
            },
          ],
          'blockOrder': [
            {'type': 'text', 'length': 6},
            {'type': 'tool-call', 'id': 'tc-1'},
            {'type': 'thinking', 'index': 0},
            {'type': 'text', 'length': 4},
          ],
        });
        expect(result['parts'].map((part) => part['type']).toList(),
            ['text', 'tool-call', 'thinking', 'text']);
        expect(result['parts'][0]['content'], 'before');
        expect(result['parts'][3]['content'], 'last');
      });

      test('keeps the default order when the map does not match', () {
        final result = modelMessageToUIMessage({
          'role': 'assistant',
          'content': 'hello',
          'blockOrder': [
            {'type': 'text', 'length': 99},
          ],
        });
        expect(result['parts'], [
          {'type': 'text', 'content': 'hello'},
        ]);
      });

      test('keeps the order from UIMessage to ModelMessage and back', () {
        final original = ui(
          parts: [
            {'type': 'text', 'content': 'before'},
            {
              'type': 'tool-call',
              'id': 'tc-1',
              'name': 'x',
              'arguments': '{}',
              'state': 'input-complete',
            },
            {'type': 'thinking', 'content': 'after'},
            {'type': 'text', 'content': 'last'},
          ],
        );
        final model = uiMessageToModelMessages(original).single;
        final round = modelMessageToUIMessage(model);
        expect(round['parts'].map((part) => part['type']).toList(),
            ['text', 'tool-call', 'thinking', 'text']);
      });
    });
  });
}
