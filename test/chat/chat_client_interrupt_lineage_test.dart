// Upstream reference: packages/ai-client/tests/chat-client-interrupt-lineage-replay.test.ts
// and chat-client-interrupt-correlation.test.ts
import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/connections.dart' as conn;
import 'package:test/test.dart';

import 'support.dart';

Map<String, dynamic> runStarted(
  String runId, [
  String threadId = 'thread-1',
  String? parentRunId,
]) =>
    <String, dynamic>{
      'type': 'RUN_STARTED',
      'runId': runId,
      'threadId': threadId,
      if (parentRunId != null) 'parentRunId': parentRunId,
    };

Map<String, dynamic> runFinishedSuccess(
  String runId, [
  String threadId = 'thread-1',
]) =>
    <String, dynamic>{
      'type': 'RUN_FINISHED',
      'runId': runId,
      'threadId': threadId,
      'outcome': <String, dynamic>{'type': 'success'},
    };

Map<String, dynamic> runFinishedInterrupt(
  String runId, [
  String threadId = 'thread-1',
]) =>
    <String, dynamic>{
      'type': 'RUN_FINISHED',
      'runId': runId,
      'threadId': threadId,
      'outcome': <String, dynamic>{
        'type': 'interrupt',
        'interrupts': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'i-$runId',
            'reason': 'approval_required',
            'metadata': <String, dynamic>{
              'kind': 'approval',
              'toolName': 'confirm',
              'input': <String, dynamic>{},
            },
          },
        ],
      },
    };

class ReplayClient {
  final ChatClient client;
  final void Function(Map<String, dynamic>) publish;

  ReplayClient(this.client, this.publish);
}

ReplayClient replayClient({
  ChatPersistence? persistence,
  Stream<Map<String, dynamic>> Function(String runId,
          {conn.CancellationSignal? signal})?
      joinRun,
}) {
  final controller = StreamController<Map<String, dynamic>>.broadcast();
  final connection = conn.ConnectionAdapter(
    subscribe: ({signal}) => controller.stream,
    send: (messages, {data, signal, runContext}) async {},
    joinRun: joinRun,
    hydrate: (threadId, {options}) async =>
        const conn.ChatHydrationResult(messages: <conn.WireMessage>[]),
  );
  final client = ChatClient(
    connection: connection,
    options: ChatClientOptions(
      threadId: 'thread-1',
      persistence: persistence,
    ),
  );
  client.subscribe();
  return ReplayClient(client, (chunk) {
    controller.add(chunk);
  });
}

Future<void> publishAndSettle(
  ReplayClient replay,
  Map<String, dynamic> chunk,
) async {
  replay.publish(chunk);
  await pump(8);
}

void main() {
  group('ChatClient interrupt lineage on replay (#1368)', () {
    final cases = <String, List<Map<String, dynamic>>>{
      'does not rejoin a completed child after its late parent link':
          <Map<String, dynamic>>[
        runFinishedSuccess('run-B'),
        runStarted('run-B', 'thread-1', 'run-A'),
        runFinishedInterrupt('run-A'),
      ],
      'clears a persisted parent pause after its late link':
          <Map<String, dynamic>>[
        runStarted('run-A'),
        runFinishedInterrupt('run-A'),
        runFinishedSuccess('run-B'),
        runStarted('run-B', 'thread-1', 'run-A'),
      ],
      'preserves an unrelated persisted pause after a late link':
          <Map<String, dynamic>>[
        runStarted('run-D'),
        runFinishedInterrupt('run-D'),
        runFinishedSuccess('run-B'),
        runStarted('run-B', 'thread-1', 'run-A'),
      ],
    };

    for (final entry in cases.entries) {
      test(entry.key, () async {
        final replay = replayClient();
        try {
          for (final chunk in entry.value) {
            await publishAndSettle(replay, chunk);
          }
          final expected = entry.key.contains('unrelated') ? 1 : 0;
          expect(replay.client.getInterrupts(), hasLength(expected));
          expect(replay.client.getSessionGenerating(), isFalse);
        } finally {
          await replay.client.dispose();
        }
      });
    }

    final progressCases =
        <String, ({List<Map<String, dynamic>> chunks, List<int> expected})>{
      'suppresses a stale pause after a completed child gains its parent link':
          (
        chunks: <Map<String, dynamic>>[
          runFinishedSuccess('run-B'),
          runStarted('run-B', 'thread-1', 'run-A'),
          runFinishedInterrupt('run-A'),
        ],
        expected: <int>[0, 0, 0],
      ),
      'clears a visible pause when a completed child gains its parent link': (
        chunks: <Map<String, dynamic>>[
          runStarted('run-A'),
          runFinishedInterrupt('run-A'),
          runFinishedSuccess('run-B'),
          runStarted('run-B', 'thread-1', 'run-A'),
        ],
        expected: <int>[0, 1, 1, 0],
      ),
      'propagates completion through late transitive parent links': (
        chunks: <Map<String, dynamic>>[
          runFinishedSuccess('run-C'),
          runStarted('run-C', 'thread-1', 'run-B'),
          runFinishedInterrupt('run-A'),
          runStarted('run-B', 'thread-1', 'run-A'),
        ],
        expected: <int>[0, 0, 1, 0],
      ),
    };

    for (final entry in progressCases.entries) {
      test(entry.key, () async {
        final replay = replayClient();
        try {
          for (var i = 0; i < entry.value.chunks.length; i++) {
            await publishAndSettle(replay, entry.value.chunks[i]);
            expect(
              replay.client.getInterrupts(),
              hasLength(entry.value.expected[i]),
            );
          }
          expect(replay.client.getResumeState(), isNull);
          expect(replay.client.getSessionGenerating(), isFalse);
        } finally {
          await replay.client.dispose();
        }
      });
    }

    test(
        'does not treat a late RUN_STARTED for an already-finished child as live generation',
        () async {
      final replay = replayClient();
      try {
        await publishAndSettle(replay, runFinishedSuccess('run-B'));
        await publishAndSettle(
          replay,
          runStarted('run-B', 'thread-1', 'run-A'),
        );
        expect(replay.client.getSessionGenerating(), isFalse);
        await publishAndSettle(replay, runStarted('run-C'));
        expect(replay.client.getSessionGenerating(), isTrue);
        await publishAndSettle(replay, runFinishedSuccess('run-C'));
        expect(replay.client.getSessionGenerating(), isFalse);
      } finally {
        await replay.client.dispose();
      }
    });

    test(
        'clears a resolved interrupt once its continuation run finishes, surviving a re-emitted stale pause',
        () async {
      final replay = replayClient();
      try {
        await publishAndSettle(replay, runStarted('run-A'));
        expect(replay.client.getInterrupts(), isEmpty);
        await publishAndSettle(replay, runFinishedInterrupt('run-A'));
        expect(replay.client.getInterrupts(), hasLength(1));
        await publishAndSettle(
          replay,
          runStarted('run-B', 'thread-1', 'run-A'),
        );
        expect(replay.client.getInterrupts(), hasLength(1));
        await publishAndSettle(replay, runFinishedInterrupt('run-A'));
        expect(replay.client.getInterrupts(), hasLength(1));
        await publishAndSettle(
          replay,
          runStarted('run-B', 'thread-1', 'run-A'),
        );
        expect(replay.client.getInterrupts(), hasLength(1));
        await publishAndSettle(replay, runFinishedSuccess('run-B'));
        expect(replay.client.getInterrupts(), isEmpty);
      } finally {
        await replay.client.dispose();
      }
    });

    test(
        'keeps a genuinely live interrupt pending when no continuation run exists',
        () async {
      final replay = replayClient();
      try {
        await publishAndSettle(replay, runStarted('run-A'));
        expect(replay.client.getInterrupts(), isEmpty);
        await publishAndSettle(replay, runFinishedInterrupt('run-A'));
        expect(replay.client.getInterrupts(), hasLength(1));
      } finally {
        await replay.client.dispose();
      }
    });

    test(
        'does not clear a pending interrupt when an unrelated run on the same thread finishes',
        () async {
      final replay = replayClient();
      try {
        await publishAndSettle(replay, runStarted('run-A'));
        await publishAndSettle(replay, runFinishedInterrupt('run-A'));
        expect(replay.client.getInterrupts(), hasLength(1));
        await publishAndSettle(replay, runStarted('run-C'));
        await publishAndSettle(replay, runFinishedSuccess('run-C'));
        expect(replay.client.getInterrupts(), hasLength(1));
      } finally {
        await replay.client.dispose();
      }
    });

    test(
        'stays cleared across a second full replay of the same history (idempotent, out-of-order safe)',
        () async {
      final replay = replayClient();
      try {
        final sequence = <Map<String, dynamic>>[
          runStarted('run-A'),
          runFinishedInterrupt('run-A'),
          runStarted('run-B', 'thread-1', 'run-A'),
          runFinishedSuccess('run-B'),
        ];
        for (final chunk in sequence) {
          await publishAndSettle(replay, chunk);
        }
        expect(replay.client.getInterrupts(), isEmpty);
        for (final chunk in sequence) {
          await publishAndSettle(replay, chunk);
          expect(replay.client.getInterrupts(), isEmpty);
        }
      } finally {
        await replay.client.dispose();
      }
    });
  });

  group('ChatClient interrupt error correlation', () {
    test(
        'does not apply a foreign shared RUN_ERROR to a local interrupt submission',
        () async {
      final replay = replayClient();
      try {
        await publishAndSettle(replay, runStarted('run-A'));
        await publishAndSettle(replay, runFinishedInterrupt('run-A'));
        expect(replay.client.getInterrupts(), hasLength(1));
        await publishAndSettle(
          replay,
          <String, dynamic>{
            'type': 'RUN_ERROR',
            'runId': 'foreign',
            'threadId': 'thread-1',
            'message': 'foreign failure',
          },
        );
        expect(replay.client.getInterrupts(), hasLength(1));
        expect(replay.client.getError(), isNull);
      } finally {
        await replay.client.dispose();
      }
    });
  });
}
