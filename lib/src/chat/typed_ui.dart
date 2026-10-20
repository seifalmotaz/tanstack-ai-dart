/// Typed UI-facing selectors layered on the non-generic UI surface.
///
/// Upstream infers tool input/output and interrupt payload/response types from
/// its schema registrations. Dart has no conditional/mapped types, so these
/// helpers take an explicit type argument (or bind it from a real
/// [ClientTool]) and keep the result typed at the consumer. Runtime name/part
/// checks prevent a typed view from being attached to the wrong part.
library;

import '../protocol.dart';
import 'types.dart';
import 'ui_selectors.dart';

/// A tool-call view whose input/output types come from [ClientTool].
///
/// `hasInput` / `hasOutput` preserve presence separately from a valid `null`
/// value. A tool result part may be supplied when output lives on the separate
/// `tool-result` part.
class ChatTypedToolPart<TInput, TOutput> {
  final AssistantPart part;
  final AssistantPart? result;
  final ChatInterrupt? interrupt;
  final TInput? input;
  final TOutput? output;
  final bool hasInput;
  final bool hasOutput;

  const ChatTypedToolPart({
    required this.part,
    required this.input,
    required this.output,
    required this.hasInput,
    required this.hasOutput,
    this.result,
    this.interrupt,
  });

  String get name => part.name;
  String get toolCallId => part.id;
}

/// Select a typed tool-call view by matching [AssistantPart.name] to [tool].
///
/// Returns `null` for a different part type or tool name. Input/output casts
/// use the supplied tool's generic parameters; a schema-invalid wire value
/// throws instead of silently becoming `null`.
ChatTypedToolPart<TInput, TOutput>? selectToolPart<TInput, TOutput>(
  AssistantPart part,
  ClientTool<TInput, TOutput> tool, {
  AssistantPart? result,
  ChatInterrupt? interrupt,
}) {
  if (part.type != 'tool-call' || part.name != tool.name) return null;
  if (result != null &&
      (result.type != 'tool-result' || result.toolCallId != part.id)) {
    throw ArgumentError('Tool result must belong to the selected call');
  }
  final hasResultOutput = result?.hasOutput == true;
  final rawOutput = part.hasOutput
      ? part.output
      : hasResultOutput
          ? result?.output
          : null;
  return ChatTypedToolPart<TInput, TOutput>(
    part: part,
    result: result,
    interrupt: interrupt,
    input: part.hasInput ? part.input as TInput? : null,
    output: (part.hasOutput || hasResultOutput) ? rawOutput as TOutput? : null,
    hasInput: part.hasInput,
    hasOutput: part.hasOutput || hasResultOutput,
  );
}

/// A typed `tool-result` view, including the upstream outcome discriminator.
class ChatTypedToolResult<TOutput> {
  final AssistantPart part;
  final TOutput? output;
  final bool hasOutput;
  final String? outcome;

  const ChatTypedToolResult({
    required this.part,
    required this.output,
    required this.hasOutput,
    required this.outcome,
  });

  String get toolCallId => part.toolCallId;
  bool get denied => outcome == 'denied';
  bool get errored => part.state == 'error' || outcome == 'error';
}

/// Select a typed `tool-result` view, or `null` for another part type.
ChatTypedToolResult<TOutput>? selectToolResult<TOutput>(AssistantPart part) {
  if (part.type != 'tool-result') return null;
  return ChatTypedToolResult<TOutput>(
    part: part,
    output: part.hasOutput ? part.output as TOutput? : null,
    hasOutput: part.hasOutput,
    outcome: part.outcome,
  );
}

/// A typed structured-output view.
class ChatTypedStructuredPart<TData> {
  final AssistantPart part;
  final TData? data;
  final TData? partial;
  final bool hasData;
  final bool hasPartial;

  const ChatTypedStructuredPart({
    required this.part,
    required this.data,
    required this.partial,
    required this.hasData,
    required this.hasPartial,
  });

  String get status => part.structuredStatus;
  String get raw => part.raw;
}

/// Select a structured-output part with an explicit data model.
ChatTypedStructuredPart<TData>? selectStructuredPart<TData>(
  AssistantPart part,
) {
  if (part.type != 'structured-output') return null;
  return ChatTypedStructuredPart<TData>(
    part: part,
    data: part.hasData ? part.data as TData? : null,
    partial: part.hasPartial ? part.partial as TData? : null,
    hasData: part.hasData,
    hasPartial: part.hasPartial,
  );
}

/// A text part that keeps the upstream `content: string` contract.
class ChatTypedTextPart {
  final AssistantPart part;

  const ChatTypedTextPart(this.part);

  String get content => part.content;
}

ChatTypedTextPart? selectTextPart(AssistantPart part) =>
    part.type == 'text' ? ChatTypedTextPart(part) : null;

/// An activity part with its upstream `activityType` / `content` fields.
class ChatTypedActivityPart {
  final AssistantPart part;

  const ChatTypedActivityPart(this.part);

  String get activityType => part.activityType;
  Object? get content => part.activityContent;
}

ChatTypedActivityPart? selectActivityPart(AssistantPart part) =>
    part.type == 'activity' ? ChatTypedActivityPart(part) : null;

/// A registered generic-interrupt view with typed payload and response.
///
/// `definitionId` is the explicit equivalent of upstream's registered
/// interrupt-key inference. When supplied, a different definition returns
/// `null`; when omitted, any generic interrupt is accepted.
class ChatTypedInterrupt<TPayload, TResponse> {
  final ChatInterrupt interrupt;
  final TPayload? payload;
  final bool hasPayload;

  const ChatTypedInterrupt({
    required this.interrupt,
    required this.payload,
    required this.hasPayload,
  });

  String get definitionId =>
      interrupt.definitionId ?? interrupt.definition?.id ?? '';

  bool get canResolve => interrupt.canResolve;

  Object? resolve(TResponse response) => interrupt.resolveInterrupt(response);
  Object? cancel() => interrupt.cancel();
  void clearResolution() => interrupt.clearResolution();
}

ChatTypedInterrupt<TPayload, TResponse>?
    selectRegisteredInterrupt<TPayload, TResponse>(
  ChatInterrupt interrupt, {
  String? definitionId,
}) {
  if (interrupt.kind != 'generic' || !interrupt.resumable) return null;
  final registeredId = interrupt.definitionId ?? interrupt.definition?.id;
  if (definitionId != null &&
      definitionId.isNotEmpty &&
      registeredId != definitionId) {
    return null;
  }
  return ChatTypedInterrupt<TPayload, TResponse>(
    interrupt: interrupt,
    payload: interrupt.payload as TPayload?,
    hasPayload: interrupt.payload != null,
  );
}

/// Convenience view over the existing non-generic selection result.
ChatTypedToolPart<TInput, TOutput>? selectFromUI<TInput, TOutput>(
  ChatUISelectedToolPart selected,
  ClientTool<TInput, TOutput> tool,
) =>
    selectToolPart<TInput, TOutput>(
      selected.part,
      tool,
      result: selected.result,
      interrupt: selected.interrupt,
    );
