import 'package:tanstack_ai_dart/devtools.dart';
import 'package:test/test.dart';

import 'support.dart';

class CallbackSetup<TOutput> {
  final InMemoryAIDevtoolsEventClient eventClient;
  final GenerationDevtoolsBridge<TOutput> bridge;
  final TOutput successResult;
  final String failureMessage;
  final void Function(bool) setLoading;
  final void Function(TOutput?) setResult;
  final void Function(AIDevtoolsGenerationRunStatus) setStatus;
  final void Function(String?) setError;
  int fetchCalls = 0;

  CallbackSetup({
    required this.eventClient,
    required this.bridge,
    required this.successResult,
    required this.failureMessage,
    required this.setLoading,
    required this.setResult,
    required this.setStatus,
    required this.setError,
  });
}

CallbackSetup<Map<String, Object?>> generationCallbackSetup(String hookName) {
  final harness = GenerationHarness<Map<String, Object?>>(
    hookName: hookName,
    outputKind: 'structured',
  );
  return CallbackSetup<Map<String, Object?>>(
    eventClient: harness.eventClient,
    bridge: harness.bridge,
    successResult: const <String, Object?>{'text': 'done'},
    failureMessage: 'generation failed',
    setLoading: (value) => harness.core.isLoading = value,
    setResult: (value) => harness.core.result = value,
    setStatus: (value) => harness.core.status = value,
    setError: (value) => harness.core.error = value,
  );
}

CallbackSetup<Map<String, Object?>> videoCallbackSetup(String hookName) {
  final harness = VideoHarness<Map<String, Object?>>(
    hookName: hookName,
    outputKind: 'video',
  );
  return CallbackSetup<Map<String, Object?>>(
    eventClient: harness.eventClient,
    bridge: harness.bridge,
    successResult: const <String, Object?>{
      'jobId': 'done',
      'status': 'completed',
      'url': 'https://example.com/video-1.mp4',
    },
    failureMessage: 'video failed',
    setLoading: (value) => harness.core.isLoading = value,
    setResult: (value) => harness.core.result = value,
    setStatus: (value) => harness.core.status = value,
    setError: (value) => harness.core.error = value,
  );
}

void callbackStopCases<TOutput>({
  required String name,
  required CallbackSetup<TOutput> Function(String hookName) create,
}) {
  group("'$name' devtools run stopped from a callback", () {
    test('finishes the run when a runId subscriber stops it', () {
      final setup = create('useRunIdStop');
      final runId = setup.bridge.beginRun(
        const <String, Object?>{'prompt': 'stop early'},
      );

      // The runId subscriber stops as soon as the id is published, before the
      // fetcher is invoked.
      final activeRunId = setup.bridge.getActiveRunId();
      if (activeRunId != null) {
        setup.bridge.finishRun(
          runId,
          AIDevtoolsRunEventType.cancelled,
          AIDevtoolsRunStatus.cancelled,
        );
      }

      expect(setup.fetchCalls, 0);
      expect(latestState(setup.eventClient)['activeRunId'], isNull);
      expect(latestRuns(setup.eventClient).last['status'], 'cancelled');
    });

    test('finishes the run when loading callback stops it', () {
      final setup = create('useLoadingStop');
      final runId = setup.bridge.beginRun(
        const <String, Object?>{'prompt': 'stop while loading'},
      );

      setup.setLoading(true);
      setup.bridge.recordLoadingChange();
      // The loading callback sees isLoading and stops.
      setup.bridge.finishRun(
        runId,
        AIDevtoolsRunEventType.cancelled,
        AIDevtoolsRunStatus.cancelled,
      );

      expect(setup.fetchCalls, 0);
      expect(latestState(setup.eventClient)['activeRunId'], isNull);
      expect(latestRuns(setup.eventClient).last['status'], 'cancelled');
    });

    test('finishes a completed run when success callback stops it', () {
      final setup = create('useSuccessStop');
      final runId = setup.bridge.beginRun(
        const <String, Object?>{'prompt': 'finish then stop'},
      );

      setup.setResult(setup.successResult);
      setup.setStatus(AIDevtoolsGenerationRunStatus.success);
      setup.bridge.recordResultChange();
      setup.bridge.recordStatusChange(
        AIDevtoolsGenerationRunStatus.success,
      );
      // The success callback stops after the result lands.
      setup.bridge.finishRun(
        runId,
        AIDevtoolsRunEventType.completed,
        AIDevtoolsRunStatus.completed,
      );

      expect(latestState(setup.eventClient)['activeRunId'], isNull);
      final run = latestRuns(setup.eventClient).last;
      expect(run['status'], 'success');
      expect(run['result'], setup.successResult);
    });

    test('records an errored run when onStatusChange stops it', () {
      final setup = create('useErrorStop');
      final runId = setup.bridge.beginRun(
        const <String, Object?>{'prompt': 'fail then stop'},
      );

      setup.setError(setup.failureMessage);
      setup.setStatus(AIDevtoolsGenerationRunStatus.error);
      setup.bridge.recordStatusChange(
        AIDevtoolsGenerationRunStatus.error,
      );
      setup.bridge.finishRun(
        runId,
        AIDevtoolsRunEventType.errored,
        AIDevtoolsRunStatus.errored,
        error: setup.failureMessage,
      );

      expect(latestState(setup.eventClient)['activeRunId'], isNull);
      final run = latestRuns(setup.eventClient).last;
      expect(run['status'], 'error');
      expect(run['error'], setup.failureMessage);
    });

    test('records an errored run when onErrorChange stops it', () {
      final setup = create('useErrorStop');
      final runId = setup.bridge.beginRun(
        const <String, Object?>{'prompt': 'fail then stop'},
      );

      setup.setError(setup.failureMessage);
      setup.setStatus(AIDevtoolsGenerationRunStatus.error);
      setup.bridge.recordErrorChange(StateError(setup.failureMessage));
      setup.bridge.finishRun(
        runId,
        AIDevtoolsRunEventType.errored,
        AIDevtoolsRunStatus.errored,
        error: setup.failureMessage,
      );

      expect(latestState(setup.eventClient)['activeRunId'], isNull);
      final run = latestRuns(setup.eventClient).last;
      expect(run['status'], 'error');
      expect(run['error'], setup.failureMessage);
    });
  });
}

void main() {
  group('generation client devtools bridge', () {
    callbackStopCases<Map<String, Object?>>(
      name: 'generation',
      create: generationCallbackSetup,
    );
    callbackStopCases<Map<String, Object?>>(
      name: 'video',
      create: videoCallbackSetup,
    );

    test('normalizes generation results into renderable devtools previews', () {
      expect(
        createAIDevtoolsGenerationPreview(
          const AIDevtoolsGenerationPreviewInput(
            outputKind: 'image',
            result: <String, Object?>{
              'id': 'img-1',
              'model': 'image-model',
              'images': <Object?>[
                <String, Object?>{
                  'url': 'https://example.com/image.png',
                },
                <String, Object?>{'b64Json': 'iVBORw0KGgo='},
              ],
            },
          ),
        ),
        const AIDevtoolsImagePreview(
          items: <AIDevtoolsGenerationMediaItem>[
            AIDevtoolsGenerationMediaItem(
              src: 'https://example.com/image.png',
              sourceType: 'url',
            ),
            AIDevtoolsGenerationMediaItem(
              src: 'data:image/png;base64,iVBORw0KGgo=',
              sourceType: 'base64',
              mimeType: 'image/png',
            ),
          ],
        ),
      );

      expect(
        createAIDevtoolsGenerationPreview(
          const AIDevtoolsGenerationPreviewInput(
            outputKind: 'audio',
            result: <String, Object?>{
              'id': 'speech-1',
              'model': 'tts-model',
              'audio': 'UklGRg==',
              'format': 'wav',
              'contentType': 'audio/wav',
            },
          ),
        ),
        const AIDevtoolsAudioPreview(
          items: <AIDevtoolsGenerationMediaItem>[
            AIDevtoolsGenerationMediaItem(
              src: 'data:audio/wav;base64,UklGRg==',
              sourceType: 'base64',
              mimeType: 'audio/wav',
              format: 'wav',
            ),
          ],
        ),
      );

      expect(
        createAIDevtoolsGenerationPreview(
          const AIDevtoolsGenerationPreviewInput(
            outputKind: 'text',
            result: <String, Object?>{
              'id': 'transcription-1',
              'model': 'whisper',
              'text': 'Hello world',
            },
          ),
        ),
        const AIDevtoolsTextPreview(text: 'Hello world'),
      );

      expect(
        createAIDevtoolsGenerationPreview(
          const AIDevtoolsGenerationPreviewInput(
            outputKind: 'video',
            result: null,
            videoStatus: <String, Object?>{
              'jobId': 'job-1',
              'status': 'processing',
              'progress': 50,
              'url': 'https://example.com/video.mp4',
            },
          ),
        ),
        const AIDevtoolsVideoPreview(
          items: <AIDevtoolsGenerationMediaItem>[
            AIDevtoolsGenerationMediaItem(
              src: 'https://example.com/video.mp4',
              sourceType: 'url',
            ),
          ],
          job: AIDevtoolsGenerationVideoJob(
            jobId: 'job-1',
            status: 'processing',
            progress: 50,
          ),
        ),
      );
    });

    test('registers a generation hook and emits run lifecycle for fetcher mode',
        () {
      final harness = GenerationHarness<Map<String, Object?>>(
        hookName: 'useGenerateObject',
        outputKind: 'structured',
      );
      harness.bridge.emitRegistered();
      harness.core.input = const <String, Object?>{'prompt': 'make object'};
      final runId = harness.bridge.beginRun(harness.core.input);
      harness.core.result = const <String, Object?>{'text': 'done'};
      harness.core.status = AIDevtoolsGenerationRunStatus.success;
      harness.core.isLoading = false;
      harness.bridge.recordResultChange();
      harness.bridge.recordStatusChange(
        AIDevtoolsGenerationRunStatus.success,
      );
      harness.bridge.finishRun(
        runId,
        AIDevtoolsRunEventType.completed,
        AIDevtoolsRunStatus.completed,
      );

      final started = harness.eventClient.emitted('run:started').single.payload;
      expect(started['hookId'], 'gen-1');
      expect(started['source'], 'client');
      expect(started['visibility'], 'client-state');
      expect(started['runId'], isA<String>());
      expect(started['status'], 'started');

      final completed =
          harness.eventClient.emitted('run:completed').single.payload;
      expect(completed['hookId'], 'gen-1');
      expect(completed['source'], 'client');
      expect(completed['visibility'], 'client-state');
      expect(completed['runId'], isA<String>());
      expect(completed['status'], 'completed');

      final state = latestState(harness.eventClient);
      expect(state['status'], 'success');
      expect(state['isLoading'], isFalse);
      expect(state['result'], {'text': 'done'});

      harness.bridge.dispose();
    });

    test(
        'includes input, progress, and renderable previews in generation snapshots',
        () {
      final harness = GenerationHarness<Map<String, Object?>>(
        hookName: 'useGenerateImage',
        outputKind: 'image',
      );
      harness.core.input = const <String, Object?>{
        'prompt': 'A quiet desk',
        'numberOfImages': 2,
      };
      final runId = harness.bridge.beginRun(harness.core.input);
      harness.core.result = const <String, Object?>{
        'id': 'img-1',
        'model': 'image-model',
        'images': <Object?>[
          <String, Object?>{'url': 'https://example.com/image.png'},
          <String, Object?>{'b64Json': 'iVBORw0KGgo='},
        ],
      };
      harness.core.status = AIDevtoolsGenerationRunStatus.success;
      harness.core.isLoading = false;
      harness.bridge.recordResultChange();
      harness.bridge.finishRun(
        runId,
        AIDevtoolsRunEventType.completed,
        AIDevtoolsRunStatus.completed,
      );

      final state = latestState(harness.eventClient);
      expect(state['input'], {
        'prompt': 'A quiet desk',
        'numberOfImages': 2,
      });
      expect(state['progress'], isNull);
      expect(state['preview'], {
        'kind': 'image',
        'items': [
          {
            'src': 'https://example.com/image.png',
            'sourceType': 'url',
          },
          {
            'src': 'data:image/png;base64,iVBORw0KGgo=',
            'sourceType': 'base64',
            'mimeType': 'image/png',
          },
        ],
      });

      harness.bridge.dispose();
    });

    test('tracks streamed progress in generation snapshots', () {
      final harness = GenerationHarness<Map<String, Object?>>(
        hookName: 'useSummarize',
        outputKind: 'text',
      );
      harness.core.input = const <String, Object?>{'text': 'Long text'};
      final runId = harness.bridge.beginRun(harness.core.input);
      harness.core.progress = const AIDevtoolsGenerationProgress(
        value: 40,
        message: 'Rendering preview',
      );
      harness.bridge.recordProgressChange();
      harness.core.result = const <String, Object?>{
        'summary': 'short version',
      };
      harness.core.status = AIDevtoolsGenerationRunStatus.success;
      harness.core.isLoading = false;
      harness.bridge.recordResultChange();
      // The client publishes the final 100% progress before finishing.
      harness.core.progress = const AIDevtoolsGenerationProgress(
        value: 100,
        message: 'Rendering preview',
      );
      harness.bridge.finishRun(
        runId,
        AIDevtoolsRunEventType.completed,
        AIDevtoolsRunStatus.completed,
      );

      final state = latestState(harness.eventClient);
      expect(state['input'], {'text': 'Long text'});
      expect(state['progress'], {
        'value': 100,
        'message': 'Rendering preview',
      });
      expect(state['preview'], {
        'kind': 'text',
        'text': 'short version',
      });

      harness.bridge.dispose();
    });

    test('retains grouped generation snapshots for previous runs', () {
      final harness = GenerationHarness<Map<String, Object?>>(
        hookName: 'useGenerateImage',
        outputKind: 'image',
      );

      void run(String prompt, String serverRunId) {
        harness.core.input = <String, Object?>{'prompt': prompt};
        final localRunId = harness.bridge.beginRun(harness.core.input);
        harness.bridge.ensureRunStarted(serverRunId);
        expect(localRunId, isNot(serverRunId));
        harness.core.progress = AIDevtoolsGenerationProgress(
          value: 70,
          message: 'Rendering $prompt',
        );
        harness.bridge.recordProgressChange();
        harness.core.result = <String, Object?>{
          'id': 'img-$prompt',
          'model': 'image-model',
          'images': <Object?>[
            <String, Object?>{'url': 'https://example.com/$prompt.png'},
          ],
        };
        harness.bridge.recordResultChange();
        harness.bridge.finishRun(
          serverRunId,
          AIDevtoolsRunEventType.completed,
          AIDevtoolsRunStatus.completed,
        );
      }

      run('one', 'run-one');
      run('two', 'run-two');

      final runs = latestRuns(harness.eventClient);
      expect(runs, hasLength(2));
      expect(runs[0]['id'], 'run-one');
      expect(runs[0]['input'], {'prompt': 'one'});
      expect(runs[0]['status'], 'success');
      expect(runs[0]['isLoading'], isFalse);
      expect(runs[0]['progress'], {
        'value': 100,
        'message': 'Rendering one',
      });
      expect((runs[0]['result'] as Map)['id'], 'img-one');
      expect(runs[0]['preview'], {
        'kind': 'image',
        'items': [
          {
            'src': 'https://example.com/one.png',
            'sourceType': 'url',
          },
        ],
      });

      expect(runs[1]['id'], 'run-two');
      expect(runs[1]['input'], {'prompt': 'two'});
      expect(runs[1]['status'], 'success');
      expect(runs[1]['isLoading'], isFalse);
      expect(runs[1]['progress'], {
        'value': 100,
        'message': 'Rendering two',
      });
      expect((runs[1]['result'] as Map)['id'], 'img-two');
      expect(runs[1]['preview'], {
        'kind': 'image',
        'items': [
          {
            'src': 'https://example.com/two.png',
            'sourceType': 'url',
          },
        ],
      });

      harness.bridge.dispose();
    });

    test('responds to devtools state requests for a generation hook', () {
      final harness = GenerationHarness<Map<String, Object?>>(
        hookName: 'useGenerateText',
        outputKind: 'text',
      );
      harness.bridge.emitRegistered();
      harness.eventClient.clear();

      harness.eventClient.dispatch('devtools:request-state', {
        'targetHookId': 'gen-1',
      });

      final registered =
          harness.eventClient.emitted('hook:registered').single.payload;
      expect(registered['hookId'], 'gen-1');
      expect(registered['hookName'], 'useGenerateText');
      expect(registered['framework'], 'react');
      expect(registered['outputKind'], 'text');

      final snapshot =
          harness.eventClient.emitted('hook:state-snapshot').single.payload;
      expect(snapshot['hookId'], 'gen-1');
      final state = snapshot['state'] as Map;
      expect(state['status'], 'idle');
      expect(state['isLoading'], isFalse);
      expect(state['result'], isNull);
      expect(state['activeRunId'], isNull);

      harness.bridge.dispose();
    });

    test('emits errored run lifecycle for generation failures', () {
      final harness = GenerationHarness<Map<String, Object?>>(
        hookName: 'useGenerateObject',
        outputKind: 'structured',
      );
      harness.core.input = const <String, Object?>{'prompt': 'fail'};
      final runId = harness.bridge.beginRun(harness.core.input);
      harness.core.error = 'Generation failed';
      harness.core.status = AIDevtoolsGenerationRunStatus.error;
      harness.core.isLoading = false;
      harness.bridge.recordErrorChange(StateError('Generation failed'));
      harness.bridge.recordStatusChange(
        AIDevtoolsGenerationRunStatus.error,
      );
      harness.bridge.finishRun(
        runId,
        AIDevtoolsRunEventType.errored,
        AIDevtoolsRunStatus.errored,
        error: 'Generation failed',
      );

      final errored = harness.eventClient.emitted('run:errored').single.payload;
      expect(errored['hookId'], 'gen-1');
      expect(errored['runId'], isA<String>());
      expect(errored['status'], 'errored');
      expect(errored['error'], 'Generation failed');

      final state = latestState(harness.eventClient);
      expect(state['status'], 'error');
      expect(state['isLoading'], isFalse);
      expect(state['error'], 'Generation failed');

      harness.bridge.dispose();
    });

    test('registers a generation hook for streaming connection mode', () {
      final harness = GenerationHarness<Map<String, Object?>>(
        hookName: 'useGenerateText',
        outputKind: 'text',
      );
      harness.core.input = const <String, Object?>{'prompt': 'stream'};
      final localRunId = harness.bridge.beginRun(harness.core.input);
      harness.bridge.ensureRunStarted('server-run-1');
      harness.core.result = const <String, Object?>{'text': 'streamed'};
      harness.core.status = AIDevtoolsGenerationRunStatus.success;
      harness.core.isLoading = false;
      harness.bridge.recordResultChange();
      harness.bridge.finishRun(
        'server-run-1',
        AIDevtoolsRunEventType.completed,
        AIDevtoolsRunStatus.completed,
      );

      final started = harness.eventClient.emitted('run:started');
      expect(started, hasLength(1));
      expect(started.single.payload['runId'], 'server-run-1');
      expect(started.single.payload['runId'], isNot(localRunId));

      final completed = harness.eventClient.emitted('run:completed');
      expect(completed.single.payload['runId'], 'server-run-1');

      final state = latestState(harness.eventClient);
      expect(state['status'], 'success');
      expect(state['isLoading'], isFalse);
      expect(state['result'], {'text': 'streamed'});

      harness.bridge.dispose();
    });

    test('does not emit hook updates after disposal', () {
      final harness = GenerationHarness<Map<String, Object?>>(
        hookName: 'useGenerateText',
        outputKind: 'text',
      );
      harness.bridge.emitRegistered();
      harness.core.input = const <String, Object?>{'prompt': 'slow'};
      harness.bridge.beginRun(harness.core.input);

      harness.bridge.dispose();
      final unregisteredIndex = harness.eventClient.events.indexWhere(
        (event) => event.name == 'hook:unregistered',
      );
      expect(unregisteredIndex, greaterThanOrEqualTo(0));

      harness.core.result = const <String, Object?>{'text': 'late'};
      harness.bridge.recordResultChange();

      final emittedAfterDispose = harness.eventClient.events
          .skip(unregisteredIndex + 1)
          .map((event) => event.name)
          .toList();
      expect(emittedAfterDispose, isNot(contains('hook:updated')));
      expect(emittedAfterDispose, isNot(contains('hook:state-snapshot')));
    });

    test('uses the stream run id for video connection lifecycle events', () {
      final harness = VideoHarness<Map<String, Object?>>(
        hookName: 'useGenerateVideo',
        outputKind: 'video',
      );
      harness.core.input = const <String, Object?>{'prompt': 'stream video'};
      final localRunId = harness.bridge.beginRun(harness.core.input);
      harness.bridge.ensureRunStarted('server-video-run-1');
      harness.core.result = const <String, Object?>{
        'jobId': 'job-1',
        'status': 'completed',
        'url': 'https://example.com/video.mp4',
      };
      harness.core.status = AIDevtoolsGenerationRunStatus.success;
      harness.core.isLoading = false;
      harness.bridge.recordResultChange();
      harness.bridge.finishRun(
        'server-video-run-1',
        AIDevtoolsRunEventType.completed,
        AIDevtoolsRunStatus.completed,
      );

      final started = harness.eventClient.emitted('run:started');
      expect(started, hasLength(1));
      expect(started.single.payload['runId'], 'server-video-run-1');
      expect(started.single.payload['runId'], isNot(localRunId));
      expect(
        harness.eventClient.emitted('run:completed').single.payload['runId'],
        'server-video-run-1',
      );

      harness.bridge.dispose();
    });

    test('registers a video hook and includes job state in snapshots', () {
      final harness = VideoHarness<Map<String, Object?>>(
        hookName: 'useGenerateVideo',
        outputKind: 'video',
      );
      harness.bridge.emitRegistered();
      harness.core.input = const <String, Object?>{'prompt': 'make video'};
      final runId = harness.bridge.beginRun(harness.core.input);
      harness.core.jobId = 'job-1';
      harness.bridge.recordJobIdChange();
      harness.core.result = const <String, Object?>{
        'jobId': 'job-1',
        'status': 'completed',
        'url': 'https://example.com/video.mp4',
      };
      harness.core.status = AIDevtoolsGenerationRunStatus.success;
      harness.core.isLoading = false;
      harness.bridge.recordResultChange();
      harness.bridge.finishRun(
        runId,
        AIDevtoolsRunEventType.completed,
        AIDevtoolsRunStatus.completed,
      );

      final registered =
          harness.eventClient.emitted('hook:registered').single.payload;
      expect(registered['hookId'], 'video-1');
      expect(registered['hookName'], 'useGenerateVideo');
      expect(registered['framework'], 'react');
      expect(registered['outputKind'], 'video');

      final completed =
          harness.eventClient.emitted('run:completed').single.payload;
      expect(completed['hookId'], 'video-1');
      expect(completed['status'], 'completed');

      final state = latestState(harness.eventClient);
      expect(state['status'], 'success');
      expect(state['isLoading'], isFalse);
      expect(state['jobId'], 'job-1');
      expect((state['result'] as Map)['url'], 'https://example.com/video.mp4');

      harness.bridge.dispose();
    });

    test('includes input, progress, and renderable previews in video snapshots',
        () {
      final harness = VideoHarness<Map<String, Object?>>(
        hookName: 'useGenerateVideo',
        outputKind: 'video',
      );
      harness.core.input = const <String, Object?>{
        'prompt': 'A flying car',
        'duration': 4,
      };
      final runId = harness.bridge.beginRun(harness.core.input);
      harness.core.jobId = 'job-1';
      harness.bridge.recordJobIdChange();
      harness.core.videoStatus = const <String, Object?>{
        'jobId': 'job-1',
        'status': 'processing',
        'progress': 60,
        'url': 'https://example.com/preview.mp4',
      };
      harness.bridge.recordVideoStatusChange();
      harness.core.progress = const AIDevtoolsGenerationProgress(value: 60);
      harness.bridge.recordProgressChange();
      harness.core.result = const <String, Object?>{
        'jobId': 'job-1',
        'status': 'completed',
        'url': 'https://example.com/final.mp4',
      };
      harness.core.videoStatus = const <String, Object?>{
        'jobId': 'job-1',
        'status': 'completed',
        'progress': 100,
        'url': 'https://example.com/final.mp4',
      };
      harness.core.status = AIDevtoolsGenerationRunStatus.success;
      harness.core.isLoading = false;
      harness.bridge.recordResultChange();
      // The client publishes the final 100% progress before finishing.
      harness.core.progress = const AIDevtoolsGenerationProgress(value: 100);
      harness.bridge.finishRun(
        runId,
        AIDevtoolsRunEventType.completed,
        AIDevtoolsRunStatus.completed,
      );

      final state = latestState(harness.eventClient);
      expect(state['input'], {'prompt': 'A flying car', 'duration': 4});
      expect(state['progress'], {'value': 100});
      expect(state['preview'], {
        'kind': 'video',
        'items': [
          {
            'src': 'https://example.com/final.mp4',
            'sourceType': 'url',
          },
        ],
        'job': {
          'jobId': 'job-1',
          'status': 'completed',
          'progress': 100,
        },
      });

      harness.bridge.dispose();
    });

    test('retains grouped video generation snapshots for previous runs', () {
      final harness = VideoHarness<Map<String, Object?>>(
        hookName: 'useGenerateVideo',
        outputKind: 'video',
      );

      void run(String prompt) {
        final serverRunId = 'video-run-$prompt';
        final jobId = 'job-$prompt';
        harness.core.input = <String, Object?>{'prompt': prompt};
        harness.bridge.beginRun(harness.core.input);
        harness.bridge.ensureRunStarted(serverRunId);
        harness.core.jobId = jobId;
        harness.bridge.recordJobIdChange();
        harness.core.videoStatus = <String, Object?>{
          'jobId': jobId,
          'status': 'processing',
          'progress': 70,
        };
        harness.bridge.recordVideoStatusChange();
        harness.core.progress = const AIDevtoolsGenerationProgress(value: 70);
        harness.bridge.recordProgressChange();
        harness.core.result = <String, Object?>{
          'jobId': jobId,
          'status': 'completed',
          'url': 'https://example.com/$prompt.mp4',
        };
        harness.core.videoStatus = <String, Object?>{
          'jobId': jobId,
          'status': 'completed',
          'progress': 100,
          'url': 'https://example.com/$prompt.mp4',
        };
        harness.bridge.recordVideoStatusChange();
        harness.bridge.recordResultChange();
        harness.bridge.finishRun(
          serverRunId,
          AIDevtoolsRunEventType.completed,
          AIDevtoolsRunStatus.completed,
        );
      }

      run('one');
      run('two');

      final runs = latestRuns(harness.eventClient);
      expect(runs, hasLength(2));
      expect(runs[0]['id'], 'video-run-one');
      expect(runs[0]['input'], {'prompt': 'one'});
      expect(runs[0]['status'], 'success');
      expect(runs[0]['isLoading'], isFalse);
      expect(runs[0]['progress'], {'value': 100});
      expect(runs[0]['jobId'], 'job-one');
      final firstVideoStatus = runs[0]['videoStatus'] as Map;
      expect(firstVideoStatus['jobId'], 'job-one');
      expect(firstVideoStatus['status'], 'completed');
      expect(firstVideoStatus['progress'], 100);
      expect(
        firstVideoStatus['url'],
        'https://example.com/one.mp4',
      );
      expect(runs[0]['preview'], {
        'kind': 'video',
        'items': [
          {
            'src': 'https://example.com/one.mp4',
            'sourceType': 'url',
          },
        ],
        'job': {
          'jobId': 'job-one',
          'status': 'completed',
          'progress': 100,
        },
      });

      expect(runs[1]['id'], 'video-run-two');
      expect(runs[1]['input'], {'prompt': 'two'});
      expect(runs[1]['status'], 'success');
      expect(runs[1]['isLoading'], isFalse);
      expect(runs[1]['progress'], {'value': 100});
      expect(runs[1]['jobId'], 'job-two');
      final secondVideoStatus = runs[1]['videoStatus'] as Map;
      expect(secondVideoStatus['jobId'], 'job-two');
      expect(secondVideoStatus['status'], 'completed');
      expect(secondVideoStatus['progress'], 100);
      expect(
        secondVideoStatus['url'],
        'https://example.com/two.mp4',
      );

      harness.bridge.dispose();
    });
  });

  group('createVideoDevtoolsBridge by environment', () {
    test('emits no devtools events in production', () {
      final harness = VideoHarness<Map<String, Object?>>();
      final bridge = createVideoDevtoolsBridge<Map<String, Object?>>(
        harness.options,
        production: true,
      );

      final runId = bridge.beginRun(const <String, Object?>{'prompt': 'x'});
      bridge.recordJobIdChange();
      bridge.recordVideoStatusChange();

      expect(runId, isNotEmpty);
      expect(harness.eventClient.events, isEmpty);
      expect(bridge, isA<NoOpVideoDevtoolsBridge<Map<String, Object?>>>());
      bridge.dispose();
    });

    test('creates a real video bridge in development', () {
      final harness = VideoHarness<Map<String, Object?>>();
      final bridge = createVideoDevtoolsBridge<Map<String, Object?>>(
        harness.options,
        production: false,
      );

      expect(bridge, isA<VideoDevtoolsBridge<Map<String, Object?>>>());
      expect(
        bridge,
        isNot(isA<NoOpVideoDevtoolsBridge<Map<String, Object?>>>()),
      );
      bridge.dispose();
    });
  });

  group('createGenerationDevtoolsBridge by environment', () {
    test('emits no devtools events in production', () {
      final harness = GenerationHarness<Map<String, Object?>>();
      final bridge = createGenerationDevtoolsBridge<Map<String, Object?>>(
        harness.options,
        production: true,
      );

      final runId = bridge.beginRun(const <String, Object?>{'prompt': 'x'});

      expect(runId, isNotEmpty);
      expect(harness.eventClient.events, isEmpty);
      expect(bridge, isA<NoOpGenerationDevtoolsBridge<Map<String, Object?>>>());
      bridge.dispose();
    });

    test('creates a real generation bridge in development', () {
      final harness = GenerationHarness<Map<String, Object?>>();
      final bridge = createGenerationDevtoolsBridge<Map<String, Object?>>(
        harness.options,
        production: false,
      );

      expect(bridge, isA<GenerationDevtoolsBridge<Map<String, Object?>>>());
      expect(
        bridge,
        isNot(isA<NoOpGenerationDevtoolsBridge<Map<String, Object?>>>()),
      );
      bridge.dispose();
    });
  });
}
