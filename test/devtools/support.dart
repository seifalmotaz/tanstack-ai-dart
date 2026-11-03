import 'dart:convert';

import 'package:tanstack_ai_dart/devtools.dart';

Map<String, dynamic> latestState(
  InMemoryAIDevtoolsEventClient client,
) {
  final snapshots = client.emitted('hook:state-snapshot');
  if (snapshots.isEmpty) {
    throw StateError('Expected at least one hook:state-snapshot');
  }
  final state = snapshots.last.payload['state'];
  if (state is! Map) {
    throw StateError('Expected hook:state-snapshot state map');
  }
  return state.map((key, value) => MapEntry('$key', value));
}

List<Map<String, dynamic>> latestRuns(
  InMemoryAIDevtoolsEventClient client,
) {
  final runs = latestState(client)['runs'];
  if (runs is! List) {
    throw StateError('Expected generation snapshot runs');
  }
  return runs
      .whereType<Map>()
      .map((run) => run.map((key, value) => MapEntry('$key', value)))
      .toList();
}

Future<void> waitFor(
  bool Function() predicate, {
  int attempts = 100,
}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('Timed out waiting for condition');
}

class ChatHarness {
  final InMemoryAIDevtoolsEventClient eventClient;
  final List<Map<String, dynamic>> messages;
  final Map<String, AIDevtoolsTool> tools;
  final String hookId;
  final String? threadId;
  final String clientId;
  final AIDevtoolsClientMetadata metadata;
  late final ChatDevtoolsBridgeOptions options;
  late final ChatDevtoolsBridge bridge;

  String status = 'ready';
  bool isLoading = false;
  bool isSubscribed = false;
  String connectionStatus = 'idle';
  bool sessionGenerating = false;
  List<String> activeRunIds = <String>[];
  List<Object?>? queue;
  String? error;
  int _idSeq = 0;

  ChatHarness({
    this.hookId = 'thread-1',
    this.threadId = 'thread-1',
    String? clientId,
    String? displayName,
    String? framework = 'react',
    String hookName = 'useChat',
    String? outputKind = 'chat',
    List<Map<String, dynamic>>? initialMessages,
    Iterable<AIDevtoolsTool>? tools,
    InMemoryAIDevtoolsEventClient? eventClient,
  })  : clientId = clientId ?? hookId,
        metadata = AIDevtoolsClientMetadata(
          name: displayName,
          framework: framework,
          hookName: hookName,
          outputKind: outputKind,
        ),
        eventClient = eventClient ?? InMemoryAIDevtoolsEventClient(),
        messages = initialMessages ?? <Map<String, dynamic>>[],
        tools = <String, AIDevtoolsTool>{
          for (final tool in tools ?? const <AIDevtoolsTool>[]) tool.name: tool,
        } {
    options = ChatDevtoolsBridgeOptions(
      hookId: hookId,
      threadId: threadId,
      clientId: this.clientId,
      metadata: metadata,
      eventClient: this.eventClient,
      getSnapshot: snapshot,
      getMessages: () => List<Map<String, dynamic>>.of(messages),
      setMessages: (next) {
        messages
          ..clear()
          ..addAll(next);
      },
      addToolResult: _addToolResult,
      generateId: _generateId,
      getTools: () => this.tools.values,
    );
    bridge = ChatDevtoolsBridge(options);
  }

  AIDevtoolsChatSnapshot snapshot() => AIDevtoolsChatSnapshot(
        messages: messages,
        status: status,
        isLoading: isLoading,
        isSubscribed: isSubscribed,
        connectionStatus: connectionStatus,
        sessionGenerating: sessionGenerating,
        activeRunIds: activeRunIds,
        queue: queue,
        error: error,
      );

  String _generateId(String prefix) => '$prefix-${++_idSeq}';

  void _addToolResult(
    String toolCallId,
    Object? output, [
    String? errorText,
  ]) {
    for (final message in messages) {
      final parts = message['parts'];
      if (parts is! List) continue;
      for (final part in parts) {
        if (part is! Map) continue;
        if (part['type'] != 'tool-call' || part['id'] != toolCallId) continue;
        part['output'] = output;
        parts.add(<String, dynamic>{
          'type': 'tool-result',
          'toolCallId': toolCallId,
          'content': output is String ? output : jsonEncode(output),
          'state': errorText != null ? 'error' : 'complete',
          if (errorText != null) 'error': errorText,
        });
        return;
      }
    }
  }
}

final class GenerationCore<TOutput> {
  Object? input;
  TOutput? result;
  AIDevtoolsGenerationProgress? progress;
  AIDevtoolsGenerationRunStatus status = AIDevtoolsGenerationRunStatus.idle;
  bool isLoading = false;
  String? error;

  AIDevtoolsGenerationCoreState<TOutput> state() =>
      AIDevtoolsGenerationCoreState<TOutput>(
        input: input,
        result: result,
        progress: progress,
        status: status,
        isLoading: isLoading,
        error: error,
      );
}

final class VideoCore<TOutput> {
  Object? input;
  TOutput? result;
  AIDevtoolsGenerationProgress? progress;
  AIDevtoolsGenerationRunStatus status = AIDevtoolsGenerationRunStatus.idle;
  bool isLoading = false;
  String? error;
  String? jobId;
  Object? videoStatus;

  AIDevtoolsVideoCoreState<TOutput> state() =>
      AIDevtoolsVideoCoreState<TOutput>(
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

class GenerationHarness<TOutput> {
  final InMemoryAIDevtoolsEventClient eventClient;
  final GenerationCore<TOutput> core = GenerationCore<TOutput>();
  final String hookId;
  final String? threadId;
  final AIDevtoolsClientMetadata metadata;
  late final GenerationDevtoolsBridgeOptions<TOutput> options;
  late final GenerationDevtoolsBridge<TOutput> bridge;

  GenerationHarness({
    this.hookId = 'gen-1',
    this.threadId = 'gen-1',
    String? clientId,
    String hookName = 'useGenerateText',
    String? outputKind = 'text',
    String? framework = 'react',
    String? displayName,
    int maxRuns = 20,
    InMemoryAIDevtoolsEventClient? eventClient,
  })  : eventClient = eventClient ?? InMemoryAIDevtoolsEventClient(),
        metadata = AIDevtoolsClientMetadata(
          name: displayName,
          framework: framework,
          hookName: hookName,
          outputKind: outputKind,
        ) {
    options = GenerationDevtoolsBridgeOptions<TOutput>(
      hookId: hookId,
      threadId: threadId,
      clientId: clientId ?? hookId,
      metadata: metadata,
      maxRuns: maxRuns,
      eventClient: this.eventClient,
      getCoreState: core.state,
    );
    bridge = GenerationDevtoolsBridge<TOutput>(options);
  }
}

class VideoHarness<TOutput> {
  final InMemoryAIDevtoolsEventClient eventClient;
  final VideoCore<TOutput> core = VideoCore<TOutput>();
  final String hookId;
  final String? threadId;
  final AIDevtoolsClientMetadata metadata;
  late final VideoDevtoolsBridgeOptions<TOutput> options;
  late final VideoDevtoolsBridge<TOutput> bridge;

  VideoHarness({
    this.hookId = 'video-1',
    this.threadId = 'video-1',
    String? clientId,
    String hookName = 'useGenerateVideo',
    String? outputKind = 'video',
    String? framework = 'react',
    String? displayName,
    int maxRuns = 20,
    InMemoryAIDevtoolsEventClient? eventClient,
  })  : eventClient = eventClient ?? InMemoryAIDevtoolsEventClient(),
        metadata = AIDevtoolsClientMetadata(
          name: displayName,
          framework: framework,
          hookName: hookName,
          outputKind: outputKind,
        ) {
    options = VideoDevtoolsBridgeOptions<TOutput>(
      hookId: hookId,
      threadId: threadId,
      clientId: clientId ?? hookId,
      metadata: metadata,
      maxRuns: maxRuns,
      eventClient: this.eventClient,
      getCoreState: core.state,
    );
    bridge = VideoDevtoolsBridge<TOutput>(options);
  }
}
