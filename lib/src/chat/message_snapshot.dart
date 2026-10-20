import '../protocol.dart';

AssistantTurn freezeAssistantTurn(AssistantTurn source) =>
    _SnapshotTurn(source);

dynamic freezeSnapshotValue(dynamic value) => _freeze(value);

Never _readOnly() => throw UnsupportedError('Chat snapshots are read-only');

Map<String, dynamic>? _map(Map<String, dynamic>? value) => value == null
    ? null
    : Map<String, dynamic>.unmodifiable(
        {for (final entry in value.entries) entry.key: _freeze(entry.value)});

dynamic _freeze(dynamic value) {
  if (value is Map<String, dynamic>) {
    return _map(value);
  }
  if (value is Map) {
    return Map<dynamic, dynamic>.unmodifiable(
        value.map((key, item) => MapEntry(key, _freeze(item))));
  }
  if (value is List) {
    return List<dynamic>.unmodifiable(value.map(_freeze));
  }
  return value;
}

class _SnapshotTurn extends AssistantTurn {
  _SnapshotTurn(AssistantTurn source)
      : super(
            id: source.id,
            role: source.role,
            parts: List<AssistantPart>.unmodifiable(
                source.parts.map(_SnapshotPart.new)),
            streaming: source.streaming,
            name: source.name,
            metadata: _map(source.metadata),
            createdAt: source.createdAt);
  @override
  set streaming(bool value) => _readOnly();
  @override
  set name(String? value) => _readOnly();
  @override
  set metadata(Map<String, dynamic>? value) => _readOnly();
  @override
  set createdAt(DateTime? value) => _readOnly();
}

class _SnapshotApproval extends AssistantApproval {
  _SnapshotApproval(AssistantApproval source)
      : super(
            id: source.id,
            needsApproval: source.needsApproval,
            approved: source.approved,
            wireFields: _map(source.wireFields));
  @override
  set approved(bool? value) => _readOnly();
}

class _SnapshotPart extends AssistantPart {
  _SnapshotPart(AssistantPart source)
      : super(
          type: source.type,
          id: source.id,
          content: source.content,
          name: source.name,
          arguments: source.arguments,
          input: _freeze(source.input),
          hasInput: source.hasInput,
          output: _freeze(source.output),
          hasOutput: source.hasOutput,
          state: source.state,
          approval: source.approval == null
              ? null
              : _SnapshotApproval(source.approval!),
          toolCallId: source.toolCallId,
          activityType: source.activityType,
          activityContent: _freeze(source.activityContent),
          signature: source.signature,
          redacted: source.redacted,
          structuredStatus: source.structuredStatus,
          raw: source.raw,
          partial: _freeze(source.partial),
          hasPartial: source.hasPartial,
          reasoning: source.reasoning,
          hasReasoning: source.hasReasoning,
          data: _freeze(source.data),
          hasData: source.hasData,
          outcome: source.outcome,
          error: source.error,
          subagent: _map(source.subagent),
          resource: _map(source.resource),
          source: _map(source.source),
          metadata: _map(source.metadata)!,
          wireFields: _map(source.wireFields),
        );
  @override
  set type(String value) => _readOnly();
  @override
  set id(String value) => _readOnly();
  @override
  set content(String value) => _readOnly();
  @override
  set name(String value) => _readOnly();
  @override
  set arguments(String value) => _readOnly();
  @override
  set input(dynamic value) => _readOnly();
  @override
  set hasInput(bool value) => _readOnly();
  @override
  set output(dynamic value) => _readOnly();
  @override
  set hasOutput(bool value) => _readOnly();
  @override
  set state(String value) => _readOnly();
  @override
  set approval(AssistantApproval? value) => _readOnly();
  @override
  set toolCallId(String value) => _readOnly();
  @override
  set activityType(String value) => _readOnly();
  @override
  set activityContent(dynamic value) => _readOnly();
  @override
  set signature(String value) => _readOnly();
  @override
  set redacted(bool value) => _readOnly();
  @override
  set outcome(String? value) => _readOnly();
  @override
  set error(String value) => _readOnly();
  @override
  set structuredStatus(String value) => _readOnly();
  @override
  set raw(String value) => _readOnly();
  @override
  set partial(dynamic value) => _readOnly();
  @override
  set hasPartial(bool value) => _readOnly();
  @override
  set reasoning(String value) => _readOnly();
  @override
  set hasReasoning(bool value) => _readOnly();
  @override
  set data(dynamic value) => _readOnly();
  @override
  set hasData(bool value) => _readOnly();
  @override
  set subagent(Map<String, dynamic>? value) => _readOnly();
  @override
  set resource(Map<String, dynamic>? value) => _readOnly();
  @override
  set source(Map<String, dynamic>? value) => _readOnly();
  @override
  set metadata(Map<String, dynamic> value) => _readOnly();
}

/// Copy mutable JSON containers without changing opaque application values.
AssistantTurn copyAssistantTurn(AssistantTurn source) => AssistantTurn(
      id: source.id,
      role: source.role,
      streaming: source.streaming,
      name: source.name,
      createdAt: source.createdAt,
      metadata: _copy(source.metadata) as Map<String, dynamic>?,
      parts: [for (final part in source.parts) copyAssistantPart(part)],
    );

AssistantPart copyAssistantPart(AssistantPart source) =>
    AssistantPart.fromJson(_copy(source.toJson()));

dynamic _copy(dynamic value) {
  if (value is Map<String, dynamic>) {
    return <String, dynamic>{
      for (final entry in value.entries) entry.key: _copy(entry.value)
    };
  }
  if (value is Map) return value.map((key, item) => MapEntry(key, _copy(item)));
  if (value is List) return value.map(_copy).toList();
  return value;
}
