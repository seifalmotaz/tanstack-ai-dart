// Ported from
// packages/ai-client/tests/connection-adapters-resumable.test.ts
// Test names and groups intentionally mirror the upstream file.
import 'package:tanstack_ai_dart/connections.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

String contentEvent(String id, String delta) =>
    sseEvent(contentChunk(delta), id: id);

String finishedEvent(String id) =>
    sseEvent(finishedChunk(threadId: 't', runId: 'r'), id: id);

String emptyIdEvent(String delta) => 'id:\n${sseData(
      '{"type":"TEXT_MESSAGE_CONTENT","messageId":"m","model":"test",'
      '"timestamp":0,"delta":"$delta","content":"$delta"}',
    )}';

void main() {
  group('resumable SSE connection adapter', () {
    test('reconnects with Last-Event-ID and de-dupes already-seen chunks',
        () async {
      late FakeHttpClient client;
      client = FakeHttpClient((request) async {
        expect(request.url.toString(), '/api/chat');
        expect(request.headers['X-Run-Id'], 'r');
        if (client.requests.length == 1) {
          return rawResponse(
            contentEvent('run@1', '1') +
                contentEvent('run@2', '2') +
                contentEvent('run@3', '3'),
          );
        }
        expect(request.headers['Last-Event-ID'], 'run@3');
        return rawResponse(
          contentEvent('run@3', '3') +
              contentEvent('run@4', '4') +
              finishedEvent('run@5'),
        );
      });

      final adapter = fetchServerSentEvents(
        '/api/chat',
        FetchConnectionOptions(
          client: client,
          reconnect: const ReconnectOptions(delay: Duration.zero),
        ),
      );

      final chunks = await collect(
        adapter.connect!(
          [
            {'role': 'user', 'content': 'hi'},
          ],
          runContext: const RunAgentInputContext(threadId: 't', runId: 'r'),
        ),
      );

      expect(deltasOf(chunks), ['1', '2', '3', '4']);
      expect(chunks.last['type'], 'RUN_FINISHED');
      expect(client.requests, hasLength(2));
    });

    test('leaves the request URL untouched and sends the run id as a header',
        () async {
      final client = FakeHttpClient(
        (_) async => rawResponse(finishedEvent('run@1')),
      );
      final adapter = fetchServerSentEvents(
        '/api/chat?provider=openai&runId=stale#response',
        FetchConnectionOptions(client: client),
      );

      await collect(
        adapter.connect!(
          [
            {'role': 'user', 'content': 'hi'},
          ],
          runContext:
              const RunAgentInputContext(threadId: 't', runId: 'current'),
        ),
      );

      expect(
        client.requests.single.url.toString(),
        '/api/chat?provider=openai&runId=stale#response',
      );
      expect(client.requests.single.headers['X-Run-Id'], 'current');
    });

    test('joinRun opens the stream from the start with ?offset=-1', () async {
      final client = FakeHttpClient(
        (_) async => rawResponse(finishedEvent('run@1')),
      );
      final adapter = fetchServerSentEvents(
        '/api/chat',
        FetchConnectionOptions(
          client: client,
          reconnect: const ReconnectOptions(delay: Duration.zero),
        ),
      );

      final chunks = await collect(adapter.joinRun!('run-x'));

      final calledUrl = client.requests.single.url;
      expect(calledUrl.queryParameters['offset'], '-1');
      expect(calledUrl.queryParameters['runId'], 'run-x');
      expect(chunks.map((chunk) => chunk['type']), contains('RUN_FINISHED'));
    });

    test(
        'surfaces an error when a durable run ends without a terminal and '
        'cannot progress', () async {
      late FakeHttpClient client;
      client = FakeHttpClient((_) async {
        if (client.requests.length == 1) {
          return rawResponse(
            contentEvent('run@1', '1') + contentEvent('run@2', '2'),
          );
        }
        return rawResponse('');
      });

      final adapter = fetchServerSentEvents(
        '/api/chat',
        FetchConnectionOptions(
          client: client,
          reconnect: const ReconnectOptions(delay: Duration.zero),
        ),
      );

      final deltas = <String>[];
      final error = await captureError(() async {
        await for (final chunk in adapter.connect!(
          [
            {'role': 'user', 'content': 'hi'},
          ],
          runContext: const RunAgentInputContext(threadId: 't', runId: 'r'),
        )) {
          if (chunk['type'] == 'TEXT_MESSAGE_CONTENT') {
            deltas.add(chunk['delta'] as String);
          }
        }
        return null;
      });

      expect(error, isA<DurableStreamIncompleteError>());
      expect(deltas, ['1', '2']);
      expect(client.requests, hasLength(2));
    });

    test('reconnects after a body reader failure and resumes exactly once',
        () async {
      late FakeHttpClient client;
      client = FakeHttpClient((request) async {
        if (client.requests.length == 1) {
          return failingResponse(
            contentEvent('run@1', '1'),
            StateError('socket disconnected'),
          );
        }
        expect(request.headers['Last-Event-ID'], 'run@1');
        return rawResponse(
          contentEvent('run@1', '1') +
              contentEvent('run@2', '2') +
              finishedEvent('run@3'),
        );
      });
      final adapter = fetchServerSentEvents(
        '/api/chat',
        FetchConnectionOptions(
          client: client,
          reconnect: const ReconnectOptions(delay: Duration.zero),
        ),
      );

      final chunks = await collect(
        adapter.connect!(
          [
            {'role': 'user', 'content': 'hi'},
          ],
          runContext: const RunAgentInputContext(threadId: 't', runId: 'r'),
        ),
      );

      expect(deltasOf(chunks), ['1', '2']);
      expect(client.requests, hasLength(2));
    });

    test(
        'retries a reconnect whose fetch() itself rejects '
        '(connection-establishment failure)', () async {
      late FakeHttpClient client;
      client = FakeHttpClient((_) async {
        if (client.requests.length == 1) {
          return rawResponse(contentEvent('run@1', '1'));
        }
        if (client.requests.length == 2) {
          throw StateError('Failed to fetch');
        }
        return rawResponse(
          contentEvent('run@2', '2') + finishedEvent('run@3'),
        );
      });
      final adapter = fetchServerSentEvents(
        '/api/chat',
        FetchConnectionOptions(
          client: client,
          reconnect: const ReconnectOptions(delay: Duration.zero),
        ),
      );

      final chunks = await collect(
        adapter.connect!(
          [
            {'role': 'user', 'content': 'hi'},
          ],
          runContext: const RunAgentInputContext(threadId: 't', runId: 'r'),
        ),
      );

      expect(deltasOf(chunks), ['1', '2']);
      expect(chunks.last['type'], 'RUN_FINISHED');
      expect(client.requests, hasLength(3));
    });

    test(
        'surfaces a first-attempt fetch() rejection (no offset held) as a '
        'hard failure', () async {
      final client = FakeHttpClient((_) async {
        throw StateError('Failed to fetch');
      });
      final adapter = fetchServerSentEvents(
        '/api/chat',
        FetchConnectionOptions(
          client: client,
          reconnect: const ReconnectOptions(delay: Duration.zero),
        ),
      );

      await expectLater(
        collect(adapter.connect!(
          [
            {'role': 'user', 'content': 'hi'},
          ],
          runContext: const RunAgentInputContext(threadId: 't', runId: 'r'),
        )),
        throwsA(isA<StreamReadError>()),
      );
      expect(client.requests, hasLength(1));
    });

    test(
        'retries a transport drop that replayed only the de-duped overlap '
        '(no new progress that attempt)', () async {
      late FakeHttpClient client;
      client = FakeHttpClient((_) async {
        if (client.requests.length == 1) {
          return failingResponse(
            contentEvent('run@1', '1'),
            StateError('socket disconnected'),
          );
        }
        if (client.requests.length == 2) {
          return failingResponse(
            contentEvent('run@1', '1'),
            StateError('socket disconnected again'),
          );
        }
        return rawResponse(
          contentEvent('run@1', '1') +
              contentEvent('run@2', '2') +
              finishedEvent('run@3'),
        );
      });
      final adapter = fetchServerSentEvents(
        '/api/chat',
        FetchConnectionOptions(
          client: client,
          reconnect: const ReconnectOptions(delay: Duration.zero),
        ),
      );

      final chunks = await collect(
        adapter.connect!(
          [
            {'role': 'user', 'content': 'hi'},
          ],
          runContext: const RunAgentInputContext(threadId: 't', runId: 'r'),
        ),
      );

      expect(deltasOf(chunks), ['1', '2']);
      expect(chunks.last['type'], 'RUN_FINISHED');
      expect(client.requests, hasLength(3));
    });

    test('bounds reconnection with a consecutive-no-progress ceiling',
        () async {
      final client = FakeHttpClient(
        (_) async => failingResponse(
          contentEvent('run@1', 'x'),
          StateError('socket disconnected'),
        ),
      );
      final adapter = fetchServerSentEvents(
        '/api/chat',
        FetchConnectionOptions(
          client: client,
          reconnect: const ReconnectOptions(
            maxAttempts: 3,
            delay: Duration.zero,
          ),
        ),
      );

      await expectLater(
        collect(adapter.connect!(
          [
            {'role': 'user', 'content': 'hi'},
          ],
          runContext: const RunAgentInputContext(threadId: 't', runId: 'r'),
        )),
        throwsA(isA<StreamReconnectLimitError>()),
      );
      expect(client.requests, hasLength(5));
    });

    test('does not count progress-making reconnects toward the ceiling',
        () async {
      var pass = 0;
      final client = FakeHttpClient((_) async {
        pass += 1;
        if (pass <= 4) {
          return failingResponse(
            contentEvent('run@$pass', '$pass'),
            StateError('socket rolled'),
          );
        }
        return rawResponse(finishedEvent('run@final'));
      });
      final adapter = fetchServerSentEvents(
        '/api/chat',
        FetchConnectionOptions(
          client: client,
          reconnect: const ReconnectOptions(
            maxAttempts: 2,
            delay: Duration.zero,
          ),
        ),
      );

      final chunks = await collect(
        adapter.connect!(
          [
            {'role': 'user', 'content': 'hi'},
          ],
          runContext: const RunAgentInputContext(threadId: 't', runId: 'r'),
        ),
      );

      expect(deltasOf(chunks), ['1', '2', '3', '4']);
      expect(chunks.last['type'], 'RUN_FINISHED');
      expect(client.requests, hasLength(5));
    });

    test('rejects invalid reconnect bounds (negative maxAttempts / delay)',
        () async {
      final client = FakeHttpClient(
        (_) async => rawResponse(finishedEvent('run@1')),
      );
      for (final reconnect in [
        const ReconnectOptions(maxAttempts: -1),
        const ReconnectOptions(delay: Duration(milliseconds: -5)),
      ]) {
        final adapter = fetchServerSentEvents(
          '/api/chat',
          FetchConnectionOptions(client: client, reconnect: reconnect),
        );
        await expectLater(
          collect(adapter.connect!(
            [
              {'role': 'user', 'content': 'hi'},
            ],
            runContext: const RunAgentInputContext(threadId: 't', runId: 'r'),
          )),
          throwsA(isA<ArgumentError>()),
        );
      }
    });

    test('delivers an empty-id event and does not track "" as a durable offset',
        () async {
      final client = FakeHttpClient(
        (_) async => rawResponse(
          contentEvent('run@1', '1') +
              emptyIdEvent('2') +
              finishedEvent('run@3'),
        ),
      );
      final adapter = fetchServerSentEvents(
        '/api/chat',
        FetchConnectionOptions(client: client),
      );

      final chunks = await collect(
        adapter.connect!(
          [
            {'role': 'user', 'content': 'hi'},
          ],
          runContext: const RunAgentInputContext(threadId: 't', runId: 'r'),
        ),
      );

      expect(deltasOf(chunks), ['1', '2']);
      expect(chunks.last['type'], 'RUN_FINISHED');
      expect(client.requests, hasLength(1));
    });

    test('stops reconnecting promptly when aborted during the throttle delay',
        () async {
      final controller = CancellationController();
      var pass = 0;
      final client = FakeHttpClient((_) async {
        pass += 1;
        return rawResponse(contentEvent('run@$pass', 'x'));
      });
      final adapter = fetchServerSentEvents(
        '/api/chat',
        FetchConnectionOptions(
          client: client,
          signal: controller.signal,
          reconnect: const ReconnectOptions(
            delay: Duration(seconds: 10),
          ),
        ),
      );

      final chunks = <StreamChunk>[];
      final done = () async {
        await for (final chunk in adapter.connect!(
          [
            {'role': 'user', 'content': 'hi'},
          ],
          runContext: const RunAgentInputContext(threadId: 't', runId: 'r'),
        )) {
          chunks.add(chunk);
        }
      }();

      await Future<void>.delayed(const Duration(milliseconds: 20));
      controller.cancel();
      await done;

      expect(chunks, hasLength(1));
      expect(client.requests, hasLength(1));
    });

    test('does not reconnect a body reader after the caller aborts', () async {
      final controller = CancellationController();
      final client = FakeHttpClient(
        (_) async => failingResponse(
          contentEvent('run@1', '1'),
          StateError('socket disconnected'),
        ),
      );
      final adapter = fetchServerSentEvents(
        '/api/chat',
        FetchConnectionOptions(
          client: client,
          reconnect: const ReconnectOptions(delay: Duration.zero),
        ),
      );
      final chunks = <StreamChunk>[];

      await for (final chunk in adapter.connect!(
        [
          {'role': 'user', 'content': 'hi'},
        ],
        signal: controller.signal,
        runContext: const RunAgentInputContext(threadId: 't', runId: 'r'),
      )) {
        chunks.add(chunk);
        controller.cancel();
      }

      expect(chunks, hasLength(1));
      expect(client.requests, hasLength(1));
    });

    test('does not retry HTTP setup failures after earlier progress', () async {
      late FakeHttpClient client;
      client = FakeHttpClient((_) async {
        if (client.requests.length == 1) {
          return rawResponse(contentEvent('run@1', '1'));
        }
        return rawResponse(
          '',
          status: 503,
          reasonPhrase: 'Unavailable',
        );
      });
      final adapter = fetchServerSentEvents(
        '/api/chat',
        FetchConnectionOptions(
          client: client,
          reconnect: const ReconnectOptions(delay: Duration.zero),
        ),
      );

      await expectLater(
        collect(adapter.connect!(
          [
            {'role': 'user', 'content': 'hi'},
          ],
          runContext: const RunAgentInputContext(threadId: 't', runId: 'r'),
        )),
        throwsA(
          predicate<Object>(
            (error) => error.toString().contains('503 Unavailable'),
          ),
        ),
      );
      expect(client.requests, hasLength(2));
    });
  });

  group('createReconnectTracker', () {
    test('de-dupes ids, tracks lastEventId, and resets on empty id', () {
      final tracker = createReconnectTracker();
      expect(tracker.note('a'), ReconnectNote.fresh);
      expect(tracker.lastEventId, 'a');
      expect(tracker.note('a'), ReconnectNote.duplicate);
      expect(tracker.note(''), ReconnectNote.reset);
      expect(tracker.lastEventId, isNull);
      expect(tracker.note('a'), ReconnectNote.fresh);
    });
  });
}
