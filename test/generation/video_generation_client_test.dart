// Ported from `packages/ai-client/tests/video-generation-client.test.ts`.
import 'dart:async';

import 'package:tanstack_ai_dart/connections.dart';
import 'package:tanstack_ai_dart/generation.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const videoResult = VideoGenerateResult(
  jobId: 'job-1',
  status: 'completed',
  url: 'https://example.com/video.mp4',
);

void main() {
  group('VideoGenerationClient', () {
    group('fetcher mode', () {
      test('should generate a result using fetcher', () async {
        final onResult = <VideoGenerateResult>[];
        final onResultChange = <VideoGenerateResult?>[];

        final client = VideoGenerationClient<VideoGenerateResult>(
          fetcher: (input, options) async => videoResult,
          onResult: (result) {
            onResult.add(result);
            return const GenerationTransformOutcome.raw();
          },
          onResultChange: onResultChange.add,
        );

        await client.generate(const VideoGenerateInput(prompt: 'test video'));

        expect(onResult, [videoResult]);
        expect(onResultChange, [videoResult]);
        expect(client.getResult(), videoResult);
        expect(client.getStatus(), GenerationClientState.success);
        expect(client.getIsLoading(), isFalse);
      });

      test('should handle fetcher errors', () async {
        final onError = <Object>[];
        final onErrorChange = <Object?>[];

        final client = VideoGenerationClient<VideoGenerateResult>(
          fetcher: (input, options) async {
            throw Exception('video fetch failed');
          },
          onError: onError.add,
          onErrorChange: onErrorChange.add,
        );

        await client.generate(const VideoGenerateInput(prompt: 'test'));

        expect(onError, hasLength(1));
        expect(generationErrorMessage(onError.single), 'video fetch failed');
        expect(client.getStatus(), GenerationClientState.error);
        expect(generationErrorMessage(client.getError()), 'video fetch failed');
      });

      test('should track loading state during fetcher call', () async {
        final states = <bool>[];

        final client = VideoGenerationClient<VideoGenerateResult>(
          fetcher: (input, options) async => videoResult,
          onLoadingChange: states.add,
        );

        await client.generate(const VideoGenerateInput(prompt: 'test'));

        expect(states, [true, false]);
      });

      test('should pass abort signal to fetcher', () async {
        GenerationFetcherOptions? captured;
        var calls = 0;

        final client = VideoGenerationClient<VideoGenerateResult>(
          fetcher: (input, options) async {
            calls++;
            captured = options;
            return videoResult;
          },
        );

        await client.generate(const VideoGenerateInput(prompt: 'test video'));

        expect(calls, 1);
        expect(captured, isNotNull);
        expect(captured!.signal.isCancelled, isFalse);
      });

      test('should not allow concurrent requests', () async {
        final first = Deferred<Object?>();
        var callCount = 0;

        final client = VideoGenerationClient<VideoGenerateResult>(
          fetcher: (input, options) async {
            callCount++;
            return first.promise;
          },
        );

        final p1 = client.generate(const VideoGenerateInput(prompt: 'test'));
        final p2 = client.generate(const VideoGenerateInput(prompt: 'test2'));

        first.resolve(videoResult);
        await p1;
        await p2;

        expect(callCount, 1);
      });
    });

    group('connection mode', () {
      test('should process stream with video job lifecycle events', () async {
        final onResult = <VideoGenerateResult>[];
        final onJobCreated = <String>[];
        final onStatusUpdate = <VideoStatusInfo>[];

        final connection = mockConnection([
          runStarted('run-1'),
          custom(GenerationEvents.videoJobCreated, {'jobId': 'job-123'}),
          custom(GenerationEvents.videoStatus, {
            'jobId': 'job-123',
            'status': 'processing',
            'progress': 50,
          }),
          custom(GenerationEvents.videoStatus, {
            'jobId': 'job-123',
            'status': 'completed',
            'progress': 100,
          }),
          custom(GenerationEvents.result, {
            'jobId': 'job-123',
            'status': 'completed',
            'url': 'https://example.com/video.mp4',
          }),
          runFinished('run-1'),
        ]);

        final client = VideoGenerationClient<VideoGenerateResult>(
          connection: connection,
          onResult: (result) {
            onResult.add(result);
            return const GenerationTransformOutcome.raw();
          },
          onJobCreated: onJobCreated.add,
          onStatusUpdate: onStatusUpdate.add,
        );

        await client.generate(const VideoGenerateInput(prompt: 'A flying car'));

        expect(onJobCreated, ['job-123']);
        expect(onStatusUpdate, hasLength(2));
        expect(onResult.single.jobId, 'job-123');
        expect(onResult.single.url, 'https://example.com/video.mp4');
        expect(client.getStatus(), GenerationClientState.success);
        expect(client.getJobId(), 'job-123');
        expect(client.getSnapshot().runId, isNull);
      });

      test('should track video status updates', () async {
        final onVideoStatusChange = <VideoStatusInfo?>[];

        final connection = mockConnection([
          runStarted('run-1'),
          custom(GenerationEvents.videoStatus, {
            'jobId': 'job-1',
            'status': 'processing',
            'progress': 25,
          }),
          custom(GenerationEvents.result, {
            'jobId': 'job-1',
            'status': 'completed',
            'url': 'https://example.com/video.mp4',
          }),
          runFinished('run-1'),
        ]);

        final client = VideoGenerationClient<VideoGenerateResult>(
          connection: connection,
          onVideoStatusChange: onVideoStatusChange.add,
        );

        await client.generate(const VideoGenerateInput(prompt: 'test'));

        expect(
          onVideoStatusChange.whereType<VideoStatusInfo>().first.toJson(),
          {
            'jobId': 'job-1',
            'status': 'processing',
            'progress': 25,
          },
        );
        expect(client.getVideoStatus()?.toJson(), {
          'jobId': 'job-1',
          'status': 'completed',
          'progress': 100,
          'url': 'https://example.com/video.mp4',
        });
      });

      test('should handle RUN_ERROR from stream', () async {
        final onError = <Object>[];

        final connection = mockConnection([
          runStarted('run-1'),
          {
            'type': 'RUN_ERROR',
            'message': 'Video generation failed',
            'runId': 'run-1',
            'error': {'message': 'Video generation failed'},
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          },
        ]);

        final client = VideoGenerationClient<VideoGenerateResult>(
          connection: connection,
          onError: onError.add,
        );

        await client.generate(const VideoGenerateInput(prompt: 'test'));

        expect(onError, hasLength(1));
        expect(client.getStatus(), GenerationClientState.error);
        expect(
          generationErrorMessage(client.getError()),
          'Video generation failed',
        );
        expect(client.getSnapshot().runId, isNull);
      });

      test('should report progress from video:status events', () async {
        final progress = <List<Object?>>[];

        final connection = mockConnection([
          runStarted('run-1'),
          custom(GenerationEvents.videoStatus, {
            'jobId': 'job-1',
            'status': 'processing',
            'progress': 50,
          }),
          runFinished('run-1'),
        ]);

        final client = VideoGenerationClient<VideoGenerateResult>(
          connection: connection,
          onProgress: (value, message) => progress.add([value, message]),
        );

        await client.generate(const VideoGenerateInput(prompt: 'test'));

        expect(progress, [
          [50, null]
        ]);
      });

      test('should report progress from generation:progress events', () async {
        final progress = <List<Object?>>[];

        final connection = mockConnection([
          runStarted('run-1'),
          custom(GenerationEvents.progress, {
            'progress': 75,
            'message': 'Almost done',
          }),
          runFinished('run-1'),
        ]);

        final client = VideoGenerationClient<VideoGenerateResult>(
          connection: connection,
          onProgress: (value, message) => progress.add([value, message]),
        );

        await client.generate(const VideoGenerateInput(prompt: 'test'));

        expect(progress, [
          [75, 'Almost done']
        ]);
      });

      test('should call onChunk for each stream chunk', () async {
        final chunks = <Map<String, dynamic>>[];

        final connection = mockConnection([
          runStarted('run-1'),
          custom(GenerationEvents.result, {
            'jobId': 'job-1',
            'status': 'completed',
            'url': 'https://example.com/video.mp4',
          }),
          runFinished('run-1'),
        ]);

        final client = VideoGenerationClient<VideoGenerateResult>(
          connection: connection,
          onChunk: chunks.add,
        );

        await client.generate(const VideoGenerateInput(prompt: 'test'));

        expect(chunks, hasLength(3));
      });

      test('should pass body and input as data to connection', () async {
        final calls = <Map<String, dynamic>?>[];
        RunAgentInputContext? context;
        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            calls.add(data);
            context = runContext;
            yield runFinished('run-1');
          },
        );

        final client = VideoGenerationClient<VideoGenerateResult>(
          connection: connection,
          body: {'model': 'runway-gen3'},
        );

        await client.generate(
          const VideoGenerateInput(prompt: 'A sunset', size: '1280x720'),
        );

        expect(calls.single, {
          'model': 'runway-gen3',
          'prompt': 'A sunset',
          'size': '1280x720',
        });
        expect(context?.threadId, matches(RegExp(r'^video-')));
        expect(context?.runId, isNotEmpty);
      });
    });

    group('stop()', () {
      test('should abort in-flight request and reset to idle', () async {
        final pending = Deferred<Object?>();

        final client = VideoGenerationClient<VideoGenerateResult>(
          fetcher: (input, options) async => pending.promise,
        );

        final generatePromise =
            client.generate(const VideoGenerateInput(prompt: 'test'));
        expect(client.getIsLoading(), isTrue);
        expect(client.getSnapshot().runId, isNotNull);

        client.stop();
        expect(client.getIsLoading(), isFalse);
        expect(client.getStatus(), GenerationClientState.idle);
        expect(client.getSnapshot().runId, isNull);

        pending.resolve(videoResult);
        await generatePromise;
      });
    });

    group('reset()', () {
      test('should clear all state and return to idle', () async {
        final connection = mockConnection([
          runStarted('run-1'),
          custom(GenerationEvents.videoJobCreated, {'jobId': 'job-123'}),
          custom(GenerationEvents.videoStatus, {
            'jobId': 'job-123',
            'status': 'processing',
            'progress': 50,
          }),
          custom(GenerationEvents.result, {
            'jobId': 'job-123',
            'status': 'completed',
            'url': 'https://example.com/video.mp4',
          }),
          runFinished('run-1'),
        ]);

        final client = VideoGenerationClient<VideoGenerateResult>(
          connection: connection,
        );

        await client.generate(const VideoGenerateInput(prompt: 'test'));
        expect(client.getResult(), isNotNull);
        expect(client.getJobId(), 'job-123');
        expect(client.getStatus(), GenerationClientState.success);

        client.reset();
        expect(client.getResult(), isNull);
        expect(client.getJobId(), isNull);
        expect(client.getVideoStatus(), isNull);
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

        final client = VideoGenerationClient<VideoGenerateResult>(
          connection: connection,
          body: {'model': 'old'},
        );

        client.updateOptions(body: {'model': 'new'});
        await client.generate(const VideoGenerateInput(prompt: 'test'));

        expect(calls.single, {'model': 'new', 'prompt': 'test'});
        expect(context?.threadId, matches(RegExp(r'^video-')));
        expect(context?.runId, isNotEmpty);
      });
    });

    group('abort handling', () {
      test('should not set result if aborted mid-stream', () async {
        final onResult = <VideoGenerateResult>[];
        final onJobCreated = <String>[];
        final aborted = Deferred<bool>();

        final connection = ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            yield runStarted('run-1');
            yield custom(
                GenerationEvents.videoJobCreated, {'jobId': 'job-123'});
            signal?.addListener(() => aborted.resolve(true));
            await aborted.promise;
            if (signal?.isCancelled ?? false) return;
            yield custom(GenerationEvents.result, {
              'jobId': 'job-123',
              'status': 'completed',
              'url': 'https://example.com/video.mp4',
            });
          },
        );

        final client = VideoGenerationClient<VideoGenerateResult>(
          connection: connection,
          onResult: (result) {
            onResult.add(result);
            return const GenerationTransformOutcome.raw();
          },
          onJobCreated: onJobCreated.add,
        );

        final generatePromise =
            client.generate(const VideoGenerateInput(prompt: 'test'));
        await Future<void>.delayed(Duration.zero);

        client.stop();
        await generatePromise;

        expect(onResult, isEmpty);
        expect(client.getResult(), isNull);
        expect(client.getStatus(), GenerationClientState.idle);
      });
    });

    group('error wrapping', () {
      test('should wrap non-Error thrown values in Error', () async {
        final onError = <Object>[];

        final client = VideoGenerationClient<VideoGenerateResult>(
          fetcher: (input, options) async {
            throw 'video error string';
          },
          onError: onError.add,
        );

        await client.generate(const VideoGenerateInput(prompt: 'test'));

        expect(onError, hasLength(1));
        expect(generationErrorMessage(onError.single), 'video error string');
        expect(generationErrorMessage(client.getError()), 'video error string');
      });

      test('should throw if neither connection nor fetcher is provided',
          () async {
        final onError = <Object>[];

        final client = VideoGenerationClient<VideoGenerateResult>(
          onError: onError.add,
        );

        await client.generate(const VideoGenerateInput(prompt: 'test'));

        expect(onError, hasLength(1));
        expect(
          generationErrorMessage(client.getError()),
          'VideoGenerationClient requires either a connection or fetcher option',
        );
      });
    });

    group('sequential generation', () {
      test('should allow a second generation after the first completes',
          () async {
        var callCount = 0;

        final client = VideoGenerationClient<VideoGenerateResult>(
          fetcher: (input, options) async {
            callCount++;
            return VideoGenerateResult(
              jobId: 'job-$callCount',
              status: 'completed',
              url: 'https://example.com/video-$callCount.mp4',
            );
          },
        );

        await client.generate(const VideoGenerateInput(prompt: 'first'));
        expect(client.getResult()?.jobId, 'job-1');

        await client.generate(const VideoGenerateInput(prompt: 'second'));
        expect(client.getResult()?.jobId, 'job-2');
        expect(callCount, 2);
      });
    });

    group('state transitions', () {
      test('should follow idle -> generating -> success', () async {
        final states = <GenerationClientState>[];

        final client = VideoGenerationClient<VideoGenerateResult>(
          fetcher: (input, options) async => videoResult,
          onStatusChange: states.add,
        );

        expect(client.getStatus(), GenerationClientState.idle);
        await client.generate(const VideoGenerateInput(prompt: 'test'));

        expect(states, [
          GenerationClientState.generating,
          GenerationClientState.success,
        ]);
      });

      test('should follow idle -> generating -> error on failure', () async {
        final states = <GenerationClientState>[];

        final client = VideoGenerationClient<VideoGenerateResult>(
          fetcher: (input, options) async {
            throw Exception('fail');
          },
          onStatusChange: states.add,
        );

        await client.generate(const VideoGenerateInput(prompt: 'test'));

        expect(states, [
          GenerationClientState.generating,
          GenerationClientState.error,
        ]);
      });
    });
  });
}
