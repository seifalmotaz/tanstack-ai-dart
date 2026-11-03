import 'dart:async';
import 'dart:convert';

import 'package:tanstack_ai_dart/src/processing/processor.dart';
import 'package:test/test.dart';

Map<String, dynamic> chunk(String type, [Map<String, dynamic>? fields]) =>
    <String, dynamic>{
      'type': type,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      ...?fields,
    };

Stream<Map<String, dynamic>> streamOf(List<Map<String, dynamic>> chunks) =>
    Stream<Map<String, dynamic>>.fromIterable(chunks);

Map<String, dynamic> runStarted([String runId = 'run-1']) =>
    chunk('RUN_STARTED', {'runId': runId, 'threadId': 'thread-1'});

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

Map<String, dynamic> textStart([String id = 'msg-1']) =>
    chunk('TEXT_MESSAGE_START', {'messageId': id, 'role': 'assistant'});

Map<String, dynamic> textContent(String delta, [String id = 'msg-1']) =>
    chunk('TEXT_MESSAGE_CONTENT', {'messageId': id, 'delta': delta});

Map<String, dynamic> textEnd([String id = 'msg-1']) =>
    chunk('TEXT_MESSAGE_END', {'messageId': id});

Map<String, dynamic> textChunk(Map<String, dynamic> fields) =>
    chunk('TEXT_MESSAGE_CHUNK', fields);

Map<String, dynamic> toolStart(String id, String name) => chunk(
      'TOOL_CALL_START',
      {'toolCallId': id, 'toolCallName': name},
    );

Map<String, dynamic> toolArgs(String id, String delta) =>
    chunk('TOOL_CALL_ARGS', {'toolCallId': id, 'delta': delta});

Map<String, dynamic> toolEnd(String id) =>
    chunk('TOOL_CALL_END', {'toolCallId': id});

Map<String, dynamic> toolResult(String id, String content) =>
    chunk('TOOL_CALL_RESULT', {
      'toolCallId': id,
      'content': content,
      'messageId': 'result-$id',
    });

Map<String, dynamic> custom(String name, [dynamic value]) =>
    chunk('CUSTOM', {'name': name, 'value': value});

Map<String, dynamic> reasoningContent(String delta, [String id = 'r-1']) =>
    chunk('REASONING_MESSAGE_CONTENT', {'messageId': id, 'delta': delta});

Map<String, dynamic> stepStarted([String name = 'step-1']) =>
    chunk('STEP_STARTED', {'stepName': name});

class Spy {
  final messages = <List<Map<String, dynamic>>>[];
  int starts = 0;
  final ends = <Map<String, dynamic>>[];
  final errors = <Object>[];
  final toolCalls = <Map<String, dynamic>>[];
  final approvals = <Map<String, dynamic>>[];
  final thinking = <List<dynamic>>[];
  final textUpdates = <List<dynamic>>[];
  final toolStates = <List<dynamic>>[];
  final customEvents = <List<dynamic>>[];

  StreamProcessorEvents get events => StreamProcessorEvents(
        onMessagesChange: messages.add,
        onStreamStart: () => starts++,
        onStreamEnd: ends.add,
        onError: errors.add,
        onToolCall: toolCalls.add,
        onApprovalRequest: approvals.add,
        onThinkingUpdate: (id, step, content) =>
            thinking.add(<dynamic>[id, step, content]),
        onTextUpdate: (id, content) => textUpdates.add(<dynamic>[id, content]),
        onToolCallStateChange: (id, tool, state, args) =>
            toolStates.add(<dynamic>[id, tool, state, args]),
        onCustomEvent: (name, data, context) =>
            customEvents.add(<dynamic>[name, data, context]),
      );
}

StreamProcessor processor([Spy? spy]) =>
    StreamProcessor(StreamProcessorOptions(events: spy?.events));

List<Map<String, dynamic>> partsOf(StreamProcessor p) => p
    .getMessages()
    .expand((message) => (message['parts'] as List))
    .whereType<Map>()
    .map((part) => part.cast<String, dynamic>())
    .toList();

Map<String, dynamic>? partById(StreamProcessor p, String id) {
  for (final part in partsOf(p)) {
    if (part['id'] == id) return part;
  }
  return null;
}

List<String> capturedWarnings(void Function() action) {
  final warnings = <String>[];
  runZoned(
    action,
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => warnings.add(line),
    ),
  );
  return warnings;
}

void main() {
  test('normalizes nested dates on snapshot existing tool-result parts', () {
    final p = processor();
    p.processChunk(chunk('MESSAGES_SNAPSHOT', {
      'messages': [
        {
          'id': 'a1',
          'role': 'assistant',
          'parts': [
            {
              'type': 'tool-result',
              'toolCallId': 'tc1',
              'content': 'ok',
              'state': 'complete',
              'createdAt': '2026-08-20T00:00:00.000Z',
            },
            {
              'type': 'tool-result',
              'toolCallId': 'tc2',
              'content': 'bad',
              'state': 'complete',
              'createdAt': 'not-a-date',
            },
          ],
        },
      ],
    }));
    final results =
        partsOf(p).where((part) => part['type'] == 'tool-result').toList();
    expect(results[0]['createdAt'], isA<DateTime>());
    expect(results[1].containsKey('createdAt'), isFalse);
  });

  test(
      'TEXT_MESSAGE_START metadata.tanstack.model survives a TOOL_CALL_RESULT output-error',
      () {
    final p = processor();
    p.processChunk({
      ...textStart(),
      'metadata': {
        'tanstack': {'model': 'gpt-5.5'},
      },
    });
    p.processChunk(chunk('TOOL_CALL_START', {
      'toolCallId': 'tc-1',
      'toolCallName': 'getWeather',
      'parentMessageId': 'msg-1',
    }));
    p.processChunk(toolArgs('tc-1', '{}'));
    p.processChunk(toolEnd('tc-1'));
    p.processChunk({
      ...toolResult('tc-1', '{"error":"boom"}'),
      'metadata': {
        'tanstack': {'state': 'output-error'},
      },
    });
    final message = p.getMessages().single;
    expect(message['metadata'], {
      'tanstack': {'model': 'gpt-5.5'},
    });
    expect(
        partsOf(p).firstWhere((part) => part['type'] == 'tool-call')['state'],
        'error');
  });

  test(
      'MESSAGES_SNAPSHOT keeps both tool calls when two assistants share an id',
      () {
    final p = processor();
    p.processChunk(chunk('MESSAGES_SNAPSHOT', {
      'messages': [
        {'id': 'u1', 'role': 'user', 'content': 'notify me'},
        {
          'id': 'run-1-message',
          'role': 'assistant',
          'content': 'Showing a notification.',
          'toolCalls': [
            {
              'id': 'call-1',
              'type': 'function',
              'function': {
                'name': 'show_notification',
                'arguments': '{"message":42,"type":"info"}',
              },
            },
          ],
        },
        {
          'id': 'run-1-message',
          'role': 'assistant',
          'content': 'Showing a notification.',
          'toolCalls': [
            {
              'id': 'call-2',
              'type': 'function',
              'function': {
                'name': 'show_notification',
                'arguments': '{"message":"done","type":"info"}',
              },
            },
          ],
        },
      ],
    }));
    p.processChunk(chunk('MESSAGES_SNAPSHOT', {
      'messages': [
        {'id': 'u1', 'role': 'user', 'content': 'notify me'},
        {
          'id': 'run-1-message',
          'role': 'assistant',
          'content': 'Showing a notification.',
          'toolCalls': [
            {
              'id': 'call-1',
              'type': 'function',
              'function': {
                'name': 'show_notification',
                'arguments': '{"message":42,"type":"info"}',
              },
            },
          ],
        },
        {
          'id': 't1',
          'role': 'tool',
          'toolCallId': 'call-1',
          'content': '{"error":"Input validation failed"}',
          'error': 'Input validation failed',
        },
        {
          'id': 'run-1-message',
          'role': 'assistant',
          'content': 'Showing a notification.',
          'toolCalls': [
            {
              'id': 'call-2',
              'type': 'function',
              'function': {
                'name': 'show_notification',
                'arguments': '{"message":"done","type":"info"}',
              },
            },
          ],
        },
      ],
    }));
    final calls =
        partsOf(p).where((part) => part['type'] == 'tool-call').toList();
    expect(calls.where((part) => part['id'] == 'call-1'), hasLength(1));
    expect(calls.where((part) => part['id'] == 'call-2'), hasLength(1));
    expect(
        calls.firstWhere((part) => part['id'] == 'call-1')['state'], 'error');
  });

  test(
      'should handle TEXT_MESSAGE_CONTENT with delta (existing test preserved)',
      () {
    final p = processor();
    p.prepareAssistantMessage();
    p.processChunk(textContent('Hello'));
    expect(p.getMessages().single['parts'], [
      {'type': 'text', 'content': 'Hello'},
    ]);
  });

  test('ignores TOOL_CALL_START index extra and uses toolCalls.size', () {
    final p = processor();
    p.prepareAssistantMessage();
    p.processChunk(chunk('TOOL_CALL_START', {
      'toolCallId': 'tc-1',
      'toolCallName': 'toolA',
      'index': 5,
    }));
    expect(p.getState().toolCalls['tc-1']!.index, 0);
  });

  test('should track tool calls by toolCallId in Map, maintaining order', () {
    final p = processor();
    p.processChunk(toolStart('b', 'two'));
    p.processChunk(toolStart('a', 'one'));
    expect(p.getState().toolCallOrder, ['b', 'a']);
    expect(p.getState().toolCalls.keys.toList(), ['b', 'a']);
  });

  for (final entry in <(String, dynamic)>[
    ('throws on serialization', 'not-json'),
    ('serializes to undefined', 'list'),
    ('is null', null),
  ]) {
    test(
        'keeps the streamed arguments and input when TOOL_CALL_END.input ${entry.$1}',
        () {
      final p = processor();
      p.processChunk(toolStart('tc-1', 'getWeather'));
      p.processChunk(toolArgs('tc-1', '{"city":"NYC"}'));
      p.processChunk(chunk('TOOL_CALL_END', {
        'toolCallId': 'tc-1',
        'input': entry.$2,
      }));
      p.finalizeStream();
      final part = partById(p, 'tc-1')!;
      expect(part['state'], 'input-complete');
      expect(part['arguments'], '{"city":"NYC"}');
      expect(part['input'], {'city': 'NYC'});
    });
  }

  group('text interleaved between tool-call args (#1017)', () {
    const argsHead = '{"templateIds":["mock-gsk-e';
    const argsTail = 'fimosfermin"]}';
    const fullArgs = '$argsHead$argsTail';
    const fullInput = {
      'templateIds': ['mock-gsk-efimosfermin'],
    };
    const corruptedInput = {
      'templateIds': ['mock-gsk-e'],
    };

    test(
        'does not publish a truncated partial-JSON parse as input after interleaved text',
        () {
      final p = processor();
      p.processChunk(runStarted());
      p.processChunk(toolStart('tc-1', 'offerTemplates'));
      p.processChunk(toolArgs('tc-1', argsHead));
      p.processChunk(textContent('Let me look those up. '));
      p.processChunk(toolArgs('tc-1', argsTail));
      p.processChunk(toolEnd('tc-1'));
      p.processChunk(runFinished());
      p.finalizeStream();
      final part = partById(p, 'tc-1')!;
      expect(part['state'], 'input-complete');
      expect(part['arguments'], fullArgs);
      expect(part['input'], isNot(corruptedInput));
      expect(part['input'], fullInput);
    });

    test('never surfaces a lenient parse of truncated args as input', () {
      final p = processor();
      p.processChunk(runStarted());
      p.processChunk(toolStart('tc-1', 'offerTemplates'));
      p.processChunk(toolArgs('tc-1', argsHead));
      p.processChunk(textContent('Let me look those up. '));
      final during = partById(p, 'tc-1')!;
      expect(during['input'], isNot(corruptedInput));
      expect(during['input'], isNull);
      p.processChunk(toolEnd('tc-1'));
      p.processChunk(runFinished());
      p.finalizeStream();
      final part = partById(p, 'tc-1')!;
      expect(part['state'], 'input-complete');
      expect(part['arguments'], argsHead);
      expect(part['input'], isNull);
    });

    test(
        'leaves the call streaming through interleaved text so TOOL_CALL_END can still run',
        () {
      final p = processor();
      p.processChunk(runStarted());
      p.processChunk(toolStart('tc-1', 'offerTemplates'));
      p.processChunk(toolArgs('tc-1', argsHead));
      p.processChunk(textContent('Let me look those up. '));
      expect(p.getState().toolCalls['tc-1']!.state, 'input-streaming');
      expect(partById(p, 'tc-1')!['state'], 'input-streaming');
      expect(partById(p, 'tc-1')!['input'], isNull);
    });

    test(
        'RUN_FINISHED safety net completes full args when TOOL_CALL_END is missing',
        () {
      final p = processor();
      p.processChunk(runStarted());
      p.processChunk(toolStart('tc-1', 'offerTemplates'));
      p.processChunk(toolArgs('tc-1', argsHead));
      p.processChunk(textContent('Let me look those up. '));
      p.processChunk(toolArgs('tc-1', argsTail));
      p.processChunk(runFinished());
      p.finalizeStream();
      final part = partById(p, 'tc-1')!;
      expect(part['state'], 'input-complete');
      expect(part['arguments'], fullArgs);
      expect(part['input'], fullInput);
    });

    test('uses TOOL_CALL_END.input as canonical after interleaved text', () {
      final p = processor();
      p.processChunk(runStarted());
      p.processChunk(toolStart('tc-1', 'offerTemplates'));
      p.processChunk(toolArgs('tc-1', argsHead));
      p.processChunk(textContent('Let me look those up. '));
      p.processChunk(toolArgs('tc-1', argsTail));
      p.processChunk(chunk('TOOL_CALL_END', {
        'toolCallId': 'tc-1',
        'input': fullInput,
      }));
      p.processChunk(runFinished());
      p.finalizeStream();
      final part = partById(p, 'tc-1')!;
      expect(part['state'], 'input-complete');
      expect(part['input'], fullInput);
      expect(p.getState().toolCalls['tc-1']!.parsedArguments, fullInput);
    });

    test('repairs multiple parallel tool calls with interleaved text', () {
      final p = processor();
      p.processChunk(runStarted());
      p.processChunk(toolStart('tc-1', 'offerTemplates'));
      p.processChunk(toolArgs('tc-1', argsHead));
      p.processChunk(toolStart('tc-2', 'getWeather'));
      p.processChunk(toolArgs('tc-2', '{"city":"New '));
      p.processChunk(textContent('Working on it. '));
      p.processChunk(toolArgs('tc-1', argsTail));
      p.processChunk(toolArgs('tc-2', 'York"}'));
      p.processChunk(toolEnd('tc-1'));
      p.processChunk(toolEnd('tc-2'));
      p.processChunk(runFinished());
      p.finalizeStream();
      final first = partById(p, 'tc-1')!;
      expect(first['state'], 'input-complete');
      expect(first['arguments'], fullArgs);
      expect(first['input'], fullInput);
      final second = partById(p, 'tc-2')!;
      expect(second['state'], 'input-complete');
      expect(second['arguments'], '{"city":"New York"}');
      expect(second['input'], {'city': 'New York'});
    });

    test('still completes after a full text block between arg deltas', () {
      final p = processor();
      p.processChunk(runStarted());
      p.processChunk(toolStart('tc-1', 'offerTemplates'));
      p.processChunk(toolArgs('tc-1', argsHead));
      p.processChunk(textStart());
      p.processChunk(textContent('Let me look those up. '));
      p.processChunk(textEnd());
      p.processChunk(toolArgs('tc-1', argsTail));
      p.processChunk(toolEnd('tc-1'));
      p.processChunk(runFinished());
      p.finalizeStream();
      final part = partById(p, 'tc-1')!;
      expect(part['state'], 'input-complete');
      expect(part['arguments'], fullArgs);
      expect(part['input'], fullInput);
    });
  });

  test(
      'should create two separate TextParts for text before and after tool calls',
      () {
    final p = processor();
    p.processChunk(textStart());
    p.processChunk(textContent('before'));
    p.processChunk(toolStart('tc-1', 'x'));
    p.processChunk(toolArgs('tc-1', '{}'));
    p.processChunk(toolEnd('tc-1'));
    p.processChunk(textStart());
    p.processChunk(textContent('after'));
    final texts = partsOf(p)
        .where((part) => part['type'] == 'text')
        .map((part) => part['content'])
        .toList();
    expect(texts, ['before', 'after']);
  });

  test('should accumulate reasoning content from REASONING_MESSAGE_CONTENT',
      () {
    final p = processor();
    p.prepareAssistantMessage();
    p.processChunk(reasoningContent('Let me think'));
    p.processChunk(reasoningContent(' about this...'));
    final thinking = partsOf(p).single;
    expect(thinking['content'], 'Let me think about this...');
  });

  test('should handle thinking then text flow', () {
    final p = processor();
    p.prepareAssistantMessage();
    p.processChunk(runStarted());
    p.processChunk(reasoningContent('Let me think'));
    p.processChunk(reasoningContent(' about this...'));
    p.processChunk(textStart());
    p.processChunk(textContent("Here's my answer."));
    p.processChunk(textEnd());
    p.processChunk(runFinished());
    p.finalizeStream();
    final parts = p.getMessages().single['parts'] as List;
    expect(parts.map((part) => part['type']).toList(), ['thinking', 'text']);
    expect(parts[0]['content'], 'Let me think about this...');
    expect(p.getState().thinking, 'Let me think about this...');
    expect(p.getState().content, "Here's my answer.");
  });

  test(
      'should create assistant message lazily on thinking content (existing test preserved)',
      () {
    final p = processor();
    p.prepareAssistantMessage();
    expect(p.getMessages(), isEmpty);
    p.processChunk(reasoningContent('thinking...'));
    expect(p.getMessages(), hasLength(1));
    expect(partsOf(p).any((part) => part['type'] == 'thinking'), isTrue);
  });

  test('should handle REASONING_MESSAGE_CONTENT without prior STEP_STARTED',
      () {
    final p = processor();
    p.prepareAssistantMessage();
    p.processChunk(reasoningContent('thinking...', 'auto-step'));
    final thinking =
        partsOf(p).firstWhere((part) => part['type'] == 'thinking');
    expect(thinking['content'], 'thinking...');
    expect(thinking['stepId'], 'auto-step');
  });

  test(
      'should clear pendingThinkingStepId when a later STEP_STARTED arrives with an active message',
      () {
    final p = processor();
    p.processChunk(stepStarted('step-a'));
    p.processChunk(textStart());
    p.processChunk(stepStarted('step-b'));
    p.processChunk(reasoningContent('contentB'));
    final thinking =
        partsOf(p).where((part) => part['type'] == 'thinking').toList();
    expect(thinking.any((part) => part['stepId'] == 'step-a'), isFalse);
    expect(thinking, hasLength(1));
    expect(thinking.single['stepId'], 'step-b');
    expect(thinking.single['content'], 'contentB');
  });

  test(
      'should not update tool-call output when TOOL_CALL_END has no result (existing test)',
      () {
    final p = processor();
    p.processChunk(toolStart('tc-1', 'x'));
    p.processChunk(toolEnd('tc-1'));
    final call = partById(p, 'tc-1')!;
    expect(call.containsKey('output'), isFalse);
    expect(call['state'], 'input-complete');
  });

  for (final entry in <(String, Map<String, dynamic>?)>[
    ('no outcome', null),
    ('a success outcome', {'type': 'success'}),
  ]) {
    test('fires onToolCall for an unanswered call with ${entry.$1}', () {
      final spy = Spy();
      final p = processor(spy);
      p.processChunk(runStarted());
      p.processChunk(toolStart('tc-1', 'ping'));
      p.processChunk(toolArgs('tc-1', ''));
      p.processChunk(toolEnd('tc-1'));
      p.processChunk(chunk('RUN_FINISHED', {
        'runId': 'run-1',
        if (entry.$2 != null) 'outcome': entry.$2,
      }));
      expect(spy.toolCalls, hasLength(1));
      expect(spy.toolCalls.single, {
        'toolCallId': 'tc-1',
        'toolName': 'ping',
        'input': {},
      });
    });
  }

  test('ignores pendingToolCallIds of an earlier run', () {
    final spy = Spy();
    final p = processor(spy);
    p.processChunk(runStarted());
    p.processChunk(toolStart('tc-1', 'ping'));
    p.processChunk(toolEnd('tc-1'));
    p.processChunk(chunk('RUN_ERROR', {'message': 'boom', 'runId': 'run-1'}));
    p.processChunk(runStarted('run-2'));
    p.processChunk(chunk('RUN_FINISHED', {
      'runId': 'run-2',
      'outcome': {
        'type': 'success',
        'pendingToolCallIds': ['tc-1'],
      },
    }));
    expect(spy.toolCalls, isEmpty);
  });

  test('skips provider-executed calls, which have no TOOL_CALL_RESULT', () {
    final spy = Spy();
    final p = processor(spy);
    p.processChunk(runStarted());
    p.processChunk(chunk('TOOL_CALL_START', {
      'toolCallId': 'srvtoolu-1',
      'toolCallName': 'web_search',
      'metadata': {'providerExecuted': true},
    }));
    p.processChunk(chunk('TOOL_CALL_END', {'toolCallId': 'srvtoolu-1'}));
    p.processChunk(runFinished());
    expect(spy.toolCalls, isEmpty);
  });

  for (final entry in <(String, List<Map<String, dynamic>>, int)>[
    (
      'a client-tool interrupt',
      [
        {
          'id': 'int-1',
          'reason': 'client_tool_input',
          'toolCallId': 'tc-1',
          'metadata': {'kind': 'client_tool', 'toolName': 'ping', 'input': {}},
        },
      ],
      1,
    ),
    (
      'a batch with a generic interrupt',
      [
        {
          'id': 'int-1',
          'reason': 'client_tool_input',
          'toolCallId': 'tc-1',
          'metadata': {'kind': 'client_tool', 'toolName': 'ping', 'input': {}},
        },
        {
          'id': 'int-2',
          'reason': 'confirmation',
          'metadata': {
            'tanstack:interruptBinding': {'kind': 'generic'},
          },
        },
      ],
      0,
    ),
  ]) {
    test('leaves ${entry.$1} to the interrupt path', () {
      final spy = Spy();
      final p = processor(spy);
      p.processChunk(runStarted());
      p.processChunk(toolStart('tc-1', 'ping'));
      p.processChunk(toolArgs('tc-1', ''));
      p.processChunk(toolEnd('tc-1'));
      p.processChunk(chunk('RUN_FINISHED', {
        'runId': 'run-1',
        'outcome': {'type': 'interrupt', 'interrupts': entry.$2},
      }));
      expect(spy.toolCalls, hasLength(entry.$3));
    });
  }

  test('does not fire on an intermediate tool_calls turn of chat()', () {
    final spy = Spy();
    final p = processor(spy);
    p.processChunk(runStarted());
    p.processChunk(toolStart('tc-1', 'ping'));
    p.processChunk(toolArgs('tc-1', ''));
    p.processChunk(toolEnd('tc-1'));
    p.processChunk(runFinished('tool_calls'));
    expect(spy.toolCalls, isEmpty);
  });

  test('fires only the calls of the run that finishes', () {
    final spy = Spy();
    final p = processor(spy);
    p.processChunk(runStarted());
    p.processChunk(toolStart('tc-1', 'ping'));
    p.processChunk(toolEnd('tc-1'));
    p.processChunk(chunk('RUN_ERROR', {'message': 'boom', 'runId': 'run-1'}));
    p.processChunk(runStarted('run-2'));
    p.processChunk(toolStart('tc-2', 'ping'));
    p.processChunk(toolEnd('tc-2'));
    p.processChunk(chunk('RUN_FINISHED', {'runId': 'run-2'}));
    expect(spy.toolCalls, hasLength(1));
    expect(spy.toolCalls.single['toolCallId'], 'tc-2');
  });

  test('finds the call after a MESSAGES_SNAPSHOT', () {
    final spy = Spy();
    final p = processor(spy);
    p.processChunk(runStarted());
    p.processChunk(toolStart('tc-1', 'ping'));
    p.processChunk(toolArgs('tc-1', '{"n":1}'));
    p.processChunk(toolEnd('tc-1'));
    p.processChunk(chunk('MESSAGES_SNAPSHOT', {
      'messages': [
        {'id': 'u-1', 'role': 'user', 'content': 'ping me'},
        {
          'id': 'a-1',
          'role': 'assistant',
          'toolCalls': [
            {
              'id': 'tc-1',
              'type': 'function',
              'function': {'name': 'ping', 'arguments': '{"n":1}'},
            },
          ],
        },
      ],
    }));
    p.processChunk(chunk('RUN_FINISHED', {
      'runId': 'run-1',
      'outcome': {'type': 'success'},
    }));
    expect(spy.toolCalls.single, {
      'toolCallId': 'tc-1',
      'toolName': 'ping',
      'input': {'n': 1},
    });
  });

  test('parses the arguments of a call a parts snapshot left without input',
      () {
    final spy = Spy();
    final p = processor(spy);
    p.processChunk(runStarted());
    p.processChunk(toolStart('tc-1', 'ping'));
    p.processChunk(toolArgs('tc-1', '{"n":1}'));
    p.processChunk(chunk('MESSAGES_SNAPSHOT', {
      'messages': [
        {
          'id': 'a-1',
          'role': 'assistant',
          'parts': [
            {
              'type': 'tool-call',
              'id': 'tc-1',
              'name': 'ping',
              'arguments': '{"n":1}',
              'state': 'input-streaming',
            },
          ],
        },
      ],
    }));
    p.processChunk(chunk('RUN_FINISHED', {
      'runId': 'run-1',
      'outcome': {'type': 'success'},
    }));
    expect(spy.toolCalls.single['input'], {'n': 1});
  });

  test('keeps the calls of a run that another run overlaps', () {
    final spy = Spy();
    final p = processor(spy);
    p.processChunk(runStarted());
    p.processChunk(toolStart('tc-1', 'ping'));
    p.processChunk(toolEnd('tc-1'));
    p.processChunk(runStarted('run-2'));
    p.processChunk(runFinished('stop', 'run-1'));
    p.processChunk(runFinished('stop', 'run-2'));
    expect(spy.toolCalls.single['toolCallId'], 'tc-1');
  });

  test('runs a reused call id again in a later run', () {
    final spy = Spy();
    final p = processor(spy);
    p.processChunk(runStarted());
    p.processChunk(toolStart('call_0', 'ping'));
    p.processChunk(toolEnd('call_0'));
    p.processChunk(custom('tool-input-available', {
      'toolCallId': 'call_0',
      'toolName': 'ping',
      'input': {},
    }));
    p.processChunk(runFinished());
    p.clearMessages();
    p.processChunk(runStarted());
    p.processChunk(toolStart('call_0', 'ping'));
    p.processChunk(toolEnd('call_0'));
    p.processChunk(runFinished());
    expect(spy.toolCalls, hasLength(2));
  });

  test('does not fire again a call that an interrupt of another run sent', () {
    final spy = Spy();
    final p = processor(spy);
    p.processChunk(runStarted('run-2'));
    p.processChunk(runStarted());
    p.processChunk(toolStart('tc-1', 'ping'));
    p.processChunk(toolEnd('tc-1'));
    p.processChunk(chunk('RUN_FINISHED', {
      'runId': 'run-1',
      'outcome': {
        'type': 'interrupt',
        'interrupts': [
          {
            'id': 'int-1',
            'reason': 'client_tool_input',
            'toolCallId': 'tc-1',
            'metadata': {
              'kind': 'client_tool',
              'toolName': 'ping',
              'input': {},
            },
          },
        ],
      },
    }));
    p.processChunk(runFinished('stop', 'run-2'));
    expect(spy.toolCalls, hasLength(1));
  });

  test('fires a call once when the same RUN_FINISHED comes twice', () {
    final spy = Spy();
    final p = processor(spy);
    p.processChunk(runStarted());
    p.processChunk(toolStart('tc-1', 'ping'));
    p.processChunk(toolEnd('tc-1'));
    p.processChunk(runFinished());
    p.processChunk(runFinished());
    expect(spy.toolCalls, hasLength(1));
  });

  test('fires a call once when pendingToolCallIds names it twice', () {
    final spy = Spy();
    final p = processor(spy);
    p.processChunk(runStarted());
    p.processChunk(toolStart('tc-1', 'ping'));
    p.processChunk(toolEnd('tc-1'));
    p.processChunk(chunk('RUN_FINISHED', {
      'runId': 'run-1',
      'outcome': {
        'type': 'success',
        'pendingToolCallIds': ['tc-1', 'tc-1'],
      },
    }));
    expect(spy.toolCalls, hasLength(1));
  });

  test('fires a call once when it starts again after a MESSAGES_SNAPSHOT', () {
    final spy = Spy();
    final p = processor(spy);
    p.processChunk(runStarted());
    p.processChunk(toolStart('tc-1', 'ping'));
    p.processChunk(toolEnd('tc-1'));
    p.processChunk(chunk('MESSAGES_SNAPSHOT', {
      'messages': [
        {
          'id': 'a-1',
          'role': 'assistant',
          'toolCalls': [
            {
              'id': 'tc-1',
              'type': 'function',
              'function': {'name': 'ping', 'arguments': '{}'},
            },
          ],
        },
      ],
    }));
    p.processChunk(toolStart('tc-1', 'ping'));
    p.processChunk(toolEnd('tc-1'));
    p.processChunk(runFinished());
    expect(spy.toolCalls, hasLength(1));
  });

  for (final answer in ['an output', 'a tool-result part']) {
    test('skips a call that has $answer', () {
      final spy = Spy();
      final p = processor(spy);
      p.processChunk(runStarted());
      p.processChunk(toolStart('tc-1', 'ping'));
      p.processChunk(toolEnd('tc-1'));
      p.addToolResult('tc-1', {'pong': true});
      if (answer == 'a tool-result part') {
        p.setMessages(p.getMessages().map((message) {
          return <String, dynamic>{
            ...message,
            'parts': (message['parts'] as List).map((part) {
              if (part is Map && part['type'] == 'tool-call') {
                return <String, dynamic>{
                  ...part.cast<String, dynamic>(),
                  'state': 'input-complete',
                  'output': null,
                };
              }
              return part;
            }).toList(),
          };
        }).toList());
      }
      p.processChunk(runFinished());
      expect(spy.toolCalls, isEmpty);
    });
  }

  test(
      'should deliver client tool interrupt before stream end for mixed tool streams',
      () async {
    final spy = Spy();
    final p = processor(spy);
    final order = <String>[];
    final wrapped = StreamProcessor(StreamProcessorOptions(
      events: StreamProcessorEvents(
        onToolCall: (args) {
          order.add('tool-call');
          spy.toolCalls.add(args);
        },
        onStreamEnd: (_) => order.add('stream-end'),
      ),
    ));
    for (final event in [
      runStarted(),
      toolStart('call_server', 'searchTools'),
      toolArgs('call_server', '{"query":"hello"}'),
      toolResult('call_server', '{"results":["a","b"]}'),
      toolStart('call_client', 'showNotification'),
      toolArgs('call_client', '{"message":"done"}'),
      custom('tool-input-available', {
        'toolCallId': 'call_client',
        'toolName': 'showNotification',
        'input': {'message': 'done'},
      }),
      runFinished('tool_calls'),
    ]) {
      wrapped.processChunk(event);
    }
    expect(order, ['tool-call']);
    expect(p.getMessages(), isEmpty);
  });

  test('should not fire onApprovalRequest for approval-requested without data',
      () {
    final spy = Spy();
    final p = processor(spy);
    p.processChunk(custom('approval-requested'));
    expect(spy.approvals, isEmpty);
  });

  test('should handle custom events with no data', () {
    final spy = Spy();
    final p = processor(spy);
    p.processChunk(custom('progress'));
    expect(spy.customEvents.single[0], 'progress');
    expect(spy.customEvents.single[1], isNull);
  });

  test('should handle multiple different custom events in sequence', () {
    final spy = Spy();
    final p = processor(spy);
    p.processChunk(custom('a', {'x': 1}));
    p.processChunk(custom('b', {'x': 2}));
    expect(spy.customEvents.map((event) => event[0]).toList(), ['a', 'b']);
  });

  test('should return false when some tool calls are complete but not all', () {
    final p = processor();
    p.processChunk(toolStart('a', 'one'));
    p.processChunk(toolEnd('a'));
    p.processChunk(toolResult('a', '{}'));
    p.processChunk(toolStart('b', 'two'));
    p.processChunk(toolArgs('b', '{}'));
    p.processChunk(toolEnd('b'));
    expect(p.areAllToolsComplete(), isFalse);
  });

  test(
      'should not create assistant message during empty multi-turn continuation',
      () {
    final p = processor();
    p.addUserMessage('recommend a guitar');
    p.prepareAssistantMessage();
    p.processChunk(toolStart('tc-1', 'getGuitars'));
    p.processChunk(chunk('TOOL_CALL_END', {
      'toolCallId': 'tc-1',
      'input': {},
    }));
    p.processChunk(runFinished('tool_calls'));
    p.finalizeStream();
    expect(p.getMessages(), hasLength(2));
    p.prepareAssistantMessage();
    p.processChunk(runFinished('stop'));
    p.finalizeStream();
    expect(p.getMessages(), hasLength(2));
  });

  test('TOOL_CALL_START uses spec toolCallName for the part name', () {
    final p = processor();
    p.prepareAssistantMessage();
    p.processChunk(toolStart('tc-1', 'legacyTool'));
    expect(p.getState().toolCalls['tc-1']!.name, 'legacyTool');
    expect(partById(p, 'tc-1')!['name'], 'legacyTool');
  });

  test(
      'TOOL_CALL_END for already input-complete tool call should be a no-op for state',
      () {
    final p = processor();
    p.processChunk(toolStart('tc-1', 'getWeather'));
    p.processChunk(chunk('TOOL_CALL_END', {
      'toolCallId': 'tc-1',
      'input': {},
    }));
    expect(p.getState().toolCalls['tc-1']!.state, 'input-complete');
    p.processChunk(toolResult('tc-1', '{"temp":72}'));
    expect(partsOf(p).any((part) => part['type'] == 'tool-result'), isTrue);
  });

  test('onMessagesChange should be called on every message state change', () {
    final spy = Spy();
    final p = processor(spy);
    p.prepareAssistantMessage();
    p.processChunk(textContent('Hello'));
    p.processChunk(textContent(' world'));
    p.processChunk(runFinished());
    p.finalizeStream();
    expect(spy.messages.length, greaterThanOrEqualTo(2));
  });

  test(
      'onThinkingUpdate should fire for each REASONING_MESSAGE_CONTENT delta with stepId',
      () {
    final spy = Spy();
    final p = processor(spy);
    p.prepareAssistantMessage();
    p.processChunk(stepStarted('step-1'));
    p.processChunk(reasoningContent('Thinking'));
    p.processChunk(reasoningContent(' more'));
    final id = p.getCurrentAssistantMessageId()!;
    expect(spy.thinking, [
      [id, 'step-1', 'Thinking'],
      [id, 'step-1', 'Thinking more'],
    ]);
  });

  test('getRecording should return null when recording is not enabled', () {
    expect(processor().getRecording(), isNull);
  });

  test('replay should pass options to the new processor', () async {
    final spy = Spy();
    final recording = ChunkRecording(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      chunks: [
        RecordedChunk(chunk: textContent('Hello'), timestamp: 1, index: 0),
        RecordedChunk(chunk: runFinished(), timestamp: 2, index: 1),
      ],
    );
    await StreamProcessor.replay(
      recording,
      StreamProcessorOptions(events: spy.events),
    );
    expect(spy.ends, hasLength(1));
  });

  test('finalizeStream should not fire onStreamEnd if no message was created',
      () {
    final spy = Spy();
    final p = processor(spy);
    p.prepareAssistantMessage();
    p.finalizeStream();
    expect(spy.ends, isEmpty);
  });

  test('TEXT_MESSAGE_START should flush pending text before resetting segment',
      () {
    final p = processor();
    p.prepareAssistantMessage();
    p.processChunk(textContent('Buffered'));
    p.processChunk(textStart('msg-2'));
    expect(p.getState().content, 'Buffered');
  });

  test(
      'should emit onStreamStart when auto-creating a message from content event',
      () {
    final spy = Spy();
    final p = processor(spy);
    p.processChunk(textContent('Hi'));
    expect(spy.starts, 1);
  });

  test('should still work when only startAssistantMessage is used', () {
    final p = processor();
    final id = p.startAssistantMessage();
    p.processChunk(textContent('Hello', id));
    expect(p.getMessages().single['id'], id);
  });

  test(
      'keeps message ids unique when a tool call names a message that already exists',
      () {
    final p = processor();
    p.processChunk(textStart('msg-1'));
    p.processChunk(textContent('hi', 'msg-1'));
    p.processChunk(chunk('TOOL_CALL_START', {
      'toolCallId': 'tc-1',
      'toolCallName': 'x',
      'parentMessageId': 'msg-1',
    }));
    p.processChunk(toolEnd('tc-1'));
    final ids = p.getMessages().map((message) => message['id']).toSet();
    expect(ids.length, p.getMessages().length);
  });

  test('keeps the thinking and the tool call in the existing parent message',
      () {
    final p = processor();
    p.processChunk(reasoningContent('thinking', 'r-1'));
    p.processChunk(chunk('TOOL_CALL_START', {
      'toolCallId': 'tc-1',
      'toolCallName': 'x',
      'parentMessageId': p.getMessages().single['id'],
    }));
    p.processChunk(toolEnd('tc-1'));
    expect(p.getMessages(), hasLength(1));
    expect(p.getMessages().single['parts'].map((part) => part['type']).toList(),
        ['thinking', 'tool-call']);
  });

  test('puts a tool call in its parent message, not in the active one', () {
    final p = processor();
    p.processChunk(textStart('a'));
    p.processChunk(textContent('A', 'a'));
    p.processChunk(textStart('b'));
    p.processChunk(chunk('TOOL_CALL_START', {
      'toolCallId': 'tc-1',
      'toolCallName': 'x',
      'parentMessageId': 'a',
    }));
    p.processChunk(toolEnd('tc-1'));
    final a = p.getMessages().firstWhere((message) => message['id'] == 'a');
    final b = p.getMessages().firstWhere((message) => message['id'] == 'b');
    expect((a['parts'] as List).any((part) => part['type'] == 'tool-call'),
        isTrue);
    expect((b['parts'] as List).any((part) => part['type'] == 'tool-call'),
        isFalse);
  });

  test('anchors a tool message that also has a valid UI resource', () {
    final p = processor();
    final resource = {
      'type': 'ui-resource',
      'resource': {
        'uri': 'ui://widget/weather',
        'mimeType': 'text/html',
        'text': '<div>72</div>',
      },
      'toolCallId': 'tc-1',
      'toolName': 'getWeather',
    };
    p.processChunk(chunk('MESSAGES_SNAPSHOT', {
      'messages': [
        {
          'id': 'a1',
          'role': 'assistant',
          'content': 'Checking.',
          'toolCalls': [
            {
              'id': 'tc-1',
              'type': 'function',
              'function': {'name': 'getWeather', 'arguments': '{}'},
            },
          ],
        },
        {
          'id': 't1',
          'role': 'tool',
          'content': '{"temp":72}',
          'toolCallId': 'tc-1',
          'metadata': {
            'tanstack': {
              'uiResources': [resource],
            },
          },
        },
      ],
    }));
    expect(p.getMessages(), hasLength(1));
    final parts = p.getMessages().single['parts'] as List;
    expect(
      parts.any((part) => jsonEncode(part) == jsonEncode(resource)),
      isTrue,
    );
    expect(
      parts.where(
        (part) => part['type'] == 'tool-result' && part['toolCallId'] == 'tc-1',
      ),
      hasLength(1),
    );
  });

  test('keeps one UI resource through repeated wire snapshot round trips', () {
    final p = processor();
    final resource = {
      'type': 'ui-resource',
      'resource': {
        'uri': 'ui://widget/weather',
        'mimeType': 'text/html',
        'text': '<div>72</div>',
      },
      'toolCallId': 'tc-1',
      'toolName': 'getWeather',
    };
    Map<String, dynamic> snapshot() => chunk('MESSAGES_SNAPSHOT', {
          'messages': [
            {
              'id': 'a1',
              'role': 'assistant',
              'content': 'Checking.',
              'toolCalls': [
                {
                  'id': 'tc-1',
                  'type': 'function',
                  'function': {'name': 'getWeather', 'arguments': '{}'},
                },
              ],
            },
            {
              'id': 't1',
              'role': 'tool',
              'content': '{"temp":72}',
              'toolCallId': 'tc-1',
              'metadata': {
                'tanstack': {
                  'uiResources': [resource],
                },
              },
            },
          ],
        });
    p.processChunk(snapshot());
    for (var cycle = 0; cycle < 2; cycle++) {
      final wire = jsonDecode(jsonEncode(p.getMessages())) as List;
      p.processChunk(chunk('MESSAGES_SNAPSHOT', {'messages': wire}));
      final assistant = p.getMessages().firstWhere(
            (message) => (message['parts'] as List).any(
              (part) => part['type'] == 'tool-call' && part['id'] == 'tc-1',
            ),
          );
      expect(
        (assistant['parts'] as List)
            .where((part) => part['type'] == 'ui-resource'),
        [resource],
      );
      expect(
        (assistant['parts'] as List).where(
          (part) =>
              part['type'] == 'tool-result' && part['toolCallId'] == 'tc-1',
        ),
        hasLength(1),
      );
    }
  });

  test(
      'should anchor each tool result into its own assistant turn across multiple turns',
      () {
    final p = processor();
    p.processChunk(chunk('MESSAGES_SNAPSHOT', {
      'messages': [
        {'id': 'u1', 'role': 'user', 'content': 'weather Berlin and Paris?'},
        {
          'id': 'a1',
          'role': 'assistant',
          'content': 'Checking Berlin.',
          'toolCalls': [
            {
              'id': 'tc-1',
              'type': 'function',
              'function': {
                'name': 'getWeather',
                'arguments': '{"loc":"Berlin"}'
              },
            },
          ],
        },
        {
          'id': 't1',
          'role': 'tool',
          'content': '{"temp":72}',
          'toolCallId': 'tc-1',
        },
        {
          'id': 'a2',
          'role': 'assistant',
          'content': 'Checking Paris.',
          'toolCalls': [
            {
              'id': 'tc-2',
              'type': 'function',
              'function': {
                'name': 'getWeather',
                'arguments': '{"loc":"Paris"}'
              },
            },
          ],
        },
        {
          'id': 't2',
          'role': 'tool',
          'content': '{"temp":65}',
          'toolCallId': 'tc-2',
        },
      ],
    }));
    expect(p.getMessages(), hasLength(3));
    expect(p.getMessages()[1]['id'], 'a1');
    expect(
      (p.getMessages()[1]['parts'] as List)
          .where((part) => part['type'] == 'tool-result')
          .map((part) => part['toolCallId']),
      ['tc-1'],
    );
    expect(p.getMessages()[2]['id'], 'a2');
    expect(
      (p.getMessages()[2]['parts'] as List)
          .where((part) => part['type'] == 'tool-result')
          .map((part) => part['toolCallId']),
      ['tc-2'],
    );
  });

  test(
      'should anchor a tool result into the message containing its tool-call, not a later reasoning message',
      () {
    final p = processor();
    p.processChunk(chunk('MESSAGES_SNAPSHOT', {
      'messages': [
        {'id': 'u1', 'role': 'user', 'content': 'weather?'},
        {
          'id': 'a1',
          'role': 'assistant',
          'content': 'Checking.',
          'toolCalls': [
            {
              'id': 'tc-1',
              'type': 'function',
              'function': {'name': 'getWeather', 'arguments': '{}'},
            },
          ],
        },
        {'id': 'r1', 'role': 'reasoning', 'content': 'Wants weather.'},
        {
          'id': 't1',
          'role': 'tool',
          'content': '{"temp":72}',
          'toolCallId': 'tc-1',
        },
      ],
    }));
    expect(p.getMessages(), hasLength(3));
    final callMessage = p.getMessages().firstWhere(
          (message) => (message['parts'] as List).any(
              (part) => part['type'] == 'tool-call' && part['id'] == 'tc-1'),
        );
    expect(callMessage['id'], 'a1');
    final reasoning =
        p.getMessages().firstWhere((message) => message['id'] == 'r1');
    expect(
      (reasoning['parts'] as List).any((part) => part['type'] == 'tool-result'),
      isFalse,
    );
    p.addToolResult('tc-1', {'temp': 72});
    expect(
      partsOf(p).where((part) => part['type'] == 'tool-result'),
      hasLength(1),
    );
  });

  test('should keep carrying a tool-call forward across consecutive snapshots',
      () {
    final p = processor();
    p.prepareAssistantMessage();
    p.processChunk(toolStart('tc-1', 'getWeather'));
    p.processChunk(toolArgs('tc-1', '{"loc":"Berlin"}'));
    p.processChunk(toolEnd('tc-1'));
    final snapshot = chunk('MESSAGES_SNAPSHOT', {
      'messages': [
        {'id': 'u1', 'role': 'user', 'content': 'weather Berlin?'},
        {'id': 'a1', 'role': 'assistant', 'content': 'Let me check.'},
        {
          'id': 't1',
          'role': 'tool',
          'content': '{"temp":72}',
          'toolCallId': 'tc-1',
        },
      ],
    });
    p.processChunk(snapshot);
    p.processChunk(snapshot);
    final parts = p.getMessages()[1]['parts'] as List;
    final calls = parts.where((part) => part['type'] == 'tool-call').toList();
    expect(calls, hasLength(1));
    expect(calls.single['name'], 'getWeather');
    expect(parts.where((part) => part['type'] == 'tool-result'), hasLength(1));
    p.addToolResult('tc-1', {'temp': 72});
  });

  test('should warn when a snapshot tool-result has no recoverable tool-call',
      () {
    final warnings = capturedWarnings(() {
      final p = processor();
      p.processChunk(chunk('MESSAGES_SNAPSHOT', {
        'messages': [
          {'id': 'u1', 'role': 'user', 'content': 'weather?'},
          {'id': 'a1', 'role': 'assistant', 'content': 'Let me check.'},
          {
            'id': 't1',
            'role': 'tool',
            'content': '{"temp":72}',
            'toolCallId': 'tc-1',
          },
        ],
      }));
      expect(
        (p.getMessages()[1]['parts'] as List)
            .any((part) => part['type'] == 'tool-result'),
        isTrue,
      );
    });
    expect(
      warnings.any(
        (line) =>
            line.contains('tool-result for "tc-1" but no matching tool-call'),
      ),
      isTrue,
    );
  });

  test(
      'should normalize AG-UI messages without parts to UIMessage[] with parts array',
      () {
    final p = processor();
    p.processChunk(chunk('MESSAGES_SNAPSHOT', {
      'messages': [
        {'id': 'ag-1', 'role': 'user', 'content': 'Hello'},
        {'id': 'ag-2', 'role': 'assistant', 'content': 'Hi there!'},
      ],
    }));
    for (final message in p.getMessages()) {
      expect(message['parts'], isA<List<dynamic>>());
    }
    expect(
      (p.getMessages()[0]['parts'] as List).single,
      {'type': 'text', 'content': 'Hello'},
    );
    expect(
      (p.getMessages()[1]['parts'] as List).single,
      {'type': 'text', 'content': 'Hi there!'},
    );
  });

  test('should preserve original AG-UI message id after normalization', () {
    final p = processor();
    p.processChunk(chunk('MESSAGES_SNAPSHOT', {
      'messages': [
        {'id': 'original-id-1', 'role': 'user', 'content': 'ping'},
        {'id': 'original-id-2', 'role': 'assistant', 'content': 'pong'},
      ],
    }));
    expect(p.getMessages().map((message) => message['id']).toList(),
        ['original-id-1', 'original-id-2']);
  });

  test('should map AG-UI assistant toolCalls to tool-call parts', () {
    final p = processor();
    p.processChunk(chunk('MESSAGES_SNAPSHOT', {
      'messages': [
        {
          'id': 'asst-tc',
          'role': 'assistant',
          'content': 'Let me check',
          'toolCalls': [
            {
              'id': 'call-1',
              'type': 'function',
              'function': {
                'name': 'getWeather',
                'arguments': '{"city":"Paris"}',
              },
            },
          ],
        },
      ],
    }));
    final call = partById(p, 'call-1')!;
    expect(call['name'], 'getWeather');
    expect(call['arguments'], '{"city":"Paris"}');
  });

  test('should map an AG-UI tool message to a tool-result part', () {
    final warnings = capturedWarnings(() {
      final p = processor();
      p.processChunk(chunk('MESSAGES_SNAPSHOT', {
        'messages': [
          {
            'id': 'tool-msg',
            'role': 'tool',
            'toolCallId': 'call-1',
            'content': '{"tempC":21}',
          },
        ],
      }));
      expect(p.getMessages().single['role'], 'assistant');
      final result = partsOf(p).single;
      expect(result['type'], 'tool-result');
      expect(result['toolCallId'], 'call-1');
      expect(result['content'], '{"tempC":21}');
    });
    expect(
      warnings
          .any((line) => line.contains('no assistant message to anchor into')),
      isTrue,
    );
  });

  test('should preserve an AG-UI tool error in a snapshot', () {
    final p = processor();
    p.processChunk(chunk('MESSAGES_SNAPSHOT', {
      'messages': [
        {
          'id': 'tool-msg',
          'role': 'tool',
          'toolCallId': 'call-1',
          'content': '{"error":"boom"}',
          'error': 'boom',
        },
      ],
    }));
    expect(partsOf(p).single, {
      'type': 'tool-result',
      'id': 'tool-msg',
      'toolCallId': 'call-1',
      'content': '{"error":"boom"}',
      'state': 'error',
      'error': 'boom',
    });
  });

  test(
      'should not throw when accessing parts.find() on snapshot-normalized messages',
      () {
    final p = processor();
    p.processChunk(chunk('MESSAGES_SNAPSHOT', {
      'messages': [
        {'id': 'snap-user', 'role': 'user', 'content': 'Use the weather tool'},
        {'id': 'snap-asst', 'role': 'assistant', 'content': ''},
      ],
    }));
    expect(() {
      p.processChunk(chunk('TOOL_CALL_START', {
        'toolCallId': 'tc-1',
        'toolCallName': 'getWeather',
        'parentMessageId': 'snap-asst',
      }));
    }, returnsNormally);
  });

  test(
      'should pass through messages that already have a parts array without re-normalizing',
      () {
    final p = processor();
    p.processChunk(chunk('MESSAGES_SNAPSHOT', {
      'messages': [
        {
          'id': 'ui-1',
          'role': 'user',
          'parts': [
            {'type': 'text', 'content': 'Already a UIMessage'},
          ],
        },
        {
          'id': 'ui-2',
          'role': 'assistant',
          'parts': [
            {'type': 'text', 'content': 'With a tool call'},
            {
              'type': 'tool-call',
              'id': 'tc-existing',
              'name': 'myTool',
              'arguments': '{}',
              'state': 'complete',
            },
          ],
        },
      ],
    }));
    expect(p.getMessages(), hasLength(2));
    expect(p.getMessages()[0]['parts'], [
      {'type': 'text', 'content': 'Already a UIMessage'},
    ]);
    expect(partById(p, 'tc-existing')!['state'], 'complete');
  });

  test('should generate a fallback id when AG-UI message has no id field', () {
    final p = processor();
    p.processChunk(chunk('MESSAGES_SNAPSHOT', {
      'messages': [
        {'role': 'user', 'content': 'No id here'},
      ],
    }));
    expect(p.getMessages().single['id'], isA<String>());
    expect(p.getMessages().single['id'], isNotEmpty);
  });

  test('should handle empty messages array without errors', () {
    final p = processor();
    p.addUserMessage('hello');
    p.processChunk(chunk('MESSAGES_SNAPSHOT', {'messages': <dynamic>[]}));
    expect(p.getMessages(), isEmpty);
  });

  test(
      'should correctly route TEXT_MESSAGE_CONTENT after a snapshot with raw AG-UI messages',
      () {
    final p = processor();
    p.processChunk(chunk('MESSAGES_SNAPSHOT', {
      'messages': [
        {'id': 'snap-user', 'role': 'user', 'content': 'Tell me a story'},
        {'id': 'snap-asst', 'role': 'assistant', 'content': 'Once upon a '},
      ],
    }));
    p.processChunk(textContent('time...', 'snap-asst'));
    p.processChunk(runFinished());
    p.finalizeStream();
    final assistant =
        p.getMessages().firstWhere((message) => message['id'] == 'snap-asst');
    expect(
      (assistant['parts'] as List)
          .firstWhere((part) => part['type'] == 'text')['content'],
      contains('time...'),
    );
  });

  test(
      'appends leftover reasoning after a stop RUN_FINISHED onto the same thinking part',
      () {
    final p = processor();
    p.prepareAssistantMessage();
    p.processChunk(runStarted());
    p.processChunk(stepStarted('step-1'));
    p.processChunk(reasoningContent('The user is asking for a beginner.'));
    p.processChunk(runFinished());
    p.processChunk(reasoningContent(' \$1,299.'));
    final thinking =
        partsOf(p).where((part) => part['type'] == 'thinking').toList();
    expect(thinking, hasLength(1));
    expect(thinking.single['content'],
        'The user is asking for a beginner. \$1,299.');
  });

  test('files each model call on its own assistant message (#1533)', () {
    final p = processor();
    p.processChunk(runStarted());
    p.processChunk(stepStarted('step-a'));
    p.processChunk(reasoningContent('think A', 'rs_A'));
    p.processChunk(textStart('msg-1'));
    p.processChunk(textContent('hello', 'msg-1'));
    p.processChunk(chunk('TOOL_CALL_START', {
      'toolCallId': 'call_S',
      'toolCallName': 'search',
      'parentMessageId': 'msg-1',
    }));
    p.processChunk(toolArgs('call_S', '{}'));
    p.processChunk(toolEnd('call_S'));
    p.processChunk(runFinished('tool_calls', 'run-1'));
    p.processChunk(toolResult('call_S', '{"ok":true}'));
    p.processChunk(chunk('TOOL_CALL_START', {
      'toolCallId': 'call_G',
      'toolCallName': 'get',
      'parentMessageId': 'msg-2',
    }));
    p.processChunk(toolArgs('call_G', '{}'));
    p.processChunk(toolEnd('call_G'));
    p.processChunk(runFinished('tool_calls', 'run-2'));
    p.processChunk(toolResult('call_G', '{"ok":true}'));
    p.processChunk(stepStarted('step-b'));
    p.processChunk(reasoningContent('think B', 'rs_B'));
    p.processChunk(textStart('msg-3'));
    p.processChunk(textContent('bye', 'msg-3'));
    p.processChunk(runFinished('stop', 'run-3'));
    final messages = p.getMessages();
    expect(messages.map((message) => message['id']).toList(),
        ['msg-1', 'msg-2', 'msg-3']);
    expect(
      messages[0]['parts'].map((part) => part['type']).toList(),
      ['thinking', 'text', 'tool-call', 'tool-result'],
    );
    expect(
      messages[1]['parts'].map((part) => part['type']).toList(),
      ['tool-call', 'tool-result'],
    );
    expect(
      messages[2]['parts'].map((part) => part['type']).toList(),
      ['thinking', 'text'],
    );
  });

  test('puts a signature on the step it names, not the active step (#1533)',
      () {
    final p = processor();
    p.processChunk(runStarted());
    p.processChunk(stepStarted('step-1'));
    p.processChunk(reasoningContent('first', 'rs_A'));
    p.processChunk(stepStarted('step-2'));
    p.processChunk(reasoningContent('second', 'rs_B'));
    p.processChunk(chunk('REASONING_ENCRYPTED_VALUE', {
      'subtype': 'message',
      'entityId': 'rs_A',
      'encryptedValue': 'sig-a',
    }));
    p.processChunk(runFinished('tool_calls'));
    p.processChunk(reasoningContent('next', 'rs_C'));
    p.processChunk(chunk('REASONING_ENCRYPTED_VALUE', {
      'subtype': 'message',
      'entityId': 'rs_A',
      'encryptedValue': 'sig-a-late',
    }));
    final messages = p.getMessages();
    expect(messages, hasLength(2));
    expect(messages[0]['parts'], [
      {
        'type': 'thinking',
        'content': 'first',
        'stepId': 'step-1',
        'signature': 'sig-a-late',
      },
      {'type': 'thinking', 'content': 'second', 'stepId': 'step-2'},
    ]);
    expect(messages[1]['parts'], [
      {'type': 'thinking', 'content': 'next', 'stepId': 'rs_C'},
    ]);
  });

  test('keeps reasoning from a second open run off the first message (#1533)',
      () {
    final p = processor();
    p.processChunk(runStarted('run-A'));
    p.processChunk(textStart('message-A'));
    p.processChunk(textContent('A output', 'message-A'));
    p.processChunk(runStarted('run-B'));
    p.processChunk(chunk('REASONING_MESSAGE_CONTENT', {
      'messageId': 'reasoning-B',
      'delta': 'B reasoning',
      'metadata': {
        'tanstack': {'runId': 'run-B'},
      },
    }));
    final messages = p.getMessages();
    expect(messages, hasLength(2));
    expect(messages[0]['id'], 'message-A');
    expect(messages[0]['metadata'], isNull);
    expect(messages[0]['parts'], [
      {'type': 'text', 'content': 'A output'},
    ]);
    expect(messages[1]['parts'].first, {
      'type': 'thinking',
      'content': 'B reasoning',
      'stepId': 'reasoning-B',
    });
    expect(messages[1]['metadata']['tanstack']['runId'], 'run-B');
  });

  test(
      'flushes leftover text after a stop RUN_FINISHED and fires onStreamEnd once',
      () {
    final spy = Spy();
    final p = processor(spy);
    p.prepareAssistantMessage();
    p.processChunk(runStarted());
    p.processChunk(textStart('msg-1'));
    p.processChunk(textContent('Hello', 'msg-1'));
    p.processChunk(runFinished());
    expect(spy.ends, hasLength(1));
    expect(p.getState().done, isTrue);
    p.processChunk(textContent(' world', 'msg-1'));
    expect(p.getState().done, isFalse);
    p.processChunk(textEnd('msg-1'));
    p.finalizeStream();
    expect(
      (p.getMessages()[0]['parts'] as List)
          .firstWhere((part) => part['type'] == 'text')['content'],
      'Hello world',
    );
    expect(spy.ends, hasLength(1));
    expect(p.getState().done, isTrue);
  });

  test('does not fire onStreamEnd on a sequential tool_calls terminal', () {
    final spy = Spy();
    final p = processor(spy);
    p.processChunk(runStarted('run-1'));
    p.processChunk(textStart('msg-1'));
    p.processChunk(textContent('calling', 'msg-1'));
    p.processChunk(runFinished('tool_calls', 'run-1'));
    expect(spy.ends, isEmpty);
    expect(p.getState().done, isFalse);
    p.processChunk(runStarted('run-2'));
    p.processChunk(textContent(' done', 'msg-1'));
    p.processChunk(runFinished('stop', 'run-2'));
    expect(spy.ends, hasLength(1));
    expect(p.getState().done, isTrue);
  });

  test('single run should finalize normally (backward compat)', () {
    final spy = Spy();
    final p = processor(spy);
    p.prepareAssistantMessage();
    p.processChunk(runStarted());
    p.processChunk(textStart());
    p.processChunk(textContent('Hello'));
    p.processChunk(textEnd());
    p.processChunk(runFinished());
    expect(spy.ends, hasLength(1));
    expect(p.getState().done, isTrue);
  });

  test(
      'tool calls in one run should not be force-completed when another run finishes',
      () {
    final p = processor();
    p.processChunk(runStarted('run-a'));
    p.processChunk(textStart('msg-a'));
    p.processChunk(toolStart('tc-a', 'toolA'));
    p.processChunk(toolArgs('tc-a', '{"q":'));
    p.processChunk(runStarted('run-b'));
    p.processChunk(textStart('msg-b'));
    p.processChunk(textContent('B done', 'msg-b'));
    p.processChunk(runFinished('stop', 'run-b'));
    expect(p.getState().toolCalls['tc-a']!.state, 'input-streaming');
    p.processChunk(toolArgs('tc-a', '"val"}'));
    p.processChunk(toolEnd('tc-a'));
    p.processChunk(runFinished('tool_calls', 'run-a'));
    expect(p.getState().toolCalls['tc-a']!.state, 'input-complete');
    expect(p.getState().done, isFalse);
    p.finalizeStream();
    expect(p.getState().done, isTrue);
  });

  test(
      'should handle MESSAGES_SNAPSHOT followed by content for existing message',
      () {
    final p = processor();
    p.processChunk(chunk('MESSAGES_SNAPSHOT', {
      'messages': [
        {
          'id': 'user-1',
          'role': 'user',
          'parts': [
            {'type': 'text', 'content': 'Tell me a story'},
          ],
        },
        {
          'id': 'asst-1',
          'role': 'assistant',
          'parts': [
            {'type': 'text', 'content': 'Once upon a '},
          ],
        },
      ],
    }));
    p.processChunk(textContent('time...', 'asst-1'));
    p.processChunk(runFinished());
    p.finalizeStream();
    expect(p.getMessages(), hasLength(2));
    expect(
      (p.getMessages()[1]['parts'] as List).single['content'],
      'Once upon a time...',
    );
  });

  test('keeps a sender name and metadata that arrives on a later chunk', () {
    final p = processor();
    p.processChunk(runStarted());
    p.processChunk(textChunk({
      'messageId': 'msg-1',
      'delta': 'hi',
      'name': 'Ada',
    }));
    p.processChunk(chunk('TEXT_MESSAGE_CHUNK', {'delta': ' there'}));
    p.processChunk(runFinished());
    expect(p.getMessages().single['name'], 'Ada');

    final tools = processor();
    tools.processChunk(runStarted());
    tools.processChunk(chunk('TOOL_CALL_CHUNK', {
      'toolCallId': 'tc-1',
      'toolCallName': 'lookup',
      'delta': '{',
    }));
    tools.processChunk(chunk('TOOL_CALL_CHUNK', {
      'delta': '}',
      'metadata': {'thoughtSignature': 'sig-2'},
    }));
    tools.processChunk(runFinished());
    expect(
      partById(tools, 'tc-1')!['metadata'],
      {'thoughtSignature': 'sig-2'},
    );

    final reasoning = processor();
    reasoning.processChunk(runStarted());
    reasoning.processChunk(chunk('REASONING_MESSAGE_CHUNK', {
      'messageId': 'r-1',
      'delta': 'think',
      'metadata': {'note': 'r'},
    }));
    reasoning.processChunk(runFinished());
    expect(reasoning.getMessages().single['metadata'], {
      'note': 'r',
      'tanstack': {'finishReason': 'stop'},
    });
  });

  for (final entry in <(String, Map<String, dynamic>)>[
    ('RAW', chunk('RAW', {'event': <String, dynamic>{}})),
    (
      'ACTIVITY_SNAPSHOT',
      chunk('ACTIVITY_SNAPSHOT', {
        'messageId': 'activity-1',
        'activityType': 'progress',
        'content': <String, dynamic>{},
      }),
    ),
    (
      'ACTIVITY_DELTA',
      chunk('ACTIVITY_DELTA', {
        'messageId': 'activity-1',
        'activityType': 'progress',
        'patch': <dynamic>[],
      }),
    ),
    (
      'REASONING_ENCRYPTED_VALUE',
      chunk('REASONING_ENCRYPTED_VALUE', {
        'subtype': 'message',
        'entityId': 'r-1',
        'encryptedValue': 'enc',
      }),
    ),
    (
      'SUBAGENT_STARTED',
      chunk('SUBAGENT_STARTED', {'subagentRunId': 'sub-1', 'name': 'a'}),
    ),
    (
      'SUBAGENT_FINISHED',
      chunk('SUBAGENT_FINISHED', {'subagentRunId': 'sub-1'}),
    ),
    (
      'SUBAGENT_ERROR',
      chunk('SUBAGENT_ERROR', {
        'subagentRunId': 'sub-1',
        'message': 'x',
      }),
    ),
  ]) {
    test('keeps the stream open across ${entry.$1}', () {
      final subagent =
          entry.$1 == 'SUBAGENT_FINISHED' || entry.$1 == 'SUBAGENT_ERROR'
              ? <Map<String, dynamic>>[
                  chunk('SUBAGENT_STARTED', {
                    'subagentRunId': 'sub-1',
                    'name': 'a',
                  }),
                ]
              : <Map<String, dynamic>>[];
      final chunked = processor();
      for (final event in [
        runStarted(),
        textChunk({'messageId': 'msg-1', 'delta': 'Hello, '}),
        ...subagent,
        entry.$2,
        chunk('TEXT_MESSAGE_CHUNK', {'delta': 'world'}),
        runFinished(),
      ]) {
        chunked.processChunk(event);
      }
      final expanded = processor();
      for (final event in [
        runStarted(),
        textStart('msg-1'),
        textContent('Hello, ', 'msg-1'),
        ...subagent,
        entry.$2,
        textContent('world', 'msg-1'),
        textEnd('msg-1'),
        runFinished(),
      ]) {
        expanded.processChunk(event);
      }
      expect(
        chunked.getMessages().map((message) => message['parts']).toList(),
        expanded.getMessages().map((message) => message['parts']).toList(),
      );
    });
  }

  test('closes the open stream when it drops an id-less chunk of another kind',
      () {
    final warnings = capturedWarnings(() {
      final p = processor();
      p.processChunk(runStarted());
      p.processChunk(chunk('TOOL_CALL_CHUNK', {
        'toolCallId': 'tc-1',
        'toolCallName': 'lookup',
        'delta': '{"a":1}',
      }));
      p.processChunk(chunk('TEXT_MESSAGE_CHUNK', {'delta': 'orphan'}));
      p.processChunk(chunk('TOOL_CALL_CHUNK', {'delta': '{"b":2}'}));
      p.processChunk(runFinished());
      final call = partById(p, 'tc-1')!;
      expect(call['arguments'], '{"a":1}');
    });
    expect(warnings, hasLength(2));
  });

  for (final reset in [
    'clearMessages',
    'prepareAssistantMessage',
    'finalizeStream'
  ]) {
    test('does not continue a stream after $reset()', () {
      final warnings = capturedWarnings(() {
        final p = processor();
        p.processChunk(textChunk({'messageId': 'msg-1', 'delta': 'old'}));
        switch (reset) {
          case 'clearMessages':
            p.clearMessages();
            break;
          case 'prepareAssistantMessage':
            p.prepareAssistantMessage();
            break;
          default:
            p.finalizeStream();
        }
        p.processChunk(chunk('TEXT_MESSAGE_CHUNK', {'delta': 'new'}));
        expect(
          p.getMessages().any(
                (message) => (message['parts'] as List).any(
                  (part) => part is Map && part['content'] == 'new',
                ),
              ),
          isFalse,
        );
      });
      expect(warnings, hasLength(1));
    });
  }

  test('replace: false still creates when the id does not exist', () {
    final p = processor();
    p.processChunk(chunk('ACTIVITY_SNAPSHOT', {
      'messageId': 'act-1',
      'activityType': 'PLAN',
      'content': {'steps': <dynamic>[]},
      'replace': false,
    }));
    expect(p.getMessages(), hasLength(1));
    expect(p.getMessages().single['role'], 'activity');
  });

  test('delta on a non-activity id warns and no-ops', () {
    final warnings = capturedWarnings(() {
      final p = processor();
      p.processChunk(textStart('msg-1'));
      p.processChunk(textContent('hello', 'msg-1'));
      p.processChunk(chunk('ACTIVITY_DELTA', {
        'messageId': 'msg-1',
        'activityType': 'SEARCH',
        'patch': [
          {'op': 'add', 'path': '/x', 'value': 1},
        ],
      }));
      expect(p.getMessages(), hasLength(1));
      expect(p.getMessages().single['role'], 'assistant');
    });
    expect(warnings, isNotEmpty);
  });

  for (final invalid in <dynamic>[null, 'unknown', 42]) {
    test('should ignore invalid tool result outcomes: ${invalid ?? 'null'}',
        () {
      final p = processor();
      p.processChunk(toolStart('tc-1', 'get_weather'));
      p.processChunk(toolEnd('tc-1'));
      p.processChunk({
        ...toolResult('tc-1', '{"ok":true}'),
        'metadata': {
          'tanstack': {'toolResultOutcome': invalid},
        },
      });
      final result =
          partsOf(p).firstWhere((part) => part['type'] == 'tool-result');
      expect(result['state'], 'complete');
      expect(result.containsKey('outcome'), isFalse);
    });
  }

  test('should mark a valid outcome as an error without output-error metadata',
      () {
    final p = processor();
    p.processChunk(toolStart('tc-1', 'get_weather'));
    p.processChunk(toolArgs('tc-1', '{}'));
    p.processChunk(toolEnd('tc-1'));
    p.processChunk({
      ...toolResult('tc-1', '{"error":"User declined tool execution"}'),
      'metadata': {
        'tanstack': {'toolResultOutcome': 'denied'},
      },
    });
    final result =
        partsOf(p).firstWhere((part) => part['type'] == 'tool-result');
    expect(result['state'], 'error');
    expect(result['outcome'], 'denied');
  });

  test(
      'keeps deltas in the structured-output part when reasoning streamed first under its own messageId (#1632)',
      () {
    final p = processor();
    p.processChunk(runStarted());
    p.processChunk(stepStarted());
    p.processChunk(reasoningContent('hm', 'reason-1'));
    p.processChunk(custom('structured-output.start', {'messageId': 'msg-1'}));
    p.processChunk(textStart('msg-1'));
    p.processChunk(textContent('{"a":', 'msg-1'));
    p.processChunk(textContent('1}', 'msg-1'));
    p.processChunk(textEnd('msg-1'));
    p.processChunk(custom('structured-output.complete', {
      'object': {'a': 1},
      'raw': '{"a":1}',
      'messageId': 'msg-1',
    }));
    p.processChunk(runFinished());
    expect(p.getMessages(), hasLength(1));
    expect(
      (p.getMessages().single['parts'] as List)
          .map((part) => part['type'])
          .toList(),
      ['thinking', 'structured-output'],
    );
  });

  test(
      'keeps a queued structured-output update when the placeholder gets its real id',
      () {
    final updates = <String>[];
    final p = StreamProcessor(StreamProcessorOptions(
      events: StreamProcessorEvents(
        onStructuredOutputChange: (args) {
          if (args['phase'] == 'update') {
            updates.add((args['delta'] as String?) ?? '');
          }
        },
      ),
    ));
    p.processChunk(runStarted());
    p.processChunk(reasoningContent('hm', 'reason-1'));
    p.processChunk(custom('structured-output.start', {'messageId': 'msg-1'}));
    p.processChunk(textContent('{"a":', 'msg-1'));
    p.processChunk(textStart('msg-1'));
    p.processChunk(textContent('1}', 'msg-1'));
    p.processChunk(custom('structured-output.complete', {
      'object': {'a': 1},
      'raw': '{"a":1}',
      'messageId': 'msg-1',
    }));
    expect(updates.join(), '{"a":1}');
  });

  test(
      'attaches a late structured-output.complete to the open assistant when the event uses a new messageId',
      () {
    final p = processor();
    final report = {
      'name': 'TanStack AI',
      'oneLiner': 'Type-safe AI SDK',
    };
    p.processChunk(runStarted());
    p.processChunk(toolStart('toolu_1', 'Read'));
    p.processChunk(toolEnd('toolu_1'));
    p.processChunk(textStart('msg-1'));
    p.processChunk(
        textContent('I have enough to produce the report.', 'msg-1'));
    p.processChunk(textEnd('msg-1'));
    p.processChunk(
        custom('structured-output.start', {'messageId': 'so-fresh-id'}));
    p.processChunk(custom('structured-output.complete', {
      'object': report,
      'raw': jsonEncode(report),
      'messageId': 'so-fresh-id',
    }));
    p.processChunk(runFinished());
    final assistants = p
        .getMessages()
        .where((message) => message['role'] == 'assistant')
        .toList();
    expect(assistants, hasLength(1));
    final sop = (assistants.single['parts'] as List)
        .firstWhere((part) => part['type'] == 'structured-output');
    expect(sop['status'], 'complete');
    expect(sop['data'], report);
  });

  test(
      'reconciles cumulative TEXT_MESSAGE_CONTENT against existing raw without duplication',
      () {
    final p = processor();
    p.processChunk(runStarted());
    p.processChunk(textStart('msg-1'));
    p.processChunk(custom('structured-output.start', {'messageId': 'msg-1'}));
    p.processChunk(textContent('{"name":', 'msg-1'));
    p.processChunk(textContent('"Alice"}', 'msg-1'));
    final sop = partsOf(p).firstWhere(
      (part) => part['type'] == 'structured-output',
    );
    expect(sop['raw'], '{"name":"Alice"}');
  });
}
