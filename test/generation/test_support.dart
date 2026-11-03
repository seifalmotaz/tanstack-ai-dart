import 'dart:async';
import 'dart:convert';

import 'package:tanstack_ai_dart/connections.dart';
import 'package:tanstack_ai_dart/devtools.dart' as devtools;
import 'package:tanstack_ai_dart/generation.dart';

class Deferred<T> {
  final Completer<T> _completer = Completer<T>();

  Future<T> get promise => _completer.future;

  void resolve(T value) {
    if (!_completer.isCompleted) _completer.complete(value);
  }

  void reject(Object error) {
    if (!_completer.isCompleted) _completer.completeError(error);
  }
}

Future<void> waitForCondition(void Function() assertion) async {
  Object? lastError;
  for (var attempt = 0; attempt < 40; attempt++) {
    try {
      assertion();
      return;
    } catch (error) {
      lastError = error;
      await Future<void>.delayed(Duration.zero);
    }
  }
  throw lastError ?? StateError('condition never became true');
}

ConnectionAdapter mockConnection(List<StreamChunk> chunks) => ConnectionAdapter(
      connect: (messages, {data, signal, runContext}) async* {
        for (final chunk in chunks) {
          yield chunk;
        }
      },
    );

GenerationResponse sseResponse(
  List<String> lines, {
  bool spaceAfterDataColon = true,
}) {
  final prefix = spaceAfterDataColon ? 'data: ' : 'data:';
  final body = '${lines.map((line) => '$prefix$line').join('\n\n')}\n\n';
  return GenerationResponse(
    statusCode: 200,
    body: Stream<List<int>>.value(utf8.encode(body)),
  );
}

Map<String, dynamic> runStarted(
  String runId, [
  String threadId = 'thread-1',
]) =>
    {
      'type': 'RUN_STARTED',
      'runId': runId,
      'threadId': threadId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

Map<String, dynamic> runFinished(
  String runId, [
  String threadId = 'thread-1',
]) =>
    {
      'type': 'RUN_FINISHED',
      'runId': runId,
      'threadId': threadId,
      'metadata': {
        'tanstack': {'finishReason': 'stop'}
      },
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

Map<String, dynamic> custom(
  String name,
  Object? value, {
  String? threadId,
  String? runId,
}) =>
    {
      'type': 'CUSTOM',
      'name': name,
      'value': value,
      if (threadId != null && runId != null)
        'metadata': {
          'tanstack': {'threadId': threadId, 'runId': runId}
        },
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

// ---------------------------------------------------------------------------
// Devtools test double. The production bridge is owned by the DevTools worker;
// generation clients only depend on the injectable port.
// ---------------------------------------------------------------------------

class FakeAiEventClient {
  final List<MapEntry<String, Map<String, dynamic>>> events =
      <MapEntry<String, Map<String, dynamic>>>[];
  final Map<String, List<void Function(Map<String, dynamic>)>> _listeners =
      <String, List<void Function(Map<String, dynamic>)>>{};

  void emit(String name, Map<String, dynamic> payload) {
    events.add(MapEntry(name, payload));
  }

  void Function() on(
    String name,
    void Function(Map<String, dynamic>) listener,
  ) {
    _listeners.putIfAbsent(name, () => []).add(listener);
    return () {
      _listeners[name]?.remove(listener);
    };
  }

  void dispatch(String name, Map<String, dynamic> payload) {
    for (final listener in List.of(_listeners[name] ?? const [])) {
      listener(payload);
    }
  }

  List<Map<String, dynamic>> emitted(String name) => [
        for (final event in events)
          if (event.key == name) event.value,
      ];

  void reset() {
    _listeners.clear();
  }

  void clearEvents() {
    events.clear();
  }
}

/// Canonical preview shape used by the real DevTools bridge.
///
/// The upstream tests import `createAIDevtoolsGenerationPreview` directly;
/// this wrapper only adapts the port's named arguments to the canonical
/// input record so the generation tests exercise one implementation.
Map<String, dynamic> createAIDevtoolsGenerationPreview({
  String? outputKind,
  Object? result,
  Object? videoStatus,
}) =>
    devtools
        .createAIDevtoolsGenerationPreview(
          devtools.AIDevtoolsGenerationPreviewInput(
            outputKind: outputKind,
            result: result,
            videoStatus: videoStatus,
          ),
        )
        .toJson();

class DevtoolsRecorder {
  final FakeAiEventClient eventClient;
  late RecordingGenerationDevtoolsBridgePort lastBridge;

  DevtoolsRecorder([FakeAiEventClient? client])
      : eventClient = client ?? FakeAiEventClient();

  GenerationDevtoolsBridgePort factory(
      GenerationDevtoolsBridgePortOptions options) {
    lastBridge = RecordingGenerationDevtoolsBridgePort(options, eventClient);
    return lastBridge;
  }

  Map<String, dynamic> latestSnapshotState() {
    final snapshots = eventClient.emitted('hook:state-snapshot');
    if (snapshots.isEmpty) {
      throw StateError('Expected a hook state snapshot payload');
    }
    final state = snapshots.last['state'];
    if (state is! Map) throw StateError('Expected a snapshot state');
    return state.map((key, value) => MapEntry('$key', value));
  }

  List<Map<String, dynamic>> latestGenerationRuns() {
    final runs = latestSnapshotState()['runs'];
    if (runs is! List) throw StateError('Expected generation snapshot runs');
    return runs
        .whereType<Map>()
        .map((run) => run.map((key, value) => MapEntry('$key', value)))
        .toList();
  }
}

class RecordingGenerationDevtoolsBridgePort
    implements GenerationDevtoolsBridgePort {
  final GenerationDevtoolsBridgePortOptions options;
  final FakeAiEventClient eventClient;
  final List<Map<String, dynamic>> _runs = <Map<String, dynamic>>[];
  String? _activeRunId;
  bool _activeRunStarted = false;
  bool _registered = false;
  bool _disposed = false;
  int _runSeq = 0;
  late final void Function() _unsubscribe;

  RecordingGenerationDevtoolsBridgePort(this.options, this.eventClient) {
    _unsubscribe = eventClient.on('devtools:request-state', (payload) {
      if (_disposed) return;
      final target = payload['targetHookId'];
      if (target is String && target != options.hookId()) return;
      emitRegistered();
      emitSnapshot();
    });
  }

  bool get _isVideo =>
      options.getCoreState().jobId != null ||
      options.metadata.outputKind == 'video';

  @override
  String beginRun(Object? input) {
    final runId = 'run-${DateTime.now().microsecondsSinceEpoch}-${_runSeq++}';
    _activeRunId = runId;
    _activeRunStarted = false;
    _upsert(runId, {
      'input': input,
      'result': null,
      'preview': createAIDevtoolsGenerationPreview(
        outputKind: options.metadata.outputKind,
        result: null,
      ),
      'progress': null,
      'status': 'generating',
      'isLoading': true,
      'clearError': true,
    });
    return runId;
  }

  @override
  void ensureRunStarted(String runId) {
    if (_activeRunStarted && _activeRunId == runId) return;
    final previous = _activeRunId;
    if (!_activeRunStarted && previous != null && previous != runId) {
      _renameRun(previous, runId);
    }
    _activeRunId = runId;
    _activeRunStarted = true;
    _upsert(runId, {
      'status': 'generating',
      'isLoading': true,
      'clearError': true,
    });
    _emitRunLifecycle('run:started', runId, 'started');
    emitState();
  }

  @override
  void finishRun(
    String runId,
    String eventType,
    String status, {
    String? error,
  }) {
    ensureRunStarted(runId);
    final core = options.getCoreState();
    final completedProgress = status == 'completed'
        ? (core.progress == null
            ? null
            : {
                'value': 100,
                if (core.progress!.message != null)
                  'message': core.progress!.message,
              })
        : (core.progress == null
            ? null
            : {
                'value': core.progress!.value,
                if (core.progress!.message != null)
                  'message': core.progress!.message,
              });
    final runStatus = status == 'completed'
        ? 'success'
        : status == 'errored'
            ? 'error'
            : 'cancelled';
    _upsert(runId, {
      'status': runStatus,
      'isLoading': false,
      'progress': completedProgress,
      'completedAt': DateTime.now().millisecondsSinceEpoch,
      if (error != null) 'error': error else 'clearError': true,
    });
    if (_activeRunId == runId) _activeRunId = null;
    _activeRunStarted = false;
    _emitRunLifecycle(eventType, runId, status, error: error);
    emitState();
  }

  @override
  String? getActiveRunId() => _activeRunId;

  @override
  void resetRuns() {
    _activeRunId = null;
    _activeRunStarted = false;
    _runs.clear();
  }

  @override
  void recordResultChange() {
    final core = options.getCoreState();
    _updateActiveRun({
      'result': core.result,
      'preview': _preview(core.result),
      'clearError': true,
    });
    emitState();
  }

  @override
  void recordLoadingChange() {
    _updateActiveRun({'isLoading': options.getCoreState().isLoading});
    emitState();
  }

  @override
  void recordErrorChange(Object? error) {
    _updateActiveRun(error == null
        ? {'clearError': true}
        : {'error': generationErrorMessage(error)});
    emitState();
  }

  @override
  void recordStatusChange(String status) {
    _updateActiveRun({'status': status});
    emitState();
  }

  @override
  void recordProgressChange() {
    final progress = options.getCoreState().progress;
    _updateActiveRun({
      'progress': progress == null
          ? null
          : {
              'value': progress.value,
              if (progress.message != null) 'message': progress.message,
            },
    });
    emitState();
  }

  @override
  void recordJobIdChange() {
    _updateActiveRun({'jobId': options.getCoreState().jobId});
    emitState();
  }

  @override
  void recordVideoStatusChange() {
    final core = options.getCoreState();
    _updateActiveRun({
      'videoStatus': core.videoStatus,
      'preview': _preview(core.result),
    });
    emitState();
  }

  @override
  void emitRegistered() {
    if (_disposed) return;
    _registered = true;
    eventClient.emit('hook:registered', {
      ..._envelope('hook:registered'),
      ..._metadataPayload(),
      'lifecycle': 'mounted',
    });
  }

  @override
  void emitUpdated() {
    if (_disposed) return;
    eventClient.emit('hook:updated', {
      ..._envelope('hook:updated'),
      ..._metadataPayload(),
      'lifecycle': 'active',
    });
  }

  @override
  void emitSnapshot() {
    if (_disposed) return;
    eventClient.emit('hook:state-snapshot', {
      ..._envelope('hook:state-snapshot'),
      ..._metadataPayload(),
      'state': _buildSnapshot(),
    });
  }

  @override
  void emitState() {
    emitUpdated();
    emitSnapshot();
  }

  @override
  void resetState() {}

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_registered) {
      eventClient.emit('hook:unregistered', {
        ..._envelope('hook:unregistered'),
        ..._metadataPayload(),
        'reason': 'disposed',
      });
    }
    _unsubscribe();
  }

  Map<String, dynamic> _buildSnapshot() {
    final core = options.getCoreState();
    return {
      'input': core.input,
      'result': core.result,
      'preview': _preview(core.result),
      'progress': core.progress == null
          ? null
          : {
              'value': core.progress!.value,
              if (core.progress!.message != null)
                'message': core.progress!.message,
            },
      'status': core.status,
      'isLoading': core.isLoading,
      'activeRunId': _activeRunId,
      'runs': _runs,
      if (core.error != null) 'error': core.error,
      if (_isVideo) 'jobId': core.jobId,
      if (_isVideo) 'videoStatus': core.videoStatus,
    };
  }

  Map<String, dynamic> _preview(Object? result) {
    final core = options.getCoreState();
    return createAIDevtoolsGenerationPreview(
      outputKind: options.metadata.outputKind,
      result: result,
      videoStatus: core.videoStatus,
    );
  }

  void _updateActiveRun(Map<String, dynamic> patch) {
    final runId = _activeRunId;
    if (runId == null) return;
    _upsert(runId, patch);
  }

  void _upsert(String runId, Map<String, dynamic> patch) {
    final index = _runs.indexWhere((run) => run['id'] == runId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final next = index >= 0
        ? Map<String, dynamic>.of(_runs[index])
        : <String, dynamic>{
            'id': runId,
            'input': options.getCoreState().input,
            'result': null,
            'preview': _preview(null),
            'progress': null,
            'status': 'idle',
            'isLoading': false,
            'startedAt': now,
            'updatedAt': now,
          };
    for (final entry in patch.entries) {
      if (entry.key == 'clearError') {
        next.remove('error');
        continue;
      }
      next[entry.key] = entry.value;
    }
    next['updatedAt'] = now;
    if (index >= 0) {
      _runs[index] = next;
    } else {
      _runs.add(next);
      if (_runs.length > options.maxRuns) {
        _runs.removeRange(0, _runs.length - options.maxRuns);
      }
    }
  }

  void _renameRun(String previousRunId, String nextRunId) {
    if (previousRunId == nextRunId) return;
    final index = _runs.indexWhere((run) => run['id'] == previousRunId);
    if (index < 0) return;
    _runs.removeWhere((run) => run['id'] == nextRunId);
    final renamed = Map<String, dynamic>.of(_runs[index]);
    renamed['id'] = nextRunId;
    renamed['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
    _runs[index] = renamed;
  }

  Map<String, dynamic> _envelope(
    String eventType, {
    String? runId,
  }) =>
      {
        'eventType': eventType,
        'source': 'client',
        'visibility': 'client-state',
        'clientId': options.clientId(),
        'hookId': options.hookId(),
        if (options.threadId().isNotEmpty) 'threadId': options.threadId(),
        if (runId != null) 'runId': runId,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

  Map<String, dynamic> _metadataPayload() => {
        'hookId': options.hookId(),
        'hookName': options.metadata.hookName,
        if (options.metadata.name != null) 'displayName': options.metadata.name,
        if (options.metadata.outputKind != null)
          'outputKind': options.metadata.outputKind,
        if (options.metadata.framework?.isNotEmpty ?? false)
          'framework': options.metadata.framework,
      };

  void _emitRunLifecycle(
    String eventType,
    String runId,
    String status, {
    String? error,
  }) {
    if (_disposed) return;
    eventClient.emit(eventType, {
      ..._envelope(eventType, runId: runId),
      'runId': runId,
      'status': status,
      if (error != null) 'error': error,
    });
  }
}
