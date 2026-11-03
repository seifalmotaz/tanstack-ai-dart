import 'package:tanstack_ai_dart/devtools.dart' as dt;
import 'package:tanstack_ai_dart/generation.dart' as gen;
import 'package:test/test.dart';

import 'support.dart';

class _PortCore {
  Object? input;
  Object? result;
  gen.GenerationDevtoolsProgress? progress;
  String status = 'idle';
  bool isLoading = false;
  Object? error;
  String? jobId;
  Object? videoStatus;

  gen.GenerationDevtoolsPortCoreState state() =>
      gen.GenerationDevtoolsPortCoreState(
        input: input,
        result: result,
        progress: progress,
        status: status,
        isLoading: isLoading,
        error: error,
        jobId: jobId,
        videoStatus: videoStatus,
      );
}

void main() {
  group('createGenerationClientDevtoolsBridgeFactory', () {
    test('delegates port lifecycle, progress, history and live identity', () {
      final events = dt.InMemoryAIDevtoolsEventClient();
      final core = _PortCore();
      var hookId = 'adapter-hook';
      var clientId = 'adapter-client';
      var threadId = 'adapter-thread';

      final options = gen.GenerationDevtoolsBridgePortOptions(
        hookId: () => hookId,
        clientId: () => clientId,
        threadId: () => threadId,
        metadata: const gen.GenerationDevtoolsMetadata(
          framework: 'react',
          hookName: 'useGenerateText',
          outputKind: 'text',
          name: 'Adapter Generation',
        ),
        getCoreState: core.state,
        maxRuns: 1,
      );
      final bridge = dt.createGenerationClientDevtoolsBridgeFactory(
        eventClient: events,
        production: false,
      )(options);

      bridge.emitRegistered();
      final registered = events.emitted('hook:registered').single.payload;
      expect(registered['hookId'], 'adapter-hook');
      expect(registered['clientId'], 'adapter-client');
      expect(registered['threadId'], 'adapter-thread');
      expect(registered['hookName'], 'useGenerateText');
      expect(registered['framework'], 'react');
      expect(registered['outputKind'], 'text');
      expect(registered['displayName'], 'Adapter Generation');

      // Identity stays live after the factory captured the callbacks.
      clientId = 'adapter-client-2';
      threadId = 'adapter-thread-2';
      bridge.emitSnapshot();
      final liveSnapshot = events.emitted('hook:state-snapshot').last.payload;
      expect(liveSnapshot['clientId'], 'adapter-client-2');
      expect(liveSnapshot['threadId'], 'adapter-thread-2');

      core.input = const <String, Object?>{'prompt': 'hello'};
      final runId = bridge.beginRun(core.input);
      core.status = 'generating';
      core.isLoading = true;
      core.progress = const gen.GenerationDevtoolsProgress(
        value: 40,
        message: 'Working',
      );
      bridge.recordProgressChange();

      core.jobId = 'job-1';
      core.videoStatus = const <String, Object?>{
        'jobId': 'job-1',
        'status': 'processing',
      };
      bridge.recordJobIdChange();
      bridge.recordVideoStatusChange();

      core.result = const <String, Object?>{'text': 'done'};
      core.status = 'success';
      core.isLoading = false;
      bridge.recordResultChange();
      bridge.recordStatusChange('success');
      core.progress = const gen.GenerationDevtoolsProgress(
        value: 100,
        message: 'Working',
      );
      bridge.finishRun(runId, 'run:completed', 'completed');

      expect(events.emitted('run:started'), isNotEmpty);
      final completed = events.emitted('run:completed').single.payload;
      expect(completed['runId'], runId);
      expect(completed['hookId'], 'adapter-hook');
      expect(completed['status'], 'completed');

      final state = latestState(events);
      expect(state['status'], 'success');
      expect(state['isLoading'], isFalse);
      expect(state['result'], {'text': 'done'});
      expect(state['progress'], {
        'value': 100,
        'message': 'Working',
      });
      expect(state['activeRunId'], isNull);

      final runs = latestRuns(events);
      expect(runs, hasLength(1));
      expect(runs.single['id'], runId);
      expect(runs.single['input'], {'prompt': 'hello'});
      expect(runs.single['status'], 'success');
      expect(runs.single['progress'], {
        'value': 100,
        'message': 'Working',
      });
      expect(runs.single['result'], {'text': 'done'});
      expect(runs.single['jobId'], 'job-1');
      expect(runs.single['videoStatus'], {
        'jobId': 'job-1',
        'status': 'processing',
      });

      // maxRuns=1 keeps only the newest run.
      core.input = const <String, Object?>{'prompt': 'second'};
      core.result = const <String, Object?>{'text': 'second done'};
      final secondRunId = bridge.beginRun(core.input);
      bridge.recordResultChange();
      bridge.finishRun(secondRunId, 'run:completed', 'completed');
      final history = latestRuns(events);
      expect(history, hasLength(1));
      expect(history.single['id'], secondRunId);

      bridge.resetState();
      bridge.emitState();
      final resetState = latestState(events);
      expect(resetState['activeRunId'], isNull);
      expect(resetState['runs'], isEmpty);

      bridge.dispose();
      expect(events.emitted('hook:unregistered'), hasLength(1));
      final unregisteredIndex = events.events.indexWhere(
        (event) => event.name == 'hook:unregistered',
      );
      core.result = const <String, Object?>{'text': 'late'};
      bridge.recordResultChange();
      final afterDispose =
          events.events.skip(unregisteredIndex + 1).map((event) => event.name);
      expect(afterDispose, isNot(contains('hook:updated')));
      expect(afterDispose, isNot(contains('hook:state-snapshot')));
    });

    test('responds to devtools state requests through the injected sink', () {
      final events = dt.InMemoryAIDevtoolsEventClient();
      final core = _PortCore();
      final options = gen.GenerationDevtoolsBridgePortOptions(
        hookId: () => 'request-hook',
        clientId: () => 'request-client',
        threadId: () => 'request-thread',
        metadata: const gen.GenerationDevtoolsMetadata(
          hookName: 'useGenerateText',
          outputKind: 'text',
        ),
        getCoreState: core.state,
      );
      final bridge = dt.createGenerationClientDevtoolsBridgeFactory(
        eventClient: events,
        production: false,
      )(options);

      bridge.emitRegistered();
      events.clear();
      events.dispatch('devtools:request-state', {
        'targetHookId': 'request-hook',
      });

      final registered = events.emitted('hook:registered').single.payload;
      expect(registered['hookId'], 'request-hook');
      expect(registered['clientId'], 'request-client');
      expect(registered['threadId'], 'request-thread');
      final snapshot = events.emitted('hook:state-snapshot').single.payload;
      expect((snapshot['state'] as Map)['status'], 'idle');
      expect((snapshot['state'] as Map)['activeRunId'], isNull);

      bridge.dispose();
    });

    test('maps errored, cancelled and server run ids onto real bridge state',
        () {
      final events = dt.InMemoryAIDevtoolsEventClient();
      final core = _PortCore();
      final options = gen.GenerationDevtoolsBridgePortOptions(
        hookId: () => 'mapping-hook',
        clientId: () => 'mapping-client',
        threadId: () => 'mapping-thread',
        metadata: const gen.GenerationDevtoolsMetadata(
          hookName: 'useGenerateText',
          outputKind: 'text',
        ),
        getCoreState: core.state,
      );
      final bridge = dt.createGenerationClientDevtoolsBridgeFactory(
        eventClient: events,
        production: false,
      )(options);
      bridge.emitRegistered();

      core.input = const <String, Object?>{'prompt': 'fail'};
      final failingRunId = bridge.beginRun(core.input);
      bridge.ensureRunStarted('server-failing-run');
      core.error = 'boom';
      core.status = 'error';
      core.isLoading = false;
      bridge.recordErrorChange(StateError('boom'));
      bridge.recordStatusChange('error');
      bridge.finishRun(
        'server-failing-run',
        'run:errored',
        'errored',
        error: 'boom',
      );

      final errored = events.emitted('run:errored').single.payload;
      expect(errored['runId'], 'server-failing-run');
      expect(errored['status'], 'errored');
      expect(errored['error'], 'boom');
      final errorState = latestState(events);
      expect(errorState['status'], 'error');
      expect(errorState['isLoading'], isFalse);
      expect(errorState['error'], 'boom');
      final errorRun = latestRuns(events).last;
      expect(errorRun['id'], 'server-failing-run');
      expect(errorRun['status'], 'error');
      expect(errorRun['error'], 'boom');

      core.input = const <String, Object?>{'prompt': 'cancel'};
      core.error = null;
      core.status = 'generating';
      final cancelRunId = bridge.beginRun(core.input);
      expect(cancelRunId, isNot('server-failing-run'));
      bridge.finishRun(cancelRunId, 'run:cancelled', 'cancelled');

      final cancelled = events.emitted('run:cancelled').single.payload;
      expect(cancelled['status'], 'cancelled');
      final cancelledRun = latestRuns(events).last;
      expect(cancelledRun['status'], 'cancelled');
      expect(cancelledRun['isLoading'], isFalse);

      bridge.resetRuns();
      bridge.emitState();
      expect(latestRuns(events), isEmpty);
      expect(latestState(events)['activeRunId'], isNull);

      bridge.dispose();
      expect(events.emitted('hook:unregistered'), hasLength(1));
      expect(failingRunId, isNotEmpty);
    });

    test('returns the production no-op bridge and emits nothing', () {
      final events = dt.InMemoryAIDevtoolsEventClient();
      final core = _PortCore();
      final options = gen.GenerationDevtoolsBridgePortOptions(
        hookId: () => 'noop-hook',
        clientId: () => 'noop-client',
        threadId: () => 'noop-thread',
        metadata: const gen.GenerationDevtoolsMetadata(
          hookName: 'useGenerateText',
          outputKind: 'text',
        ),
        getCoreState: core.state,
      );

      final bridge = dt.createGenerationClientDevtoolsBridgeFactory(
        eventClient: events,
        production: true,
      )(options);

      expect(bridge, isA<gen.NoOpGenerationDevtoolsBridgePort>());
      bridge.emitRegistered();
      bridge.beginRun(const <String, Object?>{'prompt': 'x'});
      bridge.recordResultChange();
      bridge.recordProgressChange();
      bridge.recordJobIdChange();
      bridge.recordVideoStatusChange();
      bridge.finishRun('run-x', 'run:completed', 'completed');
      bridge.dispose();

      expect(events.events, isEmpty);
    });

    test('wires the real GenerationClient onto emitted devtools state',
        () async {
      final events = dt.InMemoryAIDevtoolsEventClient();
      final client = gen.GenerationClient<Map<String, dynamic>,
          Map<String, dynamic>, Map<String, dynamic>>(
        threadId: 'gen-client-live',
        fetcher: (input, options) async => <String, dynamic>{'text': 'done'},
        devtools: const gen.GenerationDevtoolsMetadata(
          framework: 'react',
          hookName: 'useGenerateText',
          outputKind: 'text',
          name: 'Live Generation',
        ),
        devtoolsBridgeFactory: dt.createGenerationClientDevtoolsBridgeFactory(
          eventClient: events,
          production: false,
        ),
      );

      await client.generate(<String, dynamic>{'prompt': 'hello'});

      final registered = events.emitted('hook:registered').last.payload;
      expect(registered['hookId'], 'gen-client-live');
      expect(registered['threadId'], 'gen-client-live');
      expect(registered['clientId'], 'gen-client-live');
      expect(registered['hookName'], 'useGenerateText');
      expect(registered['outputKind'], 'text');
      expect(registered['displayName'], 'Live Generation');

      expect(events.emitted('run:started'), isNotEmpty);
      expect(events.emitted('run:completed'), isNotEmpty);

      final state = latestState(events);
      expect(state['status'], 'success');
      expect(state['isLoading'], isFalse);
      expect(state['result'], {'text': 'done'});
      expect(state['activeRunId'], isNull);

      final runs = latestRuns(events);
      expect(runs, hasLength(1));
      expect(runs.single['input'], {'prompt': 'hello'});
      expect(runs.single['status'], 'success');
      expect(runs.single['result'], {'text': 'done'});

      client.dispose();
      expect(events.emitted('hook:unregistered'), hasLength(1));
    });

    test('wires the real VideoGenerationClient onto video job state', () async {
      final events = dt.InMemoryAIDevtoolsEventClient();
      final client = gen.VideoGenerationClient<gen.VideoGenerateResult>(
        threadId: 'video-client-live',
        fetcher: (input, options) async => <String, dynamic>{
          'jobId': 'job-1',
          'status': 'completed',
          'url': 'https://example.com/video.mp4',
        },
        devtools: const gen.GenerationDevtoolsMetadata(
          framework: 'react',
          hookName: 'useGenerateVideo',
          outputKind: 'video',
          name: 'Live Video',
        ),
        devtoolsBridgeFactory: dt.createGenerationClientDevtoolsBridgeFactory(
          eventClient: events,
          production: false,
        ),
      );

      await client.generate(
        const gen.VideoGenerateInput(prompt: 'make video'),
      );

      final registered = events.emitted('hook:registered').last.payload;
      expect(registered['hookId'], 'video-client-live');
      expect(registered['hookName'], 'useGenerateVideo');
      expect(registered['outputKind'], 'video');
      expect(registered['displayName'], 'Live Video');

      expect(events.emitted('run:completed'), isNotEmpty);

      final state = latestState(events);
      expect(state['status'], 'success');
      expect(state['isLoading'], isFalse);
      expect(state['jobId'], 'job-1');
      expect(state['input'], {'prompt': 'make video'});
      final preview = state['preview'] as Map;
      expect(preview['kind'], 'video');
      expect((preview['items'] as List).single, {
        'src': 'https://example.com/video.mp4',
        'sourceType': 'url',
      });
      expect((preview['job'] as Map)['jobId'], 'job-1');

      final videoStatus = state['videoStatus'] as Map;
      expect(videoStatus['jobId'], 'job-1');
      expect(videoStatus['status'], 'completed');
      expect(videoStatus['progress'], 100);
      expect(videoStatus['url'], 'https://example.com/video.mp4');

      final runs = latestRuns(events);
      expect(runs, hasLength(1));
      expect(runs.single['input'], {'prompt': 'make video'});
      expect(runs.single['status'], 'success');
      expect(runs.single['jobId'], 'job-1');
      expect((runs.single['videoStatus'] as Map)['status'], 'completed');
      expect((runs.single['result'] as Map)['url'],
          'https://example.com/video.mp4');

      client.dispose();
      expect(events.emitted('hook:unregistered'), hasLength(1));
    });
  });
}
