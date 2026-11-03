import 'dart:async';
import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';
import 'package:test/test.dart';

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 300; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition did not settle');
}

void main() {
  for (final failure in ['transport', 'server']) {
    test('client retries the original interrupt batch after $failure failure',
        () async {
      final requests = <RunAgentInputContext>[];
      final client = ChatClient(
        threadId: 'thread-1',
        initialResumeSnapshot: ChatResumeSnapshot(
          resumeState:
              const ChatResumeState(threadId: 'thread-1', runId: 'parent'),
          pendingInterrupts: [
            {
              'id': 'i1',
              'reason': 'confirmation',
              'metadata': {
                'tanstack:interruptBinding': {
                  'v': 1,
                  'kind': 'generic',
                  'interruptId': 'i1',
                  'interruptedRunId': 'parent',
                  'generation': 1,
                  'responseSchemaHash': 'none',
                }
              }
            }
          ],
        ),
        connection:
            ConnectionAdapter(connect: (_, {data, signal, runContext}) async* {
          requests.add(runContext!);
          if (requests.length == 1) {
            if (failure == 'transport') throw StateError('offline');
            yield {
              'type': 'RUN_ERROR',
              'runId': runContext.runId,
              'threadId': 'thread-1',
              'message': 'retry later',
              'metadata': {
                'tanstack': {
                  'interruptErrors': [
                    {
                      'scope': 'batch',
                      'code': 'server',
                      'message': 'retry later',
                      'source': 'server',
                      'retryable': true,
                      'interruptIds': ['i1'],
                      'threadId': 'thread-1',
                      'interruptedRunId': 'parent',
                      'generation': 1,
                    }
                  ]
                }
              }
            };
            return;
          }
          yield {
            'type': 'RUN_FINISHED',
            'runId': runContext.runId,
            'threadId': 'thread-1',
            'outcome': {'type': 'success'}
          };
        }),
      );
      addTearDown(client.dispose);
      client.resolveInterrupts((ChatInterrupt item) {
        item.cancel();
        return null;
      });
      await until(() => client.getInterruptState().interruptErrors.isNotEmpty);
      expect(client.getResumeState()?.runId, 'parent');
      expect(
          client.getInterruptState().interruptErrors.single['code'], failure);
      client.retryInterrupts();
      await until(() => requests.length == 2 && !client.getIsLoading());
      expect(requests[1].resume, requests[0].resume);
      expect(requests[1].parentRunId, 'parent');
      expect(requests[1].runId, isNot(requests[0].runId));
      expect(client.getInterrupts(), isEmpty);
      expect(client.getResumeState(), isNull);
    });
  }
}
