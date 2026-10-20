/// Real devtools bridges for the TanStack AI client 0.40.0 surface.
///
/// Ported from `packages/ai-client/src/devtools.ts`. Everything the upstream
/// bridge reached into — the chat client, generation clients and the browser
/// event client — is injected here through options so the bridges can run in
/// any Dart host.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../platform/events.dart';
import 'devtools_types.dart';

int _devtoolsEventCounter = 0;

String _devtoolsIdPart(Object? value) {
  if (value == null || value == '') return 'missing';
  return 'value-${Uri.encodeComponent('$value')}';
}

/// Mirror of `_createDevtoolsEventEnvelope` for the fields used here.
Map<String, dynamic> _createDevtoolsEventEnvelope({
  String? eventId,
  required String eventType,
  required String source,
  required String visibility,
  required int timestamp,
  String? clientId,
  String? requestId,
  String? streamId,
  String? hookId,
  String? threadId,
  String? runId,
  String? messageId,
  String? toolCallId,
}) {
  final resolvedEventId = (eventId != null && eventId.isNotEmpty)
      ? eventId
      : <String>[
          source,
          eventType,
          if (clientId != null) _devtoolsIdPart(clientId),
          if (requestId != null) _devtoolsIdPart(requestId),
          if (streamId != null) _devtoolsIdPart(streamId),
          if (hookId != null) _devtoolsIdPart(hookId),
          if (threadId != null) _devtoolsIdPart(threadId),
          if (runId != null) _devtoolsIdPart(runId),
          if (messageId != null) _devtoolsIdPart(messageId),
          if (toolCallId != null) _devtoolsIdPart(toolCallId),
          '$timestamp',
          '${_devtoolsEventCounter++}',
        ].join(':');
  return <String, dynamic>{
    'eventId': resolvedEventId,
    'eventType': eventType,
    'source': source,
    'visibility': visibility,
    'timestamp': timestamp,
    if (clientId != null) 'clientId': clientId,
    if (requestId != null) 'requestId': requestId,
    if (streamId != null) 'streamId': streamId,
    if (hookId != null) 'hookId': hookId,
    if (threadId != null) 'threadId': threadId,
    if (runId != null) 'runId': runId,
    if (messageId != null) 'messageId': messageId,
    if (toolCallId != null) 'toolCallId': toolCallId,
  };
}

/// Active bridge per hook id. A newer bridge for the same hook id supersedes
/// the older one, matching upstream duplicate-hook behavior.
final Map<String, ClientDevtoolsBridge<AIDevtoolsSnapshot>>
    _activeBridgeByHookId =
    <String, ClientDevtoolsBridge<AIDevtoolsSnapshot>>{};

class ClientDevtoolsBridge<TSnapshot extends AIDevtoolsSnapshot> {
  final AIDevtoolsBridgeOptions<TSnapshot> options;
  final List<AIDevtoolsUnsubscribe> _unsubscribers = <AIDevtoolsUnsubscribe>[];
  bool _disposed = false;
  bool _superseded = false;
  bool _registered = false;

  ClientDevtoolsBridge(this.options);

  /// Subclasses override this to wire fixture replay without copying options.
  FutureOr<void> Function(AIDevtoolsToolFixture fixture)?
      get toolFixtureHandler => options.applyToolFixture;

  TSnapshot buildSnapshot() {
    final getSnapshot = options.getSnapshot;
    if (getSnapshot == null) {
      throw StateError(
        'AIDevtoolsBridgeOptions.getSnapshot is required for this bridge',
      );
    }
    return getSnapshot();
  }

  void emitRegistered() {
    if (!_prepareForMountEmit()) return;
    _registered = true;
    options.eventClient.emit('hook:registered', <String, dynamic>{
      ..._createEnvelope('hook:registered'),
      ..._createMetadataPayload(),
      'lifecycle': 'mounted',
    });
  }

  void emitUpdated() {
    if (!_prepareForEmit()) return;
    options.eventClient.emit('hook:updated', <String, dynamic>{
      ..._createEnvelope('hook:updated'),
      ..._createMetadataPayload(),
      'lifecycle': 'active',
    });
  }

  void emitSnapshot() {
    if (!_prepareForEmit()) return;
    options.eventClient.emit('hook:state-snapshot', <String, dynamic>{
      ..._createEnvelope('hook:state-snapshot'),
      ..._createMetadataPayload(),
      'state': buildSnapshot().toJson(),
    });
  }

  void emitToolsRegistered() {
    if (!_prepareForEmit()) return;

    final tools = <Map<String, dynamic>>[];
    final readTools = options.getTools;
    if (readTools != null) {
      for (final tool in readTools()) {
        tools.add(<String, dynamic>{
          'name': tool.name,
          'description': tool.description,
          'inputSchema': tool.inputSchema != null
              ? aIDevtoolsSchemaToJson(tool.inputSchema)
              : <String, dynamic>{'type': 'object'},
          if (tool.outputSchema != null)
            'outputSchema': aIDevtoolsSchemaToJson(tool.outputSchema),
          'needsApproval': tool.needsApproval,
          if (tool.metadata != null) 'metadata': tool.metadata,
        });
      }
    }

    options.eventClient.emit('tools:registered', <String, dynamic>{
      ..._createEnvelope('tools:registered'),
      ..._createMetadataPayload(),
      'tools': tools,
    });
  }

  void emitRunLifecycle(
    AIDevtoolsRunEventType eventType,
    String runId,
    AIDevtoolsRunStatus status, {
    String? error,
  }) {
    if (!_prepareForEmit()) return;
    options.eventClient.emit(eventType.wire, <String, dynamic>{
      ..._createEnvelope(eventType.wire, 'client-state', runId),
      'runId': runId,
      'status': status.name,
      if (error != null) 'error': error,
    });
  }

  void deactivate() {
    if (identical(_activeBridgeByHookId[options.liveHookId], this)) {
      _activeBridgeByHookId.remove(options.liveHookId);
    }
    final pending = List<AIDevtoolsUnsubscribe>.of(_unsubscribers);
    _unsubscribers.clear();
    for (final unsubscribe in pending) {
      unsubscribe();
    }
  }

  void supersede() {
    if (_disposed) return;
    _superseded = true;
    _disposed = true;
    deactivate();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;

    if (!_registered) {
      deactivate();
      return;
    }

    final live = _activeBridgeByHookId[options.liveHookId];
    if (!identical(live, this)) {
      deactivate();
      return;
    }

    options.eventClient.emit('hook:unregistered', <String, dynamic>{
      ..._createEnvelope('hook:unregistered'),
      ..._createMetadataPayload(),
      'reason': 'disposed',
    });

    deactivate();
  }

  /// Extension hook for subclasses that cache transported state.
  void onReplayState() {}

  bool _prepareForEmit() {
    if (_disposed || _superseded) return false;
    _activate();
    return true;
  }

  bool _prepareForMountEmit() {
    if (_superseded) return false;
    if (_disposed) {
      _disposed = false;
      _registered = false;
    }
    _activate();
    return true;
  }

  void _activate() {
    if (_disposed) return;

    final active = _activeBridgeByHookId[options.liveHookId];
    if (active != null && !identical(active, this)) {
      active.supersede();
    }
    _activeBridgeByHookId[options.liveHookId] = this;

    if (_unsubscribers.isNotEmpty) return;

    _unsubscribers.add(
      options.eventClient.on('devtools:request-state', _handleRequestState),
    );

    if (toolFixtureHandler != null) {
      _unsubscribers.add(
        options.eventClient.on(
          'devtools:tool-fixture:apply',
          _handleToolFixtureApply,
        ),
      );
    }
  }

  void _handleRequestState(AIDevtoolsEvent event) {
    if (_disposed || _superseded) return;
    final targetHookId = event.payload['targetHookId'];
    if (targetHookId is String &&
        targetHookId.isNotEmpty &&
        targetHookId != options.liveHookId) {
      return;
    }

    emitRegistered();
    emitToolsRegistered();
    emitSnapshot();
    onReplayState();
  }

  Future<void> _handleToolFixtureApply(AIDevtoolsEvent event) async {
    final fixture = AIDevtoolsToolFixture.fromMap(event.payload);
    if (!_matchesFixtureTarget(fixture)) return;
    await toolFixtureHandler?.call(fixture);
  }

  bool _matchesFixtureTarget(AIDevtoolsToolFixture fixture) {
    final hookId = fixture.hookId;
    final threadId = fixture.threadId;
    if ((hookId == null || hookId.isEmpty) &&
        (threadId == null || threadId.isEmpty)) {
      return false;
    }

    if (hookId != null && hookId.isNotEmpty) {
      return hookId == options.liveHookId;
    }

    if (threadId != null &&
        threadId.isNotEmpty &&
        (options.liveThreadId == null || threadId != options.liveThreadId)) {
      return false;
    }
    return true;
  }

  Map<String, dynamic> _createEnvelope(
    String eventType, [
    String visibility = 'client-state',
    String? runId,
  ]) {
    return _createDevtoolsEventEnvelope(
      eventType: eventType,
      source: 'client',
      visibility: visibility,
      clientId: options.liveClientId,
      hookId: options.liveHookId,
      threadId: options.liveThreadId,
      runId: runId,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Map<String, dynamic> _createMetadataPayload() => <String, dynamic>{
        'hookId': options.liveHookId,
        'hookName': options.metadata.hookName,
        if (options.metadata.name != null) 'displayName': options.metadata.name,
        if (options.metadata.outputKind != null)
          'outputKind': options.metadata.outputKind,
        if (options.metadata.framework != null)
          'framework': options.metadata.framework,
      };
}

/// Owns the chat-client devtools surface: run/stream correlation, fixture
/// replay and snapshot emission.
class ChatDevtoolsBridge extends ClientDevtoolsBridge<AIDevtoolsChatSnapshot> {
  final ChatDevtoolsBridgeOptions chatOptions;
  late ChatClientEventEmitter events;

  String? currentRunId;
  String? currentRunThreadId;
  String? currentStreamId;
  String? lastStreamId;
  ChatClientRunEventContext? lastRunEventContext;
  Object? lastMemoryStateValue;
  final List<MapEntry<String, Object?>> lastCompactionEvents =
      <MapEntry<String, Object?>>[];
  Object? lastSkillsStateValue;

  ChatDevtoolsBridge(ChatDevtoolsBridgeOptions options)
      : chatOptions = options,
        super(options) {
    events = ChatDevtoolsAwareEventEmitter(
      () => options.liveClientId,
      this,
      options.eventClient,
    );
  }

  @override
  FutureOr<void> Function(AIDevtoolsToolFixture fixture)?
      get toolFixtureHandler => applyFixture;

  // --- Stream / run context API -------------------------------------------

  void setCurrentStreamId(String? streamId) {
    currentStreamId = streamId;
    if (streamId != null && streamId.isNotEmpty) {
      lastStreamId = streamId;
    }
  }

  void recordStreamId(String streamId) {
    if (streamId.isNotEmpty) lastStreamId = streamId;
  }

  void mountWithTools(int initialMessageCount) {
    events.clientCreated(initialMessageCount);
    emitRegistered();
    emitToolsRegistered();
    emitSnapshot();
  }

  void notifyToolsChanged() {
    emitToolsRegistered();
    emitSnapshot();
  }

  String? getCurrentStreamId() => currentStreamId;

  String? getLastStreamId() => lastStreamId;

  String resolveStreamId() =>
      currentStreamId ?? lastStreamId ?? chatOptions.generateId('stream');

  void beginRun(String runId, String threadId) {
    currentRunId = runId;
    currentRunThreadId = threadId;
    lastRunEventContext = ChatClientRunEventContext(
      runId: runId,
      threadId: threadId,
    );
  }

  void observeChunk(Map<String, dynamic> chunk) {
    final type = chunk['type'];
    if (type == 'RUN_STARTED') {
      beginRun(
        '${chunk['runId'] ?? ''}',
        '${chunk['threadId'] ?? ''}',
      );
      return;
    }

    if (type == 'RUN_FINISHED' || type == 'RUN_ERROR') {
      final runId = chunk['runId'] is String ? chunk['runId'] as String : null;
      if (runId == null || runId.isEmpty || runId == currentRunId) {
        final context = getCurrentRunEventContext();
        if (context != null) {
          lastRunEventContext = context;
        }
        currentRunId = null;
        currentRunThreadId = null;
      }
    }
  }

  void recordMemoryState(Object? rawValue) {
    lastMemoryStateValue = rawValue;
    _emitMemoryState(rawValue);
  }

  void recordSkillsState(Object? rawValue) {
    lastSkillsStateValue = rawValue;
    _emitSkillsState(rawValue);
  }

  void recordCompactionEvent(String eventType, Object? rawValue) {
    lastCompactionEvents.add(MapEntry(eventType, rawValue));
    if (lastCompactionEvents.length > 60) {
      lastCompactionEvents.removeRange(
        0,
        lastCompactionEvents.length - 60,
      );
    }
    _emitCompactionEvent(eventType, rawValue);
  }

  void recordCompactionState(Object? rawValue) {
    recordCompactionEvent('compaction:state', rawValue);
  }

  @override
  void onReplayState() {
    if (lastMemoryStateValue != null) {
      _emitMemoryState(lastMemoryStateValue);
    }
    for (final event in lastCompactionEvents) {
      _emitCompactionEvent(event.key, event.value);
    }
    if (lastSkillsStateValue != null) {
      _emitSkillsState(lastSkillsStateValue);
    }
  }

  ChatClientRunEventContext? getCurrentRunEventContext() {
    final runId = currentRunId;
    if (runId == null || runId.isEmpty) return null;
    return ChatClientRunEventContext(
      threadId: currentRunThreadId ?? chatOptions.liveThreadId ?? '',
      runId: runId,
    );
  }

  ChatClientRunEventContext? getCurrentOrLastRunEventContext() =>
      getCurrentRunEventContext() ?? lastRunEventContext;

  ChatClientEventContext findToolCallContext(String toolCallId) {
    final runContext = getCurrentRunEventContext();
    if (runContext != null) {
      return ChatClientEventContext(
        threadId: runContext.threadId,
        runId: runContext.runId,
        toolCallId: toolCallId,
      );
    }
    final threadId = chatOptions.liveThreadId;
    if (threadId != null && threadId.isNotEmpty) {
      return ChatClientEventContext(
        threadId: threadId,
        toolCallId: toolCallId,
      );
    }
    return ChatClientEventContext(toolCallId: toolCallId);
  }

  // --- Fixture replay ------------------------------------------------------

  Future<void> applyFixture(AIDevtoolsToolFixture fixture) async {
    final messages = chatOptions.getMessages();
    final threadId = fixture.threadId ?? chatOptions.liveThreadId ?? '';
    if (fixture.execute == true) {
      await _executeFixture(fixture, messages, threadId);
      return;
    }

    final replay = _createReplayMessageFromFixture(fixture, messages);
    final message = replay.message;
    final toolCallId = replay.toolCallId;
    final messageId = '${message['id'] ?? ''}';

    events.messageAppended(
      message,
      context: ChatClientEventContext(
        threadId: threadId,
        toolCallId: toolCallId,
        runId: fixture.runId,
      ),
    );
    chatOptions.setMessages(<Map<String, dynamic>>[
      ...messages,
      message,
    ]);
    events.toolFixtureApplied(
      ChatClientToolFixtureAppliedEvent(
        hookId: chatOptions.liveHookId,
        threadId: threadId,
        runId: fixture.runId,
        toolName: fixture.toolName,
        input: fixture.input,
        output: fixture.output,
        execute: fixture.execute,
        message: fixture.message,
        messageId: messageId,
        toolCallId: toolCallId,
        errorText: fixture.errorText,
      ),
    );
    emitSnapshot();
  }

  Future<void> _executeFixture(
    AIDevtoolsToolFixture fixture,
    List<Map<String, dynamic>> messages,
    String threadId,
  ) async {
    final toolCallId = _resolveFixtureToolCallId(fixture.toolCallId, messages);
    final messageId = _resolveFixtureMessageId(fixture.messageId, messages);
    final message = <String, dynamic>{
      'id': messageId,
      'role': 'assistant',
      'parts': <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'tool-call',
          'id': toolCallId,
          'name': fixture.toolName,
          'arguments': _stringifyFixtureValue(fixture.input),
          'input': fixture.input,
          'state': 'input-complete',
        },
      ],
      'createdAt': DateTime.now().toIso8601String(),
    };

    events.messageAppended(
      message,
      context: ChatClientEventContext(
        threadId: threadId,
        toolCallId: toolCallId,
        runId: fixture.runId,
      ),
    );
    chatOptions.setMessages(<Map<String, dynamic>>[
      ...messages,
      message,
    ]);
    emitSnapshot();

    final clientTool = _findClientTool(fixture.toolName);
    final execute = clientTool?.execute;
    if (execute == null) {
      _addToolResultForFixture(
        fixture: fixture,
        messageId: messageId,
        toolCallId: toolCallId,
        threadId: threadId,
        output: fixture.output,
        errorText: fixture.errorText,
      );
      return;
    }

    Object? output;
    try {
      output = await execute(fixture.input);
    } catch (error) {
      _addToolResultForFixture(
        fixture: fixture,
        messageId: messageId,
        toolCallId: toolCallId,
        threadId: threadId,
        output: null,
        errorText: '$error',
      );
      return;
    }

    _addToolResultForFixture(
      fixture: fixture,
      messageId: messageId,
      toolCallId: toolCallId,
      threadId: threadId,
      output: output,
    );
  }

  void _addToolResultForFixture({
    required AIDevtoolsToolFixture fixture,
    required String messageId,
    required String toolCallId,
    required String threadId,
    required Object? output,
    String? errorText,
  }) {
    final state = errorText != null ? 'output-error' : 'output-available';
    events.toolResultAdded(
      toolCallId,
      fixture.toolName,
      output,
      state,
      ChatClientEventContext(
        threadId: threadId,
        runId: fixture.runId,
        toolCallId: toolCallId,
      ),
    );
    chatOptions.addToolResult(toolCallId, output, errorText);
    events.toolFixtureApplied(
      ChatClientToolFixtureAppliedEvent(
        hookId: chatOptions.liveHookId,
        threadId: threadId,
        runId: fixture.runId,
        toolName: fixture.toolName,
        input: fixture.input,
        output: output,
        execute: true,
        messageId: messageId,
        toolCallId: toolCallId,
        errorText: errorText,
      ),
    );
    emitSnapshot();
  }

  _FixtureReplay _createReplayMessageFromFixture(
    AIDevtoolsToolFixture fixture,
    List<Map<String, dynamic>> messages,
  ) {
    final cloned = _cloneFixtureSourceMessage(fixture, messages);
    if (cloned != null) return cloned;

    final toolCallId = _resolveFixtureToolCallId(fixture.toolCallId, messages);
    final messageId = _resolveFixtureMessageId(fixture.messageId, messages);
    final state = fixture.errorText != null ? 'error' : 'complete';

    return _FixtureReplay(
      toolCallId: toolCallId,
      message: <String, dynamic>{
        'id': messageId,
        'role': 'assistant',
        'parts': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'tool-call',
            'id': toolCallId,
            'name': fixture.toolName,
            'arguments': _stringifyFixtureValue(fixture.input),
            'input': fixture.input,
            'state': 'input-complete',
            'output': fixture.output,
          },
          <String, dynamic>{
            'type': 'tool-result',
            'toolCallId': toolCallId,
            'content': _stringifyFixtureValue(fixture.output),
            'state': state,
            if (fixture.errorText != null) 'error': fixture.errorText,
          },
        ],
        'createdAt': DateTime.now().toIso8601String(),
      },
    );
  }

  _FixtureReplay? _cloneFixtureSourceMessage(
    AIDevtoolsToolFixture fixture,
    List<Map<String, dynamic>> messages,
  ) {
    final sourceMessage = fixture.message;
    final rawParts = sourceMessage?['parts'];
    if (sourceMessage == null || rawParts is! List) return null;

    final toolCallIds = _createFixtureToolCallIdMap(rawParts, messages);
    final parts = <Map<String, dynamic>>[];
    for (final part in rawParts) {
      final cloned = _cloneFixtureMessagePart(part, toolCallIds);
      if (cloned != null) parts.add(cloned);
    }

    final mappedFixtureToolCallId =
        fixture.toolCallId != null ? toolCallIds[fixture.toolCallId] : null;
    _hydrateToolCallOutputs(
      parts,
      mappedToolCallId: mappedFixtureToolCallId,
      output: fixture.output,
    );

    if (parts.isEmpty) return null;

    final toolCallId =
        (fixture.toolCallId != null ? toolCallIds[fixture.toolCallId] : null) ??
            _firstToolCallId(parts);
    if (toolCallId == null) return null;

    return _FixtureReplay(
      toolCallId: toolCallId,
      message: <String, dynamic>{
        'id': _resolveFixtureMessageId(
          sourceMessage['id'] is String ? sourceMessage['id'] as String : null,
          messages,
        ),
        'role': sourceMessage['role'],
        'parts': parts,
        'createdAt': DateTime.now().toIso8601String(),
      },
    );
  }

  Map<String, String> _createFixtureToolCallIdMap(
    List<dynamic> parts,
    List<Map<String, dynamic>> messages,
  ) {
    final ids = <String, String>{};
    for (final part in parts) {
      if (part is! Map) continue;
      if (part['type'] != 'tool-call') continue;
      final id = part['id'];
      if (id is! String) continue;
      ids[id] = _resolveFixtureToolCallId(id, messages);
    }
    return ids;
  }

  String _resolveFixtureMessageId(
    String? messageId,
    List<Map<String, dynamic>> messages,
  ) {
    if (messageId != null &&
        messageId.isNotEmpty &&
        !messages.any((message) => message['id'] == messageId)) {
      return messageId;
    }
    return chatOptions.generateId('fixture-msg');
  }

  String _resolveFixtureToolCallId(
    String? toolCallId,
    List<Map<String, dynamic>> messages,
  ) {
    if (toolCallId != null &&
        toolCallId.isNotEmpty &&
        !_hasToolCallId(messages, toolCallId)) {
      return toolCallId;
    }
    return chatOptions.generateId('fixture-tool-call');
  }

  AIDevtoolsTool? _findClientTool(String name) {
    final readTools = chatOptions.getTools;
    if (readTools == null) return null;
    for (final tool in readTools()) {
      if (tool.name == name) return tool;
    }
    return null;
  }

  void _emitMemoryState(Object? rawValue) {
    if (rawValue is! Map) return;
    final value = rawValue.map((key, item) => MapEntry('$key', item));
    final scope = value['scope'];
    final adapter = value['adapter'];
    if (scope is! Map || adapter is! String) return;
    final runId = currentRunId;

    options.eventClient.emit('memory:retrieve:started', <String, dynamic>{
      ..._createEnvelope('memory:retrieve:started', 'client-state', runId),
      'scope': scope,
      'adapter': adapter,
      'query': value['query'] ?? '',
    });

    final recall = value['recall'];
    if (recall is Map) {
      options.eventClient.emit('memory:retrieve:completed', <String, dynamic>{
        ..._createEnvelope(
          'memory:retrieve:completed',
          'client-state',
          runId,
        ),
        'scope': scope,
        'adapter': adapter,
        'fragmentCount': recall['fragmentCount'] ?? 0,
        'hasTools': recall['hasTools'] == true,
        'systemPromptChars': recall['systemPromptChars'] ?? 0,
        'durationMs': recall['durationMs'] ?? 0,
      });
    }

    final snapshot = value['snapshot'];
    if (snapshot is Map) {
      options.eventClient.emit('memory:snapshot', <String, dynamic>{
        ..._createEnvelope('memory:snapshot', 'client-state', runId),
        'scope': scope,
        'adapter': adapter,
        'takenAt': snapshot['takenAt'],
        'data': snapshot['data'],
        'facts': snapshot['facts'] ?? <Object?>[],
      });
    }
  }

  void _emitCompactionEvent(String eventType, Object? rawValue) {
    final runId = currentRunId;
    if (eventType == 'compaction:started') {
      options.eventClient.emit('compaction:started', <String, dynamic>{
        ..._createEnvelope('compaction:started', 'client-state', runId),
        ..._readCompactionBoundaryValue(rawValue),
      });
      return;
    }
    if (eventType == 'compaction:ended') {
      options.eventClient.emit('compaction:ended', <String, dynamic>{
        ..._createEnvelope('compaction:ended', 'client-state', runId),
        ..._readCompactionBoundaryValue(rawValue),
      });
      return;
    }
    if (eventType == 'compaction:state') {
      final value = _readCompactionStateValue(rawValue);
      if (value == null) return;
      options.eventClient.emit('compaction:state', <String, dynamic>{
        ..._createEnvelope('compaction:state', 'client-state', runId),
        ...value,
      });
    }
  }

  void _emitSkillsState(Object? rawValue) {
    if (rawValue is! Map) return;
    final catalog = rawValue['catalog'];
    final activated = rawValue['activated'];
    final runId = currentRunId;
    options.eventClient.emit('skills:snapshot', <String, dynamic>{
      ..._createEnvelope('skills:snapshot', 'client-state', runId),
      'catalog': catalog is List ? catalog : <Object?>[],
      'activated': activated is List ? activated : <Object?>[],
    });
  }
}

/// Generation bridge. The generation client pushes core state through
/// [recordResultChange] / [recordProgressChange] / lifecycle methods.
class GenerationDevtoolsBridge<TOutput>
    extends ClientDevtoolsBridge<AIDevtoolsGenerationSnapshotBase<TOutput>> {
  String? activeRunId;
  bool activeRunStarted = false;
  List<AIDevtoolsGenerationRunSnapshot<TOutput>> devtoolsRuns =
      <AIDevtoolsGenerationRunSnapshot<TOutput>>[];
  final int maxRuns;
  final AIDevtoolsGenerationCoreState<TOutput> Function() getCoreState;

  // ignore: use_super_parameters
  GenerationDevtoolsBridge(GenerationDevtoolsBridgeOptions<TOutput> options)
      : maxRuns = options.maxRuns,
        getCoreState = options.getCoreState,
        super(options);

  // --- Run lifecycle (called by the generation client) -------------------

  String beginRun(Object? input) {
    final runId = generateRunId();
    activeRunId = runId;
    activeRunStarted = false;
    upsertRun(
      runId,
      AIDevtoolsGenerationRunPatch<TOutput>(
        input: input,
        result: null,
        preview: createPreview(null),
        progress: null,
        status: AIDevtoolsGenerationRunStatus.generating,
        isLoading: true,
        clearError: true,
      ),
    );
    return runId;
  }

  void ensureRunStarted(String runId) {
    if (activeRunStarted && activeRunId == runId) return;

    final previousRunId = activeRunId;
    if (!activeRunStarted && previousRunId != null && previousRunId != runId) {
      renameRun(previousRunId, runId);
    }

    activeRunId = runId;
    activeRunStarted = true;
    upsertRun(
      runId,
      AIDevtoolsGenerationRunPatch<TOutput>(
        status: AIDevtoolsGenerationRunStatus.generating,
        isLoading: true,
        clearError: true,
      ),
    );
    emitRunLifecycle(
      AIDevtoolsRunEventType.started,
      runId,
      AIDevtoolsRunStatus.started,
    );
    emitState();
  }

  void finishRun(
    String runId,
    AIDevtoolsRunEventType eventType,
    AIDevtoolsRunStatus status, {
    String? error,
  }) {
    ensureRunStarted(runId);
    final completedAt = DateTime.now().millisecondsSinceEpoch;
    final completedProgress = status == AIDevtoolsRunStatus.completed
        ? completeProgress()
        : getProgress();
    final runStatus = switch (status) {
      AIDevtoolsRunStatus.completed => AIDevtoolsGenerationRunStatus.success,
      AIDevtoolsRunStatus.errored => AIDevtoolsGenerationRunStatus.error,
      _ => AIDevtoolsGenerationRunStatus.cancelled,
    };

    upsertRun(
      runId,
      AIDevtoolsGenerationRunPatch<TOutput>(
        status: runStatus,
        isLoading: false,
        progress: completedProgress,
        completedAt: completedAt,
        error: error,
        clearError: error == null,
      ),
    );

    if (activeRunId == runId) {
      activeRunId = null;
    }
    activeRunStarted = false;
    emitRunLifecycle(eventType, runId, status, error: error);
    emitState();
  }

  String? getActiveRunId() => activeRunId;

  void resetRuns() {
    activeRunId = null;
    activeRunStarted = false;
    devtoolsRuns = <AIDevtoolsGenerationRunSnapshot<TOutput>>[];
  }

  void recordResultChange() {
    updateActiveRun(
      AIDevtoolsGenerationRunPatch<TOutput>(
        result: getCoreState().result,
        preview: createPreview(getCoreState().result),
        clearError: true,
      ),
    );
    emitState();
  }

  void recordLoadingChange() {
    updateActiveRun(
      AIDevtoolsGenerationRunPatch<TOutput>(
        isLoading: getCoreState().isLoading,
      ),
    );
    emitState();
  }

  void recordErrorChange(Object? error) {
    updateActiveRun(
      AIDevtoolsGenerationRunPatch<TOutput>(
        error: error == null ? null : _errorMessage(error),
        clearError: error == null,
      ),
    );
    emitState();
  }

  void recordStatusChange(AIDevtoolsGenerationRunStatus status) {
    updateActiveRun(
      AIDevtoolsGenerationRunPatch<TOutput>(status: status),
    );
    emitState();
  }

  void recordProgressChange() {
    updateActiveRun(
      AIDevtoolsGenerationRunPatch<TOutput>(
        progress: getCoreState().progress,
      ),
    );
    emitState();
  }

  void recordJobIdChange() {
    updateActiveRun(
      AIDevtoolsVideoRunPatch<TOutput>(
        jobId: getCoreState().jobId,
      ),
    );
    emitState();
  }

  void recordVideoStatusChange() {
    final core = getCoreState();
    updateActiveRun(
      AIDevtoolsVideoRunPatch<TOutput>(
        videoStatus: core.videoStatus,
        preview: createPreview(core.result),
      ),
    );
    emitState();
  }

  void emitState() {
    emitUpdated();
    emitSnapshot();
  }

  // --- Internal ------------------------------------------------------------

  @override
  AIDevtoolsGenerationSnapshotBase<TOutput> buildSnapshot() {
    final core = getCoreState();
    return AIDevtoolsGenerationSnapshotBase<TOutput>(
      input: core.input,
      result: core.result,
      preview: createPreview(core.result),
      progress: core.progress,
      status: core.status,
      isLoading: core.isLoading,
      activeRunId: activeRunId,
      runs: devtoolsRuns,
      error: core.error,
    );
  }

  void updateActiveRun(AIDevtoolsGenerationRunPatch<TOutput> patch) {
    final runId = activeRunId;
    if (runId == null) return;
    upsertRun(runId, patch);
  }

  void upsertRun(
    String runId,
    AIDevtoolsGenerationRunPatch<TOutput> patch,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final index = devtoolsRuns.indexWhere((run) => run.id == runId);
    final existing = index >= 0 ? devtoolsRuns[index] : null;
    final next = existing == null
        ? AIDevtoolsGenerationRunSnapshot<TOutput>(
            id: runId,
            input: getCoreState().input,
            result: null,
            preview: createPreview(null),
            progress: null,
            status: AIDevtoolsGenerationRunStatus.idle,
            isLoading: false,
            startedAt: now,
            updatedAt: now,
          )
        : AIDevtoolsGenerationRunSnapshot<TOutput>(
            id: existing.id,
            input: existing.input,
            result: existing.result,
            preview: existing.preview,
            progress: existing.progress,
            status: existing.status,
            isLoading: existing.isLoading,
            startedAt: existing.startedAt,
            updatedAt: existing.updatedAt,
            completedAt: existing.completedAt,
            error: existing.error,
            jobId: existing.jobId,
            videoStatus: existing.videoStatus,
          );

    if (patch.hasInput) next.input = patch.input;
    if (patch.hasResult) next.result = patch.result as TOutput?;
    if (patch.preview != null) next.preview = patch.preview!;
    if (patch.hasProgress) {
      next.progress = patch.progress as AIDevtoolsGenerationProgress?;
    }
    if (patch.status != null) next.status = patch.status!;
    if (patch.isLoading != null) next.isLoading = patch.isLoading!;
    if (patch.completedAt != null) next.completedAt = patch.completedAt;
    if (patch.clearError) next.error = null;
    if (patch.error != null) next.error = patch.error;
    if (patch is AIDevtoolsVideoRunPatch<TOutput>) {
      if (patch.hasJobId) next.jobId = patch.jobId as String?;
      if (patch.hasVideoStatus) next.videoStatus = patch.videoStatus;
    }
    next.updatedAt = now;

    if (index >= 0) {
      devtoolsRuns[index] = next;
    } else {
      devtoolsRuns = <AIDevtoolsGenerationRunSnapshot<TOutput>>[
        ...devtoolsRuns,
        next,
      ];
    }

    if (devtoolsRuns.length > maxRuns) {
      devtoolsRuns = devtoolsRuns.sublist(devtoolsRuns.length - maxRuns);
    }
  }

  void renameRun(String previousRunId, String nextRunId) {
    if (previousRunId == nextRunId) return;

    final index = devtoolsRuns.indexWhere((run) => run.id == previousRunId);
    if (index < 0) return;

    final existing = devtoolsRuns[index];
    final renamed = AIDevtoolsGenerationRunSnapshot<TOutput>(
      id: nextRunId,
      input: existing.input,
      result: existing.result,
      preview: existing.preview,
      progress: existing.progress,
      status: existing.status,
      isLoading: existing.isLoading,
      startedAt: existing.startedAt,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      completedAt: existing.completedAt,
      error: existing.error,
      jobId: existing.jobId,
      videoStatus: existing.videoStatus,
    );

    devtoolsRuns = devtoolsRuns
        .where((run) => run.id != nextRunId)
        .map((run) => run.id == previousRunId ? renamed : run)
        .toList();
  }

  AIDevtoolsGenerationProgress? getProgress() => getCoreState().progress;

  AIDevtoolsGenerationProgress? completeProgress() {
    final progress = getCoreState().progress;
    if (progress == null) return null;
    return AIDevtoolsGenerationProgress(
      value: 100,
      message: progress.message,
    );
  }

  AIDevtoolsGenerationPreview createPreview(Object? result) {
    return createAIDevtoolsGenerationPreview(
      AIDevtoolsGenerationPreviewInput(
        outputKind: options.metadata.outputKind,
        result: result,
      ),
    );
  }

  String generateRunId() =>
      'run-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(0x7fffffff).toRadixString(36).padLeft(6, '0').substring(0, 6)}';
}

/// Video-job specialization: snapshots also carry the job id and latest
/// provider-reported video status.
class VideoDevtoolsBridge<TOutput> extends GenerationDevtoolsBridge<TOutput> {
  // ignore: use_super_parameters
  VideoDevtoolsBridge(VideoDevtoolsBridgeOptions<TOutput> options)
      : super(options);

  AIDevtoolsVideoCoreState<TOutput> get _videoCore =>
      getCoreState() as AIDevtoolsVideoCoreState<TOutput>;

  @override
  AIDevtoolsVideoSnapshotBase<TOutput> buildSnapshot() {
    final core = _videoCore;
    return AIDevtoolsVideoSnapshotBase<TOutput>(
      input: core.input,
      result: core.result,
      preview: _createVideoPreview(core.result, core.videoStatus),
      progress: core.progress,
      status: core.status,
      isLoading: core.isLoading,
      activeRunId: activeRunId,
      runs: devtoolsRuns,
      error: core.error,
      jobId: core.jobId,
      videoStatus: core.videoStatus,
    );
  }

  @override
  void upsertRun(
    String runId,
    AIDevtoolsGenerationRunPatch<TOutput> patch,
  ) {
    super.upsertRun(runId, patch);
    if (patch is! AIDevtoolsVideoRunPatch<TOutput>) return;
    if (!patch.hasJobId && !patch.hasVideoStatus) return;

    final index = devtoolsRuns.indexWhere((run) => run.id == runId);
    if (index < 0) return;
    final target = devtoolsRuns[index];
    final merged = AIDevtoolsGenerationRunSnapshot<TOutput>(
      id: target.id,
      input: target.input,
      result: target.result,
      preview: target.preview,
      progress: target.progress,
      status: target.status,
      isLoading: target.isLoading,
      startedAt: target.startedAt,
      updatedAt: target.updatedAt,
      completedAt: target.completedAt,
      error: target.error,
      jobId: target.jobId,
      videoStatus: target.videoStatus,
    );
    if (patch.hasJobId) merged.jobId = patch.jobId as String?;
    if (patch.hasVideoStatus) merged.videoStatus = patch.videoStatus;
    devtoolsRuns[index] = merged;
  }

  @override
  AIDevtoolsGenerationPreview createPreview(Object? result) {
    final core = _videoCore;
    return _createVideoPreview(result, core.videoStatus);
  }

  AIDevtoolsGenerationPreview _createVideoPreview(
    Object? result,
    Object? videoStatus,
  ) {
    return createAIDevtoolsGenerationPreview(
      AIDevtoolsGenerationPreviewInput(
        outputKind: options.metadata.outputKind,
        result: result,
        videoStatus: videoStatus,
      ),
    );
  }
}

/// Wraps the default emitter so every chat event gets run/thread context and a
/// snapshot emission, and so stream ids are tracked passively.
class ChatDevtoolsAwareEventEmitter extends DefaultChatClientEventEmitter {
  final String Function() getClientId;
  final ChatDevtoolsBridge helper;

  ChatDevtoolsAwareEventEmitter(
    this.getClientId,
    this.helper,
    AIDevtoolsEventClient sink,
  ) : super(
          getClientId(),
          eventClient: _ForwardingAiEventClient(sink),
        );

  /// Keep the emitter's client id live, matching upstream's live identity.
  @override
  String get clientId => getClientId();

  void _afterEmit([String? streamId]) {
    if (streamId != null) helper.recordStreamId(streamId);
    helper.emitSnapshot();
  }

  ChatClientEventContext? _eventContext() {
    final context = helper.getCurrentRunEventContext();
    if (context == null) return null;
    return ChatClientEventContext(
      threadId: context.threadId,
      runId: context.runId,
      toolCallId: context.toolCallId,
    );
  }

  @override
  void textUpdated(
    String streamId,
    String messageId,
    String content, [
    ChatClientRunEventContext? context,
  ]) {
    super.textUpdated(
      streamId,
      messageId,
      content,
      context ?? helper.getCurrentRunEventContext(),
    );
    _afterEmit(streamId);
  }

  @override
  void thinkingUpdated(
    String streamId,
    String messageId,
    String content, [
    String? delta,
    ChatClientRunEventContext? context,
  ]) {
    super.thinkingUpdated(
      streamId,
      messageId,
      content,
      delta,
      context ?? helper.getCurrentRunEventContext(),
    );
    _afterEmit(streamId);
  }

  @override
  void messageAppended(
    Map<String, dynamic> uiMessage, {
    String? streamId,
    ChatClientEventContext? context,
  }) {
    super.messageAppended(
      uiMessage,
      streamId: streamId,
      context: context ?? _eventContext(),
    );
    _afterEmit(streamId);
  }

  @override
  void toolCallStateChanged(
    String streamId,
    String messageId,
    String toolCallId,
    String toolName,
    String state,
    String args, [
    ChatClientRunEventContext? context,
  ]) {
    super.toolCallStateChanged(
      streamId,
      messageId,
      toolCallId,
      toolName,
      state,
      args,
      context ?? helper.getCurrentRunEventContext(),
    );
    _afterEmit(streamId);
  }

  @override
  void structuredOutputChanged(
    String eventName,
    String streamId,
    String messageId,
    ChatClientStructuredOutputEvent output, [
    ChatClientRunEventContext? context,
  ]) {
    super.structuredOutputChanged(
      eventName,
      streamId,
      messageId,
      output,
      context ?? helper.getCurrentOrLastRunEventContext(),
    );
    _afterEmit(streamId);
  }

  @override
  void approvalRequested(
    String streamId,
    String messageId,
    String toolCallId,
    String toolName,
    Object? input,
    String approvalId, [
    ChatClientRunEventContext? context,
  ]) {
    super.approvalRequested(
      streamId,
      messageId,
      toolCallId,
      toolName,
      input,
      approvalId,
      context ?? helper.getCurrentOrLastRunEventContext(),
    );
    _afterEmit(streamId);
  }

  @override
  void toolResultAdded(
    String toolCallId,
    String toolName,
    Object? output,
    String state, [
    ChatClientEventContext? context,
  ]) {
    super.toolResultAdded(
      toolCallId,
      toolName,
      output,
      state,
      context ?? _eventContext(),
    );
    _afterEmit();
  }

  @override
  void toolApprovalResponded(
    String approvalId,
    String toolCallId,
    bool approved, [
    ChatClientRunEventContext? context,
  ]) {
    super.toolApprovalResponded(
      approvalId,
      toolCallId,
      approved,
      context ?? helper.getCurrentRunEventContext(),
    );
    _afterEmit();
  }

  @override
  void clientCreated(int initialMessageCount) {
    super.clientCreated(initialMessageCount);
    _afterEmit();
  }

  @override
  void loadingChanged(bool isLoading) {
    super.loadingChanged(isLoading);
    _afterEmit();
  }

  @override
  void errorChanged(String? error) {
    super.errorChanged(error);
    _afterEmit();
  }

  @override
  void reloaded(int fromMessageIndex) {
    super.reloaded(fromMessageIndex);
    _afterEmit();
  }

  @override
  void stopped() {
    super.stopped();
    _afterEmit();
  }

  @override
  void messagesCleared() {
    super.messagesCleared();
    _afterEmit();
  }

  @override
  void messageSent(String messageId, Object content) {
    super.messageSent(messageId, content);
    _afterEmit();
  }

  @override
  void toolFixtureApplied(ChatClientToolFixtureAppliedEvent fixture) {
    super.toolFixtureApplied(fixture);
    _afterEmit();
  }
}

class _ForwardingAiEventClient extends AiEventClient {
  final AIDevtoolsEventClient _sink;

  _ForwardingAiEventClient(this._sink);

  @override
  void emit(String eventName, Map<String, dynamic> data) {
    _sink.emit(eventName, data);
  }
}

// ---------------------------------------------------------------------------
// Fixture helpers (pure).
// ---------------------------------------------------------------------------

class _FixtureReplay {
  final Map<String, dynamic> message;
  final String toolCallId;

  const _FixtureReplay({required this.message, required this.toolCallId});
}

String _stringifyFixtureValue(Object? value) {
  if (value is String) return value;
  if (value == null) return 'null';
  if (value is Function || value is Symbol) return value.toString();
  try {
    return jsonEncode(value);
  } catch (_) {
    return value.toString();
  }
}

Object? _parseFixtureResultContent(String content) {
  try {
    return jsonDecode(content);
  } catch (_) {
    return content;
  }
}

Map<String, dynamic>? _cloneFixtureMessagePart(
  Object? part,
  Map<String, String> toolCallIds,
) {
  if (part is! Map) return null;
  final type = part['type'];
  if (type is! String) return null;
  final cloned = <String, dynamic>{
    for (final entry in part.entries)
      '${entry.key}': _deepCopyValue(entry.value),
  };

  if (type == 'tool-call' && part['id'] is String) {
    final id = part['id'] as String;
    cloned['id'] = toolCallIds[id] ?? id;
  }
  if (type == 'tool-result' && part['toolCallId'] is String) {
    final toolCallId = part['toolCallId'] as String;
    cloned['toolCallId'] = toolCallIds[toolCallId] ?? toolCallId;
  }
  return cloned;
}

String? _firstToolCallId(List<Map<String, dynamic>> parts) {
  for (final part in parts) {
    if (part['type'] == 'tool-call' && part['id'] is String) {
      return part['id'] as String;
    }
  }
  return null;
}

void _hydrateToolCallOutputs(
  List<Map<String, dynamic>> parts, {
  String? mappedToolCallId,
  required Object? output,
}) {
  for (final part in parts) {
    if (part['type'] != 'tool-result') continue;
    final toolCallId = part['toolCallId'];
    if (toolCallId is! String) continue;
    Map<String, dynamic>? toolCall;
    for (final candidate in parts) {
      if (candidate['type'] == 'tool-call' &&
          candidate['id'] == toolCallId &&
          !candidate.containsKey('output')) {
        toolCall = candidate;
        break;
      }
    }
    if (toolCall != null) {
      final content = part['content'];
      toolCall['output'] = content is List
          ? content
          : _parseFixtureResultContent('${content ?? ''}');
    }
  }

  if (mappedToolCallId != null && output != null) {
    for (final candidate in parts) {
      if (candidate['type'] == 'tool-call' &&
          candidate['id'] == mappedToolCallId &&
          !candidate.containsKey('output')) {
        candidate['output'] = output;
        break;
      }
    }
  }
}

bool _hasToolCallId(
  List<Map<String, dynamic>> messages,
  String toolCallId,
) {
  for (final message in messages) {
    final parts = message['parts'];
    if (parts is! List) continue;
    for (final part in parts) {
      if (part is! Map) continue;
      if (part['type'] == 'tool-call' && part['id'] == toolCallId) {
        return true;
      }
      if (part['type'] == 'tool-result' && part['toolCallId'] == toolCallId) {
        return true;
      }
    }
  }
  return false;
}

Object? _deepCopyValue(Object? value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        '${entry.key}': _deepCopyValue(entry.value),
    };
  }
  if (value is List) {
    return value.map(_deepCopyValue).toList();
  }
  return value;
}

String? _errorMessage(Object error) {
  try {
    final dynamic dynamicError = error;
    final message = dynamicError.message;
    if (message is String) return message;
  } catch (_) {
    // Fall through to toString for errors without a message field.
  }
  return error.toString();
}

// ---------------------------------------------------------------------------
// Compaction value readers.
// ---------------------------------------------------------------------------

Map<String, dynamic> _readCompactionBoundaryValue(Object? rawValue) {
  if (rawValue is! Map) return <String, dynamic>{};
  final out = <String, dynamic>{};
  void number(String key) {
    final value = rawValue[key];
    if (value is num) out[key] = value;
  }

  void boolean(String key) {
    final value = rawValue[key];
    if (value is bool) out[key] = value;
  }

  void string(String key) {
    final value = rawValue[key];
    if (value is String) out[key] = value;
  }

  number('before');
  number('after');
  number('messagesBefore');
  number('messagesAfter');
  boolean('reusedCheckpoint');
  number('maxTokens');
  string('strategyKey');
  number('durationMs');
  return out;
}

List<Map<String, dynamic>>? _readPreviewList(Object? value) {
  if (value is! List) return null;
  final previews = <Map<String, dynamic>>[];
  for (final item in value) {
    if (item is! Map) continue;
    final role = item['role'];
    final tokens = item['tokens'];
    final text = item['text'];
    if (role is! String || tokens is! num || text is! String) continue;
    previews.add(<String, dynamic>{
      'role': role,
      'tokens': tokens,
      'text': text,
    });
  }
  return previews;
}

Map<String, dynamic>? _readCompactionStateValue(Object? rawValue) {
  if (rawValue is! Map) return null;
  final before = rawValue['before'];
  final after = rawValue['after'];
  final messagesBefore = rawValue['messagesBefore'];
  final messagesAfter = rawValue['messagesAfter'];
  if (before is! num ||
      after is! num ||
      messagesBefore is! num ||
      messagesAfter is! num) {
    return null;
  }

  final reusedCheckpoint = rawValue['reusedCheckpoint'] == true;
  final maxTokens = rawValue['maxTokens'];
  final strategyKey = rawValue['strategyKey'];
  final dropped = _readPreviewList(rawValue['dropped']);
  final result = _readPreviewList(rawValue['result']);

  return <String, dynamic>{
    'before': before,
    'after': after,
    'messagesBefore': messagesBefore,
    'messagesAfter': messagesAfter,
    'reusedCheckpoint': reusedCheckpoint,
    if (maxTokens is num) 'maxTokens': maxTokens,
    if (strategyKey is String && strategyKey.isNotEmpty)
      'strategyKey': strategyKey,
    if (dropped != null) 'dropped': dropped,
    if (result != null) 'result': result,
  };
}
