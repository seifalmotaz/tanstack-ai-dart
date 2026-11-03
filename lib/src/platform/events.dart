/// Ported from `packages/ai-client/src/events.ts`.
///
/// The browser devtools event client is replaced by a small injectable
/// [AiEventClient]. Hosts can install a bridge in [aiEventClient] or pass a
/// custom client to [DefaultChatClientEventEmitter].
library;

class ChatClientRunEventContext {
  final String? threadId;
  final String? runId;
  final String? toolCallId;

  const ChatClientRunEventContext({
    this.threadId,
    this.runId,
    this.toolCallId,
  });

  Map<String, dynamic> toJson() => {
        if (threadId != null) 'threadId': threadId,
        if (runId != null) 'runId': runId,
        if (toolCallId != null) 'toolCallId': toolCallId,
      };
}

class ChatClientEventContext {
  final String? threadId;
  final String? runId;
  final String? toolCallId;

  const ChatClientEventContext({
    this.threadId,
    this.runId,
    this.toolCallId,
  });

  Map<String, dynamic> toJson() => {
        if (threadId != null) 'threadId': threadId,
        if (runId != null) 'runId': runId,
        if (toolCallId != null) 'toolCallId': toolCallId,
      };
}

class ChatClientToolFixtureAppliedEvent {
  final String hookId;
  final String threadId;
  final String toolName;
  final Object? input;
  final Object? output;
  final bool? execute;
  final Map<String, dynamic>? message;
  final String messageId;
  final String toolCallId;
  final String? runId;
  final String? errorText;

  const ChatClientToolFixtureAppliedEvent({
    required this.hookId,
    required this.threadId,
    required this.toolName,
    required this.input,
    required this.output,
    required this.messageId,
    required this.toolCallId,
    this.execute,
    this.message,
    this.runId,
    this.errorText,
  });

  Map<String, dynamic> toJson() => {
        'hookId': hookId,
        'threadId': threadId,
        'toolName': toolName,
        'input': input,
        'output': output,
        if (execute != null) 'execute': execute,
        if (message != null) 'message': message,
        'messageId': messageId,
        'toolCallId': toolCallId,
        if (runId != null) 'runId': runId,
        if (errorText != null) 'errorText': errorText,
      };
}

class ChatClientStructuredOutputEvent {
  final String status;
  final String? raw;
  final Object? partial;
  final Object? data;
  final String? reasoning;
  final String? errorMessage;
  final String? delta;

  const ChatClientStructuredOutputEvent({
    required this.status,
    this.raw,
    this.partial,
    this.data,
    this.reasoning,
    this.errorMessage,
    this.delta,
  });

  Map<String, dynamic> toJson() => {
        'status': status,
        if (raw != null) 'raw': raw,
        if (partial != null) 'partial': partial,
        if (data != null) 'data': data,
        if (reasoning != null) 'reasoning': reasoning,
        if (errorMessage != null) 'errorMessage': errorMessage,
        if (delta != null) 'delta': delta,
      };
}

/// A devtools event sink. The default global is in-memory/testable; a browser
/// host may replace it with a bridge to `@tanstack/ai-event-client`.
class AiEventClient {
  final List<AiDevtoolsEvent> events = <AiDevtoolsEvent>[];

  void emit(String eventName, Map<String, dynamic> data) {
    events.add(AiDevtoolsEvent(eventName, data));
  }

  void clear() => events.clear();
}

class AiDevtoolsEvent {
  final String name;
  final Map<String, dynamic> data;

  AiDevtoolsEvent(this.name, this.data);

  @override
  String toString() => 'AiDevtoolsEvent($name, $data)';
}

final AiEventClient aiEventClient = AiEventClient();

int _eventCounter = 0;

String _idPart(Object? value) {
  if (value == null || value == '') return 'missing';
  return 'value-${Uri.encodeComponent('$value')}';
}

/// Mirror of `createAIDevtoolsEventEnvelope` for the event fields the client
/// emits. Runtime ids are local to this isolate.
Map<String, dynamic> createAiDevtoolsEventEnvelope({
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
          if (clientId != null) _idPart(clientId),
          if (requestId != null) _idPart(requestId),
          if (streamId != null) _idPart(streamId),
          if (hookId != null) _idPart(hookId),
          if (threadId != null) _idPart(threadId),
          if (runId != null) _idPart(runId),
          if (messageId != null) _idPart(messageId),
          if (toolCallId != null) _idPart(toolCallId),
          '$timestamp',
          '${_eventCounter++}',
        ].join(':');
  return {
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

/// Abstract base class for ChatClient event emission.
abstract class ChatClientEventEmitter {
  final String clientId;

  ChatClientEventEmitter(this.clientId);

  void emitEvent(String eventName, [Map<String, dynamic>? data]);

  void clientCreated(int initialMessageCount) {
    emitEvent('client:created', {'initialMessageCount': initialMessageCount});
  }

  void loadingChanged(bool isLoading) {
    emitEvent('client:loading:changed', {'isLoading': isLoading});
  }

  void errorChanged(String? error) {
    emitEvent('client:error:changed', {'error': error});
  }

  void textUpdated(
    String streamId,
    String messageId,
    String content, [
    ChatClientRunEventContext? context,
  ]) {
    emitEvent('text:chunk:content', {
      'streamId': streamId,
      'messageId': messageId,
      'content': content,
      ...?context?.toJson(),
    });
  }

  void toolCallStateChanged(
    String streamId,
    String messageId,
    String toolCallId,
    String toolName,
    String state,
    String args, [
    ChatClientRunEventContext? context,
  ]) {
    emitEvent('tools:call:updated', {
      'streamId': streamId,
      'messageId': messageId,
      'toolCallId': toolCallId,
      'toolName': toolName,
      'state': state,
      'arguments': args,
      ...?context?.toJson(),
    });
  }

  void thinkingUpdated(
    String streamId,
    String messageId,
    String content, [
    String? delta,
    ChatClientRunEventContext? context,
  ]) {
    emitEvent('text:chunk:thinking', {
      'streamId': streamId,
      'messageId': messageId,
      'content': content,
      if (delta != null) 'delta': delta,
      ...?context?.toJson(),
    });
  }

  void structuredOutputChanged(
    String eventName,
    String streamId,
    String messageId,
    ChatClientStructuredOutputEvent output, [
    ChatClientRunEventContext? context,
  ]) {
    emitEvent(eventName, {
      'streamId': streamId,
      'messageId': messageId,
      ...output.toJson(),
      ...?context?.toJson(),
    });
  }

  void approvalRequested(
    String streamId,
    String messageId,
    String toolCallId,
    String toolName,
    Object? input,
    String approvalId, [
    ChatClientRunEventContext? context,
  ]) {
    emitEvent('tools:approval:requested', {
      'streamId': streamId,
      'messageId': messageId,
      'toolCallId': toolCallId,
      'toolName': toolName,
      'input': input,
      'approvalId': approvalId,
      ...?context?.toJson(),
    });
  }

  void messageAppended(
    Map<String, dynamic> uiMessage, {
    String? streamId,
    ChatClientEventContext? context,
  }) {
    final parts = uiMessage['parts'];
    final content = parts is List
        ? parts
            .whereType<Map>()
            .where((part) => part['type'] == 'text')
            .map((part) => '${part['content'] ?? ''}')
            .join(' ')
        : '';
    emitEvent('text:message:created', {
      if (streamId != null) 'streamId': streamId,
      'messageId': uiMessage['id'],
      'role': uiMessage['role'],
      'content': content,
      'parts': parts,
      ...?context?.toJson(),
    });
  }

  void messageSent(String messageId, Object content) {
    final isMultimodal = content is List;
    final textContent = content is String
        ? content
        : content is List
            ? content
                .whereType<Map>()
                .where((part) => part['type'] == 'text')
                .map((part) => '${part['content'] ?? ''}')
                .join()
            : '$content';
    emitEvent('text:message:created', {
      'messageId': messageId,
      'role': 'user',
      'content': textContent,
      if (isMultimodal) 'parts': content,
    });
    emitEvent('text:message:user', {
      'messageId': messageId,
      'role': 'user',
      'content': textContent,
      if (isMultimodal) 'parts': content,
    });
  }

  void reloaded(int fromMessageIndex) {
    emitEvent('client:reloaded', {'fromMessageIndex': fromMessageIndex});
  }

  void stopped() {
    emitEvent('client:stopped');
  }

  void messagesCleared() {
    emitEvent('client:messages:cleared');
  }

  void toolResultAdded(
    String toolCallId,
    String toolName,
    Object? output,
    String state, [
    ChatClientEventContext? context,
  ]) {
    emitEvent('tools:result:added', {
      'toolCallId': toolCallId,
      'toolName': toolName,
      'output': output,
      'state': state,
      ...?context?.toJson(),
    });
  }

  void toolApprovalResponded(
    String approvalId,
    String toolCallId,
    bool approved, [
    ChatClientRunEventContext? context,
  ]) {
    emitEvent('tools:approval:responded', {
      'approvalId': approvalId,
      'toolCallId': toolCallId,
      'approved': approved,
      ...?context?.toJson(),
    });
  }

  void toolFixtureApplied(ChatClientToolFixtureAppliedEvent fixture) {
    emitEvent('devtools:tool-fixture:applied', fixture.toJson());
  }
}

/// Default implementation of [ChatClientEventEmitter].
class DefaultChatClientEventEmitter extends ChatClientEventEmitter {
  final AiEventClient eventClient;

  DefaultChatClientEventEmitter(
    super.clientId, {
    AiEventClient? eventClient,
  }) : eventClient = eventClient ?? aiEventClient;

  @override
  void emitEvent(String eventName, [Map<String, dynamic>? data]) {
    final payload = data ?? <String, dynamic>{};
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final isUserVisibleEvent = eventName.startsWith('text:') ||
        eventName.startsWith('tools:') ||
        eventName.startsWith('structured-output:') ||
        eventName == 'devtools:tool-fixture:applied';
    final includesClientContext = eventName.startsWith('client:') ||
        eventName.startsWith('tools:') ||
        eventName.startsWith('text:') ||
        eventName.startsWith('structured-output:') ||
        eventName == 'devtools:tool-fixture:applied';
    final visibility = isUserVisibleEvent ? 'user-visible' : 'client-state';

    final envelope = createAiDevtoolsEventEnvelope(
      eventType: eventName,
      source: 'client',
      visibility: visibility,
      timestamp: timestamp,
      clientId: includesClientContext ? clientId : null,
      hookId: includesClientContext ? clientId : null,
      threadId:
          payload['threadId'] is String ? payload['threadId'] as String : null,
      runId: payload['runId'] is String ? payload['runId'] as String : null,
      streamId:
          payload['streamId'] is String ? payload['streamId'] as String : null,
      messageId: payload['messageId'] is String
          ? payload['messageId'] as String
          : null,
      toolCallId: payload['toolCallId'] is String
          ? payload['toolCallId'] as String
          : null,
    );
    eventClient.emit(eventName, {...payload, ...envelope});
  }
}
