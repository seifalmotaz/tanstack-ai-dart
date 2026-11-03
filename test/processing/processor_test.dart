import 'dart:async';

import 'package:tanstack_ai_dart/src/processing/json_parser.dart';
import 'package:tanstack_ai_dart/src/processing/processor.dart';
import 'package:tanstack_ai_dart/src/processing/strategies.dart';
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

Stream<Map<String, dynamic>> streamOf(List<Map<String, dynamic>> chunks) =>
    Stream<Map<String, dynamic>>.fromIterable(chunks);

final ev = _Events();

class _Events {
  Map<String, dynamic> runStarted([String runId = 'run-1']) =>
      chunk('RUN_STARTED', {'runId': runId, 'threadId': 'thread-1'});
  Map<String, dynamic> textStart([String messageId = 'msg-1']) =>
      chunk('TEXT_MESSAGE_START', {
        'messageId': messageId,
        'role': 'assistant',
      });
  Map<String, dynamic> textContent(
    String delta, [
    String messageId = 'msg-1',
  ]) =>
      chunk('TEXT_MESSAGE_CONTENT', {'messageId': messageId, 'delta': delta});
  Map<String, dynamic> textEnd([String messageId = 'msg-1']) =>
      chunk('TEXT_MESSAGE_END', {'messageId': messageId});
  Map<String, dynamic> toolStart(String id, String name) => chunk(
        'TOOL_CALL_START',
        {'toolCallId': id, 'toolCallName': name},
      );
  Map<String, dynamic> toolArgs(String id, String delta) =>
      chunk('TOOL_CALL_ARGS', {'toolCallId': id, 'delta': delta});
  Map<String, dynamic> toolEnd(String id) =>
      chunk('TOOL_CALL_END', {'toolCallId': id});
  Map<String, dynamic> toolResult(
    String id,
    String content, [
    String? messageId,
  ]) =>
      chunk('TOOL_CALL_RESULT', {
        'toolCallId': id,
        'content': content,
        'messageId': messageId ?? 'result-$id',
      });
  Map<String, dynamic> runFinished([
    String finishReason = 'stop',
    String runId = 'run-1',
  ]) =>
      chunk('RUN_FINISHED', {
        'runId': runId,
        'threadId': 'thread-1',
        'metadata': {
          'tanstack': {'finishReason': finishReason},
        },
      });
  Map<String, dynamic> runError(String message, [String runId = 'run-1']) =>
      chunk('RUN_ERROR', {'message': message, 'runId': runId});
  Map<String, dynamic> stepStarted([String stepName = 'step-1']) =>
      chunk('STEP_STARTED', {'stepName': stepName});
  Map<String, dynamic> stepFinished([
    String stepName = 'step-1',
  ]) =>
      chunk('STEP_FINISHED', {'stepName': stepName});
  Map<String, dynamic> reasoningContent(
    String delta, [
    String messageId = 'r-1',
  ]) =>
      chunk('REASONING_MESSAGE_CONTENT', {
        'messageId': messageId,
        'delta': delta,
      });
  Map<String, dynamic> custom(String name, [dynamic value]) =>
      chunk('CUSTOM', {'name': name, 'value': value});
  Map<String, dynamic> activitySnapshot(
    String id,
    String type,
    Map<String, dynamic> content, [
    bool? replace,
  ]) =>
      chunk('ACTIVITY_SNAPSHOT', {
        'messageId': id,
        'activityType': type,
        'content': content,
        if (replace != null) 'replace': replace,
      });
  Map<String, dynamic> activityDelta(
    String id,
    String type,
    List<Map<String, dynamic>> patch,
  ) =>
      chunk('ACTIVITY_DELTA', {
        'messageId': id,
        'activityType': type,
        'patch': patch,
      });
}

class EventSpy {
  final List<List<Map<String, dynamic>>> messages = [];
  int streamStarts = 0;
  final List<Map<String, dynamic>> streamEnds = [];
  final List<Object> errors = [];
  final List<Map<String, dynamic>> toolCalls = [];
  final List<Map<String, dynamic>> approvals = [];
  final List<List<dynamic>> customEvents = [];
  final List<List<dynamic>> textUpdates = [];
  final List<List<dynamic>> toolStates = [];
  final List<List<dynamic>> thinkingUpdates = [];
  final List<Map<String, dynamic>> structuredOutputs = [];

  StreamProcessorEvents get events => StreamProcessorEvents(
        onMessagesChange: messages.add,
        onStreamStart: () => streamStarts++,
        onStreamEnd: streamEnds.add,
        onError: errors.add,
        onToolCall: toolCalls.add,
        onApprovalRequest: approvals.add,
        onCustomEvent: (name, data, context) =>
            customEvents.add(<dynamic>[name, data, context]),
        onTextUpdate: (messageId, content) =>
            textUpdates.add(<dynamic>[messageId, content]),
        onToolCallStateChange: (messageId, id, state, args) =>
            toolStates.add(<dynamic>[messageId, id, state, args]),
        onThinkingUpdate: (messageId, stepId, content) =>
            thinkingUpdates.add(<dynamic>[messageId, stepId, content]),
        onStructuredOutputChange: structuredOutputs.add,
      );
}

StreamProcessor processor([EventSpy? spy]) => StreamProcessor(
      StreamProcessorOptions(events: spy?.events),
    );

List<Map<String, dynamic>> partsOf(StreamProcessor p) => p
    .getMessages()
    .expand((message) => (message['parts'] as List))
    .whereType<Map>()
    .map((part) => part.cast<String, dynamic>())
    .toList();

void main() {
  group('StreamProcessor constructor and options', () {
    test('should initialize with default options', () {
      final p = processor();
      expect(p.getMessages(), isEmpty);
      expect(p.getCurrentAssistantMessageId(), isNull);
      expect(p.getState().done, isFalse);
    });

    test('should accept initialMessages', () {
      final p = StreamProcessor(StreamProcessorOptions(
        initialMessages: [
          {
            'id': 'u1',
            'role': 'user',
            'parts': [
              {'type': 'text', 'content': 'hi'},
            ],
          },
        ],
      ));
      expect(p.getMessages(), hasLength(1));
      expect(p.getMessages()[0]['id'], 'u1');
    });

    test('should not mutate the initialMessages array', () {
      final initial = <Map<String, dynamic>>[
        {
          'id': 'u1',
          'role': 'user',
          'parts': [
            {'type': 'text', 'content': 'hi'},
          ],
        },
      ];
      final p =
          StreamProcessor(StreamProcessorOptions(initialMessages: initial));
      p.addUserMessage('second');
      expect(initial, hasLength(1));
      expect(p.getMessages(), hasLength(2));
    });

    test('should use custom chunkStrategy', () {
      final calls = <List<String>>[];
      final p = StreamProcessor(StreamProcessorOptions(
        chunkStrategy: _Strategy((delta, accumulated) {
          calls.add([delta, accumulated]);
          return false;
        }),
      ));
      p.prepareAssistantMessage();
      p.processChunk(ev.textContent('Hello'));
      expect(calls, [
        ['Hello', 'Hello'],
      ]);
      expect((p.getMessages()[0]['parts'] as List), isEmpty);
    });

    test('should use custom jsonParser', () {
      final calls = <String>[];
      final p = StreamProcessor(StreamProcessorOptions(
        jsonParser: _Parser((value) {
          calls.add(value);
          return {'custom': true};
        }),
      ));
      p.prepareAssistantMessage();
      p.processChunk(ev.toolStart('tc-1', 'myTool'));
      p.processChunk(ev.toolArgs('tc-1', '{"key":"val"}'));
      expect(calls, ['{"key":"val"}']);
      expect(
        p.getState().toolCalls['tc-1']!.parsedArguments,
        {'custom': true},
      );
    });
  });

  group('message management', () {
    test('setMessages should replace messages and emit change', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.setMessages([
        {
          'id': 'a1',
          'role': 'assistant',
          'parts': [
            {'type': 'text', 'content': 'hello'},
          ],
        },
      ]);
      expect(p.getMessages(), hasLength(1));
      expect(p.getMessages()[0]['id'], 'a1');
      expect(spy.messages, hasLength(1));
    });

    test('setMessages should shallow-copy the input array', () {
      final p = processor();
      final msgs = <Map<String, dynamic>>[
        {'id': 'a1', 'role': 'assistant', 'parts': <dynamic>[]},
      ];
      p.setMessages(msgs);
      msgs.add({'id': 'a2', 'role': 'user', 'parts': <dynamic>[]});
      expect(p.getMessages(), hasLength(1));
    });

    test('prependMessages inserts older messages in front', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.setMessages([
        {
          'id': 'm2',
          'role': 'user',
          'parts': [
            {'type': 'text', 'content': 'two'},
          ],
        },
      ]);
      p.prependMessages([
        {
          'id': 'm1',
          'role': 'user',
          'parts': [
            {'type': 'text', 'content': 'one'},
          ],
        },
        {
          'id': 'm2',
          'role': 'user',
          'parts': [
            {'type': 'text', 'content': 'dup'},
          ],
        },
      ]);
      expect(
        p.getMessages().map((message) => message['id']).toList(),
        ['m1', 'm2'],
      );
      expect(p.getMessages()[1]['parts'][0], {
        'type': 'text',
        'content': 'two',
      });
    });

    test('skips duplicate ids in the prepend list and keeps existing messages',
        () {
      final p = processor();
      p.setMessages([
        {
          'id': 'm1',
          'role': 'user',
          'parts': [
            {'type': 'text', 'content': 'kept'},
          ],
        },
      ]);
      p.prependMessages([
        {
          'id': 'm1',
          'role': 'user',
          'parts': [
            {'type': 'text', 'content': 'first-dup'},
          ],
        },
        {
          'id': 'm1',
          'role': 'user',
          'parts': [
            {'type': 'text', 'content': 'second-dup'},
          ],
        },
      ]);
      expect(p.getMessages(), hasLength(1));
      expect(p.getMessages()[0]['parts'][0]['content'], 'kept');
    });

    test('addUserMessage with string content', () {
      final spy = EventSpy();
      final p = processor(spy);
      final message = p.addUserMessage('Hello!');
      expect(message['role'], 'user');
      expect(message['parts'], [
        {'type': 'text', 'content': 'Hello!'},
      ]);
      expect(message['id'], isNotEmpty);
      expect(message['createdAt'], isA<DateTime>());
      expect(p.getMessages(), hasLength(1));
      expect(spy.messages, hasLength(1));
    });

    test('addUserMessage with multimodal content array', () {
      final p = processor();
      final message = p.addUserMessage([
        {'type': 'text', 'content': 'What is this?'},
        {
          'type': 'image',
          'source': {'type': 'url', 'value': 'https://example.com/img.png'},
        },
      ]);
      expect((message['parts'] as List), hasLength(2));
      expect(message['parts'][1]['type'], 'image');
    });

    test('addUserMessage with custom id', () {
      expect(processor().addUserMessage('Hello', id: 'custom-id-42')['id'],
          'custom-id-42');
    });

    test('addUserMessage stores metadata on the user UIMessage', () {
      final p = processor();
      final metadata = {
        'author': {'id': 'user-42', 'name': 'Dana'},
      };
      final message = p.addUserMessage('Hello', id: 'u1', metadata: metadata);
      expect(message['metadata'], metadata);
      expect(p.getMessages()[0]['metadata'], metadata);
    });

    test(
        'clearMessages should remove all messages and reset assistantMessageId',
        () {
      final spy = EventSpy();
      final p = processor(spy);
      p.addUserMessage('one');
      p.addUserMessage('two');
      p.clearMessages();
      expect(p.getMessages(), isEmpty);
      expect(p.getCurrentAssistantMessageId(), isNull);
    });

    test('removeMessagesAfter should truncate after the given index', () {
      final p = processor();
      p.addUserMessage('zero');
      p.addUserMessage('one');
      p.addUserMessage('two');
      p.removeMessagesAfter(0);
      expect(p.getMessages(), hasLength(1));
      expect(p.getMessages()[0]['parts'][0]['content'], 'zero');
    });

    test('toModelMessages should convert all messages', () {
      final p = processor();
      p.addUserMessage('Hello');
      p.prepareAssistantMessage();
      p.processChunk(ev.textContent('Hi there'));
      p.processChunk(ev.runFinished());
      p.finalizeStream();
      final model = p.toModelMessages();
      expect(model.length, greaterThanOrEqualTo(2));
      expect(model[0]['role'], 'user');
      expect(model[1]['role'], 'assistant');
    });
  });

  group('message metadata', () {
    test(
        'TEXT_MESSAGE_START/CONTENT/END deep-merge tanstack and keep sibling keys',
        () {
      final p = processor();
      p.processChunk({
        ...ev.textStart(),
        'metadata': {
          'tanstack': {'model': 'gpt-5.5'},
        },
      });
      p.processChunk({
        ...ev.textContent('Hello'),
        'metadata': {
          'author': {'id': 'user-42', 'name': 'Dana'},
        },
      });
      p.processChunk({
        ...ev.textEnd(),
        'metadata': {
          'tanstack': {'createdAt': '2026-08-20T00:00:00.000Z'},
        },
      });
      final message = p.getMessages()[0];
      expect(message['metadata'], {
        'author': {'id': 'user-42', 'name': 'Dana'},
        'tanstack': {
          'model': 'gpt-5.5',
          'createdAt': '2026-08-20T00:00:00.000Z',
        },
      });
      expect(
        (message['createdAt'] as DateTime).toUtc().toIso8601String(),
        '2026-08-20T00:00:00.000Z',
      );
    });

    test('ignores invalid tanstack.createdAt timestamps', () {
      final p = processor();
      p.processChunk({
        ...ev.textStart(),
        'metadata': {
          'tanstack': {'createdAt': 'not-a-date'},
        },
      });
      p.processChunk(ev.textContent('Hello'));
      p.processChunk(ev.textEnd());
      expect(p.getMessages()[0]['createdAt'], isA<DateTime>());
    });

    test('merges terminal metadata onto the current assistant message', () {
      final p = processor();
      p.processChunk({
        ...ev.textStart(),
        'metadata': {
          'tanstack': {'model': 'gpt-5.5'},
        },
      });
      p.processChunk(ev.textContent('Hello'));
      p.processChunk(chunk('RUN_FINISHED', {
        'threadId': 'thread-1',
        'runId': 'run-1',
        'metadata': {
          'author': {'id': 'run'},
          'tanstack': {'finishReason': 'stop'},
        },
      }));
      expect(p.getMessages()[0]['metadata'], {
        'author': {'id': 'run'},
        'tanstack': {'model': 'gpt-5.5', 'finishReason': 'stop'},
      });
    });

    test(
        'MESSAGES_SNAPSHOT keeps per-message metadata and ignores event-level metadata',
        () {
      final p = processor();
      p.processChunk(chunk('MESSAGES_SNAPSHOT', {
        'metadata': {'source': 'event'},
        'messages': [
          {
            'id': 'u1',
            'role': 'user',
            'content': 'Hello',
            'metadata': {
              'author': {'id': 'user-42', 'name': 'Dana'},
            },
          },
          {
            'id': 'a1',
            'role': 'assistant',
            'content': 'Hi',
            'metadata': {
              'tanstack': {
                'model': 'gpt-5.5',
                'createdAt': '2026-08-20T00:00:00.000Z',
              },
            },
          },
        ],
      }));
      final messages = p.getMessages();
      expect(messages[0]['metadata'], {
        'author': {'id': 'user-42', 'name': 'Dana'},
      });
      expect(messages[1]['metadata'], {
        'tanstack': {
          'model': 'gpt-5.5',
          'createdAt': '2026-08-20T00:00:00.000Z',
        },
      });
      expect(messages[0]['metadata'].containsKey('source'), isFalse);
      expect(messages[1]['metadata'].containsKey('source'), isFalse);
    });

    test('MESSAGES_SNAPSHOT restores structured-output and ui-resource parts',
        () {
      final p = processor();
      final uiResource = {
        'type': 'ui-resource',
        'resource': {
          'uri': 'ui://widget/todos',
          'mimeType': 'text/html',
          'text': '<div>todos</div>',
        },
        'toolCallId': 'tc-1',
        'toolName': 'getTodos',
      };
      p.processChunk(chunk('MESSAGES_SNAPSHOT', {
        'messages': [
          {
            'id': 'a1',
            'role': 'assistant',
            'content': '{"ok":true}',
            'metadata': {
              'tanstack': {
                'structuredOutput': {
                  'status': 'complete',
                  'raw': '{"ok":true}',
                  'partial': {'ok': true},
                  'data': {'ok': true},
                },
                'uiResources': [uiResource],
              },
            },
          },
        ],
      }));
      expect(p.getMessages()[0]['parts'], [
        {
          'type': 'structured-output',
          'status': 'complete',
          'raw': '{"ok":true}',
          'partial': {'ok': true},
          'data': {'ok': true},
        },
        uiResource,
      ]);
    });

    test(
        'MESSAGES_SNAPSHOT drops a complete structured-output without data and keeps the text',
        () {
      final p = processor();
      p.processChunk(chunk('MESSAGES_SNAPSHOT', {
        'messages': [
          {
            'id': 'a1',
            'role': 'assistant',
            'content': '{"ok":true}',
            'metadata': {
              'tanstack': {
                'structuredOutput': {
                  'status': 'complete',
                  'raw': '{"ok":true}',
                },
              },
            },
          },
        ],
      }));
      expect(p.getMessages()[0]['parts'], [
        {'type': 'text', 'content': '{"ok":true}'},
      ]);
    });

    test('MESSAGES_SNAPSHOT ignores a malformed ui-resource without throwing',
        () {
      final p = processor();
      p.processChunk(chunk('MESSAGES_SNAPSHOT', {
        'messages': [
          {
            'id': 'a1',
            'role': 'assistant',
            'content': 'ok',
            'name': 'Ada',
            'metadata': {
              'tanstack': {
                'uiResources': [
                  {'type': 'ui-resource'},
                ],
              },
            },
          },
        ],
      }));
      final message = p.getMessages()[0];
      expect(message['name'], 'Ada');
      expect(message['parts'], [
        {'type': 'text', 'content': 'ok'},
      ]);
    });

    test('MESSAGES_SNAPSHOT does not duplicate restored ui-resource parts', () {
      final p = processor();
      final uiResource = {
        'type': 'ui-resource',
        'resource': {
          'uri': 'ui://widget/todos',
          'mimeType': 'text/html',
          'text': '<div>todos</div>',
        },
        'toolCallId': 'tc-1',
        'toolName': 'getTodos',
      };
      p.processChunk(chunk('MESSAGES_SNAPSHOT', {
        'messages': [
          {
            'id': 'a1',
            'role': 'assistant',
            'parts': [uiResource],
            'metadata': {
              'tanstack': {
                'uiResources': [uiResource],
              },
            },
          },
        ],
      }));
      expect(p.getMessages()[0]['parts'], [uiResource]);
    });

    test('snapshot that omits user metadata keeps in-memory user metadata', () {
      final p = processor();
      p.addUserMessage('Hello', id: 'u1', metadata: {
        'author': {'id': 'user-42', 'name': 'Dana'},
      });
      p.processChunk(chunk('MESSAGES_SNAPSHOT', {
        'messages': [
          {'id': 'u1', 'role': 'user', 'content': 'Hello'},
        ],
      }));
      expect(p.getMessages()[0]['metadata'], {
        'author': {'id': 'user-42', 'name': 'Dana'},
      });
    });

    test('restores per-tool fields from a messages snapshot', () {
      final p = processor();
      p.processChunk(chunk('MESSAGES_SNAPSHOT', {
        'messages': [
          {
            'id': 'r1',
            'role': 'tool',
            'toolCallId': 'c1',
            'content': '1',
            'name': 'one',
            'metadata': {'n': 1},
          },
          {
            'id': 'r2',
            'role': 'tool',
            'toolCallId': 'c2',
            'content': '2',
            'name': 'two',
            'metadata': {'n': 2},
          },
        ],
      }));
      final results =
          partsOf(p).where((part) => part['type'] == 'tool-result').toList();
      expect(results[0]['id'], 'r1');
      expect(results[0]['name'], 'one');
      expect(results[0]['metadata'], {'n': 1});
      expect(results[1]['id'], 'r2');
    });

    test(
        'TOOL_CALL_START spec metadata lands on ToolCallPart, not parent UIMessage',
        () {
      final p = processor();
      p.processChunk(chunk('TOOL_CALL_START', {
        'toolCallId': 'tc-1',
        'toolCallName': 'search',
        'metadata': {
          'thoughtSignature': 'sig-1',
          'providerExecuted': true,
        },
      }));
      final message = p.getMessages()[0];
      expect(message['metadata'], isNull);
      expect(partsOf(p).first['metadata'], {
        'thoughtSignature': 'sig-1',
        'providerExecuted': true,
      });
    });

    test(
        'REASONING_ENCRYPTED_VALUE tool-call signature lands on process() toolCalls',
        () {
      final p = processor();
      p.processChunk(chunk('TOOL_CALL_START', {
        'toolCallId': 'tc-1',
        'toolCallName': 'search',
      }));
      p.processChunk(ev.toolArgs('tc-1', '{"q":"hi"}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(chunk('REASONING_ENCRYPTED_VALUE', {
        'subtype': 'tool-call',
        'entityId': 'tc-1',
        'encryptedValue': 'sig-2',
      }));
      p.processChunk(ev.runFinished());
      expect(p.getState().toolCalls['tc-1']!.metadata, {
        'thoughtSignature': 'sig-2',
      });
    });
  });

  group('RESULT-only tools and REASONING-only thinking', () {
    test(
        'ARGS + spec END (no result) + TOOL_CALL_RESULT builds input from ARGS and output from RESULT',
        () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'getWeather'));
      p.processChunk(ev.toolArgs('tc-1', '{"city":"NYC"}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(ev.toolResult('tc-1', '{"temp":72}'));
      final call = partsOf(p).firstWhere(
        (part) => part['type'] == 'tool-call',
      );
      expect(call['input'], {'city': 'NYC'});
      expect(call['output'], {'temp': 72});
      expect(call['state'], 'complete');
    });

    test(
        'STEP_FINISHED thinking is ignored when REASONING_MESSAGE_CONTENT already applied',
        () {
      final p = processor();
      p.processChunk(ev.reasoningContent('think-a'));
      p.processChunk(ev.stepFinished());
      final thinking = partsOf(p).firstWhere(
        (part) => part['type'] == 'thinking',
      );
      expect(thinking['content'], 'think-a');
    });

    test('STEP_FINISHED alone does not create a thinking part', () {
      final p = processor();
      p.prepareAssistantMessage();
      p.processChunk(ev.stepFinished());
      expect(
        partsOf(p).where((part) => part['type'] == 'thinking'),
        isEmpty,
      );
    });

    test('RUN_FINISHED finishReason comes from metadata.tanstack.finishReason',
        () {
      final p = processor();
      p.processChunk(chunk('RUN_FINISHED', {
        'threadId': 'thread-1',
        'runId': 'run-1',
        'metadata': {
          'tanstack': {'finishReason': 'stop'},
        },
      }));
      expect(p.getState().finishReason, 'stop');
    });

    test(
        'TOOL_CALL_RESULT with metadata.tanstack.state output-error marks tool-call state error',
        () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'getWeather'));
      p.processChunk(ev.toolArgs('tc-1', '{}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk({
        ...ev.toolResult('tc-1', '{"error":"boom"}'),
        'metadata': {
          'tanstack': {'state': 'output-error'},
        },
      });
      expect(
        partsOf(p).firstWhere((part) => part['type'] == 'tool-call')['state'],
        'error',
      );
    });

    test(
        'TEXT_MESSAGE_START metadata.tanstack.model survives a content delta leftover',
        () {
      final p = processor();
      p.processChunk({
        ...ev.textStart(),
        'metadata': {
          'tanstack': {'model': 'gpt-5.5'},
        },
      });
      p.processChunk({
        ...ev.textContent('Hi'),
        'metadata': {
          'tanstack': {'content': 'Hello Hi'},
        },
      });
      expect(p.getMessages()[0]['metadata'], {
        'tanstack': {'model': 'gpt-5.5'},
      });
    });
  });

  group('process() full stream', () {
    test('should consume async iterable and return ProcessorResult', () async {
      final p = processor();
      final result = await p.process(streamOf([
        ev.runStarted(),
        ev.textStart(),
        ev.textContent('Hello '),
        ev.textContent('world'),
        ev.textEnd(),
        ev.runFinished(),
      ]));
      expect(result.content, 'Hello world');
      expect(result.finishReason, 'stop');
      expect(p.getMessages().single['parts'], [
        {'type': 'text', 'content': 'Hello world'},
      ]);
    });

    test('should return toolCalls in ProcessorResult when tool calls present',
        () async {
      final p = processor();
      final result = await p.process(streamOf([
        ev.runStarted(),
        ev.toolStart('tc-1', 'get_weather'),
        ev.toolArgs('tc-1', '{"city":"NYC"}'),
        ev.toolEnd('tc-1'),
        ev.runFinished('tool_calls'),
      ]));
      expect(result.toolCalls, hasLength(1));
      expect(result.toolCalls![0]['function']['name'], 'get_weather');
      expect(result.toolCalls![0]['function']['arguments'], '{"city":"NYC"}');
    });

    test('should return thinking in ProcessorResult when thinking present',
        () async {
      final p = processor();
      final result = await p.process(streamOf([
        ev.runStarted(),
        ev.stepStarted(),
        ev.reasoningContent('Let me '),
        ev.reasoningContent('think'),
        ev.runFinished(),
      ]));
      expect(result.thinking, 'Let me think');
    });

    test('should call finalizeStream after consuming the stream', () async {
      final spy = EventSpy();
      final p = processor(spy);
      await p.process(streamOf([
        ev.textStart(),
        ev.textContent('done'),
        ev.textEnd(),
      ]));
      expect(spy.streamEnds, hasLength(1));
      expect(spy.streamEnds.first['parts'][0]['content'], 'done');
    });
  });

  group('single-shot text', () {
    test(
        'should handle full text-only flow: RUN_STARTED -> TEXT_MESSAGE_START -> TEXT_MESSAGE_CONTENT* -> TEXT_MESSAGE_END -> RUN_FINISHED(stop)',
        () {
      final p = processor();
      p.processChunk(ev.runStarted());
      p.processChunk(ev.textStart());
      p.processChunk(ev.textContent('Hello'));
      p.processChunk(ev.textContent(' world'));
      p.processChunk(ev.textEnd());
      p.processChunk(ev.runFinished());
      expect(p.getMessages().single['parts'], [
        {'type': 'text', 'content': 'Hello world'},
      ]);
      expect(p.getState().content, 'Hello world');
    });

    test('should create assistant lazily on TEXT_MESSAGE_CONTENT', () {
      final p = processor();
      p.processChunk(ev.textContent('Hello'));
      expect(p.getMessages(), hasLength(1));
      expect(p.getMessages()[0]['id'], 'msg-1');
      expect(p.getMessages()[0]['parts'][0]['content'], 'Hello');
    });
  });

  group('single-shot tool call', () {
    test('should handle tool call only (no text)', () {
      final p = processor();
      p.processChunk(ev.runStarted());
      p.processChunk(ev.toolStart('tc-1', 'getWeather'));
      p.processChunk(ev.toolArgs('tc-1', '{"city":"NYC"}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(ev.runFinished());
      final message = p.getMessages().single;
      expect(message['parts'], [
        {
          'type': 'tool-call',
          'id': 'tc-1',
          'name': 'getWeather',
          'arguments': '{"city":"NYC"}',
          'state': 'input-complete',
          'input': {'city': 'NYC'},
        },
      ]);
    });

    test('should handle text then tool call', () {
      final p = processor();
      p.processChunk(ev.runStarted());
      p.processChunk(ev.textStart());
      p.processChunk(ev.textContent('Checking...'));
      p.processChunk(ev.toolStart('tc-1', 'getWeather'));
      p.processChunk(ev.toolArgs('tc-1', '{"city":"NYC"}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(ev.runFinished());
      expect(
        p.getMessages().single['parts'].map((part) => part['type']).toList(),
        ['text', 'tool-call'],
      );
    });

    test(
        'should track state transitions: awaiting-input -> input-streaming -> input-complete',
        () {
      final states = <String>[];
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.toolStart('tc-1', 'getWeather'));
      p.processChunk(ev.toolArgs('tc-1', '{"city":'));
      p.processChunk(ev.toolArgs('tc-1', '"NYC"}'));
      p.processChunk(ev.toolEnd('tc-1'));
      states.addAll(
        spy.toolStates.map((entry) => entry[2] as String),
      );
      expect(states, [
        'awaiting-input',
        'input-streaming',
        'input-streaming',
        'input-complete',
      ]);
    });

    test('parses part.input from TOOL_CALL_ARGS', () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'getWeather'));
      p.processChunk(ev.toolArgs('tc-1', '{"city":"NYC"}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.finalizeStream();
      expect(partsOf(p).first['input'], {'city': 'NYC'});
    });

    test(
        'should default tool call index to toolCalls.size when index is not provided',
        () {
      final p = processor();
      p.processChunk(ev.toolStart('a', 'one'));
      p.processChunk(ev.toolStart('b', 'two'));
      expect(p.getState().toolCalls['a']!.index, 0);
      expect(p.getState().toolCalls['b']!.index, 1);
    });
  });

  group('parallel tool calls', () {
    test('should handle interleaved parallel tool calls', () {
      final p = processor();
      p.processChunk(ev.toolStart('a', 'one'));
      p.processChunk(ev.toolStart('b', 'two'));
      p.processChunk(ev.toolArgs('a', '{"x":'));
      p.processChunk(ev.toolArgs('b', '{"y":'));
      p.processChunk(ev.toolArgs('a', '1}'));
      p.processChunk(ev.toolArgs('b', '2}'));
      p.processChunk(ev.toolEnd('a'));
      p.processChunk(ev.toolEnd('b'));
      final calls = partsOf(p);
      expect(calls[0]['arguments'], '{"x":1}');
      expect(calls[1]['arguments'], '{"y":2}');
      expect(calls.every((call) => call['state'] == 'input-complete'), isTrue);
    });

    test('should handle sequential parallel tool calls', () {
      final p = processor();
      p.processChunk(ev.toolStart('a', 'one'));
      p.processChunk(ev.toolArgs('a', '{}'));
      p.processChunk(ev.toolEnd('a'));
      p.processChunk(ev.toolStart('b', 'two'));
      p.processChunk(ev.toolArgs('b', '{}'));
      p.processChunk(ev.toolEnd('b'));
      expect(
        p.getState().toolCallOrder,
        ['a', 'b'],
      );
      expect(partsOf(p).map((part) => part['id']).toList(), ['a', 'b']);
    });
  });

  group('TOOL_CALL_END input after streamed arguments', () {
    test(
        'writes TOOL_CALL_END.input into arguments even when deltas were streamed',
        () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'getWeather'));
      p.processChunk(ev.toolArgs('tc-1', '{"city":"NYC"}'));
      p.processChunk(chunk('TOOL_CALL_END', {
        'toolCallId': 'tc-1',
        'input': {'city': 'NYC', 'unit': 'metric'},
      }));
      final call = partsOf(p).first;
      expect(call['arguments'], '{"city":"NYC","unit":"metric"}');
      expect(call['input'], {'city': 'NYC', 'unit': 'metric'});
    });

    test('keeps the streamed arguments when TOOL_CALL_END carries no input',
        () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'getWeather'));
      p.processChunk(ev.toolArgs('tc-1', '{"city":"NYC"}'));
      p.processChunk(ev.toolEnd('tc-1'));
      expect(partsOf(p).first['arguments'], '{"city":"NYC"}');
    });
  });

  group('text-tool interleaving', () {
    test(
        'should reset segment text accumulation on TEXT_MESSAGE_START (existing test preserved)',
        () {
      final p = processor();
      p.processChunk(ev.textStart());
      p.processChunk(ev.textContent('before'));
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolArgs('tc-1', '{}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(ev.textStart());
      p.processChunk(ev.textContent('after'));
      final texts = partsOf(p)
          .where((part) => part['type'] == 'text')
          .map((part) => part['content'])
          .toList();
      expect(texts, ['before', 'after']);
    });

    test(
        'should produce text -> tool-call -> tool-result -> text (4-part ordering)',
        () {
      final p = processor();
      p.processChunk(ev.textStart());
      p.processChunk(ev.textContent('Checking'));
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolArgs('tc-1', '{}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(ev.toolResult('tc-1', '{"ok":true}'));
      p.processChunk(ev.textStart());
      p.processChunk(ev.textContent('Done'));
      expect(
        p.getMessages().single['parts'].map((part) => part['type']).toList(),
        ['text', 'tool-call', 'tool-result', 'text'],
      );
    });

    test('never surfaces a lenient parse of truncated args as input', () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolArgs('tc-1', '{"a":"cut'));
      expect(partsOf(p).first['input'], isNull);
    });
  });

  group('thinking/reasoning', () {
    test(
        'should accumulate REASONING_MESSAGE_CONTENT deltas into thinking content',
        () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.runStarted());
      p.processChunk(ev.textStart());
      p.processChunk(chunk('REASONING_START', {'messageId': 'r-1'}));
      p.processChunk(chunk('REASONING_MESSAGE_START', {
        'messageId': 'r-1',
        'role': 'reasoning',
      }));
      p.processChunk(ev.reasoningContent('Let me think'));
      p.processChunk(ev.reasoningContent(' about this...'));
      p.processChunk(chunk('REASONING_MESSAGE_END', {'messageId': 'r-1'}));
      p.processChunk(chunk('REASONING_END', {'messageId': 'r-1'}));
      expect(spy.thinkingUpdates, hasLength(2));
      expect(spy.thinkingUpdates[0][2], 'Let me think');
      expect(spy.thinkingUpdates[1][2], 'Let me think about this...');
    });

    test('should create a thinking part in the UIMessage', () {
      final p = processor();
      p.processChunk(ev.runStarted());
      p.processChunk(ev.textStart());
      p.processChunk(ev.reasoningContent('Thinking...'));
      p.processChunk(ev.textContent('Answer'));
      p.processChunk(ev.runFinished());
      final parts = sectionsOf(p);
      expect(parts['thinking']!.first['content'], 'Thinking...');
      expect(parts['text']!.first['content'], 'Answer');
    });

    test('should update a single ThinkingPart in-place for same stepId', () {
      final p = processor();
      p.processChunk(ev.stepStarted());
      p.processChunk(ev.reasoningContent('one'));
      p.processChunk(ev.reasoningContent(' two'));
      final thinking =
          partsOf(p).where((part) => part['type'] == 'thinking').toList();
      expect(thinking, hasLength(1));
      expect(thinking.first['content'], 'one two');
    });

    test('should create separate ThinkingParts for different stepIds', () {
      final p = processor();
      p.processChunk(ev.stepStarted('step-a'));
      p.processChunk(ev.reasoningContent('A', 'r-a'));
      p.processChunk(ev.stepStarted('step-b'));
      p.processChunk(ev.reasoningContent('B', 'r-b'));
      final thinking =
          partsOf(p).where((part) => part['type'] == 'thinking').toList();
      expect(thinking.map((part) => part['content']).toList(), ['A', 'B']);
    });

    test('should attribute reasoning content to pending STEP_STARTED stepId',
        () {
      final p = processor();
      p.processChunk(ev.runStarted());
      p.processChunk(chunk('REASONING_START', {'messageId': 'r-1'}));
      p.processChunk(chunk('REASONING_MESSAGE_START', {
        'messageId': 'r-1',
        'role': 'reasoning',
      }));
      p.processChunk(ev.stepStarted('step-1'));
      p.processChunk(ev.reasoningContent('Thinking...'));
      final thinking =
          partsOf(p).where((part) => part['type'] == 'thinking').single;
      expect(thinking['stepId'], 'step-1');
      expect(thinking['content'], 'Thinking...');
    });

    test('getResult().thinking should concatenate all steps in order',
        () async {
      final p = processor();
      final result = await p.process(streamOf([
        ev.stepStarted('step-a'),
        ev.reasoningContent('A', 'r-a'),
        ev.stepStarted('step-b'),
        ev.reasoningContent('B', 'r-b'),
        ev.runFinished(),
      ]));
      expect(result.thinking, 'AB');
    });
  });

  group('tool results', () {
    test(
        'should update tool-call part output field when TOOL_CALL_RESULT arrives',
        () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(ev.toolResult('tc-1', '{"temp":72}'));
      final call = partsOf(p).firstWhere((part) => part['type'] == 'tool-call');
      expect(call['output'], {'temp': 72});
      expect(call['state'], 'complete');
    });

    test('should handle non-JSON result string gracefully (existing test)', () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(ev.toolResult('tc-1', 'plain text'));
      final call = partsOf(p).firstWhere((part) => part['type'] == 'tool-call');
      expect(call['output'], 'plain text');
    });

    test(
        'addToolResult should create tool-result part and set output on tool-call part',
        () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.addToolResult('tc-1', {'result': 42});
      final parts = partsOf(p);
      expect(parts[0]['output'], {'result': 42});
      expect(parts[1]['type'], 'tool-result');
      expect(parts[1]['content'], '{"result":42}');
      expect(parts[1]['state'], 'complete');
    });

    test('addToolResult with string output should store as-is', () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.addToolResult('tc-1', 'ok');
      final result =
          partsOf(p).firstWhere((part) => part['type'] == 'tool-result');
      expect(result['content'], 'ok');
    });

    test('addToolResult with error should set error state', () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.addToolResult('tc-1', {'message': 'boom'}, error: 'boom');
      final parts = partsOf(p);
      expect(parts[0]['state'], 'error');
      expect(parts[0]['output'], {'error': 'boom'});
      expect(parts[1]['state'], 'error');
      expect(parts[1]['error'], 'boom');
    });

    test('addToolResult with missing toolCallId should warn and no-op', () {
      final p = processor();
      p.addToolResult('missing', 'x');
      expect(p.getMessages(), isEmpty);
    });
  });

  group('client tools (CUSTOM events)', () {
    test(
        'should fire onToolCall when tool-input-available CUSTOM event arrives',
        () {
      final spy = EventSpy();
      final p = processor(spy);
      final input = {'city': 'NYC'};
      p.processChunk(ev.custom('tool-input-available', {
        'toolCallId': 'tc-1',
        'toolName': 'getWeather',
        'input': input,
      }));
      expect(spy.toolCalls, [
        {'toolCallId': 'tc-1', 'toolName': 'getWeather', 'input': input},
      ]);
    });

    test('should not fire onToolCall for CUSTOM events with no data', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.custom('tool-input-available'));
      expect(spy.toolCalls, isEmpty);
    });

    test('should not fire onToolCall for unrelated CUSTOM events', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.custom('other', {'x': 1}));
      expect(spy.toolCalls, isEmpty);
    });
  });

  group('frontend tools on a success RUN_FINISHED', () {
    test('fires an unanswered call', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.runStarted());
      p.processChunk(ev.toolStart('tc-1', 'show'));
      p.processChunk(ev.toolArgs('tc-1', '{"message":42}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(ev.runFinished());
      expect(spy.toolCalls, hasLength(1));
      expect(spy.toolCalls.first['input'], {'message': 42});
    });

    test('fires only the calls named in pendingToolCallIds', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.runStarted());
      p.processChunk(ev.toolStart('a', 'one'));
      p.processChunk(ev.toolArgs('a', '{}'));
      p.processChunk(ev.toolEnd('a'));
      p.processChunk(ev.toolStart('b', 'two'));
      p.processChunk(ev.toolArgs('b', '{}'));
      p.processChunk(ev.toolEnd('b'));
      p.processChunk(chunk('RUN_FINISHED', {
        'runId': 'run-1',
        'outcome': {
          'type': 'success',
          'pendingToolCallIds': ['b'],
        },
        'metadata': {
          'tanstack': {'finishReason': 'stop'},
        },
      }));
      expect(spy.toolCalls.map((call) => call['toolCallId']).toList(), ['b']);
    });

    test('skips calls the run answered with TOOL_CALL_RESULT', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.runStarted());
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolArgs('tc-1', '{}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(ev.toolResult('tc-1', '{}'));
      p.processChunk(ev.runFinished());
      expect(spy.toolCalls, isEmpty);
    });

    test('skips a call that waits for approval', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.runStarted());
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolArgs('tc-1', '{}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(chunk('RUN_FINISHED', {
        'runId': 'run-1',
        'outcome': {
          'type': 'interrupt',
          'interrupts': [
            {
              'id': 'ap-1',
              'toolCallId': 'tc-1',
              'reason': 'approval_required',
              'metadata': {'kind': 'approval', 'toolName': 'x'},
            },
          ],
        },
      }));
      expect(spy.toolCalls, isEmpty);
      expect(spy.approvals, hasLength(1));
    });

    test('does not fire a call that tool-input-available already sent', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.runStarted());
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolArgs('tc-1', '{}'));
      p.processChunk(ev.custom('tool-input-available', {
        'toolCallId': 'tc-1',
        'toolName': 'x',
        'input': {},
      }));
      p.processChunk(ev.runFinished());
      expect(spy.toolCalls, hasLength(1));
    });

    test('does not fire on a cancelled run', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.runStarted());
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolArgs('tc-1', '{}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(chunk('RUN_FINISHED', {
        'runId': 'run-1',
        'metadata': {
          'tanstack': {'finishReason': 'stop', 'stopReason': 'aborted'},
        },
      }));
      expect(spy.toolCalls, hasLength(1));
    });

    test('skips a call of an answer cut at the output limit, and logs nothing',
        () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.runStarted());
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolArgs('tc-1', '{}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(ev.runFinished('length'));
      expect(spy.toolCalls, isEmpty);
    });
  });

  group('approval flow', () {
    test('should handle approval-requested CUSTOM event', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.toolStart('tc-1', 'delete'));
      p.processChunk(ev.toolArgs('tc-1', '{}'));
      p.processChunk(ev.toolEnd('tc-1'));
      final input = {'id': 1};
      p.processChunk(ev.custom('approval-requested', {
        'toolCallId': 'tc-1',
        'toolName': 'delete',
        'input': input,
        'approval': {'id': 'ap-1', 'needsApproval': true},
      }));
      final call = partsOf(p).firstWhere((part) => part['type'] == 'tool-call');
      expect(call['state'], 'approval-requested');
      expect(call['approval'], {'id': 'ap-1', 'needsApproval': true});
      expect(spy.approvals.single['approvalId'], 'ap-1');
    });

    test('should handle approval interrupts on RUN_FINISHED', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.runStarted());
      p.processChunk(ev.toolStart('tc-1', 'delete'));
      p.processChunk(ev.toolArgs('tc-1', '{}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(chunk('RUN_FINISHED', {
        'runId': 'run-1',
        'outcome': {
          'type': 'interrupt',
          'interrupts': [
            {
              'id': 'ap-1',
              'toolCallId': 'tc-1',
              'reason': 'approval_required',
              'metadata': {'kind': 'approval', 'toolName': 'delete'},
            },
          ],
        },
      }));
      final call = partsOf(p).firstWhere((part) => part['type'] == 'tool-call');
      expect(call['state'], 'approval-requested');
      expect(spy.approvals.single, {
        'toolCallId': 'tc-1',
        'toolName': 'delete',
        'input': {},
        'approvalId': 'ap-1',
      });
    });

    test('should handle client tool interrupts on RUN_FINISHED', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.runStarted());
      p.processChunk(ev.toolStart('tc-1', 'lookup'));
      p.processChunk(ev.toolArgs('tc-1', '{"q":"x"}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(chunk('RUN_FINISHED', {
        'runId': 'run-1',
        'outcome': {
          'type': 'interrupt',
          'interrupts': [
            {
              'id': 'i-1',
              'toolCallId': 'tc-1',
              'reason': 'tanstack:client_tool_execution',
              'metadata': {
                'kind': 'client_tool',
                'toolName': 'lookup',
                'input': {'q': 'x'},
              },
            },
          ],
        },
      }));
      expect(spy.toolCalls.single['toolCallId'], 'tc-1');
      expect(spy.toolCalls.single['input'], {'q': 'x'});
    });

    test(
        'does not auto-run client tools when a generic interrupt shares the batch',
        () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.runStarted());
      p.processChunk(ev.toolStart('tc-1', 'lookup'));
      p.processChunk(ev.toolArgs('tc-1', '{}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(chunk('RUN_FINISHED', {
        'runId': 'run-1',
        'outcome': {
          'type': 'interrupt',
          'interrupts': [
            {
              'id': 'i-1',
              'toolCallId': 'tc-1',
              'reason': 'client_tool_input',
              'metadata': {'kind': 'client_tool'},
            },
            {
              'id': 'i-2',
              'metadata': {
                interruptBindingMetadataKey: {'kind': 'generic'},
              },
            },
          ],
        },
      }));
      expect(spy.toolCalls, isEmpty);
    });

    test('addToolApprovalResponse should approve a tool call', () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolArgs('tc-1', '{}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(ev.custom('approval-requested', {
        'toolCallId': 'tc-1',
        'toolName': 'x',
        'input': {},
        'approval': {'id': 'ap-1', 'needsApproval': true},
      }));
      p.addToolApprovalResponse('ap-1', true);
      final call = partsOf(p).firstWhere((part) => part['type'] == 'tool-call');
      expect(call['approval']['approved'], isTrue);
      expect(call['state'], 'approval-responded');
    });

    test('addToolApprovalResponse should deny a tool call', () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolArgs('tc-1', '{}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(ev.custom('approval-requested', {
        'toolCallId': 'tc-1',
        'toolName': 'x',
        'input': {},
        'approval': {'id': 'ap-1', 'needsApproval': true},
      }));
      p.addToolApprovalResponse('ap-1', false);
      final call = partsOf(p).firstWhere((part) => part['type'] == 'tool-call');
      expect(call['approval']['approved'], isFalse);
      expect(call['state'], 'approval-responded');
    });
  });

  group('custom event dispatch', () {
    test('should forward arbitrary custom events to onCustomEvent callback',
        () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.custom('progress', {'percent': 50}));
      expect(spy.customEvents.single[0], 'progress');
      expect(spy.customEvents.single[1], {'percent': 50});
    });

    test(
        'should extract toolCallId from custom event data and include in context',
        () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.custom('progress', {
        'toolCallId': 'tc-1',
        'percent': 50,
      }));
      expect(spy.customEvents.single[2], {'toolCallId': 'tc-1'});
    });

    test(
        'should NOT forward system custom events (tool-input-available) to onCustomEvent',
        () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.custom('tool-input-available', {
        'toolCallId': 'tc-1',
        'toolName': 'x',
        'input': {},
      }));
      expect(spy.customEvents, isEmpty);
    });

    test(
        'should NOT forward system custom events (approval-requested) to onCustomEvent',
        () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.custom('approval-requested', {
        'toolCallId': 'tc-1',
        'toolName': 'x',
        'input': {},
        'approval': {'id': 'a', 'needsApproval': true},
      }));
      expect(spy.customEvents, isEmpty);
    });

    test('should work when onCustomEvent handler is not provided', () {
      final p = processor();
      p.processChunk(ev.custom('progress', {'percent': 50}));
      expect(p.getMessages(), isEmpty);
    });
  });

  group('areAllToolsComplete', () {
    test('should return true when there is no assistant message', () {
      expect(processor().areAllToolsComplete(), isTrue);
    });

    test('should return true when there are no tool calls', () {
      final p = processor();
      p.processChunk(ev.textStart());
      p.processChunk(ev.textContent('hi'));
      expect(p.areAllToolsComplete(), isTrue);
    });

    test(
        'should return false when tool calls are pending (no result, no output)',
        () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolArgs('tc-1', '{}'));
      p.processChunk(ev.toolEnd('tc-1'));
      expect(p.areAllToolsComplete(), isFalse);
    });

    test(
        'should return true when tool call has corresponding tool-result part (server tool)',
        () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(ev.toolResult('tc-1', '{}'));
      expect(p.areAllToolsComplete(), isTrue);
    });

    test('should return true when client tool has output (via addToolResult)',
        () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.addToolResult('tc-1', 'ok');
      expect(p.areAllToolsComplete(), isTrue);
    });

    test('should return true when tool call is in approval-responded state',
        () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(ev.custom('approval-requested', {
        'toolCallId': 'tc-1',
        'toolName': 'x',
        'input': {},
        'approval': {'id': 'a', 'needsApproval': true},
      }));
      p.addToolApprovalResponse('a', true);
      expect(p.areAllToolsComplete(), isTrue);
    });
  });

  group('lazy assistant message creation', () {
    test('should not create assistant message when no content arrives', () {
      final p = processor();
      p.prepareAssistantMessage();
      p.processChunk(ev.runFinished());
      p.finalizeStream();
      expect(p.getMessages(), isEmpty);
    });

    test('should create assistant message lazily on first text content', () {
      final p = processor();
      p.prepareAssistantMessage();
      expect(p.getMessages(), isEmpty);
      p.processChunk(ev.textContent('Hello'));
      expect(p.getMessages(), hasLength(1));
    });

    test('should create assistant message lazily on first tool call', () {
      final p = processor();
      p.prepareAssistantMessage();
      p.processChunk(ev.toolStart('tc-1', 'x'));
      expect(p.getMessages(), hasLength(1));
    });

    test('should create assistant message lazily on error', () {
      final p = processor();
      p.prepareAssistantMessage();
      p.processChunk(ev.runError('boom'));
      expect(p.getMessages(), hasLength(1));
    });

    test(
        'should support deprecated startAssistantMessage for backwards compatibility',
        () {
      final p = processor();
      final id = p.startAssistantMessage();
      p.processChunk(ev.textContent('Hello', id));
      expect(p.getMessages().single['id'], id);
    });
  });

  group('edge cases', () {
    test('duplicate TOOL_CALL_START with same toolCallId should be a no-op',
        () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolStart('tc-1', 'x'));
      expect(
        partsOf(p).where((part) => part['type'] == 'tool-call'),
        hasLength(1),
      );
    });

    test('TOOL_CALL_ARGS for unknown toolCallId should be silently dropped',
        () {
      final p = processor();
      p.processChunk(ev.toolArgs('missing', '{}'));
      expect(p.getMessages(), isEmpty);
    });

    test(
        'empty delta in TOOL_CALL_ARGS should not transition from awaiting-input',
        () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolArgs('tc-1', ''));
      expect(p.getState().toolCalls['tc-1']!.state, 'awaiting-input');
    });

    test('missing TOOL_CALL_END should be caught by RUN_FINISHED safety net',
        () {
      final p = processor();
      p.processChunk(ev.runStarted());
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolArgs('tc-1', '{"a":1}'));
      p.processChunk(ev.runFinished('tool_calls'));
      expect(
        partsOf(p).firstWhere((part) => part['type'] == 'tool-call')['state'],
        'input-complete',
      );
    });

    test(
        'non-content event types (RUN_STARTED, TEXT_MESSAGE_END, STEP_STARTED, STATE_SNAPSHOT, STATE_DELTA) should not create messages',
        () {
      final p = processor();
      for (final event in [
        ev.runStarted(),
        ev.textEnd(),
        ev.stepStarted(),
        chunk('STATE_SNAPSHOT', {'snapshot': {}}),
        chunk('STATE_DELTA', {'delta': []}),
      ]) {
        p.processChunk(event);
      }
      expect(p.getMessages(), isEmpty);
    });

    test('RUN_ERROR with empty message should use fallback', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(chunk('RUN_ERROR', {'runId': 'run-1'}));
      expect((spy.errors.single as Map)['message'], 'An error occurred');
    });

    test(
        'attaches code and rawEvent from RUN_ERROR chunk to the Error passed to onError',
        () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(chunk('RUN_ERROR', {
        'runId': 'run-1',
        'message': 'boom',
        'code': 'E_BOOM',
        'rawEvent': {'detail': 'x'},
      }));
      final error = spy.errors.single as Map;
      expect(error['message'], 'boom');
      expect(error['code'], 'E_BOOM');
      expect(error['rawEvent'], {'detail': 'x'});
    });
  });

  group('event callbacks', () {
    test('onStreamStart should fire on first content-bearing chunk', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.runStarted());
      expect(spy.streamStarts, 0);
      p.processChunk(ev.textContent('Hello'));
      expect(spy.streamStarts, 1);
      p.processChunk(ev.textContent(' there'));
      expect(spy.streamStarts, 1);
    });

    test(
        'onStreamEnd should fire during finalizeStream with the assistant message',
        () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.textStart());
      p.processChunk(ev.textContent('done'));
      p.processChunk(ev.textEnd());
      p.finalizeStream();
      expect(spy.streamEnds, hasLength(1));
      expect(spy.streamEnds.first['parts'][0]['content'], 'done');
    });

    test('onStreamEnd should NOT fire if no assistant message was created', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.prepareAssistantMessage();
      p.finalizeStream();
      expect(spy.streamEnds, isEmpty);
    });

    test('onError should fire on RUN_ERROR', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.runError('boom'));
      expect(spy.errors, hasLength(1));
    });

    test('onTextUpdate should fire for each text emission', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.textContent('a'));
      p.processChunk(ev.textContent('b'));
      expect(spy.textUpdates, hasLength(2));
      expect(spy.textUpdates[0][1], 'a');
      expect(spy.textUpdates[1][1], 'ab');
    });

    test('onToolCallStateChange should fire on state transitions', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolArgs('tc-1', '{}'));
      p.processChunk(ev.toolEnd('tc-1'));
      expect(
        spy.toolStates.map((entry) => entry[2]).toList(),
        ['awaiting-input', 'input-streaming', 'input-complete'],
      );
    });
  });

  group('recording and replay', () {
    test('should record chunks when recording option is enabled via process()',
        () async {
      final p = StreamProcessor(const StreamProcessorOptions(recording: true));
      await p.process(streamOf([ev.runStarted(), ev.runFinished()]));
      expect(p.getRecording(), isNotNull);
      expect(p.getRecording()!.chunks, hasLength(2));
    });

    test('should record chunks when startRecording is called manually', () {
      final p = processor();
      expect(p.getRecording(), isNull);
      p._startRecordingForTest();
      p.processChunk(ev.runStarted());
      expect(p.getRecording()!.chunks, hasLength(1));
    });

    test('StreamProcessor.replay should process a recording', () async {
      final p = StreamProcessor(const StreamProcessorOptions(recording: true));
      await p.process(streamOf([
        ev.textStart(),
        ev.textContent('Hello'),
        ev.textEnd(),
      ]));
      final replayed = await StreamProcessor.replay(p.getRecording()!);
      expect(replayed.content, 'Hello');
    });

    test('createReplayStream should yield all chunks from a recording',
        () async {
      final recording = ChunkRecording(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        chunks: [
          RecordedChunk(
            chunk: ev.runStarted(),
            timestamp: 1,
            index: 0,
          ),
          RecordedChunk(
            chunk: ev.runFinished(),
            timestamp: 2,
            index: 1,
          ),
        ],
      );
      final chunks = await createReplayStream(recording).toList();
      expect(chunks, hasLength(2));
      expect(chunks[0]['type'], 'RUN_STARTED');
      expect(chunks[1]['type'], 'RUN_FINISHED');
    });
  });

  group('finalizeStream and reset', () {
    test('finalizeStream should flush pending text not yet emitted', () {
      final p = StreamProcessor(StreamProcessorOptions(
        chunkStrategy: _Strategy((_, __) => false),
      ));
      p.prepareAssistantMessage();
      p.processChunk(ev.textContent('Buffered'));
      expect((p.getMessages()[0]['parts'] as List), isEmpty);
      p.finalizeStream();
      expect(p.getMessages()[0]['parts'][0]['content'], 'Buffered');
    });

    test('finalizeStream should force-complete tool calls as safety net', () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolArgs('tc-1', '{}'));
      p.finalizeStream();
      expect(
        partsOf(p).firstWhere((part) => part['type'] == 'tool-call')['state'],
        'input-complete',
      );
    });

    test('reset should clear all messages and stream state', () {
      final p = processor();
      p.processChunk(ev.textContent('hi'));
      p.reset();
      expect(p.getMessages(), isEmpty);
      expect(p.getState().done, isFalse);
      expect(p.getState().content, '');
    });

    test('chunkStrategy.reset should be called on prepareAssistantMessage', () {
      var resets = 0;
      final p = StreamProcessor(StreamProcessorOptions(
        chunkStrategy: _Strategy((_, __) => true, onReset: () => resets++),
      ));
      p.prepareAssistantMessage();
      expect(resets, 1);
    });
  });

  group('getState', () {
    test('should return a complete state snapshot', () {
      final p = processor();
      p.processChunk(ev.textContent('Hello'));
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolArgs('tc-1', '{"a":1}'));
      p.processChunk(ev.toolEnd('tc-1'));
      final state = p.getState();
      expect(state.content, 'Hello');
      expect(state.toolCalls.containsKey('tc-1'), isTrue);
      expect(state.toolCallOrder, ['tc-1']);
      expect(state.done, isFalse);
    });

    test(
        'should return independent copies (mutations do not affect internal state)',
        () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'x'));
      final state = p.getState();
      state.toolCalls.remove('tc-1');
      expect(p.getState().toolCalls.containsKey('tc-1'), isTrue);
    });
  });

  group('TEXT_MESSAGE_START', () {
    test('should create a message with correct role and messageId', () {
      final p = processor();
      p.processChunk(ev.textStart('msg-42'));
      expect(p.getMessages().single['id'], 'msg-42');
      expect(p.getMessages().single['role'], 'assistant');
    });

    test('should create a user message via TEXT_MESSAGE_START', () {
      final p = processor();
      p.processChunk(chunk('TEXT_MESSAGE_START', {
        'messageId': 'u1',
        'role': 'user',
      }));
      p.processChunk(ev.textContent('hi', 'u1'));
      expect(p.getMessages().single['role'], 'user');
    });

    test('should emit onStreamStart when a new message arrives', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.textStart());
      expect(spy.streamStarts, 1);
    });
  });

  group('TEXT_MESSAGE_END', () {
    test('should not emit onStreamEnd (that happens in finalizeStream)', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.textContent('hi'));
      p.processChunk(ev.textEnd());
      expect(spy.streamEnds, isEmpty);
    });

    test('should emit pending text on TEXT_MESSAGE_END', () {
      final p = processor();
      p.processChunk(ev.textStart());
      p.processChunk(ev.textContent('pending'));
      p.processChunk(ev.textEnd());
      expect(p.getMessages().single['parts'][0]['content'], 'pending');
    });
  });

  group('interleaved messages', () {
    test('should handle two interleaved assistant messages', () {
      final p = processor();
      p.processChunk(ev.textStart('a'));
      p.processChunk(ev.textContent('A', 'a'));
      p.processChunk(ev.textStart('b'));
      p.processChunk(ev.textContent('B', 'b'));
      expect(p.getMessages(), hasLength(2));
      expect(p.getMessages()[0]['parts'][0]['content'], 'A');
      expect(p.getMessages()[1]['parts'][0]['content'], 'B');
    });

    test('should emit onStreamEnd on finalizeStream (not on TEXT_MESSAGE_END)',
        () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.textContent('hi'));
      p.processChunk(ev.textEnd());
      expect(spy.streamEnds, isEmpty);
      p.finalizeStream();
      expect(spy.streamEnds, hasLength(1));
    });
  });

  group('startAssistantMessage + TEXT_MESSAGE_START dedup', () {
    test(
        'should associate TEXT_MESSAGE_START with pending manual message (different ID)',
        () {
      final p = processor();
      final id = p.startAssistantMessage();
      p.processChunk(ev.textStart('server-id'));
      p.processChunk(ev.textContent('hi', 'server-id'));
      expect(p.getMessages(), hasLength(1));
      expect(p.getMessages().single['id'], 'server-id');
      expect(p.getMessages().single['parts'][0]['content'], 'hi');
      expect(id, isNot('server-id'));
    });

    test(
        'should associate TEXT_MESSAGE_START with pending manual message (same ID)',
        () {
      final p = processor();
      p.startAssistantMessage('same');
      p.processChunk(ev.textStart('same'));
      p.processChunk(ev.textContent('hi', 'same'));
      expect(p.getMessages(), hasLength(1));
    });

    test(
        'should work when TEXT_MESSAGE_START arrives without startAssistantMessage',
        () {
      final p = processor();
      p.processChunk(ev.textStart());
      expect(p.getMessages(), hasLength(1));
    });
  });

  group('MESSAGES_SNAPSHOT', () {
    test('should hydrate messages and emit onMessagesChange', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(chunk('MESSAGES_SNAPSHOT', {
        'messages': [
          {'id': 'u1', 'role': 'user', 'content': 'hello'},
          {'id': 'a1', 'role': 'assistant', 'content': 'hi'},
        ],
      }));
      expect(p.getMessages().map((message) => message['role']).toList(),
          ['user', 'assistant']);
      expect(spy.messages, isNotEmpty);
    });

    test('should replace existing messages (not append)', () {
      final p = processor();
      p.addUserMessage('old');
      p.processChunk(chunk('MESSAGES_SNAPSHOT', {
        'messages': [
          {'id': 'u1', 'role': 'user', 'content': 'new'},
        ],
      }));
      expect(p.getMessages(), hasLength(1));
      expect(p.getMessages()[0]['parts'][0]['content'], 'new');
    });

    test(
        'should anchor a snapshot tool message into the preceding assistant message',
        () {
      final p = processor();
      p.processChunk(chunk('MESSAGES_SNAPSHOT', {
        'messages': [
          {
            'id': 'a1',
            'role': 'assistant',
            'content': 'calling',
            'toolCalls': [
              {
                'id': 'c1',
                'type': 'function',
                'function': {'name': 'x', 'arguments': '{}'},
              },
            ],
          },
          {
            'id': 'r1',
            'role': 'tool',
            'toolCallId': 'c1',
            'content': '{"ok":true}',
          },
        ],
      }));
      expect(p.getMessages(), hasLength(1));
      final parts = p.getMessages().single['parts'] as List;
      expect(parts.map((part) => part['type']).toList(),
          ['text', 'tool-call', 'tool-result']);
    });

    test(
        'should preserve an in-flight tool-call part the snapshot omits so addToolResult still works (#859)',
        () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolArgs('tc-1', '{}'));
      p.processChunk(chunk('MESSAGES_SNAPSHOT', {
        'messages': [
          {
            'id': 'a1',
            'role': 'assistant',
            'content': 'calling',
            'toolCalls': [
              {
                'id': 'other',
                'type': 'function',
                'function': {'name': 'y', 'arguments': '{}'},
              },
            ],
          },
          {
            'id': 'r1',
            'role': 'tool',
            'toolCallId': 'tc-1',
            'content': '{"ok":true}',
          },
        ],
      }));
      final call = partsOf(p).firstWhere(
        (part) => part['type'] == 'tool-call' && part['id'] == 'tc-1',
      );
      expect(call['state'], 'complete');
      expect(call['output'], {'ok': true});
    });

    test('should not duplicate a tool-call part the snapshot already supplies',
        () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'x'));
      p.processChunk(ev.toolArgs('tc-1', '{}'));
      p.processChunk(chunk('MESSAGES_SNAPSHOT', {
        'messages': [
          {
            'id': 'a1',
            'role': 'assistant',
            'content': 'calling',
            'toolCalls': [
              {
                'id': 'tc-1',
                'type': 'function',
                'function': {'name': 'x', 'arguments': '{}'},
              },
            ],
          },
          {
            'id': 'r1',
            'role': 'tool',
            'toolCallId': 'tc-1',
            'content': '{}',
          },
        ],
      }));
      expect(
        partsOf(p).where(
          (part) => part['type'] == 'tool-call' && part['id'] == 'tc-1',
        ),
        hasLength(1),
      );
    });

    test(
        'should fold tool-result content into tool-call output on MESSAGES_SNAPSHOT (server tools)',
        () {
      final p = processor();
      p.processChunk(chunk('MESSAGES_SNAPSHOT', {
        'messages': [
          {
            'id': 'a1',
            'role': 'assistant',
            'content': '',
            'toolCalls': [
              {
                'id': 'tc-1',
                'type': 'function',
                'function': {'name': 'x', 'arguments': '{}'},
              },
            ],
          },
          {
            'id': 'r1',
            'role': 'tool',
            'toolCallId': 'tc-1',
            'content': '{"value":3}',
          },
        ],
      }));
      final call = partsOf(p).firstWhere((part) => part['type'] == 'tool-call');
      expect(call['output'], {'value': 3});
      expect(call['state'], 'complete');
    });

    test(
        'should reset stale state and process subsequent stream events correctly',
        () {
      final p = processor();
      p.processChunk(ev.textStart('old'));
      p.processChunk(ev.textContent('old', 'old'));
      p.processChunk(chunk('MESSAGES_SNAPSHOT', {
        'messages': [
          {'id': 'u1', 'role': 'user', 'content': 'hello'},
        ],
      }));
      p.processChunk(ev.textStart('new'));
      p.processChunk(ev.textContent('new text', 'new'));
      expect(
        p.getMessages().map((message) => message['id']).toList(),
        ['u1', 'new'],
      );
      expect(p.getMessages()[1]['parts'][0]['content'], 'new text');
    });
  });

  group('concurrent runs', () {
    test('RUN_FINISHED for one run should not finalize a still-active run', () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.runStarted('run-a'));
      p.processChunk(ev.runStarted('run-b'));
      p.processChunk(ev.textStart('a'));
      p.processChunk(ev.textContent('A', 'a'));
      p.processChunk(ev.runFinished('stop', 'run-a'));
      expect(spy.streamEnds, isEmpty);
      expect(p.getState().done, isFalse);
      p.processChunk(ev.textStart('b'));
      p.processChunk(ev.textContent('B', 'b'));
      p.processChunk(ev.runFinished('stop', 'run-b'));
      expect(p.getState().done, isTrue);
    });

    test('should not set isDone until all concurrent runs finish', () {
      final p = processor();
      p.processChunk(ev.runStarted('run-a'));
      p.processChunk(ev.runStarted('run-b'));
      p.processChunk(ev.runFinished('stop', 'run-a'));
      expect(p.getState().done, isFalse);
      p.processChunk(ev.runFinished('stop', 'run-b'));
      expect(p.getState().done, isTrue);
    });

    test(
        'RUN_FINISHED without prior RUN_STARTED should finalize normally (backward compat)',
        () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.textContent('hi'));
      p.processChunk(ev.runFinished());
      expect(p.getState().done, isTrue);
      expect(spy.streamEnds, hasLength(1));
    });

    test('RUN_ERROR for one run should not affect other active runs', () {
      final p = processor();
      p.processChunk(ev.runStarted('run-a'));
      p.processChunk(ev.runStarted('run-b'));
      p.processChunk(ev.runError('boom', 'run-a'));
      expect(p.getState().done, isFalse);
    });
  });

  group('reconnect dedupe', () {
    test(
        'TEXT_MESSAGE_CONTENT for existing message should not create a duplicate',
        () {
      final p = processor();
      p.processChunk(ev.textStart());
      p.processChunk(ev.textContent('first'));
      p.processChunk(ev.textContent(' second'));
      expect(p.getMessages(), hasLength(1));
      expect(p.getMessages()[0]['parts'][0]['content'], 'first second');
    });

    test('should correctly append delta to existing text on reconnect', () {
      final p = StreamProcessor(StreamProcessorOptions(
        initialMessages: [
          {
            'id': 'msg-1',
            'role': 'assistant',
            'parts': [
              {'type': 'text', 'content': 'Hello '},
            ],
          },
        ],
      ));
      p.processChunk(ev.textContent('world'));
      expect(p.getMessages()[0]['parts'][0]['content'], 'Hello world');
    });

    test('should handle reconnect when existing message has no text parts', () {
      final p = StreamProcessor(StreamProcessorOptions(
        initialMessages: [
          {'id': 'msg-1', 'role': 'assistant', 'parts': <dynamic>[]},
        ],
      ));
      p.processChunk(ev.textContent('Hello'));
      expect(p.getMessages()[0]['parts'][0]['content'], 'Hello');
    });

    test('should not fire onStreamStart when hydrating existing message', () {
      final spy = EventSpy();
      final p = StreamProcessor(StreamProcessorOptions(
        events: spy.events,
        initialMessages: [
          {'id': 'msg-1', 'role': 'assistant', 'parts': <dynamic>[]},
        ],
      ));
      p.processChunk(ev.textContent('Hello'));
      expect(spy.streamStarts, 0);
    });
  });

  group('*_CHUNK shorthand events', () {
    test('builds the same message as START / CONTENT / END (#1531 repro)', () {
      final expanded = processor();
      expanded.processChunk(ev.runStarted());
      expanded.processChunk(ev.textStart('msg-1'));
      expanded.processChunk(ev.textContent('Hello, '));
      expanded.processChunk(ev.textContent('world'));
      expanded.processChunk(ev.textEnd());
      expanded.processChunk(ev.runFinished());

      final chunked = processor();
      chunked.processChunk(ev.runStarted());
      chunked.processChunk(chunk('TEXT_MESSAGE_CHUNK', {
        'messageId': 'msg-1',
        'delta': 'Hello, ',
      }));
      chunked.processChunk(chunk('TEXT_MESSAGE_CHUNK', {'delta': 'world'}));
      chunked.processChunk(ev.runFinished());

      expect(
        chunked.getMessages().map((message) => message['parts']).toList(),
        expanded.getMessages().map((message) => message['parts']).toList(),
      );
    });

    test(
        'continues a stream on a chunk with no id, and closes it on the next event',
        () {
      final p = processor();
      p.processChunk(ev.runStarted());
      p.processChunk(chunk('TEXT_MESSAGE_CHUNK', {
        'messageId': 'msg-1',
        'delta': 'Hello, ',
      }));
      p.processChunk(chunk('TEXT_MESSAGE_CHUNK', {'delta': 'world'}));
      p.processChunk(ev.runFinished());
      expect(p.getMessages()[0]['parts'][0]['content'], 'Hello, world');
    });

    test('keeps the parent message and the metadata of a tool call chunk', () {
      final p = processor();
      p.processChunk(ev.textStart('msg-1'));
      p.processChunk(chunk('TOOL_CALL_CHUNK', {
        'toolCallId': 'tc-1',
        'toolCallName': 'lookup',
        'parentMessageId': 'msg-1',
        'delta': '{"q":',
        'metadata': {'thoughtSignature': 'sig'},
      }));
      p.processChunk(chunk('TOOL_CALL_CHUNK', {'delta': '1}'}));
      p.processChunk(ev.textEnd('msg-1'));
      expect(p.getMessages().single['id'], 'msg-1');
      final call = partsOf(p).firstWhere((part) => part['type'] == 'tool-call');
      expect(call['arguments'], '{"q":1}');
      expect(call['metadata'], {'thoughtSignature': 'sig'});
    });

    test('closes the open tool call when a new one has no toolCallName', () {
      final p = processor();
      p.processChunk(ev.runStarted());
      p.processChunk(chunk('TOOL_CALL_CHUNK', {
        'toolCallId': 'tc-1',
        'toolCallName': 'lookup',
        'delta': '{"a":1}',
      }));
      p.processChunk(chunk('TOOL_CALL_CHUNK', {
        'toolCallId': 'tc-2',
        'delta': '{"b":',
      }));
      p.processChunk(chunk('TOOL_CALL_CHUNK', {'delta': '2}'}));
      p.processChunk(ev.runFinished());
      final call = partsOf(p).firstWhere((part) => part['type'] == 'tool-call');
      expect(call['id'], 'tc-1');
      expect(call['arguments'], '{"a":1}');
    });

    test(
        'drops, with a warning, an id-less chunk with nothing open and a tool call chunk with no name',
        () {
      final p = processor();
      p.processChunk(ev.runStarted());
      p.processChunk(chunk('TEXT_MESSAGE_CHUNK', {'delta': 'orphan'}));
      p.processChunk(chunk('TOOL_CALL_CHUNK', {
        'toolCallId': 'tc-1',
        'delta': '{}',
      }));
      p.processChunk(ev.runFinished());
      expect(p.getMessages(), isEmpty);
    });

    test('does not continue a stream after clearMessages', () {
      final p = processor();
      p.processChunk(ev.textContent('old', 'msg-1'));
      p.clearMessages();
      p.processChunk(chunk('TEXT_MESSAGE_CHUNK', {'delta': 'new'}));
      expect(p.getMessages(), isEmpty);
    });
  });

  group('REASONING events', () {
    test(
        'should handle REASONING events without errors when no matching message',
        () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.runStarted());
      p.processChunk(chunk('REASONING_START', {'messageId': 'r-1'}));
      p.processChunk(chunk('REASONING_MESSAGE_START', {
        'messageId': 'r-1',
        'role': 'reasoning',
      }));
      p.processChunk(ev.reasoningContent('thinking'));
      p.processChunk(chunk('REASONING_MESSAGE_END', {'messageId': 'r-1'}));
      p.processChunk(chunk('REASONING_END', {'messageId': 'r-1'}));
      expect(spy.thinkingUpdates, isNotEmpty);
    });

    test('should not fail on no-op REASONING lifecycle events', () {
      final p = processor();
      p.processChunk(ev.runStarted());
      p.processChunk(ev.textStart());
      p.processChunk(chunk('REASONING_START', {'messageId': 'r-1'}));
      p.processChunk(chunk('REASONING_MESSAGE_START', {
        'messageId': 'r-1',
        'role': 'reasoning',
      }));
      p.processChunk(chunk('REASONING_MESSAGE_END', {'messageId': 'r-1'}));
      p.processChunk(chunk('REASONING_END', {'messageId': 'r-1'}));
      expect(p.getMessages(), isNotNull);
    });
  });

  group('ACTIVITY_SNAPSHOT and ACTIVITY_DELTA', () {
    test(
        'creates an activity UIMessage and does not turn it into assistant text',
        () {
      final p = processor();
      p.processChunk(ev.activitySnapshot('act-1', 'SEARCH', {
        'query': 'tanstack',
      }));
      final message = p.getMessages().single;
      expect(message['role'], 'activity');
      expect(message['id'], 'act-1');
      final part = (message['parts'] as List).single;
      expect(part['type'], 'activity');
      expect(part['activityType'], 'SEARCH');
      expect(part['content'], {'query': 'tanstack'});
      expect(p.getState().content, '');
    });

    test(
        'replace: true updates content; replace: false keeps the existing activity',
        () {
      final p = processor();
      p.processChunk(ev.activitySnapshot('act-1', 'SEARCH', {'query': 'one'}));
      p.processChunk(ev.activitySnapshot('act-1', 'SEARCH', {'query': 'two'}));
      expect(p.getMessages()[0]['parts'][0]['content'], {'query': 'two'});
      p.processChunk(ev.activitySnapshot(
        'act-1',
        'SEARCH',
        {'query': 'three'},
        false,
      ));
      expect(p.getMessages()[0]['parts'][0]['content'], {'query': 'two'});
    });

    test('applies an RFC 6902 patch to activity content', () {
      final p = processor();
      p.processChunk(ev.activitySnapshot('act-1', 'SEARCH', {
        'query': 'tanstack',
        'status': 'running',
      }));
      p.processChunk(ev.activityDelta('act-1', 'SEARCH', [
        {'op': 'replace', 'path': '/status', 'value': 'done'},
        {'op': 'add', 'path': '/hits', 'value': 3},
      ]));
      expect(p.getMessages()[0]['parts'][0]['content'], {
        'query': 'tanstack',
        'status': 'done',
        'hits': 3,
      });
    });

    test('delta on a missing id warns and no-ops', () {
      final p = processor();
      p.processChunk(ev.activityDelta('missing', 'SEARCH', [
        {'op': 'replace', 'path': '/status', 'value': 'done'},
      ]));
      expect(p.getMessages(), isEmpty);
    });

    test('keeps previous content when the patch fails', () {
      final p = processor();
      p.processChunk(ev.activitySnapshot('act-1', 'SEARCH', {
        'status': 'running',
      }));
      p.processChunk(ev.activityDelta('act-1', 'SEARCH', [
        {'op': 'test', 'path': '/status', 'value': 'done'},
      ]));
      expect(p.getMessages()[0]['parts'][0]['content'], {
        'status': 'running',
      });
    });

    test('rejects a delta whose activityType does not match', () {
      final p = processor();
      p.processChunk(ev.activitySnapshot('act-1', 'SEARCH', {
        'status': 'running',
      }));
      p.processChunk(ev.activityDelta('act-1', 'PLAN', [
        {'op': 'replace', 'path': '/status', 'value': 'done'},
      ]));
      expect(p.getMessages()[0]['parts'][0]['activityType'], 'SEARCH');
      expect(p.getMessages()[0]['parts'][0]['content'], {
        'status': 'running',
      });
    });

    test('keeps previous content when a root replace is not an object', () {
      final p = processor();
      p.processChunk(ev.activitySnapshot('act-1', 'SEARCH', {
        'status': 'running',
      }));
      p.processChunk(ev.activityDelta('act-1', 'SEARCH', [
        {'op': 'replace', 'path': '', 'value': <dynamic>[]},
      ]));
      expect(p.getMessages()[0]['parts'][0]['content'], {
        'status': 'running',
      });
    });

    test('copies snapshot metadata and merges delta metadata', () {
      final p = processor();
      p.processChunk({
        ...ev.activitySnapshot('act-1', 'SEARCH', {'status': 'running'}),
        'metadata': {
          'source': 'snap',
          'tanstack': {'model': 'test'},
        },
      });
      p.processChunk({
        ...ev.activityDelta('act-1', 'SEARCH', [
          {'op': 'replace', 'path': '/status', 'value': 'done'},
        ]),
        'metadata': {
          'extra': true,
          'tanstack': {'run': 'r1'},
        },
      });
      expect(p.getMessages()[0]['metadata'], {
        'source': 'snap',
        'extra': true,
        'tanstack': {'model': 'test', 'run': 'r1'},
      });
      expect(p.getMessages()[0]['parts'][0]['content'], {'status': 'done'});
    });

    test('omits activity messages from toModelMessages', () {
      final p = processor();
      p.processChunk(ev.textStart('user-1'));
      p.processChunk(ev.activitySnapshot('act-1', 'SEARCH', {'query': 'x'}));
      p.processChunk(ev.textStart('msg-1'));
      p.processChunk(ev.textContent('hello', 'msg-1'));
      final model = p.toModelMessages();
      expect(model.any((message) => message['role'] == 'activity'), isFalse);
    });

    test('does not replace a non-activity message that shares the id', () {
      final p = processor();
      p.processChunk(ev.textStart('shared'));
      p.processChunk(ev.textContent('hello', 'shared'));
      p.processChunk(ev.activitySnapshot('shared', 'SEARCH', {'query': 'x'}));
      expect(p.getMessages(), hasLength(1));
      expect(p.getMessages()[0]['role'], 'assistant');
      expect(
        (p.getMessages()[0]['parts'] as List)
            .any((part) => part['type'] == 'text'),
        isTrue,
      );
    });

    test('does not overwrite an activity message with TEXT_MESSAGE_START', () {
      final p = processor();
      p.processChunk(ev.activitySnapshot('act-1', 'SEARCH', {'query': 'x'}));
      p.processChunk(ev.textStart('act-1'));
      p.processChunk(ev.textContent('stolen', 'act-1'));
      expect(p.getMessages(), hasLength(1));
      expect(p.getMessages()[0]['role'], 'activity');
      expect(
        (p.getMessages()[0]['parts'] as List)
            .any((part) => part['type'] == 'text'),
        isFalse,
      );
    });

    test(
        'MESSAGES_SNAPSHOT with ActivityMessage restores activity id and content',
        () {
      final p = processor();
      p.processChunk(chunk('MESSAGES_SNAPSHOT', {
        'messages': [
          {'id': 'u1', 'role': 'user', 'content': 'hi'},
          {
            'id': 'act-1',
            'role': 'activity',
            'activityType': 'SEARCH',
            'content': {'query': 'tanstack'},
          },
          {'id': 'a1', 'role': 'assistant', 'content': 'done'},
        ],
      }));
      expect(
        p.getMessages().map((message) => message['role']).toList(),
        ['user', 'activity', 'assistant'],
      );
      expect(p.getMessages()[1]['id'], 'act-1');
      expect(p.getMessages()[1]['parts'][0]['content'], {
        'query': 'tanstack',
      });
      expect(
        p.toModelMessages().any((message) => message['role'] == 'activity'),
        isFalse,
      );
    });

    test('MESSAGES_SNAPSHOT without activity keeps the previous activity row',
        () {
      final p = processor();
      p.processChunk(
        ev.activitySnapshot('act-1', 'SEARCH', {'query': 'keep-me'}),
      );
      p.addUserMessage('hi');
      p.processChunk(chunk('MESSAGES_SNAPSHOT', {
        'messages': [
          {'id': 'u1', 'role': 'user', 'content': 'hi'},
          {'id': 'a1', 'role': 'assistant', 'content': 'done'},
        ],
      }));
      expect(
        p.getMessages().map((message) => message['role']).toList(),
        ['activity', 'user', 'assistant'],
      );
      expect(p.getMessages()[0]['id'], 'act-1');
    });
  });

  group('TOOL_CALL_RESULT event', () {
    test('should create tool-result part and update tool-call output', () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'get_weather'));
      p.processChunk(ev.toolArgs('tc-1', '{"city":"NYC"}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(ev.toolResult('tc-1', '{"temp": 72}'));
      final parts = partsOf(p);
      expect(parts[0]['output'], {'temp': 72});
      expect(parts[0]['state'], 'complete');
      expect(parts[1]['toolCallId'], 'tc-1');
      expect(parts[1]['content'], '{"temp": 72}');
      expect(parts[1]['state'], 'complete');
    });

    test('should mark output-error tool results as errored message parts', () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'get_weather'));
      p.processChunk(ev.toolArgs('tc-1', '{"city":"NYC"}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk({
        ...ev.toolResult('tc-1', '{"error":"boom"}'),
        'metadata': {
          'tanstack': {'state': 'output-error'},
        },
      });
      final parts = partsOf(p);
      expect(parts[0]['output'], {'error': 'boom'});
      expect(parts[0]['state'], 'error');
      expect(parts[1]['state'], 'error');
      expect(parts[1]['error'], 'boom');
    });

    test('should preserve a denied outcome on output-error tool results', () {
      final p = processor();
      p.processChunk(ev.toolStart('tc-1', 'get_weather'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk({
        ...ev.toolResult('tc-1', '{"error":"User declined tool execution"}'),
        'metadata': {
          'tanstack': {
            'state': 'output-error',
            'toolResultOutcome': 'denied',
          },
        },
      });
      final result =
          partsOf(p).firstWhere((part) => part['type'] == 'tool-result');
      expect(result['state'], 'error');
      expect(result['outcome'], 'denied');
    });

    test('should ignore invalid tool result outcomes', () {
      for (final invalid in <dynamic>[null, 'unknown', 42]) {
        final p = processor();
        p.processChunk(ev.toolStart('tc-1', 'get_weather'));
        p.processChunk(ev.toolEnd('tc-1'));
        p.processChunk({
          ...ev.toolResult('tc-1', '{"ok":true}'),
          'metadata': {
            'tanstack': {'toolResultOutcome': invalid},
          },
        });
        final result =
            partsOf(p).firstWhere((part) => part['type'] == 'tool-result');
        expect(result['state'], 'complete');
        expect(result.containsKey('outcome'), isFalse);
      }
    });

    test(
        'keeps the tool-call part terminal at "error" through RUN_FINISHED even when output-error arrives before TOOL_CALL_END',
        () {
      final p = processor();
      p.processChunk(ev.runStarted());
      p.processChunk(ev.textStart());
      p.processChunk(ev.toolStart('tc-1', 'get_weather'));
      p.processChunk({
        ...ev.toolResult('tc-1', '{"error":"boom"}'),
        'metadata': {
          'tanstack': {'state': 'output-error'},
        },
      });
      p.processChunk(ev.runFinished());
      final call = partsOf(p).firstWhere((part) => part['type'] == 'tool-call');
      expect(call['state'], 'error');
      expect(p.getState().toolCalls['tc-1']!.state, 'input-complete');
    });
  });

  group('Structured output parts', () {
    test(
        'routes deltas after structured-output.start into a structured-output part',
        () {
      final p = processor();
      p.processChunk(ev.runStarted());
      p.processChunk(ev.textStart('msg-1'));
      p.processChunk(ev.custom('structured-output.start', {
        'messageId': 'msg-1',
      }));
      p.processChunk(ev.textContent('{"name":', 'msg-1'));
      p.processChunk(ev.textContent('"Alice"}', 'msg-1'));
      p.processChunk(ev.custom('structured-output.complete', {
        'object': {'name': 'Alice'},
        'raw': '{"name":"Alice"}',
        'messageId': 'msg-1',
      }));
      p.processChunk(ev.runFinished('stop'));
      final assistant = p.getMessages().single;
      expect(
        (assistant['parts'] as List).any((part) => part['type'] == 'text'),
        isFalse,
      );
      final sop = (assistant['parts'] as List)
          .firstWhere((part) => part['type'] == 'structured-output');
      expect(sop['status'], 'complete');
      expect(sop['data'], {'name': 'Alice'});
      expect(sop['raw'], '{"name":"Alice"}');
    });

    test('progressively populates partial as JSON deltas arrive', () {
      final p = processor();
      p.processChunk(ev.textStart('msg-1'));
      p.processChunk(ev.custom('structured-output.start', {
        'messageId': 'msg-1',
      }));
      p.processChunk(ev.textContent('{"name":', 'msg-1'));
      var sop = partsOf(p).firstWhere(
        (part) => part['type'] == 'structured-output',
      );
      expect(sop['status'], 'streaming');
      p.processChunk(ev.textContent('"Alice"', 'msg-1'));
      sop = partsOf(p).firstWhere(
        (part) => part['type'] == 'structured-output',
      );
      expect(sop['partial'], {'name': 'Alice'});
      p.processChunk(ev.textContent('}', 'msg-1'));
      p.processChunk(ev.custom('structured-output.complete', {
        'object': {'name': 'Alice'},
        'raw': '{"name":"Alice"}',
        'messageId': 'msg-1',
      }));
      sop = partsOf(p).firstWhere(
        (part) => part['type'] == 'structured-output',
      );
      expect(sop['status'], 'complete');
      expect(sop['data'], {'name': 'Alice'});
    });

    test('marks a streaming structured-output part as errored on RUN_ERROR',
        () {
      final p = processor();
      p.processChunk(ev.textStart('msg-1'));
      p.processChunk(ev.custom('structured-output.start', {
        'messageId': 'msg-1',
      }));
      p.processChunk(ev.textContent('{"name":"Al', 'msg-1'));
      p.processChunk(ev.runError('Stream aborted'));
      final sop = partsOf(p).firstWhere(
        (part) => part['type'] == 'structured-output',
      );
      expect(sop['status'], 'error');
      expect(sop['errorMessage'], 'Stream aborted');
      expect(sop['raw'], '{"name":"Al');
    });

    test(
        'creates an error placeholder part when RUN_ERROR fires before any delta',
        () {
      final p = processor();
      p.processChunk(ev.textStart('msg-1'));
      p.processChunk(ev.custom('structured-output.start', {
        'messageId': 'msg-1',
      }));
      p.processChunk(ev.runError('Connection lost'));
      final sop = partsOf(p).firstWhere(
        (part) => part['type'] == 'structured-output',
      );
      expect(sop['status'], 'error');
      expect(sop['errorMessage'], 'Connection lost');
      expect(sop['raw'], '');
    });

    test(
        'keeps a complete structured-output part complete if a later RUN_ERROR fires on the same message',
        () {
      final p = processor();
      p.processChunk(ev.textStart('msg-1'));
      p.processChunk(ev.custom('structured-output.start', {
        'messageId': 'msg-1',
      }));
      p.processChunk(ev.textContent('{"name":"A"}', 'msg-1'));
      p.processChunk(ev.custom('structured-output.complete', {
        'object': {'name': 'A'},
        'raw': '{"name":"A"}',
        'messageId': 'msg-1',
      }));
      p.processChunk(ev.runError('downstream failed'));
      final sop = partsOf(p).firstWhere(
        (part) => part['type'] == 'structured-output',
      );
      expect(sop['status'], 'complete');
      expect(sop['data'], {'name': 'A'});
    });

    test(
        'handles tool-call interleaved between structured-output.start and the first delta',
        () {
      final p = processor();
      p.processChunk(ev.textStart('msg-1'));
      p.processChunk(ev.custom('structured-output.start', {
        'messageId': 'msg-1',
      }));
      p.processChunk(ev.toolStart('tc-1', 'lookup'));
      p.processChunk(ev.toolArgs('tc-1', '{"q":"x"}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(ev.textContent('{"name":"A"}', 'msg-1'));
      p.processChunk(ev.custom('structured-output.complete', {
        'object': {'name': 'A'},
        'raw': '{"name":"A"}',
        'messageId': 'msg-1',
      }));
      p.processChunk(ev.runFinished());
      final parts = p.getMessages().single['parts'] as List;
      final tool = parts.firstWhere((part) => part['type'] == 'tool-call');
      final sop =
          parts.firstWhere((part) => part['type'] == 'structured-output');
      expect(tool['id'], 'tc-1');
      expect(tool['state'], 'input-complete');
      expect(sop['status'], 'complete');
    });

    test(
        'snaps a streaming structured-output part to error if RUN_FINISHED fires without structured-output.complete',
        () {
      final p = processor();
      p.processChunk(ev.runStarted('run-a'));
      p.processChunk(ev.textStart('msg-1'));
      p.processChunk(ev.custom('structured-output.start', {
        'messageId': 'msg-1',
      }));
      p.processChunk(ev.textContent('{"name":"A', 'msg-1'));
      p.processChunk(ev.runFinished('stop', 'run-a'));
      final sop = partsOf(p).firstWhere(
        (part) => part['type'] == 'structured-output',
      );
      expect(sop['status'], 'error');
      p.processChunk(ev.runStarted('run-b'));
      p.processChunk(ev.textStart('msg-1'));
      p.processChunk(ev.textContent('plain', 'msg-1'));
      final text = partsOf(p).firstWhere((part) => part['type'] == 'text');
      expect(text['content'], 'plain');
    });

    test(
        'clears structuredMessageIds for messages dropped by removeMessagesAfter (reload)',
        () {
      final p = processor();
      final user = p.addUserMessage('extract person');
      p.processChunk(ev.runStarted('run-a'));
      p.processChunk(ev.textStart('msg-a'));
      p.processChunk(ev.custom('structured-output.start', {
        'messageId': 'msg-a',
      }));
      p.processChunk(ev.textContent('{"name":"A"', 'msg-a'));
      final userIndex =
          p.getMessages().indexWhere((message) => message['id'] == user['id']);
      p.removeMessagesAfter(userIndex);
      p.processChunk(ev.textStart('msg-a'));
      p.processChunk(ev.textContent('hello', 'msg-a'));
      final assistants = p
          .getMessages()
          .where((message) => message['role'] == 'assistant')
          .toList();
      expect(assistants, hasLength(1));
      expect(
        (assistants[0]['parts'] as List)
            .any((part) => part['type'] == 'structured-output'),
        isFalse,
      );
      expect(
        (assistants[0]['parts'] as List)
            .firstWhere((part) => part['type'] == 'text')['content'],
        'hello',
      );
    });

    test('clears messageStates for messages dropped by removeMessagesAfter',
        () {
      final p = processor();
      final user = p.addUserMessage('hi');
      p.processChunk(ev.runStarted('run-a'));
      p.processChunk(ev.textStart('msg-a'));
      p.processChunk(ev.textContent('first turn', 'msg-a'));
      final userIndex =
          p.getMessages().indexWhere((message) => message['id'] == user['id']);
      p.removeMessagesAfter(userIndex);
      p.processChunk(ev.textContent('resumed', 'msg-a'));
      final assistants = p
          .getMessages()
          .where((message) => message['role'] == 'assistant')
          .toList();
      expect(assistants, hasLength(1));
      expect(
        (assistants[0]['parts'] as List)
            .firstWhere((part) => part['type'] == 'text')['content'],
        'resumed',
      );
    });
  });

  group('per-message tool calls', () {
    test('should route tool calls to the correct message via parentMessageId',
        () {
      final p = processor();
      p.processChunk(chunk('TEXT_MESSAGE_START', {
        'messageId': 'msg-a',
        'role': 'assistant',
      }));
      p.processChunk(chunk('TOOL_CALL_START', {
        'toolCallId': 'tc-1',
        'toolCallName': 'myTool',
        'parentMessageId': 'msg-a',
      }));
      p.processChunk(ev.toolArgs('tc-1', '{"arg": "val"}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.finalizeStream();
      expect(p.getMessages(), hasLength(1));
      final call = partsOf(p).firstWhere((part) => part['type'] == 'tool-call');
      expect(call['name'], 'myTool');
      expect(call['state'], 'input-complete');
    });

    test(
        'should preserve the server message id in tool-first flows when parentMessageId is provided',
        () {
      final p = processor();
      p.processChunk(chunk('TOOL_CALL_START', {
        'toolCallId': 'tc-1',
        'toolCallName': 'lookupWeather',
        'parentMessageId': 'anthropic-msg-1',
      }));
      expect(p.getMessages().single['id'], 'anthropic-msg-1');
      p.processChunk(ev.toolArgs('tc-1', '{"location":"Berlin"}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(chunk('TEXT_MESSAGE_START', {
        'messageId': 'anthropic-msg-1',
        'role': 'assistant',
      }));
      p.processChunk(ev.textContent('It is sunny.', 'anthropic-msg-1'));
      p.processChunk(ev.textEnd('anthropic-msg-1'));
      p.finalizeStream();
      expect(p.getMessages(), hasLength(1));
      expect(p.getMessages().single['id'], 'anthropic-msg-1');
      expect(p.getMessages().single['parts'], [
        {
          'type': 'tool-call',
          'id': 'tc-1',
          'name': 'lookupWeather',
          'arguments': '{"location":"Berlin"}',
          'state': 'input-complete',
          'input': {'location': 'Berlin'},
        },
        {'type': 'text', 'content': 'It is sunny.'},
      ]);
    });

    test(
        'should not drop the first TEXT_MESSAGE_CONTENT delta in a tool-first flow (#1247)',
        () {
      final p = processor();
      p.processChunk(chunk('TOOL_CALL_START', {
        'toolCallId': 'tc-1',
        'toolCallName': 'lookupWeather',
        'parentMessageId': 'anthropic-msg-1',
      }));
      p.processChunk(ev.toolArgs('tc-1', '{"location":"Berlin"}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(chunk('TEXT_MESSAGE_START', {
        'messageId': 'anthropic-msg-1',
        'role': 'assistant',
      }));
      p.processChunk(ev.textContent('It is ', 'anthropic-msg-1'));
      p.processChunk(ev.textContent('sunny.', 'anthropic-msg-1'));
      p.processChunk(ev.textEnd('anthropic-msg-1'));
      p.finalizeStream();
      expect(
        partsOf(p).where((part) => part['type'] == 'text').toList(),
        [
          {'type': 'text', 'content': 'It is sunny.'},
        ],
      );
    });

    test(
        'should not drop the first TEXT_MESSAGE_CONTENT delta when the text starts before the tool call (#1247)',
        () {
      final p = processor();
      p.processChunk(ev.textStart('msg-1'));
      p.processChunk(chunk('TOOL_CALL_START', {
        'toolCallId': 'tc-1',
        'toolCallName': 'lookupWeather',
        'parentMessageId': 'msg-1',
      }));
      p.processChunk(ev.toolArgs('tc-1', '{"location":"Berlin"}'));
      p.processChunk(ev.toolEnd('tc-1'));
      p.processChunk(ev.textContent('It is '));
      p.processChunk(ev.textContent('sunny.'));
      p.processChunk(ev.textEnd());
      p.finalizeStream();
      expect(
        partsOf(p).where((part) => part['type'] == 'text').toList(),
        [
          {'type': 'text', 'content': 'It is sunny.'},
        ],
      );
    });
  });

  group('double onStreamEnd guard', () {
    test(
        'should fire onStreamEnd exactly once when RUN_FINISHED arrives before TEXT_MESSAGE_END',
        () {
      final spy = EventSpy();
      final p = processor(spy);
      p.processChunk(ev.textStart());
      p.processChunk(ev.textContent('hi'));
      p.processChunk(ev.runFinished());
      p.processChunk(ev.textEnd());
      p.processChunk(ev.runFinished());
      expect(spy.streamEnds, hasLength(1));
    });
  });

  group('replay', () {
    test(
        'replay should consume legacy approval-requested CUSTOM chunks after RUN_FINISHED',
        () async {
      final spy = EventSpy();
      final recording = ChunkRecording(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        chunks: [
          RecordedChunk(chunk: ev.runStarted(), timestamp: 1, index: 0),
          RecordedChunk(
            chunk: ev.toolStart('tc-1', 'dangerousTool'),
            timestamp: 2,
            index: 1,
          ),
          RecordedChunk(
            chunk: ev.toolArgs('tc-1', '{"action":"delete"}'),
            timestamp: 3,
            index: 2,
          ),
          RecordedChunk(
            chunk: ev.runFinished('tool_calls'),
            timestamp: 4,
            index: 3,
          ),
          RecordedChunk(
            chunk: ev.custom('approval-requested', {
              'toolCallId': 'tc-1',
              'toolName': 'dangerousTool',
              'input': {'action': 'delete'},
              'approval': {'id': 'approval-1', 'needsApproval': true},
            }),
            timestamp: 5,
            index: 4,
          ),
        ],
      );
      await StreamProcessor.replay(
        recording,
        StreamProcessorOptions(events: spy.events),
      );
      expect(spy.approvals.single, {
        'toolCallId': 'tc-1',
        'toolName': 'dangerousTool',
        'input': {'action': 'delete'},
        'approvalId': 'approval-1',
      });
    });
  });
}

Map<String, List<Map<String, dynamic>>> sectionsOf(StreamProcessor p) {
  final result = <String, List<Map<String, dynamic>>>{};
  for (final part in partsOf(p)) {
    result.putIfAbsent(part['type'] as String, () => []).add(part);
  }
  return result;
}

class _Strategy implements ChunkStrategy {
  final bool Function(String chunk, String accumulated) callback;
  final void Function()? onReset;
  _Strategy(this.callback, {this.onReset});

  @override
  bool shouldEmit(String chunk, String accumulated) =>
      callback(chunk, accumulated);

  @override
  void reset() => onReset?.call();
}

class _Parser implements JSONParser {
  final dynamic Function(String) callback;
  _Parser(this.callback);

  @override
  dynamic parse(String jsonString) => callback(jsonString);
}

extension _StartRecording on StreamProcessor {
  void _startRecordingForTest() {
    final dynamic self = this;
    // Exposed through recording: manual startRecording is public upstream.
    // ignore: avoid_dynamic_calls
    self.startRecording();
  }
}
