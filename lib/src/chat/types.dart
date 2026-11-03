import 'dart:async';

import '../protocol.dart';
import '../connections/connection_adapter.dart';
import '../connections/stream_connections.dart' show ChatFetcher;
import '../platform/byok/client.dart' show ByokClient;
import '../devtools/devtools_types.dart';
import '../devtools/devtools_noop.dart' show ChatDevtoolsBridgeFactory;
import '../platform/persistence_types.dart'
    show ChatResumeState, ChatResumeSnapshot, ChatClientPersistence;
import '../connections/hydration.dart'
    show ChatHydrateOptions, ChatHydrationPage;
export '../platform/persistence_types.dart'
    show ChatResumeState, ChatResumeSnapshot, ChatClientPersistence;
export '../connections/hydration.dart'
    show ChatHydrateOptions, ChatHydrationPage;
import '../platform/tool_types.dart';
export '../platform/tool_types.dart';

/// Lifecycle state matching upstream `ChatClientState`.
enum ChatClientState { submitted, streaming, ready, error }

/// Request-local queue policy used when [ChatClient.sendText] arrives while a
/// run is active. Mirrors upstream `whenBusy`.
enum QueueWhenBusy { queue, drop, interrupt }

/// How the queue drains after the active run settles.
enum QueueDrainMode { fifo, batch }

/// What to do when the queue is at `maxSize`.
enum QueueOverflow { reject, dropOldest }

/// Normalized queue configuration (upstream `normalizeQueueOption`).
class ChatQueueConfig {
  final QueueWhenBusy whenBusy;
  final QueueDrainMode drain;
  final int? maxSize;
  final QueueOverflow onOverflow;

  /// Optional strategy receives the pending item and current queue.
  final QueueWhenBusy Function(ChatQueueStrategyInput input)? strategy;

  const ChatQueueConfig({
    this.whenBusy = QueueWhenBusy.queue,
    this.drain = QueueDrainMode.fifo,
    this.maxSize,
    this.onOverflow = QueueOverflow.reject,
    this.strategy,
  });

  /// Accepts a string shorthand, [ChatQueueConfig], or a map:
  /// `{whenBusy, drain, maxSize, onOverflow, strategy}`.
  factory ChatQueueConfig.from(Object? raw) {
    if (raw == null) return const ChatQueueConfig();
    if (raw is ChatQueueConfig) return raw;
    if (raw is String) return ChatQueueConfig(whenBusy: parseWhenBusy(raw));
    if (raw is Map) {
      final whenBusy = parseWhenBusy(raw['whenBusy']);
      final drain =
          raw['drain'] == 'batch' ? QueueDrainMode.batch : QueueDrainMode.fifo;
      final maxSize = raw['maxSize'];
      if (maxSize != null && (maxSize is! int || maxSize < 0)) {
        throw ArgumentError.value(
            maxSize, 'maxSize', 'must be a non-negative int');
      }
      final onOverflow = raw['onOverflow'] == 'drop-oldest'
          ? QueueOverflow.dropOldest
          : QueueOverflow.reject;
      final strategy = raw['strategy'];
      final parsedStrategy = strategy is Function
          ? (ChatQueueStrategyInput input) => _callStrategy(strategy, input)
          : null;
      return ChatQueueConfig(
        whenBusy: whenBusy,
        // A custom strategy owns the decision; upstream forces FIFO.
        drain: parsedStrategy != null ? QueueDrainMode.fifo : drain,
        maxSize: maxSize is int ? maxSize : null,
        onOverflow: onOverflow,
        strategy: parsedStrategy,
      );
    }
    throw ArgumentError.value(raw, 'queue', 'must be a String or a Map');
  }

  static QueueWhenBusy parseWhenBusy(Object? value) => switch (value) {
        'drop' => QueueWhenBusy.drop,
        'interrupt' => QueueWhenBusy.interrupt,
        _ => QueueWhenBusy.queue,
      };
}

QueueWhenBusy _callStrategy(
  Function strategy,
  ChatQueueStrategyInput input,
) {
  final result = Function.apply(strategy, [input]);
  return result is QueueWhenBusy
      ? result
      : ChatQueueConfig.parseWhenBusy(result);
}

/// Input for a custom queue strategy.
class ChatQueueStrategyInput {
  final QueuedMessage pending;
  final String busyReason;
  final List<QueuedMessage> queued;

  const ChatQueueStrategyInput({
    required this.pending,
    required this.busyReason,
    required this.queued,
  });
}

/// A message held while another run owns the client.
class QueuedMessage {
  final String id;
  final dynamic content;
  final DateTime createdAt;
  final Map<String, dynamic>? body;

  QueuedMessage({
    required this.id,
    required this.content,
    DateTime? createdAt,
    this.body,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'content': content is Map && content['parts'] is List
            ? (content['parts'] as List)
                .map((part) =>
                    part is Map ? Map<String, dynamic>.from(part) : part)
                .toList()
            : content,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };
}

/// Optional per-call overrides for [ChatClient.sendText] / sendMessage.
class ChatSendOptions {
  final QueueWhenBusy? whenBusy;
  final Map<String, dynamic>? body;

  const ChatSendOptions({this.whenBusy, this.body});
}

/// A client-side tool the chat may execute automatically.
class ChatClientTool implements ClientTool<dynamic, dynamic> {
  @override
  final String name;
  @override
  final String description;
  @override
  final bool needsApproval;

  /// Returns the tool output. Receives the decoded input and the run context.
  @override
  final FutureOr<dynamic> Function(dynamic input, Object? context)? execute;

  /// Optional output validator. Throw to turn the result into `output-error`.
  final FutureOr<void> Function(dynamic output)? validateOutput;
  @override
  final ToolSchema? inputSchema;
  @override
  final ToolSchema? outputSchema;
  final Object? approvalSchema;
  @override
  final Object? metadata;

  const ChatClientTool({
    required this.name,
    this.description = '',
    this.needsApproval = false,
    this.execute,
    this.validateOutput,
    this.inputSchema,
    this.outputSchema,
    this.approvalSchema,
    this.metadata,
  });
  @override
  bool get hasExecute => execute != null;
  @override
  FutureOr<Object?> invoke(Object? input, ToolCallContext context) {
    final callback = execute;
    if (callback == null) {
      throw StateError('Tool $name has no execute callback');
    }
    return callback(input, context.context);
  }
}

/// A registered interrupt definition (generic AG-UI interrupts).
class ChatInterruptDefinition {
  final String id;
  final Object? responseSchema;
  final Object? payloadSchema;

  /// Optional validator for the response payload. Throw to reject.
  final void Function(dynamic payload)? validate;

  const ChatInterruptDefinition(
      {required this.id,
      this.validate,
      this.responseSchema,
      this.payloadSchema});
}

/// One resolved/unresolved interrupt surfaced by the client.
class ChatInterrupt {
  final String id;
  final String
      kind; // tool-approval | generic | client-tool-execution | unbound
  final String reason;
  final String? message;
  final String? toolName;
  final String? toolCallId;
  final dynamic input;
  final dynamic payload;
  final Map<String, dynamic>? metadata;
  final Map<String, dynamic>? binding;
  final String threadId;
  final String interruptedRunId;
  final int generation;
  dynamic originalArgs;
  dynamic responseSchema;
  String? expiresAt;
  ClientTool? tool;
  ChatInterruptDefinition? definition;
  int validationGeneration;
  ChatInterruptStatus status;
  String? definitionId;
  String? key;
  int? batchIndex;
  bool canResolve;
  Map<String, dynamic>? error;
  Map<String, dynamic>? resolution;
  Object? Function(dynamic response, [dynamic options])? onResolveInterrupt;
  void Function()? onCancel;
  void Function()? onClearResolution;

  ChatInterrupt({
    required this.id,
    required this.kind,
    required this.reason,
    this.message,
    this.toolName,
    this.toolCallId,
    this.input,
    this.payload,
    this.metadata,
    this.binding,
    required this.threadId,
    required this.interruptedRunId,
    required this.generation,
    this.originalArgs,
    this.responseSchema,
    this.expiresAt,
    this.tool,
    this.definition,
    this.validationGeneration = 0,
    this.status = ChatInterruptStatus.pending,
    this.canResolve = true,
    this.definitionId,
    this.key,
    this.batchIndex,
    this.error,
    this.resolution,
    this.onResolveInterrupt,
    this.onCancel,
    this.onClearResolution,
  });

  bool get resumable => canResolve && status != ChatInterruptStatus.error;

  List<Map<String, dynamic>> get errors => error == null
      ? const <Map<String, dynamic>>[]
      : <Map<String, dynamic>>[error!];

  dynamic resolveInterrupt(dynamic response, [dynamic options]) {
    final handler = onResolveInterrupt;
    if (handler != null) return handler(response, options);
    if (!canResolve) return null;
    resolution = <String, dynamic>{
      'interruptId': id,
      'status': 'resolved',
      if (response != null) 'payload': response,
    };
    return resolution;
  }

  dynamic resolveApproval(bool approved) => resolveInterrupt(
        <String, dynamic>{'approved': approved},
      );

  dynamic cancel() {
    final handler = onCancel;
    if (handler != null) return handler();
    resolution = <String, dynamic>{
      'interruptId': id,
      'status': 'cancelled',
    };
    return resolution;
  }

  void clearResolution() {
    final handler = onClearResolution;
    if (handler != null) {
      handler();
      return;
    }
    resolution = null;
  }

  ChatInterrupt copy() => ChatInterrupt(
        id: id,
        kind: kind,
        reason: reason,
        message: message,
        toolName: toolName,
        toolCallId: toolCallId,
        input: input,
        payload: payload,
        metadata: metadata,
        binding: binding,
        threadId: threadId,
        interruptedRunId: interruptedRunId,
        generation: generation,
        originalArgs: originalArgs,
        responseSchema: responseSchema,
        expiresAt: expiresAt,
        tool: tool,
        definition: definition,
        validationGeneration: validationGeneration,
        status: status,
        canResolve: canResolve,
        definitionId: definitionId,
        key: key,
        batchIndex: batchIndex,
        error: error,
        resolution: resolution,
        onResolveInterrupt: onResolveInterrupt,
        onCancel: onCancel,
        onClearResolution: onClearResolution,
      );
}

enum ChatInterruptStatus { pending, validating, staged, submitting, error }

/// Immutable interrupt state snapshot.
class ChatInterruptState {
  final List<ChatInterrupt> interrupts;
  final List<ChatInterrupt> pendingInterrupts;
  final List<Map<String, dynamic>> interruptErrors;
  final bool resuming;

  const ChatInterruptState({
    required this.interrupts,
    required this.pendingInterrupts,
    required this.interruptErrors,
    required this.resuming,
  });

  static const empty = ChatInterruptState(
    interrupts: <ChatInterrupt>[],
    pendingInterrupts: <ChatInterrupt>[],
    interruptErrors: <Map<String, dynamic>>[],
    resuming: false,
  );
}

/// Older-page hydration result.
class ChatHydrationResult {
  final List<AssistantTurn> messages;
  final ChatResumeState? activeRun;
  final ChatHydrationInterrupts? interrupts;
  final ChatHydrationPage? page;

  const ChatHydrationResult({
    required this.messages,
    this.activeRun,
    this.interrupts,
    this.page,
  });
}

/// Interrupt batch restored with a hydrated run.
class ChatHydrationInterrupts {
  final String runId;
  final String? threadId;
  final int generation;
  final List<Map<String, dynamic>> pending;

  const ChatHydrationInterrupts({
    required this.runId,
    this.threadId,
    this.generation = 0,
    required this.pending,
  });

  String get effectiveThreadId => threadId ?? runId;
}

/// Optional paged history configuration.
class ChatHistoryConfig {
  final int pageSize;

  const ChatHistoryConfig({required this.pageSize});
}

/// Snapshot consumed by UIs.
class ChatSnapshot {
  final List<AssistantTurn> messages;
  final List<QueuedMessage> queue;
  final String status;
  final bool isLoading;
  final bool isStreaming;
  final bool isHydrating;
  final bool sessionGenerating;
  final bool hasOlderMessages;
  final String? error;
  final bool isSubscribed;
  final String connectionStatus;
  final String? runId;
  final ChatInterruptState interruptState;

  const ChatSnapshot({
    required this.messages,
    required this.queue,
    required this.status,
    required this.isLoading,
    required this.isStreaming,
    required this.isHydrating,
    required this.sessionGenerating,
    required this.hasOlderMessages,
    required this.error,
    this.isSubscribed = false,
    this.connectionStatus = 'disconnected',
    this.runId,
    this.interruptState = ChatInterruptState.empty,
  });
}

/// Hydration callback (server or storage).
typedef ChatHydrateCallback = FutureOr<ChatHydrationResult> Function(
  String threadId,
  ChatHydrateOptions options,
);

/// A persisted conversation adapter (upstream `ChatClientPersistence`).
class ChatPersistence {
  final FutureOr<List<AssistantTurn>?> Function()? getItem;
  final FutureOr<void> Function(List<AssistantTurn> messages)? setItem;
  final FutureOr<void> Function()? removeItem;

  const ChatPersistence({this.getItem, this.setItem, this.removeItem});
}

/// Content input accepted by [ChatClient.sendMessage].
class ChatMessageInput {
  final dynamic content;
  final String? id;
  final Map<String, dynamic>? metadata;

  const ChatMessageInput({
    required this.content,
    this.id,
    this.metadata,
  });
}

/// Typed persistence choices retain thread-id/history constraints in Dart.
class ChatPersistenceOptions {
  final String? threadId;
  final Object persistence;
  final ChatHistoryConfig? history;

  const ChatPersistenceOptions.ephemeral({this.threadId})
      : persistence = false,
        history = null;
  const ChatPersistenceOptions.server(
      {required String this.threadId, this.history})
      : persistence = true;
  const ChatPersistenceOptions.stored(
      {required String this.threadId, required ChatClientPersistence adapter})
      : persistence = adapter,
        history = null;
}

/// Optional configuration for [ChatClient]. All fields are optional so the
/// original `ChatClient(transport: ..., messages: ..., bodyBuilder: ...,
/// onChanged: ...)` constructor remains source-compatible.
class ChatClientOptions {
  final ConnectionAdapter? connection;
  final ChatFetcher? fetcher;
  final List<AssistantTurn>? initialMessages;
  final ChatResumeSnapshot? initialResumeSnapshot;
  final ChatPersistenceOptions? persistenceOptions;
  final ByokClient? byok;
  final FutureOr<String?> Function()? byokProvider;
  final FutureOr<void> Function()? onResponse;
  final AIDevtoolsClientMetadata? devtools;
  final ChatDevtoolsBridgeFactory? devtoolsBridgeFactory;
  final String? threadId;
  final ChatQueueConfig? queue;
  final ChatHistoryConfig? history;
  final ChatHydrateCallback? hydrate;
  final Object? context;
  final List<ClientTool>? tools;
  final List<ChatInterruptDefinition>? interrupts;
  final Map<String, dynamic>? body;
  final Map<String, dynamic>? forwardedProps;
  final ChatResumeState? initialResume;
  final ChatHydrationInterrupts? initialInterrupts;

  /// false/omitted: ephemeral; true: server hydration; adapter: client storage.
  final Object? persistence;

  final void Function(List<AssistantTurn> messages)? onMessagesChange;
  final void Function(bool loading)? onLoadingChange;
  final void Function(String status)? onStatusChange;
  final void Function(bool subscribed)? onSubscriptionChange;
  final void Function(String status)? onConnectionStatusChange;
  final void Function(Map<String, dynamic> chunk)? onChunk;
  final void Function(Map<String, dynamic> chunk)? onFinish;
  final void Function(Object error, Map<String, dynamic>? chunk)? onError;
  final void Function(List<QueuedMessage> queue)? onQueueChange;
  final void Function(bool generating)? onSessionGeneratingChange;
  final void Function(String? runId)? onRunIdChange;
  final void Function(ChatInterruptState state, String source)?
      onInterruptStateChange;
  final void Function(Map<String, dynamic> event, Object? context)?
      onCustomEvent;

  const ChatClientOptions({
    this.connection,
    this.fetcher,
    this.initialMessages,
    this.initialResumeSnapshot,
    this.persistenceOptions,
    this.byok,
    this.byokProvider,
    this.onResponse,
    this.devtools,
    this.devtoolsBridgeFactory,
    this.threadId,
    this.queue,
    this.history,
    this.hydrate,
    this.context,
    this.tools,
    this.interrupts,
    this.body,
    this.forwardedProps,
    this.initialResume,
    this.initialInterrupts,
    this.persistence,
    this.onMessagesChange,
    this.onLoadingChange,
    this.onStatusChange,
    this.onSubscriptionChange,
    this.onConnectionStatusChange,
    this.onChunk,
    this.onFinish,
    this.onError,
    this.onQueueChange,
    this.onSessionGeneratingChange,
    this.onRunIdChange,
    this.onInterruptStateChange,
    this.onCustomEvent,
  });
}

/// Preserve an explicitly typed options value, matching the upstream helper.
ChatClientOptions createChatClientOptions(ChatClientOptions options) => options;
