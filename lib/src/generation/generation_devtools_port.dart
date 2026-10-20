/// Narrow devtools seam used by the generation clients.
///
/// The full DevTools bridge, snapshot history, and media preview factory are
/// owned by the DevTools worker. Generation clients only depend on this
/// injectable surface, so the real bridge can be plugged in without importing
/// or duplicating its implementation here.
library;

import '../devtools/devtools_types.dart';

export '../devtools/devtools_types.dart'
    show AIDevtoolsClientMetadata, AIDevtoolsGenerationProgress;

/// Metadata used to register a generation hook with TanStack AI Devtools.
///
/// Canonical type: [AIDevtoolsClientMetadata]. The alias keeps the narrow
/// generation port readable without maintaining a parallel shape.
typedef GenerationDevtoolsMetadata = AIDevtoolsClientMetadata;

/// Progress payload read by the DevTools panel.
///
/// Canonical type: [AIDevtoolsGenerationProgress].
typedef GenerationDevtoolsProgress = AIDevtoolsGenerationProgress;

/// Core client state handed to a DevTools bridge.
class GenerationDevtoolsPortCoreState {
  final Object? input;
  final Object? result;
  final GenerationDevtoolsProgress? progress;
  final String status;
  final bool isLoading;
  final Object? error;
  final String? jobId;
  final Object? videoStatus;

  const GenerationDevtoolsPortCoreState({
    required this.input,
    required this.result,
    required this.progress,
    required this.status,
    required this.isLoading,
    this.error,
    this.jobId,
    this.videoStatus,
  });
}

/// Options passed to an injected DevTools bridge factory.
class GenerationDevtoolsBridgePortOptions {
  final String Function() hookId;
  final String Function() clientId;
  final String Function() threadId;
  final GenerationDevtoolsMetadata metadata;
  final GenerationDevtoolsPortCoreState Function() getCoreState;
  final int maxRuns;

  const GenerationDevtoolsBridgePortOptions({
    required this.hookId,
    required this.clientId,
    required this.threadId,
    required this.metadata,
    required this.getCoreState,
    this.maxRuns = 20,
  });
}

/// The client-facing run lifecycle surface of the DevTools bridge.
abstract class GenerationDevtoolsBridgePort {
  String beginRun(Object? input);
  void ensureRunStarted(String runId);
  void finishRun(
    String runId,
    String eventType,
    String status, {
    String? error,
  });
  String? getActiveRunId();
  void resetRuns();
  void recordResultChange();
  void recordLoadingChange();
  void recordErrorChange(Object? error);
  void recordStatusChange(String status);
  void recordProgressChange();
  void recordJobIdChange();
  void recordVideoStatusChange();
  void emitRegistered();
  void emitUpdated();
  void emitSnapshot();
  void emitState();
  void resetState();
  void dispose();
}

/// Factory injected through client options.
typedef GenerationDevtoolsBridgePortFactory = GenerationDevtoolsBridgePort
    Function(
  GenerationDevtoolsBridgePortOptions options,
);

/// No-op bridge used when the host did not opt into DevTools.
class NoOpGenerationDevtoolsBridgePort implements GenerationDevtoolsBridgePort {
  const NoOpGenerationDevtoolsBridgePort();

  @override
  String beginRun(Object? input) =>
      'noop-run-${DateTime.now().microsecondsSinceEpoch}';

  @override
  void ensureRunStarted(String runId) {}
  @override
  void finishRun(String runId, String eventType, String status,
      {String? error}) {}
  @override
  String? getActiveRunId() => null;
  @override
  void resetRuns() {}
  @override
  void recordResultChange() {}
  @override
  void recordLoadingChange() {}
  @override
  void recordErrorChange(Object? error) {}
  @override
  void recordStatusChange(String status) {}
  @override
  void recordProgressChange() {}
  @override
  void recordJobIdChange() {}
  @override
  void recordVideoStatusChange() {}
  @override
  void emitRegistered() {}
  @override
  void emitUpdated() {}
  @override
  void emitSnapshot() {}
  @override
  void emitState() {}
  @override
  void resetState() {}
  @override
  void dispose() {}
}

GenerationDevtoolsBridgePort createNoOpGenerationDevtoolsBridgePort(
  GenerationDevtoolsBridgePortOptions options,
) =>
    const NoOpGenerationDevtoolsBridgePort();
