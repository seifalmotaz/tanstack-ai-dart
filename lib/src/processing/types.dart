import 'strategies.dart';

/// Lifecycle state of a tool call being streamed.
abstract final class ToolCallState {
  static const awaitingInput = 'awaiting-input';
  static const inputStreaming = 'input-streaming';
  static const inputComplete = 'input-complete';
  static const approvalRequested = 'approval-requested';
  static const approvalResponded = 'approval-responded';
  static const complete = 'complete';
  static const error = 'error';
}

/// Lifecycle state of a tool result part.
abstract final class ToolResultState {
  static const streaming = 'streaming';
  static const complete = 'complete';
  static const error = 'error';
}

/// Internal state for a tool call being tracked by the stream processor.
class InternalToolCallState {
  final String id;
  final String name;
  String arguments;
  String state;
  dynamic parsedArguments;
  final int index;
  Map<String, dynamic>? metadata;

  InternalToolCallState({
    required this.id,
    required this.name,
    this.arguments = '',
    this.state = ToolCallState.awaitingInput,
    this.parsedArguments,
    required this.index,
    this.metadata,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'arguments': arguments,
        'state': state,
        if (parsedArguments != null) 'parsedArguments': parsedArguments,
        'index': index,
        if (metadata != null) 'metadata': metadata,
      };
}

/// Per-message streaming state.
class MessageStreamState {
  String id;
  String role;
  String totalTextContent = '';
  String currentSegmentText = '';
  String lastEmittedText = '';
  bool hasSeenReasoningEvents = false;
  final Map<String, String> thinkingSteps = <String, String>{};
  final Map<String, String> thinkingStepSignatures = <String, String>{};
  final List<String> thinkingStepOrder = <String>[];
  String? currentThinkingStepId;
  final Map<String, InternalToolCallState> toolCalls =
      <String, InternalToolCallState>{};
  final List<String> toolCallOrder = <String>[];
  bool hasToolCallsSinceTextStart = false;
  bool isComplete = false;

  MessageStreamState({
    required this.id,
    required this.role,
  });
}

/// Result returned after a stream is processed.
class ProcessorResult {
  final String content;
  final String? thinking;
  final List<Map<String, dynamic>>? toolCalls;
  final String? finishReason;

  const ProcessorResult({
    required this.content,
    this.thinking,
    this.toolCalls,
    this.finishReason,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'content': content,
        if (thinking != null) 'thinking': thinking,
        if (toolCalls != null) 'toolCalls': toolCalls,
        if (finishReason != null) 'finishReason': finishReason,
      };
}

/// Snapshot of the processor's current state.
class ProcessorState {
  final String content;
  final String thinking;
  final Map<String, InternalToolCallState> toolCalls;
  final List<String> toolCallOrder;
  final String? finishReason;
  final bool done;

  const ProcessorState({
    required this.content,
    required this.thinking,
    required this.toolCalls,
    required this.toolCallOrder,
    required this.finishReason,
    required this.done,
  });
}

/// One recorded chunk with its position in the recording.
class RecordedChunk {
  final Map<String, dynamic> chunk;
  final int timestamp;
  final int index;

  const RecordedChunk({
    required this.chunk,
    required this.timestamp,
    required this.index,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'chunk': chunk,
        'timestamp': timestamp,
        'index': index,
      };
}

/// Recording format for replay testing.
class ChunkRecording {
  final String version;
  final int timestamp;
  final String? model;
  final String? provider;
  final List<RecordedChunk> chunks;
  ProcessorResult? result;

  ChunkRecording({
    this.version = '1.0',
    required this.timestamp,
    this.model,
    this.provider,
    List<RecordedChunk>? chunks,
    this.result,
  }) : chunks = chunks ?? <RecordedChunk>[];

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': version,
        'timestamp': timestamp,
        if (model != null) 'model': model,
        if (provider != null) 'provider': provider,
        'chunks': chunks.map((chunk) => chunk.toJson()).toList(),
        if (result != null) 'result': result!.toJson(),
      };
}

/// Event handlers emitted by the processor.
class StreamProcessorEvents {
  final void Function(List<Map<String, dynamic>> messages)? onMessagesChange;
  final void Function()? onStreamStart;
  final void Function(Map<String, dynamic> message)? onStreamEnd;
  final void Function(Object error)? onError;
  final void Function(Map<String, dynamic> args)? onToolCall;
  final void Function(Map<String, dynamic> args)? onApprovalRequest;
  final void Function(
    String eventType,
    dynamic data,
    Map<String, dynamic> context,
  )? onCustomEvent;
  final void Function(String messageId, String content)? onTextUpdate;
  final void Function(
    String messageId,
    String toolCallId,
    String state,
    String args,
  )? onToolCallStateChange;
  final void Function(
    String messageId,
    String stepId,
    String content,
  )? onThinkingUpdate;
  final void Function(Map<String, dynamic> args)? onStructuredOutputChange;

  const StreamProcessorEvents({
    this.onMessagesChange,
    this.onStreamStart,
    this.onStreamEnd,
    this.onError,
    this.onToolCall,
    this.onApprovalRequest,
    this.onCustomEvent,
    this.onTextUpdate,
    this.onToolCallStateChange,
    this.onThinkingUpdate,
    this.onStructuredOutputChange,
  });
}

/// Options accepted by [StreamProcessor].
class StreamProcessorOptions {
  final ChunkStrategy? chunkStrategy;
  final StreamProcessorEvents? events;
  final dynamic jsonParser;
  final bool recording;
  final List<Map<String, dynamic>>? initialMessages;
  final String? subagentRunId;

  const StreamProcessorOptions({
    this.chunkStrategy,
    this.events,
    this.jsonParser,
    this.recording = false,
    this.initialMessages,
    this.subagentRunId,
  });
}

/// AG-UI event names used by the processor.
abstract final class EventType {
  static const runStarted = 'RUN_STARTED';
  static const runFinished = 'RUN_FINISHED';
  static const runError = 'RUN_ERROR';
  static const textMessageStart = 'TEXT_MESSAGE_START';
  static const textMessageContent = 'TEXT_MESSAGE_CONTENT';
  static const textMessageEnd = 'TEXT_MESSAGE_END';
  static const textMessageChunk = 'TEXT_MESSAGE_CHUNK';
  static const toolCallStart = 'TOOL_CALL_START';
  static const toolCallArgs = 'TOOL_CALL_ARGS';
  static const toolCallEnd = 'TOOL_CALL_END';
  static const toolCallChunk = 'TOOL_CALL_CHUNK';
  static const toolCallResult = 'TOOL_CALL_RESULT';
  static const reasoningStart = 'REASONING_START';
  static const reasoningMessageStart = 'REASONING_MESSAGE_START';
  static const reasoningMessageContent = 'REASONING_MESSAGE_CONTENT';
  static const reasoningMessageEnd = 'REASONING_MESSAGE_END';
  static const reasoningMessageChunk = 'REASONING_MESSAGE_CHUNK';
  static const reasoningEnd = 'REASONING_END';
  static const reasoningEncryptedValue = 'REASONING_ENCRYPTED_VALUE';
  static const stepStarted = 'STEP_STARTED';
  static const stepFinished = 'STEP_FINISHED';
  static const messagesSnapshot = 'MESSAGES_SNAPSHOT';
  static const stateSnapshot = 'STATE_SNAPSHOT';
  static const stateDelta = 'STATE_DELTA';
  static const custom = 'CUSTOM';
  static const activitySnapshot = 'ACTIVITY_SNAPSHOT';
  static const activityDelta = 'ACTIVITY_DELTA';
  static const subagentStarted = 'SUBAGENT_STARTED';
  static const subagentFinished = 'SUBAGENT_FINISHED';
  static const subagentError = 'SUBAGENT_ERROR';
  static const raw = 'RAW';
}
