// Upstream reference: packages/ai-client/tests/cleared-stream-tracker.test.ts
import 'package:tanstack_ai_dart/chat.dart';
import 'package:test/test.dart';

void main() {
  group('ClearedStreamTracker', () {
    final runlessChunks = <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'TEXT_MESSAGE_START',
        'messageId': 'late-msg',
        'role': 'assistant',
      },
      <String, dynamic>{
        'type': 'TEXT_MESSAGE_CHUNK',
        'messageId': 'late-msg',
        'delta': 'hi',
      },
      <String, dynamic>{
        'type': 'TOOL_CALL_CHUNK',
        'toolCallId': 'tc-late',
        'toolCallName': 'x',
      },
    ];

    for (final chunk in runlessChunks) {
      test('ignores a runless ${chunk['type']} from a run cleared mid-stream',
          () {
        final tracker = ClearedStreamTracker();
        tracker.onRunStarted('run-1');
        tracker.snapshotClear(
          messages: const <AssistantTurn>[],
          activeRunIds: <String>{'run-1'},
          currentRunId: 'run-1',
        );

        expect(tracker.shouldIgnoreChunk(chunk), isTrue);
      });
    }

    test('ignores chunks carrying a cleared run id', () {
      final tracker = ClearedStreamTracker();
      tracker.snapshotClear(
        messages: const <AssistantTurn>[],
        activeRunIds: <String>{'run-1'},
      );
      expect(
        tracker.shouldIgnoreChunk(<String, dynamic>{
          'type': 'TEXT_MESSAGE_CONTENT',
          'runId': 'run-1',
          'messageId': 'm',
          'delta': 'x',
        }),
        isTrue,
      );
    });

    test('marks tool calls cleared through a parent message id', () {
      final tracker = ClearedStreamTracker();
      tracker.snapshotClear(
        messages: <AssistantTurn>[
          AssistantTurn(id: 'parent', role: 'assistant'),
        ],
      );
      final chunk = <String, dynamic>{
        'type': 'TOOL_CALL_START',
        'toolCallId': 'tc-1',
        'parentMessageId': 'parent',
      };
      expect(tracker.shouldIgnoreChunk(chunk), isTrue);
      expect(
        tracker.shouldIgnoreChunk(<String, dynamic>{
          'type': 'TOOL_CALL_ARGS',
          'toolCallId': 'tc-1',
          'delta': '{}',
        }),
        isTrue,
      );
    });

    test('onRunSettled stops ignoring and takeRunlessRunId releases ownership',
        () {
      final tracker = ClearedStreamTracker();
      tracker.onRunStarted('run-1');
      tracker.snapshotClear(
        messages: const <AssistantTurn>[],
        activeRunIds: <String>{'run-1'},
        currentRunId: 'run-1',
      );
      expect(
        tracker.shouldIgnoreChunk(<String, dynamic>{
          'type': 'TEXT_MESSAGE_CHUNK',
          'messageId': 'm',
          'delta': 'x',
        }),
        isTrue,
      );
      tracker.onRunSettled('run-1');
      expect(
        tracker.shouldIgnoreChunk(<String, dynamic>{
          'type': 'TEXT_MESSAGE_CHUNK',
          'messageId': 'fresh',
          'delta': 'x',
        }),
        isFalse,
      );
      expect(tracker.takeRunlessRunId(), isNull);
    });

    test('resetActiveRuns and onSessionRunError clear run ownership', () {
      final tracker = ClearedStreamTracker();
      tracker.onRunStarted('run-1');
      tracker.snapshotClear(
        messages: const <AssistantTurn>[],
        activeRunIds: <String>{'run-1'},
      );
      tracker.onSessionRunError();
      expect(
        tracker.shouldIgnoreChunk(<String, dynamic>{
          'type': 'TEXT_MESSAGE_CHUNK',
          'messageId': 'm',
          'delta': 'x',
        }),
        isFalse,
      );
      tracker.resetActiveRuns();
    });
  });
}
