import 'dart:async';
import 'dart:convert';

import 'json_parser.dart';
import 'message_converters.dart';
import 'strategies.dart';
import 'types.dart';

export 'types.dart';

/// State machine that turns an AG-UI / TanStack AI chunk stream into UI
/// messages. Port of `StreamProcessor` from `@tanstack/ai` 0.70.0.
class StreamProcessor {
  final ChunkStrategy chunkStrategy;
  final StreamProcessorEvents events;
  final dynamic jsonParser;
  bool recordingEnabled;

  List<Map<String, dynamic>> _messages = <Map<String, dynamic>>[];
  final Map<String, MessageStreamState> _messageStates =
      <String, MessageStreamState>{};
  final Set<String> _activeMessageIds = <String>{};
  final Map<String, String> _toolCallToMessage = <String, String>{};
  String? _pendingManualMessageId;
  bool _legacyManualMessage = false;
  String? _pendingThinkingStepId;
  _OpenChunk? _openChunk;

  final Set<String> _structuredMessageIds = <String>{};
  final Map<String, _StructuredBatch> _structuredOutputUpdateBatches =
      <String, _StructuredBatch>{};

  final Set<String> _activeRuns = <String>{};
  final Map<String, Set<String>> _callMessageIds = <String, Set<String>>{};
  final Set<String> _unassignedCallMessageIds = <String>{};
  final Set<String> _sealedMessageIds = <String>{};
  final Map<String, _ThinkingOwner> _thinkingOwners =
      <String, _ThinkingOwner>{};
  List<String> _runToolCallIds = <String>[];
  final Set<String> _toolCallsSentToClient = <String>{};
  final Map<String, StreamProcessor> _childProcessors =
      <String, StreamProcessor>{};
  final Map<String, String> _childToolCalls = <String, String>{};

  String? _finishReason;
  bool _hasError = false;
  bool _isDone = false;
  bool _streamEndEmitted = false;

  ChunkRecording? _recording;
  int _recordingStartTime = 0;

  final String? subagentRunId;

  static const int _structuredOutputUpdateBatchSize = 12;

  static const Set<String> _chunkPassThrough = <String>{
    'RAW',
    'ACTIVITY_SNAPSHOT',
    'ACTIVITY_DELTA',
    'REASONING_ENCRYPTED_VALUE',
    'SUBAGENT_STARTED',
    'SUBAGENT_FINISHED',
    'SUBAGENT_ERROR',
  };

  static const Set<String> _runLevelClosesLanes = <String>{
    'RUN_STARTED',
    'RUN_FINISHED',
    'RUN_ERROR',
    'MESSAGES_SNAPSHOT',
  };

  StreamProcessor(
      [StreamProcessorOptions options = const StreamProcessorOptions()])
      : subagentRunId = options.subagentRunId,
        chunkStrategy = options.chunkStrategy ?? ImmediateStrategy(),
        events = options.events ?? const StreamProcessorEvents(),
        jsonParser = options.jsonParser ?? defaultJSONParser,
        recordingEnabled = options.recording {
    if (options.initialMessages != null) {
      _messages = <Map<String, dynamic>>[
        for (final message in options.initialMessages!)
          <String, dynamic>{...message},
      ];
    }
  }

  // ---------------------------------------------------------------------------
  // Message management
  // ---------------------------------------------------------------------------

  void setMessages(List<Map<String, dynamic>> messages) {
    _messages = <Map<String, dynamic>>[...messages];
    _emitMessagesChange();
  }

  void prependMessages(List<Map<String, dynamic>> messages) {
    final existingIds = _messages.map((message) => message['id']).toSet();
    final older = <Map<String, dynamic>>[];
    for (final message in messages) {
      if (!existingIds.add(message['id'])) continue;
      older.add(message);
    }
    _messages = <Map<String, dynamic>>[...older, ..._messages];
    _emitMessagesChange();
  }

  Map<String, dynamic> addUserMessage(
    dynamic content, {
    String? id,
    Map<String, dynamic>? metadata,
  }) {
    final parts = content is String
        ? <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'content': content},
          ]
        : (content as List)
            .whereType<Map>()
            .map((part) => <String, dynamic>{...part.cast<String, dynamic>()})
            .toList();
    final message = <String, dynamic>{
      'id': id ?? generateMessageId(),
      'role': 'user',
      'parts': parts,
      'createdAt': DateTime.now(),
      if (metadata != null) 'metadata': metadata,
    };
    _messages = <Map<String, dynamic>>[..._messages, message];
    _emitMessagesChange();
    return message;
  }

  void prepareAssistantMessage() => _resetStreamState();

  String startAssistantMessage([String? messageId]) {
    prepareAssistantMessage();
    final result = _ensureAssistantMessage(messageId);
    _pendingManualMessageId = result.messageId;
    _legacyManualMessage = true;
    return result.messageId;
  }

  String? getCurrentAssistantMessageId() {
    String? lastId;
    for (final entry in _messageStates.entries) {
      if (entry.value.role == 'assistant') lastId = entry.key;
    }
    return lastId;
  }

  void addToolResult(String toolCallId, dynamic output, {String? error}) {
    Map<String, dynamic>? messageWithToolCall;
    for (final message in _messages) {
      if ((message['parts'] as List).any(
        (part) =>
            part is Map &&
            part['type'] == 'tool-call' &&
            part['id'] == toolCallId,
      )) {
        messageWithToolCall = message;
        break;
      }
    }
    if (messageWithToolCall == null) {
      final owner = _childOwningToolCall(
        (part) => part['id'] == toolCallId,
      );
      if (owner != null) {
        _updateChild(owner, (child) {
          child.addToolResult(toolCallId, output, error: error);
        });
        return;
      }
      _warn('Could not find message with tool call $toolCallId');
      return;
    }

    _messages = _updateToolCallWithOutput(
      _messages,
      toolCallId,
      output,
      error != null ? ToolCallState.error : null,
      error,
    );
    final content = normalizeToolResult(output);
    _messages = _updateToolResultPart(
      _messages,
      messageWithToolCall['id'] as String,
      toolCallId,
      content,
      error != null ? ToolResultState.error : ToolResultState.complete,
      error: error,
    );
    _emitMessagesChange();
  }

  void addToolApprovalResponse(String approvalId, bool approved) {
    final owner = _childOwningToolCall(
      (part) =>
          part['approval'] is Map &&
          (part['approval'] as Map)['id'] == approvalId,
    );
    if (owner != null) {
      _updateChild(owner, (child) {
        child.addToolApprovalResponse(approvalId, approved);
      });
      return;
    }
    _messages = _updateToolCallApprovalResponse(
      _messages,
      approvalId,
      approved,
    );
    _emitMessagesChange();
  }

  List<Map<String, dynamic>> toModelMessages() {
    final modelMessages = <Map<String, dynamic>>[];
    for (final message in _messages) {
      modelMessages.addAll(uiMessageToModelMessages(message));
    }
    return modelMessages;
  }

  List<Map<String, dynamic>> getMessages() => _messages;

  bool areAllToolsComplete() {
    Map<String, dynamic>? lastAssistant;
    for (final message in _messages.reversed) {
      if (message['role'] == 'assistant') {
        lastAssistant = message;
        break;
      }
    }
    if (lastAssistant == null) return true;
    final parts = lastAssistant['parts'] as List;
    final toolParts = parts
        .whereType<Map>()
        .where((part) => part['type'] == 'tool-call')
        .map((part) => part.cast<String, dynamic>())
        .toList();
    if (toolParts.isEmpty) return true;
    final toolResultIds = <String>{
      for (final part in parts.whereType<Map>())
        if (part['type'] == 'tool-result') part['toolCallId'] as String,
    };
    return toolParts.every(
      (part) =>
          part['state'] == 'complete' ||
          part['state'] == 'approval-responded' ||
          (part['output'] != null && part['approval'] == null) ||
          toolResultIds.contains(part['id']) ||
          isProviderExecutedToolCall(part),
    );
  }

  void removeMessagesAfter(int index) {
    final keptIds =
        _messages.take(index + 1).map((message) => message['id']).toSet();
    _structuredMessageIds.removeWhere((id) => !keptIds.contains(id));
    _structuredOutputUpdateBatches
        .removeWhere((id, _) => !keptIds.contains(id));
    _messageStates.removeWhere((id, _) => !keptIds.contains(id));
    _toolCallToMessage
        .removeWhere((id, messageId) => !keptIds.contains(messageId));
    _activeMessageIds.removeWhere((id) => !keptIds.contains(id));
    if (_pendingManualMessageId != null &&
        !keptIds.contains(_pendingManualMessageId)) {
      _pendingManualMessageId = null;
      _legacyManualMessage = false;
    }
    for (final ids in _callMessageIds.values) {
      ids.removeWhere((id) => !keptIds.contains(id));
    }
    _unassignedCallMessageIds.removeWhere((id) => !keptIds.contains(id));
    _sealedMessageIds.removeWhere((id) => !keptIds.contains(id));
    _thinkingOwners.removeWhere(
      (key, owner) => !keptIds.contains(owner.messageId),
    );
    _messages = _messages.take(index + 1).toList();
    _emitMessagesChange();
  }

  void clearMessages() {
    for (final ids in _callMessageIds.values) {
      ids.clear();
    }
    _unassignedCallMessageIds.clear();
    _messages = <Map<String, dynamic>>[];
    _messageStates.clear();
    _activeMessageIds.clear();
    _toolCallToMessage.clear();
    _structuredMessageIds.clear();
    _structuredOutputUpdateBatches.clear();
    _pendingManualMessageId = null;
    _legacyManualMessage = false;
    _sealedMessageIds.clear();
    _thinkingOwners.clear();
    _openChunk = null;
    _childProcessors.clear();
    _childToolCalls.clear();
    _emitMessagesChange();
  }

  // ---------------------------------------------------------------------------
  // Stream processing
  // ---------------------------------------------------------------------------

  Future<ProcessorResult> process(Stream<dynamic> stream) async {
    _resetStreamState();
    if (recordingEnabled) _startRecording();
    await for (final chunk in stream) {
      if (chunk is Map) processChunk(chunk.cast<String, dynamic>());
    }
    finalizeStream();
    if (_recording != null) _recording!.result = _getResult();
    return _getResult();
  }

  void processChunk(Map<String, dynamic> chunk) {
    if (_recording != null) {
      _recording!.chunks.add(
        RecordedChunk(
          chunk: chunk,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          index: _recording!.chunks.length,
        ),
      );
    }
    if (_routeToChild(chunk)) return;
    for (final event in _expandChunk(chunk)) {
      _dispatchChunk(event);
    }
  }

  void _dispatchChunk(Map<String, dynamic> chunk) {
    switch (chunk['type']) {
      case 'SUBAGENT_STARTED':
        _handleSubagentStarted(chunk);
        break;
      case 'SUBAGENT_FINISHED':
        _handleSubagentFinished(chunk);
        break;
      case 'SUBAGENT_ERROR':
        _handleSubagentError(chunk);
        break;
      case 'TEXT_MESSAGE_START':
        _handleTextMessageStart(chunk);
        break;
      case 'TEXT_MESSAGE_CONTENT':
        _handleTextMessageContent(chunk);
        break;
      case 'TEXT_MESSAGE_END':
        _handleTextMessageEnd(chunk);
        break;
      case 'TOOL_CALL_START':
        _handleToolCallStart(chunk);
        break;
      case 'TOOL_CALL_ARGS':
        _handleToolCallArgs(chunk);
        break;
      case 'TOOL_CALL_END':
        _handleToolCallEnd(chunk);
        break;
      case 'TOOL_CALL_RESULT':
        _handleToolCallResult(chunk);
        break;
      case 'RUN_STARTED':
        _handleRunStarted(chunk);
        break;
      case 'RUN_FINISHED':
        _handleRunFinished(chunk);
        break;
      case 'RUN_ERROR':
        _handleRunError(chunk);
        break;
      case 'STEP_STARTED':
        _handleStepStarted(chunk);
        break;
      case 'STEP_FINISHED':
        _handleStepFinished(chunk);
        break;
      case 'MESSAGES_SNAPSHOT':
        _handleMessagesSnapshot(chunk);
        break;
      case 'CUSTOM':
        _handleCustomEvent(chunk);
        break;
      case 'REASONING_MESSAGE_START':
        if (chunk['metadata'] != null) {
          final target = _unscopedAssistant(chunk);
          final result = _ensureAssistantMessage(
            target.id,
            fallbackToActive: !target.create,
          );
          _mergeMessageMetadata(result.messageId, chunk['metadata']);
        }
        break;
      case 'REASONING_MESSAGE_CONTENT':
        _handleReasoningContent(chunk);
        break;
      case 'REASONING_ENCRYPTED_VALUE':
        _handleReasoningEncryptedValue(chunk);
        break;
      case 'ACTIVITY_SNAPSHOT':
        _handleActivitySnapshot(chunk);
        break;
      case 'ACTIVITY_DELTA':
        _handleActivityDelta(chunk);
        break;
      default:
        break;
    }
  }

  List<Map<String, dynamic>> _expandChunk(Map<String, dynamic> chunk) {
    final open = _openChunk;
    final timestamp = chunk['timestamp'];
    switch (chunk['type']) {
      case 'TEXT_MESSAGE_CHUNK':
        final id = _chunkStreamId(
          'TEXT_MESSAGE',
          chunk['messageId'] as String?,
          chunk['type'] as String,
        );
        if (id == null) return _closeChunk();
        final result = <Map<String, dynamic>>[];
        if (open?.family != 'TEXT_MESSAGE' || open?.id != id) {
          result
            ..addAll(_closeChunk())
            ..add(<String, dynamic>{
              'type': 'TEXT_MESSAGE_START',
              'messageId': id,
              'role': chunk['role'] ?? 'assistant',
              if (chunk['name'] != null) 'name': chunk['name'],
              'timestamp': timestamp,
            });
          _openChunk = _OpenChunk('TEXT_MESSAGE', id);
        }
        if (chunk.containsKey('delta') || chunk.containsKey('metadata')) {
          result.add(<String, dynamic>{
            'type': 'TEXT_MESSAGE_CONTENT',
            'messageId': id,
            'delta': chunk['delta'] ?? '',
            if (chunk['metadata'] != null) 'metadata': chunk['metadata'],
            'timestamp': timestamp,
          });
        }
        return result;
      case 'TOOL_CALL_CHUNK':
        final id = _chunkStreamId(
          'TOOL_CALL',
          chunk['toolCallId'] as String?,
          chunk['type'] as String,
        );
        if (id == null) return _closeChunk();
        final result = <Map<String, dynamic>>[];
        if (open?.family != 'TOOL_CALL' || open?.id != id) {
          if (chunk['toolCallName'] == null) {
            _warn(
              'Dropped TOOL_CALL_CHUNK $id: the first chunk of a tool call '
              'needs a toolCallName',
            );
            return _closeChunk();
          }
          result
            ..addAll(_closeChunk())
            ..add(<String, dynamic>{
              'type': 'TOOL_CALL_START',
              'toolCallId': id,
              'toolCallName': chunk['toolCallName'],
              if (chunk['parentMessageId'] != null)
                'parentMessageId': chunk['parentMessageId'],
              if (chunk['metadata'] != null) 'metadata': chunk['metadata'],
              'timestamp': timestamp,
            });
          _openChunk = _OpenChunk('TOOL_CALL', id);
        }
        if (chunk.containsKey('delta') || chunk.containsKey('metadata')) {
          result.add(<String, dynamic>{
            'type': 'TOOL_CALL_ARGS',
            'toolCallId': id,
            'delta': chunk['delta'] ?? '',
            if (chunk['metadata'] != null) 'metadata': chunk['metadata'],
            'timestamp': timestamp,
          });
        }
        return result;
      case 'REASONING_MESSAGE_CHUNK':
        final id = _chunkStreamId(
          'REASONING_MESSAGE',
          chunk['messageId'] as String?,
          chunk['type'] as String,
        );
        if (id == null) return _closeChunk();
        final result = <Map<String, dynamic>>[];
        if (open?.family != 'REASONING_MESSAGE' || open?.id != id) {
          result
            ..addAll(_closeChunk())
            ..add(<String, dynamic>{
              'type': 'REASONING_MESSAGE_START',
              'messageId': id,
              'role': 'reasoning',
              'timestamp': timestamp,
            });
          _openChunk = _OpenChunk('REASONING_MESSAGE', id);
        }
        if (chunk.containsKey('delta') || chunk.containsKey('metadata')) {
          result.add(<String, dynamic>{
            'type': 'REASONING_MESSAGE_CONTENT',
            'messageId': id,
            'delta': chunk['delta'] ?? '',
            if (chunk['metadata'] != null) 'metadata': chunk['metadata'],
            'timestamp': timestamp,
          });
        }
        return result;
      default:
        final result = <Map<String, dynamic>>[];
        if (open != null && !_chunkPassThrough.contains(chunk['type'])) {
          result.addAll(_closeChunk());
        }
        if (_runLevelClosesLanes.contains(chunk['type'])) {
          _closeChildChunkLanes();
        }
        result.add(chunk);
        return result;
    }
  }

  void _closeChildChunkLanes() {
    for (final child in _childProcessors.values) {
      for (final event in child._closeChunk()) {
        child._dispatchChunk(event);
      }
      child._closeChildChunkLanes();
    }
  }

  String? _childContinuing(Map<String, dynamic> chunk) {
    String family;
    if (chunk['type'] == 'TEXT_MESSAGE_CHUNK' && chunk['messageId'] == null) {
      family = 'TEXT_MESSAGE';
    } else if (chunk['type'] == 'REASONING_MESSAGE_CHUNK' &&
        chunk['messageId'] == null) {
      family = 'REASONING_MESSAGE';
    } else if (chunk['type'] == 'TOOL_CALL_CHUNK' &&
        chunk['toolCallId'] == null) {
      family = 'TOOL_CALL';
    } else {
      return null;
    }
    if (_openChunkCount(family) != 1) return null;
    for (final entry in _childProcessors.entries) {
      if (entry.value._openChunkCount(family) == 1) return entry.key;
    }
    return null;
  }

  int _openChunkCount(String family) {
    var count = _openChunk?.family == family ? 1 : 0;
    for (final child in _childProcessors.values) {
      count += child._openChunkCount(family);
    }
    return count;
  }

  String? _chunkStreamId(String family, String? id, String type) {
    if (id != null) return id;
    if (_openChunk?.family == family) return _openChunk!.id;
    _warn('Dropped $type: it has no id and continues nothing');
    return null;
  }

  List<Map<String, dynamic>> _closeChunk() {
    final open = _openChunk;
    if (open == null) return <Map<String, dynamic>>[];
    _openChunk = null;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    switch (open.family) {
      case 'TEXT_MESSAGE':
        return <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'TEXT_MESSAGE_END',
            'messageId': open.id,
            'timestamp': timestamp,
          },
        ];
      case 'TOOL_CALL':
        return <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'TOOL_CALL_END',
            'toolCallId': open.id,
            'timestamp': timestamp,
          },
        ];
      default:
        return <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'REASONING_MESSAGE_END',
            'messageId': open.id,
            'timestamp': timestamp,
          },
        ];
    }
  }

  // ---------------------------------------------------------------------------
  // Per-message state
  // ---------------------------------------------------------------------------

  MessageStreamState _createMessageState(String messageId, String role) {
    final state = MessageStreamState(id: messageId, role: role);
    _messageStates[messageId] = state;
    return state;
  }

  MessageStreamState? _getMessageState(String messageId) =>
      _messageStates[messageId];

  void _consumePendingThinkingStep(MessageStreamState state) {
    final stepId = _pendingThinkingStepId;
    if (stepId == null) return;
    state.currentThinkingStepId = stepId;
    if (!state.thinkingSteps.containsKey(stepId)) {
      state.thinkingSteps[stepId] = '';
      state.thinkingStepOrder.add(stepId);
    }
    _pendingThinkingStepId = null;
  }

  String? _getActiveAssistantMessageId() {
    bool belongsToCurrentCall(String id) {
      return _activeRuns.isEmpty ||
          _activeRuns.any(
            (runId) => _callMessageIds[runId]?.contains(id) == true,
          ) ||
          (_pendingManualMessageId == id &&
              _messageStates[id]?.isComplete != true &&
              !_isDone);
    }

    final ids = _activeMessageIds.toList().reversed;
    for (final id in ids) {
      if (_sealedMessageIds.contains(id)) continue;
      final state = _messageStates[id];
      if (state != null &&
          state.role == 'assistant' &&
          belongsToCurrentCall(id)) {
        return id;
      }
    }
    for (final entry in _messageStates.entries.toList().reversed) {
      if (_sealedMessageIds.contains(entry.key)) continue;
      if (entry.value.role == 'assistant' && belongsToCurrentCall(entry.key)) {
        return entry.key;
      }
    }
    return null;
  }

  String? _runOfMessage(String messageId) {
    for (final entry in _callMessageIds.entries) {
      if (entry.value.contains(messageId)) return entry.key;
    }
    return null;
  }

  String? _openMessageOfRun(String runId) {
    final ids = _callMessageIds[runId];
    if (ids == null) return null;
    for (final id in ids.toList().reversed) {
      if (_sealedMessageIds.contains(id)) continue;
      if (_messageStates[id]?.role == 'assistant') return id;
    }
    return null;
  }

  ({String? id, bool create}) _unscopedAssistant(Map<String, dynamic> chunk) {
    final explicit = _getChunkRunId(chunk);
    final onlyRun = _activeRuns.length == 1 ? _activeRuns.first : null;
    final runId = explicit ?? onlyRun;
    if (runId != null) {
      final open = _openMessageOfRun(runId);
      if (open != null) return (id: open, create: false);
      if (explicit != null || _activeRuns.contains(runId)) {
        return (id: null, create: true);
      }
    }
    final active = _getActiveAssistantMessageId();
    if (active != null) return (id: active, create: false);
    return (id: null, create: true);
  }

  void _rememberThinking(
    String messageId,
    String stepId, [
    String? reasoningMessageId,
  ]) {
    final owner = _ThinkingOwner(messageId, stepId);
    _thinkingOwners[stepId] = owner;
    if (reasoningMessageId != null && reasoningMessageId != stepId) {
      _thinkingOwners[reasoningMessageId] = owner;
    }
  }

  bool _applyKnownSignature(String? namedId, String signature) {
    if (namedId == null) return false;
    final owner = _thinkingOwners[namedId];
    if (owner == null) return false;
    final state = _getMessageState(owner.messageId);
    if (state == null) return false;
    state.thinkingStepSignatures[owner.stepId] = signature;
    final content = state.thinkingSteps[owner.stepId] ?? '';
    if (!state.thinkingSteps.containsKey(owner.stepId)) {
      state.thinkingSteps[owner.stepId] = content;
      state.thinkingStepOrder.add(owner.stepId);
    }
    _messages = _updateThinkingPart(
      _messages,
      owner.messageId,
      owner.stepId,
      content,
      signature,
    );
    _emitMessagesChange();
    return true;
  }

  void _resumeAssistantState(String id, MessageStreamState state) {
    _activeMessageIds.add(id);
    if (state.isComplete || _isDone) {
      state.isComplete = false;
      _isDone = false;
    }
  }

  ({String messageId, MessageStreamState state}) _ensureAssistantMessage(
    String? preferredId, {
    bool fallbackToActive = true,
  }) {
    var targetId = preferredId;
    if (targetId != null) {
      final pendingId = _pendingManualMessageId;
      if (pendingId != null &&
          pendingId != targetId &&
          !_legacyManualMessage &&
          _messageStates[pendingId]?.isComplete == false &&
          !_messages.any((message) => message['id'] == targetId)) {
        _renameMessage(pendingId, targetId);
        _pendingManualMessageId = targetId;
      }
      final state = _getMessageState(targetId);
      if (state != null) {
        _resumeAssistantState(targetId, state);
        return (messageId: targetId, state: state);
      }
    }

    final activeId = fallbackToActive && preferredId == null
        ? _getActiveAssistantMessageId()
        : null;
    if (activeId != null) {
      final state = _getMessageState(activeId);
      if (state != null) {
        _resumeAssistantState(activeId, state);
        return (messageId: activeId, state: state);
      }
    }

    if (targetId != null) {
      Map<String, dynamic>? existingMessage;
      for (final message in _messages) {
        if (message['id'] == targetId) {
          existingMessage = message;
          break;
        }
      }
      if (existingMessage?['role'] == 'activity') {
        targetId = null;
      } else if (existingMessage != null) {
        final state = _createMessageState(
          targetId,
          existingMessage['role'] as String,
        );
        _activeMessageIds.add(targetId);
        final parts = existingMessage['parts'] as List;
        if (parts.isNotEmpty &&
            parts.last is Map &&
            parts.last['type'] == 'text') {
          final content = parts.last['content'] as String;
          state.currentSegmentText = content;
          state.lastEmittedText = content;
          state.totalTextContent = content;
        }
        return (messageId: targetId, state: state);
      }
    }

    final id = targetId ?? generateMessageId();
    final assistantMessage = <String, dynamic>{
      'id': id,
      'role': 'assistant',
      'parts': <Map<String, dynamic>>[],
      'createdAt': DateTime.now(),
    };
    _messages = <Map<String, dynamic>>[..._messages, assistantMessage];
    final state = _createMessageState(id, 'assistant');
    _activeMessageIds.add(id);
    if (targetId == null) _pendingManualMessageId = id;
    events.onStreamStart?.call();
    _emitMessagesChange();
    return (messageId: id, state: state);
  }

  // ---------------------------------------------------------------------------
  // Event handlers
  // ---------------------------------------------------------------------------

  void _mergeMessageMetadata(String messageId, dynamic incoming) {
    final runId = tanstackMetadata(<String, dynamic>{
          if (incoming is Map) 'metadata': incoming,
        })?['runId'] as String? ??
        (_activeRuns.length == 1 ? _activeRuns.first : null);
    if (runId != null) {
      (_callMessageIds[runId] ??= <String>{}).add(messageId);
    } else {
      _unassignedCallMessageIds.add(messageId);
    }
    if (incoming is! Map) return;
    Map<String, dynamic>? message;
    for (final candidate in _messages) {
      if (candidate['id'] == messageId) {
        message = candidate;
        break;
      }
    }
    if (message == null) return;

    final incomingRecord = <String, dynamic>{
      ...incoming.cast<String, dynamic>()
    };
    final incomingTanstack = tanstackMetadata(<String, dynamic>{
      'metadata': incomingRecord,
    });
    Map<String, dynamic> toMerge = incomingRecord;
    if (incomingTanstack != null &&
        (incomingTanstack.containsKey('content') ||
            incomingTanstack.containsKey('args'))) {
      toMerge = <String, dynamic>{
        ...incomingRecord,
        'tanstack': <String, dynamic>{
          for (final entry in incomingTanstack.entries)
            if (entry.key != 'content' && entry.key != 'args')
              entry.key: entry.value,
        },
      };
    }
    final current = message['metadata'];
    final metadata = mergeMetadata(
      current is Map ? current.cast<String, dynamic>() : null,
      toMerge,
    );
    final createdAt =
        coerceCreatedAt(tanstackMetadata(incomingRecord)?['createdAt']);
    _messages = _messages.map((candidate) {
      if (candidate['id'] != messageId) return candidate;
      final next = <String, dynamic>{...candidate};
      if (metadata != null) next['metadata'] = metadata;
      if (createdAt != null) next['createdAt'] = createdAt;
      return next;
    }).toList();
    _emitMessagesChange();
  }

  Map<String, dynamic>? _findSubagentPart(String subagentRunId) {
    for (final message in _messages) {
      for (final raw in message['parts'] as List) {
        if (raw is! Map || raw['type'] != 'subagent') continue;
        final subagent = raw['subagent'];
        if (subagent is Map && subagent['id'] == subagentRunId) {
          return raw.cast<String, dynamic>();
        }
      }
    }
    return null;
  }

  String? _childOwning(String id) {
    bool holds(List<dynamic> messages) => messages.any(
          (message) =>
              message is Map &&
              (message['parts'] as List).any(
                (raw) =>
                    raw is Map &&
                    raw['type'] == 'subagent' &&
                    (raw['subagent']['id'] == id ||
                        holds(raw['subagent']['messages'] as List)),
              ),
        );

    for (final message in _messages) {
      for (final raw in message['parts'] as List) {
        if (raw is! Map || raw['type'] != 'subagent') continue;
        if (raw['subagent']['id'] == id ||
            holds(raw['subagent']['messages'] as List)) {
          return raw['subagent']['id'] as String;
        }
      }
    }
    return null;
  }

  String? _childOwningToolCall(
    bool Function(Map<String, dynamic> part) matches,
  ) {
    bool holds(List<dynamic> messages) => messages.any(
          (message) =>
              message is Map &&
              (message['parts'] as List).any(
                (raw) =>
                    raw is Map &&
                    ((raw['type'] == 'tool-call' &&
                            matches(raw.cast<String, dynamic>())) ||
                        (raw['type'] == 'subagent' &&
                            holds(raw['subagent']['messages'] as List))),
              ),
        );

    for (final message in _messages) {
      for (final raw in message['parts'] as List) {
        if (raw is Map &&
            raw['type'] == 'subagent' &&
            holds(raw['subagent']['messages'] as List)) {
          return raw['subagent']['id'] as String;
        }
      }
    }
    return null;
  }

  StreamProcessor? _childProcessor(String childId) {
    final part = _findSubagentPart(childId);
    if (part == null) return null;
    final subagent = part['subagent'] as Map;
    final childMessages = (subagent['messages'] as List)
        .map((message) => <String, dynamic>{
              ...(message as Map).cast<String, dynamic>(),
            })
        .toList();
    final existing = _childProcessors[childId];
    if (existing != null) {
      if (!identical(existing._messages, subagent['messages'])) {
        existing._messages = childMessages;
      }
      return existing;
    }
    final child = StreamProcessor(StreamProcessorOptions(
      subagentRunId: childId,
      initialMessages: childMessages,
      events: StreamProcessorEvents(
        onToolCall: events.onToolCall,
        onApprovalRequest: events.onApprovalRequest,
        onCustomEvent: events.onCustomEvent,
      ),
    ));
    _childProcessors[childId] = child;
    return child;
  }

  void _updateChild(
    String childId,
    void Function(StreamProcessor child) update,
  ) {
    final child = _childProcessor(childId);
    if (child == null) return;
    update(child);
    final messages = child.getMessages();
    _patchSubagent(childId, (subagent) {
      subagent['messages'] = messages;
    });
  }

  void _handleSubagentStarted(Map<String, dynamic> chunk) {
    final childId = chunk['subagentRunId'] as String;
    final existing = _findSubagentPart(childId);
    if (existing != null) {
      _childProcessors.remove(childId);
      _patchSubagent(childId, (subagent) {
        subagent['status'] = 'running';
        subagent.remove('interruptIds');
        subagent.remove('error');
        if (chunk['metadata'] != null) {
          subagent['metadata'] = chunk['metadata'];
        }
      });
      return;
    }
    final result = _ensureAssistantMessage(null);
    final part = <String, dynamic>{
      'type': 'subagent',
      'subagent': <String, dynamic>{
        'id': childId,
        'name': chunk['name'],
        if (chunk['description'] != null) 'description': chunk['description'],
        'status': 'running',
        if (chunk['parentSubagentRunId'] != null)
          'parentSubagentRunId': chunk['parentSubagentRunId'],
        if (chunk['parentToolCallId'] != null)
          'parentToolCallId': chunk['parentToolCallId'],
        if (chunk['metadata'] != null) 'metadata': chunk['metadata'],
        'messages': <Map<String, dynamic>>[],
      },
    };
    _messages = _messages.map((message) {
      if (message['id'] != result.messageId) return message;
      return <String, dynamic>{
        ...message,
        'parts': <dynamic>[...message['parts'] as List, part],
      };
    }).toList();
    _emitMessagesChange();
  }

  void _handleSubagentFinished(Map<String, dynamic> chunk) {
    final childId = chunk['subagentRunId'] as String;
    _updateChild(childId, (child) => child.finalizeStream());
    _patchSubagent(childId, (subagent) {
      if (subagent['status'] == 'error') return;
      final outcome = chunk['outcome'];
      if (outcome is Map && outcome['type'] == 'suspended') {
        subagent['status'] = 'suspended';
        subagent['interruptIds'] = outcome['interruptIds'] ?? <String>[];
        return;
      }
      subagent['status'] = 'finished';
    });
  }

  void _handleSubagentError(Map<String, dynamic> chunk) {
    final childId = chunk['subagentRunId'] as String;
    _updateChild(childId, (child) => child.finalizeStream());
    _patchSubagent(childId, (subagent) {
      subagent['status'] = 'error';
      subagent['error'] = <String, dynamic>{
        'message': chunk['message'],
        if (chunk['code'] != null) 'code': chunk['code'],
      };
    });
  }

  void _patchSubagent(
    String childId,
    void Function(Map<String, dynamic> subagent) patch,
  ) {
    _messages = _messages.map((message) {
      final parts = <dynamic>[...message['parts'] as List];
      var index = -1;
      for (var i = 0; i < parts.length; i++) {
        final part = parts[i];
        if (part is Map &&
            part['type'] == 'subagent' &&
            part['subagent']['id'] == childId) {
          index = i;
          break;
        }
      }
      if (index == -1) return message;
      final part = (parts[index] as Map).cast<String, dynamic>();
      final subagent = <String, dynamic>{
        ...(part['subagent'] as Map).cast<String, dynamic>(),
      };
      patch(subagent);
      parts[index] = <String, dynamic>{
        'type': 'subagent',
        'subagent': subagent
      };
      return <String, dynamic>{...message, 'parts': parts};
    }).toList();
    _emitMessagesChange();
  }

  bool _routeToChild(Map<String, dynamic> chunk) {
    String? id;
    if (chunk['type'] == 'SUBAGENT_STARTED') {
      id = chunk['parentSubagentRunId'] as String?;
    } else if (chunk['type'] == 'SUBAGENT_FINISHED' ||
        chunk['type'] == 'SUBAGENT_ERROR') {
      if (_findSubagentPart(chunk['subagentRunId'] as String) != null) {
        return false;
      }
      id = chunk['subagentRunId'] as String?;
    } else if (chunk['subagentRunId'] is String &&
        (chunk['subagentRunId'] as String).isNotEmpty) {
      id = chunk['subagentRunId'] as String;
    } else if (chunk['toolCallId'] is String) {
      id = _childToolCalls[chunk['toolCallId']];
    } else {
      id = _childContinuing(chunk);
    }
    if (id == null) return false;
    final owner = _childOwning(id);
    if (owner == null) {
      if (id == subagentRunId) return false;
      _warn('Dropped a chunk for unknown subagent $id');
      return true;
    }
    if (_findSubagentPart(owner)?['subagent']['status'] == 'error') {
      return true;
    }
    if ((chunk['type'] == 'TOOL_CALL_START' ||
            chunk['type'] == 'TOOL_CALL_CHUNK') &&
        chunk['toolCallId'] != null) {
      _childToolCalls[chunk['toolCallId'] as String] = owner;
    }
    _updateChild(owner, (child) => child.processChunk(chunk));
    return true;
  }

  void _renameMessage(String fromId, String toId) {
    _messages = _messages.map((message) {
      if (message['id'] != fromId) return message;
      return <String, dynamic>{...message, 'id': toId};
    }).toList();
    final state = _messageStates.remove(fromId);
    if (state != null) {
      state.id = toId;
      _messageStates[toId] = state;
    }
    _activeMessageIds.remove(fromId);
    _activeMessageIds.add(toId);
    final remappedToolCalls = <String, String>{};
    _toolCallToMessage.forEach((toolCallId, messageId) {
      remappedToolCalls[toolCallId] = messageId == fromId ? toId : messageId;
    });
    _toolCallToMessage
      ..clear()
      ..addAll(remappedToolCalls);
    if (_structuredMessageIds.remove(fromId)) {
      _structuredMessageIds.add(toId);
    }
    final batch = _structuredOutputUpdateBatches.remove(fromId);
    if (batch != null) _structuredOutputUpdateBatches[toId] = batch;
    for (final ids in _callMessageIds.values) {
      if (ids.remove(fromId)) ids.add(toId);
    }
    if (_unassignedCallMessageIds.remove(fromId)) {
      _unassignedCallMessageIds.add(toId);
    }
    if (_sealedMessageIds.remove(fromId)) _sealedMessageIds.add(toId);
    _thinkingOwners.forEach((key, owner) {
      if (owner.messageId == fromId) {
        _thinkingOwners[key] = _ThinkingOwner(toId, owner.stepId);
      }
    });
  }

  void _handleTextMessageStart(Map<String, dynamic> chunk) {
    final messageId = chunk['messageId'] as String;
    if (_messages.any(
      (message) => message['id'] == messageId && message['role'] == 'activity',
    )) {
      _warn("TEXT_MESSAGE_START: Dropped text for '$messageId'");
      return;
    }
    final role = chunk['role'];
    final uiRole =
        role == 'user' || role == 'system' ? role as String : 'assistant';

    final pendingId = _pendingManualMessageId;
    final pendingRun = pendingId == null ? null : _runOfMessage(pendingId);
    final targetRun = _runOfMessage(messageId);
    final separateRuns =
        pendingRun != null && targetRun != null && pendingRun != targetRun;
    if (pendingId != null && !separateRuns) {
      _pendingManualMessageId = null;
      _legacyManualMessage = false;
      if (pendingId != messageId) _renameMessage(pendingId, messageId);
      var pendingState = _messageStates[messageId];
      if (pendingState == null) {
        pendingState = _createMessageState(messageId, uiRole);
        _activeMessageIds.add(messageId);
      } else if (pendingState.hasToolCallsSinceTextStart) {
        if (pendingState.currentSegmentText != pendingState.lastEmittedText) {
          _emitTextUpdateForMessage(messageId);
        }
        pendingState.currentSegmentText = '';
        pendingState.lastEmittedText = '';
        pendingState.hasToolCallsSinceTextStart = false;
      }
      _applySenderName(messageId, chunk['name'] as String?);
      _mergeMessageMetadata(messageId, chunk['metadata']);
      _emitMessagesChange();
      return;
    }

    Map<String, dynamic>? existing;
    for (final message in _messages) {
      if (message['id'] == messageId) {
        existing = message;
        break;
      }
    }
    if (existing != null) {
      _activeMessageIds.add(messageId);
      final state =
          _messageStates[messageId] ?? _createMessageState(messageId, uiRole);
      if (state.hasToolCallsSinceTextStart) {
        if (state.currentSegmentText != state.lastEmittedText) {
          _emitTextUpdateForMessage(messageId);
        }
        state.currentSegmentText = '';
        state.lastEmittedText = '';
        state.hasToolCallsSinceTextStart = false;
      }
      _applySenderName(messageId, chunk['name'] as String?);
      _mergeMessageMetadata(messageId, chunk['metadata']);
      return;
    }

    _messages = <Map<String, dynamic>>[
      ..._messages,
      <String, dynamic>{
        'id': messageId,
        'role': uiRole,
        'parts': <Map<String, dynamic>>[],
        'createdAt': DateTime.now(),
      },
    ];
    _createMessageState(messageId, uiRole);
    _activeMessageIds.add(messageId);
    _applySenderName(messageId, chunk['name'] as String?);
    _mergeMessageMetadata(messageId, chunk['metadata']);
    events.onStreamStart?.call();
    _emitMessagesChange();
  }

  void _applySenderName(String messageId, String? name) {
    if (name == null) return;
    _messages = _messages.map((message) {
      if (message['id'] != messageId) return message;
      return <String, dynamic>{...message, 'name': name};
    }).toList();
  }

  void _handleTextMessageEnd(Map<String, dynamic> chunk) {
    final messageId = chunk['messageId'] as String;
    _mergeMessageMetadata(messageId, chunk['metadata']);
    final state = _getMessageState(messageId);
    if (state == null || state.isComplete) return;
    if (state.currentSegmentText != state.lastEmittedText) {
      _emitTextUpdateForMessage(messageId);
    }
  }

  void _handleMessagesSnapshot(Map<String, dynamic> chunk) {
    _resetStreamState();
    final prevMessages = _messages;
    final prevById = <String, Map<String, dynamic>>{
      for (final message in prevMessages) message['id'] as String: message,
    };
    final rawMessages = (chunk['messages'] as List?) ?? <dynamic>[];
    final split = splitSubagentWire(rawMessages);
    final normalized = _mergeReasoningFanOut(
      split.top.map(aguiSnapshotMessageToUIMessage).toList(),
    );
    final reconciled = _reconcileSnapshotToolCalls(
      normalized,
      prevMessages,
    ).map((message) {
      if (message['metadata'] != null) return message;
      final prev = prevById[message['id']];
      if (prev?['metadata'] == null) return message;
      return <String, dynamic>{...message, 'metadata': prev!['metadata']};
    }).toList();
    _messages = _mergeOmittedActivity(
      prevMessages,
      _attachSnapshotSubagents(
        reconciled,
        split.top,
        split.groups,
        prevMessages,
      ),
    );
    _emitMessagesChange();
  }

  List<Map<String, dynamic>> _mergeOmittedActivity(
    List<Map<String, dynamic>> prevMessages,
    List<Map<String, dynamic>> snapshot,
  ) {
    final snapshotIds = snapshot.map((message) => message['id']).toSet();
    final omitted = prevMessages
        .where((message) =>
            message['role'] == 'activity' &&
            !snapshotIds.contains(message['id']))
        .toList();
    if (omitted.isEmpty) return snapshot;
    final out = <Map<String, dynamic>>[...snapshot];
    for (final activity in omitted) {
      final prevIndex =
          prevMessages.indexWhere((message) => message['id'] == activity['id']);
      out.insert(prevIndex.clamp(0, out.length), activity);
    }
    return out;
  }

  List<Map<String, dynamic>> _attachSnapshotSubagents(
    List<Map<String, dynamic>> messages,
    List<dynamic> top,
    List<SubagentWireGroup> groups,
    List<Map<String, dynamic>> prevMessages,
  ) {
    final cards = <_SubagentCard>[];
    final children = <String, StreamProcessor>{};
    for (final group in groups) {
      final child = StreamProcessor(StreamProcessorOptions(
        subagentRunId: group.id,
      ));
      child.processChunk(<String, dynamic>{
        'type': 'MESSAGES_SNAPSHOT',
        'messages': group.messages,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      children[group.id] = child;
      String? hostId;
      for (var i = group.hostIndex; i >= 0 && i < top.length; i--) {
        final message = top[i];
        if (message is Map && message['role'] == 'assistant') {
          hostId = message['id'] as String?;
          break;
        }
      }
      cards.add(_SubagentCard(
        hostId: hostId,
        part: <String, dynamic>{
          'type': 'subagent',
          'subagent': <String, dynamic>{
            ...group.info,
            'id': group.id,
            'messages': child.getMessages(),
          },
        },
      ));
    }
    final inSnapshot = groups.map((group) => group.id).toSet();
    for (final message in prevMessages) {
      for (final raw in message['parts'] as List) {
        if (raw is! Map || raw['type'] != 'subagent') continue;
        final subagent = raw['subagent'] as Map;
        if (inSnapshot.contains(subagent['id'])) continue;
        cards.add(_SubagentCard(
          hostId: message['id'] as String?,
          toolCallId: subagent['parentToolCallId'] as String?,
          part: raw.cast<String, dynamic>(),
          carried: true,
        ));
        final kept = _childProcessors[subagent['id']];
        if (kept != null) children[subagent['id'] as String] = kept;
      }
    }
    _childProcessors
      ..clear()
      ..addAll(children);

    var out = messages;
    for (final card in cards) {
      var index = out.indexWhere((message) => message['id'] == card.hostId);
      if (index == -1 && card.toolCallId != null) {
        index = out.indexWhere(
          (message) => (message['parts'] as List).any(
            (part) =>
                part is Map &&
                part['type'] == 'tool-call' &&
                part['id'] == card.toolCallId,
          ),
        );
      }
      if (index == -1 && !card.carried) {
        for (var i = out.length - 1; i >= 0; i--) {
          if (out[i]['role'] == 'assistant') {
            index = i;
            break;
          }
        }
      }
      if (index == -1) {
        if (!card.carried) {
          out = <Map<String, dynamic>>[
            ...out,
            <String, dynamic>{
              'id': generateMessageId(),
              'role': 'assistant',
              'parts': <dynamic>[card.part],
            },
          ];
        }
        continue;
      }
      out = <Map<String, dynamic>>[
        for (var i = 0; i < out.length; i++)
          if (i != index ||
              (out[i]['parts'] as List).any(
                (part) =>
                    part is Map &&
                    part['type'] == 'subagent' &&
                    part['subagent']['id'] == card.part['subagent']['id'],
              ))
            out[i]
          else
            <String, dynamic>{
              ...out[i],
              'parts': <dynamic>[...out[i]['parts'] as List, card.part],
            },
      ];
    }
    return out;
  }

  List<Map<String, dynamic>> _mergeReasoningFanOut(
    List<Map<String, dynamic>> messages,
  ) {
    final out = <Map<String, dynamic>>[];
    var pending = <Map<String, dynamic>>[];
    List<Map<String, dynamic>> thinkingParts(Map<String, dynamic> message) =>
        (message['parts'] as List)
            .whereType<Map>()
            .where((part) => part['type'] == 'thinking')
            .map((part) => part.cast<String, dynamic>())
            .toList();
    bool isThinkingOnly(Map<String, dynamic> message) =>
        message['role'] == 'assistant' &&
        (message['parts'] as List).isNotEmpty &&
        (message['parts'] as List)
            .every((part) => part is Map && part['type'] == 'thinking');
    bool isToolResultOnly(Map<String, dynamic> message) =>
        message['role'] == 'assistant' &&
        (message['parts'] as List)
            .any((part) => part is Map && part['type'] == 'tool-result') &&
        (message['parts'] as List).every(
          (part) =>
              part is Map &&
              (part['type'] == 'tool-result' || part['type'] == 'ui-resource'),
        );
    void flushPending() {
      out.addAll(pending);
      pending = <Map<String, dynamic>>[];
    }

    for (final message in messages) {
      if (isThinkingOnly(message)) {
        pending.add(message);
        continue;
      }
      var next = message;
      if (message['role'] == 'assistant' &&
          pending.isNotEmpty &&
          !isToolResultOnly(message)) {
        next = <String, dynamic>{
          ...message,
          'parts': <dynamic>[
            ...pending.expand(thinkingParts),
            ...message['parts'] as List,
          ],
        };
        pending = <Map<String, dynamic>>[];
      } else {
        flushPending();
      }
      var parentIndex = out.length - 1;
      while (parentIndex >= 0) {
        if (!isToolResultOnly(out[parentIndex])) break;
        parentIndex--;
      }
      final parent = parentIndex >= 0 ? out[parentIndex] : null;
      if (parent != null &&
          parent['role'] == 'assistant' &&
          next['role'] == 'assistant' &&
          isAssistantSegmentOf(next['id'] as String?, parent['id'] as String)) {
        final folded = out
            .sublist(parentIndex)
            .expand((message) => message['parts'] as List)
            .toList();
        out
          ..removeRange(parentIndex, out.length)
          ..add(<String, dynamic>{
            ...parent,
            'parts': <dynamic>[...folded, ...next['parts'] as List],
          });
        continue;
      }
      out.add(next);
    }
    flushPending();
    return out;
  }

  List<Map<String, dynamic>> _reconcileSnapshotToolCalls(
    List<Map<String, dynamic>> snapshot,
    List<Map<String, dynamic>> prevMessages,
  ) {
    final prevToolCalls = <String, Map<String, dynamic>>{};
    for (final message in prevMessages) {
      for (final raw in message['parts'] as List) {
        if (raw is Map && raw['type'] == 'tool-call') {
          prevToolCalls[raw['id'] as String] = raw.cast<String, dynamic>();
        }
      }
    }
    final snapshotToolCallIds = <String>{};
    for (final message in snapshot) {
      for (final raw in message['parts'] as List) {
        if (raw is Map && raw['type'] == 'tool-call') {
          snapshotToolCallIds.add(raw['id'] as String);
        }
      }
    }

    final reconciled = <Map<String, dynamic>>[];
    for (final message in snapshot) {
      final parts = message['parts'] as List;
      final resultParts = parts
          .whereType<Map>()
          .where((part) => part['type'] == 'tool-result')
          .map((part) => part.cast<String, dynamic>())
          .toList();
      Map<String, dynamic>? resultPart;
      if (message['role'] == 'assistant' &&
          resultParts.length == 1 &&
          parts.every(
            (part) =>
                part is Map &&
                (part['type'] == 'tool-result' ||
                    part['type'] == 'ui-resource'),
          )) {
        resultPart = resultParts.first;
      }
      if (resultPart == null) {
        reconciled.add(message);
        continue;
      }

      Map<String, dynamic>? target;
      for (final candidate in reconciled.reversed) {
        if ((candidate['parts'] as List).any(
          (part) =>
              part is Map &&
              part['type'] == 'tool-call' &&
              part['id'] == resultPart!['toolCallId'],
        )) {
          target = candidate;
          break;
        }
      }
      target ??= () {
        for (final candidate in reconciled.reversed) {
          if (candidate['role'] == 'assistant' &&
              !((candidate['parts'] as List).length == 1 &&
                  (candidate['parts'] as List)[0] is Map &&
                  (candidate['parts'] as List)[0]['type'] == 'tool-result')) {
            return candidate;
          }
        }
        return null;
      }();

      if (target == null) {
        if (!snapshotToolCallIds.contains(resultPart['toolCallId'])) {
          _warn(
            'MESSAGES_SNAPSHOT contains a tool-result for '
            '"${resultPart['toolCallId']}" but no matching tool-call exists '
            'in the snapshot, and there is no assistant message to anchor '
            'into; addToolResult("${resultPart['toolCallId']}") will not be '
            'able to locate this call',
          );
        }
        reconciled.add(message);
        continue;
      }

      final targetParts = <dynamic>[...target['parts'] as List];
      final toolCallId = resultPart['toolCallId'] as String;
      if (!snapshotToolCallIds.contains(toolCallId) &&
          !targetParts.any(
            (part) =>
                part is Map &&
                part['type'] == 'tool-call' &&
                part['id'] == toolCallId,
          )) {
        final prev = prevToolCalls[toolCallId];
        if (prev != null) {
          targetParts.add(<String, dynamic>{...prev});
          snapshotToolCallIds.add(toolCallId);
        } else {
          _warn(
            'MESSAGES_SNAPSHOT contains a tool-result for "$toolCallId" '
            'but no matching tool-call exists in the snapshot or pre-snapshot',
          );
        }
      }
      targetParts.addAll(parts);
      target['parts'] = targetParts;
    }

    return _enrichSnapshotToolCallsFromResults(reconciled, prevToolCalls);
  }

  List<Map<String, dynamic>> _enrichSnapshotToolCallsFromResults(
    List<Map<String, dynamic>> messages,
    Map<String, Map<String, dynamic>> prevToolCalls,
  ) {
    final resultsByCallId = <String, Map<String, dynamic>>{};
    for (final message in messages) {
      for (final raw in message['parts'] as List) {
        if (raw is Map && raw['type'] == 'tool-result') {
          resultsByCallId[raw['toolCallId'] as String] =
              raw.cast<String, dynamic>();
        }
      }
    }
    return messages.map((message) {
      final parts = <dynamic>[];
      var changed = false;
      for (final raw in message['parts'] as List) {
        if (raw is! Map || raw['type'] != 'tool-call') {
          parts.add(raw);
          continue;
        }
        final part = raw.cast<String, dynamic>();
        final prev = prevToolCalls[part['id']];
        final result = resultsByCallId[part['id']];
        var next = <String, dynamic>{...part};

        if (prev != null &&
            (prev['output'] != null ||
                prev['state'] == 'complete' ||
                prev['state'] == 'error') &&
            (next['output'] == null ||
                <String?>[
                  'input-complete',
                  'input-streaming',
                  'awaiting-input',
                ].contains(next['state']))) {
          next = <String, dynamic>{
            ...next,
            if (prev['output'] != null) 'output': prev['output'],
            'state': prev['state'],
            if (prev['approval'] != null) 'approval': prev['approval'],
            if (prev['metadata'] != null) 'metadata': prev['metadata'],
          };
        }

        if (result != null && next['output'] == null) {
          dynamic output;
          final content = result['content'];
          if (content is List) {
            output = content;
          } else {
            try {
              output = jsonDecode(content as String);
            } catch (_) {
              output = content;
            }
          }
          final errorText =
              result['state'] == 'error' ? toolResultErrorText(output) : null;
          next = <String, dynamic>{
            ...next,
            'output': errorText != null
                ? <String, dynamic>{'error': errorText}
                : output,
            'state': result['state'] == 'error' ? 'error' : 'complete',
          };
        }
        if (!identical(next, part)) changed = true;
        parts.add(next);
      }
      return changed ? <String, dynamic>{...message, 'parts': parts} : message;
    }).toList();
  }

  void _handleTextMessageContent(Map<String, dynamic> chunk) {
    final messageId = chunk['messageId'] as String;
    if (_messages.any(
      (message) => message['id'] == messageId && message['role'] == 'activity',
    )) {
      _warn("TEXT_MESSAGE_CONTENT: Dropped text for '$messageId'");
      return;
    }
    final preferredId = _legacyManualMessage && _pendingManualMessageId != null
        ? _pendingManualMessageId
        : messageId;
    final result = _ensureAssistantMessage(preferredId);
    final id = result.messageId;
    final state = result.state;
    _mergeMessageMetadata(id, chunk['metadata']);

    if (_structuredMessageIds.contains(id)) {
      final delta = _string(chunk['delta']);
      if (delta.isNotEmpty) {
        _messages = _appendStructuredOutputDelta(_messages, id, delta);
        state.totalTextContent += delta;
        _queueStructuredOutputUpdate(id, delta);
        _emitMessagesChange();
      }
      return;
    }

    final previousSegment = state.currentSegmentText;
    if (state.hasToolCallsSinceTextStart && previousSegment.isNotEmpty) {
      if (previousSegment != state.lastEmittedText) {
        _emitTextUpdateForMessage(id);
      }
      state.currentSegmentText = '';
      state.lastEmittedText = '';
      state.hasToolCallsSinceTextStart = false;
    }
    state.hasToolCallsSinceTextStart = false;

    final currentText = state.currentSegmentText;
    final delta = _string(chunk['delta']);
    final nextText = delta.isNotEmpty ? currentText + delta : currentText;
    state.currentSegmentText = nextText;
    state.totalTextContent += nextText.substring(currentText.length);

    final shouldEmit =
        chunkStrategy.shouldEmit(delta, state.currentSegmentText);
    if (shouldEmit && state.currentSegmentText != state.lastEmittedText) {
      _emitTextUpdateForMessage(id);
    }
  }

  void _handleToolCallStart(Map<String, dynamic> chunk) {
    final pendingId = _pendingManualMessageId;
    final parentId = chunk['parentMessageId'] as String?;
    if (pendingId != null && parentId != null && parentId != pendingId) {
      final parent = _messageById(_messages, parentId);
      final placeholder = _messageById(_messages, pendingId);
      final pendingRun = _runOfMessage(pendingId);
      final parentRun = parent == null ? null : _runOfMessage(parentId);
      final separateRuns =
          pendingRun != null && parentRun != null && pendingRun != parentRun;
      if (parent == null) {
        _pendingManualMessageId = null;
        _renameMessage(pendingId, parentId);
      } else if (!separateRuns &&
          parent['role'] == 'assistant' &&
          placeholder != null) {
        _pendingManualMessageId = null;
        _messages = _messages
            .where((message) => message['id'] != pendingId)
            .map((message) {
          if (message['id'] != parentId) return message;
          return <String, dynamic>{
            ...message,
            'parts': <dynamic>[
              ...message['parts'] as List,
              ...placeholder['parts'] as List,
            ],
          };
        }).toList();
        _renameMessage(pendingId, parentId);
      }
    }

    final targetMessageId = parentId ?? _getActiveAssistantMessageId();
    final result = _ensureAssistantMessage(
      targetMessageId,
      fallbackToActive: parentId == null,
    );
    final messageId = result.messageId;
    final state = result.state;
    final tanstack = tanstackMetadata(chunk);
    _mergeMessageMetadata(
      messageId,
      tanstack == null ? null : <String, dynamic>{'tanstack': tanstack},
    );
    state.hasToolCallsSinceTextStart = true;

    final toolCallId = chunk['toolCallId'] as String;
    if (state.toolCalls.containsKey(toolCallId)) return;

    final initialState = ToolCallState.awaitingInput;
    final toolName = _string(chunk['toolCallName']);
    final chunkMetadata = chunk['metadata'] is Map
        ? (chunk['metadata'] as Map).cast<String, dynamic>()
        : null;
    final toolCall = InternalToolCallState(
      id: toolCallId,
      name: toolName,
      index: state.toolCalls.length,
      metadata: chunkMetadata,
    );
    state.toolCalls[toolCallId] = toolCall;
    state.toolCallOrder.add(toolCallId);
    _runToolCallIds.add(toolCallId);
    _toolCallToMessage[toolCallId] = messageId;

    _messages = _updateToolCallPart(_messages, messageId, <String, dynamic>{
      'id': toolCallId,
      'name': toolName,
      'arguments': '',
      'state': initialState,
      if (chunkMetadata != null) 'metadata': chunkMetadata,
    });
    _emitMessagesChange();
    events.onToolCallStateChange?.call(messageId, toolCallId, initialState, '');
  }

  void _handleToolCallArgs(Map<String, dynamic> chunk) {
    final toolCallId = chunk['toolCallId'] as String;
    final messageId = _toolCallToMessage[toolCallId];
    if (messageId == null) return;
    final state = _getMessageState(messageId);
    if (state == null) return;
    final toolCall = state.toolCalls[toolCallId];
    if (toolCall == null) return;

    final wasAwaitingInput = toolCall.state == ToolCallState.awaitingInput;
    if (chunk['metadata'] != null) {
      toolCall.metadata = mergeMetadata(toolCall.metadata, chunk['metadata']);
    }
    final delta = _string(chunk['delta']);
    toolCall.arguments += delta;
    if (wasAwaitingInput && delta.isNotEmpty) {
      toolCall.state = ToolCallState.inputStreaming;
    }
    toolCall.parsedArguments = jsonParser.parse(toolCall.arguments);

    _messages = _updateToolCallPart(_messages, messageId, <String, dynamic>{
      'id': toolCall.id,
      'name': toolCall.name,
      'arguments': toolCall.arguments,
      'state': toolCall.state,
      if (toolCall.metadata != null) 'metadata': toolCall.metadata,
    });
    _emitMessagesChange();
    events.onToolCallStateChange?.call(
      messageId,
      toolCall.id,
      toolCall.state,
      toolCall.arguments,
    );
  }

  void _handleToolCallEnd(Map<String, dynamic> chunk) {
    final toolCallId = chunk['toolCallId'] as String;
    final messageId = _toolCallToMessage[toolCallId];
    if (messageId == null) return;
    final state = _getMessageState(messageId);
    if (state == null) return;
    final toolCall = state.toolCalls[toolCallId];
    if (toolCall == null || toolCall.state == ToolCallState.inputComplete) {
      return;
    }
    final finished = _finishToolCallArguments(toolCall.arguments, chunk);
    toolCall.arguments = finished.args;
    final index = state.toolCallOrder.indexOf(toolCallId);
    _completeToolCall(messageId, index, toolCall);
  }

  void _handleToolCallResult(Map<String, dynamic> chunk) {
    final toolCallId = chunk['toolCallId'] as String;
    String? messageId = _toolCallToMessage[toolCallId];
    if (messageId == null) {
      for (final message in _messages) {
        if ((message['parts'] as List).any(
          (part) =>
              part is Map &&
              part['type'] == 'tool-call' &&
              part['id'] == toolCallId,
        )) {
          messageId = message['id'] as String;
          break;
        }
      }
    }
    if (messageId == null) return;

    final rawOutcome = tanstackMetadata(chunk)?['toolResultOutcome'];
    final outcome = isToolResultOutcome(rawOutcome) ? rawOutcome : null;
    final isOutputError = chunk['state'] == 'output-error' ||
        tanstackMetadata(chunk)?['state'] == 'output-error' ||
        outcome != null;

    dynamic output;
    final content = chunk['content'];
    try {
      output = content is String ? jsonDecode(content) : content;
    } catch (_) {
      output = content;
    }
    _messages = _updateToolCallWithOutput(
      _messages,
      toolCallId,
      output,
      isOutputError ? ToolCallState.error : null,
    );
    final resultState =
        isOutputError ? ToolResultState.error : ToolResultState.complete;
    _messages = _updateToolResultPart(
      _messages,
      messageId,
      toolCallId,
      isContentPartArray(output) ? output : aguiContentToContentParts(content),
      resultState,
      error: resultState == ToolResultState.error
          ? toolResultErrorText(output)
          : null,
      outcome: outcome,
    );
    _emitMessagesChange();
  }

  void _handleRunStarted(Map<String, dynamic> chunk) {
    if (_activeRuns.isEmpty) {
      _runToolCallIds = <String>[];
      _toolCallsSentToClient.clear();
      _streamEndEmitted = false;
    }
    if (chunk['runId'] is String) _activeRuns.add(chunk['runId'] as String);
  }

  void _handleRunFinished(Map<String, dynamic> chunk) {
    final incoming = tanstackMetadata(chunk);
    final model = chunk['model'] ?? incoming?['model'];
    final responseId = chunk['responseId'] ?? incoming?['responseId'];
    final runId = chunk['runId'] as String? ??
        (_activeRuns.isEmpty ? '' : _activeRuns.last);
    final ids = _callMessageIds[runId] ??
        (_activeRuns.contains(runId)
            ? <String>{}
            : <String>{..._unassignedCallMessageIds});
    for (final messageId in ids) {
      _mergeMessageMetadata(
        messageId,
        withTanstackMetadata(chunk, <String, dynamic>{
          if (model != null) 'model': model,
          if (responseId != null) 'responseId': responseId,
        })['metadata'],
      );
    }
    if (_pendingManualMessageId != null &&
        ids.contains(_pendingManualMessageId)) {
      _pendingManualMessageId = null;
      _legacyManualMessage = false;
    }
    _callMessageIds.remove(runId);
    for (final id in ids) {
      _unassignedCallMessageIds.remove(id);
    }
    _finishReason = chunk['finishReason'] ??
        tanstackMetadata(chunk)?['finishReason'] as String?;
    _activeRuns.remove(runId);

    final outcome = chunk['outcome'];
    if (outcome is Map && outcome['type'] == 'interrupt') {
      _handleInterrupts((outcome['interrupts'] as List?) ?? <dynamic>[]);
    }

    if (_activeRuns.isEmpty) {
      _completeAllToolCalls();
      final isIntermediateToolTurn = _finishReason == 'tool_calls' &&
          !(outcome is Map && outcome['type'] == 'interrupt');
      if (isIntermediateToolTurn) {
        _sealedMessageIds.addAll(ids);
        return;
      }
      if (outcome == null || (outcome is Map && outcome['type'] == 'success')) {
        _handlePendingToolCalls(
          outcome is Map ? (outcome['pendingToolCallIds'] as List?) : null,
        );
      }
      _isDone = true;
      finalizeStream();
    }
  }

  void _handlePendingToolCalls(List<dynamic>? pendingToolCallIds) {
    final ids = pendingToolCallIds != null && pendingToolCallIds.isNotEmpty
        ? pendingToolCallIds
            .whereType<String>()
            .where(_runToolCallIds.contains)
            .toList()
        : _runToolCallIds;
    final parts = <Map<String, dynamic>>[
      for (final message in _messages)
        for (final raw in message['parts'] as List)
          if (raw is Map) raw.cast<String, dynamic>(),
    ];
    for (final toolCallId in ids) {
      if (_toolCallsSentToClient.contains(toolCallId)) continue;
      Map<String, dynamic>? part;
      for (final candidate in parts) {
        if (candidate['type'] == 'tool-call' && candidate['id'] == toolCallId) {
          part = candidate;
          break;
        }
      }
      if (part == null ||
          isProviderExecutedToolCall(part) ||
          part['output'] != null ||
          parts.any((candidate) =>
              candidate['type'] == 'tool-result' &&
              candidate['toolCallId'] == toolCallId) ||
          _isToolCallPartTerminal(toolCallId) ||
          _isToolCallPartAwaitingUserAction(toolCallId)) {
        continue;
      }
      if (_finishReason == 'length') continue;
      final input =
          part['input'] ?? _parseToolArguments(_string(part['arguments']));
      if (input == null) {
        _warn(
          'Did not run tool call $toolCallId: the arguments of '
          '${part['name']} are not complete JSON',
        );
        continue;
      }
      _toolCallsSentToClient.add(toolCallId);
      events.onToolCall?.call(<String, dynamic>{
        'toolCallId': toolCallId,
        'toolName': part['name'],
        'input': input,
      });
    }
  }

  void _handleInterrupts(List<dynamic> interrupts, {bool emit = true}) {
    final hasGeneric = interrupts.any((raw) {
      if (raw is! Map) return false;
      final metadata = raw['metadata'];
      return metadata is Map &&
          metadata[interruptBindingMetadataKey] is Map &&
          metadata[interruptBindingMetadataKey]['kind'] == 'generic';
    });
    for (final raw in interrupts) {
      if (raw is! Map) continue;
      final interrupt = raw.cast<String, dynamic>();
      final metadata = interrupt['metadata'] is Map
          ? (interrupt['metadata'] as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      final kind =
          metadata['kind'] is String ? metadata['kind'] as String : null;
      final toolCallId = interrupt['toolCallId'] as String?;
      if (toolCallId == null) continue;

      final owner = interrupt['subagentRunId'] != null
          ? _childOwning(interrupt['subagentRunId'] as String)
          : _childOwningToolCall((part) => part['id'] == toolCallId);
      if (owner != null) {
        _updateChild(owner, (child) {
          child._handleInterrupts(<dynamic>[interrupt], emit: false);
        });
      }

      final toolName = metadata['toolName'] is String
          ? metadata['toolName'] as String
          : _findToolCallName(toolCallId);
      final input = metadata.containsKey('input')
          ? metadata['input']
          : <String, dynamic>{};

      if (kind == 'approval' || interrupt['reason'] == 'approval_required') {
        if (owner != null) {
          if (emit) {
            events.onApprovalRequest?.call(<String, dynamic>{
              'toolCallId': toolCallId,
              'toolName': toolName,
              'input': input,
              'approvalId': interrupt['id'],
            });
          }
          continue;
        }
        final resolvedMessageId = _getActiveAssistantMessageId() ??
            _toolCallToMessage[toolCallId] ??
            _findAssistantOwningToolCall(toolCallId);
        if (resolvedMessageId != null) {
          _messages = _updateToolCallApproval(
            _messages,
            resolvedMessageId,
            toolCallId,
            interrupt['id'] as String,
          );
          _emitMessagesChange();
        }
        if (!emit) continue;
        events.onApprovalRequest?.call(<String, dynamic>{
          'toolCallId': toolCallId,
          'toolName': toolName,
          'input': input,
          'approvalId': interrupt['id'],
        });
        continue;
      }

      if (kind == 'client_tool' || interrupt['reason'] == 'client_tool_input') {
        if (hasGeneric || !emit) continue;
        _toolCallsSentToClient.add(toolCallId);
        events.onToolCall?.call(<String, dynamic>{
          'toolCallId': toolCallId,
          'toolName': toolName,
          'input': input,
        });
      }
    }
  }

  String? _findAssistantOwningToolCall(String toolCallId) {
    for (final message in _messages.reversed) {
      if (message['role'] == 'assistant' &&
          (message['parts'] as List).any(
            (part) =>
                part is Map &&
                part['type'] == 'tool-call' &&
                part['id'] == toolCallId,
          )) {
        return message['id'] as String;
      }
    }
    return null;
  }

  String _findToolCallName(String toolCallId) {
    for (final state in _messageStates.values) {
      final toolCall = state.toolCalls[toolCallId];
      if (toolCall != null) return toolCall.name;
    }
    return '';
  }

  void _handleRunError(Map<String, dynamic> chunk) {
    _hasError = true;
    final runId = _getChunkRunId(chunk) ??
        (_activeRuns.length == 1 ? _activeRuns.first : null);
    final currentIds = runId != null
        ? (_callMessageIds[runId] ?? _unassignedCallMessageIds)
        : _unassignedCallMessageIds;
    if (runId != null) {
      _activeRuns.remove(runId);
    } else {
      _activeRuns.clear();
    }
    final discardedCall = runId != null &&
        _callMessageIds.containsKey(runId) &&
        currentIds.isEmpty;
    final messageId = discardedCall
        ? null
        : _ensureAssistantMessage(
            currentIds.isNotEmpty ? currentIds.last : generateMessageId(),
            fallbackToActive: false,
          ).messageId;
    final ids = <String>{...currentIds};
    if (messageId != null) ids.add(messageId);
    for (final id in ids) {
      _mergeMessageMetadata(
        id,
        withTanstackMetadata(chunk, <String, dynamic>{
          'stopReason': tanstackMetadata(chunk)?['stopReason'] ?? 'error',
        })['metadata'],
      );
    }
    if (_pendingManualMessageId != null &&
        ids.contains(_pendingManualMessageId)) {
      _pendingManualMessageId = null;
      _legacyManualMessage = false;
    }
    if (runId != null) _callMessageIds.remove(runId);
    for (final id in ids) {
      _unassignedCallMessageIds.remove(id);
    }

    final errorMessage = _string(chunk['message'], 'An error occurred');
    if (messageId != null && _structuredMessageIds.contains(messageId)) {
      _flushStructuredOutputUpdate(messageId);
      _messages = _errorStructuredOutputPart(
        _messages,
        messageId,
        errorMessage,
      );
      _structuredMessageIds.remove(messageId);
      _emitStructuredOutputChange(messageId, 'error');
      _emitMessagesChange();
    }
    final error = <String, Object>{
      'message': errorMessage,
    };
    if (chunk['code'] != null) error['code'] = chunk['code'];
    if (chunk['rawEvent'] != null) error['rawEvent'] = chunk['rawEvent'];
    events.onError?.call(error);
  }

  void _handleStepStarted(Map<String, dynamic> chunk) {
    final stepId = _string(chunk['stepName'], generateMessageId());
    final target = _unscopedAssistant(chunk);
    final activeId = target.create ? null : target.id;
    if (activeId != null) {
      final state = _getMessageState(activeId);
      if (state != null) {
        state.currentThinkingStepId = stepId;
        if (!state.thinkingSteps.containsKey(stepId)) {
          state.thinkingSteps[stepId] = '';
          state.thinkingStepOrder.add(stepId);
        }
        _rememberThinking(activeId, stepId);
        _pendingThinkingStepId = null;
        return;
      }
    }
    _pendingThinkingStepId = stepId;
  }

  void _handleStepFinished(Map<String, dynamic> chunk) {
    final metadataSignature = tanstackMetadata(chunk)?['signature'];
    final signature = chunk['signature'] is String
        ? chunk['signature'] as String
        : metadataSignature is String
            ? metadataSignature
            : null;
    if (signature == null) return;

    final namedStep = (chunk['stepId'] ?? chunk['stepName']) as String?;
    if (_applyKnownSignature(namedStep, signature)) return;

    final target = _unscopedAssistant(chunk);
    final result = _ensureAssistantMessage(
      target.id,
      fallbackToActive: !target.create,
    );
    final stepId = result.state.currentThinkingStepId ?? namedStep;
    if (stepId == null) return;
    _rememberThinking(result.messageId, stepId);
    final thinking = result.state.thinkingSteps[stepId];
    if (thinking == null) return;
    result.state.thinkingStepSignatures[stepId] = signature;
    _messages = _updateThinkingPart(
      _messages,
      result.messageId,
      stepId,
      thinking,
      signature,
    );
    _emitMessagesChange();
  }

  void _handleReasoningContent(Map<String, dynamic> chunk) {
    final target = _unscopedAssistant(chunk);
    final result = _ensureAssistantMessage(
      target.id,
      fallbackToActive: !target.create,
    );
    final messageId = result.messageId;
    final state = result.state;
    _mergeMessageMetadata(messageId, chunk['metadata']);

    state.hasSeenReasoningEvents = true;
    final delta = _string(chunk['delta']);
    _consumePendingThinkingStep(state);
    final stepId = state.currentThinkingStepId ?? chunk['messageId'] as String;
    if (!state.thinkingSteps.containsKey(stepId)) {
      state.thinkingSteps[stepId] = '';
      state.thinkingStepOrder.add(stepId);
      state.currentThinkingStepId = stepId;
    }
    _rememberThinking(messageId, stepId, chunk['messageId'] as String?);
    final nextThinking = (state.thinkingSteps[stepId] ?? '') + delta;
    state.thinkingSteps[stepId] = nextThinking;
    _messages = _updateThinkingPart(
      _messages,
      messageId,
      stepId,
      nextThinking,
      state.thinkingStepSignatures[stepId],
    );
    _emitMessagesChange();
    events.onThinkingUpdate?.call(messageId, stepId, nextThinking);
  }

  void _handleReasoningEncryptedValue(Map<String, dynamic> chunk) {
    final encryptedValue = chunk['encryptedValue'];
    if (encryptedValue is! String || encryptedValue.isEmpty) return;
    if (chunk['subtype'] == 'tool-call') {
      _attachToolCallSignature(chunk['entityId'] as String, encryptedValue);
      return;
    }
    if (_applyKnownSignature(chunk['entityId'] as String?, encryptedValue)) {
      return;
    }
    final target = _unscopedAssistant(chunk);
    final result = _ensureAssistantMessage(
      target.id,
      fallbackToActive: !target.create,
    );
    final stepId =
        result.state.currentThinkingStepId ?? chunk['entityId'] as String;
    _rememberThinking(
      result.messageId,
      stepId,
      chunk['entityId'] as String?,
    );
    _mergeMessageMetadata(result.messageId, chunk['metadata']);
    result.state.thinkingStepSignatures[stepId] = encryptedValue;
    final content = result.state.thinkingSteps[stepId] ?? '';
    if (!result.state.thinkingSteps.containsKey(stepId)) {
      result.state.thinkingSteps[stepId] = content;
      result.state.thinkingStepOrder.add(stepId);
    }
    _messages = _updateThinkingPart(
      _messages,
      result.messageId,
      stepId,
      content,
      encryptedValue,
    );
    _emitMessagesChange();
  }

  void _attachToolCallSignature(String toolCallId, String signature) {
    _messages = _messages.map((message) {
      var changed = false;
      final parts = (message['parts'] as List).map((raw) {
        if (raw is! Map ||
            raw['type'] != 'tool-call' ||
            raw['id'] != toolCallId) {
          return raw;
        }
        changed = true;
        final metadata = raw['metadata'] is Map
            ? <String, dynamic>{
                ...(raw['metadata'] as Map).cast<String, dynamic>()
              }
            : <String, dynamic>{};
        metadata['thoughtSignature'] = signature;
        return <String, dynamic>{
          ...raw.cast<String, dynamic>(),
          'metadata': metadata
        };
      }).toList();
      return changed ? <String, dynamic>{...message, 'parts': parts} : message;
    }).toList();
    for (final state in _messageStates.values) {
      final call = state.toolCalls[toolCallId];
      if (call == null) continue;
      call.metadata = <String, dynamic>{
        ...(call.metadata ?? <String, dynamic>{}),
        'thoughtSignature': signature,
      };
    }
    _emitMessagesChange();
  }

  void _handleCustomEvent(Map<String, dynamic> chunk) {
    final activeMessageId = _getActiveAssistantMessageId();
    final name = chunk['name'];
    final value = chunk['value'];

    if (name == 'structured-output.start' && value != null) {
      final targetId = _string(
        () {
          if (value is Map &&
              value['messageId'] is String &&
              _getMessageState(value['messageId'] as String) != null) {
            return value['messageId'] as String;
          }
          return activeMessageId ??
              (value is Map ? value['messageId'] as String? : null);
        }(),
      );
      final result = _ensureAssistantMessage(
        targetId.isEmpty ? null : targetId,
      );
      _structuredMessageIds.add(result.messageId);
      _structuredOutputUpdateBatches.remove(result.messageId);
      events.onStructuredOutputChange?.call(<String, dynamic>{
        'phase': 'start',
        'messageId': result.messageId,
        'status': 'streaming',
        'raw': '',
      });
      return;
    }

    if (name == 'structured-output.complete' && value is Map) {
      final targetId = _string(
        () {
          if (value['messageId'] is String &&
              _getMessageState(value['messageId'] as String) != null) {
            return value['messageId'] as String;
          }
          return activeMessageId ?? value['messageId'] as String?;
        }(),
      );
      final result = _ensureAssistantMessage(
        targetId.isEmpty ? null : targetId,
      );
      _flushStructuredOutputUpdate(result.messageId);
      _messages = _completeStructuredOutputPart(
        _messages,
        result.messageId,
        value['object'],
        _string(value['raw']),
        value['reasoning'] as String?,
      );
      _structuredMessageIds.remove(result.messageId);
      _emitStructuredOutputChange(result.messageId, 'complete');
      _emitMessagesChange();
    }

    if (name == 'tool-input-available' && value is Map) {
      final toolCallId = value['toolCallId'] as String;
      _toolCallsSentToClient.add(toolCallId);
      events.onToolCall?.call(<String, dynamic>{
        'toolCallId': toolCallId,
        'toolName': value['toolName'],
        'input': value['input'],
      });
      return;
    }

    if (name == 'approval-requested' && value is Map) {
      final toolCallId = value['toolCallId'] as String;
      final approval = (value['approval'] as Map).cast<String, dynamic>();
      final resolvedMessageId =
          activeMessageId ?? _toolCallToMessage[toolCallId];
      if (resolvedMessageId != null) {
        _messages = _updateToolCallApproval(
          _messages,
          resolvedMessageId,
          toolCallId,
          approval['id'] as String,
        );
        _emitMessagesChange();
      }
      events.onApprovalRequest?.call(<String, dynamic>{
        'toolCallId': toolCallId,
        'toolName': value['toolName'],
        'input': value['input'],
        'approvalId': approval['id'],
      });
      return;
    }

    if (name == 'ui-resource' && value is Map) {
      final toolCallId = value['toolCallId'] as String;
      final resolvedMessageId =
          _toolCallToMessage[toolCallId] ?? activeMessageId;
      if (resolvedMessageId != null) {
        final part = <String, dynamic>{
          'type': 'ui-resource',
          'resource': value['resource'],
          'toolCallId': toolCallId,
          'toolName': value['toolName'],
          if (value['serverId'] != null) 'serverId': value['serverId'],
          if (value['meta'] != null) 'meta': value['meta'],
        };
        _messages = _messages.map((message) {
          if (message['id'] != resolvedMessageId) return message;
          return <String, dynamic>{
            ...message,
            'parts': <dynamic>[...message['parts'] as List, part],
          };
        }).toList();
        _emitMessagesChange();
      } else {
        _warn(
          '[mcp-apps] dropped ui-resource: no target message for '
          'toolCallId "$toolCallId"',
        );
      }
      return;
    }

    final handler = events.onCustomEvent;
    if (handler != null) {
      final toolCallId = value is Map ? value['toolCallId'] as String? : null;
      handler(
        _string(name),
        value,
        <String, dynamic>{if (toolCallId != null) 'toolCallId': toolCallId},
      );
    }
  }

  void _handleActivitySnapshot(Map<String, dynamic> chunk) {
    final messageId = chunk['messageId'] as String;
    final activityType = chunk['activityType'] as String;
    final replace = chunk['replace'] != false;
    final existingIndex =
        _messages.indexWhere((message) => message['id'] == messageId);
    final existing = existingIndex >= 0 ? _messages[existingIndex] : null;
    if (existing != null && existing['role'] != 'activity') {
      _warn(
          "ACTIVITY_SNAPSHOT: Message '$messageId' is not an activity message");
      return;
    }
    if (existing != null && !replace) return;
    final metadata = mergeMetadata(
      existing?['role'] == 'activity' && _isRecord(existing?['metadata'])
          ? (existing!['metadata'] as Map).cast<String, dynamic>()
          : null,
      chunk['metadata'],
    );
    final next = <String, dynamic>{
      'id': messageId,
      'role': 'activity',
      'parts': <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'activity',
          'activityType': activityType,
          'content': _clone(chunk['content'] ?? <String, dynamic>{}),
        },
      ],
      if (metadata != null) 'metadata': metadata,
      if (existing?['role'] == 'activity' && existing?['createdAt'] != null)
        'createdAt': existing!['createdAt'],
      if (existing?['role'] == 'activity' && existing?['name'] != null)
        'name': existing!['name'],
    };
    if (existingIndex == -1) {
      _messages = <Map<String, dynamic>>[..._messages, next];
    } else {
      _messages = <Map<String, dynamic>>[
        for (var i = 0; i < _messages.length; i++)
          i == existingIndex ? next : _messages[i],
      ];
    }
    _emitMessagesChange();
  }

  void _handleActivityDelta(Map<String, dynamic> chunk) {
    final messageId = chunk['messageId'] as String;
    final activityType = chunk['activityType'] as String;
    final existingIndex =
        _messages.indexWhere((message) => message['id'] == messageId);
    if (existingIndex == -1) {
      _warn("ACTIVITY_DELTA: No activity message '$messageId'");
      return;
    }
    final existing = _messages[existingIndex];
    if (existing['role'] != 'activity') {
      _warn("ACTIVITY_DELTA: Message '$messageId' is not an activity message");
      return;
    }
    Map<String, dynamic>? activityPart;
    for (final raw in existing['parts'] as List) {
      if (raw is Map && raw['type'] == 'activity') {
        activityPart = raw.cast<String, dynamic>();
        break;
      }
    }
    if (activityPart != null && activityPart['activityType'] != activityType) {
      _warn(
        "ACTIVITY_DELTA: activityType '$activityType' does not match "
        "'${activityPart['activityType']}' for '$messageId'",
      );
      return;
    }
    final baseContent = _clone(
      activityPart?['content'] ?? <String, dynamic>{},
    );
    try {
      final patched = _applyJsonPatch(
        baseContent,
        (chunk['patch'] as List?) ?? <dynamic>[],
      );
      if (!_isRecord(patched)) {
        _warn(
            "ACTIVITY_DELTA: patched content for '$messageId' is not an object");
        return;
      }
      final nextPart = <String, dynamic>{
        'type': 'activity',
        'activityType': activityType,
        'content': _clone(patched),
      };
      final parts = activityPart != null
          ? (existing['parts'] as List)
              .map((raw) =>
                  raw is Map && raw['type'] == 'activity' ? nextPart : raw)
              .toList()
          : <dynamic>[nextPart];
      final metadata = mergeMetadata(
        _isRecord(existing['metadata'])
            ? (existing['metadata'] as Map).cast<String, dynamic>()
            : null,
        chunk['metadata'],
      );
      _messages = <Map<String, dynamic>>[
        for (var i = 0; i < _messages.length; i++)
          if (i != existingIndex)
            _messages[i]
          else
            <String, dynamic>{
              ..._messages[i],
              'parts': parts,
              if (metadata != null) 'metadata': metadata,
            },
      ];
      _emitMessagesChange();
    } catch (error) {
      _warn("Failed to apply activity patch for '$messageId': $error");
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void _completeAllToolCalls() {
    for (final messageId in _activeMessageIds.toList()) {
      _completeAllToolCallsForMessage(messageId);
    }
  }

  void _completeAllToolCallsForMessage(String messageId) {
    final state = _getMessageState(messageId);
    if (state == null) return;
    for (final entry in state.toolCalls.entries.toList()) {
      if (entry.value.state != ToolCallState.inputComplete) {
        final index = state.toolCallOrder.indexOf(entry.key);
        _completeToolCall(messageId, index, entry.value);
      }
    }
  }

  void _completeToolCall(
    String messageId,
    int index,
    InternalToolCallState toolCall,
  ) {
    toolCall.state = ToolCallState.inputComplete;
    var strictParseSucceeded = false;
    try {
      toolCall.parsedArguments = jsonDecode(toolCall.arguments);
      strictParseSucceeded = true;
    } catch (_) {
      toolCall.parsedArguments = null;
    }

    if (_isToolCallPartTerminal(toolCall.id)) return;
    if (_isToolCallPartAwaitingUserAction(toolCall.id)) return;

    _messages = _updateToolCallPart(_messages, messageId, <String, dynamic>{
      'id': toolCall.id,
      'name': toolCall.name,
      'arguments': toolCall.arguments,
      'state': ToolCallState.inputComplete,
      if (strictParseSucceeded) 'input': toolCall.parsedArguments,
      if (toolCall.metadata != null) 'metadata': toolCall.metadata,
    });
    _emitMessagesChange();
    events.onToolCallStateChange?.call(
      messageId,
      toolCall.id,
      ToolCallState.inputComplete,
      toolCall.arguments,
    );
  }

  bool _isToolCallPartAwaitingUserAction(String toolCallId) {
    return _messages.any(
      (message) => (message['parts'] as List).any(
        (part) =>
            part is Map &&
            part['type'] == 'tool-call' &&
            part['id'] == toolCallId &&
            (part['state'] == 'approval-requested' ||
                part['state'] == 'approval-responded'),
      ),
    );
  }

  bool _isToolCallPartTerminal(String toolCallId) {
    return _messages.any(
      (message) => (message['parts'] as List).any(
        (part) =>
            part is Map &&
            part['type'] == 'tool-call' &&
            part['id'] == toolCallId &&
            (part['state'] == 'error' || part['state'] == 'complete'),
      ),
    );
  }

  void _emitTextUpdateForMessage(String messageId) {
    final state = _getMessageState(messageId);
    if (state == null) return;
    state.lastEmittedText = state.currentSegmentText;
    _messages = _updateTextPart(
      _messages,
      messageId,
      state.currentSegmentText,
    );
    _emitMessagesChange();
    events.onTextUpdate?.call(messageId, state.currentSegmentText);
  }

  void _queueStructuredOutputUpdate(String messageId, String delta) {
    final existing = _structuredOutputUpdateBatches[messageId];
    final next = _StructuredBatch(
      '${existing?.delta ?? ''}$delta',
      (existing?.chunkCount ?? 0) + 1,
    );
    _structuredOutputUpdateBatches[messageId] = next;
    if (next.chunkCount >= _structuredOutputUpdateBatchSize) {
      _flushStructuredOutputUpdate(messageId);
    }
  }

  void _flushStructuredOutputUpdate(String messageId) {
    final batch = _structuredOutputUpdateBatches.remove(messageId);
    if (batch == null || batch.chunkCount == 0) return;
    _emitStructuredOutputChange(messageId, 'update', batch.delta);
  }

  void _emitStructuredOutputChange(
    String messageId,
    String phase, [
    String? delta,
  ]) {
    Map<String, dynamic>? part;
    for (final message in _messages) {
      if (message['id'] != messageId) continue;
      for (final raw in message['parts'] as List) {
        if (raw is Map && raw['type'] == 'structured-output') {
          part = raw.cast<String, dynamic>();
          break;
        }
      }
      break;
    }
    if (part == null) return;
    events.onStructuredOutputChange?.call(<String, dynamic>{
      'phase': phase,
      'messageId': messageId,
      'status': part['status'],
      'raw': part['raw'],
      if (part['partial'] != null) 'partial': part['partial'],
      if (part['data'] != null) 'data': part['data'],
      if (part['reasoning'] != null) 'reasoning': part['reasoning'],
      if (part['errorMessage'] != null) 'errorMessage': part['errorMessage'],
      if (delta != null) 'delta': delta,
    });
  }

  void _emitMessagesChange() {
    events.onMessagesChange?.call(<Map<String, dynamic>>[..._messages]);
  }

  void finalizeStream() {
    _isDone = true;
    for (final event in _closeChunk()) {
      _dispatchChunk(event);
    }
    _closeChildChunkLanes();
    Map<String, dynamic>? lastAssistantMessage;

    for (final messageId in _activeMessageIds.toList()) {
      final state = _getMessageState(messageId);
      if (state == null) continue;
      _completeAllToolCallsForMessage(messageId);
      if (state.currentSegmentText != state.lastEmittedText) {
        _emitTextUpdateForMessage(messageId);
      }
      state.isComplete = true;
      final message = _messageById(_messages, messageId);
      if (message != null && message['role'] == 'assistant') {
        lastAssistantMessage = message;
      }
    }

    for (final messageId in _structuredMessageIds.toList()) {
      _flushStructuredOutputUpdate(messageId);
      _messages = _errorStructuredOutputPart(
        _messages,
        messageId,
        'Stream ended without structured-output.complete',
      );
      _emitStructuredOutputChange(messageId, 'error');
    }
    _structuredMessageIds.clear();
    _structuredOutputUpdateBatches.clear();
    _activeMessageIds.clear();

    if (lastAssistantMessage != null && !_hasError) {
      if (_isWhitespaceOnlyMessage(lastAssistantMessage)) {
        _messages = _messages
            .where((message) => message['id'] != lastAssistantMessage!['id'])
            .toList();
        _emitMessagesChange();
        return;
      }
    }

    if (lastAssistantMessage != null && !_streamEndEmitted) {
      _streamEndEmitted = true;
      events.onStreamEnd?.call(lastAssistantMessage);
    }
  }

  List<Map<String, dynamic>> _getCompletedToolCalls() {
    final result = <Map<String, dynamic>>[];
    for (final state in _messageStates.values) {
      for (final toolCall in state.toolCalls.values) {
        if (toolCall.state != ToolCallState.inputComplete) continue;
        result.add(<String, dynamic>{
          'id': toolCall.id,
          'type': 'function',
          'function': <String, dynamic>{
            'name': toolCall.name,
            'arguments': toolCall.arguments,
          },
          if (toolCall.metadata != null) 'metadata': toolCall.metadata,
        });
      }
    }
    return result;
  }

  ProcessorResult _getResult() {
    final toolCalls = _getCompletedToolCalls();
    var content = '';
    var thinking = '';
    for (final state in _messageStates.values) {
      content += state.totalTextContent;
      for (final stepId in state.thinkingStepOrder) {
        thinking += state.thinkingSteps[stepId] ?? '';
      }
    }
    return ProcessorResult(
      content: content,
      thinking: thinking.isEmpty ? null : thinking,
      toolCalls: toolCalls.isEmpty ? null : toolCalls,
      finishReason: _finishReason,
    );
  }

  ProcessorState getState() {
    var content = '';
    var thinking = '';
    final toolCalls = <String, InternalToolCallState>{};
    final toolCallOrder = <String>[];
    for (final state in _messageStates.values) {
      content += state.totalTextContent;
      for (final stepId in state.thinkingStepOrder) {
        thinking += state.thinkingSteps[stepId] ?? '';
      }
      toolCalls.addAll(state.toolCalls);
      toolCallOrder.addAll(state.toolCallOrder);
    }
    return ProcessorState(
      content: content,
      thinking: thinking,
      toolCalls: toolCalls,
      toolCallOrder: toolCallOrder,
      finishReason: _finishReason,
      done: _isDone,
    );
  }

  void startRecording({String? model, String? provider}) {
    recordingEnabled = true;
    _recordingStartTime = DateTime.now().millisecondsSinceEpoch;
    _recording = ChunkRecording(
      timestamp: _recordingStartTime,
      model: model,
      provider: provider,
    );
  }

  void _startRecording() {
    recordingEnabled = true;
    _recordingStartTime = DateTime.now().millisecondsSinceEpoch;
    _recording = ChunkRecording(timestamp: _recordingStartTime);
  }

  ChunkRecording? getRecording() => _recording;

  void _resetStreamState() {
    _messageStates.clear();
    _callMessageIds.clear();
    _unassignedCallMessageIds.clear();
    _activeMessageIds.clear();
    _activeRuns.clear();
    _toolCallToMessage.clear();
    _structuredMessageIds.clear();
    _structuredOutputUpdateBatches.clear();
    _pendingManualMessageId = null;
    _legacyManualMessage = false;
    _pendingThinkingStepId = null;
    _sealedMessageIds.clear();
    _thinkingOwners.clear();
    _openChunk = null;
    _finishReason = null;
    _hasError = false;
    _isDone = false;
    _streamEndEmitted = false;
    chunkStrategy.reset();
  }

  void reset() {
    _resetStreamState();
    _messages = <Map<String, dynamic>>[];
    _childProcessors.clear();
    _childToolCalls.clear();
  }

  bool _isWhitespaceOnlyMessage(Map<String, dynamic> message) {
    final parts = message['parts'] as List;
    if (parts.isEmpty) return false;
    return parts.every(
      (part) =>
          part is Map &&
          part['type'] == 'text' &&
          _string(part['content']).trim().isEmpty,
    );
  }

  static Future<ProcessorResult> replay(
    ChunkRecording recording, [
    StreamProcessorOptions options = const StreamProcessorOptions(),
  ]) {
    final processor = StreamProcessor(options);
    return processor.process(createReplayStream(recording));
  }
}

/// Build a stream that yields the chunks of a recording.
Stream<Map<String, dynamic>> createReplayStream(ChunkRecording recording) =>
    Stream<Map<String, dynamic>>.fromIterable(
      recording.chunks.map((recorded) => recorded.chunk),
    );

/// Metadata key used by generic interrupt bindings.
const interruptBindingMetadataKey = 'tanstack:interruptBinding';

// ---------------------------------------------------------------------------
// Internal value types
// ---------------------------------------------------------------------------

class _OpenChunk {
  final String family;
  final String id;
  const _OpenChunk(this.family, this.id);
}

class _StructuredBatch {
  final String delta;
  final int chunkCount;
  const _StructuredBatch(this.delta, this.chunkCount);
}

class _ThinkingOwner {
  final String messageId;
  final String stepId;
  const _ThinkingOwner(this.messageId, this.stepId);
}

class _SubagentCard {
  final String? hostId;
  final String? toolCallId;
  final Map<String, dynamic> part;
  final bool carried;
  const _SubagentCard({
    this.hostId,
    this.toolCallId,
    required this.part,
    this.carried = false,
  });
}

// ---------------------------------------------------------------------------
// Map helpers / part updaters (port of message-updaters.ts)
// ---------------------------------------------------------------------------

bool _isRecord(dynamic value) => value is Map;

String _string(dynamic value, [String fallback = '']) =>
    value is String ? value : fallback;

dynamic _clone(dynamic value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  try {
    return jsonDecode(jsonEncode(value));
  } catch (_) {
    return value;
  }
}

Map<String, dynamic>? _messageById(
  List<Map<String, dynamic>> messages,
  String id,
) {
  for (final message in messages) {
    if (message['id'] == id) return message;
  }
  return null;
}

String? _getChunkRunId(Map<String, dynamic> chunk) {
  final top = chunk['runId'];
  if (top is String && top.isNotEmpty) return top;
  final fromMetadata = tanstackMetadata(chunk)?['runId'];
  return fromMetadata is String && fromMetadata.isNotEmpty
      ? fromMetadata
      : null;
}

List<Map<String, dynamic>> _updateTextPart(
  List<Map<String, dynamic>> messages,
  String messageId,
  String content,
) {
  return messages.map((message) {
    if (message['id'] != messageId) return message;
    final parts = <dynamic>[...message['parts'] as List];
    if (parts.isNotEmpty && parts.last is Map && parts.last['type'] == 'text') {
      parts[parts.length - 1] = <String, dynamic>{
        'type': 'text',
        'content': content,
      };
    } else {
      parts.add(<String, dynamic>{'type': 'text', 'content': content});
    }
    return <String, dynamic>{...message, 'parts': parts};
  }).toList();
}

List<Map<String, dynamic>> _updateToolCallPart(
  List<Map<String, dynamic>> messages,
  String messageId,
  Map<String, dynamic> toolCall,
) {
  return messages.map((message) {
    if (message['id'] != messageId) return message;
    final parts = <dynamic>[...message['parts'] as List];
    Map<String, dynamic>? existing;
    var existingIndex = -1;
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part is Map &&
          part['type'] == 'tool-call' &&
          part['id'] == toolCall['id']) {
        existing = part.cast<String, dynamic>();
        existingIndex = i;
        break;
      }
    }
    final metadata = toolCall['metadata'] ?? existing?['metadata'];
    final input = toolCall['input'] ?? existing?['input'];
    final next = <String, dynamic>{
      'type': 'tool-call',
      'id': toolCall['id'],
      'name': toolCall['name'],
      'arguments': toolCall['arguments'],
      'state': toolCall['state'],
      if (existing?['approval'] != null)
        'approval': <String, dynamic>{
          ...(existing!['approval'] as Map).cast<String, dynamic>(),
        },
      if (existing?['output'] != null) 'output': existing!['output'],
      if (input != null) 'input': input,
      if (metadata != null) 'metadata': metadata,
    };
    if (existingIndex >= 0) {
      parts[existingIndex] = next;
    } else {
      parts.add(next);
    }
    return <String, dynamic>{...message, 'parts': parts};
  }).toList();
}

List<Map<String, dynamic>> _updateToolResultPart(
  List<Map<String, dynamic>> messages,
  String messageId,
  String toolCallId,
  dynamic content,
  String state, {
  String? error,
  dynamic outcome,
}) {
  return messages.map((message) {
    if (message['id'] != messageId) return message;
    final parts = <dynamic>[...message['parts'] as List];
    var index = -1;
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part is Map &&
          part['type'] == 'tool-result' &&
          part['toolCallId'] == toolCallId) {
        index = i;
        break;
      }
    }
    final next = <String, dynamic>{
      'type': 'tool-result',
      'toolCallId': toolCallId,
      'content': content,
      'state': state,
      if (outcome != null) 'outcome': outcome,
      if (error != null && error.isNotEmpty) 'error': error,
    };
    if (index >= 0) {
      parts[index] = next;
    } else {
      parts.add(next);
    }
    return <String, dynamic>{...message, 'parts': parts};
  }).toList();
}

List<Map<String, dynamic>> _updateToolCallApproval(
  List<Map<String, dynamic>> messages,
  String messageId,
  String toolCallId,
  String approvalId,
) {
  return messages.map((message) {
    if (message['id'] != messageId) return message;
    final parts = <dynamic>[...message['parts'] as List];
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part is Map &&
          part['type'] == 'tool-call' &&
          part['id'] == toolCallId) {
        parts[i] = <String, dynamic>{
          ...part.cast<String, dynamic>(),
          'state': 'approval-requested',
          'approval': <String, dynamic>{
            'id': approvalId,
            'needsApproval': true,
          },
        };
      }
    }
    return <String, dynamic>{...message, 'parts': parts};
  }).toList();
}

List<Map<String, dynamic>> _updateToolCallWithOutput(
  List<Map<String, dynamic>> messages,
  String toolCallId,
  dynamic output, [
  String? state,
  String? errorText,
]) {
  return messages.map((message) {
    final parts = <dynamic>[...message['parts'] as List];
    var changed = false;
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part is Map &&
          part['type'] == 'tool-call' &&
          part['id'] == toolCallId) {
        parts[i] = <String, dynamic>{
          ...part.cast<String, dynamic>(),
          'output': errorText != null
              ? <String, dynamic>{'error': errorText}
              : output,
          'state': state ?? (errorText != null ? 'error' : 'complete'),
        };
        changed = true;
      }
    }
    return changed ? <String, dynamic>{...message, 'parts': parts} : message;
  }).toList();
}

List<Map<String, dynamic>> _updateToolCallApprovalResponse(
  List<Map<String, dynamic>> messages,
  String approvalId,
  bool approved,
) {
  return messages.map((message) {
    final parts = <dynamic>[...message['parts'] as List];
    var changed = false;
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part is Map &&
          part['type'] == 'tool-call' &&
          part['approval'] is Map &&
          part['approval']['id'] == approvalId) {
        parts[i] = <String, dynamic>{
          ...part.cast<String, dynamic>(),
          'approval': <String, dynamic>{
            ...(part['approval'] as Map).cast<String, dynamic>(),
            'approved': approved,
          },
          'state': 'approval-responded',
        };
        changed = true;
      }
    }
    return changed ? <String, dynamic>{...message, 'parts': parts} : message;
  }).toList();
}

List<Map<String, dynamic>> _appendStructuredOutputDelta(
  List<Map<String, dynamic>> messages,
  String messageId,
  String delta,
) {
  return messages.map((message) {
    if (message['id'] != messageId) return message;
    final parts = <dynamic>[...message['parts'] as List];
    var index = -1;
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part is Map && part['type'] == 'structured-output') {
        index = i;
        break;
      }
    }
    final existing =
        index >= 0 ? (parts[index] as Map).cast<String, dynamic>() : null;
    final nextRaw = '${existing?['raw'] ?? ''}$delta';
    final progressive = parsePartialJSON(nextRaw);
    final nextPartial = progressive ?? existing?['partial'];
    final next = <String, dynamic>{
      'type': 'structured-output',
      'status': 'streaming',
      'raw': nextRaw,
      if (nextPartial != null) 'partial': nextPartial,
      if (existing?['reasoning'] != null) 'reasoning': existing!['reasoning'],
    };
    if (index >= 0) {
      parts[index] = next;
    } else {
      parts.add(next);
    }
    return <String, dynamic>{...message, 'parts': parts};
  }).toList();
}

List<Map<String, dynamic>> _completeStructuredOutputPart(
  List<Map<String, dynamic>> messages,
  String messageId,
  dynamic data,
  String raw, [
  String? reasoning,
]) {
  return messages.map((message) {
    if (message['id'] != messageId) return message;
    final parts = <dynamic>[...message['parts'] as List];
    var index = -1;
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part is Map && part['type'] == 'structured-output') {
        index = i;
        break;
      }
    }
    final existingRaw = index >= 0 ? _string((parts[index] as Map)['raw']) : '';
    var resolvedRaw = raw.isNotEmpty ? raw : existingRaw;
    if (resolvedRaw.isEmpty && data != null) {
      try {
        resolvedRaw = jsonEncode(data);
      } catch (_) {
        resolvedRaw = '';
      }
    }
    final next = <String, dynamic>{
      'type': 'structured-output',
      'status': 'complete',
      'data': data,
      'partial': data,
      'raw': resolvedRaw,
      if (reasoning != null) 'reasoning': reasoning,
    };
    if (index >= 0) {
      parts[index] = next;
    } else {
      parts.add(next);
    }
    return <String, dynamic>{...message, 'parts': parts};
  }).toList();
}

List<Map<String, dynamic>> _errorStructuredOutputPart(
  List<Map<String, dynamic>> messages,
  String messageId,
  String errorMessage,
) {
  return messages.map((message) {
    if (message['id'] != messageId) return message;
    final parts = <dynamic>[...message['parts'] as List];
    var index = -1;
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part is Map && part['type'] == 'structured-output') {
        index = i;
        break;
      }
    }
    if (index < 0) {
      parts.add(<String, dynamic>{
        'type': 'structured-output',
        'status': 'error',
        'raw': '',
        'errorMessage': errorMessage,
      });
      return <String, dynamic>{...message, 'parts': parts};
    }
    final existing = (parts[index] as Map).cast<String, dynamic>();
    if (existing['status'] == 'complete') return message;
    parts[index] = <String, dynamic>{
      ...existing,
      'status': 'error',
      'errorMessage': errorMessage,
    };
    return <String, dynamic>{...message, 'parts': parts};
  }).toList();
}

List<Map<String, dynamic>> _updateThinkingPart(
  List<Map<String, dynamic>> messages,
  String messageId,
  String stepId,
  String content, [
  String? signature,
]) {
  return messages.map((message) {
    if (message['id'] != messageId) return message;
    final parts = <dynamic>[...message['parts'] as List];
    var index = -1;
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part is Map &&
          part['type'] == 'thinking' &&
          part['stepId'] == stepId) {
        index = i;
        break;
      }
    }
    Map<String, dynamic>? adopted;
    if (index < 0) {
      for (var i = 0; i < parts.length; i++) {
        final part = parts[i];
        if (part is Map &&
            part['type'] == 'thinking' &&
            part['stepId'] == null) {
          index = i;
          adopted = part.cast<String, dynamic>();
          break;
        }
      }
    }
    final nextSignature = signature ?? adopted?['signature'] as String?;
    final redacted =
        isRedactedThinkingId(stepId) || adopted?['redacted'] == true;
    final next = <String, dynamic>{
      'type': 'thinking',
      'content': content,
      'stepId': stepId,
      if (nextSignature != null && nextSignature.isNotEmpty)
        'signature': nextSignature,
      if (redacted) 'redacted': true,
    };
    if (index >= 0) {
      parts[index] = next;
    } else {
      parts.add(next);
    }
    return <String, dynamic>{...message, 'parts': parts};
  }).toList();
}

dynamic _parseToolArguments(String args) {
  if (args.trim().isEmpty) return <String, dynamic>{};
  try {
    final parsed = jsonDecode(args);
    return parsed;
  } catch (_) {
    return null;
  }
}

({String args, dynamic input}) _finishToolCallArguments(
  String streamed,
  Map<String, dynamic> end,
) {
  final metadata = tanstackMetadata(end);
  final endArgs = end['args'] ?? metadata?['args'];
  final rawArgs = endArgs is String ? endArgs : null;
  final endInput = end['input'] ?? metadata?['input'];
  final input =
      endInput != null && endInput is Map || endInput is List ? endInput : null;
  String? raw = rawArgs ?? streamed;
  if (rawArgs == null && input != null) {
    try {
      jsonDecode(raw);
    } catch (_) {
      raw = null;
    }
  }
  var args = raw ?? streamed;
  if (input != null) {
    try {
      final parsed = jsonDecode(args);
      if (jsonEncode(parsed) != jsonEncode(input)) {
        args = jsonEncode(input);
      }
    } catch (_) {
      args = jsonEncode(input);
    }
  }
  return (args: args, input: _parseToolArguments(args));
}

// ---------------------------------------------------------------------------
// RFC 6902 JSON patch (activity deltas)
// ---------------------------------------------------------------------------

dynamic _applyJsonPatch(dynamic document, List<dynamic> patch) {
  var current = _clone(document);
  for (final raw in patch) {
    if (raw is! Map) continue;
    final operation = raw.cast<String, dynamic>();
    final op = operation['op'];
    final path = _string(operation['path']);
    switch (op) {
      case 'add':
        current = _patchAdd(current, path, _clone(operation['value']));
        break;
      case 'replace':
        current = _patchReplace(current, path, _clone(operation['value']));
        break;
      case 'remove':
        current = _patchRemove(current, path);
        break;
      case 'test':
        final existing = _patchGet(current, path);
        if (jsonEncode(existing) != jsonEncode(operation['value'])) {
          throw const FormatException('JSON patch test failed');
        }
        break;
      case 'copy':
        final from = _patchGet(current, _string(operation['from']));
        current = _patchAdd(current, path, _clone(from));
        break;
      case 'move':
        final from = _patchGet(current, _string(operation['from']));
        current = _patchRemove(current, _string(operation['from']));
        current = _patchAdd(current, path, _clone(from));
        break;
      default:
        throw const FormatException('Unsupported JSON patch operation');
    }
  }
  return current;
}

List<String> _patchTokens(String path) {
  if (path.isEmpty) return <String>[];
  if (!path.startsWith('/')) throw const FormatException('Bad JSON pointer');
  return path
      .substring(1)
      .split('/')
      .map((token) => token.replaceAll('~1', '/').replaceAll('~0', '~'))
      .toList();
}

dynamic _patchGet(dynamic document, String path) {
  dynamic current = document;
  for (final token in _patchTokens(path)) {
    if (current is Map) {
      if (!current.containsKey(token)) {
        throw const FormatException('Path not found');
      }
      current = current[token];
    } else if (current is List) {
      final index = int.parse(token);
      current = current[index];
    } else {
      throw const FormatException('Path not found');
    }
  }
  return current;
}

dynamic _patchAdd(dynamic document, String path, dynamic value) {
  final tokens = _patchTokens(path);
  if (tokens.isEmpty) return value;
  final parent = _patchGet(
    document,
    _patchParentPath(tokens),
  );
  final key = tokens.last;
  if (parent is Map) {
    parent[key] = value;
  } else if (parent is List) {
    if (key == '-') {
      parent.add(value);
    } else {
      parent.insert(int.parse(key), value);
    }
  } else {
    throw const FormatException('Path not found');
  }
  return document;
}

String _patchParentPath(List<String> tokens) {
  final parentTokens = tokens.take(tokens.length - 1);
  if (parentTokens.isEmpty) return '';
  return '/${parentTokens.map((token) => token.replaceAll('~', '~0').replaceAll('/', '~1')).join('/')}';
}

dynamic _patchReplace(dynamic document, String path, dynamic value) {
  final tokens = _patchTokens(path);
  if (tokens.isEmpty) return value;
  final parent = _patchGet(
    document,
    _patchParentPath(tokens),
  );
  final key = tokens.last;
  if (parent is Map) {
    if (!parent.containsKey(key)) throw const FormatException('Path not found');
    parent[key] = value;
  } else if (parent is List) {
    final index = int.parse(key);
    if (index < 0 || index >= parent.length) {
      throw const FormatException('Path not found');
    }
    parent[index] = value;
  } else {
    throw const FormatException('Path not found');
  }
  return document;
}

dynamic _patchRemove(dynamic document, String path) {
  final tokens = _patchTokens(path);
  if (tokens.isEmpty) throw const FormatException('Cannot remove root');
  final parent = _patchGet(
    document,
    _patchParentPath(tokens),
  );
  final key = tokens.last;
  if (parent is Map) {
    parent.remove(key);
  } else if (parent is List) {
    parent.removeAt(int.parse(key));
  } else {
    throw const FormatException('Path not found');
  }
  return document;
}

void _warn(String message) {
  // Warnings are intentionally non-fatal, matching upstream console.warn.
  // ignore: avoid_print
  print('[StreamProcessor] $message');
}
