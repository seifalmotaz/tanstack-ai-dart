import 'dart:convert';

import 'identity.dart';

const _absentOutput = Object();
const _absentInput = Object();
const _absentValue = Object();

/// A human-approval request attached to a tool-call part.
class AssistantApproval {
  final String id;
  final bool needsApproval;
  bool? approved;

  /// Original wire fields, preserved for exact round-trips and snapshots.
  final Map<String, dynamic>? wireFields;

  AssistantApproval({
    required this.id,
    this.needsApproval = true,
    this.approved,
    this.wireFields,
  });

  factory AssistantApproval.fromJson(dynamic raw) {
    final m = _asMap(raw);
    return AssistantApproval(
      id: _strVal(m['id']),
      needsApproval: m['needsApproval'] != false,
      approved: m['approved'] is bool ? m['approved'] as bool : null,
      wireFields: m,
    );
  }

  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{...?wireFields};
    out['id'] = id;
    out['needsApproval'] = needsApproval;
    if (approved != null) {
      out['approved'] = approved;
    } else if (wireFields?.containsKey('approved') == true) {
      out['approved'] = null;
    } else {
      out.remove('approved');
    }
    return out;
  }
}

/// One displayable piece of an assistant turn.
class AssistantPart {
  String type;
  String id;
  String content;
  String name;
  String arguments;

  dynamic _input;
  dynamic get input => _input;
  set input(dynamic value) {
    _input = value;
    hasInput = true;
  }

  /// True when [input] is present on the wire, including an explicit `null`.
  bool hasInput;

  dynamic _output;
  dynamic get output => _output;
  set output(dynamic value) {
    _output = value;
    hasOutput = true;
  }

  /// True when [output] is present on the wire, including an explicit `null`.
  bool hasOutput;
  String state;
  AssistantApproval? approval;

  /// Tool-result correlation (wire `toolCallId`).
  String toolCallId;

  /// Activity parts (`ACTIVITY_SNAPSHOT` / `ACTIVITY_DELTA`).
  String activityType;
  dynamic activityContent;

  /// Thinking provider signature / redaction marker.
  String signature;
  bool redacted;

  /// Structured-output parts (`CUSTOM structured-output.*`).
  String structuredStatus;
  String raw;

  dynamic _partial;
  dynamic get partial => _partial;
  set partial(dynamic value) {
    _partial = value;
    hasPartial = true;
  }

  bool hasPartial;

  String _reasoning = '';
  String get reasoning => _reasoning;
  set reasoning(String value) {
    _reasoning = value;
    hasReasoning = true;
  }

  bool hasReasoning;

  dynamic _data;
  dynamic get data => _data;
  set data(dynamic value) {
    _data = value;
    hasData = true;
  }

  bool hasData;

  /// Tool-result metadata (`outcome` / `error`).
  String? outcome;
  String error;

  /// Subagent cards (`SUBAGENT_*`).
  Map<String, dynamic>? subagent;

  /// UI resource parts.
  Map<String, dynamic>? resource;

  /// Media parts (`image`, `audio`, `video`, `document`).
  Map<String, dynamic>? source;

  /// Extensible AG-UI metadata preserved on parts.
  Map<String, dynamic> metadata;

  /// Original wire fields. Used to preserve unknown/future fields and to keep
  /// modern parsed parts free of legacy default fields.
  final Map<String, dynamic>? wireFields;

  AssistantPart({
    required this.type,
    this.id = '',
    this.content = '',
    this.name = '',
    this.arguments = '',
    dynamic input = _absentInput,
    bool? hasInput,
    dynamic output = _absentOutput,
    bool? hasOutput,
    this.state = 'input-complete',
    this.approval,
    this.toolCallId = '',
    this.activityType = '',
    this.activityContent,
    this.signature = '',
    this.redacted = false,
    this.structuredStatus = '',
    this.raw = '',
    dynamic partial = _absentValue,
    bool? hasPartial,
    dynamic reasoning = _absentValue,
    bool? hasReasoning,
    dynamic data = _absentValue,
    bool? hasData,
    this.outcome,
    this.error = '',
    this.subagent,
    this.resource,
    this.source,
    Map<String, dynamic>? metadata,
    this.wireFields,
  })  : _input = identical(input, _absentInput) ? null : input,
        hasInput = hasInput ?? !identical(input, _absentInput),
        _output = identical(output, _absentOutput) ? null : output,
        hasOutput = hasOutput ?? !identical(output, _absentOutput),
        _partial = identical(partial, _absentValue) ? null : partial,
        hasPartial = hasPartial ?? !identical(partial, _absentValue),
        _reasoning = identical(reasoning, _absentValue)
            ? ''
            : (reasoning is String ? reasoning : '$reasoning'),
        hasReasoning = hasReasoning ?? !identical(reasoning, _absentValue),
        _data = identical(data, _absentValue) ? null : data,
        hasData = hasData ?? !identical(data, _absentValue),
        metadata = metadata ?? <String, dynamic>{};

  factory AssistantPart.text(String content) =>
      AssistantPart(type: 'text', content: content);

  factory AssistantPart.thinking({required String id, String content = ''}) =>
      AssistantPart(type: 'thinking', id: id, content: content);

  factory AssistantPart.tool({
    required String id,
    required String name,
    String arguments = '',
    dynamic input = _absentInput,
    dynamic output = _absentOutput,
    bool? hasOutput,
    String state = 'input-complete',
    AssistantApproval? approval,
    Map<String, dynamic>? metadata,
  }) =>
      AssistantPart(
        type: 'tool-call',
        id: id,
        name: name,
        arguments: arguments,
        input: input,
        output: output,
        hasOutput: hasOutput,
        state: state,
        approval: approval,
        metadata: metadata,
      );

  bool _had(String key) => wireFields?.containsKey(key) ?? false;

  Map<String, dynamic> _baseJson() => <String, dynamic>{...?wireFields};

  factory AssistantPart.fromJson(dynamic raw) {
    final m = _asMap(raw);
    final type = _strVal(m['type']);
    if (type == 'tool-call' || type == 'tool') {
      return AssistantPart(
        type: 'tool-call',
        id: _strVal(m['id'], 'tool'),
        name: _strVal(m['name'] ?? m['toolName'], 'tool'),
        arguments: _strVal(m['arguments']),
        input: m.containsKey('input') ? m['input'] : _absentInput,
        output: m.containsKey('output')
            ? m['output']
            : m.containsKey('result')
                ? m['result']
                : _absentOutput,
        state: _strVal(m['state'], 'complete'),
        approval: m['approval'] is Map
            ? AssistantApproval.fromJson(m['approval'])
            : null,
        metadata: m['metadata'] is Map ? _asMap(m['metadata']) : null,
        wireFields: m,
      );
    }
    if (type == 'tool-result') {
      final content = m['content'] ?? m['output'];
      return AssistantPart(
        type: type,
        id: _strVal(m['id']),
        name: _strVal(m['name']),
        toolCallId: _strVal(m['toolCallId']),
        content: content is String ? content : '',
        output: m.containsKey('content')
            ? content
            : m.containsKey('output')
                ? m['output']
                : _absentOutput,
        state: _strVal(m['state'], 'complete'),
        outcome: m.containsKey('outcome') ? _strVal(m['outcome']) : null,
        error: _strVal(m['error']),
        metadata: m['metadata'] is Map ? _asMap(m['metadata']) : null,
        wireFields: m,
      );
    }
    if (type == 'activity') {
      return AssistantPart(
        type: type,
        id: _strVal(m['messageId'] ?? m['id']),
        activityType: _strVal(m['activityType']),
        activityContent: m['content'],
        metadata: m['metadata'] is Map ? _asMap(m['metadata']) : null,
        wireFields: m,
      );
    }
    if (type == 'structured-output') {
      return AssistantPart(
        type: type,
        structuredStatus: _strVal(m['status'], 'streaming'),
        raw: _strVal(m['raw']),
        partial: m.containsKey('partial') ? m['partial'] : _absentValue,
        reasoning:
            m.containsKey('reasoning') ? _strVal(m['reasoning']) : _absentValue,
        data: m.containsKey('data') ? m['data'] : _absentValue,
        content: _strVal(m['errorMessage']),
        metadata: m['metadata'] is Map ? _asMap(m['metadata']) : null,
        wireFields: m,
      );
    }
    if (type == 'subagent') {
      return AssistantPart(
        type: type,
        id: _strVal(m['subagent'] is Map ? _asMap(m['subagent'])['id'] : ''),
        subagent: m['subagent'] is Map ? _asMap(m['subagent']) : null,
        wireFields: m,
      );
    }
    if (type == 'ui-resource') {
      return AssistantPart(
        type: type,
        id: _strVal(m['id'] ?? m['toolCallId']),
        name: _strVal(m['toolName']),
        toolCallId: _strVal(m['toolCallId']),
        resource: m['resource'] is Map ? _asMap(m['resource']) : null,
        metadata: m['metadata'] is Map ? _asMap(m['metadata']) : null,
        wireFields: m,
      );
    }
    if (type == 'image' ||
        type == 'audio' ||
        type == 'video' ||
        type == 'document') {
      return AssistantPart(
        type: type,
        id: _strVal(m['id']),
        source: m['source'] is Map ? _asMap(m['source']) : null,
        metadata: m['metadata'] is Map ? _asMap(m['metadata']) : null,
        wireFields: m,
      );
    }
    if (type == 'thinking' || type == 'reasoning') {
      return AssistantPart(
        type: type == 'reasoning' ? 'thinking' : type,
        id: _strVal(m['id']),
        content: _strVal(m['content']),
        signature: _strVal(m['signature']),
        redacted: m['redacted'] == true,
        metadata: m['metadata'] is Map ? _asMap(m['metadata']) : null,
        wireFields: m,
      );
    }
    if (type == 'text') {
      return AssistantPart(
        type: 'text',
        content: _strVal(m['content']),
        metadata: m['metadata'] is Map ? _asMap(m['metadata']) : null,
        wireFields: m,
      );
    }
    if (type.isEmpty && m['content'] is String) {
      return AssistantPart.text(m['content'] as String);
    }
    // Unknown/future part type: preserve it instead of collapsing to a tool.
    return AssistantPart(type: type, wireFields: m);
  }

  Map<String, dynamic> toJson() {
    final out = _baseJson();
    out['type'] = type;
    switch (type) {
      case 'text':
        out['content'] = content;
        if (metadata.isNotEmpty || _had('metadata')) {
          out['metadata'] = metadata;
        } else {
          out.remove('metadata');
        }
        break;
      case 'thinking':
        if (id.isNotEmpty || _had('id')) {
          out['id'] = id;
        } else {
          out.remove('id');
        }
        out['content'] = content;
        if (signature.isNotEmpty || _had('signature')) {
          out['signature'] = signature;
        } else {
          out.remove('signature');
        }
        if (redacted || _had('redacted')) {
          out['redacted'] = redacted;
        } else {
          out.remove('redacted');
        }
        if (metadata.isNotEmpty || _had('metadata')) {
          out['metadata'] = metadata;
        } else {
          out.remove('metadata');
        }
        break;
      case 'tool-result':
        if (id.isNotEmpty || _had('id')) {
          out['id'] = id;
        } else {
          out.remove('id');
        }
        if (name.isNotEmpty || _had('name')) {
          out['name'] = name;
        } else {
          out.remove('name');
        }
        out['toolCallId'] = toolCallId;
        out['content'] = hasOutput ? _output : content;
        out['state'] = state;
        if (outcome != null) {
          out['outcome'] = outcome;
        } else {
          out.remove('outcome');
        }
        if (error.isNotEmpty ||
            (wireFields?.containsKey('error') == true && error.isNotEmpty)) {
          out['error'] = error;
        } else {
          out.remove('error');
        }
        if (metadata.isNotEmpty || _had('metadata')) {
          out['metadata'] = metadata;
        } else {
          out.remove('metadata');
        }
        break;
      case 'activity':
        if (id.isNotEmpty || _had('messageId')) {
          out['messageId'] = id;
        } else {
          out.remove('messageId');
        }
        out['activityType'] = activityType;
        out['content'] = activityContent;
        if (metadata.isNotEmpty || _had('metadata')) {
          out['metadata'] = metadata;
        } else {
          out.remove('metadata');
        }
        break;
      case 'structured-output':
        out['status'] =
            structuredStatus.isEmpty ? 'streaming' : structuredStatus;
        out['raw'] = raw;
        if (hasPartial) {
          out['partial'] = partial;
        } else {
          out.remove('partial');
        }
        if (hasReasoning) {
          out['reasoning'] = reasoning;
        } else {
          out.remove('reasoning');
        }
        if (hasData) {
          out['data'] = _data;
        } else {
          out.remove('data');
        }
        if (content.isNotEmpty) {
          out['errorMessage'] = content;
        } else {
          out.remove('errorMessage');
        }
        if (metadata.isNotEmpty || _had('metadata')) {
          out['metadata'] = metadata;
        } else {
          out.remove('metadata');
        }
        break;
      case 'subagent':
        out['subagent'] = subagent ?? <String, dynamic>{};
        break;
      case 'ui-resource':
        if (wireFields != null) {
          // Modern flat shape: keep id/uri/mimeType/content and any future
          // fields. Only managed legacy fields that were present are written.
          if (id.isNotEmpty || _had('id')) {
            out['id'] = id;
          }
          if (toolCallId.isNotEmpty || _had('toolCallId')) {
            out['toolCallId'] = toolCallId.isEmpty ? id : toolCallId;
          }
          if (name.isNotEmpty || _had('toolName')) {
            out['toolName'] = name;
          }
          if (resource != null) {
            out['resource'] = resource;
          } else if (_had('resource')) {
            out.remove('resource');
          }
        } else {
          // Legacy shape.
          out['resource'] = resource ?? <String, dynamic>{};
          out['toolCallId'] = toolCallId.isEmpty ? id : toolCallId;
          out['toolName'] = name;
        }
        if (metadata.isNotEmpty || _had('metadata')) {
          out['metadata'] = metadata;
        } else {
          out.remove('metadata');
        }
        break;
      case 'image':
      case 'audio':
      case 'video':
      case 'document':
        if (id.isNotEmpty || _had('id')) {
          out['id'] = id;
        } else {
          out.remove('id');
        }
        if (source != null) {
          out['source'] = source;
        } else {
          out.remove('source');
        }
        if (metadata.isNotEmpty || _had('metadata')) {
          out['metadata'] = metadata;
        } else {
          out.remove('metadata');
        }
        break;
      case 'tool-call':
      case 'tool':
        out['type'] = 'tool-call';
        out['id'] = id;
        out['name'] = name;
        if (arguments.isNotEmpty || _had('arguments') || wireFields == null) {
          out['arguments'] = arguments;
        } else {
          out.remove('arguments');
        }
        out['state'] = state;
        if (hasInput) {
          out['input'] = _input;
        } else {
          out.remove('input');
        }
        if (hasOutput) {
          out['output'] = _output;
        } else {
          out.remove('output');
        }
        if (approval != null) {
          out['approval'] = approval!.toJson();
        } else {
          out.remove('approval');
        }
        if (metadata.isNotEmpty || _had('metadata')) {
          out['metadata'] = metadata;
        } else {
          out.remove('metadata');
        }
        break;
      default:
        out['type'] = type;
        break;
    }
    return out;
  }

  String get wireArguments {
    if (arguments.trim().isNotEmpty) return arguments;
    if (input != null) return jsonEncode(input);
    return '{}';
  }
}

/// A user or assistant message made of [AssistantPart]s.
class AssistantTurn {
  final String id;
  final String role;
  final List<AssistantPart> parts;
  bool streaming;

  /// Optional AG-UI sender name.
  String? name;

  /// Optional wire metadata (`{tanstack: {...}}` etc.).
  Map<String, dynamic>? metadata;

  /// Optional creation time; [toRow] uses `now` when absent for compatibility.
  DateTime? createdAt;

  AssistantTurn({
    required this.id,
    required this.role,
    List<AssistantPart>? parts,
    this.streaming = false,
    this.name,
    this.metadata,
    this.createdAt,
  }) : parts = parts ?? <AssistantPart>[];

  factory AssistantTurn.user(String text, {String id = ''}) => AssistantTurn(
        id: id.isEmpty ? generateIdentity('user') : id,
        role: 'user',
        parts: [AssistantPart.text(text)],
      );

  factory AssistantTurn.assistant({
    String id = '',
    Map<String, dynamic>? metadata,
    DateTime? createdAt,
  }) =>
      AssistantTurn(
        id: id.isEmpty ? generateIdentity('assistant') : id,
        role: 'assistant',
        metadata: metadata,
        createdAt: createdAt,
      );

  /// Frontend-only activity message (`role: activity`).
  factory AssistantTurn.activity({
    String id = '',
    required List<AssistantPart> parts,
  }) =>
      AssistantTurn(
        id: id.isEmpty ? generateIdentity('activity') : id,
        role: 'activity',
        parts: parts,
      );

  String get answer => parts
      .where((p) => p.type == 'text')
      .map((p) => p.content.trim())
      .where((s) => s.isNotEmpty)
      .join('\n\n');

  Iterable<AssistantPart> get thoughts =>
      parts.where((p) => p.type == 'thinking');
  Iterable<AssistantPart> get tools =>
      parts.where((p) => p.type == 'tool-call');

  void mergeParts(Iterable<AssistantPart> incoming) {
    for (final part in incoming) {
      if (part.type == 'tool-call' && part.id.isNotEmpty) {
        final i = parts.indexWhere(
          (p) => p.type == 'tool-call' && p.id == part.id,
        );
        if (i >= 0) {
          final previous = parts[i];
          parts[i] = _toolRank(part.state) >= _toolRank(previous.state)
              ? part
              : previous;
          continue;
        }
      }
      parts.add(part);
    }
  }

  Map<String, dynamic> toRow() => {
        'id': id,
        'role': role,
        'parts': parts.map((p) => p.toJson()).toList(),
        'createdAt': (createdAt ?? DateTime.now()).toIso8601String(),
        if (name != null) 'name': name,
        if (metadata != null) 'metadata': metadata,
      };
}

int _toolRank(String state) => switch (state) {
      'input-streaming' => 1,
      'input-available' || 'input-complete' => 2,
      'approval-requested' => 3,
      'approval-responded' => 4,
      'complete' || 'error' => 6,
      _ => 0,
    };

/// Folds legacy AG-UI SSE events into display parts.
///
/// Thinking/reasoning never becomes answer text; only `text` parts
/// participate in [AssistantTurn.answer].
class AssistantStreamReducer {
  final List<AssistantPart> parts;
  String? error;
  bool done = false;

  /// Run/thread identity carried by the events seen so far.
  String? runId;
  String? threadId;
  String? finishReason;
  String? model;

  /// True when the terminal event was an interrupt rather than a completion.
  bool interrupted = false;

  /// Raw interrupt descriptors from the terminal event.
  List<Map<String, dynamic>> interrupts = <Map<String, dynamic>>[];

  /// A `MESSAGES_SNAPSHOT` event, when the server sent one.
  List<Map<String, dynamic>>? snapshotMessages;

  AssistantPart? _text;
  AssistantPart? _thinking;
  AssistantPart? _structured;
  final Map<String, AssistantPart> _activityByMessage =
      <String, AssistantPart>{};
  final Map<String, AssistantPart> _subagents = <String, AssistantPart>{};
  int _thoughtSeq = 0;

  AssistantStreamReducer(this.parts);

  void reset() {
    error = null;
    done = false;
    runId = null;
    threadId = null;
    finishReason = null;
    model = null;
    interrupted = false;
    interrupts = <Map<String, dynamic>>[];
    snapshotMessages = null;
    _text = null;
    _thinking = null;
    _structured = null;
    _activityByMessage.clear();
    _subagents.clear();
    _thoughtSeq = 0;
  }

  void apply(Map<String, dynamic> event) {
    final type = _strVal(event['type']);
    if (type.isEmpty) return;

    final eventRunId = _strVal(event['runId']);
    if (eventRunId.isNotEmpty) runId = eventRunId;
    final eventThreadId = _strVal(event['threadId']);
    if (eventThreadId.isNotEmpty) threadId = eventThreadId;

    switch (type) {
      case 'TEXT_MESSAGE_START':
        _thinking = null;
        _newText();
        break;
      case 'TEXT_MESSAGE_CONTENT':
      case 'TEXT_MESSAGE_CHUNK':
        _thinking = null;
        final piece = _strVal(event['delta'] ?? event['content']);
        if (piece.isEmpty) break;
        (_text ?? _newText()).content += piece;
        break;
      case 'TEXT_MESSAGE_END':
        _text = null;
        break;
      case 'THINKING_TEXT_MESSAGE_START':
      case 'REASONING_MESSAGE_START':
      case 'REASONING_START':
      case 'THINKING_START':
        _text = null;
        _thinking ??= _newThinking();
        break;
      case 'THINKING_TEXT_MESSAGE_CONTENT':
      case 'THINKING_TEXT_MESSAGE_CHUNK':
      case 'REASONING_MESSAGE_CONTENT':
      case 'REASONING_MESSAGE_CHUNK':
        _text = null;
        final piece = _strVal(event['delta'] ?? event['content']);
        if (piece.isEmpty) break;
        (_thinking ?? _newThinking()).content += piece;
        break;
      case 'THINKING_TEXT_MESSAGE_END':
      case 'REASONING_MESSAGE_END':
      case 'THINKING_END':
      case 'REASONING_END':
        _thinking = null;
        break;
      case 'TOOL_CALL_START':
        _text = null;
        _thinking = null;
        final id = _strVal(event['toolCallId']);
        if (id.isEmpty) break;
        final had = _findTool(id) != null;
        final part = _ensureTool(
          id,
          _strVal(event['toolCallName'] ?? event['toolName'], 'tool'),
        );
        if (!had) part.state = 'input-streaming';
        break;
      case 'TOOL_CALL_ARGS':
      case 'TOOL_CALL_CHUNK':
        _text = null;
        _thinking = null;
        final id = _strVal(event['toolCallId']);
        if (id.isEmpty) break;
        final part = _ensureTool(
          id,
          _strVal(event['toolCallName'] ?? event['toolName'], 'tool'),
        );
        if (part.state == 'input-streaming' || part.state == 'awaiting-input') {
          part.state = 'input-available';
        }
        final args = _strVal(event['args']);
        if (args.isNotEmpty) {
          part.arguments = args;
        } else {
          part.arguments += _strVal(event['delta']);
        }
        if (event['input'] != null) part.input = event['input'];
        break;
      case 'TOOL_CALL_END':
        final id = _strVal(event['toolCallId']);
        if (id.isEmpty) break;
        final part = _ensureTool(
          id,
          _strVal(event['toolCallName'] ?? event['toolName'], 'tool'),
        );
        if (event['input'] != null) part.input = event['input'];
        if (event.containsKey('result')) {
          part.output = event['result'];
          part.hasOutput = true;
        }
        if (part.input == null && part.arguments.isNotEmpty) {
          part.input = _tryJson(part.arguments);
        }
        final rawState = _strVal(event['state']);
        part.state = rawState == 'output-error' || rawState == 'error'
            ? 'error'
            : 'complete';
        break;
      case 'TOOL_CALL_RESULT':
        final id = _strVal(event['toolCallId']);
        if (id.isEmpty) break;
        final part = _ensureTool(
          id,
          _strVal(event['toolCallName'] ?? event['toolName'], 'tool'),
        );
        part.output =
            event.containsKey('content') ? event['content'] : event['result'];
        part.hasOutput = true;
        part.state =
            event['error'] != null || _strVal(event['state']) == 'output-error'
                ? 'error'
                : 'complete';
        break;
      case 'CUSTOM':
        _applyCustom(event);
        break;
      case 'MESSAGES_SNAPSHOT':
        final messages = event['messages'];
        if (messages is List) {
          snapshotMessages = [
            for (final row in messages)
              if (row is Map) _asMap(row),
          ];
        }
        break;
      case 'ACTIVITY_SNAPSHOT':
        _applyActivitySnapshot(event);
        break;
      case 'ACTIVITY_DELTA':
        _applyActivityDelta(event);
        break;
      case 'SUBAGENT_STARTED':
        _applySubagentStarted(event);
        break;
      case 'SUBAGENT_FINISHED':
        _applySubagentFinished(event);
        break;
      case 'SUBAGENT_ERROR':
        _applySubagentError(event);
        break;
      case 'RUN_STARTED':
        break;
      case 'RUN_FINISHED':
        done = true;
        final outcome = _asMap(event['outcome']);
        final outcomeType = _strVal(outcome['type']);
        interrupted = outcomeType == 'interrupt';
        finishReason = _strVal(event['finishReason']).isEmpty
            ? finishReason
            : _strVal(event['finishReason']);
        model =
            _strVal(event['model']).isEmpty ? model : _strVal(event['model']);
        final metadata = _asMap(event['metadata']);
        final tanstack = _asMap(metadata['tanstack']);
        if (tanstack['finishReason'] != null) {
          finishReason = _strVal(tanstack['finishReason']);
        }
        if (tanstack['model'] != null) model = _strVal(tanstack['model']);
        final raw = _interruptsFrom(event);
        interrupts = raw;
        _applyInterrupts(raw);
        break;
      case 'RUN_ERROR':
        done = true;
        error = _strVal(event['message'], 'The assistant run failed.').trim();
        if (error!.isEmpty) error = 'The assistant run failed.';
        break;
      default:
        break;
    }
  }

  void _applyCustom(Map<String, dynamic> event) {
    final name = _strVal(event['name']);
    final value = _asMap(event['value']);
    switch (name) {
      case 'approval-requested':
      case 'tool-approval-requested':
        _applyApproval(value);
        break;
      case 'tool-input-available':
        final id = _strVal(value['toolCallId']);
        if (id.isEmpty) break;
        final part = _ensureTool(
          id,
          _strVal(value['toolName'] ?? value['toolCallName'], 'tool'),
        );
        if (value.containsKey('input')) part.input = value['input'];
        part.state = 'input-available';
        break;
      case 'structured-output.start':
        final part = AssistantPart(
          type: 'structured-output',
          structuredStatus: 'streaming',
          raw: '',
        );
        _structured = part;
        parts.add(part);
        break;
      case 'structured-output.delta':
      case 'structured-output.chunk':
        final piece = _strVal(value['delta'] ?? value['raw']);
        if (piece.isEmpty) break;
        final part = _structured ?? _newStructured();
        part.raw += piece;
        break;
      case 'structured-output.complete':
        final part = _structured ?? _newStructured();
        part.structuredStatus = 'complete';
        if (value.containsKey('object')) part.data = value['object'];
        if (value.containsKey('data')) part.data = value['data'];
        if (value['raw'] != null) part.raw = _strVal(value['raw']);
        break;
      case 'structured-output.error':
        final part = _structured ?? _newStructured();
        part.structuredStatus = 'error';
        part.content = _strVal(value['message'] ?? value['errorMessage']);
        break;
    }
  }

  AssistantPart _newStructured() {
    final part = AssistantPart(
      type: 'structured-output',
      structuredStatus: 'streaming',
      raw: '',
    );
    parts.add(part);
    _structured = part;
    return part;
  }

  List<Map<String, dynamic>> _interruptsFrom(Map<String, dynamic> event) {
    final out = <Map<String, dynamic>>[];
    void add(dynamic raw) {
      if (raw is! List) return;
      for (final item in raw) {
        if (item is Map) out.add(_asMap(item));
      }
    }

    add(_asMap(event['outcome'])['interrupts']);
    add(event['interrupts']);
    return out;
  }

  AssistantPart _applyActivitySnapshot(Map<String, dynamic> event) {
    final messageId = _strVal(event['messageId']);
    final existing = _activityByMessage[messageId];
    if (existing != null && event['replace'] != false) {
      existing.activityType =
          _strVal(event['activityType'], existing.activityType);
      existing.activityContent = event['content'];
      return existing;
    }
    final part = AssistantPart(
      type: 'activity',
      id: messageId,
      activityType: _strVal(event['activityType']),
      activityContent: event['content'],
      metadata: event['metadata'] is Map ? _asMap(event['metadata']) : null,
    );
    parts.add(part);
    if (messageId.isNotEmpty) _activityByMessage[messageId] = part;
    return part;
  }

  void _applyActivityDelta(Map<String, dynamic> event) {
    final messageId = _strVal(event['messageId']);
    var part = _activityByMessage[messageId];
    if (part == null) {
      part = AssistantPart(
        type: 'activity',
        id: messageId,
        activityType: _strVal(event['activityType']),
        activityContent: <String, dynamic>{},
      );
      parts.add(part);
      if (messageId.isNotEmpty) _activityByMessage[messageId] = part;
    }
    final patch = event['patch'];
    if (patch is List) {
      for (final op in patch) {
        _applyJsonPatch(part, _asMap(op));
      }
    }
  }

  void _applyJsonPatch(AssistantPart part, Map<String, dynamic> op) {
    final operation = _strVal(op['op']);
    final path = _strVal(op['path']);
    if (!path.startsWith('/')) return;
    final segments = path
        .substring(1)
        .split('/')
        .map((s) => s.replaceAll('~1', '/').replaceAll('~0', '~'))
        .toList();
    dynamic container = part.activityContent;
    if (container is! Map && container is! List) {
      container = <String, dynamic>{};
      part.activityContent = container;
    }
    for (var i = 0; i < segments.length; i++) {
      final key = segments[i];
      final last = i == segments.length - 1;
      dynamic next;
      if (container is List) {
        final index = int.tryParse(key);
        if (index == null || index < 0) return;
        if (last) {
          if (operation == 'add') {
            if (index >= container.length) {
              container.add(op['value']);
            } else {
              container[index] = op['value'];
            }
          } else if (operation == 'replace') {
            if (index < container.length) container[index] = op['value'];
          } else if (operation == 'remove') {
            if (index < container.length) container.removeAt(index);
          }
          return;
        }
        if (index >= container.length) return;
        next = container[index];
        if (next is! Map && next is! List) {
          next = <String, dynamic>{};
          container[index] = next;
        }
      } else if (container is Map) {
        if (last) {
          if (operation == 'remove') {
            container.remove(key);
          } else {
            container[key] = op['value'];
          }
          return;
        }
        next = container[key];
        if (next is! Map && next is! List) {
          next = <String, dynamic>{};
          container[key] = next;
        }
      } else {
        return;
      }
      container = next;
    }
  }

  void _applySubagentStarted(Map<String, dynamic> event) {
    final id = _strVal(event['subagentRunId']);
    if (id.isEmpty) return;
    final subagent = <String, dynamic>{
      'id': id,
      'name': _strVal(event['name']),
      'description': event['description'],
      'status': 'running',
      if (event['parentSubagentRunId'] != null)
        'parentSubagentRunId': event['parentSubagentRunId'],
      if (event['parentToolCallId'] != null)
        'parentToolCallId': event['parentToolCallId'],
      if (event['metadata'] is Map) 'metadata': _asMap(event['metadata']),
      'messages': <dynamic>[],
    };
    final part = AssistantPart(type: 'subagent', id: id, subagent: subagent);
    parts.add(part);
    _subagents[id] = part;
  }

  void _applySubagentFinished(Map<String, dynamic> event) {
    final id = _strVal(event['subagentRunId']);
    final part = _subagents[id];
    if (part == null) return;
    final outcome = _asMap(event['outcome']);
    final status = _strVal(outcome['type']);
    final subagent = part.subagent ?? <String, dynamic>{};
    subagent['status'] = status == 'suspended' ? 'suspended' : 'finished';
    if (outcome['interruptIds'] is List) {
      subagent['interruptIds'] = outcome['interruptIds'];
    }
    part.subagent = subagent;
  }

  void _applySubagentError(Map<String, dynamic> event) {
    final id = _strVal(event['subagentRunId']);
    final part = _subagents[id];
    if (part == null) return;
    final subagent = part.subagent ?? <String, dynamic>{};
    subagent['status'] = 'error';
    subagent['error'] = {
      'message': _strVal(event['message'], 'Subagent failed'),
      if (event['code'] != null) 'code': event['code'],
    };
    part.subagent = subagent;
  }

  AssistantPart _newText() {
    final part = AssistantPart.text('');
    parts.add(part);
    _text = part;
    return part;
  }

  AssistantPart _newThinking() {
    _thoughtSeq += 1;
    final part = AssistantPart.thinking(id: 'thought-$_thoughtSeq');
    parts.add(part);
    _thinking = part;
    return part;
  }

  AssistantPart? _findTool(String id) {
    for (final part in parts) {
      if (part.type == 'tool-call' && part.id == id) return part;
    }
    return null;
  }

  AssistantPart _ensureTool(String id, String name) {
    var part = _findTool(id);
    if (part == null) {
      part = AssistantPart.tool(id: id, name: name, state: 'input-streaming');
      parts.add(part);
    } else if (part.name.isEmpty || part.name == 'tool') {
      part.name = name;
    }
    return part;
  }

  void _applyApproval(Map<String, dynamic> value) {
    final id = _strVal(value['toolCallId']);
    if (id.isEmpty) return;
    final part = _ensureTool(
      id,
      _strVal(
        value['toolName'] ?? value['toolCallName'] ?? value['name'],
        'tool',
      ),
    );
    if (value.containsKey('input')) part.input = value['input'];
    final approval = _asMap(value['approval']);
    final approvalId = _strVal(approval['id']);
    if (approvalId.isEmpty) return;
    part.approval = AssistantApproval(
      id: approvalId,
      needsApproval: approval['needsApproval'] != false,
    );
    part.state = 'approval-requested';
  }

  void _applyInterrupts(List<Map<String, dynamic>> raw) {
    for (final interrupt in raw) {
      final metadata = _asMap(interrupt['metadata']);
      final kind = _strVal(metadata['kind']);
      final reason = _strVal(interrupt['reason']);
      if (kind != 'approval' && reason != 'approval_required') continue;
      final id = _strVal(interrupt['toolCallId']);
      if (id.isEmpty) continue;
      final part = _ensureTool(
        id,
        _strVal(metadata['toolName'] ?? interrupt['toolName'], 'tool'),
      );
      if (metadata.containsKey('input')) part.input = metadata['input'];
      final approvalId = _strVal(interrupt['id']);
      if (approvalId.isEmpty) continue;
      part.approval = AssistantApproval(id: approvalId, needsApproval: true);
      part.state = 'approval-requested';
    }
  }
}

/// An approved request may already have reached the server when cancelled.
/// Represent it as an interrupted result so a later prompt cannot replay it.
void interruptApprovedTools(AssistantTurn turn) {
  for (final part in turn.tools) {
    if (part.approval?.approved == true && part.output == null) {
      part.state = 'error';
      part.output = {
        'error':
            'Execution was interrupted. Check the record before requesting this action again.'
      };
      part.hasOutput = true;
    }
  }
}

/// Wire payload TanStack puts in a `role: tool` message for an approval.
Map<String, dynamic> assistantApprovalPayload(bool approved) => {
      'approved': approved,
      if (approved) 'pendingExecution': true,
      'message':
          approved ? 'User approved this action' : 'User denied this action',
    };

/// Legacy wire messages (`content` + `toolCalls` + `role: tool`).
List<Map<String, dynamic>> assistantModelMessages(
  Iterable<AssistantTurn> turns,
) {
  final out = <Map<String, dynamic>>[];
  for (final turn in turns) {
    if (turn.role == 'user') {
      final content = turn.answer;
      if (content.isEmpty) continue;
      out.add({'id': turn.id, 'role': 'user', 'content': content});
      continue;
    }
    if (turn.role != 'assistant') continue;

    final tools = turn.tools.toList();
    final content = turn.answer;
    if (content.isNotEmpty || tools.isNotEmpty) {
      final message = <String, dynamic>{
        'id': turn.id,
        'role': 'assistant',
        'content': content,
      };
      if (tools.isNotEmpty) {
        message['toolCalls'] = [
          for (final part in tools)
            {
              'id': part.id,
              'type': 'function',
              'function': {'name': part.name, 'arguments': part.wireArguments},
            },
        ];
      }
      out.add(message);
    }

    for (final part in tools) {
      if (part.hasOutput || part.output != null) {
        out.add({
          'role': 'tool',
          'id': '${turn.id}-${part.id}',
          'toolCallId': part.id,
          'content':
              part.output is String ? part.output : jsonEncode(part.output),
        });
      } else if (part.approval?.approved != null) {
        out.add({
          'role': 'tool',
          'id': '${turn.id}-${part.id}-approval',
          'toolCallId': part.id,
          'content': jsonEncode(
            assistantApprovalPayload(part.approval!.approved!),
          ),
        });
      }
    }
  }
  return out;
}

/// UI messages retain approval IDs and decisions required by TanStack's
/// extractClientStateFromOriginalMessages before model-message conversion.
/// Internal reasoning and empty streaming placeholders never leave the client.
List<Map<String, dynamic>> assistantWireMessages(
        Iterable<AssistantTurn> turns) =>
    [
      for (final turn in turns)
        if ((turn.role == 'user' || turn.role == 'assistant') &&
            turn.parts.any((p) =>
                (p.type == 'text' && p.content.isNotEmpty) ||
                p.type == 'tool-call' ||
                p.type == 'tool-result' ||
                p.type == 'image' ||
                p.type == 'audio' ||
                p.type == 'video' ||
                p.type == 'document'))
          {
            'id': turn.id,
            'role': turn.role,
            'parts': [
              for (final part in turn.parts)
                if (part.type == 'text' && part.content.isNotEmpty)
                  part.toJson()
                else if (part.type == 'image' ||
                    part.type == 'audio' ||
                    part.type == 'video' ||
                    part.type == 'document' ||
                    part.type == 'tool-result')
                  part.toJson()
                else if (turn.role == 'assistant' && part.type == 'tool-call')
                  {...part.toJson(), 'arguments': part.wireArguments},
            ],
          },
    ];

/// Request body for the legacy TanStack chat endpoint.
///
/// [threadId] is optional and only included when non-empty. The transport
/// itself makes no durable-thread assumptions.
Map<String, dynamic> assistantChatBody(
  String? threadId,
  Iterable<AssistantTurn> turns,
) {
  final body = <String, dynamic>{
    'runId': generateIdentity('run'),
    'state': <String, dynamic>{},
    'messages': assistantWireMessages(turns),
    'tools': <dynamic>[],
    'context': <dynamic>[],
  };
  if (threadId != null && threadId.isNotEmpty) {
    body['durableThreadId'] = threadId;
    body['threadId'] = threadId;
    body['forwardedProps'] = {
      'durableThreadId': threadId,
      'threadId': threadId,
    };
    body['data'] = {'durableThreadId': threadId, 'threadId': threadId};
  }
  return body;
}

/// Restores turns from a persisted thread row (`{messages: [...]}`).
List<AssistantTurn> assistantTurnsFromThread(dynamic raw) {
  final rows = _asMap(raw)['messages'];
  if (rows is! List) return [];
  final turns = <AssistantTurn>[];
  var index = 0;
  for (final rawRow in rows) {
    index += 1;
    final row = _asMap(rawRow);
    final role = _strVal(row['role']);
    if (role != 'user' && role != 'assistant' && role != 'activity') {
      continue;
    }

    final parts = <AssistantPart>[];
    final rawParts = row['parts'];
    if (rawParts is List) {
      for (final rawPart in rawParts) {
        parts.add(AssistantPart.fromJson(rawPart));
      }
    } else {
      final content = _strVal(row['content']);
      if (content.isNotEmpty) parts.add(AssistantPart.text(content));
    }
    if (role == 'user') parts.removeWhere((p) => p.type != 'text');
    if (parts.isEmpty && role != 'activity') continue;

    final createdAtRaw = row['createdAt'];
    final turn = AssistantTurn(
      id: _strVal(row['id'], 'msg-$index'),
      role: role,
      parts: parts,
      name: row['name'] == null ? null : _strVal(row['name']),
      metadata: row['metadata'] is Map ? _asMap(row['metadata']) : null,
      createdAt:
          createdAtRaw is String ? DateTime.tryParse(createdAtRaw) : null,
    );
    if (role == 'assistant' &&
        turns.isNotEmpty &&
        turns.last.role == 'assistant') {
      turns.last.mergeParts(parts);
    } else {
      turns.add(turn);
    }
  }
  return turns;
}

/// Builds a short title from the first user message.
String generateAssistantThreadTitle(String raw, {int maxLen = 48}) {
  var text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return 'New chat';
  text = text.replaceFirst(
    RegExp(
      r'^(please|pls|hey|hi|hello|can you|could you|would you|i want to|i need to|help me)\s+',
      caseSensitive: false,
    ),
    '',
  );
  final cut = RegExp(r'[.!?\n]').firstMatch(text)?.start ?? -1;
  if (cut > 12 && cut < maxLen + 10) text = text.substring(0, cut);
  if (text.length > maxLen) {
    final sliced = text.substring(0, maxLen - 1);
    final lastSpace = sliced.lastIndexOf(' ');
    text =
        '${(lastSpace > 20 ? sliced.substring(0, lastSpace) : sliced).trimRight()}…';
  }
  if (text.isEmpty) return 'New chat';
  text = text[0].toUpperCase() + text.substring(1);
  return text.replaceAll(RegExp(r'[,;:\-–—]+$'), '').trim();
}

Map<String, dynamic> _asMap(dynamic v) =>
    v is Map ? v.map((k, val) => MapEntry('$k', val)) : <String, dynamic>{};

String _strVal(dynamic v, [String fallback = '']) =>
    v == null ? fallback : '$v';

dynamic _tryJson(String raw) {
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}
