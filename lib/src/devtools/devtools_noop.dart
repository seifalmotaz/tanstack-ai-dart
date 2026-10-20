/// No-op devtools bridges and factories.
///
/// Ported from `packages/ai-client/src/devtools-noop.ts`. Production hosts get
/// these by default; they never touch the event sink or the preview/fixture
/// machinery.
library;

import '../platform/events.dart';
import 'devtools.dart';
import 'devtools_types.dart';

class NoOpChatClientEventEmitter extends ChatClientEventEmitter {
  NoOpChatClientEventEmitter(super.clientId);

  @override
  void emitEvent(String eventName, [Map<String, dynamic>? data]) {
    // Intentionally empty.
  }
}

class NoOpChatDevtoolsBridge extends ChatDevtoolsBridge {
  NoOpChatDevtoolsBridge(ChatDevtoolsBridgeOptions options) : super(options) {
    events = NoOpChatClientEventEmitter(options.clientId);
  }

  // Base bridge surface.
  @override
  void emitRegistered() {}
  @override
  void emitUpdated() {}
  @override
  void emitSnapshot() {}
  @override
  void emitToolsRegistered() {}
  @override
  void emitRunLifecycle(
    AIDevtoolsRunEventType eventType,
    String runId,
    AIDevtoolsRunStatus status, {
    String? error,
  }) {}
  @override
  void deactivate() {}
  @override
  void supersede() {}
  @override
  void dispose() {}

  // Chat-specific surface.
  @override
  void mountWithTools(int initialMessageCount) {}
  @override
  void notifyToolsChanged() {}
  @override
  void setCurrentStreamId(String? streamId) {}
  @override
  void recordStreamId(String streamId) {}
  @override
  String? getCurrentStreamId() => null;
  @override
  String? getLastStreamId() => null;
  @override
  String resolveStreamId() => '';
  @override
  void observeChunk(Map<String, dynamic> chunk) {}
  @override
  void recordMemoryState(Object? rawValue) {}
  @override
  void recordCompactionEvent(String eventType, Object? rawValue) {}
  @override
  void recordCompactionState(Object? rawValue) {}
  @override
  void recordSkillsState(Object? rawValue) {}
  @override
  void beginRun(String runId, String threadId) {}
  @override
  ChatClientRunEventContext? getCurrentRunEventContext() => null;
  @override
  ChatClientRunEventContext? getCurrentOrLastRunEventContext() => null;
  @override
  ChatClientEventContext findToolCallContext(String toolCallId) =>
      ChatClientEventContext(toolCallId: toolCallId);
  @override
  Future<void> applyFixture(AIDevtoolsToolFixture fixture) async {}
}

mixin _NoOpGenerationSurface<TOutput> on GenerationDevtoolsBridge<TOutput> {
  @override
  void emitRegistered() {}
  @override
  void emitUpdated() {}
  @override
  void emitSnapshot() {}
  @override
  void emitToolsRegistered() {}
  @override
  void emitRunLifecycle(
    AIDevtoolsRunEventType eventType,
    String runId,
    AIDevtoolsRunStatus status, {
    String? error,
  }) {}
  @override
  void deactivate() {}
  @override
  void supersede() {}
  @override
  void dispose() {}

  @override
  String beginRun(Object? input) =>
      'noop-run-${DateTime.now().millisecondsSinceEpoch}-'
      '${DateTime.now().microsecond.remainder(1000000)}';
  @override
  void ensureRunStarted(String runId) {}
  @override
  void finishRun(
    String runId,
    AIDevtoolsRunEventType eventType,
    AIDevtoolsRunStatus status, {
    String? error,
  }) {}
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
  void recordStatusChange(AIDevtoolsGenerationRunStatus status) {}
  @override
  void recordProgressChange() {}
  @override
  void recordJobIdChange() {}
  @override
  void recordVideoStatusChange() {}
  @override
  void emitState() {}
}

class NoOpGenerationDevtoolsBridge<TOutput>
    extends GenerationDevtoolsBridge<TOutput>
    with _NoOpGenerationSurface<TOutput> {
  // ignore: use_super_parameters
  NoOpGenerationDevtoolsBridge(GenerationDevtoolsBridgeOptions<TOutput> options)
      : super(options);
}

class NoOpVideoDevtoolsBridge<TOutput> extends VideoDevtoolsBridge<TOutput>
    with _NoOpGenerationSurface<TOutput> {
  // ignore: use_super_parameters
  NoOpVideoDevtoolsBridge(VideoDevtoolsBridgeOptions<TOutput> options)
      : super(options);

  @override
  void recordJobIdChange() {}
  @override
  void recordVideoStatusChange() {}
}

// Factories, mirroring the upstream no-op factory exports.

typedef ChatDevtoolsBridgeFactory = ChatDevtoolsBridge Function(
  ChatDevtoolsBridgeOptions options,
);

typedef GenerationDevtoolsBridgeFactory = GenerationDevtoolsBridge<TOutput>
    Function<TOutput>(GenerationDevtoolsBridgeOptions<TOutput> options);

typedef VideoDevtoolsBridgeFactory = VideoDevtoolsBridge<TOutput>
    Function<TOutput>(VideoDevtoolsBridgeOptions<TOutput> options);

ChatDevtoolsBridge createNoOpChatDevtoolsBridge(
  ChatDevtoolsBridgeOptions options,
) =>
    NoOpChatDevtoolsBridge(options);

GenerationDevtoolsBridge<TOutput> createNoOpGenerationDevtoolsBridge<TOutput>(
  GenerationDevtoolsBridgeOptions<TOutput> options,
) =>
    NoOpGenerationDevtoolsBridge<TOutput>(options);

VideoDevtoolsBridge<TOutput> createNoOpVideoDevtoolsBridge<TOutput>(
  VideoDevtoolsBridgeOptions<TOutput> options,
) =>
    NoOpVideoDevtoolsBridge<TOutput>(options);
