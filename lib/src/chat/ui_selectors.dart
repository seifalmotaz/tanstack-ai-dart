import '../protocol.dart';
import 'types.dart';

const Map<String, String> _partKeyByType = <String, String>{
  'text': 'text',
  'image': 'image',
  'audio': 'audio',
  'video': 'video',
  'document': 'document',
  'thinking': 'thinking',
  'activity': 'activity',
  'tool-call': 'toolCall',
  'tool-result': 'toolResult',
  'structured-output': 'structuredOutput',
  'ui-resource': 'uiResource',
  'subagent': 'subagent',
};

String partTypeToKey(String type) {
  final mapped = _partKeyByType[type];
  if (mapped != null) return mapped;
  return type.replaceAllMapped(
    RegExp(r'-([a-z])'),
    (match) => match.group(1)!.toUpperCase(),
  );
}

List<String> collectInlineToolNames(
  Map<String, dynamic>? toolInterrupts,
  List<String>? mappedToolNames,
) {
  final placed = (toolInterrupts ?? const <String, dynamic>{}).keys.toSet();
  return [
    for (final name in mappedToolNames ?? const <String>[])
      if (!placed.contains(name)) name,
  ];
}

Object? resolveInterruptComponent(
  ChatInterrupt interrupt,
  Map<String, dynamic>? interruptsMap,
) {
  if (interruptsMap == null) return null;
  if (interrupt.kind == 'tool-approval') {
    final tools = interruptsMap['tools'];
    if (tools is! Map) return null;
    return tools[interrupt.toolName];
  }
  final generic = interruptsMap['generic'];
  if (generic is! Map) return null;
  final definitionId = interrupt.definitionId;
  if (definitionId != null &&
      definitionId.isNotEmpty &&
      definitionId != 'fallback') {
    final registered = generic[definitionId];
    if (registered != null) return registered;
  }
  return generic['fallback'];
}

class ChatUISelectedToolPart {
  final String key = 'toolCall';
  final AssistantPart part;
  final AssistantPart? result;
  final ChatInterrupt? interrupt;
  final dynamic input;
  final dynamic output;

  const ChatUISelectedToolPart({
    required this.part,
    this.result,
    this.interrupt,
    this.input,
    this.output,
  });

  @override
  String toString() => 'ChatUISelectedToolPart(${part.id})';
}

class ChatUISelectedResultPart {
  final String key = 'toolResult';
  final AssistantPart part;
  final bool matched;

  const ChatUISelectedResultPart({required this.part, required this.matched});

  @override
  String toString() => 'ChatUISelectedResultPart(${part.toolCallId})';
}

class ChatUISelectedGenericPart {
  final String key;
  final AssistantPart part;

  const ChatUISelectedGenericPart({required this.key, required this.part});

  @override
  String toString() => 'ChatUISelectedGenericPart($key)';
}

typedef ChatUISelectedPart = Object;

class ChatUISelectedMessage {
  final AssistantTurn message;
  final List<ChatUISelectedPart> parts;

  const ChatUISelectedMessage({required this.message, required this.parts});
}

class ChatUISelection {
  final List<ChatUISelectedMessage> messages;
  final List<ChatInterrupt> interrupts;

  const ChatUISelection({required this.messages, required this.interrupts});
}

class ChatUISelectInput {
  final List<AssistantTurn> messages;
  final List<ChatInterrupt>? interrupts;
  final List<String>? inlineToolNames;

  const ChatUISelectInput({
    required this.messages,
    this.interrupts,
    this.inlineToolNames,
  });
}

ChatUISelection selectChatUI(ChatUISelectInput input) {
  final interrupts = input.interrupts ?? const <ChatInterrupt>[];
  final inlineToolNames = (input.inlineToolNames ?? const <String>[]).toSet();

  final resultsByCallId = <String, AssistantPart>{};
  final callIds = <String>{};
  for (final message in input.messages) {
    for (final part in message.parts) {
      if (part.type == 'tool-call') callIds.add(part.id);
      if (part.type == 'tool-result') {
        resultsByCallId[part.toolCallId] = part;
      }
    }
  }

  final approvalByCallId = <String, ChatInterrupt>{};
  for (final interrupt in interrupts) {
    if (interrupt.kind == 'tool-approval' && interrupt.toolCallId != null) {
      approvalByCallId[interrupt.toolCallId!] = interrupt;
    }
  }

  final selectedMessages = <ChatUISelectedMessage>[
    for (final message in input.messages)
      ChatUISelectedMessage(
        message: message,
        parts: [
          for (final part in message.parts)
            _selectPart(part, resultsByCallId, approvalByCallId, callIds),
        ],
      ),
  ];

  return ChatUISelection(
    messages: selectedMessages,
    interrupts: [
      for (final interrupt in interrupts)
        if (!_hidesInlineInterrupt(interrupt, inlineToolNames, callIds))
          interrupt,
    ],
  );
}

bool _hidesInlineInterrupt(
  ChatInterrupt interrupt,
  Set<String> inlineToolNames,
  Set<String> callIds,
) {
  if (interrupt.kind != 'tool-approval') return false;
  final name = interrupt.toolName;
  if (name == null || !inlineToolNames.contains(name)) return false;
  final callId = interrupt.toolCallId;
  return callId != null && callIds.contains(callId);
}

ChatUISelectedPart _selectPart(
  AssistantPart part,
  Map<String, AssistantPart> resultsByCallId,
  Map<String, ChatInterrupt> approvalByCallId,
  Set<String> callIds,
) {
  if (part.type == 'tool-call') {
    final result = resultsByCallId[part.id];
    final interrupt = approvalByCallId[part.id];
    return ChatUISelectedToolPart(
      part: part,
      result: result,
      interrupt: interrupt,
      input: part.input,
      output: part.output ?? result?.output,
    );
  }
  if (part.type == 'tool-result') {
    return ChatUISelectedResultPart(
      part: part,
      matched: callIds.contains(part.toolCallId),
    );
  }
  return ChatUISelectedGenericPart(key: partTypeToKey(part.type), part: part);
}

List<ChatUISelectedPart> automaticPartsForMessage(
  ChatUISelectedMessage selected,
) =>
    [
      for (final part in selected.parts)
        if (!(part is ChatUISelectedResultPart && part.matched)) part,
    ];

ChatUISelectedMessage selectMessageUI(
  AssistantTurn message,
  ChatUISelectInput input,
) {
  final selection = selectChatUI(
    ChatUISelectInput(
      messages: <AssistantTurn>[message],
      interrupts: input.interrupts,
      inlineToolNames: input.inlineToolNames,
    ),
  );
  return selection.messages.isEmpty
      ? ChatUISelectedMessage(
          message: message,
          parts: const <ChatUISelectedPart>[],
        )
      : selection.messages.first;
}
