// Ported from
// packages/ai-client/tests/connection-adapters.test.ts
// Test names and groups intentionally mirror the upstream file.
import 'dart:async';
import 'dart:convert';

import 'package:tanstack_ai_dart/connections.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  group('connection-adapters', () {
    test('forwards resume on a fetcher adapter', () async {
      ChatFetcherInput? seen;
      final adapter = fetcherToConnectionAdapter(
        (input, {signal, headers}) async* {
          seen = input;
          yield finishedChunk();
        },
      );
      final controller = CancellationController();
      final resume = [
        {
          'interruptId': 'generic-1',
          'status': 'cancelled',
          'metadata': {
            'tanstack:interruptContinuation': {
              'v': 1,
              'definitionId': 'review',
              'key': 'one',
              'batchIndex': 0,
              'reason': 'review',
              'message': 'Review',
            },
          },
        },
      ];

      await collect(
        adapter.connect!(
          [],
          data: {'source': 'test'},
          signal: controller.signal,
          runContext: RunAgentInputContext(
            threadId: 'thread-1',
            runId: 'resume-run',
            parentRunId: 'interrupted-run',
            resume: resume,
          ),
        ),
      );

      expect(seen?.threadId, 'thread-1');
      expect(seen?.runId, 'resume-run');
      expect(seen?.parentRunId, 'interrupted-run');
      expect(seen?.resume, resume);
      expect(seen?.data, {'source': 'test'});
    });

    group('fetchServerSentEvents', () {
      test('sends generic continuation on resume metadata, not state',
          () async {
        final client = FakeHttpClient((_) async => rawResponse(''));
        final adapter = fetchServerSentEvents(
          '/api/chat',
          FetchConnectionOptions(client: client),
        );
        final resume = [
          {
            'interruptId': 'generic-1',
            'status': 'cancelled',
            'metadata': {
              'tanstack:interruptContinuation': {'v': 1}
            },
          },
        ];

        await collect(
          adapter.connect!(
            [
              {'role': 'user', 'content': 'Resume'},
            ],
            runContext: RunAgentInputContext(
              threadId: 'thread-1',
              runId: 'run-2',
              resume: resume,
            ),
          ),
        );

        final body = jsonBodyOf(client.requests.single);
        expect(body['resume'], resume);
        expect(body['state'], {});
      });

      test('should handle SSE format with data: prefix', () async {
        final client = FakeHttpClient(
          (_) async => rawResponse(
            sseData(
              jsonEncode({
                'type': 'TEXT_MESSAGE_CONTENT',
                'messageId': 'msg-1',
                'model': 'test',
                'timestamp': 123,
                'delta': 'Hello',
                'content': 'Hello',
              }),
            ),
          ),
        );
        final adapter = fetchServerSentEvents(
          '/api/chat',
          FetchConnectionOptions(client: client),
        );

        final chunks = await collect(
          adapter.connect!([
            {'role': 'user', 'content': 'Hello'},
          ]),
        );

        expect(chunks, hasLength(1));
        expect(chunks.single, {
          'type': 'TEXT_MESSAGE_CONTENT',
          'messageId': 'msg-1',
          'model': 'test',
          'timestamp': 123,
          'delta': 'Hello',
          'content': 'Hello',
        });
      });

      test('should handle SSE format with data: prefix and no space', () async {
        final client = FakeHttpClient(
          (_) async => rawResponse(
            'data:${jsonEncode(contentChunk('Hello'))}\n\n',
          ),
        );
        final adapter = fetchServerSentEvents(
          '/api/chat',
          FetchConnectionOptions(client: client),
        );

        final chunks = await collect(
          adapter.connect!([
            {'role': 'user', 'content': 'Hello'},
          ]),
        );

        expect(chunks, hasLength(1));
        expect(chunks.single['delta'], 'Hello');
      });

      test(
          'does not truncate an agentic run at the first RUN_FINISHED '
          '(multiple terminals per run)', () async {
        final body =
            'data: ${jsonEncode({'type': 'RUN_STARTED', 'timestamp': 1})}\n\n'
            'data: ${jsonEncode({'type': 'TOOL_CALL_END', 'timestamp': 2})}\n\n'
            'data: ${jsonEncode({'type': 'RUN_FINISHED', 'timestamp': 3})}\n\n'
            'data: ${jsonEncode({
              'type': 'TOOL_CALL_RESULT',
              'timestamp': 4
            })}\n\n'
            'data: ${jsonEncode({'type': 'RUN_STARTED', 'timestamp': 5})}\n\n'
            'data: ${jsonEncode({
              'type': 'TEXT_MESSAGE_CONTENT',
              'messageId': 'm',
              'model': 't',
              'timestamp': 6,
              'delta': 'final',
              'content': 'final'
            })}\n\n'
            'data: ${jsonEncode({'type': 'RUN_FINISHED', 'timestamp': 7})}\n\n';
        final client = FakeHttpClient((_) async => rawResponse(body));
        final adapter = fetchServerSentEvents(
          '/api/chat',
          FetchConnectionOptions(client: client),
        );

        final chunks = await collect(
          adapter.connect!([
            {'role': 'user', 'content': 'Hello'},
          ]),
        );

        expect(chunks.map((chunk) => chunk['type']), [
          'RUN_STARTED',
          'TOOL_CALL_END',
          'RUN_FINISHED',
          'TOOL_CALL_RESULT',
          'RUN_STARTED',
          'TEXT_MESSAGE_CONTENT',
          'RUN_FINISHED',
        ]);
      });

      test('should handle SSE format without data: prefix', () async {
        final client = FakeHttpClient(
          (_) async => rawResponse('${jsonEncode(contentChunk('Hello'))}\n'),
        );
        final adapter = fetchServerSentEvents(
          '/api/chat',
          FetchConnectionOptions(client: client),
        );
        final chunks = await collect(
          adapter.connect!([
            {'role': 'user', 'content': 'Hello'},
          ]),
        );
        expect(chunks, hasLength(1));
      });

      test('should synthesize RUN_FINISHED on [DONE] and stop reading',
          () async {
        final client =
            FakeHttpClient((_) async => rawResponse('data: [DONE]\n\n'));
        final adapter = fetchServerSentEvents(
          '/api/chat',
          FetchConnectionOptions(client: client),
        );
        final chunks = await collect(
          adapter.connect!([
            {'role': 'user', 'content': 'Hello'},
          ]),
        );
        expect(chunks, hasLength(1));
        expect(chunks.single['type'], 'RUN_FINISHED');
      });

      test('should throw a FormatException on malformed JSON', () async {
        final client =
            FakeHttpClient((_) async => rawResponse('data: invalid json\n\n'));
        final adapter = fetchServerSentEvents(
          '/api/chat',
          FetchConnectionOptions(client: client),
        );

        await expectLater(
          collect(adapter.connect!([
            {'role': 'user', 'content': 'Hello'},
          ])),
          throwsA(isA<FormatException>()),
        );
      });

      test('should handle HTTP errors', () async {
        final client = FakeHttpClient(
          (_) async => rawResponse(
            '',
            status: 500,
            reasonPhrase: 'Internal Server Error',
          ),
        );
        final adapter = fetchServerSentEvents(
          '/api/chat',
          FetchConnectionOptions(client: client),
        );

        await expectLater(
          collect(adapter.connect!([
            {'role': 'user', 'content': 'Hello'},
          ])),
          throwsA(
            predicate<Object>(
              (error) =>
                  error.toString() ==
                  'HTTP error! status: 500 Internal Server Error',
            ),
          ),
        );
      });

      test('should merge custom headers', () async {
        final client = FakeHttpClient((_) async => rawResponse(''));
        final adapter = fetchServerSentEvents(
          '/api/chat',
          FetchConnectionOptions(
            client: client,
            headers: {'Authorization': 'Bearer token'},
          ),
        );

        await collect(adapter.connect!([]));

        expect(
            headersOf(client.requests.single),
            containsPair(
              'Content-Type',
              'application/json',
            ));
        expect(
            headersOf(client.requests.single),
            containsPair(
              'Authorization',
              'Bearer token',
            ));
      });

      test('should pass data to request body forwardedProps', () async {
        final client = FakeHttpClient((_) async => rawResponse(''));
        final adapter = fetchServerSentEvents(
          '/api/chat',
          FetchConnectionOptions(client: client),
        );

        await collect(
          adapter.connect!(
            [
              {'role': 'user', 'content': 'Hello'},
            ],
            data: {'key': 'value'},
          ),
        );

        final body = jsonBodyOf(client.requests.single);
        expect(body['forwardedProps'], containsPair('key', 'value'));
      });

      test('should mirror forwardedProps under legacy `data` field', () async {
        final client = FakeHttpClient((_) async => rawResponse(''));
        final adapter = fetchServerSentEvents(
          '/api/chat',
          FetchConnectionOptions(client: client),
        );

        await collect(
          adapter.connect!(
            [
              {'role': 'user', 'content': 'Hello'},
            ],
            data: {'provider': 'openai', 'model': 'gpt-4o'},
          ),
        );

        final body = jsonBodyOf(client.requests.single);
        expect(body['data'], body['forwardedProps']);
        expect(body['data'], containsPair('provider', 'openai'));
      });

      test('should use custom client when provided', () async {
        final client = FakeHttpClient((_) async => rawResponse(''));
        final adapter = fetchServerSentEvents(
          '/api/chat',
          FetchConnectionOptions(client: client),
        );

        await collect(
          adapter.connect!([
            {'role': 'user', 'content': 'Hello'},
          ]),
        );

        expect(client.requests, hasLength(1));
        expect(client.requests.single.url.toString(), '/api/chat');
      });

      test('should resolve dynamic URL from function', () async {
        final client = FakeHttpClient((_) async => rawResponse(''));
        final adapter = fetchServerSentEvents(
          () => '/api/dynamic',
          FetchConnectionOptions(client: client),
        );

        await collect(adapter.connect!([]));

        expect(client.requests.single.url.toString(), '/api/dynamic');
      });

      test('should resolve dynamic options from sync function', () async {
        final client = FakeHttpClient((_) async => rawResponse(''));
        final adapter = fetchServerSentEvents(
          '/api/chat',
          () => FetchConnectionOptions(
            client: client,
            headers: {'X-Custom': 'dynamic'},
          ),
        );

        await collect(adapter.connect!([]));

        expect(
          client.requests.single.headers,
          containsPair('X-Custom', 'dynamic'),
        );
      });

      test('should resolve dynamic options from async function', () async {
        final client = FakeHttpClient((_) async => rawResponse(''));
        final adapter = fetchServerSentEvents(
          '/api/chat',
          () async => FetchConnectionOptions(
            client: client,
            headers: {'X-Async': 'token'},
          ),
        );

        await collect(adapter.connect!([]));

        expect(
          client.requests.single.headers,
          containsPair('X-Async', 'token'),
        );
      });

      test('should merge options.body into request body forwardedProps',
          () async {
        final client = FakeHttpClient((_) async => rawResponse(''));
        final adapter = fetchServerSentEvents(
          '/api/chat',
          FetchConnectionOptions(
            client: client,
            body: {'model': 'gpt-4o', 'provider': 'openai'},
          ),
        );

        await collect(
          adapter.connect!(
            [
              {'role': 'user', 'content': 'Hello'},
            ],
            data: {'key': 'value'},
          ),
        );

        expect(jsonBodyOf(client.requests.single)['forwardedProps'], {
          'model': 'gpt-4o',
          'provider': 'openai',
          'key': 'value',
        });
      });

      test('should handle multiple chunks across multiple reads', () async {
        final body = '${sseEvent({
              'type': 'RUN_STARTED',
              'runId': 'run-1',
              'timestamp': 100,
            })}\n${sseEvent({
              'type': 'CUSTOM',
              'name': 'generation:result',
              'value': {'id': '1'},
              'timestamp': 200,
            })}\n${sseEvent({
              'type': 'RUN_FINISHED',
              'runId': 'run-1',
              'threadId': 'thread-1',
              'timestamp': 300,
            })}';
        final client = FakeHttpClient((_) async => rawResponse(body));
        final adapter = fetchServerSentEvents(
          '/api/generate',
          FetchConnectionOptions(client: client),
        );

        final chunks = await collect(
          adapter.connect!([], data: {'prompt': 'test'}),
        );

        expect(chunks, hasLength(3));
        expect(chunks[0]['type'], 'RUN_STARTED');
        expect(chunks[1]['type'], 'CUSTOM');
        expect(chunks[2]['type'], 'RUN_FINISHED');
      });

      test('should handle missing response body', () {
        expect(
          () => requireResponseBody(null),
          throwsA(
            isA<UnsupportedResponseStreamError>().having(
              (error) => error.missingFeature,
              'missingFeature',
              UnsupportedResponseStreamError.responseBody,
            ),
          ),
        );
      });

      test(
          'should throw an actionable unsupported-stream error when getReader '
          'is missing', () {
        const error = UnsupportedResponseStreamError(
          UnsupportedResponseStreamError.responseBodyGetReader,
        );
        expect(error.missingFeature, 'Response.body.getReader');
        expect(error.toString(), contains('streaming chunks'));
      });

      test('should preserve HTTP errors before stream capability checks',
          () async {
        final client = FakeHttpClient(
          (_) async => rawResponse(
            '',
            status: 500,
            reasonPhrase: 'Internal Server Error',
          ),
        );
        final adapter = fetchServerSentEvents(
          '/api/chat',
          FetchConnectionOptions(client: client),
        );
        final error = await captureError(() => collect(adapter.connect!([])));
        expect(
          error.toString(),
          'HTTP error! status: 500 Internal Server Error',
        );
        expect(error, isNot(isA<UnsupportedResponseStreamError>()));
      });

      test('should handle Headers object', () async {
        // Dart has no WHATWG Headers class; a plain Map is the equivalent seam.
        final client = FakeHttpClient((_) async => rawResponse(''));
        final adapter = fetchServerSentEvents(
          '/api/chat',
          FetchConnectionOptions(
            client: client,
            headers: {'Authorization': 'Bearer token'},
          ),
        );
        await collect(adapter.connect!([]));
        expect(
          client.requests.single.headers['Authorization'],
          'Bearer token',
        );
        expect(
          client.requests.single.headers['Content-Type'],
          'application/json',
        );
      });
    });

    group('fetchHttpStream', () {
      test('normalizes only owned dates during fetch hydration', () async {
        final metadata = {
          'createdAt': 'message-metadata',
          'tanstack': {'createdAt': 'metadata-tanstack-date'},
          'nested': {'createdAt': 'nested-date'},
        };
        final content = [
          {
            'type': 'text',
            'content': 'result',
            'metadata': {'createdAt': 'content-date'},
          },
        ];
        final client = FakeHttpClient(
          (_) async => jsonResponse({
            'messages': [
              {
                'id': 'a1',
                'role': 'assistant',
                'createdAt': '2026-08-20T00:00:00.000Z',
                'parts': [
                  {
                    'type': 'tool-result',
                    'toolCallId': 'call-1',
                    'content': content,
                    'state': 'complete',
                    'createdAt': '2026-08-20T00:00:01.000Z',
                    'metadata': {'createdAt': 'part-metadata'},
                  },
                ],
                'metadata': metadata,
              },
              {
                'id': 'a2',
                'role': 'assistant',
                'createdAt': 'invalid-message-date',
                'parts': [
                  {
                    'type': 'tool-result',
                    'toolCallId': 'call-2',
                    'content': 'ok',
                    'state': 'complete',
                    'createdAt': 'invalid-part-date',
                  },
                ],
              },
            ],
            'activeRun': null,
          }),
        );
        final adapter = fetchHttpStream(
          '/api/chat',
          FetchConnectionOptions(client: client),
        );

        final result = await adapter.hydrate!('thread-1');

        expect(
          result.messages[0]['createdAt'],
          DateTime.parse('2026-08-20T00:00:00.000Z'),
        );
        expect(
          (result.messages[0]['parts'] as List).first['createdAt'],
          DateTime.parse('2026-08-20T00:00:01.000Z'),
        );
        expect(result.messages[0]['metadata'], metadata);
        final part = (result.messages[0]['parts'] as List).first as Map;
        expect(part['metadata'], {'createdAt': 'part-metadata'});
        expect(part['content'], content);
        expect(result.messages[1].containsKey('createdAt'), isFalse);
        expect(
          ((result.messages[1]['parts'] as List).first as Map)
              .containsKey('createdAt'),
          isFalse,
        );
      });

      test('should parse newline-delimited JSON', () async {
        final client = FakeHttpClient(
          (_) async => rawResponse(ndjsonLine(contentChunk('Hello'))),
        );
        final adapter = fetchHttpStream(
          '/api/chat',
          FetchConnectionOptions(client: client),
        );
        final chunks = await collect(
          adapter.connect!([
            {'role': 'user', 'content': 'Hello'},
          ]),
        );
        expect(chunks, hasLength(1));
      });

      test('should throw a FormatException on malformed JSON', () async {
        final client =
            FakeHttpClient((_) async => rawResponse('invalid json\n'));
        final adapter = fetchHttpStream(
          '/api/chat',
          FetchConnectionOptions(client: client),
        );
        await expectLater(
          collect(adapter.connect!([
            {'role': 'user', 'content': 'Hello'},
          ])),
          throwsA(isA<FormatException>()),
        );
      });

      test('should handle HTTP errors', () async {
        final client = FakeHttpClient(
          (_) async => rawResponse(
            '',
            status: 404,
            reasonPhrase: 'Not Found',
          ),
        );
        final adapter = fetchHttpStream(
          '/api/chat',
          FetchConnectionOptions(client: client),
        );
        await expectLater(
          collect(adapter.connect!([
            {'role': 'user', 'content': 'Hello'},
          ])),
          throwsA(
            predicate<Object>(
              (error) =>
                  error.toString() == 'HTTP error! status: 404 Not Found',
            ),
          ),
        );
      });

      test('should use custom client when provided', () async {
        final client = FakeHttpClient((_) async => rawResponse(''));
        final adapter = fetchHttpStream(
          '/api/chat',
          FetchConnectionOptions(client: client),
        );
        await collect(adapter.connect!([]));
        expect(client.requests, hasLength(1));
      });

      test('should merge custom headers', () async {
        final client = FakeHttpClient((_) async => rawResponse(''));
        final adapter = fetchHttpStream(
          '/api/chat',
          FetchConnectionOptions(
            client: client,
            headers: {'Authorization': 'Bearer token'},
          ),
        );
        await collect(adapter.connect!([]));
        expect(
            client.requests.single.headers,
            containsPair(
              'Content-Type',
              'application/json',
            ));
        expect(
            client.requests.single.headers,
            containsPair(
              'Authorization',
              'Bearer token',
            ));
      });

      test('should pass data to request body forwardedProps', () async {
        final client = FakeHttpClient((_) async => rawResponse(''));
        final adapter = fetchHttpStream(
          '/api/chat',
          FetchConnectionOptions(client: client),
        );
        await collect(
          adapter.connect!(
            [
              {'role': 'user', 'content': 'Hello'},
            ],
            data: {'key': 'value'},
          ),
        );
        expect(
          jsonBodyOf(client.requests.single)['forwardedProps'],
          containsPair('key', 'value'),
        );
      });

      test('should resolve dynamic URL from function', () async {
        final client = FakeHttpClient((_) async => rawResponse(''));
        final adapter = fetchHttpStream(
          () => '/api/dynamic',
          FetchConnectionOptions(client: client),
        );
        await collect(adapter.connect!([]));
        expect(client.requests.single.url.toString(), '/api/dynamic');
      });

      test('should handle multiple chunks across multiple reads', () async {
        final body = ndjsonLine({
              'type': 'RUN_STARTED',
              'runId': 'run-1',
              'timestamp': 100,
            }) +
            ndjsonLine({
              'type': 'CUSTOM',
              'name': 'generation:result',
              'value': {'id': '1'},
              'timestamp': 200,
            }) +
            ndjsonLine({
              'type': 'RUN_FINISHED',
              'runId': 'run-1',
              'threadId': 'thread-1',
              'timestamp': 300,
            });
        final client = FakeHttpClient((_) async => rawResponse(body));
        final adapter = fetchHttpStream(
          '/api/generate',
          FetchConnectionOptions(client: client),
        );
        final chunks = await collect(
          adapter.connect!([], data: {'prompt': 'test'}),
        );
        expect(chunks, hasLength(3));
        expect(chunks[0]['type'], 'RUN_STARTED');
        expect(chunks[1]['type'], 'CUSTOM');
        expect(chunks[2]['type'], 'RUN_FINISHED');
      });

      test('should handle missing response body', () {
        expect(
          () => requireResponseBody(null),
          throwsA(
            isA<UnsupportedResponseStreamError>().having(
              (error) => error.missingFeature,
              'missingFeature',
              UnsupportedResponseStreamError.responseBody,
            ),
          ),
        );
      });

      test(
          'should throw an actionable unsupported-stream error when '
          'TextDecoder is missing', () {
        const error = UnsupportedResponseStreamError(
          UnsupportedResponseStreamError.textDecoder,
        );
        expect(error.missingFeature, 'TextDecoder');
        expect(error.toString(), contains('TextDecoder'));
      });
    });

    group('stream', () {
      test('should delegate to stream factory', () async {
        var called = false;
        final adapter = stream((messages, data, signal) async* {
          called = true;
          yield contentChunk('Hello');
        });

        final chunks = await collect(
          adapter.connect!([
            {'role': 'user', 'content': 'Hello'},
          ]),
        );

        expect(called, isTrue);
        expect(chunks, hasLength(1));
      });

      test('should pass data to stream factory', () async {
        List<WireMessage>? seenMessages;
        Map<String, dynamic>? seenData;
        final adapter = stream((messages, data, signal) async* {
          seenMessages = messages;
          seenData = data;
          yield finishedChunk();
        });
        final data = {'key': 'value'};

        await collect(
          adapter.connect!(
            [
              {'role': 'user', 'content': 'Hello'},
            ],
            data: data,
          ),
        );

        expect(seenMessages, isNotNull);
        expect(seenData, data);
      });

      test('should spread supplied persistence handlers onto the adapter', () {
        final adapter = stream(
          (messages, data, signal) async* {},
          StreamConnectionHandlers(
            hydrate: (threadId, {options}) async =>
                const ChatHydrationResult(messages: []),
            hydrateGeneration: (threadId) async =>
                const GenerationHydrationResult(),
            joinRun: (runId, {signal}) async* {},
          ),
        );

        expect(adapter.hydrate, isNotNull);
        expect(adapter.hydrateGeneration, isNotNull);
        expect(adapter.joinRun, isNotNull);
      });

      test('should omit persistence handlers that are not supplied', () {
        final adapter = stream((messages, data, signal) async* {});
        expect(adapter.hydrate, isNull);
        expect(adapter.hydrateGeneration, isNull);
        expect(adapter.joinRun, isNull);
      });
    });

    group('normalizeConnectionAdapter', () {
      test('should throw when connection is not provided', () {
        expect(
          () => normalizeConnectionAdapter(null),
          throwsA(
            predicate<Object>(
              (error) =>
                  error.toString().contains('Connection adapter is required'),
            ),
          ),
        );
      });

      test('should throw when subscribe/send are partially implemented', () {
        final invalid = [
          ConnectionAdapter(subscribe: ({signal}) => const Stream.empty()),
          ConnectionAdapter(
            send: (messages, {data, signal, runContext}) async {},
          ),
        ];

        for (final adapter in invalid) {
          expect(
            () => normalizeConnectionAdapter(adapter),
            throwsA(
              predicate<Object>(
                (error) => error
                    .toString()
                    .contains('either connect or both subscribe and send'),
              ),
            ),
          );
        }
      });

      test('should throw when both connection modes are provided', () {
        final adapter = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {},
          subscribe: ({signal}) => const Stream.empty(),
          send: (messages, {data, signal, runContext}) async {},
        );
        expect(
          () => normalizeConnectionAdapter(adapter),
          throwsA(
            predicate<Object>(
              (error) => error.toString().contains('not both modes'),
            ),
          ),
        );
      });

      test(
          'should synthesize RUN_FINISHED when wrapped connect stream has no '
          'terminal event', () async {
        final base = stream((messages, data, signal) async* {
          yield contentChunk('Hi');
        });
        final adapter = normalizeConnectionAdapter(base);
        final controller = CancellationController();
        final receivedFuture =
            adapter.subscribe(signal: controller.signal).take(2).toList();

        await adapter.send(
          [
            {'role': 'user', 'content': 'Hello'},
          ],
          runContext: const RunAgentInputContext(
            threadId: 'thread-test',
            runId: 'run-test',
          ),
        );
        final received = await receivedFuture;

        expect(received, hasLength(2));
        expect(received[1]['type'], 'RUN_FINISHED');
      });

      test('should synthesize RUN_ERROR when wrapped connect stream throws',
          () async {
        final base = stream((messages, data, signal) async* {
          throw StateError('connect exploded');
        });
        final adapter = normalizeConnectionAdapter(base);
        final controller = CancellationController();
        final receivedFuture =
            adapter.subscribe(signal: controller.signal).take(1).toList();

        final error = await captureError(
          () => adapter.send(
            [
              {'role': 'user', 'content': 'Hello'},
            ],
            runContext: const RunAgentInputContext(
              threadId: 'thread-test',
              runId: 'run-test',
            ),
          ),
        );
        final received = await receivedFuture;

        expect(error.toString(), contains('connect exploded'));
        expect(received, hasLength(1));
        expect(received.single['type'], 'RUN_ERROR');
      });

      test(
          'should not synthesize duplicate RUN_ERROR when stream already '
          'emitted one before throwing', () async {
        final base = stream((messages, data, signal) async* {
          yield {'type': 'RUN_ERROR', 'message': 'already failed'};
          throw StateError('connect exploded');
        });
        final adapter = normalizeConnectionAdapter(base);
        final controller = CancellationController();
        final receivedFuture =
            adapter.subscribe(signal: controller.signal).take(1).toList();

        final error = await captureError(
          () => adapter.send([
            {'role': 'user', 'content': 'Hello'},
          ]),
        );
        final received = await receivedFuture;

        expect(error.toString(), contains('connect exploded'));
        expect(received, hasLength(1));
        expect(received.single['type'], 'RUN_ERROR');
        expect(received.single['message'], 'already failed');
      });
    });

    group('rpcStream', () {
      test('should delegate to RPC call', () async {
        var called = false;
        final adapter = rpcStream((messages, data, signal) async* {
          called = true;
          yield contentChunk('Hello');
        });

        final chunks = await collect(
          adapter.connect!([
            {'role': 'user', 'content': 'Hello'},
          ]),
        );

        expect(called, isTrue);
        expect(chunks, hasLength(1));
        expect(chunks.single['delta'], 'Hello');
      });

      test('should pass messages and data to RPC call', () async {
        List<WireMessage>? seenMessages;
        Map<String, dynamic>? seenData;
        final adapter = rpcStream((messages, data, signal) async* {
          seenMessages = messages;
          seenData = data;
          yield finishedChunk();
        });
        final data = {'model': 'gpt-4o'};

        await collect(
          adapter.connect!(
            [
              {'role': 'user', 'content': 'Hello'},
            ],
            data: data,
          ),
        );

        expect(seenMessages, isNotNull);
        expect(seenData, data);
      });

      test('should spread supplied persistence handlers onto the adapter', () {
        final adapter = rpcStream(
          (messages, data, signal) async* {},
          StreamConnectionHandlers(
            hydrate: (threadId, {options}) async =>
                const ChatHydrationResult(messages: []),
            hydrateGeneration: (threadId) async =>
                const GenerationHydrationResult(),
            joinRun: (runId, {signal}) async* {},
          ),
        );
        expect(adapter.hydrate, isNotNull);
        expect(adapter.hydrateGeneration, isNotNull);
        expect(adapter.joinRun, isNotNull);
      });

      test('should omit persistence handlers that are not supplied', () {
        final adapter = rpcStream((messages, data, signal) async* {});
        expect(adapter.hydrate, isNull);
        expect(adapter.hydrateGeneration, isNull);
        expect(adapter.joinRun, isNull);
      });
    });

    group('hydrateGeneration', () {
      test('maps a populated body to the hydration result', () async {
        final client = FakeHttpClient(
          (_) async => jsonResponse({
            'resumeSnapshot': {
              'schemaVersion': 1,
              'resumeState': {'threadId': 't1', 'runId': 'r1'},
              'status': 'running',
            },
            'activeRun': {'runId': 'r1'},
          }),
        );
        final adapter = fetchServerSentEvents(
          '/api/generate',
          FetchConnectionOptions(client: client),
        );

        final result = await adapter.hydrateGeneration!('t1');

        expect(result.activeRun?.runId, 'r1');
        expect(result.resumeSnapshot?['status'], 'running');
        expect(client.requests.single.url.toString(), contains('threadId=t1'));
      });

      test('treats a 200 carrying null as a genuine miss', () async {
        final adapter = fetchServerSentEvents(
          '/api/generate',
          FetchConnectionOptions(
            client: FakeHttpClient((_) async => jsonResponse(null)),
          ),
        );

        final result = await adapter.hydrateGeneration!('t1');
        expect(result.resumeSnapshot, isNull);
        expect(result.activeRun, isNull);
      });

      test('rejects a non-object body instead of reporting a fresh thread',
          () async {
        final adapter = fetchServerSentEvents(
          '/api/generate',
          FetchConnectionOptions(
            client: FakeHttpClient((_) async => jsonResponse('not json')),
          ),
        );
        await expectLater(
          adapter.hydrateGeneration!('t1'),
          throwsA(
            predicate<Object>(
              (error) => error.toString().contains('expected a JSON object'),
            ),
          ),
        );

        final arrayAdapter = fetchServerSentEvents(
          '/api/generate',
          FetchConnectionOptions(
            client: FakeHttpClient((_) async => jsonResponse([])),
          ),
        );
        await expectLater(
          arrayAdapter.hydrateGeneration!('t1'),
          throwsA(
            predicate<Object>(
              (error) => error.toString().contains('an array'),
            ),
          ),
        );
      });
    });

    group('chat hydrate paging', () {
      test(
          'includes limit and before as search params when hydrate options '
          'are passed', () async {
        final client = FakeHttpClient(
          (_) async => jsonResponse({
            'messages': <Object>[],
            'activeRun': null,
            'page': {'truncated': true, 'cursor': 'c1'},
          }),
        );
        final adapter = fetchHttpStream(
          '/api/chat',
          FetchConnectionOptions(client: client),
        );

        final result = await adapter.hydrate!(
          'thread-1',
          options: const ChatHydrateOptions(limit: 50, before: 'cursor-a'),
        );

        expect(
          client.requests.single.url.toString(),
          '/api/chat?threadId=thread-1&limit=50&before=cursor-a',
        );
        expect(result.page.truncated, isTrue);
        expect(result.page.cursor, 'c1');
      });

      test('treats truncated true without a cursor as a full list', () async {
        final client = FakeHttpClient(
          (_) async => jsonResponse({
            'messages': <Object>[],
            'activeRun': null,
            'page': {'truncated': true},
          }),
        );
        final adapter = fetchHttpStream(
          '/api/chat',
          FetchConnectionOptions(client: client),
        );

        final result = await adapter.hydrate!('thread-1');
        expect(result.page.truncated, isFalse);
        expect(result.page.cursor, isNull);
      });

      test('treats a missing page as a full list', () async {
        final client = FakeHttpClient(
          (_) async => jsonResponse({
            'messages': [
              {
                'id': 'm1',
                'role': 'user',
                'parts': [
                  {'type': 'text', 'content': 'hi'},
                ],
              },
            ],
            'activeRun': null,
          }),
        );
        final adapter = fetchHttpStream(
          '/api/chat',
          FetchConnectionOptions(client: client),
        );

        final result = await adapter.hydrate!('thread-1');

        expect(client.requests.single.url.toString(),
            '/api/chat?threadId=thread-1');
        expect(result.page.truncated, isFalse);
        expect(result.messages.map((message) => message['id']), ['m1']);
      });

      test('forwards hydrate paging options through normalizeConnectionAdapter',
          () async {
        const hydration = ChatHydrationResult(messages: []);
        ChatHydrateOptions? seenOptions;
        final normalized = normalizeConnectionAdapter(
          ConnectionAdapter(
            connect: (messages, {data, signal, runContext}) async* {},
            hydrate: (threadId, {options}) async {
              seenOptions = options;
              return hydration;
            },
          ),
        );

        final result = await normalized.hydrate!(
          't1',
          options: const ChatHydrateOptions(limit: 50, before: 'c1'),
        );

        expect(result, same(hydration));
        expect(seenOptions?.limit, 50);
        expect(seenOptions?.before, 'c1');
      });
    });
  });
}
