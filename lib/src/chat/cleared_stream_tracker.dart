import '../protocol.dart';

/// Tracks stream chunks that must be ignored after the owning chat was cleared.
///
/// Port of upstream `cleared-stream-tracker.ts` for Map-based AG-UI events.
class ClearedStreamTracker {
  final Set<String> _clearedMessageIds = <String>{};
  final Set<String> _clearedRunIds = <String>{};
  final Set<String> _ignoredActiveRunIds = <String>{};
  final Set<String> _clearedToolCallIds = <String>{};
  String? _currentRunlessRunId;

  void snapshotClear({
    required List<AssistantTurn> messages,
    Set<String> activeRunIds = const <String>{},
    String? currentRunId,
  }) {
    for (final message in messages) {
      _clearedMessageIds.add(message.id);
    }
    for (final runId in activeRunIds) {
      _clearedRunIds.add(runId);
      _ignoredActiveRunIds.add(runId);
    }
    if (currentRunId != null && currentRunId.isNotEmpty) {
      _clearedRunIds.add(currentRunId);
      _ignoredActiveRunIds.add(currentRunId);
    }
  }

  bool shouldIgnoreChunk(Map<String, dynamic> chunk) {
    final runId = _runId(chunk);
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

    final toolCallId = _toolCallId(chunk);
    if (toolCallId != null && _clearedToolCallIds.contains(toolCallId)) {
      return true;
    }

    final parentMessageId = _stringField(chunk, 'parentMessageId');
    if (parentMessageId != null &&
        _clearedMessageIds.contains(parentMessageId)) {
      if (toolCallId != null) _clearedToolCallIds.add(toolCallId);
      return true;
    }

    final messageId = _messageId(chunk);
    return messageId != null && _clearedMessageIds.contains(messageId);
  }

  void onRunStarted(String runId) => _currentRunlessRunId = runId;

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

  void resetActiveRuns() {
    _ignoredActiveRunIds.clear();
    _currentRunlessRunId = null;
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
    final messageId = _messageId(chunk);
    if (messageId != null) _clearedMessageIds.add(messageId);
    final toolCallId = _toolCallId(chunk);
    if (toolCallId != null) _clearedToolCallIds.add(toolCallId);
  }

  bool _isRunlessChunkFromIgnoredRun(Map<String, dynamic> chunk) {
    final runId = _runId(chunk);
    if (runId != null) return false;
    final current = _currentRunlessRunId;
    if (current == null) return false;
    if (!_ignoredActiveRunIds.contains(current) &&
        !_clearedRunIds.contains(current)) {
      return false;
    }
    return const <String>{
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
    }.contains(chunk['type']);
  }

  static String? _stringField(Map<String, dynamic> chunk, String key) {
    final value = chunk[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  static String? _runId(Map<String, dynamic> chunk) =>
      _stringField(chunk, 'runId');

  static String? _toolCallId(Map<String, dynamic> chunk) =>
      _stringField(chunk, 'toolCallId');

  static String? _messageId(Map<String, dynamic> chunk) =>
      _stringField(chunk, 'messageId');
}
