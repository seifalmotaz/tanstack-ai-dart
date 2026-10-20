import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'connections/cancellation.dart';
import 'connections/connection_adapter.dart';
import 'connections/stream_connections.dart'
    show ChatFetcher, fetcherToConnectionAdapter;
import 'connections/types.dart'
    show ClientToolDeclaration, RunAgentInputContext;
import 'processing/processor.dart' as proc;
import 'processing/message_converters.dart' as converters;
import 'chat/cleared_stream_tracker.dart';
import 'chat/connection_transport.dart';
import 'chat/devtools_adapter.dart';
import 'chat/interrupt_manager.dart';
import 'chat/types.dart';
import 'chat/message_snapshot.dart';
import 'chat/processing_scheduler.dart';
import 'chat/legacy_persistence.dart';
import 'platform/client_persistor.dart' as caching;
import 'platform/persistence_types.dart' as storage;
import 'devtools/devtools_noop.dart' show ChatDevtoolsBridgeFactory;
import 'devtools/devtools_types.dart';
import 'platform/events.dart' show ChatClientStructuredOutputEvent;
import 'protocol.dart';
import 'transport.dart';
import 'identity.dart';
import 'platform/byok/byok.dart' as byok_api;

enum ChatClientStatus { idle, streaming, error }

/// Convenience wrapper around a [ChatTransport].
///
/// It owns [messages], folds events into the last assistant turn with
/// [AssistantStreamReducer], and supports send / stop / approval continuation.
/// Supply [bodyBuilder] when the server needs a custom request body (durable
/// thread id, model options, etc.). Otherwise [assistantChatBody] is used with
/// no thread id.
///
/// The original constructor stays source-compatible. The optional parameters
/// add the upstream TanStack surfaces: queue policies, interrupts, history
/// paging, runtime context, client tools, subagent handles and snapshots.
class ChatClient {
  final ChatTransport? transport;
  ConnectionAdapter? connection;
  final List<AssistantTurn> messages;
  Map<String, dynamic> Function(List<AssistantTurn> messages)? bodyBuilder;
  void Function()? onChanged;

  ChatClient({
    ChatTransport? transport,
    ConnectionAdapter? connection,
    ChatFetcher? fetcher,
    List<AssistantTurn>? messages,
    List<AssistantTurn>? initialMessages,
    this.bodyBuilder,
    this.onChanged,
    void Function(String status)? onStatusChange,
    void Function(bool subscribed)? onSubscriptionChange,
    void Function(String status)? onConnectionStatusChange,
    ChatClientOptions? options,
    StreamProcessingScheduler? processingScheduler,
    byok_api.ByokClient? byokClient,
    byok_api.ByokClient? byok,
    FutureOr<String?> Function()? byokProvider,
    FutureOr<void> Function()? onResponse,
    AIDevtoolsClientMetadata? devtools,
    ChatDevtoolsBridgeFactory? devtoolsBridgeFactory,
    String? threadId,
    ChatQueueConfig? queue,
    ChatHistoryConfig? history,
    ChatHydrateCallback? hydrate,
    Object? context,
    List<ClientTool>? tools,
    List<ChatInterruptDefinition>? interrupts,
    Map<String, dynamic>? body,
    Map<String, dynamic>? forwardedProps,
    ChatResumeState? initialResume,
    storage.ChatResumeSnapshot? initialResumeSnapshot,
    ChatPersistenceOptions? persistenceOptions,
    ChatHydrationInterrupts? initialInterrupts,
    Object? persistence,
    void Function(List<AssistantTurn> messages)? onMessagesChange,
    void Function(bool loading)? onLoadingChange,
    void Function(Map<String, dynamic> chunk)? onChunk,
    void Function(Map<String, dynamic> chunk)? onFinish,
    void Function(Object error, Map<String, dynamic>? chunk)? onError,
    void Function(List<QueuedMessage> queue)? onQueueChange,
    void Function(bool generating)? onSessionGeneratingChange,
    void Function(String? runId)? onRunIdChange,
    void Function(ChatInterruptState state, String source)?
        onInterruptStateChange,
    void Function(Map<String, dynamic> event, Object? context)? onCustomEvent,
  })  : transport = transport,
        _processingScheduler =
            processingScheduler ?? StreamProcessingScheduler(),
        connection = _resolveConnection(connection ?? options?.connection,
            fetcher ?? options?.fetcher, transport),
        _byok = byokClient ?? byok,
        _byokProvider = byokProvider,
        _onResponse = onResponse,
        messages = connection != null ||
                fetcher != null ||
                options?.connection != null ||
                options?.fetcher != null ||
                initialMessages != null
            ? [
                for (final turn in initialMessages ??
                    messages ??
                    options?.initialMessages ??
                    <AssistantTurn>[])
                  copyAssistantTurn(turn)
              ]
            : messages ?? options?.initialMessages ?? <AssistantTurn>[],
        _options = _mergeOptions(
          options,
          onMessagesChange: onMessagesChange,
          onLoadingChange: onLoadingChange,
          onChunk: onChunk,
          onFinish: onFinish,
          onError: onError,
          onQueueChange: onQueueChange,
          onSessionGeneratingChange: onSessionGeneratingChange,
          onRunIdChange: onRunIdChange,
          onInterruptStateChange: onInterruptStateChange,
          onCustomEvent: onCustomEvent,
          tools: tools,
        ) {
    final opts = _options;
    _onCustomEvent = opts.onCustomEvent;
    _byok ??= opts.byok;
    _byokProvider ??= opts.byokProvider;
    _onResponse ??= opts.onResponse;
    final persistenceSettings = persistenceOptions ?? opts.persistenceOptions;
    final resumeSnapshot = initialResumeSnapshot ?? opts.initialResumeSnapshot;
    final devtoolsOptions = devtools ?? opts.devtools;
    _onStatusChange = onStatusChange ?? opts.onStatusChange;
    _onSubscriptionChange = onSubscriptionChange ?? opts.onSubscriptionChange;
    _onConnectionStatusChange =
        onConnectionStatusChange ?? opts.onConnectionStatusChange;
    _threadId = threadId ?? opts.threadId ?? persistenceSettings?.threadId;
    final persistenceConfig =
        persistence ?? persistenceSettings?.persistence ?? opts.persistence;
    _queueConfig = queue ?? opts.queue ?? const ChatQueueConfig();
    _history = history ?? persistenceSettings?.history ?? opts.history;
    if (this.connection != null && persistenceConfig != true) {
      if (_history != null && persistenceConfig is ChatClientPersistence) {
        throw ArgumentError(
            'history requires server-authoritative persistence:true');
      }
      _history = null;
    }
    _hydrate = hydrate ??
        opts.hydrate ??
        (this.connection?.hydrate == null || persistenceConfig != true
            ? null
            : connectionHydrateCallback(this.connection!.hydrate!));
    _context = context ?? opts.context;
    _bodyOption = body ?? opts.body;
    _forwardedProps = forwardedProps ?? opts.forwardedProps;

    _interruptManager = InterruptManager(
      tools: tools ?? opts.tools,
      interrupts: interrupts ?? opts.interrupts,
      onChange: (state, source) {
        opts.onInterruptStateChange?.call(state, source);
        _notify();
      },
      submitSubmission: _submitInterruptBatch,
    );
    _connectionTransport = this.connection == null
        ? null
        : ConnectionChatTransport(this.connection!);
    _initialResume =
        initialResume ?? opts.initialResume ?? resumeSnapshot?.resumeState;
    _initialInterrupts = initialInterrupts ??
        opts.initialInterrupts ??
        (resumeSnapshot != null && resumeSnapshot.pendingInterrupts.isNotEmpty
            ? ChatHydrationInterrupts(
                runId: resumeSnapshot.resumeState.runId,
                threadId: resumeSnapshot.resumeState.threadId,
                pending: resumeSnapshot.pendingInterrupts)
            : null);
    if (_initialResume != null) {
      _resumeState = _initialResume;
      _threadId ??= _initialResume!.threadId;
      _runId = _initialResume!.runId;
      _activeRunIds.add(_initialResume!.runId);
    }
    if (_hydrate != null && _threadId != null) {
      _isHydrating = true;
    }
    if (persistenceConfig != null &&
        persistenceConfig != false &&
        (_threadId == null || _threadId!.isEmpty)) {
      throw ArgumentError(
        'ChatClient: persistence needs a stable `threadId` so the same '
        'conversation is loaded on the next mount.',
      );
    }
    _devtools = ChatDevtoolsAdapter(
      metadata: AIDevtoolsClientMetadata(
        name: devtoolsOptions?.name,
        framework: devtoolsOptions?.framework,
        hookName: devtoolsOptions?.hookName ?? 'useChat',
        outputKind: devtoolsOptions?.outputKind ?? 'chat',
      ),
      factory: devtoolsBridgeFactory ?? opts.devtoolsBridgeFactory,
      hookId: () => _threadId ?? '',
      threadId: () => _threadId,
      getSnapshot: _devtoolsSnapshot,
      getMessages: _devtoolsMessages,
      setMessages: _setDevtoolsMessages,
      addToolResult: _addDevtoolsToolResult,
      generateId: _newMessageId,
      getTools: () => _options.tools ?? const <ClientTool>[],
      getContext: () => _context,
    );
    if (_initialInterrupts != null) {
      _interruptManager.hydrate(_initialInterrupts!, source: 'hydrate');
    }
    _syncSubagents();
    _initializePersistence(persistenceConfig);
    _constructed = true;
    _lastNotifiedTranscript = messagesFingerprint();
  }

  void _initializePersistence(Object? config) {
    if (config == null || config == false || config == true) return;
    final storage.ChatClientPersistence adapter;
    if (config is ChatPersistence) {
      adapter = LegacyChatPersistenceAdapter(config);
    } else if (config is storage.ChatClientPersistence) {
      adapter = config;
    } else {
      throw ArgumentError(
          'persistence must be a bool or a chat storage adapter');
    }
    final persistor = caching.ChatPersistor(adapter, _threadId!, (rows) {
      if (_disposed) return;
      messages
        ..clear()
        ..addAll(assistantTurnsFromProcessor(rows));
      _syncSubagents();
      _notify();
    }, _restoreStoredResume);
    _persistor = persistor;
    final initial = persistor.readInitial();
    if (initial is Future<storage.ChatPersistedState?>) {
      _isHydrating = true;
      _persistenceReady = persistor.hydrateAsync(initial)?.whenComplete(() {
        if (_disposed) return;
        if (_hydrate == null) _isHydrating = false;
        _notify();
      });
    } else if (initial != null) {
      messages
        ..clear()
        ..addAll(assistantTurnsFromProcessor(initial.messages));
      if (initial.resume != null) _restoreStoredResume(initial.resume!);
      _syncSubagents();
    }
  }

  void _restoreStoredResume(storage.ChatResumeSnapshot snapshot) {
    if (_disposed) return;
    _resumeState = snapshot.resumeState;
    _threadId = snapshot.resumeState.threadId;
    _runId = snapshot.resumeState.runId;
    if (snapshot.pendingInterrupts.isNotEmpty) {
      _interruptManager.hydrate(
          ChatHydrationInterrupts(
              runId: snapshot.resumeState.runId,
              threadId: snapshot.resumeState.threadId,
              pending: snapshot.pendingInterrupts),
          source: 'hydrate');
    } else {
      _rejoinRunId = snapshot.resumeState.runId;
      if (_attached) _maybeRejoinStoredRun();
    }
    _notify();
  }

  void _maybeRejoinStoredRun() {
    final runId = _rejoinRunId;
    if (runId == null ||
        _joinedRunId == runId ||
        _disposed ||
        connection?.joinRun == null) {
      return;
    }
    _joinedRunId = runId;
    unawaited(_joinRun(runId));
  }

  storage.ChatResumeSnapshot? getResumeSnapshot() {
    final run = _resumeState ??
        (_runId != null && isStreaming
            ? ChatResumeState(threadId: _threadId ?? '', runId: _runId!)
            : null);
    return run == null
        ? null
        : storage.ChatResumeSnapshot(
            resumeState: run,
            pendingInterrupts: _interruptManager.getDescriptors());
  }

  static ConnectionAdapter? _resolveConnection(ConnectionAdapter? connection,
      ChatFetcher? fetcher, ChatTransport? transport) {
    if (fetcher != null && (connection != null || transport != null)) {
      throw ArgumentError('Pass either connection, fetcher, or transport.');
    }
    if (fetcher != null) return fetcherToConnectionAdapter(fetcher);
    if (connection == null && transport == null) {
      throw ArgumentError(
          'ChatClient requires a connection, fetcher, or transport.');
    }
    if (connection != null) normalizeConnectionAdapter(connection);
    return connection;
  }

  ChatClientOptions _options;
  final StreamProcessingScheduler _processingScheduler;
  byok_api.ByokClient? _byok;
  FutureOr<String?> Function()? _byokProvider;
  FutureOr<void> Function()? _onResponse;
  void Function(Map<String, dynamic> event, Object? context)? _onCustomEvent;
  late final ChatDevtoolsAdapter _devtools;
  String? _devtoolsRunId;
  String? _devtoolsStreamId;
  ConnectionChatTransport? _connectionTransport;
  proc.StreamProcessor? _processor;
  CancellationController? _cancellation;
  bool _processorErrored = false;

  ChatClientStatus status = ChatClientStatus.idle;
  String? error;

  late String? _threadId;
  String? _runId;
  late ChatQueueConfig _queueConfig;
  ChatHistoryConfig? _history;
  ChatHydrateCallback? _hydrate;
  Object? _context;
  Map<String, dynamic>? _bodyOption;
  Map<String, dynamic>? _forwardedProps;
  caching.ChatPersistor? _persistor;
  Future<void>? _persistenceReady;
  String? _lastPersistedResume = '';
  bool _clearingStorage = false;
  String? _rejoinRunId;
  String? _joinedRunId;
  bool _attached = false;
  bool _tailingRun = false;
  Timer? _rejoinConnectTimer;
  bool _constructed = false;
  late final InterruptManager _interruptManager;
  ChatResumeState? _initialResume;
  ChatHydrationInterrupts? _initialInterrupts;

  final ClearedStreamTracker _clearedTracker = ClearedStreamTracker();
  final List<QueuedMessage> _queue = <QueuedMessage>[];
  final Set<String> _activeRunIds = <String>{};
  final Set<String> _knownServerMessageIds = <String>{};
  final Set<String> _stoppedSubagentIds = <String>{};
  final Map<String, SubagentHandle> _subagentHandles =
      <String, SubagentHandle>{};
  final List<void Function()> _snapshotListeners = <void Function()>[];

  StreamSubscription<Map<String, dynamic>>? _subscription;
  Completer<void>? _runCompletion;
  StreamSubscription<Map<String, dynamic>>? _nativeSubscription;
  CancellationController? _nativeCancellation;
  int _nativeGeneration = 0;
  bool _localRunStarted = false;
  bool _hasRunChunk = false;
  void Function(String status)? _onStatusChange;
  String _lastNotifiedStatus = 'ready';
  String? _lastNotifiedTranscript;
  AssistantTurn? _streamingTurn;
  AssistantStreamReducer? _reducer;
  ChatResumeState? _resumeState;
  ChatHydrationPage? _olderPage;
  int _generation = 0;
  int _continuationGeneration = 0;
  int _streamContinuationGeneration = 0;
  int _queueSeq = 0;
  int _historyGeneration = 0;
  bool _delivering = false;
  int _deliveryClaim = 0;
  int _sendClaim = 0;
  int _drainClaim = 0;
  bool _sendInFlight = false;
  bool _queueDraining = false;
  bool _stopQueueDrain = false;
  bool _isHydrating = false;
  bool _loadingOlder = false;
  bool _disposed = false;
  bool _detached = false;
  Future<void>? _hydrateFuture;
  ChatHydrationResult? _desiredHydration;
  bool _pendingToolContinuation = false;
  bool _resumeWasResume = false;
  List<Map<String, dynamic>>? _pendingResumeItems;
  Completer<void>? _pendingResumeCompletion;
  InterruptManagerSubmission? _activeInterruptSubmission;
  Object? _interruptSubmissionFailure;
  Map<String, dynamic>? _lastTerminalEvent;
  bool _subscribed = false;
  String _connectionStatus = 'idle';
  String _lastConnectionStatus = 'idle';
  bool _lastSubscribed = false;
  bool _lastSessionGenerating = false;
  void Function(bool)? _onSubscriptionChange;
  void Function(String)? _onConnectionStatusChange;
  ChatSnapshot? _snapshot;
  Map<String, AssistantTurn> _snapshotTurnCache = <String, AssistantTurn>{};

  bool get isStreaming => status == ChatClientStatus.streaming;
  bool getIsSubscribed() => _subscribed;
  String getConnectionStatus() => _connectionStatus;
  bool get isLoading => isStreaming || _sendInFlight || _queueDraining;

  ChatClientState getState() => state;

  ChatClientState get state => switch (status) {
        ChatClientStatus.idle =>
          error == null ? ChatClientState.ready : ChatClientState.error,
        ChatClientStatus.streaming => connection != null && !_hasRunChunk
            ? ChatClientState.submitted
            : ChatClientState.streaming,
        ChatClientStatus.error => ChatClientState.error,
      };

  String? get threadId => _threadId;
  String? get currentRunId => _runId;
  String? getCurrentRunId() => _runId;
  Object? get context => _context;
  bool get isHydrating => _isHydrating;
  bool get hasOlderMessages => _olderPage?.truncated == true;
  bool getHasOlderMessages() => hasOlderMessages;
  bool getIsHydrating() => _isHydrating;

  /// The active reducer, exposed for tests or advanced callers.
  AssistantStreamReducer? get reducer => _reducer;

  List<AssistantTurn> getMessages() => messages;

  List<ChatInterrupt> getInterrupts() => _interruptManager.getInterrupts();

  List<ChatInterrupt> getPendingInterrupts() =>
      _interruptManager.getState().pendingInterrupts;

  ChatInterruptState getInterruptState() => _interruptManager.getState();

  ChatResumeState? getResumeState() => _resumeState;

  List<QueuedMessage> getQueue() => List<QueuedMessage>.from(_queue);

  List<SubagentHandle> getSubagents() =>
      List<SubagentHandle>.unmodifiable(_subagentHandles.values);

  bool getSessionGenerating() => _activeRunIds.isNotEmpty;

  bool getIsLoading() => isLoading;

  String getStatus() => state.name;

  String? getError() => error;

  ChatSnapshot getSnapshot() {
    return _snapshot ??= _buildSnapshot();
  }

  /// Registers this client with the devtools panel. Mirrors upstream
  /// `mountDevtools()`: explicit, idempotent and safe when the default no-op
  /// bridge is in use.
  void mountDevtools() {
    _ensureThreadId();
    _devtools.mount(messages.length);
  }

  void _ensureThreadId() {
    final existing = _threadId;
    if (existing == null || existing.isEmpty) {
      _threadId = generateIdentity('thread');
    }
  }

  AIDevtoolsChatSnapshot _devtoolsSnapshot() => AIDevtoolsChatSnapshot(
        messages: _devtoolsMessages(),
        status: state.name,
        isLoading: isLoading,
        isSubscribed: _subscribed,
        connectionStatus: _connectionStatus,
        sessionGenerating: getSessionGenerating(),
        activeRunIds: _activeRunIds.toList(growable: false),
        queue: getQueue().map((item) => item.toJson()).toList(growable: false),
        error: error,
      );

  List<Map<String, dynamic>> _devtoolsMessages() => <Map<String, dynamic>>[
        for (final turn in messages) _cloneTurn(turn).toRow(),
      ];

  void _setDevtoolsMessages(List<Map<String, dynamic>> next) {
    setMessagesManually(<AssistantTurn>[
      for (final raw in next)
        AssistantTurn(
          id: _str(raw['id']),
          role: _str(raw['role']),
          parts: [
            for (final part
                in raw['parts'] is List ? raw['parts'] as List : const [])
              if (part is Map)
                AssistantPart.fromJson(Map<String, dynamic>.from(part)),
          ],
          name: raw['name'] is String ? raw['name'] as String : null,
          metadata: raw['metadata'] is Map
              ? Map<String, dynamic>.from(raw['metadata'] as Map)
              : null,
          createdAt: raw['createdAt'] is String
              ? DateTime.tryParse(raw['createdAt'] as String)
              : null,
        ),
    ]);
  }

  void _addDevtoolsToolResult(
    String toolCallId,
    Object? output, [
    String? errorText,
  ]) {
    for (final turn in messages) {
      final index = turn.parts.indexWhere(
        (part) => part.type == 'tool-call' && part.id == toolCallId,
      );
      if (index < 0) continue;
      final part = turn.parts[index];
      final failed = errorText != null;
      part.output = failed ? errorText : output;
      part.hasOutput = true;
      part.state = failed ? 'error' : 'complete';
      if (!turn.parts.any(
        (candidate) =>
            candidate.type == 'tool-result' &&
            candidate.toolCallId == toolCallId,
      )) {
        turn.parts.add(
          AssistantPart(
            type: 'tool-result',
            name: part.name,
            toolCallId: toolCallId,
            content: _stringifyDevtoolsValue(output),
            output: failed ? errorText : output,
            state: failed ? 'error' : 'complete',
            error: errorText ?? '',
          ),
        );
      }
      break;
    }
    _notify();
  }

  static String _stringifyDevtoolsValue(Object? value) {
    if (value is String) return value;
    if (value == null) return 'null';
    try {
      return jsonEncode(value);
    } catch (_) {
      return '$value';
    }
  }

  void Function() subscribeSnapshot(void Function() listener) {
    _snapshotListeners.add(listener);
    return () => _snapshotListeners.remove(listener);
  }

  /// Loads persisted messages and, when configured, hydrates history.
  Future<void> attach() async {
    if (_disposed) return;
    if (_attached && !_detached && _hydrateFuture == null && error == null) {
      await _persistenceReady;
      return;
    }
    final inFlight = _hydrateFuture;
    if (inFlight != null) {
      _detached = false;
      await inFlight;
      final pending = _desiredHydration;
      if (pending != null && !_detached && !_disposed) {
        _desiredHydration = null;
        _applyHydration(pending, source: 'hydrate');
      }
      return;
    }
    _detached = false;
    _attached = true;
    final persistenceReady = _persistenceReady;
    if (persistenceReady != null) await persistenceReady;
    if (_disposed || _detached) return;
    _maybeRejoinStoredRun();
    if (_initialResume != null &&
        !_interruptManager.hasPending &&
        _rejoinRunId == null) {
      _rejoinRunId = _initialResume!.runId;
      _maybeRejoinStoredRun();
    }
    final hydrate = _hydrate;
    if (hydrate == null) return;
    final id = _threadId;
    if (id == null || id.isEmpty) return;
    final generation = ++_historyGeneration;
    _isHydrating = true;
    _notify();
    final future = () async {
      try {
        final options = ChatHydrateOptions(
          limit: _history?.pageSize,
        );
        final result = await Future.sync(() => hydrate(id, options));
        if (_disposed || generation != _historyGeneration) return;
        if (_detached) {
          _desiredHydration = result;
          return;
        }
        _applyHydration(result, source: 'hydrate');
      } catch (e) {
        if (_disposed || generation != _historyGeneration || _detached) {
          return;
        }
        final message = '$e';
        error = message;
        status = ChatClientStatus.error;
        _options.onError?.call(e, null);
        _notify();
      } finally {
        if (generation == _historyGeneration) {
          _isHydrating = false;
          _notify();
        }
      }
    }();
    _hydrateFuture = future;
    await future;
    if (identical(_hydrateFuture, future)) _hydrateFuture = null;
  }

  /// Detaches the view without cancelling a pending hydrate request.
  void detach() {
    _detached = true;
    if (_tailingRun) {
      unawaited(_cancelActive(clearQueue: false, keepResume: true));
    }
  }

  void _applyHydration(
    ChatHydrationResult result, {
    required String source,
  }) {
    error = null;
    if (status == ChatClientStatus.error) status = ChatClientStatus.idle;
    if (result.messages.isNotEmpty) {
      messages
        ..clear()
        ..addAll(result.messages);
      _rememberServerIds(result.messages);
    }
    final run = result.activeRun;
    final interrupts = result.interrupts;
    if (run != null) {
      _resumeState = run;
      _threadId = run.threadId;
      _runId = run.runId;
      _activeRunIds.add(run.runId);
    }
    if (interrupts != null &&
        interrupts.pending.isNotEmpty &&
        (run == null || run.runId == interrupts.runId)) {
      _resumeState = ChatResumeState(
        threadId: _threadId ?? '',
        runId: interrupts.runId,
      );
      _runId = interrupts.runId;
      _activeRunIds.add(interrupts.runId);
      _interruptManager.hydrate(
          ChatHydrationInterrupts(
            runId: interrupts.runId,
            threadId: _threadId,
            generation: interrupts.generation,
            pending: interrupts.pending,
          ),
          source: source);
    } else if (run != null && connection?.joinRun != null) {
      unawaited(_joinRun(run.runId));
    }
    _applyHydrationPage(result.page);
    _notify();
  }

  void _applyHydrationPage(ChatHydrationPage? page) {
    if (page != null && page.truncated) {
      _olderPage = page;
    } else {
      _olderPage = null;
    }
  }

  Future<void> loadOlderMessages() async {
    final hydrate = _hydrate;
    if (hydrate == null || _disposed) return;
    if (!hasOlderMessages) return;
    final cursor = _olderPage?.cursor;
    if (cursor == null || cursor.isEmpty) return;
    final id = _threadId;
    if (id == null || id.isEmpty) return;
    if (_loadingOlder) return;

    _loadingOlder = true;
    final generation = _historyGeneration;
    try {
      final result = await Future.sync(
        () => hydrate(
          id,
          ChatHydrateOptions(before: cursor, limit: _history?.pageSize),
        ),
      );
      if (_disposed || generation != _historyGeneration) return;
      if (result.messages.isEmpty) {
        throw StateError('Older page was empty');
      }
      _applyHydrationPage(result.page);
      messages.insertAll(0, result.messages);
      _rememberServerIds(result.messages);
      _notify();
    } finally {
      _loadingOlder = false;
    }
  }

  /// Appends a user turn and an assistant placeholder, then streams the reply.
  Future<void> sendText(String text, {ChatSendOptions? options}) async {
    await sendMessage(text, sendOptions: options);
  }

  /// Appends an existing user/activity message and streams the reply.
  Future<void> append(Object input) async {
    AssistantTurn message;
    if (input is AssistantTurn) {
      message = input;
    } else if (input is Map) {
      final raw = Map<String, dynamic>.from(input);
      if (raw['role'] == 'system') return;
      final rows = raw['parts'] is List
          ? [raw]
          : converters.modelMessagesToUIMessages([raw]);
      final converted = assistantTurnsFromProcessor(rows);
      if (converted.isEmpty) {
        throw ArgumentError('append requires a UI or model message');
      }
      message = converted.single;
    } else {
      throw ArgumentError('append requires a UI or model message');
    }
    if (_interruptManager.hasPending) {
      throw StateError(
        'ChatClient: cannot append normal input while pending interrupts '
        'exist. Use resumeInterrupts() instead.',
      );
    }
    if (message.role == 'system') return;
    if (message.id.isEmpty) {
      message = AssistantTurn(
          id: generateIdentity(message.role),
          role: message.role,
          parts: message.parts,
          streaming: message.streaming,
          name: message.name,
          metadata: message.metadata,
          createdAt: message.createdAt);
    }
    message.createdAt ??= DateTime.now();
    if (message.role == 'activity') {
      messages.add(message);
      _notify();
      return;
    }
    message.createdAt ??= DateTime.now();
    messages.add(message);
    final assistant = AssistantTurn.assistant(createdAt: DateTime.now());
    messages.add(assistant);
    await _start(assistant);
  }

  /// Start the persistent push subscription, or mark a request adapter active.
  void subscribe({bool restart = false}) {
    if (_disposed) return;
    if (restart) _stopNativeSubscription();
    _subscribed = true;
    _connectionStatus = 'connecting';
    _openNativeSubscription();
    _notify();
  }

  void _stopNativeSubscription() {
    _nativeGeneration++;
    _nativeCancellation?.cancel();
    _nativeCancellation = null;
    final current = _nativeSubscription;
    _nativeSubscription = null;
    if (current != null) unawaited(current.cancel().catchError((Object _) {}));
  }

  void _openNativeSubscription() {
    final subscribe = connection?.subscribe;
    if (subscribe == null || _nativeSubscription != null || _disposed) return;
    final generation = ++_nativeGeneration;
    final cancellation = CancellationController();
    _nativeCancellation = cancellation;
    _subscribed = true;
    _connectionStatus = 'connecting';
    _processor ??= proc.StreamProcessor(proc.StreamProcessorOptions(
        events: proc.StreamProcessorEvents(
            onStructuredOutputChange: _emitStructuredOutput),
        initialMessages: assistantWireTurns(messages, includeActivity: true)));
    final Stream<Map<String, dynamic>> source;
    try {
      source = subscribe(signal: cancellation.signal);
    } catch (failure) {
      _nativeFailure(failure);
      return;
    }
    _nativeSubscription =
        budgetStreamProcessing(source, _processingScheduler).listen(
      (event) {
        if (generation != _nativeGeneration ||
            _disposed ||
            cancellation.signal.isAborted) {
          return;
        }
        if (!_acceptChunk(event)) return;
        _connectionStatus = 'connected';
        final fallback = _streamingTurn ??
            AssistantTurn(id: 'background', role: 'assistant');
        final previousRun = _runId;
        final eventRun = _str(event['runId']);
        final settlesSend = _runCompletion != null &&
            (eventRun.isEmpty || eventRun == previousRun || !_localRunStarted);
        _processor ??= proc.StreamProcessor(proc.StreamProcessorOptions(
            events: proc.StreamProcessorEvents(
                onStructuredOutputChange: _emitStructuredOutput),
            initialMessages:
                assistantWireTurns(messages, includeActivity: true)));
        _handleConnectionEvent(event, fallback);
        if (settlesSend && _isFinalTerminal(event)) {
          _processor?.finalizeStream();
          _syncProcessorMessages();
          _finish(_currentTurn(fallback),
              error: _processorErrored
                  ? (error ?? 'The assistant run failed.')
                  : null,
              status: _processorErrored
                  ? ChatClientStatus.error
                  : ChatClientStatus.idle);
        }
      },
      onError: (Object failure, StackTrace stack) {
        if (generation != _nativeGeneration || _disposed) return;
        _nativeFailure(failure);
      },
      onDone: () {
        if (generation != _nativeGeneration || _disposed) return;
        _nativeSubscription = null;
        _subscribed = false;
        _connectionStatus = 'disconnected';
        _activeRunIds.clear();
        if (_runCompletion != null) {
          _finish(
              _currentTurn(AssistantTurn(id: 'background', role: 'assistant')),
              error: null,
              status: ChatClientStatus.idle);
        }
        _notify();
      },
    );
  }

  void _nativeFailure(Object failure) {
    _stopNativeSubscription();
    _subscribed = false;
    _connectionStatus = 'error';
    _activeRunIds.clear();
    _finish(_currentTurn(AssistantTurn(id: 'background', role: 'assistant')),
        error: '$failure', status: ChatClientStatus.error);
  }

  bool _acceptChunk(Map<String, dynamic> event) {
    if (event['type'] == 'SUBAGENT_STARTED') {
      _stoppedSubagentIds.remove(_str(event['subagentRunId']));
    }
    if (!_clearedTracker.shouldIgnoreChunk(event)) return true;
    if (_isFinalTerminal(event)) {
      final runId = _str(event['runId']);
      if (runId.isNotEmpty) {
        _clearedTracker.onRunSettled(runId);
      } else {
        _clearedTracker.onSessionRunError();
      }
    }
    return false;
  }

  bool _isIntermediateToolTurn(Map<String, dynamic> event) {
    if (event['type'] != 'RUN_FINISHED') return false;
    if (event['outcome'] is Map &&
        (event['outcome'] as Map)['type'] == 'interrupt') {
      return false;
    }
    final metadata = event['metadata'];
    final tanstack = metadata is Map ? metadata['tanstack'] : null;
    return (event['finishReason'] ??
            (tanstack is Map ? tanstack['finishReason'] : null)) ==
        'tool_calls';
  }

  bool _isFinalTerminal(Map<String, dynamic> event) =>
      event['type'] == 'RUN_ERROR' ||
      (event['type'] == 'RUN_FINISHED' && !_isIntermediateToolTurn(event));

  /// Tears down live behavior and aborts an in-flight request.
  Future<void> unsubscribe() async {
    _stopNativeSubscription();
    _continuationGeneration++;
    _activeRunIds.clear();
    _flushQueue();
    _resumeState = null;
    _interruptManager.reset();
    await _cancelActive(clearQueue: true, keepResume: false);
    _subscribed = false;
    _connectionStatus = 'disconnected';
    _notify();
  }

  /// Sends text or a [ChatMessageInput] with optional per-call body overrides.
  Future<void> sendMessage(
    dynamic content, {
    Map<String, dynamic>? body,
    ChatSendOptions? sendOptions,
  }) async {
    final normalized = _normalizeInput(content);
    if (normalized == null) return;
    if (_isHydrating) {
      _isHydrating = false;
      _historyGeneration++;
      _notify();
    }
    if (_interruptManager.hasPending) {
      throw StateError(
        'ChatClient: cannot send normal input while pending interrupts exist. '
        'Use resumeInterrupts() instead.',
      );
    }
    final resolvedBody = <String, dynamic>{
      ...?_bodyOption,
      ...?_forwardedProps,
      ...?body,
      ...?sendOptions?.body,
    };

    if (isLoading) {
      final decision = _decideWhenBusy(content, sendOptions);
      if (decision.whenBusy == QueueWhenBusy.drop) return;
      if (decision.whenBusy == QueueWhenBusy.queue) {
        _enqueue(content, resolvedBody, decision.id);
        return;
      }
      // interrupt: abort the current run, keep queued items for later.
      _stopQueueDrain = true;
      await _cancelActive(clearQueue: false, keepResume: true);
      _activeRunIds.clear();
    }

    final claim = ++_sendClaim;
    _sendInFlight = true;
    try {
      await _deliverMessage(normalized, resolvedBody);
    } finally {
      if (claim == _sendClaim) {
        _sendInFlight = false;
        _notify();
      }
    }
  }

  _QueueDecision _decideWhenBusy(
    dynamic content,
    ChatSendOptions? sendOptions,
  ) {
    final id = _nextQueuedId();
    final override = sendOptions?.whenBusy;
    if (override != null) return _QueueDecision(override, id);
    final strategy = _queueConfig.strategy;
    if (strategy != null) {
      final pending = QueuedMessage(
        id: id,
        content: content,
        body: sendOptions?.body,
      );
      final reason = isStreaming
          ? 'streaming'
          : (_queueDraining ? 'draining' : 'sendInFlight');
      try {
        final action = strategy(
          ChatQueueStrategyInput(
            pending: pending,
            busyReason: reason,
            queued: getQueue(),
          ),
        );
        return _QueueDecision(action, id);
      } catch (_) {
        return _QueueDecision(_queueConfig.whenBusy, id);
      }
    }
    return _QueueDecision(_queueConfig.whenBusy, id);
  }

  void _enqueue(dynamic content, Map<String, dynamic> body, String id) {
    final maxSize = _queueConfig.maxSize;
    if (maxSize != null && _queue.length >= maxSize) {
      if (_queueConfig.onOverflow == QueueOverflow.reject || maxSize == 0) {
        return;
      }
      _queue.removeAt(0);
    }
    _queue.add(
      QueuedMessage(
        id: id,
        content: content,
        body: body.isEmpty ? null : body,
      ),
    );
    _emitQueueChange();
  }

  String _nextQueuedId() =>
      'queued-${DateTime.now().microsecondsSinceEpoch}-${_queueSeq++}';

  void _emitQueueChange() {
    _options.onQueueChange?.call(getQueue());
    _notify();
  }

  void cancelQueued(String id) {
    final index = _queue.indexWhere((item) => item.id == id);
    if (index < 0) return;
    _queue.removeAt(index);
    _emitQueueChange();
  }

  Future<void> _deliverMessage(
    _NormalizedInput input,
    Map<String, dynamic> body,
  ) async {
    if (isStreaming || _delivering) return;
    final claim = ++_deliveryClaim;
    _delivering = true;
    try {
      final user = AssistantTurn(
        id: input.id ?? _newMessageId('user'),
        role: 'user',
        parts: input.parts,
        metadata: input.metadata,
        createdAt: DateTime.now(),
      );
      messages.add(user);
      _devtools.bridge.events.messageSent(
        user.id,
        input.parts.length == 1 && input.parts.single.type == 'text'
            ? input.parts.single.content
            : input.parts.map((part) => part.toJson()).toList(),
      );
      final assistant = AssistantTurn.assistant(createdAt: DateTime.now());
      messages.add(assistant);
      _pendingMessageBody = body;
      _notify();
      await _start(assistant);
    } finally {
      if (claim == _deliveryClaim) _delivering = false;
    }
  }

  Map<String, dynamic>? _pendingMessageBody;

  /// Marks [part]'s approval and streams the continuation.
  Future<void> approve(AssistantPart part, bool approved) async {
    final approval = part.approval;
    final turn = _turnForPart(part);
    if (approval == null || approval.approved != null || turn == null) {
      return;
    }
    approval.approved = approved;
    part.state = 'approval-responded';
    _devtools.bridge.events.toolApprovalResponded(
      approval.id,
      part.id,
      approved,
    );
    _notify();

    // Native interrupt path: resolve the descriptor and resume when complete.
    if (_interruptManager.resolveToolApprovalDecision(approval.id, approved)) {
      return;
    }
    if (isStreaming) {
      _pendingToolContinuation = true;
      return;
    }
    await _start(turn);
  }

  /// Responds by approval id (upstream `addToolApprovalResponse`).
  Future<void> addToolApprovalResponse({
    required String id,
    required bool approved,
  }) async {
    for (final turn in messages) {
      for (final part in turn.parts) {
        if (part.approval?.id == id) {
          if (part.approval!.approved == null) {
            await approve(part, approved);
          }
          return;
        }
      }
    }
    if (_interruptManager.resolveToolApprovalDecision(id, approved)) {
      _notify();
    }
  }

  /// Adds the result of a client-side tool execution.
  Future<void> addToolResult({
    required String toolCallId,
    String? tool,
    dynamic output,
    String state = 'output-available',
    String? errorText,
  }) async {
    final continuationGeneration = _streamContinuationGeneration;
    AssistantPart? found;
    AssistantTurn? owner;
    for (final turn in messages) {
      for (final part in turn.parts) {
        if (part.type == 'tool-call' && part.id == toolCallId) {
          found = part;
          owner = turn;
          break;
        }
      }
      if (found != null) break;
    }
    final definition = _toolNamed(tool ?? found?.name ?? '');
    if (state != 'output-error' && definition != null) {
      try {
        final validated =
            await validateWithSchema(definition.outputSchema, output);
        if (!validated.success) {
          throw StateError(
              validated.issues.map((issue) => issue.message).join('; '));
        }
        output = validated.data;
        if (definition is ChatClientTool && definition.validateOutput != null) {
          await definition.validateOutput!(output);
        }
      } catch (failure) {
        state = 'output-error';
        errorText = '$failure';
      }
      if (continuationGeneration != _continuationGeneration || _disposed) {
        return;
      }
    }
    if (found != null) {
      found.output = state == 'output-error'
          ? (errorText ?? 'Tool execution failed')
          : output;
      found.hasOutput = true;
      found.state = state == 'output-error' ? 'error' : 'complete';
      _notify();
    }
    if (state == 'output-error'
        ? _interruptManager.resolveClientToolError(
            toolCallId,
            errorText ?? 'Tool execution failed',
          )
        : _interruptManager.resolveClientToolOutput(toolCallId, output)) {
      return;
    }
    if (continuationGeneration != _continuationGeneration) return;
    if (isStreaming) {
      _pendingToolContinuation = true;
      return;
    }
    if (found != null && owner != null && _shouldAutoSend()) {
      final assistant = AssistantTurn.assistant(createdAt: DateTime.now());
      messages.add(assistant);
      await _start(assistant);
    }
  }

  /// Cancel the active stream and close the transport client promptly.
  Future<void> stop() async {
    _continuationGeneration++;
    _activeInterruptSubmission = null;
    _interruptSubmissionFailure = null;
    _activeRunIds.clear();
    _resumeState = null;
    _resumeWasResume = false;
    _interruptManager.reset();
    _pendingToolContinuation = false;
    await _cancelActive(clearQueue: true, keepResume: false);
    _options.onRunIdChange?.call(null);
    _notify();
  }

  /// Clear all messages and pending state.
  Future<void> clear() async {
    _continuationGeneration++;
    final hadActive = _subscription != null || _sendInFlight || isLoading;
    _clearedTracker.snapshotClear(
      messages: messages,
      activeRunIds: _activeRunIds,
      currentRunId: _runId,
    );
    if (hadActive) {
      await _cancelActive(clearQueue: true, keepResume: false);
    } else {
      _flushQueue();
    }
    _activeRunIds.clear();
    messages.clear();
    _processor?.setMessages([]);
    _knownServerMessageIds.clear();
    _olderPage = null;
    _historyGeneration++;
    _isHydrating = false;
    _desiredHydration = null;
    _resumeState = null;
    _runId = null;
    _threadId = _threadId; // cleared state keeps the configured thread id
    _interruptManager.reset();
    _subagentHandles.clear();
    _stoppedSubagentIds.clear();
    _pendingToolContinuation = false;
    error = null;
    status = ChatClientStatus.idle;
    _persistor?.remove();
    _lastPersistedResume = '';
    _clearingStorage = true;
    try {
      _notify();
    } finally {
      _clearingStorage = false;
    }
  }

  /// Reload the last assistant message from the last user turn.
  Future<void> reload() async {
    _continuationGeneration++;
    final lastUser = messages.lastIndexWhere((turn) => turn.role == 'user');
    if (lastUser == -1) return;
    if (isStreaming) {
      await _cancelActive(clearQueue: false, keepResume: true);
    }
    _flushQueue();
    final retained = messages.sublist(0, lastUser + 1);
    messages
      ..clear()
      ..addAll(retained);
    _notify();
    final assistant = AssistantTurn.assistant(createdAt: DateTime.now());
    messages.add(assistant);
    await _start(assistant);
  }

  Future<void> _submitInterruptBatch(
      InterruptManagerSubmission submission) async {
    final generation = _continuationGeneration;
    _activeInterruptSubmission = submission;
    _interruptSubmissionFailure = null;
    for (final resolution in submission.resolutions) {
      final payload = resolution['payload'];
      if (payload is Map && payload['approved'] is bool) {
        _processor?.addToolApprovalResponse(
            resolution['interruptId'] as String, payload['approved'] as bool);
      }
    }
    if (_processor != null) _syncProcessorMessages();
    try {
      if (isLoading) {
        _pendingResumeItems = submission.resolutions;
        final completion = _pendingResumeCompletion = Completer<void>();
        await completion.future;
      } else {
        await _resumeFromManager(items: submission.resolutions);
      }
      if (generation != _continuationGeneration) return;
      final failure = _interruptSubmissionFailure;
      if (failure != null) throw failure;
      if (status == ChatClientStatus.error) {
        throw StateError(error ?? 'Interrupt continuation failed');
      }
    } finally {
      if (identical(_activeInterruptSubmission, submission)) {
        _activeInterruptSubmission = null;
      }
    }
  }

  Future<void> _resumeFromManager({
    List<Map<String, dynamic>>? items,
  }) async {
    items ??= _interruptManager.getResolutions();
    final state = _resumeState;
    if (items.isEmpty || state == null) return;
    _resumeWasResume = true;
    final assistant = AssistantTurn.assistant(createdAt: DateTime.now());
    messages.add(assistant);
    await _start(
      assistant,
      resumeItems: items,
      resumeThreadId: state.threadId,
      resumeParentRunId: state.runId,
    );
  }

  void resolveInterrupts(Object resolution) =>
      _interruptManager.resolve(resolution);
  void cancelInterrupts() => _interruptManager.cancel();
  void retryInterrupts() => _interruptManager.retry();

  /// Sends AG-UI resume entries with the interrupted run context.
  Future<void> resumeInterrupts(List<Map<String, dynamic>> items) async {
    _pendingResumeItems = null;
    final state = _resumeState;
    if (state == null) {
      throw StateError('ChatClient: no interrupted run to resume.');
    }
    _resumeWasResume = true;
    final assistant = AssistantTurn.assistant(createdAt: DateTime.now());
    messages.add(assistant);
    await _start(
      assistant,
      resumeItems: items,
      resumeThreadId: state.threadId,
      resumeParentRunId: state.runId,
    );
  }

  /// Resume with an explicit durable pointer (upstream `resumeInterruptsUnsafe`).
  Future<void> resumeInterruptsUnsafe(
    List<Map<String, dynamic>> items, {
    required String threadId,
    required String runId,
  }) async {
    _pendingResumeItems = null;
    _resumeState = ChatResumeState(threadId: threadId, runId: runId);
    _threadId = threadId;
    _runId = runId;
    _resumeWasResume = true;
    final assistant = AssistantTurn.assistant(createdAt: DateTime.now());
    messages.add(assistant);
    await _start(
      assistant,
      resumeItems: items,
      resumeThreadId: threadId,
      resumeParentRunId: runId,
    );
  }

  Future<void> _start(
    AssistantTurn turn, {
    List<Map<String, dynamic>>? resumeItems,
    String? resumeThreadId,
    String? resumeParentRunId,
  }) async {
    final token = ++_generation;
    _stopQueueDrain = false;
    _streamContinuationGeneration = _continuationGeneration;
    final requestRunId = generateIdentity('run');
    _startedTools.clear();
    _localRunStarted = false;
    _hasRunChunk = false;
    if (resumeParentRunId != null) {
      _interruptManager.trackRunStarted(requestRunId,
          parentRunId: resumeParentRunId);
    }
    _ensureThreadId();
    _streamingTurn = turn;
    status = ChatClientStatus.streaming;
    error = null;
    turn.streaming = true;
    _runId = requestRunId;
    _subscribed = true;
    _devtoolsRunId = requestRunId;
    _devtoolsStreamId = generateIdentity('stream');
    _devtools.bridge
      ..setCurrentStreamId(_devtoolsStreamId)
      ..beginRun(requestRunId, _threadId ?? '');
    _devtools.bridge.emitRunLifecycle(
      AIDevtoolsRunEventType.created,
      requestRunId,
      AIDevtoolsRunStatus.created,
    );
    _devtools.bridge.emitRunLifecycle(
      AIDevtoolsRunEventType.started,
      requestRunId,
      AIDevtoolsRunStatus.started,
    );
    _devtools.bridge.events.messageAppended(
      turn.toRow(),
      streamId: _devtoolsStreamId,
    );
    _options.onRunIdChange?.call(requestRunId);
    _options.onLoadingChange?.call(true);
    _notify();

    final sendMessages = _messagesForSend(fullHistory: resumeItems != null);
    final body = _buildBody(
      sendMessages,
      requestRunId: requestRunId,
      resumeItems: resumeItems,
      resumeThreadId: resumeThreadId,
      resumeParentRunId: resumeParentRunId,
    );
    _pendingMessageBody = null;

    try {
      await _onResponse?.call();
    } catch (e) {
      if (token == _generation && !_disposed) {
        _finish(turn, error: e.toString(), status: ChatClientStatus.error);
      }
      return;
    }
    if (token != _generation || _disposed) return;

    final connectionTransport = _connectionTransport;
    if (connectionTransport != null) {
      final completion = Completer<void>();
      _runCompletion = completion;
      _reducer = null;
      _processor = proc.StreamProcessor(
        proc.StreamProcessorOptions(
          events: proc.StreamProcessorEvents(
              onStructuredOutputChange: _emitStructuredOutput),
          initialMessages: assistantWireTurns(messages, includeActivity: true)
              .where((message) => (message['parts'] as List).isNotEmpty)
              .toList(),
        ),
      );
      _processorErrored = false;
      final cancellation = CancellationController();
      _cancellation = cancellation;
      try {
        if (cancellation.signal.isAborted) {
          return await completion.future;
        }
        Map<String, String>? headers;
        final keyring = _byok;
        if (keyring != null) {
          final requested = await _byokProvider?.call();
          final provider = byok_api.resolveByokProviderId(null, [
            requested,
            (body['forwardedProps'] as Map?)?['provider'],
            _forwardedProps?['provider'],
            _bodyOption?['provider'],
            byok_api.byokFallbackProviderId(keyring)
          ]);
          headers =
              await byok_api.prepareResolvedByokHeaders(keyring, provider);
          if (token != _generation ||
              _disposed ||
              cancellation.signal.isAborted) {
            return await completion.future;
          }
        }
        if (connection?.subscribe != null) {
          _openNativeSubscription();
          final request = _connectionRequest(body, headers);
          await connection!.send!(request.messages,
              data: request.data,
              signal: cancellation.signal,
              runContext: request.context);
          return await completion.future;
        }
        _subscription = budgetStreamProcessing(
                _connectionStream(body, cancellation.signal, headers: headers),
                _processingScheduler)
            .listen(
          (event) {
            if (token != _generation || _disposed) return;
            if (!_acceptChunk(event)) return;
            _handleConnectionEvent(event, turn);
          },
          onError: (Object e, StackTrace _) {
            if (token != _generation || _disposed) return;
            _subscription = null;
            _requestByok(e);
            _finish(
              _currentTurn(turn),
              error: e.toString(),
              status: ChatClientStatus.error,
            );
          },
          onDone: () {
            if (token != _generation || _disposed) return;
            _subscription = null;
            _processor?.finalizeStream();
            _syncProcessorMessages();
            _finish(
              _currentTurn(turn),
              error: _processorErrored
                  ? (error ?? 'The assistant run failed.')
                  : null,
              status: _processorErrored
                  ? ChatClientStatus.error
                  : ChatClientStatus.idle,
            );
          },
          cancelOnError: true,
        );
      } catch (e) {
        if (token != _generation || _disposed) return completion.future;
        _requestByok(e);
        _finish(turn, error: e.toString(), status: ChatClientStatus.error);
      }
      return completion.future;
    }

    _reducer = AssistantStreamReducer(turn.parts);

    try {
      _subscription = transport!.stream(body).listen(
        (event) {
          if (token != _generation || _disposed) return;
          if (!_acceptChunk(event)) return;
          _handleEvent(event, turn);
        },
        onError: (Object e, StackTrace _) {
          if (token != _generation || _disposed) return;
          _subscription = null;
          _finish(
            turn,
            error: e.toString(),
            status: ChatClientStatus.error,
          );
        },
        onDone: () {
          if (token != _generation || _disposed) return;
          _subscription = null;
          final reducer = _reducer;
          final failure = reducer?.error ?? error;
          _finish(
            turn,
            error: failure,
            status: failure == null
                ? ChatClientStatus.idle
                : ChatClientStatus.error,
          );
        },
        cancelOnError: true,
      );
    } catch (e) {
      _finish(turn, error: e.toString(), status: ChatClientStatus.error);
    }
  }

  void _requestByok(Object error) {
    if (error is byok_api.ByokMissingError) {
      _byok?.request(error.provider, 'missing');
    } else if (error is byok_api.ByokBlockedError) {
      _byok?.request(error.provider, error.reason);
    }
  }

  ({
    List<Map<String, dynamic>> messages,
    Map<String, dynamic>? data,
    RunAgentInputContext context
  }) _connectionRequest(
      Map<String, dynamic> body, Map<String, String>? headers) {
    final rawMessages = body['messages'];
    final wireMessages = <Map<String, dynamic>>[
      if (rawMessages is List)
        for (final row in rawMessages)
          if (row is Map) row.map((key, value) => MapEntry('$key', value)),
    ];
    final forwarded = body['forwardedProps'] is Map
        ? Map<String, dynamic>.from(body['forwardedProps'] as Map)
        : null;
    final resume = body['resume'] is List
        ? [
            for (final item in body['resume'] as List)
              if (item is Map)
                item.map((key, value) => MapEntry('$key', value)),
          ]
        : null;
    final runContext = RunAgentInputContext(
      threadId: '${body['threadId'] ?? body['durableThreadId'] ?? ''}',
      runId: '${body['runId'] ?? ''}',
      parentRunId:
          body['parentRunId'] is String ? body['parentRunId'] as String : null,
      resume: resume,
      headers: headers,
      clientTools: [
        for (final tool in _options.tools ?? const <ClientTool>[])
          ClientToolDeclaration(
            name: tool.name,
            description: tool.description,
            parameters: convertSchemaToJsonSchema(tool.inputSchema),
          ),
      ],
      forwardedProps: forwarded,
    );

    return (messages: wireMessages, data: forwarded, context: runContext);
  }

  Stream<Map<String, dynamic>> _connectionStream(
    Map<String, dynamic> body,
    CancellationSignal signal, {
    Map<String, String>? headers,
  }) {
    final connection = this.connection;
    if (connection == null) return const Stream<Map<String, dynamic>>.empty();
    final request = _connectionRequest(body, headers);
    final messages = request.messages;
    final forwarded = request.data;
    final runContext = request.context;

    if (connection.connect != null && connection.subscribe == null) {
      late StreamController<Map<String, dynamic>> controller;
      StreamSubscription<Map<String, dynamic>>? subscription;
      var closed = false;
      void close() {
        if (closed) return;
        closed = true;
        unawaited(subscription?.cancel());
        if (!controller.isClosed) controller.close();
      }

      controller = StreamController<Map<String, dynamic>>(
        onListen: () {
          subscription = connection.connect!(
            messages,
            data: forwarded,
            signal: signal,
            runContext: runContext,
          )
              .listen(
            (chunk) {
              if (closed) return;
              controller.add(chunk);
            },
            onError: (Object error, StackTrace stack) {
              if (closed) return;
              controller.addError(error, stack);
              close();
            },
            onDone: close,
          );
          signal.addListener(close);
        },
        onCancel: close,
      );
      return controller.stream;
    }
    return ConnectionChatTransport(connection)
        .stream(body, headers: headers, signal: signal);
  }

  Map<String, dynamic> _buildBody(
    List<AssistantTurn> sendMessages, {
    required String requestRunId,
    List<Map<String, dynamic>>? resumeItems,
    String? resumeThreadId,
    String? resumeParentRunId,
  }) {
    final custom = bodyBuilder?.call(messages);
    final body =
        custom ?? assistantChatBody(resumeThreadId ?? _threadId, sendMessages);
    if (custom != null || _connectionTransport != null) {
      body['messages'] = _wireMessages(sendMessages);
    }
    if (custom == null || connection != null) {
      body['runId'] = requestRunId;
    } else {
      body.putIfAbsent('runId', () => requestRunId);
    }
    final effectiveThread = resumeThreadId ?? _threadId;
    if (effectiveThread != null && effectiveThread.isNotEmpty) {
      body.putIfAbsent('threadId', () => effectiveThread);
    }
    if (_options.tools != null) {
      body['tools'] = [
        for (final tool in _options.tools!)
          {
            'name': tool.name,
            'description': tool.description,
          },
      ];
    }
    final mergedForwarded = <String, dynamic>{
      ...?_forwardedProps,
      ...?_pendingMessageBody,
    };
    if (mergedForwarded.isNotEmpty) {
      body['forwardedProps'] = mergedForwarded;
    }
    if (resumeItems != null) {
      body['resume'] = resumeItems;
      if (resumeParentRunId != null) {
        body['parentRunId'] = resumeParentRunId;
      }
    }
    return body;
  }

  List<Map<String, dynamic>> _wireMessages(List<AssistantTurn> turns) {
    if (_connectionTransport != null) return assistantWireTurns(turns);
    return assistantWireMessages(turns);
  }

  List<AssistantTurn> _messagesForSend({bool fullHistory = false}) {
    final forModel = [
      for (final turn in messages)
        if (turn.role != 'activity' && _hasWireContent(turn)) turn,
    ];
    final pageSize = _history?.pageSize;
    if (pageSize == null || fullHistory) return forModel;
    final unknown = [
      for (final turn in forModel)
        if (!_knownServerMessageIds.contains(turn.id)) turn,
    ];
    if (unknown.isNotEmpty) return unknown;
    final lastUser = forModel.lastIndexWhere((turn) => turn.role == 'user');
    if (lastUser == -1) return const <AssistantTurn>[];
    return forModel.sublist(lastUser);
  }

  AssistantTurn _currentTurn(AssistantTurn fallback) {
    for (final turn in messages.reversed) {
      if (turn.role == 'assistant') return turn;
    }
    return fallback;
  }

  void _syncProcessorMessages() {
    final processor = _processor;
    if (processor == null) return;
    final converted = assistantTurnsFromProcessor(processor.getMessages());
    messages
      ..clear()
      ..addAll(converted);
    _syncSubagents();
  }

  List<Map<String, dynamic>> _eventInterrupts(Map<String, dynamic> event) {
    final out = <Map<String, dynamic>>[];
    void add(Object? raw) {
      if (raw is! List) return;
      for (final item in raw) {
        if (item is Map) out.add(Map<String, dynamic>.from(item));
      }
    }

    final outcome = event['outcome'];
    if (outcome is Map) add(outcome['interrupts']);
    add(event['interrupts']);
    return out;
  }

  bool _trackRunStarted(Map<String, dynamic> event) {
    final id = _str(event['runId']);
    if (id.isEmpty) return true;
    final parent =
        event['parentRunId'] is String ? event['parentRunId'] as String : null;
    if (!_interruptManager.trackRunStarted(id, parentRunId: parent)) {
      if (_resumeState != null &&
          _interruptManager.isRunAnswered(_resumeState!.runId)) {
        _resumeState = null;
        _resumeWasResume = false;
        _runId = _activeRunIds.isEmpty ? null : _activeRunIds.last;
        _notify();
      }
      return false;
    }
    if (_runCompletion != null) _localRunStarted = true;
    _runId = id;
    _activeRunIds.add(id);
    _clearedTracker.onRunStarted(id);
    return true;
  }

  void _handleConnectionEvent(
    Map<String, dynamic> event,
    AssistantTurn fallback,
  ) {
    final type = _str(event['type']);
    _hasRunChunk = true;
    _connectionStatus = 'connected';
    _devtools.bridge.observeChunk(event);
    if (type == 'RUN_STARTED' && !_trackRunStarted(event)) return;
    final submission = _activeInterruptSubmission;
    if (type == 'RUN_ERROR' && submission != null) {
      final metadata = event['metadata'];
      final tanstack = metadata is Map ? metadata['tanstack'] : null;
      final errors = tanstack is Map ? tanstack['interruptErrors'] : null;
      final eventRunId = _str(event['runId']);
      if (errors is List &&
          errors.isNotEmpty &&
          (eventRunId.isEmpty || eventRunId == _runId) &&
          (event['threadId'] == null ||
              event['threadId'] == submission.threadId) &&
          errors.every((item) =>
              item is Map &&
              item['threadId'] == submission.threadId &&
              item['interruptedRunId'] == submission.interruptedRunId &&
              item['generation'] == submission.generation)) {
        _interruptSubmissionFailure = {'errors': errors};
      }
    }

    final processor = _processor;
    if (processor != null) {
      processor.processChunk(event);
      _syncProcessorMessages();
    }

    if (type == 'CUSTOM') {
      final name = _str(event['name']);
      if (!const <String>{
        'approval-requested',
        'tool-approval-requested',
        'tool-input-available',
        'structured-output.start',
        'structured-output.delta',
        'structured-output.chunk',
        'structured-output.complete',
        'structured-output.error',
      }.contains(name)) {
        _onCustomEvent?.call(event, _context);
      }
    }

    if (type == 'RUN_FINISHED' && !_isIntermediateToolTurn(event)) {
      _lastTerminalEvent = event;
      final runId = _str(event['runId']);
      final effectiveRun = runId.isEmpty ? _runId : runId;
      if (effectiveRun != null) {
        _activeRunIds.remove(effectiveRun);
        _clearedTracker.onRunSettled(effectiveRun);
      }
      final interrupts = _eventInterrupts(event);
      final interrupted = interrupts.isNotEmpty ||
          (event['outcome'] is Map &&
              (event['outcome'] as Map)['type'] == 'interrupt');
      if (interrupted && !_interruptManager.isRunAnswered(effectiveRun ?? '')) {
        final effectiveThread = _str(event['threadId']).isEmpty
            ? _threadId
            : _str(event['threadId']);
        _resumeState = ChatResumeState(
          threadId: effectiveThread ?? '',
          runId: effectiveRun ?? '',
        );
        _runId = effectiveRun;
        _interruptManager.hydrate(
          ChatHydrationInterrupts(
            runId: effectiveRun ?? '',
            threadId: _resumeState?.threadId ?? _threadId ?? '',
            pending: interrupts,
          ),
          source: 'live',
        );
        for (final descriptor in interrupts) {
          final metadata = descriptor['metadata'];
          if (metadata is! Map || metadata['kind'] != 'client_tool') continue;
          final callId = descriptor['toolCallId'];
          for (final turn in messages) {
            for (final part in turn.parts) {
              if (part.type == 'tool-call' &&
                  part.id == callId &&
                  metadata.containsKey('input')) {
                part.input = metadata['input'];
              }
            }
          }
        }
      } else {
        if (!interrupted && effectiveRun != null) {
          _interruptManager.trackRunSettled(effectiveRun);
        }
        if (_resumeState != null &&
            _interruptManager.isRunAnswered(_resumeState!.runId)) {
          _resumeState = null;
          _resumeWasResume = false;
        }
        if (_runId == effectiveRun && _resumeState == null) {
          _runId = _activeRunIds.isEmpty ? null : _activeRunIds.last;
          _options.onRunIdChange?.call(_runId);
        }
      }
    } else if (type == 'RUN_ERROR') {
      final runId = _str(event['runId']);
      final local =
          runId.isEmpty || runId == _runId || _activeRunIds.contains(runId);
      if (!local) return;
      _lastTerminalEvent = event;
      _processorErrored = true;
      error = _str(event['message']).isEmpty
          ? 'The assistant run failed.'
          : _str(event['message']);
      if (runId.isNotEmpty && _activeInterruptSubmission == null) {
        _interruptManager.trackRunSettled(runId);
      }
      if (_resumeState != null &&
          _interruptManager.isRunAnswered(_resumeState!.runId)) {
        _resumeState = null;
        _resumeWasResume = false;
      }
      if (runId.isEmpty) {
        _activeRunIds.clear();
      } else {
        _activeRunIds.remove(runId);
        _clearedTracker.onRunSettled(runId);
      }
    }

    _syncSubagents();
    _emitDevtoolsChunk(event, _currentTurn(fallback));
    _maybeExecuteTools(
      _currentTurn(fallback),
      canRun: type == 'TOOL_CALL_END' ||
          type == 'TOOL_CALL_RESULT' ||
          type == 'RUN_FINISHED' ||
          type == 'CUSTOM',
    );
    _options.onChunk?.call(event);
    _notify();
  }

  bool _rebuildsMessage(Map<String, dynamic> event) => const {
        'TEXT_MESSAGE_START',
        'TEXT_MESSAGE_CONTENT',
        'TEXT_MESSAGE_CHUNK',
        'REASONING_MESSAGE_START',
        'REASONING_MESSAGE_CONTENT',
        'REASONING_MESSAGE_CHUNK',
        'THINKING_TEXT_MESSAGE_START',
        'THINKING_TEXT_MESSAGE_CONTENT',
        'TOOL_CALL_START',
        'TOOL_CALL_ARGS',
        'TOOL_CALL_CHUNK',
        'SUBAGENT_STARTED',
        'ACTIVITY_SNAPSHOT',
      }.contains(event['type']);

  Future<void> _joinRun(String runId) async {
    final join = connection?.joinRun;
    if (join == null || _disposed) return;
    final token = ++_generation;
    _processor = proc.StreamProcessor(
      proc.StreamProcessorOptions(
        events: proc.StreamProcessorEvents(
            onStructuredOutputChange: _emitStructuredOutput),
        initialMessages: assistantWireTurns(messages, includeActivity: true)
            .where((message) => (message['parts'] as List).isNotEmpty)
            .toList(),
      ),
    );
    _processorErrored = false;
    _runId = runId;
    _activeRunIds.add(runId);
    status = ChatClientStatus.streaming;
    _subscribed = true;
    _devtoolsRunId = runId;
    _devtoolsStreamId = generateIdentity('stream');
    _devtools.bridge
      ..setCurrentStreamId(_devtoolsStreamId)
      ..beginRun(runId, _threadId ?? '');
    _devtools.bridge.emitRunLifecycle(
      AIDevtoolsRunEventType.started,
      runId,
      AIDevtoolsRunStatus.started,
    );
    final cancellation = CancellationController();
    _cancellation = cancellation;
    final fallback = AssistantTurn.assistant(createdAt: DateTime.now());
    _notify();
    _tailingRun = true;
    var attached = false;
    _rejoinConnectTimer?.cancel();
    _rejoinConnectTimer = Timer(const Duration(seconds: 2), () {
      if (!attached && token == _generation && !_disposed) {
        unawaited(_cancelActive(clearQueue: false, keepResume: true));
      }
    });
    var replayStarted = false;
    final hydratedTailId =
        messages.isNotEmpty && messages.last.role == 'assistant'
            ? messages.last.id
            : null;
    try {
      _subscription = join(runId, signal: cancellation.signal).listen(
        (event) {
          if (token != _generation || _disposed) return;
          attached = true;
          _rejoinConnectTimer?.cancel();
          if (!_acceptChunk(event)) return;
          if (!replayStarted && _rebuildsMessage(event)) {
            replayStarted = true;
            if (hydratedTailId != null) {
              messages.removeWhere((message) => message.id == hydratedTailId);
              _processor?.setMessages(
                  assistantWireTurns(messages, includeActivity: true));
            }
          }
          _handleConnectionEvent(event, fallback);
        },
        onError: (Object e, StackTrace _) {
          if (token != _generation || _disposed) return;
          _subscription = null;
          _tailingRun = false;
          _rejoinConnectTimer?.cancel();
          if (!attached && !_detached) {
            _resumeState = null;
            _runId = null;
            _activeRunIds.remove(runId);
            _interruptManager.reset();
          }
          _finish(
            _currentTurn(fallback),
            error: attached ? e.toString() : null,
            status: attached ? ChatClientStatus.error : ChatClientStatus.idle,
          );
        },
        onDone: () {
          if (token != _generation || _disposed) return;
          _subscription = null;
          _tailingRun = false;
          _rejoinConnectTimer?.cancel();
          _processor?.finalizeStream();
          _syncProcessorMessages();
          _finish(
            _currentTurn(fallback),
            error: _processorErrored
                ? (error ?? 'The assistant run failed.')
                : null,
            status: _processorErrored
                ? ChatClientStatus.error
                : ChatClientStatus.idle,
          );
        },
        cancelOnError: true,
      );
    } catch (e) {
      _tailingRun = false;
      _rejoinConnectTimer?.cancel();
      if (!attached && !_detached) {
        _resumeState = null;
        _runId = null;
        _activeRunIds.remove(runId);
        _interruptManager.reset();
      }
      _finish(fallback,
          error: attached ? e.toString() : null,
          status: attached ? ChatClientStatus.error : ChatClientStatus.idle);
    }
  }

  void _handleEvent(Map<String, dynamic> event, AssistantTurn turn) {
    final type = '${event['type'] ?? ''}';
    final reducer = _reducer;
    if (reducer == null) return;
    _devtools.bridge.observeChunk(event);

    if (type == 'RUN_STARTED') {
      final id = _str(event['runId']);
      if (id.isNotEmpty) {
        final previous = _runId;
        if (previous != null && previous != id) {
          _activeRunIds.remove(previous);
        }
        _runId = id;
        _activeRunIds.add(id);
        _clearedTracker.onRunStarted(id);
      }
    }

    reducer.apply(event);
    if (type == 'RUN_FINISHED') {
      if (event['finishReason'] == null && reducer.finishReason != null) {
        event['finishReason'] = reducer.finishReason;
      }
      if (event['model'] == null && reducer.model != null) {
        event['model'] = reducer.model;
      }
      _lastTerminalEvent = event;
    } else if (type == 'RUN_ERROR') {
      _lastTerminalEvent = event;
    }
    final snapshot = reducer.snapshotMessages;
    if (snapshot != null) {
      _applySnapshot(snapshot);
      reducer.snapshotMessages = null;
    }

    if (type == 'CUSTOM') {
      final name = _str(event['name']);
      if (!const <String>{
        'approval-requested',
        'tool-approval-requested',
        'tool-input-available',
        'structured-output.start',
        'structured-output.delta',
        'structured-output.chunk',
        'structured-output.complete',
        'structured-output.error',
      }.contains(name)) {
        _onCustomEvent?.call(event, _context);
      }
    }

    if (type == 'RUN_FINISHED') {
      final runId = _str(event['runId']);
      final effectiveRun = runId.isEmpty ? _runId : runId;
      if (effectiveRun != null) {
        _activeRunIds.remove(effectiveRun);
        _clearedTracker.onRunSettled(effectiveRun);
      }
      if (reducer.interrupted) {
        final effectiveThread = _str(event['threadId']).isEmpty
            ? _threadId
            : _str(event['threadId']);
        _resumeState = ChatResumeState(
          threadId: effectiveThread ?? '',
          runId: effectiveRun ?? '',
        );
        _runId = effectiveRun;
        _interruptManager.hydrate(
          ChatHydrationInterrupts(
            runId: effectiveRun ?? '',
            threadId: _resumeState?.threadId ?? _threadId ?? '',
            pending: reducer.interrupts,
          ),
          source: 'live',
        );
      } else if (_resumeWasResume ||
          (_resumeState != null && _resumeState!.runId == effectiveRun)) {
        _resumeState = null;
        _resumeWasResume = false;
        _interruptManager.reset();
        _runId = null;
        _options.onRunIdChange?.call(null);
      } else {
        _runId = null;
        _options.onRunIdChange?.call(null);
      }
    } else if (type == 'RUN_ERROR') {
      final runId = _str(event['runId']);
      if (runId.isEmpty) {
        _activeRunIds.clear();
      } else {
        _activeRunIds.remove(runId);
        _clearedTracker.onRunSettled(runId);
      }
    }

    if (_stoppedSubagentIds.isNotEmpty) {
      for (final id in _stoppedSubagentIds) {
        for (final part in turn.parts) {
          final subagent = part.subagent;
          if (part.type == 'subagent' && subagent?['id'] == id) {
            subagent!['status'] = 'error';
            subagent['error'] = <String, dynamic>{'message': 'Stopped'};
          }
        }
      }
    }

    _syncSubagents();
    _emitDevtoolsChunk(event, turn);
    _maybeExecuteTools(
      turn,
      canRun: type == 'TOOL_CALL_END' ||
          type == 'TOOL_CALL_RESULT' ||
          type == 'CUSTOM',
    );
    _options.onChunk?.call(event);
    _notify();
  }

  void _emitStructuredOutput(Map<String, dynamic> update) {
    final phase = update['phase'];
    final name = switch (phase) {
      'start' => 'structured-output:started',
      'complete' => 'structured-output:completed',
      'error' => 'structured-output:errored',
      _ => 'structured-output:updated',
    };
    _devtools.bridge.events.structuredOutputChanged(
        name,
        _devtools.bridge.resolveStreamId(),
        _str(update['messageId']),
        ChatClientStructuredOutputEvent(
            status: _str(update['status']),
            raw: update['raw'] as String?,
            partial: update['partial'],
            data: update['data'],
            reasoning: update['reasoning'] as String?,
            errorMessage: update['errorMessage'] as String?,
            delta: update['delta'] as String?));
  }

  void _emitDevtoolsChunk(
    Map<String, dynamic> event,
    AssistantTurn turn,
  ) {
    final type = _str(event['type']);
    final events = _devtools.bridge.events;
    final streamId = _devtoolsStreamId;
    final messageId =
        _str(event['messageId']).isEmpty ? turn.id : _str(event['messageId']);
    final runContext = _devtools.bridge.getCurrentRunEventContext();

    if (type == 'TEXT_MESSAGE_CONTENT' || type == 'TEXT_MESSAGE_CHUNK') {
      final content = _lastPartContent(turn, 'text');
      if (streamId != null && content != null) {
        events.textUpdated(streamId, messageId, content);
      }
      return;
    }
    if (type == 'THINKING_TEXT_MESSAGE_CONTENT' ||
        type == 'THINKING_TEXT_MESSAGE_CHUNK' ||
        type == 'REASONING_MESSAGE_CONTENT' ||
        type == 'REASONING_MESSAGE_CHUNK') {
      final content = _lastPartContent(turn, 'thinking');
      if (streamId != null && content != null) {
        events.thinkingUpdated(streamId, messageId, content);
      }
      return;
    }
    if (type == 'TOOL_CALL_START' ||
        type == 'TOOL_CALL_ARGS' ||
        type == 'TOOL_CALL_CHUNK' ||
        type == 'TOOL_CALL_END') {
      final toolCallId = _str(event['toolCallId']);
      final part = _findDevtoolsPart(turn, toolCallId);
      if (streamId != null && part != null) {
        events.toolCallStateChanged(
          streamId,
          messageId,
          part.id,
          part.name.isEmpty ? 'unknown' : part.name,
          part.state,
          part.arguments,
          runContext,
        );
      }
      return;
    }
    if (type != 'CUSTOM') return;

    final name = _str(event['name']);
    final value = event['value'] is Map
        ? Map<String, dynamic>.from(event['value'] as Map)
        : const <String, dynamic>{};
    if (name == 'approval-requested' || name == 'tool-approval-requested') {
      final toolCallId = _str(value['toolCallId']);
      final part = _findDevtoolsPart(turn, toolCallId);
      final approval = value['approval'] is Map
          ? Map<String, dynamic>.from(value['approval'] as Map)
          : const <String, dynamic>{};
      final approvalId = _str(approval['id']);
      if (streamId != null && toolCallId.isNotEmpty && approvalId.isNotEmpty) {
        events.approvalRequested(
          streamId,
          messageId,
          toolCallId,
          _str(value['toolName']).isEmpty
              ? (part?.name ?? 'unknown')
              : _str(value['toolName']),
          value['input'] ?? part?.input,
          approvalId,
        );
      }
      return;
    }
    if (name.startsWith('structured-output.')) {
      if (_processor != null) return;
      final phase = name.substring('structured-output.'.length);
      final eventName = switch (phase) {
        'start' => 'structured-output:started',
        'complete' => 'structured-output:completed',
        'error' => 'structured-output:errored',
        _ => 'structured-output:updated',
      };
      final errorMessage = _str(value['message'] ?? value['errorMessage']);
      if (streamId != null) {
        events.structuredOutputChanged(
          eventName,
          streamId,
          _str(value['messageId']).isEmpty
              ? messageId
              : _str(value['messageId']),
          ChatClientStructuredOutputEvent(
            status: phase,
            raw: _str(value['raw']).isEmpty ? null : _str(value['raw']),
            partial: value['partial'],
            data: value['object'] ?? value['data'],
            reasoning: value['reasoning'] is String
                ? value['reasoning'] as String
                : null,
            errorMessage: errorMessage.isEmpty ? null : errorMessage,
            delta: _str(value['delta']).isEmpty ? null : _str(value['delta']),
          ),
        );
      }
      return;
    }
    if (name == 'memory:state') {
      _devtools.bridge.recordMemoryState(value);
    } else if (name == 'compaction:started' ||
        name == 'compaction:state' ||
        name == 'compaction:ended') {
      _devtools.bridge.recordCompactionEvent(name, value);
    } else if (name == 'skills:state') {
      _devtools.bridge.recordSkillsState(value);
    }
  }

  static String? _lastPartContent(AssistantTurn turn, String type) {
    for (final part in turn.parts.reversed) {
      if (part.type == type) return part.content;
    }
    return null;
  }

  static AssistantPart? _findDevtoolsPart(
    AssistantTurn turn,
    String toolCallId,
  ) {
    for (final part in turn.parts) {
      if (part.type == 'tool-call' && part.id == toolCallId) return part;
    }
    return null;
  }

  void _applySnapshot(List<Map<String, dynamic>> snapshot) {
    final restored = assistantTurnsFromProcessor(snapshot);
    if (restored.isEmpty && snapshot.isNotEmpty) return;
    messages
      ..clear()
      ..addAll(restored);
    _notify();
  }

  void _syncSubagents() {
    final present = <String>{};
    final visited = HashSet<Map<String, dynamic>>.identity();
    SubagentHandle bind(Map<String, dynamic> raw) {
      final data = raw is SubagentHandle ? raw.data : raw;
      final id = _str(data['id']);
      present.add(id);
      final handle = _subagentHandles.putIfAbsent(
          id, () => SubagentHandle(data, stop: () => stopSubagent(id)));
      handle.data = data;
      if (!visited.add(data)) return handle;
      if (_stoppedSubagentIds.contains(id)) {
        data['status'] = 'error';
        data['error'] = <String, dynamic>{'message': 'Stopped'};
      }
      final children = data['messages'];
      if (children is List) {
        for (final message in children.whereType<Map>()) {
          final parts = message['parts'];
          if (parts is! List) continue;
          for (final part in parts.whereType<Map>()) {
            final child = part['subagent'];
            if (part['type'] == 'subagent' && child is Map<String, dynamic>) {
              part['subagent'] = bind(child);
            }
          }
        }
      }
      return handle;
    }

    for (final turn in messages) {
      for (final part in turn.parts) {
        if (part.type == 'subagent' && part.subagent != null) {
          part.subagent = bind(part.subagent!);
        }
      }
    }
    _subagentHandles.removeWhere((id, _) => !present.contains(id));
  }

  void stopSubagent(String id) {
    final handle = _subagentHandles[id];
    if (handle == null || handle.status != 'running') return;
    _stoppedSubagentIds.add(id);
    handle.data['status'] = 'error';
    handle.data['error'] = <String, dynamic>{'message': 'Stopped'};
    _cancellation?.cancel();
    _notify();
  }

  final Set<String> _startedTools = <String>{};
  final Map<String, int> _executingTools = <String, int>{};
  bool get _hasExecutingTools =>
      _executingTools.values.any((generation) => generation == _generation);

  void _maybeExecuteTools(AssistantTurn turn, {required bool canRun}) {
    if (!canRun) return;
    final tools = _options.tools;
    if (tools == null || tools.isEmpty) return;
    for (final part in turn.parts) {
      if (part.type != 'tool-call') continue;
      if (part.hasOutput || part.output != null) continue;
      if (part.state == 'error' ||
          part.state == 'approval-requested' ||
          part.state == 'approval-responded') {
        continue;
      }
      if (part.input == null && part.arguments.trim().isEmpty) continue;
      if (part.approval != null) continue;
      if (_startedTools.contains(part.id)) {
        if (_executingTools[part.id] == _generation && !part.hasOutput) {
          part.state = 'executing';
        }
        continue;
      }
      final tool = _toolNamed(part.name);
      if (tool == null || tool.needsApproval || !tool.hasExecute) continue;
      if (part.input == null && part.arguments.trim().isNotEmpty) {
        try {
          part.input = jsonDecode(part.arguments);
        } catch (_) {
          // The server may send an opaque argument string.
        }
      }
      _startedTools.add(part.id);
      _executingTools[part.id] = _generation;
      part.state = 'executing';
      unawaited(_executeTool(tool, part));
    }
  }

  Future<void> _executeTool(ClientTool tool, AssistantPart part) async {
    final generation = _generation;
    final signal = _cancellation?.signal;
    final context = _context;
    final devtoolsContext = _devtools.bridge.findToolCallContext(part.id);
    bool stale() =>
        generation != _generation || _disposed || (signal?.isAborted ?? false);
    try {
      final validatedInput =
          await validateWithSchema(tool.inputSchema, part.input);
      if (!validatedInput.success) {
        throw StateError(
            validatedInput.issues.map((issue) => issue.message).join('; '));
      }
      if (stale()) return;
      final toolContext =
          ToolCallContext(abortSignal: signal, context: context);
      var output = await Future.sync(
          () => tool.invoke(validatedInput.data, toolContext));
      final validatedOutput = tool.outputSchema == null
          ? SchemaValidationResult.success(output)
          : await validateWithSchema(tool.outputSchema, output);
      if (!validatedOutput.success) {
        throw StateError(
            validatedOutput.issues.map((issue) => issue.message).join('; '));
      }
      output = validatedOutput.data;
      final validator = tool is ChatClientTool ? tool.validateOutput : null;
      if (validator != null) {
        await Future.sync(() => validator(output));
      }
      if (!_disposed) {
        _devtools.bridge.events.toolResultAdded(
          part.id,
          part.name,
          output,
          'output-available',
          devtoolsContext,
        );
      }
      if (stale()) return;
      part.output = output;
      part.hasOutput = true;
      part.state = 'complete';

      _processor?.addToolResult(part.id, output);
      if (_processor != null) _syncProcessorMessages();
      if (_interruptManager.resolveClientToolOutput(part.id, output)) {
        if (_interruptManager.isComplete) {
          _pendingToolContinuation = true;
        }
      } else {
        _pendingToolContinuation = true;
      }
    } catch (e) {
      final message =
          e is StateError && '$e'.isEmpty ? 'Tool execution failed' : '$e';
      if (!_disposed) {
        _devtools.bridge.events.toolResultAdded(
          part.id,
          part.name,
          message,
          'output-error',
          devtoolsContext,
        );
      }
      if (stale()) return;
      part.output = message;
      part.hasOutput = true;
      part.state = 'error';

      _processor?.addToolResult(part.id, message, error: message);
      if (_processor != null) _syncProcessorMessages();
      if (!_interruptManager.resolveClientToolError(part.id, message)) {
        _pendingToolContinuation = true;
      }
    } finally {
      if (_executingTools[part.id] == generation) {
        _executingTools.remove(part.id);
      }
      _notify();
      if (!stale() &&
          !_hasExecutingTools &&
          !isStreaming &&
          _pendingToolContinuation &&
          _shouldAutoSend()) {
        _pendingToolContinuation = false;
        final assistant = AssistantTurn.assistant(createdAt: DateTime.now());
        messages.add(assistant);
        unawaited(_start(assistant));
      }
    }
  }

  ClientTool? _toolNamed(String name) {
    for (final tool in _options.tools ?? const <ClientTool>[]) {
      if (tool.name == name) return tool;
    }
    return null;
  }

  bool _shouldAutoSend() {
    if (_resumeState != null) return false;
    if (_interruptManager.getInterrupts().isNotEmpty) return false;
    final lastAssistant = messages.lastWhere((turn) => turn.role == 'assistant',
        orElse: () => AssistantTurn(id: '', role: 'assistant'));
    if (lastAssistant.id.isEmpty) return false;
    final tools = lastAssistant.parts.where((p) => p.type == 'tool-call');
    if (tools.isEmpty) return false;
    return tools.every(
      (p) =>
          p.state == 'complete' ||
          p.state == 'error' ||
          p.state == 'approval-responded',
    );
  }

  void _finish(
    AssistantTurn turn, {
    required String? error,
    required ChatClientStatus status,
  }) {
    final completion = _runCompletion;
    _runCompletion = null;
    final finishedGeneration = _generation;
    final finishedRunId = _runId;
    final devtoolsRunId = _devtoolsRunId ?? finishedRunId;
    if (devtoolsRunId != null && devtoolsRunId.isNotEmpty) {
      final failed = error != null || status == ChatClientStatus.error;
      _devtools.bridge.emitRunLifecycle(
        failed
            ? AIDevtoolsRunEventType.errored
            : AIDevtoolsRunEventType.completed,
        devtoolsRunId,
        failed ? AIDevtoolsRunStatus.errored : AIDevtoolsRunStatus.completed,
        error: failed ? (error ?? this.error) : null,
      );
    }
    _devtoolsRunId = null;
    _devtoolsStreamId = null;
    _devtools.bridge.setCurrentStreamId(null);
    if (error != null) {
      interruptApprovedTools(turn);
      _flushQueue();
    }
    turn.streaming = false;
    _streamingTurn = null;
    _reducer = null;
    _pendingMessageBody = null;
    this.error = error;
    this.status = status;
    if (status == ChatClientStatus.idle) {
      _runId = null;
      _options.onRunIdChange?.call(null);
    }
    _options.onLoadingChange?.call(false);
    if (error == null) {
      _options.onFinish?.call(
        _lastTerminalEvent ??
            <String, dynamic>{
              'type': 'RUN_FINISHED',
              if (finishedRunId != null) 'runId': finishedRunId,
            },
      );
      _lastTerminalEvent = null;
    } else {
      _options.onError?.call(error, null);
    }
    _notify();

    if (finishedGeneration != _generation) {
      _settleRun(completion);
      return;
    }

    if (status == ChatClientStatus.idle) {
      final pendingResume = _pendingResumeItems;
      if (pendingResume != null) {
        _pendingResumeItems = null;
        final pendingCompletion = _pendingResumeCompletion;
        _pendingResumeCompletion = null;
        final continuation = _resumeFromManager(items: pendingResume);
        _settleRun(pendingCompletion, continuation);
        _settleRun(completion, continuation);
        return;
      }
      if (_pendingToolContinuation &&
          !_hasExecutingTools &&
          _shouldAutoSend()) {
        _pendingToolContinuation = false;
        final assistant = AssistantTurn.assistant(createdAt: DateTime.now());
        messages.add(assistant);
        _settleRun(completion, _start(assistant));
        return;
      }
      _pendingToolContinuation = false;
      _settleRun(completion);
      if (!_stopQueueDrain) {
        // Release the completed send's delivery claim before draining its queue.
        Timer.run(() => unawaited(_drainQueue()));
      }
      _stopQueueDrain = false;
    } else {
      _flushQueue();
      _settleRun(completion);
    }
  }

  void _settleRun(Completer<void>? completion, [Future<void>? continuation]) {
    void complete() {
      if (completion != null && !completion.isCompleted) completion.complete();
    }

    if (continuation == null) {
      complete();
    } else {
      unawaited(continuation.then((_) => complete(),
          onError: (Object error, StackTrace stack) {
        if (completion != null && !completion.isCompleted) {
          completion.completeError(error, stack);
        }
      }));
    }
  }

  Future<void> _drainQueue() async {
    if (_queueDraining || isStreaming || _queue.isEmpty) return;
    final claim = ++_drainClaim;
    _queueDraining = true;
    _stopQueueDrain = false;
    try {
      if (_queueConfig.drain == QueueDrainMode.batch) {
        while (_queue.isNotEmpty) {
          if (isStreaming || _stopQueueDrain) return;
          final items = List<QueuedMessage>.from(_queue);
          _queue.clear();
          _emitQueueChange();
          final merged = _mergeQueued(items);
          final mergedBody = <String, dynamic>{
            for (final item in items) ...?item.body
          };
          final ok = await _deliverAndWait(merged, mergedBody);
          if (!ok || isStreaming || _stopQueueDrain) return;
        }
        return;
      }
      while (_queue.isNotEmpty) {
        if (isStreaming || _stopQueueDrain) return;
        final next = _queue.removeAt(0);
        _emitQueueChange();
        final ok = await _deliverAndWait(next.content, next.body);
        if (!ok || isStreaming || _stopQueueDrain) return;
      }
    } finally {
      if (claim == _drainClaim) {
        _queueDraining = false;
        _stopQueueDrain = false;
        _notify();
      }
    }
  }

  Future<bool> _deliverAndWait(dynamic content,
      [Map<String, dynamic>? body]) async {
    final normalized = _normalizeInput(content);
    if (normalized == null) return false;
    final claim = ++_sendClaim;
    _sendInFlight = true;
    try {
      await _deliverMessage(normalized, body ?? const <String, dynamic>{});
      // Wait until the stream settles so FIFO/batch ordering is preserved.
      while (isStreaming && claim == _sendClaim) {
        await Future<void>.delayed(Duration.zero);
      }
      return claim == _sendClaim && status != ChatClientStatus.error;
    } finally {
      if (claim == _sendClaim) _sendInFlight = false;
    }
  }

  dynamic _mergeQueued(List<QueuedMessage> items) {
    if (items.length == 1) return items.single.content;
    if (items.every((item) => item.content is String)) {
      return items.map((item) => item.content as String).join('\n');
    }
    final parts = <Map<String, dynamic>>[];
    final mergedMetadata = <String, dynamic>{};
    var hasMetadata = false;
    for (final item in items) {
      final content = item.content;
      if (content is String) {
        parts.add(<String, dynamic>{'type': 'text', 'content': content});
      } else if (content is ChatMessageInput) {
        final metadata = content.metadata;
        if (metadata != null) {
          mergedMetadata.addAll(metadata);
          hasMetadata = true;
        }
        final inner = content.content;
        if (inner is String) {
          parts.add(<String, dynamic>{'type': 'text', 'content': inner});
        } else if (inner is List) {
          for (final part in inner) {
            if (part is Map) parts.add(Map<String, dynamic>.from(part));
          }
        }
      }
    }
    return ChatMessageInput(
      content: parts,
      metadata: hasMetadata ? mergedMetadata : null,
    );
  }

  Future<void> _cancelActive({
    required bool clearQueue,
    required bool keepResume,
  }) async {
    _tailingRun = false;
    _rejoinConnectTimer?.cancel();
    _rejoinConnectTimer = null;
    _generation += 1;
    _deliveryClaim++;
    _sendClaim++;
    _drainClaim++;
    _delivering = false;
    _sendInFlight = false;
    _queueDraining = false;
    if (!keepResume) {
      _activeInterruptSubmission = null;
      _interruptSubmissionFailure = null;
      _pendingResumeItems = null;
      _settleRun(_pendingResumeCompletion);
      _pendingResumeCompletion = null;
    }
    final devtoolsRunId = _devtoolsRunId;
    if (devtoolsRunId != null && devtoolsRunId.isNotEmpty) {
      _devtools.bridge.emitRunLifecycle(
        AIDevtoolsRunEventType.cancelled,
        devtoolsRunId,
        AIDevtoolsRunStatus.cancelled,
      );
    }
    _devtoolsRunId = null;
    _devtoolsStreamId = null;
    _devtools.bridge.setCurrentStreamId(null);
    final cancellation = _cancellation;
    _cancellation = null;
    cancellation?.cancel();
    final completion = _runCompletion;
    _runCompletion = null;
    final current = _subscription;
    _subscription = null;
    _processor = null;
    final active = _streamingTurn;
    if (active != null) interruptApprovedTools(active);
    active?.streaming = false;
    _streamingTurn = null;
    _reducer = null;
    status = ChatClientStatus.idle;
    _pendingMessageBody = null;
    _options.onLoadingChange?.call(false);
    if (clearQueue) {
      _flushQueue();
    }
    if (!keepResume) {
      _resumeState = null;
      _runId = null;
      _interruptManager.reset();
    }
    _notify();
    _settleRun(completion);
    try {
      final cleanup = current?.cancel();
      if (cleanup != null) {
        await Future.any<void>([
          cleanup.catchError((Object _) {}),
          Future<void>.delayed(Duration.zero),
        ]);
      }
    } catch (_) {
      // A custom stream's cleanup must not keep the conversation busy.
    }
  }

  void _flushQueue() {
    if (_queue.isEmpty) return;
    _queue.clear();
    _emitQueueChange();
  }

  bool _hasWireContent(AssistantTurn turn) {
    if (turn.role == 'user') {
      return turn.parts
          .any((part) => part.type != 'text' || part.content.isNotEmpty);
    }
    return turn.parts.any(
      (part) =>
          (part.type == 'text' && part.content.isNotEmpty) ||
          part.type == 'tool-call' ||
          part.type == 'tool-result' ||
          part.type == 'image' ||
          part.type == 'audio' ||
          part.type == 'video' ||
          part.type == 'document',
    );
  }

  void _rememberServerIds(Iterable<AssistantTurn> turns) {
    for (final turn in turns) {
      _knownServerMessageIds.add(turn.id);
    }
  }

  _NormalizedInput? _normalizeInput(dynamic content) {
    if (content is String) {
      final trimmed = content.trim();
      if (trimmed.isEmpty) return null;
      return _NormalizedInput(
        parts: <AssistantPart>[AssistantPart.text(trimmed)],
      );
    }
    if (content is ChatMessageInput) {
      final inner = content.content;
      if (inner is String) {
        final trimmed = inner.trim();
        if (trimmed.isEmpty) return null;
        return _NormalizedInput(
          id: content.id,
          metadata: content.metadata,
          parts: <AssistantPart>[AssistantPart.text(trimmed)],
        );
      }
      if (inner is List) {
        if (inner.isEmpty) {
          return _NormalizedInput(
            id: content.id,
            metadata: content.metadata,
            parts: <AssistantPart>[],
          );
        }
        return _NormalizedInput(
          id: content.id,
          metadata: content.metadata,
          parts: [
            for (final raw in inner)
              if (raw is Map) AssistantPart.fromJson(raw),
          ],
        );
      }
    }
    if (content is Map) {
      return _normalizeInput(
        ChatMessageInput(
          content: content['content'],
          id: content['id'] is String ? content['id'] as String : null,
          metadata: content['metadata'] is Map
              ? Map<String, dynamic>.from(content['metadata'] as Map)
              : null,
        ),
      );
    }
    return null;
  }

  AssistantTurn? _turnForPart(AssistantPart part) {
    for (final turn in messages) {
      if (turn.parts.contains(part)) return turn;
    }
    return null;
  }

  String _newMessageId(String role) => generateIdentity(role);

  ChatSnapshot _buildSnapshot() {
    final nextCache = <String, AssistantTurn>{};
    final nextMessages = <AssistantTurn>[];
    for (final turn in messages) {
      final key = '${turn.id}\u0000${_turnFingerprint(turn)}';
      final cached = _snapshotTurnCache[key];
      final copy = cached ?? freezeAssistantTurn(turn);
      nextCache[key] = copy;
      nextMessages.add(copy);
    }
    _snapshotTurnCache = nextCache;
    return ChatSnapshot(
      messages: List<AssistantTurn>.unmodifiable(nextMessages),
      queue: List<QueuedMessage>.unmodifiable([
        for (final item in getQueue())
          QueuedMessage(
              id: item.id,
              content: freezeSnapshotValue(item.content),
              createdAt: item.createdAt,
              body: freezeSnapshotValue(item.body))
      ]),
      isSubscribed: _subscribed,
      connectionStatus: _connectionStatus,
      runId: _runId,
      interruptState: _interruptManager.getState(),
      status: state.name,
      isLoading: isLoading,
      isStreaming: isStreaming,
      isHydrating: _isHydrating,
      sessionGenerating: getSessionGenerating(),
      hasOlderMessages: hasOlderMessages,
      error: error,
    );
  }

  String _turnFingerprint(AssistantTurn turn) {
    try {
      return jsonEncode(<String, dynamic>{
        'id': turn.id,
        'role': turn.role,
        'streaming': turn.streaming,
        'createdAt': turn.createdAt?.toIso8601String(),
        'name': turn.name,
        'metadata': turn.metadata,
        'parts': [for (final part in turn.parts) part.toJson()],
      },
          toEncodable: (value) => value is DateTime
              ? value.toIso8601String()
              : {'opaqueIdentity': identityHashCode(value)});
    } catch (_) {
      return '${identityHashCode(turn)}-${turn.parts.length}';
    }
  }

  static AssistantTurn _cloneTurn(AssistantTurn turn) =>
      copyAssistantTurn(turn);

  String messagesFingerprint() => messages.map(_turnFingerprint).join('\u0000');

  void _notify() {
    _snapshot = null;
    if (!_constructed) return;
    if (_subscribed != _lastSubscribed) {
      _lastSubscribed = _subscribed;
      try {
        _onSubscriptionChange?.call(_subscribed);
      } catch (_) {}
    }
    if (_connectionStatus != _lastConnectionStatus) {
      _lastConnectionStatus = _connectionStatus;
      try {
        _onConnectionStatusChange?.call(_connectionStatus);
      } catch (_) {}
    }
    final generating = getSessionGenerating();
    if (generating != _lastSessionGenerating) {
      _lastSessionGenerating = generating;
      try {
        _options.onSessionGeneratingChange?.call(generating);
      } catch (_) {}
    }
    final nextStatus = state.name;
    if (nextStatus != _lastNotifiedStatus) {
      _lastNotifiedStatus = nextStatus;
      try {
        _onStatusChange?.call(nextStatus);
      } catch (_) {}
    }
    final transcript = messagesFingerprint();
    if (transcript != _lastNotifiedTranscript) {
      _lastNotifiedTranscript = transcript;
      if (!_disposed) {
        _persistor?.notifyMessagesChanged(
            assistantWireTurns(messages, includeActivity: true));
      }
      try {
        _options.onMessagesChange?.call(getSnapshot().messages);
      } catch (_) {}
    }
    final resume = getResumeSnapshot();
    final resumeFingerprint = resume == null
        ? ''
        : jsonEncode(resume.toJson(),
            toEncodable: (value) =>
                value is DateTime ? value.toIso8601String() : '$value');
    if (!_disposed &&
        !(_clearingStorage && messages.isEmpty) &&
        resumeFingerprint != _lastPersistedResume) {
      _lastPersistedResume = resumeFingerprint;
      _persistor?.persistResumeSnapshot(resume);
    }
    try {
      onChanged?.call();
    } catch (_) {
      // A throwing listener must not break stream processing.
    }
    for (final listener in List<void Function()>.from(_snapshotListeners)) {
      try {
        listener();
      } catch (_) {
        // Keep notifying the remaining listeners.
      }
    }
    _devtools.emitSnapshot();
  }

  /// Replace the transcript manually (upstream `setMessagesManually`).
  void setMessagesManually(List<AssistantTurn> next) {
    final copied = next.map(copyAssistantTurn).toList();
    messages
      ..clear()
      ..addAll(copied);
    _processor
        ?.setMessages(assistantWireTurns(messages, includeActivity: true));
    _syncSubagents();
    _notify();
  }

  static const Object _unset = Object();

  /// Update wire-payload options without recreating the client.
  ///
  /// Passing an explicit `null` for [context], [body] or [forwardedProps]
  /// clears that slot; omitting the parameter leaves it unchanged.
  void updateOptions({
    Object? context = _unset,
    Object? body = _unset,
    Object? forwardedProps = _unset,
    Object? onResponse = _unset,
    Object? onCustomEvent = _unset,
    Object? byokClient = _unset,
    Object? byokProvider = _unset,
    Object? connection = _unset,
    Object? tools = _unset,
    ChatQueueConfig? queue,
  }) {
    if (!identical(tools, _unset)) {
      final configured =
          tools == null ? <ClientTool>[] : (tools as List).cast<ClientTool>();
      _options = _mergeOptions(_options, tools: configured);
      _interruptManager.updateTools(configured);
      _devtools.notifyToolsChanged();
    }
    if (!identical(connection, _unset)) {
      final next = connection as ConnectionAdapter?;
      if (!identical(this.connection, next)) {
        final subscribed = _subscribed;
        _stopNativeSubscription();
        unawaited(_cancelActive(clearQueue: false, keepResume: true)
            .catchError((Object _) {}));
        _activeRunIds.clear();
        this.connection = _resolveConnection(next, null, transport);
        _connectionTransport =
            next == null ? null : ConnectionChatTransport(next);
        _subscribed = false;
        _connectionStatus = 'idle';
        if (subscribed) subscribe();
      }
    }
    if (!identical(context, _unset)) _context = context;
    if (!identical(onCustomEvent, _unset)) {
      _onCustomEvent =
          onCustomEvent as void Function(Map<String, dynamic>, Object?)?;
    }
    if (!identical(byokClient, _unset)) {
      _byok = byokClient as byok_api.ByokClient?;
    }
    if (!identical(byokProvider, _unset)) {
      _byokProvider = byokProvider as FutureOr<String?> Function()?;
    }
    if (!identical(onResponse, _unset)) {
      final callback = onResponse;
      _onResponse = callback is Function
          ? () async {
              await Future.sync(() => (callback as dynamic)());
            }
          : null;
    }
    if (!identical(body, _unset)) {
      _bodyOption = body is Map ? Map<String, dynamic>.from(body) : null;
    }
    if (!identical(forwardedProps, _unset)) {
      _forwardedProps = forwardedProps is Map
          ? Map<String, dynamic>.from(forwardedProps)
          : null;
    }
    if (queue != null) _queueConfig = queue;
    _notify();
  }

  /// Removes listeners and cancels in-flight work.
  Future<void> dispose() async {
    _disposed = true;
    _subscribed = false;
    _connectionStatus = 'disconnected';
    _stopNativeSubscription();
    await _cancelActive(clearQueue: true, keepResume: false);
    _snapshotListeners.clear();
    _interruptManager.dispose();
    _devtools.dispose();
  }

  static ChatClientOptions _mergeOptions(
    ChatClientOptions? base, {
    void Function(List<AssistantTurn> messages)? onMessagesChange,
    void Function(bool loading)? onLoadingChange,
    void Function(Map<String, dynamic> chunk)? onChunk,
    void Function(Map<String, dynamic> chunk)? onFinish,
    void Function(Object error, Map<String, dynamic>? chunk)? onError,
    void Function(List<QueuedMessage> queue)? onQueueChange,
    void Function(bool generating)? onSessionGeneratingChange,
    void Function(String? runId)? onRunIdChange,
    void Function(ChatInterruptState state, String source)?
        onInterruptStateChange,
    void Function(Map<String, dynamic> event, Object? context)? onCustomEvent,
    List<ClientTool>? tools,
  }) {
    final opts = base ?? const ChatClientOptions();
    return ChatClientOptions(
      connection: opts.connection,
      fetcher: opts.fetcher,
      initialMessages: opts.initialMessages,
      initialResumeSnapshot: opts.initialResumeSnapshot,
      persistenceOptions: opts.persistenceOptions,
      byok: opts.byok,
      byokProvider: opts.byokProvider,
      onResponse: opts.onResponse,
      devtools: opts.devtools,
      devtoolsBridgeFactory: opts.devtoolsBridgeFactory,
      threadId: opts.threadId,
      queue: opts.queue,
      history: opts.history,
      hydrate: opts.hydrate,
      context: opts.context,
      tools: tools ?? opts.tools,
      interrupts: opts.interrupts,
      body: opts.body,
      forwardedProps: opts.forwardedProps,
      initialResume: opts.initialResume,
      initialInterrupts: opts.initialInterrupts,
      persistence: opts.persistence,
      onMessagesChange: onMessagesChange ?? opts.onMessagesChange,
      onLoadingChange: onLoadingChange ?? opts.onLoadingChange,
      onStatusChange: opts.onStatusChange,
      onSubscriptionChange: opts.onSubscriptionChange,
      onConnectionStatusChange: opts.onConnectionStatusChange,
      onChunk: onChunk ?? opts.onChunk,
      onFinish: onFinish ?? opts.onFinish,
      onError: onError ?? opts.onError,
      onQueueChange: onQueueChange ?? opts.onQueueChange,
      onSessionGeneratingChange:
          onSessionGeneratingChange ?? opts.onSessionGeneratingChange,
      onRunIdChange: onRunIdChange ?? opts.onRunIdChange,
      onInterruptStateChange:
          onInterruptStateChange ?? opts.onInterruptStateChange,
      onCustomEvent: onCustomEvent ?? opts.onCustomEvent,
    );
  }

  static String _str(Object? value) => value == null ? '' : '$value';
}

class _QueueDecision {
  final QueueWhenBusy whenBusy;
  final String id;

  const _QueueDecision(this.whenBusy, this.id);
}

class _NormalizedInput {
  final List<AssistantPart> parts;
  final String? id;
  final Map<String, dynamic>? metadata;

  const _NormalizedInput({required this.parts, this.id, this.metadata});
}

/// A live subagent card handle. [data] is the same map exposed on
/// [AssistantPart.subagent].
class SubagentHandle extends MapBase<String, dynamic> {
  Map<String, dynamic> data;
  final void Function() stop;

  SubagentHandle(this.data, {required this.stop});

  @override
  dynamic operator [](Object? key) => data[key];

  @override
  void operator []=(String key, dynamic value) => data[key] = value;

  @override
  void clear() => data.clear();

  @override
  Iterable<String> get keys => data.keys;

  @override
  dynamic remove(Object? key) => data.remove(key);

  String get id => '${data['id'] ?? ''}';
  String get name => '${data['name'] ?? ''}';
  String get status => '${data['status'] ?? 'running'}';
  dynamic get input {
    final metadata = data['metadata'];
    if (metadata is Map) {
      if (metadata['input'] != null) return metadata['input'];
      final tanstack = metadata['tanstack'];
      if (tanstack is Map && tanstack['subagentInput'] != null) {
        return tanstack['subagentInput'];
      }
    }
    return data['input'];
  }

  List<dynamic> get messages =>
      data['messages'] is List ? data['messages'] as List : const <dynamic>[];
  Map<String, dynamic>? get error => data['error'] is Map
      ? Map<String, dynamic>.from(data['error'] as Map)
      : null;
}
