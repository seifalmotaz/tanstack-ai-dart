// Ported from packages/ai-client/tests/connection-adapters-xhr.test.ts
// Test names and groups intentionally mirror the upstream file.
//
// Platform distinction: when a client is injected, these adapters use it
// unchanged, so request method/headers/body and incremental response frames are
// observable, but `xhr.abort()`/handler cleanup is not. Without an injected
// client the web build uses a real package:web XMLHttpRequest seam; the VM uses
// IO. `withCredentials` is forwarded to the web XHR seam and is inert on VM.
import 'dart:async';

import 'package:tanstack_ai_dart/connections.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  group('xhr connection adapters', () {
    test('retries transient HTTP errors on a durable XHR reconnect', () async {
      late FakeHttpClient client;
      client = FakeHttpClient((request) async {
        if (client.requests.length == 1) {
          return rawResponse(sseEvent(contentChunk('one'), id: 'offset-1'));
        }
        expect(request.headers['Last-Event-ID'], 'offset-1');
        if (client.requests.length == 2) {
          return rawResponse('', status: 503, headers: {'retry-after': '0'});
        }
        return rawResponse(sseEvent(finishedChunk(), id: 'offset-2'));
      });
      final adapter = xhrServerSentEvents('/api/chat',
          options: XhrConnectionOptions(
              client: client,
              reconnect: const ReconnectOptions(initialDelay: Duration.zero)));
      final result = await collect(adapter.connect!([],
          runContext: const RunAgentInputContext(threadId: 't', runId: 'r')));
      expect(result.last['type'], 'RUN_FINISHED');
      expect(client.requests, hasLength(3));
    });
    group('xhrServerSentEvents', () {
      test(
          'parses split SSE chunks across multiple progress events and sends '
          'AG-UI request body', () async {
        final body = ControlledResponse();
        final client = FakeHttpClient((_) async => body.response);
        final adapter = xhrServerSentEvents(
          '/api/chat',
          options: XhrConnectionOptions(
            client: client,
            headers: {'Authorization': 'Bearer token'},
            body: {'model': 'test-model'},
            withCredentials: true,
          ),
        );

        final iterator = StreamIterator<StreamChunk>(
          adapter.connect!(
            [
              {'role': 'user', 'content': 'Hello'},
            ],
            data: {'temperature': 0},
            runContext: const RunAgentInputContext(
              threadId: 'thread-1',
              runId: 'run-1',
            ),
          ),
        );
        final nextChunk = iterator.moveNext();
        await tick();

        final request = client.requests.single;
        expect(request.method, 'POST');
        expect(request.url.toString(), '/api/chat');
        expect(
            request.headers,
            containsPair(
              'Content-Type',
              'application/json',
            ));
        expect(request.headers, containsPair('Authorization', 'Bearer token'));
        expect(request.headers, containsPair('X-Run-Id', 'run-1'));
        final bodyJson = jsonBodyOf(request);
        expect(bodyJson['threadId'], 'thread-1');
        expect(bodyJson['runId'], 'run-1');
        expect(bodyJson['forwardedProps'], {
          'model': 'test-model',
          'temperature': 0,
        });

        body.write('data: {"type":"TEXT_MESSAGE_CONTENT","messageId":"msg');
        await tick();
        body.write(
          '-1","model":"test","timestamp":123,"delta":"Hello","content":"Hello"}\n\n',
        );

        expect(await nextChunk, isTrue);
        final chunk = iterator.current;
        expect(chunk['type'], 'TEXT_MESSAGE_CONTENT');
        expect(chunk['messageId'], 'msg-1');
        expect(chunk['delta'], 'Hello');
        await iterator.cancel();
      });

      test('sends resume in the AG-UI request body', () async {
        final body = ControlledResponse();
        final client = FakeHttpClient((_) async => body.response);
        final adapter = xhrServerSentEvents(
          '/api/chat',
          options: XhrConnectionOptions(client: client),
        );
        final resume = [
          {
            'interruptId': 'interrupt-1',
            'status': 'resolved',
            'payload': {'approved': true},
          },
          {'interruptId': 'interrupt-2', 'status': 'cancelled'},
        ];

        final iterator = StreamIterator<StreamChunk>(
          adapter.connect!(
            [],
            runContext: RunAgentInputContext(
              threadId: 'thread-1',
              runId: 'run-1',
              resume: resume,
            ),
          ),
        );
        final nextChunk = iterator.moveNext();
        await tick();

        expect(jsonBodyOf(client.requests.single)['resume'], resume);

        body.write(sseEvent(finishedChunk()));
        expect(await nextChunk, isTrue);
        expect(iterator.current['type'], 'RUN_FINISHED');
        await iterator.cancel();
      });

      test('parses SSE data frames without a space after the colon', () async {
        final body = ControlledResponse();
        final client = FakeHttpClient((_) async => body.response);
        final adapter = xhrServerSentEvents(
          '/api/chat',
          options: XhrConnectionOptions(client: client),
        );
        final iterator = StreamIterator<StreamChunk>(
          adapter.connect!(
            [],
            runContext: const RunAgentInputContext(
                threadId: 'test-thread', runId: 'test-run'),
          ),
        );
        final nextChunk = iterator.moveNext();
        await tick();

        body.write(
          'data:{"type":"TEXT_MESSAGE_CONTENT","messageId":"msg-1",'
          '"model":"test","timestamp":123,"delta":"Hello","content":"Hello"}\n\n',
        );

        expect(await nextChunk, isTrue);
        expect(iterator.current['delta'], 'Hello');
        await iterator.cancel();
      });

      test('throws a FormatException on malformed JSON', () async {
        final body = ControlledResponse();
        final client = FakeHttpClient((_) async => body.response);
        final adapter = xhrServerSentEvents(
          '/api/chat',
          options: XhrConnectionOptions(client: client),
        );
        final iterator = StreamIterator<StreamChunk>(adapter.connect!(
          [],
          runContext: const RunAgentInputContext(
              threadId: 'test-thread', runId: 'test-run'),
        ));
        final nextChunk = iterator.moveNext();
        await tick();

        body.write('data: not json\n\n');

        await expectLater(nextChunk, throwsA(isA<FormatException>()));
        await iterator.cancel();
      });

      test('throws a meaningful error for non-2xx status', () async {
        final client = FakeHttpClient(
          (_) async => rawResponse(
            '',
            status: 503,
            reasonPhrase: 'Service Unavailable',
          ),
        );
        final adapter = xhrServerSentEvents(
          '/api/chat',
          options: XhrConnectionOptions(client: client),
        );
        await expectLater(
          collect(adapter.connect!(
            [],
            runContext: const RunAgentInputContext(
                threadId: 'test-thread', runId: 'test-run'),
          )),
          throwsA(
            predicate<Object>(
              (error) =>
                  error.toString() ==
                  'XHR error! status: 503 Service Unavailable',
            ),
          ),
        );
      });

      test(
          'throws status error instead of yielding or parsing body chunks '
          'when status is non-2xx before progress', () async {
        final client = FakeHttpClient(
          (_) async => rawResponse(
            'data: not json\n\n',
            status: 500,
            reasonPhrase: 'Internal Server Error',
          ),
        );
        final adapter = xhrServerSentEvents(
          '/api/chat',
          options: XhrConnectionOptions(client: client),
        );
        final error = await captureError(() => collect(adapter.connect!(
              [],
              runContext: const RunAgentInputContext(
                  threadId: 'test-thread', runId: 'test-run'),
            )));
        expect(
          error.toString(),
          'XHR error! status: 500 Internal Server Error',
        );
        expect(error, isNot(isA<FormatException>()));
      });

      test('does not send when the abort signal is already aborted', () async {
        final controller = CancellationController();
        controller.cancel();
        final client = FakeHttpClient((_) async => rawResponse(''));
        final adapter = xhrServerSentEvents(
          '/api/chat',
          options: XhrConnectionOptions(client: client),
        );

        final chunks = await collect(
          adapter.connect!(
            [],
            signal: controller.signal,
            runContext: const RunAgentInputContext(
                threadId: 'test-thread', runId: 'test-run'),
          ),
        );

        expect(chunks, isEmpty);
        expect(client.requests, isEmpty);
      });

      test(
          'maps AbortSignal to xhr.abort, stops output, and cleans up '
          'handlers', () async {
        final controller = CancellationController();
        final body = ControlledResponse();
        final client = FakeHttpClient((_) async => body.response);
        final adapter = xhrServerSentEvents(
          '/api/chat',
          options: XhrConnectionOptions(client: client),
        );
        final iterator = StreamIterator<StreamChunk>(
          adapter.connect!(
            [],
            signal: controller.signal,
            runContext: const RunAgentInputContext(
                threadId: 'test-thread', runId: 'test-run'),
          ),
        );
        final nextChunk = iterator.moveNext();
        await tick();

        controller.cancel();

        expect(await nextChunk, isFalse);
        expect(body.cancelled, isTrue);
        await iterator.cancel();
      });

      test('cleans up abort listener and xhr handlers after success and error',
          () async {
        final successBody = ControlledResponse();
        final success = FakeHttpClient((_) async => successBody.response);
        final successIterator = StreamIterator<StreamChunk>(
          xhrServerSentEvents(
            '/api/chat',
            options: XhrConnectionOptions(client: success),
          ).connect!(
            [],
            runContext: const RunAgentInputContext(
                threadId: 'test-thread', runId: 'test-run'),
          ),
        );
        final next = successIterator.moveNext();
        await tick();
        successBody.write(sseEvent(finishedChunk()));
        await next;
        unawaited(successBody.close());
        await successIterator.moveNext();
        expect(successBody.cancelled, isTrue);

        final failureBody = ControlledResponse();
        final failure = FakeHttpClient((_) async => failureBody.response);
        final failureIterator = StreamIterator<StreamChunk>(
          xhrServerSentEvents(
            '/api/chat',
            options: XhrConnectionOptions(client: failure),
          ).connect!(
            [],
            runContext: const RunAgentInputContext(
                threadId: 'test-thread', runId: 'test-run'),
          ),
        );
        final failureNext = failureIterator.moveNext();
        await tick();
        failureBody.write('data: not json\n\n');
        await expectLater(
          failureNext,
          throwsA(isA<FormatException>()),
        );
        expect(failureBody.cancelled, isTrue);
        await failureIterator.cancel();
      });

      test('throws StreamTruncatedError on trailing unterminated SSE data',
          () async {
        final client = FakeHttpClient(
          (_) async => rawResponse('data: {"type":"RUN_STARTED"'),
        );
        final adapter = xhrServerSentEvents(
          '/api/chat',
          options: XhrConnectionOptions(client: client),
        );
        await expectLater(
          collect(adapter.connect!(
            [],
            runContext: const RunAgentInputContext(
                threadId: 'test-thread', runId: 'test-run'),
          )),
          throwsA(isA<StreamTruncatedError>()),
        );
      });
    });

    group('xhrHttpStream', () {
      test('parses split newline-delimited JSON across progress events',
          () async {
        final body = ControlledResponse();
        final client = FakeHttpClient((_) async => body.response);
        final adapter = xhrHttpStream(
          '/api/chat',
          options: XhrConnectionOptions(client: client),
        );
        final iterator = StreamIterator<StreamChunk>(adapter.connect!(
          [],
          runContext: const RunAgentInputContext(
              threadId: 'test-thread', runId: 'test-run'),
        ));
        final nextChunk = iterator.moveNext();
        await tick();

        body.write('{"type":"RUN_STARTED","runId":"run');
        await tick();
        body.write('-1","timestamp":100}\n');

        expect(await nextChunk, isTrue);
        expect(iterator.current['type'], 'RUN_STARTED');
        expect(iterator.current['runId'], 'run-1');
        await iterator.cancel();
      });

      test('throws a FormatException for malformed newline-delimited JSON',
          () async {
        final body = ControlledResponse();
        final client = FakeHttpClient((_) async => body.response);
        final adapter = xhrHttpStream(
          '/api/chat',
          options: XhrConnectionOptions(client: client),
        );
        final iterator = StreamIterator<StreamChunk>(adapter.connect!(
          [],
          runContext: const RunAgentInputContext(
              threadId: 'test-thread', runId: 'test-run'),
        ));
        final nextChunk = iterator.moveNext();
        await tick();

        body.write('not json\n');

        await expectLater(nextChunk, throwsA(isA<FormatException>()));
        await iterator.cancel();
      });

      test(
          'throws status error instead of yielding or parsing body chunks '
          'when status is non-2xx before progress', () async {
        final client = FakeHttpClient(
          (_) async => rawResponse(
            'not json\n',
            status: 500,
            reasonPhrase: 'Internal Server Error',
          ),
        );
        final adapter = xhrHttpStream(
          '/api/chat',
          options: XhrConnectionOptions(client: client),
        );
        final error = await captureError(() => collect(adapter.connect!(
              [],
              runContext: const RunAgentInputContext(
                  threadId: 'test-thread', runId: 'test-run'),
            )));
        expect(
          error.toString(),
          'XHR error! status: 500 Internal Server Error',
        );
        expect(error, isNot(isA<FormatException>()));
      });

      test('does not send when the abort signal is already aborted', () async {
        final controller = CancellationController();
        controller.cancel();
        final client = FakeHttpClient((_) async => rawResponse(''));
        final adapter = xhrHttpStream(
          '/api/chat',
          options: XhrConnectionOptions(client: client),
        );

        final chunks = await collect(
          adapter.connect!(
            [],
            signal: controller.signal,
            runContext: const RunAgentInputContext(
                threadId: 'test-thread', runId: 'test-run'),
          ),
        );

        expect(chunks, isEmpty);
        expect(client.requests, isEmpty);
      });
    });
  });
}
