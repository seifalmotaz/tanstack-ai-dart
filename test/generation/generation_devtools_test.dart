// Ported from `packages/ai-client/tests/generation-devtools.test.ts`.
//
// The concrete DevTools bridge is owned by the DevTools worker; these tests
// drive the clients through the injectable bridge port with a recording double.
import 'dart:async';

import 'package:tanstack_ai_dart/connections.dart';
import 'package:tanstack_ai_dart/devtools.dart'
    show
        InMemoryAIDevtoolsEventClient,
        createGenerationClientDevtoolsBridgeFactory;
import 'package:tanstack_ai_dart/generation.dart';
import 'package:test/test.dart';

import 'test_support.dart';

typedef StopRunOptions = ({
  String threadId,
  String hookName,
  Future<String> Function() fetchText,
  void Function(bool isLoading)? onLoadingChange,
  void Function(GenerationClientState status)? onStatusChange,
  void Function(Object? error)? onErrorChange,
});

class _Kind {
  final dynamic Function(
    DevtoolsRecorder recorder,
    StopRunOptions options,
  ) create;
  final bool Function(Object? result) successResult;

  const _Kind(this.create, this.successResult);
}

void main() {
  group('generation client devtools bridge', () {
    late DevtoolsRecorder recorder;

    setUp(() {
      recorder = DevtoolsRecorder();
    });

    Map<String, dynamic> resultChunk(Object? value) =>
        custom(GenerationEvents.result, value);

    Map<String, dynamic> runStartedChunk(String runId) => runStarted(runId);

    Map<String, dynamic> runFinishedChunk(String runId) => runFinished(runId);

    Map<String, dynamic> latestSnapshotState() =>
        recorder.latestSnapshotState();

    List<Map<String, dynamic>> latestGenerationRuns() =>
        recorder.latestGenerationRuns();

    test('uses canonical devtools metadata and progress types', () {
      const metadata = GenerationDevtoolsMetadata(
        framework: 'react',
        hookName: 'useGeneration',
      );
      expect(metadata, isA<AIDevtoolsClientMetadata>());
      expect(metadata.framework, 'react');

      const progress =
          GenerationDevtoolsProgress(value: 25, message: 'Halfway');
      expect(progress, isA<AIDevtoolsGenerationProgress>());
      expect(progress.toJson(), {'value': 25, 'message': 'Halfway'});
    });

    test('normalizes generation results into renderable devtools previews', () {
      expect(
        createAIDevtoolsGenerationPreview(
          outputKind: 'image',
          result: {
            'id': 'img-1',
            'model': 'image-model',
            'images': [
              {'url': 'https://example.com/image.png'},
              {'b64Json': 'iVBORw0KGgo='},
            ],
          },
        ),
        {
          'kind': 'image',
          'items': [
            {'src': 'https://example.com/image.png', 'sourceType': 'url'},
            {
              'src': 'data:image/png;base64,iVBORw0KGgo=',
              'sourceType': 'base64',
              'mimeType': 'image/png',
            },
          ],
        },
      );

      expect(
        createAIDevtoolsGenerationPreview(
          outputKind: 'audio',
          result: {
            'id': 'speech-1',
            'model': 'tts-model',
            'audio': 'UklGRg==',
            'format': 'wav',
            'contentType': 'audio/wav',
          },
        ),
        {
          'kind': 'audio',
          'items': [
            {
              'src': 'data:audio/wav;base64,UklGRg==',
              'sourceType': 'base64',
              'mimeType': 'audio/wav',
              'format': 'wav',
            },
          ],
        },
      );

      expect(
        createAIDevtoolsGenerationPreview(
          outputKind: 'text',
          result: {
            'id': 'transcription-1',
            'model': 'whisper',
            'text': 'Hello world',
          },
        ),
        {'kind': 'text', 'text': 'Hello world'},
      );

      expect(
        createAIDevtoolsGenerationPreview(
          outputKind: 'video',
          result: null,
          videoStatus: {
            'jobId': 'job-1',
            'status': 'processing',
            'progress': 50,
            'url': 'https://example.com/video.mp4',
          },
        ),
        {
          'kind': 'video',
          'items': [
            {'src': 'https://example.com/video.mp4', 'sourceType': 'url'},
          ],
          'job': {'jobId': 'job-1', 'status': 'processing', 'progress': 50},
        },
      );
    });

    test('registers a generation hook and emits run lifecycle for fetcher mode',
        () async {
      final client = GenerationClient(
        threadId: 'gen-1',
        fetcher: (input, options) async => {'text': 'done'},
        devtools: const GenerationDevtoolsMetadata(
          framework: 'react',
          hookName: 'useGenerateObject',
          outputKind: 'structured',
        ),
        devtoolsBridgeFactory: recorder.factory,
      );
      recorder.eventClient.clearEvents();

      await client.generate({'prompt': 'make object'});

      expect(
        recorder.eventClient.emitted('run:started').single,
        containsPair('hookId', 'gen-1'),
      );
      expect(
        recorder.eventClient.emitted('run:started').single,
        containsPair('status', 'started'),
      );
      expect(
        recorder.eventClient.emitted('run:completed').single,
        containsPair('status', 'completed'),
      );
      final snapshot = recorder.eventClient.emitted('hook:state-snapshot').last;
      expect(snapshot['hookId'], 'gen-1');
      expect(snapshot['hookName'], 'useGenerateObject');
      expect(snapshot['framework'], 'react');
      expect(snapshot['outputKind'], 'structured');
      expect((snapshot['state'] as Map)['status'], 'success');
      expect((snapshot['state'] as Map)['isLoading'], isFalse);
      expect((snapshot['state'] as Map)['result'], {'text': 'done'});

      client.dispose();
    });

    final kinds = <String, _Kind>{
      'generation': _Kind(
        (recorder, options) => GenerationClient<Map<String, dynamic>,
            Map<String, dynamic>, Map<String, dynamic>>(
          threadId: options.threadId,
          fetcher: (input, fetchOptions) async =>
              {'text': await options.fetchText()},
          devtools: GenerationDevtoolsMetadata(hookName: options.hookName),
          devtoolsBridgeFactory: recorder.factory,
          onLoadingChange: options.onLoadingChange,
          onStatusChange: options.onStatusChange,
          onErrorChange: options.onErrorChange,
        ),
        (result) => result is Map && result['text'] == 'done' || result == null,
      ),
      'video': _Kind(
        (recorder, options) => VideoGenerationClient<VideoGenerateResult>(
          threadId: options.threadId,
          fetcher: (input, fetchOptions) async => VideoGenerateResult(
            jobId: await options.fetchText(),
            status: 'completed',
            url: 'https://example.com/video-1.mp4',
          ),
          devtools: GenerationDevtoolsMetadata(
            hookName: options.hookName,
            outputKind: 'video',
          ),
          devtoolsBridgeFactory: recorder.factory,
          onLoadingChange: options.onLoadingChange,
          onStatusChange: options.onStatusChange,
          onErrorChange: options.onErrorChange,
        ),
        (result) => result is VideoGenerateResult && result.jobId == 'done',
      ),
    };

    for (final kindEntry in kinds.entries) {
      final kind = kindEntry.value;
      group('${kindEntry.key} devtools run stopped from a callback', () {
        test('finishes the run when a runId subscriber stops it', () async {
          var fetchCalls = 0;
          final StopRunOptions options = (
            threadId: '${kindEntry.key}-run-id-stop',
            hookName: 'useRunIdStop',
            fetchText: () async {
              fetchCalls++;
              return 'done';
            },
            onLoadingChange: null,
            onStatusChange: null,
            onErrorChange: null,
          );
          final client = kind.create(recorder, options);
          final unsubscribe = _subscribe(client, () {
            if (_snapshotRunId(client) != null) _stop(client);
          });

          await _generate(client, 'stop early');

          expect(fetchCalls, 0);
          expect(latestSnapshotState()['activeRunId'], isNull);
          unsubscribe();
          client.dispose();
        });

        test('finishes the run when loading callback stops it', () async {
          var fetchCalls = 0;
          late dynamic client;
          final StopRunOptions options = (
            threadId: '${kindEntry.key}-loading-stop',
            hookName: 'useLoadingStop',
            fetchText: () async {
              fetchCalls++;
              return 'done';
            },
            onLoadingChange: (bool isLoading) {
              if (isLoading) _stop(client);
            },
            onStatusChange: null,
            onErrorChange: null,
          );
          client = kind.create(recorder, options);

          await _generate(client, 'stop while loading');

          expect(fetchCalls, 0);
          expect(latestSnapshotState()['activeRunId'], isNull);
          client.dispose();
        });

        test('finishes a completed run when success callback stops it',
            () async {
          late dynamic client;
          final StopRunOptions options = (
            threadId: '${kindEntry.key}-success-stop',
            hookName: 'useSuccessStop',
            fetchText: () async => 'done',
            onLoadingChange: null,
            onStatusChange: (GenerationClientState status) {
              if (status == GenerationClientState.success) _stop(client);
            },
            onErrorChange: null,
          );
          client = kind.create(recorder, options);

          await _generate(client, 'finish then stop');

          expect(latestSnapshotState()['activeRunId'], isNull);
          final lastRun = latestGenerationRuns().last;
          expect(lastRun['status'], 'success');
          expect(kind.successResult(lastRun['result']), isTrue);
          client.dispose();
        });

        for (final callback in ['onStatusChange', 'onErrorChange']) {
          test('records an errored run when $callback stops it', () async {
            late dynamic client;
            void stopOnError() {
              if (_errorOf(client) != null) _stop(client);
            }

            final StopRunOptions options = (
              threadId: '${kindEntry.key}-error-stop-$callback',
              hookName: 'useErrorStop',
              fetchText: () async {
                throw Exception('${kindEntry.key} failed');
              },
              onLoadingChange: null,
              onStatusChange: callback == 'onStatusChange'
                  ? (GenerationClientState status) => stopOnError()
                  : null,
              onErrorChange: callback == 'onErrorChange'
                  ? (Object? error) => stopOnError()
                  : null,
            );
            client = kind.create(recorder, options);

            await _generate(client, 'fail then stop');

            expect(latestSnapshotState()['activeRunId'], isNull);
            final lastRun = latestGenerationRuns().last;
            expect(lastRun['status'], 'error');
            expect(lastRun['error'], '${kindEntry.key} failed');
            client.dispose();
          });
        }
      });
    }

    test(
        'includes input, progress, and renderable previews in generation snapshots',
        () async {
      final client = GenerationClient(
        threadId: 'image-hook',
        fetcher: (input, options) async => {
          'id': 'img-1',
          'model': 'image-model',
          'images': [
            {'url': 'https://example.com/image.png'},
            {'b64Json': 'iVBORw0KGgo='},
          ],
        },
        devtools: const GenerationDevtoolsMetadata(
          framework: 'react',
          hookName: 'useGenerateImage',
          outputKind: 'image',
        ),
        devtoolsBridgeFactory: recorder.factory,
      );
      recorder.eventClient.clearEvents();

      await client.generate({'prompt': 'A quiet desk', 'numberOfImages': 2});

      final state = latestSnapshotState();
      expect(state['input'], {'prompt': 'A quiet desk', 'numberOfImages': 2});
      expect(state['progress'], isNull);
      expect(state['preview'], {
        'kind': 'image',
        'items': [
          {'src': 'https://example.com/image.png', 'sourceType': 'url'},
          {
            'src': 'data:image/png;base64,iVBORw0KGgo=',
            'sourceType': 'base64',
            'mimeType': 'image/png',
          },
        ],
      });

      client.dispose();
    });

    test('tracks streamed progress in generation snapshots', () async {
      // ignore: prefer_function_declarations_over_variables
      final connect = (List<WireMessage> messages,
          {Map<String, dynamic>? data,
          CancellationSignal? signal,
          RunAgentInputContext? runContext}) async* {
        yield runStartedChunk('run-progress');
        yield custom(GenerationEvents.progress, {
          'progress': 40,
          'message': 'Rendering preview',
        });
        yield resultChunk({'summary': 'short version'});
        yield runFinishedChunk('run-progress');
      };
      final client = GenerationClient(
        threadId: 'summary-hook',
        connection: ConnectionAdapter(connect: connect),
        devtools: const GenerationDevtoolsMetadata(
          hookName: 'useSummarize',
          outputKind: 'text',
        ),
        devtoolsBridgeFactory: recorder.factory,
      );
      recorder.eventClient.clearEvents();

      await client.generate({'text': 'Long text'});

      final state = latestSnapshotState();
      expect(state['input'], {'text': 'Long text'});
      expect(state['progress'], {
        'value': 100,
        'message': 'Rendering preview',
      });
      expect(state['preview'], {'kind': 'text', 'text': 'short version'});

      client.dispose();
    });

    test('retains grouped generation snapshots for previous runs', () async {
      // ignore: prefer_function_declarations_over_variables
      final connect = (List<WireMessage> messages,
          {Map<String, dynamic>? data,
          CancellationSignal? signal,
          RunAgentInputContext? runContext}) async* {
        final prompt =
            data?['prompt'] is String ? data!['prompt'] as String : 'unknown';
        final runId = 'run-$prompt';
        yield runStartedChunk(runId);
        yield custom(GenerationEvents.progress, {
          'progress': 70,
          'message': 'Rendering $prompt',
        });
        yield resultChunk({
          'id': 'img-$prompt',
          'model': 'image-model',
          'images': [
            {'url': 'https://example.com/$prompt.png'}
          ],
        });
        yield runFinishedChunk(runId);
      };
      final client = GenerationClient(
        threadId: 'image-history',
        connection: ConnectionAdapter(connect: connect),
        devtools: const GenerationDevtoolsMetadata(
          hookName: 'useGenerateImage',
          outputKind: 'image',
        ),
        devtoolsBridgeFactory: recorder.factory,
      );
      recorder.eventClient.clearEvents();

      await client.generate({'prompt': 'one'});
      await client.generate({'prompt': 'two'});

      final runs = latestGenerationRuns();
      expect(runs, hasLength(2));
      for (final prompt in ['one', 'two']) {
        final run = runs.firstWhere((run) => run['id'] == 'run-$prompt');
        expect(run['input'], {'prompt': prompt});
        expect(run['status'], 'success');
        expect(run['isLoading'], isFalse);
        expect(run['progress'], {
          'value': 100,
          'message': 'Rendering $prompt',
        });
        expect((run['result'] as Map)['id'], 'img-$prompt');
        expect(run['preview'], {
          'kind': 'image',
          'items': [
            {
              'src': 'https://example.com/$prompt.png',
              'sourceType': 'url',
            },
          ],
        });
      }

      client.dispose();
    });

    test('responds to devtools state requests for a generation hook', () async {
      final client = GenerationClient(
        threadId: 'gen-1',
        fetcher: (input, options) async => {'text': 'done'},
        devtools: const GenerationDevtoolsMetadata(
          framework: 'react',
          hookName: 'useGenerateText',
          outputKind: 'text',
        ),
        devtoolsBridgeFactory: recorder.factory,
      );
      client.mountDevtools();
      recorder.eventClient.clearEvents();

      recorder.eventClient.dispatch('devtools:request-state', {
        'targetHookId': 'gen-1',
      });

      final registered = recorder.eventClient.emitted('hook:registered').single;
      expect(registered['hookId'], 'gen-1');
      expect(registered['hookName'], 'useGenerateText');
      expect(registered['framework'], 'react');
      expect(registered['outputKind'], 'text');
      final snapshot =
          recorder.eventClient.emitted('hook:state-snapshot').single;
      final state = snapshot['state'] as Map;
      expect(state['status'], 'idle');
      expect(state['isLoading'], isFalse);
      expect(state['result'], isNull);
      expect(state['activeRunId'], isNull);

      client.dispose();
    });

    test('emits errored run lifecycle for generation failures', () async {
      final client = GenerationClient(
        threadId: 'gen-1',
        fetcher: (input, options) async {
          throw Exception('Generation failed');
        },
        devtools: const GenerationDevtoolsMetadata(
          hookName: 'useGenerateObject',
          outputKind: 'structured',
        ),
        devtoolsBridgeFactory: recorder.factory,
      );
      recorder.eventClient.clearEvents();

      await client.generate({'prompt': 'fail'});

      final errored = recorder.eventClient.emitted('run:errored').single;
      expect(errored['hookId'], 'gen-1');
      expect(errored['status'], 'errored');
      expect(errored['error'], 'Generation failed');
      final state = latestSnapshotState();
      expect(state['status'], 'error');
      expect(state['isLoading'], isFalse);
      expect(state['error'], 'Generation failed');

      client.dispose();
    });

    test('registers a generation hook for streaming connection mode', () async {
      final contexts = <RunAgentInputContext?>[];
      // ignore: prefer_function_declarations_over_variables
      final connectSpy = (List<WireMessage> messages,
          {Map<String, dynamic>? data,
          CancellationSignal? signal,
          RunAgentInputContext? runContext}) async* {
        contexts.add(runContext);
        yield runStartedChunk('server-run-1');
        yield resultChunk({'text': 'streamed'});
        yield runFinishedChunk('server-run-1');
      };

      final client = GenerationClient(
        threadId: 'gen-stream',
        connection: ConnectionAdapter(connect: connectSpy),
        devtools: const GenerationDevtoolsMetadata(
          hookName: 'useGenerateText',
          outputKind: 'text',
        ),
        devtoolsBridgeFactory: recorder.factory,
      );
      recorder.eventClient.clearEvents();

      await client.generate({'prompt': 'stream'});
      final runContext = contexts.single;

      expect(runContext?.threadId, 'gen-stream');
      expect(runContext?.runId, isNotNull);
      expect(
        recorder.eventClient.emitted('run:started').single['runId'],
        'server-run-1',
      );
      expect(
        recorder.eventClient.emitted('run:started').single['runId'],
        isNot(runContext?.runId),
      );
      expect(recorder.eventClient.emitted('run:started'), hasLength(1));
      expect(
        recorder.eventClient.emitted('run:completed').single['runId'],
        'server-run-1',
      );
      final state = latestSnapshotState();
      expect(state['status'], 'success');
      expect(state['isLoading'], isFalse);
      expect(state['result'], {'text': 'streamed'});

      client.dispose();
    });

    test('does not emit hook updates after disposal', () async {
      final deferred = Deferred<Object?>();
      final client = GenerationClient(
        threadId: 'gen-1',
        fetcher: (input, options) async => deferred.promise,
        devtools: const GenerationDevtoolsMetadata(
          hookName: 'useGenerateText',
          outputKind: 'text',
        ),
        devtoolsBridgeFactory: recorder.factory,
      );
      final generatePromise = client.generate({'prompt': 'slow'});
      await Future<void>.value();

      client.dispose();
      final events = recorder.eventClient.events;
      final unregisteredIndex =
          events.indexWhere((event) => event.key == 'hook:unregistered');
      deferred.resolve({'text': 'late'});
      await generatePromise;

      expect(unregisteredIndex, greaterThanOrEqualTo(0));
      final afterDispose =
          events.skip(unregisteredIndex + 1).map((event) => event.key).toList();
      expect(afterDispose, isNot(contains('hook:updated')));
      expect(afterDispose, isNot(contains('hook:state-snapshot')));
    });

    test('uses the stream run id for video connection lifecycle events',
        () async {
      final contexts = <RunAgentInputContext?>[];
      // ignore: prefer_function_declarations_over_variables
      final connectSpy = (List<WireMessage> messages,
          {Map<String, dynamic>? data,
          CancellationSignal? signal,
          RunAgentInputContext? runContext}) async* {
        contexts.add(runContext);
        yield runStartedChunk('server-video-run-1');
        yield custom(GenerationEvents.result, {
          'jobId': 'job-1',
          'status': 'completed',
          'url': 'https://example.com/video.mp4',
        });
        yield runFinishedChunk('server-video-run-1');
      };
      final client = VideoGenerationClient<VideoGenerateResult>(
        threadId: 'video-stream',
        connection: ConnectionAdapter(connect: connectSpy),
        devtools: const GenerationDevtoolsMetadata(
          hookName: 'useGenerateVideo',
          outputKind: 'video',
        ),
        devtoolsBridgeFactory: recorder.factory,
      );
      recorder.eventClient.clearEvents();

      await client.generate(const VideoGenerateInput(prompt: 'stream video'));
      final runId = contexts.single?.runId ?? 'missing-run';

      expect(
        recorder.eventClient
            .emitted('run:started')
            .where((event) => event['runId'] == runId),
        isEmpty,
      );
      expect(recorder.eventClient.emitted('run:started'), hasLength(1));
      expect(
        recorder.eventClient.emitted('run:completed').single['runId'],
        'server-video-run-1',
      );

      client.dispose();
    });

    test('registers a video hook and includes job state in snapshots',
        () async {
      final client = VideoGenerationClient<VideoGenerateResult>(
        threadId: 'video-1',
        fetcher: (input, options) async => const VideoGenerateResult(
          jobId: 'job-1',
          status: 'completed',
          url: 'https://example.com/video.mp4',
        ),
        devtools: const GenerationDevtoolsMetadata(
          framework: 'react',
          hookName: 'useGenerateVideo',
          outputKind: 'video',
        ),
        devtoolsBridgeFactory: recorder.factory,
      );

      await client.generate(const VideoGenerateInput(prompt: 'make video'));

      final registered = recorder.eventClient.emitted('hook:registered').single;
      expect(registered['hookId'], 'video-1');
      expect(registered['hookName'], 'useGenerateVideo');
      expect(registered['framework'], 'react');
      expect(registered['outputKind'], 'video');
      final completed = recorder.eventClient.emitted('run:completed').single;
      expect(completed['hookId'], 'video-1');
      expect(completed['status'], 'completed');
      final state = latestSnapshotState();
      expect(state['status'], 'success');
      expect(state['isLoading'], isFalse);
      expect(state['jobId'], 'job-1');
      expect((state['result'] as VideoGenerateResult).url,
          'https://example.com/video.mp4');

      client.dispose();
    });

    test('includes input, progress, and renderable previews in video snapshots',
        () async {
      // ignore: prefer_function_declarations_over_variables
      final connect = (List<WireMessage> messages,
          {Map<String, dynamic>? data,
          CancellationSignal? signal,
          RunAgentInputContext? runContext}) async* {
        yield runStartedChunk('video-run');
        yield custom(GenerationEvents.videoJobCreated, {'jobId': 'job-1'});
        yield custom(GenerationEvents.videoStatus, {
          'jobId': 'job-1',
          'status': 'processing',
          'progress': 60,
          'url': 'https://example.com/preview.mp4',
        });
        yield custom(GenerationEvents.result, {
          'jobId': 'job-1',
          'status': 'completed',
          'url': 'https://example.com/final.mp4',
        });
        yield runFinishedChunk('video-run');
      };
      final client = VideoGenerationClient<VideoGenerateResult>(
        threadId: 'video-hook',
        connection: ConnectionAdapter(connect: connect),
        devtools: const GenerationDevtoolsMetadata(
          hookName: 'useGenerateVideo',
          outputKind: 'video',
        ),
        devtoolsBridgeFactory: recorder.factory,
      );
      recorder.eventClient.clearEvents();

      await client.generate(
        const VideoGenerateInput(prompt: 'A flying car', duration: 4),
      );

      final state = latestSnapshotState();
      expect((state['input'] as VideoGenerateInput).toJson(), {
        'prompt': 'A flying car',
        'duration': 4,
      });
      expect(state['progress'], {'value': 100});
      expect(state['preview'], {
        'kind': 'video',
        'items': [
          {'src': 'https://example.com/final.mp4', 'sourceType': 'url'},
        ],
        'job': {'jobId': 'job-1', 'status': 'completed', 'progress': 100},
      });

      client.dispose();
    });

    test('retains grouped video generation snapshots for previous runs',
        () async {
      // ignore: prefer_function_declarations_over_variables
      final connect = (List<WireMessage> messages,
          {Map<String, dynamic>? data,
          CancellationSignal? signal,
          RunAgentInputContext? runContext}) async* {
        final prompt =
            data?['prompt'] is String ? data!['prompt'] as String : 'unknown';
        final runId = 'video-run-$prompt';
        final jobId = 'job-$prompt';
        yield runStartedChunk(runId);
        yield custom(GenerationEvents.videoJobCreated, {'jobId': jobId});
        yield custom(GenerationEvents.videoStatus, {
          'jobId': jobId,
          'status': 'processing',
          'progress': 70,
        });
        yield custom(GenerationEvents.result, {
          'jobId': jobId,
          'status': 'completed',
          'url': 'https://example.com/$prompt.mp4',
        });
        yield runFinishedChunk(runId);
      };
      final client = VideoGenerationClient<VideoGenerateResult>(
        threadId: 'video-history',
        connection: ConnectionAdapter(connect: connect),
        devtools: const GenerationDevtoolsMetadata(
          hookName: 'useGenerateVideo',
          outputKind: 'video',
        ),
        devtoolsBridgeFactory: recorder.factory,
      );
      recorder.eventClient.clearEvents();

      await client.generate(const VideoGenerateInput(prompt: 'one'));
      await client.generate(const VideoGenerateInput(prompt: 'two'));

      final runs = latestGenerationRuns();
      expect(runs, hasLength(2));
      for (final prompt in ['one', 'two']) {
        final run = runs.firstWhere((run) => run['id'] == 'video-run-$prompt');
        expect((run['input'] as VideoGenerateInput).toJson(), {
          'prompt': prompt,
        });
        expect(run['status'], 'success');
        expect(run['isLoading'], isFalse);
        expect(run['progress'], {'value': 100});
        expect(run['jobId'], 'job-$prompt');
        final videoStatus = run['videoStatus'] as VideoStatusInfo?;
        expect(videoStatus?.jobId, 'job-$prompt');
        expect(videoStatus?.status, 'completed');
        expect(videoStatus?.progress, 100);
        expect(videoStatus?.url, 'https://example.com/$prompt.mp4');
        expect(run['preview'], {
          'kind': 'video',
          'items': [
            {
              'src': 'https://example.com/$prompt.mp4',
              'sourceType': 'url',
            },
          ],
          'job': {
            'jobId': 'job-$prompt',
            'status': 'completed',
            'progress': 100,
          },
        });
      }

      client.dispose();
    });

    test('emits generation lifecycle through the real devtools adapter',
        () async {
      final events = InMemoryAIDevtoolsEventClient();
      final client = GenerationClient(
        connection: mockConnection([
          runStarted('run-real'),
          custom(GenerationEvents.result, {'id': 'real-result'}),
          runFinished('run-real'),
        ]),
        devtools: const GenerationDevtoolsMetadata(
          framework: 'react',
          hookName: 'useGeneration',
        ),
        devtoolsBridgeFactory: createGenerationClientDevtoolsBridgeFactory(
          eventClient: events,
          production: false,
        ),
      );

      await client.generate({'prompt': 'real'});

      expect(events.emitted('hook:registered'), isNotEmpty);
      final snapshots = events.emitted('hook:state-snapshot');
      expect(snapshots, isNotEmpty);
      final state = snapshots.last.payload['state'] as Map<String, dynamic>;
      final runs = state['runs'] as List;
      expect(runs, isNotEmpty);
      expect((runs.last as Map)['result'], {'id': 'real-result'});

      client.dispose();
    });
  });
}

// Dynamic helpers keep the harness usable with both concrete client types,
// mirroring the upstream `RunClient` structural interface.
void Function() _subscribe(dynamic client, void Function() listener) =>
    client.subscribe(listener) as void Function();

Future<void> _generate(dynamic client, String prompt) async {
  if (_isVideoClient(client)) {
    await client.generate(VideoGenerateInput(prompt: prompt));
  } else {
    await client.generate({'prompt': prompt});
  }
}

void _stop(dynamic client) => client.stop();

String? _snapshotRunId(dynamic client) => client.getSnapshot().runId as String?;

Object? _errorOf(dynamic client) => client.getError();

bool _isVideoClient(dynamic client) =>
    client is VideoGenerationClient<VideoGenerateResult>;
