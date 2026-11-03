import 'dart:convert';

import 'message_converters.dart';

typedef _Json = Map<String, dynamic>;

/// Serialize UI/model messages to the AG-UI wire format used by AI 0.70.0.
List<Map<String, dynamic>> uiMessagesToWire(
  List<Map<String, dynamic>> messages, {
  bool includeSnapshotStructuredOutput = false,
  bool includeActivity = false,
}) {
  final output = <_Json>[];
  final used = <String>{
    for (final message in messages)
      if (message['id'] is String && message['role'] != 'tool')
        message['id'] as String,
  };
  final assistantIds = {
    for (final message in messages)
      if (message['role'] == 'assistant') message['id'],
  };
  String unique(String id) {
    var candidate = id;
    var suffix = 2;
    while (used.contains(candidate)) {
      candidate = '$id-${suffix++}';
    }
    used.add(candidate);
    return candidate;
  }

  for (final message in messages) {
    final role = message['role'];
    if (role == 'activity') {
      if (includeActivity) {
        final parts = _parts(message);
        for (final part in parts.where((part) => part['type'] == 'activity')) {
          output.add({
            'id': message['id'],
            'role': 'activity',
            'activityType': part['activityType'],
            'content': _clone(part['content']),
            if (message['metadata'] != null) 'metadata': message['metadata'],
            if (part.containsKey('subagentRunId'))
              'subagentRunId': part['subagentRunId'],
          });
          break;
        }
      }
      continue;
    }
    if (!message.containsKey('parts') &&
        role == 'tool' &&
        message['toolCallId'] != null) {
      final toolId = message['toolCallId'];
      final original = message['id'];
      output.add({
        'role': 'tool',
        'id': unique(original == null || assistantIds.contains(original)
            ? 'tool-$toolId'
            : '$original'),
        if (message.containsKey('name')) 'name': message['name'],
        'toolCallId': toolId,
        'content': _stringify(message['content']),
        if (message.containsKey('error')) 'error': message['error'],
        'metadata': _toolMetadata(message, message['content']),
      });
      continue;
    }
    final ui = message.containsKey('parts')
        ? message
        : modelMessageToUIMessage(message, message['id'] as String?);
    final parts = _parts(ui);
    used.add('${ui['id']}');
    if (role == 'system' || role == 'user') {
      dynamic content = parts.isEmpty ? message['content'] ?? '' : _text(parts);
      if (role == 'user' &&
          parts.any((part) => _media.contains(part['type']))) {
        content = [
          for (final part in parts)
            if (part['type'] == 'text')
              {'type': 'text', 'text': part['content']}
            else if (_media.contains(part['type']))
              part,
        ];
      }
      output.add(_anchor(ui, parts, role as String, {'content': content},
          includeSnapshotStructuredOutput));
      continue;
    }

    var segment = _Segment(false);
    final segments = [segment];
    for (final part in parts) {
      final type = part['type'];
      if (segment.closed &&
          const {'thinking', 'text', 'tool-call'}.contains(type)) {
        segment = _Segment(false);
        segments.add(segment);
      }
      final afterCall =
          segment.parts.any((part) => part['type'] == 'tool-call');
      if (type == 'thinking') {
        if (segment.parts.any((part) =>
            part['type'] == 'tool-call' && isProviderExecutedToolCall(part))) {
          segment = _Segment(false);
          segments.add(segment);
        } else if (afterCall ||
            segment.parts.any((part) => part['type'] == 'text')) {
          segment = _Segment(true);
          segments.add(segment);
        }
        segment.thinking.add(part);
      } else if (type == 'text' && afterCall) {
        segment = _Segment(true);
        segments.add(segment);
        segment.parts.add(part);
      } else {
        segment.parts.add(part);
        if (type == 'tool-result') segment.closed = true;
      }
    }
    final explicit = {
      for (final part in parts)
        if (part['type'] == 'tool-result') part['toolCallId'],
    };
    void pushTools(List<_Json> row) {
      for (final part in row) {
        if (part['type'] == 'tool-result') {
          output.add({
            'role': 'tool',
            'id': unique('${part['id'] ?? 'tool-${part['toolCallId']}'}'),
            'toolCallId': part['toolCallId'],
            if (part.containsKey('name')) 'name': part['name'],
            'content': _stringify(part['content']),
            if (part.containsKey('error')) 'error': part['error'],
            'metadata': _toolMetadata(part, part['content'],
                ownsResources: true, outcome: part['outcome']),
          });
        } else if (part['type'] == 'tool-call') {
          final approval = _map(part['approval']);
          final approved = approval['approved'];
          if (explicit.contains(part['id']) ||
              (!part.containsKey('output') &&
                  (part['state'] != 'approval-responded' ||
                      approved == null))) {
            continue;
          }
          final result = part.containsKey('output')
              ? normalizeToolResult(part['output'])
              : jsonEncode({
                  'approved': approved,
                  if (approved == true) 'pendingExecution': true,
                  'message': approved == true
                      ? 'User approved this action'
                      : 'User denied this action',
                });
          output.add({
            'role': 'tool',
            'id': unique('tool-${part['id']}'),
            'toolCallId': part['id'],
            'content': _stringify(result),
            'metadata': _toolMetadata({}, result,
                outcome: approved == false ? 'denied' : null),
          });
        }
      }
    }

    var previousAnchor = '${ui['id']}';
    var pendingTools = <_Json>[];
    for (final (index, current) in segments.indexed) {
      for (final thought in current.thinking) {
        var id =
            '${ui['id']}-reasoning-${thought['id'] ?? _hash('${thought['content']}')}';
        if (thought['redacted'] == true) id = 'redacted_thinking-$id';
        output.add({
          'role': 'reasoning',
          'id': unique(id),
          'content': thought['content'],
          if (thought['signature'] is String &&
              (thought['signature'] as String).isNotEmpty)
            'encryptedValue': thought['signature'],
        });
      }
      final text = _text(current.parts);
      final calls = [
        for (final part in current.parts)
          if (part['type'] == 'tool-call')
            {
              'id': part['id'],
              'type': 'function',
              'function': {
                'name': part['name'],
                'arguments': part['arguments']
              },
              if (_map(part['metadata'])['thoughtSignature'] is String &&
                  (_map(part['metadata'])['thoughtSignature'] as String)
                      .isNotEmpty)
                'encryptedValue': _map(part['metadata'])['thoughtSignature'],
            },
      ];
      final row = index == 0
          ? ui
          : {
              ...ui,
              'id': unique('${ui['id']}-segment-$index'),
            };
      final anchor = _anchor(
          row,
          current.parts,
          'assistant',
          {
            if (text.isNotEmpty) 'content': text,
            if (calls.isNotEmpty) 'toolCalls': calls,
          },
          includeSnapshotStructuredOutput);
      if (current.continues) {
        final metadata = _map(anchor['metadata']);
        anchor['metadata'] = {
          ...metadata,
          'tanstack': {
            ..._map(metadata['tanstack']),
            'continues': previousAnchor
          },
        };
      }
      output.add(anchor);
      previousAnchor = '${anchor['id']}';
      pendingTools.addAll(current.parts);
      if (current.closed || index == segments.length - 1) {
        pushTools(pendingTools);
        pendingTools = [];
      }
    }
    for (final part in parts.where((part) => part['type'] == 'subagent')) {
      final child = _map(part['subagent']);
      final info = {
        for (final key in const [
          'name',
          'status',
          'description',
          'error',
          'interruptIds',
          'parentSubagentRunId',
          'parentToolCallId',
          'metadata'
        ])
          if (child.containsKey(key)) key: child[key],
      };
      final nested = uiMessagesToWire(_maps(child['messages']),
          includeActivity: includeActivity,
          includeSnapshotStructuredOutput: includeSnapshotStructuredOutput);
      final owns = nested.any((message) => _childId(message) == null);
      final rows = owns
          ? nested
          : <_Json>[
              {'id': 'subagent:${child['id']}', 'role': 'assistant'},
              ...nested,
            ];
      for (final (index, message) in rows.indexed) {
        final nestedId = _childId(message);
        if (nestedId != null) {
          final nestedInfo = _map(tanstackMetadata(message)?['subagent']);
          output.add(nestedInfo.isEmpty ||
                  nestedInfo.containsKey('parentSubagentRunId')
              ? message
              : _tagChild(message, nestedId, {
                  ...nestedInfo,
                  'parentSubagentRunId': child['id'],
                }));
        } else {
          output.add(_tagChild(message, '${child['id']}', {
            ...info,
            if (!owns && index == 0) 'placeholder': true,
          }));
        }
      }
    }
  }
  return output;
}

class _Segment {
  final bool continues;
  final thinking = <_Json>[];
  final parts = <_Json>[];
  bool closed = false;
  _Segment(this.continues);
}

const _media = {'image', 'audio', 'video', 'document'};
_Json _map(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
List<_Json> _maps(dynamic value) =>
    value is List ? value.whereType<Map>().map(_map).toList() : <_Json>[];
List<_Json> _parts(_Json value) => _maps(value['parts']);
String _stringify(dynamic value) => value is String ? value : jsonEncode(value);
dynamic _clone(dynamic value) => value is List
    ? value.map(_clone).toList()
    : value is Map
        ? value.map((key, value) => MapEntry(key, _clone(value)))
        : value;

String _text(List<_Json> parts) => [
      for (final part in parts)
        if (part['type'] == 'text')
          part['content'] ?? ''
        else if (part['type'] == 'structured-output' &&
            part['status'] == 'complete' &&
            part['raw'] != '')
          part['raw'] ?? '',
    ].join();

_Json _toolMetadata(_Json part, dynamic content,
    {bool ownsResources = false, dynamic outcome}) {
  final base = _map(part['metadata']);
  final tanstack = _map(base['tanstack']);
  if (ownsResources) tanstack.remove('uiResources');
  final date = coerceCreatedAt(part['createdAt']);
  return {
    ...base,
    'tanstack': {
      ...tanstack,
      if (outcome != null) 'toolResultOutcome': outcome,
      'toolResult': {
        if (part.containsKey('id')) 'id': part['id'],
        if (date != null) 'createdAt': date.toUtc().toIso8601String(),
        if (content is List) 'content': content,
      },
    }
  };
}

_Json _anchor(_Json message, List<_Json> parts, String role, _Json extras,
    bool snapshotStructured) {
  final base = _map(message['metadata']);
  final tanstack = _map(base['tanstack']);
  if (tanstack['run'] is Map) {
    tanstack['run'] = _map(tanstack['run'])
      ..remove('startedAt')
      ..remove('finishedAt');
  }
  for (final key in const [
    'createdAt',
    'continues',
    'structuredOutput',
    'toolCallMetadata',
    'toolResult',
    'toolResultOutcome',
    'uiResources'
  ]) {
    tanstack.remove(key);
  }
  final date = coerceCreatedAt(message['createdAt']);
  if (date != null) tanstack['createdAt'] = date.toUtc().toIso8601String();
  for (final part in parts) {
    if (part['type'] == 'structured-output' &&
        (snapshotStructured || part['status'] != 'complete')) {
      tanstack['structuredOutput'] = {
        'status': part['status'],
        'raw': part['raw'],
        if (snapshotStructured && part.containsKey('partial'))
          'partial': part['partial'],
        if (snapshotStructured && part.containsKey('data'))
          'data': part['data'],
        if (snapshotStructured &&
            part['reasoning'] != null &&
            part['reasoning'] != '')
          'reasoning': part['reasoning'],
        if (part.containsKey('errorMessage'))
          'errorMessage': part['errorMessage'],
      };
      break;
    }
  }
  final callMetadata = {
    for (final part in parts)
      if (part['type'] == 'tool-call' && part.containsKey('metadata'))
        '${part['id']}': part['metadata'],
  };
  if (callMetadata.isNotEmpty) tanstack['toolCallMetadata'] = callMetadata;
  final resources =
      parts.where((part) => part['type'] == 'ui-resource').toList();
  if (resources.isNotEmpty) tanstack['uiResources'] = resources;
  if (tanstack.isEmpty) {
    base.remove('tanstack');
  } else {
    base['tanstack'] = tanstack;
  }
  return {
    'id': message['id'],
    if (message.containsKey('name')) 'name': message['name'],
    if (base.isNotEmpty) 'metadata': base,
    'role': role,
    ...extras,
  };
}

String _hash(String text) {
  var hash = 0;
  for (final unit in text.codeUnits) {
    hash = ((hash * 31 + unit) & 0xffffffff).toSigned(32);
  }
  return hash.abs().toRadixString(36);
}

String? _childId(_Json message) => message['subagentRunId'] is String &&
        (message['subagentRunId'] as String).isNotEmpty &&
        !message.containsKey('parts')
    ? message['subagentRunId'] as String
    : null;
_Json _tagChild(_Json message, String id, _Json info) {
  final metadata = _map(message['metadata']);
  return {
    ...message,
    'subagentRunId': id,
    'metadata': {
      ...metadata,
      'tanstack': {..._map(metadata['tanstack']), 'subagent': info},
    }
  };
}
