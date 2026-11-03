// Ported from
// packages/ai-client/tests/connection-adapters-resumable-transports.test.ts
// Test names and groups intentionally mirror the upstream file.
//
// Platform distinction: upstream drives a fake XMLHttpRequest directly. Dart's
// XHR-named adapters use an injected http.Client, so a "fresh XHR" maps to a
// fresh request on the fake client.
import 'package:tanstack_ai_dart/connections.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

String envelopeLine(String id, Map<String, dynamic> chunk) =>
    ndjsonLine(chunk, id: id);

String bareLine(Map<String, dynamic> chunk) => ndjsonLine(chunk);

void main() {
  group('resumable NDJSON (fetchHttpStream)', () {
    test('reconnects with Last-Event-ID and de-dupes already-seen chunks',
        () async {
      late FakeHttpClient client;
      client = FakeHttpClient((request) async {
        expect(request.url.toString(), '/api/chat');
        expect(request.headers['X-Run-Id'], 'r');
        if (client.requests.length == 1) {
          return rawResponse(
            envelopeLine('run@1', contentChunk('1')) +
                envelopeLine('run@2', contentChunk('2')) +
                envelopeLine('run@3', contentChunk('3')),
          );
        }
        expect(request.headers['Last-Event-ID'], 'run@3');
        return rawResponse(
          envelopeLine('run@3', contentChunk('3')) +
              envelopeLine('run@4', contentChunk('4')) +
              envelopeLine('run@5', finishedChunk()),
        );
      });
      final adapter = fetchHttpStream(
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

    test('joinRun opens the stream from the start with ?offset=-1', () async {
      final client = FakeHttpClient(
        (_) async => rawResponse(envelopeLine('run@1', finishedChunk())),
      );
      final adapter = fetchHttpStream(
        '/api/chat',
        FetchConnectionOptions(client: client),
      );

      final chunks = await collect(adapter.joinRun!('run-x'));

      final url = client.requests.single.url;
      expect(url.queryParameters['offset'], '-1');
      expect(url.queryParameters['runId'], 'run-x');
      expect(chunks.map((chunk) => chunk['type']), contains('RUN_FINISHED'));
    });

    test(
        'treats a bare-line (non-durable) stream as a single fetch with no '
        'reconnect', () async {
      final client = FakeHttpClient(
        (_) async => rawResponse(
          bareLine(contentChunk('1')) +
              bareLine(contentChunk('2')) +
              bareLine(finishedChunk()),
        ),
      );
      final adapter = fetchHttpStream(
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
      expect(client.requests, hasLength(1));
    });
  });

  group('resumable XHR transports', () {
    test(
        'xhrHttpStream reconnects with Last-Event-ID across a fresh XHR '
        '(NDJSON envelopes)', () async {
      late FakeHttpClient client;
      client = FakeHttpClient((request) async {
        if (client.requests.length == 1) {
          expect(request.method, 'POST');
          expect(request.url.toString(), '/api/chat');
          expect(request.headers['X-Run-Id'], 'r');
          return rawResponse(
            envelopeLine('run@1', contentChunk('1')) +
                envelopeLine('run@2', contentChunk('2')),
          );
        }
        expect(request.method, 'POST');
        expect(request.headers['Last-Event-ID'], 'run@2');
        return rawResponse(
          envelopeLine('run@2', contentChunk('2')) +
              envelopeLine('run@3', contentChunk('3')) +
              envelopeLine('run@4', finishedChunk()),
        );
      });
      final adapter = xhrHttpStream(
        '/api/chat',
        XhrConnectionOptions(
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

      expect(deltasOf(chunks), ['1', '2', '3']);
      expect(chunks.last['type'], 'RUN_FINISHED');
      expect(client.requests, hasLength(2));
    });

    test('xhrHttpStream reconnects after an onerror socket drop (held offset)',
        () async {
      late FakeHttpClient client;
      client = FakeHttpClient((_) async {
        if (client.requests.length == 1) {
          return failingResponse(
            envelopeLine('run@1', contentChunk('1')),
            StateError('xhr error'),
          );
        }
        expect(client.requests.last.headers['Last-Event-ID'], 'run@1');
        return rawResponse(
          envelopeLine('run@2', contentChunk('2')) +
              envelopeLine('run@3', finishedChunk()),
        );
      });
      final adapter = xhrHttpStream(
        '/api/chat',
        XhrConnectionOptions(
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
      expect(client.requests, hasLength(2));
    });

    test('xhrServerSentEvents is resumable too (durable SSE over XHR)',
        () async {
      late FakeHttpClient client;
      client = FakeHttpClient((request) async {
        if (client.requests.length == 1) {
          return rawResponse(sseEvent(contentChunk('1'), id: 'run@1'));
        }
        expect(request.headers['Last-Event-ID'], 'run@1');
        return rawResponse(
          sseEvent(contentChunk('1'), id: 'run@1') +
              sseEvent(finishedChunk(), id: 'run@2'),
        );
      });
      final adapter = xhrServerSentEvents(
        '/api/chat',
        XhrConnectionOptions(
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

      expect(deltasOf(chunks), ['1']);
      expect(chunks.last['type'], 'RUN_FINISHED');
    });

    test('xhrHttpStream joinRun issues a GET from the start with ?offset=-1',
        () async {
      final client = FakeHttpClient(
        (_) async => rawResponse(envelopeLine('run@1', finishedChunk())),
      );
      final adapter = xhrHttpStream(
        '/api/chat',
        XhrConnectionOptions(client: client),
      );

      final chunks = await collect(adapter.joinRun!('run-x'));

      final request = client.requests.single;
      expect(request.method, 'GET');
      expect(request.url.queryParameters['offset'], '-1');
      expect(request.url.queryParameters['runId'], 'run-x');
      expect(chunks.map((chunk) => chunk['type']), contains('RUN_FINISHED'));
    });
  });
}
