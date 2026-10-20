// Ported from `packages/ai-client/tests/generation-client.test.ts`.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:tanstack_ai_dart/connections.dart';
import 'package:tanstack_ai_dart/generation.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const restoredImageArtifact = PersistedArtifactRef(
  role: 'output',
  artifactId: 'artifact-image-1',
  threadId: 'thread-img',
  runId: 'run-img',
  name: 'image.png',
  mimeType: 'image/png',
  size: 2048,
  createdAt: '2026-07-06T00:00:00.000Z',
  url: '/api/artifacts/artifact-image-1',
  source: PersistedArtifactSource(
    activity: 'image',
    path: 'runs/run-img/image.png',
    provider: 'test',
    model: 'test-image',
    mediaType: 'image',
  ),
);

const restoredVideoArtifact = PersistedArtifactRef(
  role: 'output',
  artifactId: 'artifact-video-1',
  threadId: 'thread-video',
  runId: 'run-video',
  name: 'clip.mp4',
  mimeType: 'video/mp4',
  size: 40960,
  createdAt: '2026-07-06T00:00:00.000Z',
  url: '/api/artifacts/artifact-video-1',
  source: PersistedArtifactSource(
    activity: 'video',
    path: 'runs/run-video/clip.mp4',
    provider: 'test',
    model: 'test-video',
    mediaType: 'video',
  ),
);

Map<String, dynamic> completedHydration() => {
      'resumeSnapshot': {
        'schemaVersion': 1,
        'resumeState': null,
        'status': 'complete',
        'result': {'id': 'result-1', 'model': 'image-model'},
      },
      'activeRun': null,
    };

ConnectionAdapter hydratingConnection(
  Map<String, dynamic> result,
) =>
    ConnectionAdapter(
      connect: (messages, {data, signal, runContext}) => const Stream.empty(),
      hydrateGeneration: (_) async => GenerationHydrationResult(
        resumeSnapshot: result['resumeSnapshot'] as Map<String, dynamic>?,
        activeRun: result['activeRun'] == null
            ? null
            : ActiveRun((result['activeRun'] as Map)['runId'] as String),
      ),
    );

void main() {
  group('GenerationClient', () {
    group('fetcher mode', () {
      test('should generate a result using fetcher', () async {
        final mockResult = {'id': '1', 'images': <Object?>[]};
        final onResult = <Object?>[];
        final onResultChange = <Object?>[];

        final client = GenerationClient(
          fetcher: (input, options) async => mockResult,
          onResult: (result) {
            onResult.add(result);
            return const GenerationTransformOutcome.raw();
          },
          onResultChange: onResultChange.add,
        );

        await client.generate({'prompt': 'test'});

        expect(onResult, [mockResult]);
        expect(onResultChange, [mockResult]);
        expect(client.getResult(), mockResult);
        expect(client.getStatus(), GenerationClientState.success);
        expect(client.getSnapshot().runId, isNull);
        expect(client.getIsLoading(), isFalse);
      });

      test('should handle fetcher errors', () async {
        final onError = <Object>[];
        final onErrorChange = <Object?>[];

        final client = GenerationClient(
          fetcher: (input, options) async {
            throw Exception('fetch failed');
          },
          onError: onError.add,
          onErrorChange: onErrorChange.add,
        );

        await client.generate({'prompt': 'test'});

        expect(onError, hasLength(1));
        expect(generationErrorMessage(onError.first), 'fetch failed');
        expect(client.getStatus(), GenerationClientState.error);
        expect(generationErrorMessage(client.getError()), 'fetch failed');
      });

      test('should track loading state during fetcher call', () async {
        final states = <bool>[];

        final client = GenerationClient(
          fetcher: (input, options) async => {'id': '1'},
          onLoadingChange: states.add,
        );

        await client.generate({'prompt': 'test'});

        expect(states, [true, false]);
      });

      test('should pass abort signal to fetcher', () async {
        GenerationFetcherOptions? captured;
        var calls = 0;

        final client = GenerationClient(
          fetcher: (input, options) async {
            calls++;
            captured = options;
            return {'id': '1'};
          },
        );

        await client.generate({'prompt': 'test'});

        expect(calls, 1);
        expect(captured, isNotNull);
        expect(captured!.signal.isCancelled, isFalse);
      });

      test('should not allow concurrent requests', () async {
        final first = Deferred<Object?>();
        var callCount = 0;

        final client = GenerationClient(
          fetcher: (input, options) async {
            callCount++;
            return first.promise;
          },
        );

        final p1 = client.generate({'prompt': 'test'});
        final p2 = client.generate({'prompt': 'test2'});

        first.resolve({'id': '1'});
        await p1;
        await p2;

        expect(callCount, 1);
      });
    });

    group('connection mode', () {
      test('should process stream and extract result from CUSTOM event',
          () async {
        final mockResult = {
          'id': '1',
          'images': [
            {'url': 'http://example.com/img.png'}
          ],
        };
        final onResult = <Object?>[];

        final connection = mockConnection([
          runStarted('run-1'),
          custom(GenerationEvents.result, mockResult),
          runFinished('run-1'),
        ]);

        final client = GenerationClient(
          connection: connection,
          onResult: (result) {
            onResult.add(result);
            return const GenerationTransformOutcome.raw();
          },
        );

        await client.generate({'prompt': 'test'});

        expect(onResult, [mockResult]);
        expect(client.getResult(), mockResult);
        expect(client.getStatus(), GenerationClientState.success);
      });

      test('keeps the local run id when a stream chunk has no resume pointer',
          () async {
        final gate = Deferred<bool>();
        final chunks = [
          custom(GenerationEvents.progress, {'percent': 1}),
          runStarted('run-1'),
          custom(GenerationEvents.result, {'id': '1'}),
          runFinished('run-1'),
        ];
        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            yield chunks[0];
            await gate.promise;
            for (final chunk in chunks.skip(1)) {
              yield chunk;
            }
          },
        );

        final client = GenerationClient(connection: connection);
        final pending = client.generate({'prompt': 'test'});
        await waitForCondition(() {
          expect(client.getSnapshot().isLoading, isTrue);
        });
        expect(client.getSnapshot().runId, isNotNull);
        expect(client.getSnapshot().runId, isNotEmpty);
        gate.resolve(true);
        await pending;
        expect(client.getSnapshot().runId, isNull);
      });

      test('should handle RUN_ERROR from stream', () async {
        final onError = <Object>[];

        final connection = mockConnection([
          runStarted('run-1'),
          {
            'type': 'RUN_ERROR',
            'message': 'Generation failed',
            'runId': 'run-1',
            'error': {'message': 'Generation failed'},
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          },
        ]);

        final client = GenerationClient(
          connection: connection,
          onError: onError.add,
        );

        await client.generate({'prompt': 'test'});

        expect(onError, hasLength(1));
        expect(client.getStatus(), GenerationClientState.error);
        expect(generationErrorMessage(client.getError()), 'Generation failed');
        expect(client.getSnapshot().runId, isNull);
      });

      test('should report progress from CUSTOM progress events', () async {
        final progress = <List<Object?>>[];

        final connection = mockConnection([
          runStarted('run-1'),
          custom(GenerationEvents.progress, {
            'progress': 50,
            'message': 'Halfway',
          }),
          custom(GenerationEvents.result, {'id': '1'}),
          runFinished('run-1'),
        ]);

        final client = GenerationClient(
          connection: connection,
          onProgress: (value, message) => progress.add([value, message]),
        );

        await client.generate({'prompt': 'test'});

        expect(progress, [
          [50, 'Halfway']
        ]);
      });

      test('should call onChunk for each stream chunk', () async {
        final chunks = <StreamChunk>[];

        final connection = mockConnection([
          runStarted('run-1'),
          custom(GenerationEvents.result, {'id': '1'}),
          runFinished('run-1'),
        ]);

        final client = GenerationClient(
          connection: connection,
          onChunk: chunks.add,
        );

        await client.generate({'prompt': 'test'});

        expect(chunks, hasLength(3));
      });

      test('should pass body and input as data to connection', () async {
        final calls = <Map<String, dynamic>?>[];
        RunAgentInputContext? context;

        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            calls.add(data);
            context = runContext;
            yield custom(GenerationEvents.result, {'id': '1'});
            yield runFinished('run-1');
          },
        );

        final client = GenerationClient(
          connection: connection,
          body: {'model': 'dall-e-3'},
        );

        await client.generate({'prompt': 'sunset', 'size': '1024x1024'});

        expect(calls.single, {
          'model': 'dall-e-3',
          'prompt': 'sunset',
          'size': '1024x1024',
        });
        expect(context?.threadId, matches(RegExp(r'^generation-')));
        expect(context?.runId, isNotEmpty);
      });
    });

    test('plugs fetchServerSentEvents into the client without conversion',
        () async {
      final body = [
        jsonEncode(runStarted('run-http', 'thread-http')),
        jsonEncode(custom(GenerationEvents.result, {'id': 'http-result'})),
        jsonEncode(runFinished('run-http', 'thread-http')),
      ].map((line) => 'data: $line\n\n').join();
      final client = GenerationClient(
        connection: fetchServerSentEvents(
          'https://example.com/generate',
          FetchConnectionOptions(client: _FakeHttpClient(body)),
        ),
      );

      await client.generate({'prompt': 'http'});

      expect(client.getStatus(), GenerationClientState.success);
      expect(client.getResult(), {'id': 'http-result'});
    });

    group('stop()', () {
      test('should abort in-flight request and reset to idle', () async {
        final pending = Deferred<Object?>();

        final client = GenerationClient(
          fetcher: (input, options) async => pending.promise,
        );

        final generatePromise = client.generate({'prompt': 'test'});
        expect(client.getIsLoading(), isTrue);
        expect(client.getSnapshot().runId, isNotNull);

        client.stop();
        expect(client.getIsLoading(), isFalse);
        expect(client.getStatus(), GenerationClientState.idle);
        expect(client.getSnapshot().runId, isNull);

        pending.resolve({'id': '1'});
        await generatePromise;
      });
    });

    group('reset()', () {
      test('should clear result, error, and return to idle', () async {
        final client = GenerationClient(
          fetcher: (input, options) async => {'id': '1'},
        );

        await client.generate({'prompt': 'test'});
        expect(client.getResult(), {'id': '1'});
        expect(client.getStatus(), GenerationClientState.success);

        client.reset();
        expect(client.getResult(), isNull);
        expect(client.getError(), isNull);
        expect(client.getStatus(), GenerationClientState.idle);
        expect(client.getSnapshot().runId, isNull);
      });
    });

    group('updateOptions()', () {
      test('should update body without recreating client', () async {
        final calls = <Map<String, dynamic>?>[];
        RunAgentInputContext? context;
        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            calls.add(data);
            context = runContext;
            yield runFinished('run-1');
          },
        );

        final client = GenerationClient(
          connection: connection,
          body: {'model': 'old'},
        );

        client.updateOptions(body: {'model': 'new'});
        await client.generate({'prompt': 'test'});

        expect(calls.single, {'model': 'new', 'prompt': 'test'});
        expect(context?.threadId, matches(RegExp(r'^generation-')));
        expect(context?.runId, isNotEmpty);
      });
    });

    group('abort handling', () {
      test('should not set result if aborted mid-stream', () async {
        final onResult = <Object?>[];
        final aborted = Deferred<bool>();

        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            yield runStarted('run-1');
            signal?.addListener(() => aborted.resolve(true));
            await aborted.promise;
            if (signal?.isCancelled ?? false) return;
            yield custom(GenerationEvents.result, {'id': '1'});
          },
        );

        final client = GenerationClient(
          connection: connection,
          onResult: (result) {
            onResult.add(result);
            return const GenerationTransformOutcome.raw();
          },
        );

        final generatePromise = client.generate({'prompt': 'test'});
        await Future<void>.delayed(Duration.zero);

        client.stop();
        await generatePromise;

        expect(onResult, isEmpty);
        expect(client.getResult(), isNull);
        expect(client.getStatus(), GenerationClientState.idle);
      });

      test(
          'should ignore chunks yielded after stop() by an abort-ignoring connection',
          () async {
        final onResult = <Object?>[];
        final aborted = Deferred<bool>();

        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            yield runStarted('run-1');
            signal?.addListener(() => aborted.resolve(true));
            await aborted.promise;
            yield custom(GenerationEvents.result, {'id': 'late-result'});
            yield runFinished('run-1');
          },
        );

        final client = GenerationClient(
          connection: connection,
          onResult: (result) {
            onResult.add(result);
            return const GenerationTransformOutcome.raw();
          },
        );

        final generatePromise = client.generate({'prompt': 'test'});
        await Future<void>.delayed(Duration.zero);

        client.stop();
        await generatePromise;

        expect(onResult, isEmpty);
        expect(client.getResult(), isNull);
        expect(client.getStatus(), GenerationClientState.idle);
      });

      test(
          'should not let a stopped run clear the controller for a newer generation',
          () async {
        final firstAborted = Deferred<bool>();
        final firstCanFinish = Deferred<bool>();
        final secondAborted = Deferred<bool>();
        final signals = <CancellationSignal?>[];

        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            signals.add(signal);
            if (data?['prompt'] == 'first') {
              yield runStarted('run-1');
              signal?.addListener(() => firstAborted.resolve(true));
              await firstAborted.promise;
              await firstCanFinish.promise;
              yield custom(GenerationEvents.result, {'id': 'late-first'});
              return;
            }
            yield runStarted('run-2');
            signal?.addListener(() => secondAborted.resolve(true));
            await secondAborted.promise;
          },
        );

        final client = GenerationClient(connection: connection);

        final firstGenerate = client.generate({'prompt': 'first'});
        await waitForCondition(() {
          expect(signals, hasLength(1));
        });

        client.stop();
        final secondGenerate = client.generate({'prompt': 'second'});
        await waitForCondition(() {
          expect(signals, hasLength(2));
          expect(client.getIsLoading(), isTrue);
          expect(client.getSnapshot().runId, 'run-2');
        });

        firstCanFinish.resolve(true);
        await firstGenerate;

        expect(client.getIsLoading(), isTrue);
        expect(client.getSnapshot().runId, 'run-2');

        client.stop();
        expect(signals[1]?.isCancelled, isTrue);

        await secondGenerate;
        expect(client.getIsLoading(), isFalse);
      });

      test(
          'should ignore video chunks yielded after stop() by an abort-ignoring connection',
          () async {
        final onResult = <Object?>[];
        final onStatusUpdate = <VideoStatusInfo>[];
        final aborted = Deferred<bool>();

        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            yield runStarted('run-1');
            signal?.addListener(() => aborted.resolve(true));
            await aborted.promise;
            yield custom(GenerationEvents.result, {'id': 'late-video'});
            yield custom(GenerationEvents.videoStatus, {
              'status': 'completed',
              'progress': 100,
            });
            yield runFinished('run-1');
          },
        );

        final client = VideoGenerationClient<VideoGenerateResult>(
          connection: connection,
          onResult: (result) {
            onResult.add(result);
            return const GenerationTransformOutcome.raw();
          },
          onStatusUpdate: onStatusUpdate.add,
        );

        final generatePromise =
            client.generate(const VideoGenerateInput(prompt: 'test'));
        await Future<void>.delayed(Duration.zero);

        client.stop();
        await generatePromise;

        expect(onResult, isEmpty);
        expect(onStatusUpdate, isEmpty);
        expect(client.getResult(), isNull);
        expect(client.getVideoStatus(), isNull);
        expect(client.getStatus(), GenerationClientState.idle);
      });

      test(
          'should not let a stopped video run clear the controller for a newer generation',
          () async {
        final firstAborted = Deferred<bool>();
        final firstCanFinish = Deferred<bool>();
        final secondAborted = Deferred<bool>();
        final signals = <CancellationSignal?>[];

        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            signals.add(signal);
            if (data?['prompt'] == 'first') {
              yield runStarted('run-1');
              signal?.addListener(() => firstAborted.resolve(true));
              await firstAborted.promise;
              await firstCanFinish.promise;
              yield custom(GenerationEvents.result, {
                'jobId': 'late-first',
                'status': 'completed',
                'url': 'https://example.com/late.mp4',
              });
              return;
            }
            yield runStarted('run-2');
            signal?.addListener(() => secondAborted.resolve(true));
            await secondAborted.promise;
          },
        );

        final client =
            VideoGenerationClient<VideoGenerateResult>(connection: connection);

        final firstGenerate =
            client.generate(const VideoGenerateInput(prompt: 'first'));
        await waitForCondition(() {
          expect(signals, hasLength(1));
        });

        client.stop();
        final secondGenerate =
            client.generate(const VideoGenerateInput(prompt: 'second'));
        await waitForCondition(() {
          expect(signals, hasLength(2));
          expect(client.getIsLoading(), isTrue);
          expect(client.getSnapshot().runId, 'run-2');
        });

        firstCanFinish.resolve(true);
        await firstGenerate;

        expect(client.getIsLoading(), isTrue);
        expect(client.getSnapshot().runId, 'run-2');

        client.stop();
        expect(signals[1]?.isCancelled, isTrue);

        await secondGenerate;
        expect(client.getIsLoading(), isFalse);
      });

      test('should not set result if fetcher resolves after stop()', () async {
        final pending = Deferred<Object?>();
        final onResult = <Object?>[];

        final client = GenerationClient(
          fetcher: (input, options) async => pending.promise,
          onResult: (result) {
            onResult.add(result);
            return const GenerationTransformOutcome.raw();
          },
        );

        final generatePromise = client.generate({'prompt': 'test'});
        client.stop();
        pending.resolve({'id': '1'});
        await generatePromise;

        expect(onResult, isEmpty);
        expect(client.getResult(), isNull);
      });
    });

    group('error wrapping', () {
      test('should wrap non-Error thrown values in Error', () async {
        final onError = <Object>[];

        final client = GenerationClient(
          fetcher: (input, options) async {
            throw 'string error';
          },
          onError: onError.add,
        );

        await client.generate({'prompt': 'test'});

        expect(onError, hasLength(1));
        expect(generationErrorMessage(onError.first), 'string error');
        expect(generationErrorMessage(client.getError()), 'string error');
      });

      test('should throw if neither connection nor fetcher is provided',
          () async {
        final onError = <Object>[];

        final client = GenerationClient(onError: onError.add);

        await client.generate({'prompt': 'test'});

        expect(onError, hasLength(1));
        expect(
          generationErrorMessage(client.getError()),
          'GenerationClient requires either a connection or fetcher option',
        );
      });
    });

    group('stream edge cases', () {
      test(
          'should finish with success but null result if stream has no result event',
          () async {
        final onResult = <Object?>[];

        final connection = mockConnection([
          runStarted('run-1'),
          runFinished('run-1'),
        ]);

        final client = GenerationClient(
          connection: connection,
          onResult: (result) {
            onResult.add(result);
            return const GenerationTransformOutcome.raw();
          },
        );

        await client.generate({'prompt': 'test'});

        expect(client.getStatus(), GenerationClientState.success);
        expect(client.getResult(), isNull);
        expect(onResult, isEmpty);
      });

      test('should ignore unknown CUSTOM event names and still call onChunk',
          () async {
        final chunks = <StreamChunk>[];

        final connection = mockConnection([
          runStarted('run-1'),
          custom('unknown:event', {'foo': 'bar'}),
          runFinished('run-1'),
        ]);

        final client = GenerationClient(
          connection: connection,
          onChunk: chunks.add,
        );

        await client.generate({'prompt': 'test'});

        expect(chunks, hasLength(3));
        expect(client.getStatus(), GenerationClientState.success);
        expect(client.getResult(), isNull);
      });
    });

    group('sequential generation', () {
      test('should allow a second generation after the first completes',
          () async {
        var callCount = 0;

        final client = GenerationClient(
          fetcher: (input, options) async {
            callCount++;
            return {'id': '$callCount'};
          },
        );

        await client.generate({'prompt': 'first'});
        expect(client.getResult(), {'id': '1'});
        expect(client.getStatus(), GenerationClientState.success);

        await client.generate({'prompt': 'second'});
        expect(client.getResult(), {'id': '2'});
        expect(client.getStatus(), GenerationClientState.success);
        expect(callCount, 2);
      });
    });

    group('onResult transform', () {
      test(
          'should transform result when onResult returns a non-null value (fetcher)',
          () async {
        final onResultChange = <Object?>[];

        final client = GenerationClient(
          fetcher: (input, options) async => {'id': '1'},
          onResult: (raw) =>
              GenerationTransformOutcome.value({'transformed': true}),
          onResultChange: onResultChange.add,
        );

        await client.generate({'prompt': 'test'});

        expect(client.getResult(), {'transformed': true});
        expect(onResultChange, [
          {'transformed': true}
        ]);
        expect(client.getStatus(), GenerationClientState.success);
      });

      test('should keep previous result when onResult returns null', () async {
        final onResultChange = <Object?>[];

        final client = GenerationClient(
          fetcher: (input, options) async => {'id': '1'},
          onResult: (raw) => const GenerationTransformOutcome.keep(),
          onResultChange: onResultChange.add,
        );

        await client.generate({'prompt': 'test'});

        expect(client.getResult(), isNull);
        expect(onResultChange, isEmpty);
        expect(client.getStatus(), GenerationClientState.success);
      });

      test('should use raw result when onResult returns void', () async {
        final onResult = <Object?>[];

        final client = GenerationClient(
          fetcher: (input, options) async => {'id': '1', 'data': 'test'},
          onResult: (raw) {
            onResult.add(raw);
            return const GenerationTransformOutcome.raw();
          },
        );

        await client.generate({'prompt': 'test'});

        expect(onResult, [
          {'id': '1', 'data': 'test'}
        ]);
        expect(client.getResult(), {'id': '1', 'data': 'test'});
      });

      test('should transform result from stream CUSTOM event', () async {
        final connection = mockConnection([
          runStarted('run-1'),
          custom(GenerationEvents.result, {'id': '1', 'images': <Object?>[]}),
          runFinished('run-1'),
        ]);

        final client = GenerationClient(
          connection: connection,
          onResult: (raw) => GenerationTransformOutcome.value({
            'imageCount': ((raw as Map)['images'] as List).length,
          }),
        );

        await client.generate({'prompt': 'test'});

        expect(client.getResult(), {'imageCount': 0});
      });

      test('should reset transformed result to null on reset()', () async {
        final client = GenerationClient(
          fetcher: (input, options) async => {'id': '1'},
          onResult: (raw) =>
              GenerationTransformOutcome.value({'transformed': true}),
        );

        await client.generate({'prompt': 'test'});
        expect(client.getResult(), {'transformed': true});

        client.reset();
        expect(client.getResult(), isNull);
      });

      test(
          'should keep previous transformed result on second generation when onResult returns null',
          () async {
        var callCount = 0;
        final client = GenerationClient(
          fetcher: (input, options) async {
            callCount++;
            return {'id': '$callCount'};
          },
          onResult: (raw) => (raw as Map)['id'] == '1'
              ? const GenerationTransformOutcome.value({'transformed': 'first'})
              : const GenerationTransformOutcome.keep(),
        );

        await client.generate({'prompt': 'first'});
        expect(client.getResult(), {'transformed': 'first'});

        await client.generate({'prompt': 'second'});
        expect(client.getResult(), {'transformed': 'first'});
      });
    });

    group('fetcher returning Response (SSE stream)', () {
      test('should parse SSE Response and extract result from CUSTOM event',
          () async {
        final mockResult = {
          'id': '1',
          'images': [
            {'url': 'http://example.com'}
          ],
        };
        final onResult = <Object?>[];

        final response = sseResponse([
          jsonEncode(runStarted('run-1')),
          jsonEncode(custom(GenerationEvents.result, mockResult)),
          jsonEncode(runFinished('run-1')),
        ]);

        final client = GenerationClient(
          fetcher: (input, options) async => response,
          onResult: (result) {
            onResult.add(result);
            return const GenerationTransformOutcome.raw();
          },
        );

        await client.generate({'prompt': 'test'});

        expect(onResult, [mockResult]);
        expect(client.getResult(), mockResult);
        expect(client.getStatus(), GenerationClientState.success);
      });

      test(
          'should parse SSE Response data frames without a space after the colon',
          () async {
        final mockResult = {
          'id': '1',
          'images': [
            {'url': 'http://example.com'}
          ],
        };
        final onResult = <Object?>[];

        final response = sseResponse(
          [
            jsonEncode(custom(GenerationEvents.result, mockResult)),
            jsonEncode(runFinished('run-1')),
          ],
          spaceAfterDataColon: false,
        );

        final client = GenerationClient(
          fetcher: (input, options) async => response,
          onResult: (result) {
            onResult.add(result);
            return const GenerationTransformOutcome.raw();
          },
        );

        await client.generate({'prompt': 'test'});

        expect(onResult, [mockResult]);
        expect(client.getResult(), mockResult);
        expect(client.getStatus(), GenerationClientState.success);
      });

      test('should handle RUN_ERROR from SSE Response', () async {
        final onError = <Object>[];

        final response = sseResponse([
          jsonEncode(runStarted('run-1')),
          jsonEncode({
            'type': 'RUN_ERROR',
            'message': 'Generation failed',
            'runId': 'run-1',
            'error': {'message': 'Generation failed'},
            'timestamp': 200,
          }),
        ]);

        final client = GenerationClient(
          fetcher: (input, options) async => response,
          onError: onError.add,
        );

        await client.generate({'prompt': 'test'});

        expect(onError, hasLength(1));
        expect(client.getStatus(), GenerationClientState.error);
        expect(generationErrorMessage(client.getError()), 'Generation failed');
      });

      test('should call onChunk for each SSE chunk from Response', () async {
        final chunks = <StreamChunk>[];

        final response = sseResponse([
          jsonEncode(runStarted('run-1')),
          jsonEncode(custom(GenerationEvents.result, {'id': '1'})),
          jsonEncode(runFinished('run-1')),
        ]);

        final client = GenerationClient(
          fetcher: (input, options) async => response,
          onChunk: chunks.add,
        );

        await client.generate({'prompt': 'test'});

        expect(chunks, hasLength(3));
      });

      test('should report progress from SSE Response stream', () async {
        final progress = <List<Object?>>[];

        final response = sseResponse([
          jsonEncode(runStarted('run-1')),
          jsonEncode(custom(GenerationEvents.progress, {
            'progress': 50,
            'message': 'Halfway',
          })),
          jsonEncode(custom(GenerationEvents.result, {'id': '1'})),
          jsonEncode(runFinished('run-1')),
        ]);

        final client = GenerationClient(
          fetcher: (input, options) async => response,
          onProgress: (value, message) => progress.add([value, message]),
        );

        await client.generate({'prompt': 'test'});

        expect(progress, [
          [50, 'Halfway']
        ]);
      });

      test('should handle HTTP error Response from fetcher', () async {
        final onError = <Object>[];

        const errorResponse = GenerationResponse(
          statusCode: 500,
          reasonPhrase: 'Internal Server Error',
        );

        final client = GenerationClient(
          fetcher: (input, options) async => errorResponse,
          onError: onError.add,
        );

        await client.generate({'prompt': 'test'});

        expect(onError, hasLength(1));
        expect(client.getStatus(), GenerationClientState.error);
        expect(generationErrorMessage(client.getError()), contains('500'));
      });

      test(
          'should surface unsupported streaming from a fetcher-returned Response',
          () async {
        final onError = <Object>[];
        const response = GenerationResponse(statusCode: 200);

        final client = GenerationClient(
          fetcher: (input, options) async => response,
          onError: onError.add,
        );

        await client.generate({'prompt': 'test'});

        expect(onError.single, isA<UnsupportedResponseStreamError>());
        expect(
          (client.getError() as UnsupportedResponseStreamError).missingFeature,
          'Response.body',
        );
        expect(client.getStatus(), GenerationClientState.error);
      });

      test('should pass input type-safely (fetcher receives typed input)',
          () async {
        GenerationFetcherOptions? captured;
        final response = sseResponse([
          jsonEncode(custom(GenerationEvents.result, {'id': '1'})),
          jsonEncode(runFinished('run-1')),
        ]);

        final client = GenerationClient(
          fetcher: (input, options) async {
            captured = options;
            return response;
          },
        );

        await client.generate({'prompt': 'sunset'});

        expect(captured, isNotNull);
        expect(client.getResult(), {'id': '1'});
      });
    });

    group('state transitions', () {
      test('should follow idle -> generating -> success', () async {
        final states = <GenerationClientState>[];

        final client = GenerationClient(
          fetcher: (input, options) async => {'id': '1'},
          onStatusChange: states.add,
        );

        expect(client.getStatus(), GenerationClientState.idle);
        await client.generate({'prompt': 'test'});

        expect(states, [
          GenerationClientState.generating,
          GenerationClientState.success,
        ]);
      });

      test('should follow idle -> generating -> error on failure', () async {
        final states = <GenerationClientState>[];

        final client = GenerationClient(
          fetcher: (input, options) async {
            throw Exception('fail');
          },
          onStatusChange: states.add,
        );

        await client.generate({'prompt': 'test'});

        expect(states, [
          GenerationClientState.generating,
          GenerationClientState.error,
        ]);
      });
    });

    group('server-driven persistence (persistence: true)', () {
      test(
          'adopts the server snapshot on mount, keyed by threadId, without a local store',
          () async {
        final hydrateCalls = <String>[];
        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) =>
              const Stream.empty(),
          hydrateGeneration: (threadId) async {
            hydrateCalls.add(threadId);
            return GenerationHydrationResult(
              resumeSnapshot: (completedHydration()['resumeSnapshot']
                  as Map<String, dynamic>),
            );
          },
        );
        final snapshots = <GenerationResumeSnapshot?>[];
        final client = GenerationClient(
          threadId: 'thread-server',
          connection: connection,
          persistence: true,
          onResumeSnapshotChange: snapshots.add,
        );
        client.mountDevtools();

        await waitForCondition(() {
          expect(client.getResumeSnapshot()?.status,
              GenerationResumeStatus.complete);
        });
        expect(hydrateCalls, ['thread-server']);
        expect(client.getResumeSnapshot()?.result?.id, 'result-1');
        expect(
          snapshots.where((snapshot) =>
              snapshot?.status == GenerationResumeStatus.complete),
          isNotEmpty,
        );
      });

      test('reuses the stable threadId for hydration and wire runs', () async {
        final hydrateCalls = <String>[];
        final runThreadIds = <String>[];
        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            if (runContext != null) runThreadIds.add(runContext.threadId);
            yield runStarted('run-1', 'thread-stable');
            yield runFinished('run-1', 'thread-stable');
          },
          hydrateGeneration: (threadId) async {
            hydrateCalls.add(threadId);
            return const GenerationHydrationResult();
          },
        );
        final client = GenerationClient(
          threadId: 'thread-stable',
          connection: connection,
          persistence: true,
        );
        client.mountDevtools();

        await waitForCondition(() {
          expect(hydrateCalls, ['thread-stable']);
        });
        await client.generate({'prompt': 'first'});
        await client.generate({'prompt': 'second'});

        expect(hydrateCalls, ['thread-stable']);
        expect(runThreadIds, ['thread-stable', 'thread-stable']);
      });

      test(
          'repaints result from the server snapshot via reconstructResult (image)',
          () async {
        final connection = hydratingConnection({
          'resumeSnapshot': {
            'schemaVersion': 1,
            'resumeState': null,
            'status': 'complete',
            'activity': 'image',
            'result': {
              'id': 'srv-img',
              'model': 'test-image',
              'artifacts': [restoredImageArtifact.toJson()],
            },
          },
          'activeRun': null,
        });
        final resumeStates = <GenerationResumeState?>[];
        final client = GenerationClient(
          threadId: 'thread-img-server',
          connection: connection,
          persistence: true,
          reconstructResult: reconstructImageResult,
          onResumeStateChange: resumeStates.add,
        );
        client.mountDevtools();

        await waitForCondition(() {
          expect(client.getResult(), {
            'id': 'srv-img',
            'model': 'test-image',
            'images': [
              {'url': '/api/artifacts/artifact-image-1'}
            ],
            'artifacts': [restoredImageArtifact.toJson()],
          });
        });
        expect(client.getStatus(), GenerationClientState.success);
        expect(resumeStates.last, isNull);
      });

      test(
          'rejoins an in-flight run reported by the server and finishes it in place',
          () async {
        const runId = 'run-live-1';
        final chunks = [
          runStarted(runId, 'thread-live'),
          custom(GenerationEvents.result, {
            'id': 'live-img',
            'model': 'test-image',
            'images': [
              {'url': '/live.png'}
            ],
          }),
          runFinished(runId, 'thread-live'),
        ];
        final joinCalls = <String>[];
        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) =>
              const Stream.empty(),
          hydrateGeneration: (threadId) async => GenerationHydrationResult(
            resumeSnapshot: {
              'schemaVersion': 1,
              'resumeState': {'threadId': 'thread-live', 'runId': runId},
              'status': 'running',
            },
            activeRun: const ActiveRun(runId),
          ),
          joinRun: (runId, {signal}) async* {
            joinCalls.add(runId);
            for (final chunk in chunks) {
              yield chunk;
            }
          },
        );
        final client = GenerationClient(
          threadId: 'thread-live',
          connection: connection,
          persistence: true,
        );
        client.mountDevtools();

        await waitForCondition(() {
          expect(client.getStatus(), GenerationClientState.success);
          expect((client.getResult() as Map?)?['id'], 'live-img');
        });
        expect(joinCalls, [runId]);
        expect(client.getIsLoading(), isFalse);
        expect(client.getSnapshot().runId, isNull);
      });

      test(
          'surfaces an error (never stays stuck generating) when the rejoin throws',
          () async {
        const runId = 'run-gone-1';
        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) =>
              const Stream.empty(),
          hydrateGeneration: (threadId) async => GenerationHydrationResult(
            resumeSnapshot: {
              'schemaVersion': 1,
              'resumeState': {'threadId': 'thread-gone', 'runId': runId},
              'status': 'running',
            },
            activeRun: const ActiveRun(runId),
          ),
          joinRun: (runId, {signal}) async* {
            throw Exception('Unknown or expired memory stream run');
          },
        );
        final client = GenerationClient(
          threadId: 'thread-gone',
          connection: connection,
          persistence: true,
        );
        client.mountDevtools();

        await waitForCondition(() {
          expect(client.getStatus(), GenerationClientState.error);
        });
        expect(client.getIsLoading(), isFalse);
        expect(generationErrorMessage(client.getError()), contains('expired'));
      });

      test(
          'surfaces an error when the rejoin delivers a terminal RUN_ERROR chunk',
          () async {
        const runId = 'run-gone-2';
        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) =>
              const Stream.empty(),
          hydrateGeneration: (threadId) async => GenerationHydrationResult(
            resumeSnapshot: {
              'schemaVersion': 1,
              'resumeState': {'threadId': 'thread-gone-2', 'runId': runId},
              'status': 'running',
            },
            activeRun: const ActiveRun(runId),
          ),
          joinRun: (runId, {signal}) async* {
            yield runStarted(runId, 'thread-gone-2');
            yield {
              'type': 'RUN_ERROR',
              'message': 'Memory stream run produced no data within 100ms',
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            };
          },
        );
        final client = GenerationClient(
          threadId: 'thread-gone-2',
          connection: connection,
          persistence: true,
        );
        client.mountDevtools();

        await waitForCondition(() {
          expect(client.getStatus(), GenerationClientState.error);
        });
        expect(client.getIsLoading(), isFalse);
        expect(generationErrorMessage(client.getError()), contains('no data'));
      });

      test('does nothing when the connection exposes no hydrateGeneration',
          () async {
        final client = GenerationClient(
          threadId: 'thread-server',
          connection: mockConnection([]),
          persistence: true,
        );

        await Future<void>.delayed(Duration.zero);
        expect(client.getResumeSnapshot(), isNull);
      });

      test('ignores an invalid server snapshot without throwing', () async {
        final connection = hydratingConnection({
          'resumeSnapshot': {'resumeState': null, 'status': 'bogus'},
          'activeRun': null,
        });
        final client = GenerationClient(
          threadId: 'thread-server',
          connection: connection,
          persistence: true,
        );

        await Future<void>.delayed(Duration.zero);
        expect(client.getResumeSnapshot(), isNull);
      });

      test(
          'does not stomp a run that a generate() started before hydration resolves',
          () async {
        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            yield runStarted('run-live', 'thread-server');
            yield runFinished('run-live', 'thread-server');
          },
          hydrateGeneration: (_) async => GenerationHydrationResult(
            resumeSnapshot: (completedHydration()['resumeSnapshot']
                as Map<String, dynamic>),
          ),
        );
        final client = GenerationClient(
          threadId: 'thread-server',
          connection: connection,
          persistence: true,
        );

        await client.generate({'prompt': 'test'});
        await Future<void>.delayed(Duration.zero);

        expect(client.getStatus(), GenerationClientState.success);
        expect(client.getResumeSnapshot()?.status,
            GenerationResumeStatus.complete);
        expect(client.getResumeSnapshot()?.result?.id, isNull);
      });

      test('adopts the server snapshot for the video client too', () async {
        final hydrateCalls = <String>[];
        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) =>
              const Stream.empty(),
          hydrateGeneration: (threadId) async {
            hydrateCalls.add(threadId);
            return GenerationHydrationResult(
              resumeSnapshot: {
                'schemaVersion': 1,
                'resumeState': null,
                'status': 'complete',
                'activity': 'video',
                'result': {
                  'id': 'srv-video',
                  'model': 'test-video',
                  'providerJobId': 'job-7',
                  'artifacts': [restoredVideoArtifact.toJson()],
                },
              },
            );
          },
        );
        final client = VideoGenerationClient<VideoGenerateResult>(
          threadId: 'thread-video',
          connection: connection,
          persistence: true,
        );
        client.mountDevtools();

        await waitForCondition(() {
          expect(client.getResumeSnapshot()?.status,
              GenerationResumeStatus.complete);
        });
        expect(hydrateCalls, ['thread-video']);
        expect(client.getStatus(), GenerationClientState.success);
        expect(client.getResult()?.jobId, 'job-7');
        expect(client.getResult()?.status, 'completed');
        expect(client.getResult()?.url, '/api/artifacts/artifact-video-1');
        expect(client.getJobId(), 'job-7');
      });

      test(
          'hydrates via the hydrateGeneration option in fetcher mode (no connection)',
          () async {
        final hydrateCalls = <String>[];
        final client = GenerationClient(
          threadId: 'thread-server',
          fetcher: (input, options) async => <String, dynamic>{},
          persistence: true,
          hydrateGeneration: (threadId) async {
            hydrateCalls.add(threadId);
            return GenerationHydrationResult(
              resumeSnapshot: (completedHydration()['resumeSnapshot']
                  as Map<String, dynamic>),
            );
          },
        );
        client.mountDevtools();

        await waitForCondition(() {
          expect(client.getResumeSnapshot()?.status,
              GenerationResumeStatus.complete);
        });
        expect(hydrateCalls, ['thread-server']);
      });

      test(
          'rejoins an in-flight run via the joinRun option when the connection lacks one',
          () async {
        const runId = 'run-option-1';
        final joinCalls = <String>[];
        final client = GenerationClient(
          threadId: 'thread-option',
          connection: mockConnection([]),
          persistence: true,
          hydrateGeneration: (threadId) async => GenerationHydrationResult(
            resumeSnapshot: {
              'schemaVersion': 1,
              'resumeState': {'threadId': 'thread-option', 'runId': runId},
              'status': 'running',
            },
            activeRun: const ActiveRun(runId),
          ),
          joinRun: (runId, {signal}) async* {
            joinCalls.add(runId);
            yield runStarted(runId, 'thread-option');
            yield custom(GenerationEvents.result, {'id': 'option-img'});
            yield runFinished(runId, 'thread-option');
          },
        );
        client.mountDevtools();

        await waitForCondition(() {
          expect(client.getStatus(), GenerationClientState.success);
          expect((client.getResult() as Map?)?['id'], 'option-img');
        });
        expect(joinCalls, [runId]);
        expect(client.getIsLoading(), isFalse);
      });

      test('warns only when persistence: true has no hydrate source at all',
          () async {
        final messages = <String>[];
        await runZoned(
          () async {
            GenerationClient(
              threadId: 'thread-warn',
              fetcher: (input, options) async => <String, dynamic>{},
              persistence: true,
            ).mountDevtools();
          },
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => messages.add(line),
          ),
        );
        expect(messages.join('\n'), contains('`persistence: true`'));
        messages.clear();

        await runZoned(
          () async {
            GenerationClient(
              threadId: 'thread-warn',
              fetcher: (input, options) async => <String, dynamic>{},
              persistence: true,
              hydrateGeneration: (_) async => const GenerationHydrationResult(),
            ).mountDevtools();
            await Future<void>.delayed(Duration.zero);
          },
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => messages.add(line),
          ),
        );
        expect(messages.join('\n'), isNot(contains('`persistence: true`')));
      });

      test(
          'repaints a running server snapshot with no joinRun available as an interrupted error',
          () async {
        const runId = 'run-stranded';
        final connection = hydratingConnection({
          'resumeSnapshot': {
            'schemaVersion': 1,
            'resumeState': {'threadId': 'thread-stranded', 'runId': runId},
            'status': 'running',
          },
          'activeRun': {'runId': runId},
        });
        final client = GenerationClient(
          threadId: 'thread-stranded',
          connection: connection,
          persistence: true,
        );
        client.mountDevtools();

        await waitForCondition(() {
          expect(client.getStatus(), GenerationClientState.error);
        });
        expect(client.getIsLoading(), isFalse);
        expect(generationErrorMessage(client.getError()),
            matches(RegExp('interrupted')));
        expect(
            client.getResumeSnapshot()?.status, GenerationResumeStatus.error);
        expect(client.getResumeSnapshot()?.resumeState, isNull);
      });

      test(
          'surfaces a hydration transport failure instead of looking like a fresh thread',
          () async {
        final errors = <Object>[];
        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) =>
              const Stream.empty(),
          hydrateGeneration: (_) async {
            throw Exception('403 Forbidden');
          },
        );
        final client = GenerationClient(
          threadId: 'thread-denied',
          connection: connection,
          persistence: true,
          onError: errors.add,
        );
        client.mountDevtools();

        await waitForCondition(() {
          expect(client.getStatus(), GenerationClientState.error);
        });
        expect(generationErrorMessage(client.getError()),
            contains('403 Forbidden'));
        expect(errors, hasLength(1));
        expect(client.getIsLoading(), isFalse);
      });

      test(
          'stays silent for a genuine hydration miss (no record for the thread)',
          () async {
        final errors = <Object>[];
        final connection = hydratingConnection({
          'resumeSnapshot': null,
          'activeRun': null,
        });
        final client = GenerationClient(
          threadId: 'thread-fresh',
          connection: connection,
          persistence: true,
          onError: errors.add,
        );
        client.mountDevtools();

        await Future<void>.delayed(Duration.zero);
        expect(client.getStatus(), GenerationClientState.idle);
        expect(client.getError(), isNull);
        expect(errors, isEmpty);
      });

      test('surfaces a hydration failure for the video client too', () async {
        final errors = <Object>[];
        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) =>
              const Stream.empty(),
          hydrateGeneration: (_) async {
            throw Exception('503 Service Unavailable');
          },
        );
        final client = VideoGenerationClient<VideoGenerateResult>(
          threadId: 'thread-video-denied',
          connection: connection,
          persistence: true,
          onError: errors.add,
        );
        client.mountDevtools();

        await waitForCondition(() {
          expect(client.getStatus(), GenerationClientState.error);
        });
        expect(generationErrorMessage(client.getError()), contains('503'));
        expect(errors, hasLength(1));
      });
    });

    group('truncated stream (no terminal chunk)', () {
      List<StreamChunk> truncatedChunks(String runId, String threadId) => [
            runStarted(runId, threadId),
            custom(GenerationEvents.progress, {'progress': 40}),
          ];

      test(
          'settles generate() to an error when the stream ends without RUN_FINISHED',
          () async {
        final errors = <Object>[];
        final client = GenerationClient(
          threadId: 'thread-trunc',
          connection:
              mockConnection(truncatedChunks('run-trunc', 'thread-trunc')),
          onError: errors.add,
        );

        await client.generate({'prompt': 'test'});

        expect(client.getStatus(), GenerationClientState.error);
        expect(client.getIsLoading(), isFalse);
        expect(generationErrorMessage(client.getError()),
            matches(RegExp('ended before the run finished')));
        expect(errors, hasLength(1));
        expect(
            client.getResumeSnapshot()?.status, GenerationResumeStatus.error);
        expect(client.getResumeSnapshot()?.resumeState, isNull);
      });

      test(
          'settles a rejoin to an error when the replayed stream ends without RUN_FINISHED',
          () async {
        const runId = 'run-trunc-rejoin';
        final errors = <Object>[];
        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) =>
              const Stream.empty(),
          hydrateGeneration: (_) async => GenerationHydrationResult(
            resumeSnapshot: {
              'schemaVersion': 1,
              'resumeState': {
                'threadId': 'thread-trunc-rejoin',
                'runId': runId
              },
              'status': 'running',
            },
            activeRun: const ActiveRun(runId),
          ),
          joinRun: (runId, {signal}) async* {
            for (final chunk in truncatedChunks(runId, 'thread-trunc-rejoin')) {
              yield chunk;
            }
          },
        );
        final client = GenerationClient(
          threadId: 'thread-trunc-rejoin',
          connection: connection,
          persistence: true,
          onError: errors.add,
        );
        client.mountDevtools();

        await waitForCondition(() {
          expect(client.getStatus(), GenerationClientState.error);
        });
        expect(client.getIsLoading(), isFalse);
        expect(generationErrorMessage(client.getError()),
            matches(RegExp('ended before the run finished')));
        expect(errors, hasLength(1));
        expect(
            client.getResumeSnapshot()?.status, GenerationResumeStatus.error);
        expect(client.getResumeSnapshot()?.resumeState, isNull);
      });

      test(
          'settles a video generate() to an error when the stream ends without RUN_FINISHED',
          () async {
        final errors = <Object>[];
        final client = VideoGenerationClient<VideoGenerateResult>(
          threadId: 'thread-video-trunc',
          connection: mockConnection(
            truncatedChunks('run-video-trunc', 'thread-video-trunc'),
          ),
          onError: errors.add,
        );

        await client.generate(const VideoGenerateInput(prompt: 'test'));

        expect(client.getStatus(), GenerationClientState.error);
        expect(client.getIsLoading(), isFalse);
        expect(generationErrorMessage(client.getError()),
            matches(RegExp('ended before the run finished')));
        expect(errors, hasLength(1));
        expect(
            client.getResumeSnapshot()?.status, GenerationResumeStatus.error);
        expect(client.getResumeSnapshot()?.resumeState, isNull);
      });

      test(
          'settles a video rejoin to an error when the replayed stream ends without RUN_FINISHED',
          () async {
        const runId = 'run-video-trunc-rejoin';
        final errors = <Object>[];
        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) =>
              const Stream.empty(),
          hydrateGeneration: (_) async => GenerationHydrationResult(
            resumeSnapshot: {
              'schemaVersion': 1,
              'resumeState': {
                'threadId': 'thread-video-rejoin',
                'runId': runId
              },
              'status': 'running',
            },
            activeRun: const ActiveRun(runId),
          ),
          joinRun: (runId, {signal}) async* {
            for (final chunk in truncatedChunks(runId, 'thread-video-rejoin')) {
              yield chunk;
            }
          },
        );
        final client = VideoGenerationClient<VideoGenerateResult>(
          threadId: 'thread-video-rejoin',
          connection: connection,
          persistence: true,
          onError: errors.add,
        );
        client.mountDevtools();

        await waitForCondition(() {
          expect(client.getStatus(), GenerationClientState.error);
        });
        expect(client.getIsLoading(), isFalse);
        expect(generationErrorMessage(client.getError()),
            matches(RegExp('ended before the run finished')));
        expect(errors, hasLength(1));
        expect(
            client.getResumeSnapshot()?.status, GenerationResumeStatus.error);
        expect(client.getResumeSnapshot()?.resumeState, isNull);
      });

      test(
          'does not report a truncation when the stream was stopped by the caller',
          () async {
        final errors = <Object>[];
        final client = GenerationClient(
          connection: ConnectionAdapter(
            connect: (messages, {data, signal, runContext}) async* {
              yield runStarted('run-stop', 'thread-stop');
              await Future<void>.delayed(Duration.zero);
              if (signal?.isCancelled ?? false) return;
              yield runFinished('run-stop', 'thread-stop');
            },
          ),
          onError: errors.add,
        );

        final generating = client.generate({'prompt': 'test'});
        await Future<void>.delayed(Duration.zero);
        client.stop();
        await generating;

        expect(client.getStatus(), GenerationClientState.idle);
        expect(client.getError(), isNull);
        expect(errors, isEmpty);
      });
    });

    group('declined result reconstruction on restore', () {
      ConnectionAdapter resultOnlyHydratingConnection() => ConnectionAdapter(
            connect: (messages, {data, signal, runContext}) =>
                const Stream.empty(),
            hydrateGeneration: (_) async => GenerationHydrationResult(
              resumeSnapshot: {
                'schemaVersion': 1,
                'resumeState': null,
                'status': 'complete',
                'result': {'id': 'result-1', 'model': 'image-model'},
              },
            ),
          );

      test('reports a complete snapshot the activity mapper cannot rebuild',
          () async {
        final errors = <Object>[];
        final client = GenerationClient(
          threadId: 'thread-unrestorable',
          connection: ConnectionAdapter(
            connect: (messages, {data, signal, runContext}) =>
                const Stream.empty(),
            hydrateGeneration: (_) async => GenerationHydrationResult(
              resumeSnapshot: {
                'schemaVersion': 1,
                'resumeState': null,
                'status': 'complete',
                'activity': 'image',
                'result': {
                  'id': 'srv-img',
                  'model': 'test-image',
                  'artifacts': <Object?>[],
                },
              },
            ),
          ),
          persistence: true,
          reconstructResult: reconstructImageResult,
          onError: errors.add,
        );
        client.mountDevtools();

        await waitForCondition(() {
          expect(client.getStatus(), GenerationClientState.error);
        });
        expect(client.getResult(), isNull);
        expect(generationErrorMessage(client.getError()),
            matches(RegExp('could not be rebuilt')));
        expect(errors, hasLength(1));
      });

      test(
          'stays a plain success when no reconstructResult mapper is configured',
          () async {
        final errors = <Object>[];
        final client = GenerationClient(
          threadId: 'thread-no-mapper',
          connection: resultOnlyHydratingConnection(),
          persistence: true,
          onError: errors.add,
        );
        client.mountDevtools();

        await waitForCondition(() {
          expect(client.getResumeSnapshot()?.status,
              GenerationResumeStatus.complete);
        });
        expect(client.getStatus(), GenerationClientState.success);
        expect(client.getResult(), isNull);
        expect(errors, isEmpty);
      });

      test('does not report a decline while a restored run is still in flight',
          () async {
        const runId = 'run-still-live';
        final errors = <Object>[];
        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) =>
              const Stream.empty(),
          hydrateGeneration: (_) async => GenerationHydrationResult(
            resumeSnapshot: {
              'schemaVersion': 1,
              'resumeState': {
                'threadId': 'thread-live-decline',
                'runId': runId
              },
              'status': 'running',
            },
            activeRun: const ActiveRun(runId),
          ),
          joinRun: (runId, {signal}) async* {
            yield custom(GenerationEvents.result, {
              'id': 'late-img',
              'model': 'm',
              'images': [
                {'url': '/x.png'}
              ],
            });
            yield runFinished(runId, 'thread-live-decline');
          },
        );
        final client = GenerationClient(
          threadId: 'thread-live-decline',
          connection: connection,
          persistence: true,
          reconstructResult: reconstructImageResult,
          onError: errors.add,
        );
        client.mountDevtools();

        await waitForCondition(() {
          expect(client.getStatus(), GenerationClientState.success);
        });
        expect((client.getResult() as Map?)?['id'], 'late-img');
        expect(errors, isEmpty);
      });

      test('reports a complete video snapshot with no durable artifact',
          () async {
        final errors = <Object>[];
        final client = VideoGenerationClient<VideoGenerateResult>(
          threadId: 'thread-video-unrestorable',
          connection: resultOnlyHydratingConnection(),
          persistence: true,
          onError: errors.add,
        );
        client.mountDevtools();

        await waitForCondition(() {
          expect(client.getStatus(), GenerationClientState.error);
        });
        expect(client.getResult(), isNull);
        expect(generationErrorMessage(client.getError()),
            matches(RegExp('could not be rebuilt')));
        expect(errors, hasLength(1));
      });
    });
  });

  // One harness over both clients, so each run-ownership race is pinned once.
  group('run ownership', () {
    final clients = <String, HarnessFactory>{
      'GenerationClient': (options) {
        final client = GenerationClient<Map<String, dynamic>,
            Map<String, dynamic>, Map<String, dynamic>>(
          connection: options.connection,
          fetcher: options.connection == null
              ? (input, fetchOptions) async {
                  final id = await (options.fetcher ?? (p) async => p)(
                    input['prompt'] as String,
                  );
                  return <String, dynamic>{'id': id};
                }
              : null,
          onChunk: options.onChunk,
          onLoadingChange: options.onLoadingChange,
          onStatusChange: options.onStatusChange,
          onErrorChange: options.onErrorChange,
          onError: options.onError,
          onResultChange: (result) =>
              options.onResultChange?.call(result?['id'] as String?),
        );
        return RunHarness(
          generate: (prompt) => client.generate({'prompt': prompt}),
          stop: client.stop,
          reset: client.reset,
          dispose: client.dispose,
          mountDevtools: client.mountDevtools,
          subscribe: client.subscribe,
          runId: () => client.getSnapshot().runId,
          isLoading: () => client.getSnapshot().isLoading,
          getIsLoading: client.getIsLoading,
          getStatus: client.getStatus,
          getError: client.getError,
          getResumeSnapshot: client.getResumeSnapshot,
          resultId: () => client.getResult()?['id'] as String?,
        );
      },
      'VideoGenerationClient': (options) {
        final client = VideoGenerationClient<VideoGenerateResult>(
          connection: options.connection,
          fetcher: options.connection == null
              ? (input, fetchOptions) async {
                  final jobId = await (options.fetcher ?? (p) async => p)(
                    input.prompt as String,
                  );
                  return VideoGenerateResult(
                    jobId: jobId,
                    status: 'completed',
                    url: 'https://example.com/$jobId.mp4',
                  );
                }
              : null,
          onChunk: options.onChunk,
          onLoadingChange: options.onLoadingChange,
          onStatusChange: options.onStatusChange,
          onErrorChange: options.onErrorChange,
          onError: options.onError,
          onResultChange: (result) =>
              options.onResultChange?.call(result?.jobId),
        );
        return RunHarness(
          generate: (prompt) =>
              client.generate(VideoGenerateInput(prompt: prompt)),
          stop: client.stop,
          reset: client.reset,
          dispose: client.dispose,
          mountDevtools: client.mountDevtools,
          subscribe: client.subscribe,
          runId: () => client.getSnapshot().runId,
          isLoading: () => client.getSnapshot().isLoading,
          getIsLoading: client.getIsLoading,
          getStatus: client.getStatus,
          getError: client.getError,
          getResumeSnapshot: client.getResumeSnapshot,
          resultId: () => client.getResult()?.jobId,
        );
      },
    };

    for (final entry in clients.entries) {
      group('${entry.key} run ownership', () {
        final create = entry.value;

        test(
            'should not overwrite a run started by the stopped loading callback',
            () async {
          final first = Deferred<String>();
          final second = Deferred<String>();
          Future<void>? secondGenerate;
          String? secondRunId;
          var replaced = false;
          late RunHarness harness;
          harness = create(RunHarnessOptions(
            fetcher: (prompt) =>
                prompt == 'first' ? first.promise : second.promise,
            onLoadingChange: (isLoading) {
              if (isLoading || replaced) return;
              replaced = true;
              secondGenerate = harness.generate('second');
              secondRunId = harness.runId();
            },
          ));

          final firstGenerate = harness.generate('first');
          harness.stop();

          expect(secondRunId, isNotNull);
          expect(harness.runId(), secondRunId);
          expect(harness.getIsLoading(), isTrue);
          expect(harness.getStatus(), GenerationClientState.generating);
          first.resolve('first');
          second.resolve('second');
          await Future.wait([firstGenerate, secondGenerate!]);
        });

        test(
            'should not overwrite a run started by the stopped status callback',
            () async {
          final first = Deferred<String>();
          final second = Deferred<String>();
          Future<void>? secondGenerate;
          late RunHarness harness;
          harness = create(RunHarnessOptions(
            fetcher: (prompt) =>
                prompt == 'first' ? first.promise : second.promise,
            onStatusChange: (status) {
              if (status != GenerationClientState.idle ||
                  secondGenerate != null) {
                return;
              }
              secondGenerate = harness.generate('second');
            },
          ));

          final firstGenerate = harness.generate('first');
          harness.stop();

          expect(secondGenerate, isNotNull);
          expect(harness.getIsLoading(), isTrue);
          expect(harness.isLoading(), isTrue);
          expect(harness.getStatus(), GenerationClientState.generating);
          first.resolve('first');
          second.resolve('second');
          await Future.wait([firstGenerate, secondGenerate!]);
        });

        test('should publish isLoading false when a stop callback throws',
            () async {
          final first = Deferred<String>();
          late RunHarness harness;
          harness = create(RunHarnessOptions(
            fetcher: (prompt) => first.promise,
            onStatusChange: (status) {
              if (status == GenerationClientState.idle) {
                throw Exception('status failed');
              }
            },
          ));

          final run = harness.generate('first');
          expect(() => harness.stop(), throwsA(isA<Exception>()));

          expect(harness.getIsLoading(), isFalse);
          expect(harness.isLoading(), isFalse);
          first.resolve('first');
          await run;
        });

        test('should not lock generate() when the loading callback throws',
            () async {
          var failNext = true;
          final harness = create(RunHarnessOptions(
            onLoadingChange: (isLoading) {
              if (!isLoading || !failNext) return;
              failNext = false;
              throw Exception('loading failed');
            },
          ));

          await harness.generate('first');

          expect(harness.getStatus(), GenerationClientState.error);
          expect(generationErrorMessage(harness.getError()), 'loading failed');
          expect(harness.isLoading(), isFalse);

          await harness.generate('second');

          expect(harness.getStatus(), GenerationClientState.success);
          expect(harness.resultId(), 'second');
        });

        test('should stop before transport work when loading callback stops',
            () async {
          final prompts = <String>[];
          late RunHarness harness;
          harness = create(RunHarnessOptions(
            fetcher: (prompt) async {
              prompts.add(prompt);
              return prompt;
            },
            onLoadingChange: (isLoading) {
              if (isLoading) harness.stop();
            },
          ));

          await harness.generate('test');

          expect(prompts, isEmpty);
          expect(harness.getStatus(), GenerationClientState.idle);
          expect(harness.runId(), isNull);
        });

        test('should not complete resume state after success callback stops',
            () async {
          late RunHarness harness;
          harness = create(RunHarnessOptions(
            onStatusChange: (status) {
              if (status == GenerationClientState.success) harness.stop();
            },
          ));

          await harness.generate('test');

          expect(harness.getStatus(), GenerationClientState.success);
          expect(harness.runId(), isNull);
          expect(harness.getResumeSnapshot(), isNull);
        });

        test(
            'should not let initialization continue after loading callback starts a replacement',
            () async {
          final second = Deferred<String>();
          final prompts = <String>[];
          var replaced = false;
          Future<void>? secondGenerate;
          late RunHarness harness;
          harness = create(RunHarnessOptions(
            fetcher: (prompt) async {
              prompts.add(prompt);
              return prompt == 'second' ? await second.promise : 'first';
            },
            onLoadingChange: (isLoading) {
              if (!isLoading || replaced) return;
              replaced = true;
              harness.stop();
              secondGenerate = harness.generate('second');
            },
          ));

          await harness.generate('first');

          expect(prompts, ['second']);
          expect(harness.getStatus(), GenerationClientState.generating);
          second.resolve('second');
          await secondGenerate;
        });

        test('should not let an old result callback complete a replacement run',
            () async {
          final second = Deferred<String>();
          Future<void>? secondGenerate;
          String? secondRunId;
          late RunHarness harness;
          harness = create(RunHarnessOptions(
            fetcher: (prompt) async =>
                prompt == 'first' ? 'first' : await second.promise,
            onResultChange: (resultId) {
              if (resultId != 'first') return;
              harness.stop();
              secondGenerate = harness.generate('second');
              secondRunId = harness.runId();
            },
          ));

          await harness.generate('first');

          expect(secondRunId, isNotNull);
          expect(harness.runId(), secondRunId);
          expect(harness.getStatus(), GenerationClientState.generating);
          expect(harness.getResumeSnapshot(), isNull);
          second.resolve('second');
          await secondGenerate;
        });

        test('should not let an old error callback overwrite a replacement run',
            () async {
          final second = Deferred<String>();
          Future<void>? secondGenerate;
          String? secondRunId;
          late RunHarness harness;
          harness = create(RunHarnessOptions(
            fetcher: (prompt) async {
              if (prompt == 'first') throw Exception('first failed');
              return second.promise;
            },
            onErrorChange: (error) {
              if (generationErrorMessage(error) != 'first failed') return;
              harness.stop();
              secondGenerate = harness.generate('second');
              secondRunId = harness.runId();
            },
          ));

          await harness.generate('first');

          expect(secondRunId, isNotNull);
          expect(harness.runId(), secondRunId);
          expect(harness.getStatus(), GenerationClientState.generating);
          second.resolve('second');
          await secondGenerate;
        });

        test(
            'should remain stopped when the error callback stops, and still report the error once',
            () async {
          final onError = <Object>[];
          late RunHarness harness;
          harness = create(RunHarnessOptions(
            fetcher: (prompt) async {
              throw Exception('failed');
            },
            onErrorChange: (error) {
              if (error != null) harness.stop();
            },
            onError: onError.add,
          ));

          await harness.generate('test');

          expect(harness.getStatus(), GenerationClientState.idle);
          expect(harness.runId(), isNull);
          expect(onError, hasLength(1));
          expect(generationErrorMessage(onError.single), 'failed');
        });

        test(
            'should not let an old error status callback overwrite a replacement run',
            () async {
          final second = Deferred<String>();
          Future<void>? secondGenerate;
          var replaced = false;
          late RunHarness harness;
          harness = create(RunHarnessOptions(
            fetcher: (prompt) async {
              if (prompt == 'first') throw Exception('first failed');
              return second.promise;
            },
            onStatusChange: (status) {
              if (status != GenerationClientState.error || replaced) return;
              replaced = true;
              harness.stop();
              secondGenerate = harness.generate('second');
            },
          ));

          await harness.generate('first');

          expect(harness.getStatus(), GenerationClientState.generating);
          expect(harness.getError(), isNull);
          second.resolve('second');
          await secondGenerate;
        });

        test('should stop before transport when the run id subscriber stops',
            () async {
          final prompts = <String>[];
          final loading = <bool>[];
          final harness = create(RunHarnessOptions(
            fetcher: (prompt) async {
              prompts.add(prompt);
              return prompt;
            },
            onLoadingChange: loading.add,
          ));
          harness.subscribe(() {
            if (harness.runId() != null) harness.stop();
          });

          await harness.generate('test');

          expect(prompts, isEmpty);
          expect(loading, isNot(contains(true)));
          expect(harness.runId(), isNull);
        });

        test(
            'should not continue an old run after the run id subscriber starts a replacement',
            () async {
          final second = Deferred<String>();
          final prompts = <String>[];
          Future<void>? secondGenerate;
          var replaced = false;
          final harness = create(RunHarnessOptions(
            fetcher: (prompt) async {
              prompts.add(prompt);
              return prompt == 'second' ? await second.promise : 'first';
            },
          ));
          harness.subscribe(() {
            if (harness.runId() == null || replaced) return;
            replaced = true;
            harness.stop();
            secondGenerate = harness.generate('second');
          });

          await harness.generate('first');

          expect(prompts, ['second']);
          expect(harness.getStatus(), GenerationClientState.generating);
          second.resolve('second');
          await secondGenerate;
        });

        test(
            'should not call the loading callback after its snapshot subscriber stops',
            () async {
          final prompts = <String>[];
          final loading = <bool>[];
          final harness = create(RunHarnessOptions(
            fetcher: (prompt) async {
              prompts.add(prompt);
              return prompt;
            },
            onLoadingChange: loading.add,
          ));
          harness.subscribe(() {
            if (harness.isLoading()) harness.stop();
          });

          await harness.generate('test');

          expect(prompts, isEmpty);
          expect(loading, isNot(contains(true)));
        });

        test(
            'should not call the old status callback after its subscriber starts a replacement',
            () async {
          final second = Deferred<String>();
          final generatingStatuses = <GenerationClientState>[];
          Future<void>? secondGenerate;
          var replaced = false;
          final harness = create(RunHarnessOptions(
            fetcher: (prompt) async =>
                prompt == 'second' ? await second.promise : 'first',
            onStatusChange: (status) {
              if (status == GenerationClientState.generating) {
                generatingStatuses.add(status);
              }
            },
          ));
          harness.subscribe(() {
            if (harness.getStatus() != GenerationClientState.generating ||
                replaced) {
              return;
            }
            replaced = true;
            harness.stop();
            secondGenerate = harness.generate('second');
          });

          await harness.generate('first');

          expect(generatingStatuses, [GenerationClientState.generating]);
          expect(harness.getStatus(), GenerationClientState.generating);
          second.resolve('second');
          await secondGenerate;
        });

        test(
            'should not call the old result callback after its subscriber starts a replacement',
            () async {
          final second = Deferred<String>();
          final results = <String?>[];
          Future<void>? secondGenerate;
          var replaced = false;
          final harness = create(RunHarnessOptions(
            fetcher: (prompt) async =>
                prompt == 'second' ? await second.promise : 'first',
            onResultChange: results.add,
          ));
          harness.subscribe(() {
            if (harness.resultId() != 'first' || replaced) return;
            replaced = true;
            harness.stop();
            secondGenerate = harness.generate('second');
          });

          await harness.generate('first');

          expect(results, isNot(contains('first')));
          expect(harness.getStatus(), GenerationClientState.generating);
          second.resolve('second');
          await secondGenerate;
        });

        test(
            'should not call the old error callback after its subscriber starts a replacement',
            () async {
          final second = Deferred<String>();
          final errors = <Object?>[];
          Future<void>? secondGenerate;
          var replaced = false;
          final harness = create(RunHarnessOptions(
            fetcher: (prompt) async {
              if (prompt == 'first') throw Exception('first failed');
              return second.promise;
            },
            onErrorChange: errors.add,
          ));
          harness.subscribe(() {
            if (generationErrorMessage(harness.getError()) != 'first failed' ||
                replaced) {
              return;
            }
            replaced = true;
            harness.stop();
            secondGenerate = harness.generate('second');
          });

          await harness.generate('first');

          expect(errors.whereType<Object>(), isEmpty);
          expect(harness.getStatus(), GenerationClientState.generating);
          second.resolve('second');
          await secondGenerate;
        });

        test('should not overwrite a run started by the reset loading callback',
            () async {
          final first = Deferred<String>();
          final second = Deferred<String>();
          var replaceOnStop = false;
          Future<void>? secondGenerate;
          String? secondRunId;
          late RunHarness harness;
          harness = create(RunHarnessOptions(
            fetcher: (prompt) async {
              if (prompt == 'seed') return 'seed';
              return prompt == 'first' ? first.promise : second.promise;
            },
            onLoadingChange: (isLoading) {
              if (isLoading || !replaceOnStop) return;
              replaceOnStop = false;
              secondGenerate = harness.generate('second');
              secondRunId = harness.runId();
            },
          ));
          await harness.generate('seed');
          final firstGenerate = harness.generate('first');
          replaceOnStop = true;

          harness.reset();

          expect(secondRunId, isNotNull);
          expect(harness.runId(), secondRunId);
          expect(harness.getStatus(), GenerationClientState.generating);
          expect(harness.getIsLoading(), isTrue);
          expect(harness.resultId(), 'seed');
          first.resolve('first');
          second.resolve('second');
          await Future.wait([firstGenerate, secondGenerate!]);
        });

        test(
            'should not overwrite a run started by the dispose loading callback',
            () async {
          final first = Deferred<String>();
          final second = Deferred<String>();
          var replaceOnDispose = false;
          Future<void>? secondGenerate;
          String? secondRunId;
          late RunHarness harness;
          harness = create(RunHarnessOptions(
            fetcher: (prompt) =>
                prompt == 'first' ? first.promise : second.promise,
            onLoadingChange: (isLoading) {
              if (isLoading || !replaceOnDispose) return;
              replaceOnDispose = false;
              harness.mountDevtools();
              secondGenerate = harness.generate('second');
              secondRunId = harness.runId();
            },
          ));
          final firstGenerate = harness.generate('first');
          replaceOnDispose = true;

          harness.dispose();

          expect(secondRunId, isNotNull);
          expect(harness.runId(), secondRunId);
          expect(harness.getStatus(), GenerationClientState.generating);
          expect(harness.getIsLoading(), isTrue);
          first.resolve('first');
          second.resolve('second');
          await Future.wait([firstGenerate, secondGenerate!]);
        });

        test('should not publish a run id after onChunk stops the run',
            () async {
          final connection = ConnectionAdapter(
            connect: (messages, {data, signal, runContext}) async* {
              yield runStarted('run-1');
            },
          );
          late RunHarness harness;
          harness = create(RunHarnessOptions(
            connection: connection,
            onChunk: (chunk) {
              if (chunk['type'] == 'RUN_STARTED') harness.stop();
            },
          ));

          await harness.generate('test');

          expect(harness.runId(), isNull);
          expect(harness.getStatus(), GenerationClientState.idle);
        });

        test('should not let an old onChunk continuation overwrite a newer run',
            () async {
          var connectionCount = 0;
          final secondBlocked = Deferred<bool>();
          final connection = ConnectionAdapter(
            connect: (messages, {data, signal, runContext}) async* {
              connectionCount++;
              if (connectionCount == 1) {
                yield runStarted('run-1');
                return;
              }
              await secondBlocked.promise;
            },
          );
          Future<void>? secondGenerate;
          String? secondLocalRunId;
          late RunHarness harness;
          harness = create(RunHarnessOptions(
            connection: connection,
            onChunk: (chunk) {
              if (chunk['type'] != 'RUN_STARTED') return;
              harness.stop();
              secondGenerate = harness.generate('second');
              secondLocalRunId = harness.runId();
            },
          ));

          await harness.generate('first');

          expect(secondLocalRunId, isNotNull);
          expect(harness.runId(), secondLocalRunId);
          expect(harness.getIsLoading(), isTrue);
          harness.stop();
          secondBlocked.resolve(true);
          await secondGenerate;
        });
      });
    }
  });
}

typedef HarnessFactory = RunHarness Function(RunHarnessOptions options);

class RunHarnessOptions {
  final Future<String> Function(String prompt)? fetcher;
  final ConnectionAdapter? connection;
  final void Function(StreamChunk chunk)? onChunk;
  final void Function(bool isLoading)? onLoadingChange;
  final void Function(GenerationClientState status)? onStatusChange;
  final void Function(Object? error)? onErrorChange;
  final void Function(Object error)? onError;
  final void Function(String? resultId)? onResultChange;

  const RunHarnessOptions({
    this.fetcher,
    this.connection,
    this.onChunk,
    this.onLoadingChange,
    this.onStatusChange,
    this.onErrorChange,
    this.onError,
    this.onResultChange,
  });
}

class RunHarness {
  final Future<void> Function(String prompt) generate;
  final void Function() stop;
  final void Function() reset;
  final void Function() dispose;
  final void Function() mountDevtools;
  final void Function() Function(void Function() listener) subscribe;
  final String? Function() runId;
  final bool Function() isLoading;
  final bool Function() getIsLoading;
  final GenerationClientState Function() getStatus;
  final Object? Function() getError;
  final GenerationResumeSnapshot? Function() getResumeSnapshot;
  final String? Function() resultId;

  const RunHarness({
    required this.generate,
    required this.stop,
    required this.reset,
    required this.dispose,
    required this.mountDevtools,
    required this.subscribe,
    required this.runId,
    required this.isLoading,
    required this.getIsLoading,
    required this.getStatus,
    required this.getError,
    required this.getResumeSnapshot,
    required this.resultId,
  });
}

class _FakeHttpClient extends http.BaseClient {
  final String body;

  _FakeHttpClient(this.body);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}
