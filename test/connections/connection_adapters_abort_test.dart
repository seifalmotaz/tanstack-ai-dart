// Ported from
// packages/ai-client/tests/connection-adapters-abort.test.ts
// Test names and groups intentionally mirror the upstream file.
//
// Platform distinction: upstream asserts `RequestInit.signal` is passed to
// fetch and that XHR handlers are cleaned up. Dart's http seam has no request
// signal object, so these tests assert the observable behavior: the reader
// stops promptly on cancellation and releases the response stream.
import 'package:tanstack_ai_dart/connections.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  group('Connection Adapters - Abort Signal Handling', () {
    test('should pass abortSignal to fetch', () async {
      final controller = CancellationController();
      final body = ControlledResponse();
      final client = FakeHttpClient((_) async => body.response);
      final adapter = fetchServerSentEvents(
        '/api/chat',
        FetchConnectionOptions(client: client),
      );

      final result = collect(adapter.connect!(
        [
          {'role': 'user', 'content': 'Hello'},
        ],
        signal: controller.signal,
      ));
      await tick();
      body.write('data: [DONE]\n\n');
      await tick();
      controller.cancel();
      final chunks = await result.timeout(const Duration(seconds: 2));

      expect(client.requests, hasLength(1));
      expect(chunks, hasLength(1));
      expect(chunks.single['type'], 'RUN_FINISHED');
    });

    test('should use provided abortSignal over options.signal', () async {
      final provided = CancellationController();
      final options = CancellationController();
      final client = FakeHttpClient(
        (_) async => rawResponse('data: [DONE]\n\n'),
      );
      final adapter = fetchServerSentEvents(
        '/api/chat',
        FetchConnectionOptions(client: client, signal: options.signal),
      );

      final chunks = await collect(
        adapter.connect!(
          [
            {'role': 'user', 'content': 'Hello'},
          ],
          signal: provided.signal,
        ),
      );

      expect(chunks, hasLength(1));
    });

    test('should stop reading stream when aborted', () async {
      final controller = CancellationController();
      final body = ControlledResponse();
      final client = FakeHttpClient((_) async => body.response);
      final adapter = fetchServerSentEvents(
        '/api/chat',
        FetchConnectionOptions(client: client),
      );

      final result = collect(adapter.connect!(
        [
          {'role': 'user', 'content': 'Hello'},
        ],
        signal: controller.signal,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      body.write(sseData('{"type":"TEXT_MESSAGE_CONTENT","delta":"Hello"}'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      controller.cancel();
      final chunks = await result.timeout(const Duration(seconds: 2));

      expect(chunks, hasLength(1));
      expect(body.cancelled, isTrue);
    });

    test('should check abortSignal before each read', () async {
      final controller = CancellationController();
      final body = ControlledResponse();
      final client = FakeHttpClient((_) async => body.response);
      final adapter = fetchServerSentEvents(
        '/api/chat',
        FetchConnectionOptions(client: client),
      );

      final result = collect(adapter.connect!(
        [
          {'role': 'user', 'content': 'Hello'},
        ],
        signal: controller.signal,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      controller.cancel();
      final chunks = await result.timeout(const Duration(seconds: 2));

      expect(chunks, isEmpty);
      expect(body.cancelled, isTrue);
    });

    test('fetchHttpStream should pass abortSignal to fetch', () async {
      final controller = CancellationController();
      final client = FakeHttpClient(
        (_) async => rawResponse(ndjsonLine(contentChunk('x'))),
      );
      final adapter = fetchHttpStream(
        '/api/chat',
        FetchConnectionOptions(client: client),
      );

      final chunks = await collect(
        adapter.connect!(
          [
            {'role': 'user', 'content': 'Hello'},
          ],
          signal: controller.signal,
        ),
      );

      expect(client.requests, hasLength(1));
      expect(chunks, hasLength(1));
    });

    test('fetchHttpStream should stop reading stream when aborted', () async {
      final controller = CancellationController();
      final body = ControlledResponse();
      final client = FakeHttpClient((_) async => body.response);
      final adapter = fetchHttpStream(
        '/api/chat',
        FetchConnectionOptions(client: client),
      );

      final result = collect(adapter.connect!(
        [
          {'role': 'user', 'content': 'Hello'},
        ],
        signal: controller.signal,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      body.write(ndjsonLine(contentChunk('Hello')));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      controller.cancel();
      final chunks = await result.timeout(const Duration(seconds: 2));

      expect(chunks, hasLength(1));
      expect(body.cancelled, isTrue);
    });
  });
}
