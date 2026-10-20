import 'dart:async';

import 'persistence_types.dart';

/// Ported from `packages/ai-client/src/client-persistor.ts`.
///
/// Stream chunks are JSON-compatible maps (the wire union is extensible). The
/// persistor reads only `type` plus the relevant id fields.

ChatPersistedState? normalizePersistedState(Object? raw) {
  if (raw is ChatPersistedState) return raw;
  if (raw is List) {
    return ChatPersistedState(
      messages: raw
          .whereType<Map>()
          .map((message) => Map<String, dynamic>.from(message))
          .toList(growable: false),
    );
  }
  if (raw is Map && raw['messages'] is List) {
    return ChatPersistedState.fromJson(Map<String, dynamic>.from(raw));
  }
  return null;
}

String? _getChunkRunId(Map<String, dynamic> chunk) =>
    chunk['runId'] is String ? chunk['runId'] as String : null;

String? _getChunkToolCallId(Map<String, dynamic> chunk) =>
    chunk['toolCallId'] is String ? chunk['toolCallId'] as String : null;

String? _getChunkMessageId(Map<String, dynamic> chunk) =>
    chunk['messageId'] is String ? chunk['messageId'] as String : null;

String? _getChunkParentMessageId(Map<String, dynamic> chunk) =>
    chunk['parentMessageId'] is String
        ? chunk['parentMessageId'] as String
        : null;

/// Encapsulates persistence orchestration and clear-during-stream suppression.
///
/// All adapter calls are best-effort: a throwing or rejecting adapter never
/// breaks chat setup or streaming.
class ChatPersistor {
  final ChatClientPersistence adapter;
  final String id;
  final void Function(List<Map<String, dynamic>> messages) applyMessages;
  final void Function(ChatResumeSnapshot snapshot)? applyResume;

  bool _skipNextPersist = false;
  int _generation = 0;
  Future<void> _queue = Future<void>.value();
  bool _queuePending = false;
  int _messagesGeneration = 0;
  List<Map<String, dynamic>> _lastMessages = <Map<String, dynamic>>[];
  ChatResumeSnapshot? _lastResume;

  final Set<String> _clearedMessageIds = <String>{};
  final Set<String> _clearedRunIds = <String>{};
  final Set<String> _ignoredActiveRunIds = <String>{};
  final Set<String> _clearedToolCallIds = <String>{};
  String? _currentRunlessRunId;

  ChatPersistor(
    this.adapter,
    this.id,
    this.applyMessages, [
    this.applyResume,
  ]);

  void _writeState() {
    final messages = List<Map<String, dynamic>>.of(_lastMessages);
    if (messages.isEmpty && _lastResume == null) {
      final generation = _generation;
      _runOperation(() {
        if (generation != _generation) return null;
        return adapter.removeItem(id);
      });
      return;
    }
    final generation = _generation;
    final state = ChatPersistedState(
      messages: messages,
      resume: _lastResume,
    );
    _runOperation(() {
      if (generation != _generation) return null;
      return adapter.setItem(id, state);
    });
  }

  /// Synchronously read persisted state for constructor-time hydration.
  /// Returns a future when the adapter is asynchronous.
  FutureOr<ChatPersistedState?> readInitial() {
    try {
      final raw = adapter.getItem(id);
      if (raw is Future) {
        return raw.then(normalizePersistedState).catchError((_) => null);
      }
      final state = normalizePersistedState(raw);
      if (state != null) {
        _lastMessages = state.messages;
        _lastResume = state.resume;
      }
      return state;
    } catch (_) {
      return null;
    }
  }

  /// Apply async hydrated state unless the message list already changed.
  Future<void>? hydrateAsync(FutureOr<ChatPersistedState?> persistedState) {
    if (persistedState is! Future) return null;
    final hydrationGeneration = _messagesGeneration;
    return (persistedState as Future<ChatPersistedState?>).then((state) {
      if (state == null || _messagesGeneration != hydrationGeneration) return;
      _lastResume = state.resume;
      _lastMessages = state.messages;
      applyMessages(state.messages);
      final resume = state.resume;
      if (resume != null) applyResume?.call(resume);
    }).catchError((_) {
      // Persistence adapters are best-effort.
    });
  }

  void notifyMessagesChanged(List<Map<String, dynamic>> messages) {
    _messagesGeneration++;
    _lastMessages = List<Map<String, dynamic>>.of(messages);
    if (_skipNextPersist) {
      _skipNextPersist = false;
      return;
    }
    _writeState();
  }

  void persistResumeSnapshot(ChatResumeSnapshot? snapshot) {
    _lastResume = snapshot;
    if (_skipNextPersist) return;
    _writeState();
  }

  void remove() {
    _lastMessages = <Map<String, dynamic>>[];
    _lastResume = null;
    final generation = ++_generation;
    _runOperation(() {
      if (generation != _generation) return null;
      return adapter.removeItem(id);
    });
  }

  void _runOperation(FutureOr<void> Function() operation) {
    if (_queuePending) {
      final queued = _queue.then((_) async {
        await operation();
      }).catchError((_) {
        // Persistence adapters are best-effort.
      });
      _queue = queued;
      unawaited(queued.whenComplete(() {
        if (identical(_queue, queued)) _queuePending = false;
      }));
      return;
    }

    try {
      final result = operation();
      if (result is Future) {
        _queuePending = true;
        final queued = result.catchError((_) {
          // Persistence adapters are best-effort.
        });
        _queue = queued;
        unawaited(queued.whenComplete(() {
          if (identical(_queue, queued)) _queuePending = false;
        }));
      }
    } catch (_) {
      // Persistence adapters are best-effort.
    }
  }

  void snapshotClear({
    required List<Map<String, dynamic>> messages,
    required Set<String> activeRunIds,
    required String? currentRunId,
  }) {
    for (final message in messages) {
      final messageId = message['id'];
      if (messageId is String) _clearedMessageIds.add(messageId);
    }
    for (final runId in activeRunIds) {
      _clearedRunIds.add(runId);
      _ignoredActiveRunIds.add(runId);
    }
    if (currentRunId != null) {
      _clearedRunIds.add(currentRunId);
      _ignoredActiveRunIds.add(currentRunId);
    }
  }

  void beginClear() {
    _skipNextPersist = true;
  }

  bool shouldIgnoreChunk(Map<String, dynamic> chunk) {
    final runId = _getChunkRunId(chunk);
    if (runId != null && _clearedRunIds.contains(runId)) {
      if (chunk['type'] == 'RUN_STARTED') {
        _ignoredActiveRunIds.add(runId);
        _currentRunlessRunId = runId;
      }
      _markIgnoredChunkIds(chunk);
      return true;
    }

    if (runId != null && _ignoredActiveRunIds.contains(runId)) {
      _markIgnoredChunkIds(chunk);
      return true;
    }

    if (_isRunlessChunkFromIgnoredRun(chunk)) {
      _markIgnoredChunkIds(chunk);
      return true;
    }

    final toolCallId = _getChunkToolCallId(chunk);
    if (toolCallId != null && _clearedToolCallIds.contains(toolCallId)) {
      return true;
    }

    final parentMessageId = _getChunkParentMessageId(chunk);
    if (parentMessageId != null &&
        _clearedMessageIds.contains(parentMessageId)) {
      if (toolCallId != null) _clearedToolCallIds.add(toolCallId);
      return true;
    }

    final messageId = _getChunkMessageId(chunk);
    if (messageId == null) return false;
    return _clearedMessageIds.contains(messageId);
  }

  void onRunStarted(String runId) {
    _currentRunlessRunId = runId;
  }

  void onRunSettled(String runId) {
    _ignoredActiveRunIds.remove(runId);
    _clearedRunIds.remove(runId);
    if (_currentRunlessRunId == runId) {
      _currentRunlessRunId =
          _ignoredActiveRunIds.isEmpty ? null : _ignoredActiveRunIds.first;
    }
  }

  void onSessionRunError() {
    _ignoredActiveRunIds.clear();
    _currentRunlessRunId = null;
  }

  void resetIgnored() {
    _ignoredActiveRunIds.clear();
  }

  String? takeRunlessRunId() {
    final runId = _currentRunlessRunId;
    if (runId == null) return null;
    _ignoredActiveRunIds.remove(runId);
    _clearedRunIds.remove(runId);
    _currentRunlessRunId =
        _ignoredActiveRunIds.isEmpty ? null : _ignoredActiveRunIds.first;
    return runId;
  }

  void _markIgnoredChunkIds(Map<String, dynamic> chunk) {
    final messageId = _getChunkMessageId(chunk);
    if (messageId != null) _clearedMessageIds.add(messageId);
    final toolCallId = _getChunkToolCallId(chunk);
    if (toolCallId != null) _clearedToolCallIds.add(toolCallId);
  }

  bool _isRunlessChunkFromIgnoredRun(Map<String, dynamic> chunk) {
    final runId = _getChunkRunId(chunk);
    if (runId != null || _currentRunlessRunId == null) return false;
    if (!_ignoredActiveRunIds.contains(_currentRunlessRunId) &&
        !_clearedRunIds.contains(_currentRunlessRunId)) {
      return false;
    }
    const ignoredTypes = <String>{
      'TEXT_MESSAGE_START',
      'TEXT_MESSAGE_CONTENT',
      'TEXT_MESSAGE_CHUNK',
      'TOOL_CALL_START',
      'TOOL_CALL_ARGS',
      'TOOL_CALL_END',
      'TOOL_CALL_RESULT',
      'TOOL_CALL_CHUNK',
      'MESSAGES_SNAPSHOT',
      'RUN_ERROR',
    };
    return ignoredTypes.contains(chunk['type']);
  }
}
