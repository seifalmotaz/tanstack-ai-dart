/// Bridges the stable generation-client devtools port to the real devtools
/// bridge implementation.
///
/// The generation clients own `generation_devtools_port.dart`; this adapter
/// keeps that seam stable while wiring the real [GenerationDevtoolsBridge] or
/// [VideoDevtoolsBridge]. Identity, metadata, progress, statuses and run
/// lifecycle strings are translated at this boundary.
library;

import '../generation/generation_devtools_port.dart' as port;
import 'devtools.dart' as real;
import 'devtools_factories.dart' show isAIDevtoolsProduction;
import 'devtools_types.dart' as types;

/// Build a [port.GenerationDevtoolsBridgePortFactory] that creation-time generation
/// clients can pass as `devtoolsBridgeFactory`.
///
/// When [production] is true (or the host runs in a production Dart VM), the
/// factory returns the port's no-op bridge and emits no devtools events.
port.GenerationDevtoolsBridgePortFactory
    createGenerationClientDevtoolsBridgeFactory({
  types.AIDevtoolsEventClient? eventClient,
  bool? production,
}) {
  final sink = eventClient ?? types.aiDevtoolsEventClient;
  final isProduction = production ?? isAIDevtoolsProduction();

  return (port.GenerationDevtoolsBridgePortOptions options) {
    if (isProduction) {
      return port.createNoOpGenerationDevtoolsBridgePort(options);
    }
    return _GenerationClientDevtoolsAdapter(options, sink);
  };
}

class _GenerationClientDevtoolsAdapter
    implements port.GenerationDevtoolsBridgePort {
  final port.GenerationDevtoolsBridgePortOptions options;
  late final real.GenerationDevtoolsBridge<Object?> bridge;

  _GenerationClientDevtoolsAdapter(
    this.options,
    types.AIDevtoolsEventClient eventClient,
  ) {
    final metadata = types.AIDevtoolsClientMetadata(
      framework: options.metadata.framework,
      hookName: options.metadata.hookName,
      outputKind: options.metadata.outputKind,
      name: options.metadata.name,
    );

    String liveHookId() => options.hookId();
    String liveClientId() => options.clientId();
    String? liveThreadId() {
      final threadId = options.threadId();
      return threadId.isEmpty ? null : threadId;
    }

    final isVideo = options.metadata.outputKind == 'video' ||
        options.getCoreState().jobId != null ||
        options.getCoreState().videoStatus != null;

    if (isVideo) {
      final video = real.VideoDevtoolsBridge<Object?>(
        types.VideoDevtoolsBridgeOptions<Object?>(
          hookId: '',
          clientId: '',
          hookIdGetter: liveHookId,
          clientIdGetter: liveClientId,
          threadIdGetter: liveThreadId,
          metadata: metadata,
          maxRuns: options.maxRuns,
          eventClient: eventClient,
          getCoreState: _videoCoreState,
        ),
      );
      bridge = video;
    } else {
      bridge = real.GenerationDevtoolsBridge<Object?>(
        types.GenerationDevtoolsBridgeOptions<Object?>(
          hookId: '',
          clientId: '',
          hookIdGetter: liveHookId,
          clientIdGetter: liveClientId,
          threadIdGetter: liveThreadId,
          metadata: metadata,
          maxRuns: options.maxRuns,
          eventClient: eventClient,
          getCoreState: _coreState,
        ),
      );
    }
  }

  @override
  String beginRun(Object? input) => bridge.beginRun(_jsonValue(input));

  @override
  void ensureRunStarted(String runId) => bridge.ensureRunStarted(runId);

  @override
  void finishRun(
    String runId,
    String eventType,
    String status, {
    String? error,
  }) {
    bridge.finishRun(
      runId,
      _mapEventType(eventType),
      _mapRunStatus(status),
      error: error,
    );
  }

  @override
  String? getActiveRunId() => bridge.getActiveRunId();

  @override
  void resetRuns() => bridge.resetRuns();

  @override
  void recordResultChange() => bridge.recordResultChange();

  @override
  void recordLoadingChange() => bridge.recordLoadingChange();

  @override
  void recordErrorChange(Object? error) => bridge.recordErrorChange(error);

  @override
  void recordStatusChange(String status) =>
      bridge.recordStatusChange(_mapStatus(status));

  @override
  void recordProgressChange() => bridge.recordProgressChange();

  @override
  void recordJobIdChange() => bridge.recordJobIdChange();

  @override
  void recordVideoStatusChange() => bridge.recordVideoStatusChange();

  @override
  void emitRegistered() => bridge.emitRegistered();

  @override
  void emitUpdated() => bridge.emitUpdated();

  @override
  void emitSnapshot() => bridge.emitSnapshot();

  @override
  void emitState() => bridge.emitState();

  @override
  void resetState() => bridge.resetRuns();

  @override
  void dispose() => bridge.dispose();

  types.AIDevtoolsGenerationCoreState<Object?> _coreState() {
    final core = options.getCoreState();
    return types.AIDevtoolsGenerationCoreState<Object?>(
      input: _jsonValue(core.input),
      result: _jsonValue(core.result),
      progress: _mapProgress(core.progress),
      status: _mapStatus(core.status),
      isLoading: core.isLoading,
      error: _mapError(core.error),
      jobId: core.jobId,
      videoStatus: _jsonValue(core.videoStatus),
    );
  }

  types.AIDevtoolsVideoCoreState<Object?> _videoCoreState() {
    final core = options.getCoreState();
    return types.AIDevtoolsVideoCoreState<Object?>(
      input: _jsonValue(core.input),
      result: _jsonValue(core.result),
      progress: _mapProgress(core.progress),
      status: _mapStatus(core.status),
      isLoading: core.isLoading,
      error: _mapError(core.error),
      jobId: core.jobId,
      videoStatus: _jsonValue(core.videoStatus),
    );
  }
}

types.AIDevtoolsGenerationProgress? _mapProgress(Object? progress) {
  if (progress == null) return null;
  if (progress is types.AIDevtoolsGenerationProgress) return progress;
  // The generation port owns its progress shape. Read it structurally so this
  // adapter survives the main barrel aliasing it to the devtools type.
  try {
    final dynamic candidate = progress;
    final value = candidate.value;
    final message = candidate.message;
    if (value is num) {
      return types.AIDevtoolsGenerationProgress(
        value: value,
        message: message is String ? message : null,
      );
    }
  } catch (_) {
    // Ignore malformed progress values.
  }
  return null;
}

types.AIDevtoolsGenerationRunStatus _mapStatus(String status) {
  switch (status) {
    case 'idle':
      return types.AIDevtoolsGenerationRunStatus.idle;
    case 'generating':
      return types.AIDevtoolsGenerationRunStatus.generating;
    case 'success':
      return types.AIDevtoolsGenerationRunStatus.success;
    case 'error':
      return types.AIDevtoolsGenerationRunStatus.error;
    case 'cancelled':
      return types.AIDevtoolsGenerationRunStatus.cancelled;
  }
  throw ArgumentError.value(status, 'status', 'Unknown generation status');
}

types.AIDevtoolsRunEventType _mapEventType(String eventType) {
  switch (eventType) {
    case 'run:created':
      return types.AIDevtoolsRunEventType.created;
    case 'run:started':
      return types.AIDevtoolsRunEventType.started;
    case 'run:updated':
      return types.AIDevtoolsRunEventType.updated;
    case 'run:completed':
      return types.AIDevtoolsRunEventType.completed;
    case 'run:errored':
      return types.AIDevtoolsRunEventType.errored;
    case 'run:cancelled':
      return types.AIDevtoolsRunEventType.cancelled;
  }
  throw ArgumentError.value(eventType, 'eventType', 'Unknown run event type');
}

types.AIDevtoolsRunStatus _mapRunStatus(String status) {
  switch (status) {
    case 'created':
      return types.AIDevtoolsRunStatus.created;
    case 'started':
      return types.AIDevtoolsRunStatus.started;
    case 'updated':
      return types.AIDevtoolsRunStatus.updated;
    case 'completed':
      return types.AIDevtoolsRunStatus.completed;
    case 'errored':
      return types.AIDevtoolsRunStatus.errored;
    case 'cancelled':
      return types.AIDevtoolsRunStatus.cancelled;
  }
  throw ArgumentError.value(status, 'status', 'Unknown run status');
}

String? _mapError(Object? error) {
  if (error == null) return null;
  if (error is String) return error;
  try {
    final dynamic dynamicError = error;
    final message = dynamicError.message;
    if (message is String) return message;
  } catch (_) {
    // Fall through to toString.
  }
  return error.toString();
}

Object? _jsonValue(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        '${entry.key}': _jsonValue(entry.value),
    };
  }
  if (value is List) {
    return value.map(_jsonValue).toList();
  }
  try {
    final dynamic candidate = value;
    final json = candidate.toJson();
    if (json is Map ||
        json is List ||
        json is String ||
        json is num ||
        json is bool) {
      return _jsonValue(json);
    }
  } catch (_) {
    // Fall through to the raw value for non-serializable inputs.
  }
  return value;
}
