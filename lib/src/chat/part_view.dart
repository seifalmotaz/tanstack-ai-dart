/// Immutable, exhaustive consumer views over the mutable wire protocol parts.
///
/// [ChatPart.fromPart] snapshots the supplied [AssistantPart] through its wire
/// JSON and deep-freezes every JSON container. The original part and its
/// nested maps/lists are therefore never aliased, and [ChatPart.wire] remains
/// the lossless original wire shape (including unknown/future fields).
library;

import '../protocol.dart';
import 'message_snapshot.dart';

/// A read-only view of one [AssistantPart].
///
/// The sealed hierarchy lets consumers switch exhaustively over the protocol
/// part types without touching the mutable reducer models.
sealed class ChatPart {
  final String type;

  /// Lossless, deep-frozen wire JSON for this part.
  final Map<String, dynamic> wire;

  ChatPart._(this.type, this.wire);

  /// Snapshot [source] and return the matching typed view.
  ///
  /// Unknown/future part types become [ChatUnknownPart] without losing any
  /// wire fields.
  factory ChatPart.fromPart(AssistantPart source) {
    final wire = _freezeWire(source.toJson());
    final part = AssistantPart.fromJson(wire);
    final approval = _mapOrNull(wire['approval']);

    switch (part.type) {
      case 'text':
        return ChatTextPart._(wire, part.content);
      case 'thinking':
        return ChatThinkingPart._(
          wire,
          id: part.id,
          content: part.content,
          signature: part.signature,
          redacted: part.redacted,
        );
      case 'tool-call':
        return ChatToolCallPart._(
          wire,
          id: part.id,
          name: part.name,
          arguments: part.arguments,
          input: part.input,
          hasInput: part.hasInput,
          output: part.output,
          hasOutput: part.hasOutput,
          state: part.state,
          approval: approval,
        );
      case 'tool-result':
        return ChatToolResultPart._(
          wire,
          id: part.id,
          name: part.name,
          toolCallId: part.toolCallId,
          content: part.content,
          output: part.output,
          hasOutput: part.hasOutput,
          state: part.state,
          outcome: part.outcome,
          error: part.error,
        );
      case 'activity':
        return ChatActivityPart._(
          wire,
          id: part.id,
          activityType: part.activityType,
          content: part.activityContent,
        );
      case 'structured-output':
        return ChatStructuredPart._(
          wire,
          status: part.structuredStatus,
          raw: part.raw,
          data: part.data,
          hasData: part.hasData,
          partial: part.partial,
          hasPartial: part.hasPartial,
          reasoning: part.reasoning,
          hasReasoning: part.hasReasoning,
          errorMessage: part.content,
        );
      case 'subagent':
        return ChatSubagentPart._(
          wire,
          id: part.id,
          subagent: _mapOrNull(wire['subagent']),
        );
      case 'image':
      case 'audio':
      case 'video':
      case 'document':
        return ChatMediaPart._(
          wire,
          mediaType: part.type,
          id: part.id,
          source: _mapOrNull(wire['source']),
        );
      default:
        return ChatUnknownPart._(wire, part.type);
    }
  }

  /// Alias for [wire] for callers that expect a JSON conversion method.
  Map<String, dynamic> toJson() => wire;
}

final class ChatTextPart extends ChatPart {
  final String content;

  ChatTextPart._(Map<String, dynamic> wire, this.content)
      : super._('text', wire);
}

final class ChatThinkingPart extends ChatPart {
  final String id;
  final String content;
  final String signature;
  final bool redacted;

  ChatThinkingPart._(
    Map<String, dynamic> wire, {
    required this.id,
    required this.content,
    required this.signature,
    required this.redacted,
  }) : super._('thinking', wire);
}

final class ChatToolCallPart extends ChatPart {
  final String id;
  final String name;
  final String arguments;
  final Object? input;
  final bool hasInput;
  final Object? output;
  final bool hasOutput;
  final String state;
  final Map<String, dynamic>? approval;

  ChatToolCallPart._(
    Map<String, dynamic> wire, {
    required this.id,
    required this.name,
    required this.arguments,
    required this.input,
    required this.hasInput,
    required this.output,
    required this.hasOutput,
    required this.state,
    required this.approval,
  }) : super._('tool-call', wire);
}

final class ChatToolResultPart extends ChatPart {
  final String id;
  final String name;
  final String toolCallId;
  final String content;
  final Object? output;
  final bool hasOutput;
  final String state;
  final String? outcome;
  final String error;

  ChatToolResultPart._(
    Map<String, dynamic> wire, {
    required this.id,
    required this.name,
    required this.toolCallId,
    required this.content,
    required this.output,
    required this.hasOutput,
    required this.state,
    required this.outcome,
    required this.error,
  }) : super._('tool-result', wire);
}

final class ChatActivityPart extends ChatPart {
  final String id;
  final String activityType;
  final Object? content;

  ChatActivityPart._(
    Map<String, dynamic> wire, {
    required this.id,
    required this.activityType,
    required this.content,
  }) : super._('activity', wire);
}

final class ChatStructuredPart extends ChatPart {
  final String status;
  final String raw;
  final Object? data;
  final bool hasData;
  final Object? partial;
  final bool hasPartial;
  final String reasoning;
  final bool hasReasoning;
  final String errorMessage;

  ChatStructuredPart._(
    Map<String, dynamic> wire, {
    required this.status,
    required this.raw,
    required this.data,
    required this.hasData,
    required this.partial,
    required this.hasPartial,
    required this.reasoning,
    required this.hasReasoning,
    required this.errorMessage,
  }) : super._('structured-output', wire);
}

final class ChatSubagentPart extends ChatPart {
  final String id;
  final Map<String, dynamic>? subagent;

  ChatSubagentPart._(
    Map<String, dynamic> wire, {
    required this.id,
    required this.subagent,
  }) : super._('subagent', wire);
}

/// A media part (`image`, `audio`, `video` or `document`).
final class ChatMediaPart extends ChatPart {
  final String id;
  final Map<String, dynamic>? source;

  ChatMediaPart._(
    Map<String, dynamic> wire, {
    required String mediaType,
    required this.id,
    required this.source,
  }) : super._(mediaType, wire);

  String get mediaType => type;
}

/// Any part type without a dedicated view, including future protocol types.
final class ChatUnknownPart extends ChatPart {
  ChatUnknownPart._(Map<String, dynamic> wire, String type)
      : super._(type, wire);
}

extension AssistantPartChatView on AssistantPart {
  /// Immutable exhaustive view of this part.
  ChatPart get chatPart => ChatPart.fromPart(this);
}

extension AssistantTurnChatViews on AssistantTurn {
  /// Immutable exhaustive views of this turn's parts.
  List<ChatPart> get chatParts =>
      List<ChatPart>.unmodifiable(parts.map(ChatPart.fromPart));
}

Map<String, dynamic> _freezeWire(Map<String, dynamic> value) =>
    freezeSnapshotValue(value) as Map<String, dynamic>;

Map<String, dynamic>? _mapOrNull(Object? value) =>
    value is Map<String, dynamic> ? value : _mapOrNullUnchecked(value);

Map<String, dynamic>? _mapOrNullUnchecked(Object? value) {
  if (value is! Map) return null;
  return Map<String, dynamic>.unmodifiable(
    value.map((key, item) => MapEntry('$key', item)),
  );
}
