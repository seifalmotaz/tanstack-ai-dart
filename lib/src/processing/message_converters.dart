import 'dart:convert';

import '../identity.dart';

/// Pure-Dart port of the public TanStack AI message converters.
///
/// UI messages and model messages use `Map<String, dynamic>` shapes so they
/// can round-trip through JSON without a parallel class hierarchy.

const List<String> _contentPartTypes = <String>[
  'text',
  'image',
  'audio',
  'video',
  'document',
];

bool _isRecord(dynamic value) => value is Map && value is! List;

Map<String, dynamic> _asRecord(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

String? _nonEmptyString(dynamic value) =>
    value is String && value.isNotEmpty ? value : null;

String _string(dynamic value, [String fallback = '']) =>
    value is String ? value : fallback;

/// Generate a unique client-side message id.
String generateMessageId() => generateIdentity('msg');

/// JSON.stringify that returns `''` instead of throwing.
dynamic _clone(dynamic value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  try {
    return jsonDecode(jsonEncode(value));
  } catch (_) {
    return value;
  }
}

String safeJsonStringify(dynamic value) {
  try {
    final encoded = jsonEncode(value);
    return encoded == 'null' ? '' : encoded;
  } catch (_) {
    return '';
  }
}

/// Rebuild a [DateTime] from a live date or an ISO string.
DateTime? coerceCreatedAt(dynamic value) {
  if (value is DateTime) return value;
  if (value is! String) return null;
  return DateTime.tryParse(value);
}

/// Read `metadata.tanstack` from a message, part, or raw metadata map.
Map<String, dynamic>? tanstackMetadata(dynamic value) {
  if (value == null) return null;
  Map<String, dynamic> metadata;
  if (value is Map) {
    if (value.containsKey('metadata')) {
      final nested = value['metadata'];
      if (_isRecord(nested)) {
        metadata = _asRecord(nested);
      } else {
        metadata = _asRecord(value);
      }
    } else {
      metadata = _asRecord(value);
    }
  } else {
    return null;
  }
  final tanstack = metadata['tanstack'];
  return _isRecord(tanstack) ? _asRecord(tanstack) : null;
}

/// Merge two metadata maps. `tanstack` is merged one level deep.
Map<String, dynamic>? mergeMetadata(
  Map<String, dynamic>? current,
  dynamic incoming,
) {
  if (incoming == null) return current;
  if (!_isRecord(incoming)) return current;
  final next = _asRecord(incoming);
  if (current == null) return next;
  final merged = <String, dynamic>{...current, ...next};
  final currentTanstack = current['tanstack'];
  final incomingTanstack = next['tanstack'];
  if (_isRecord(currentTanstack) && _isRecord(incomingTanstack)) {
    merged['tanstack'] = <String, dynamic>{
      ..._asRecord(currentTanstack),
      ..._asRecord(incomingTanstack),
    };
  }
  return merged;
}

/// Copy `value` and merge [tanstack] into its `metadata.tanstack` bag.
Map<String, dynamic> withTanstackMetadata(
  Map<String, dynamic> value,
  Map<String, dynamic> tanstack,
) {
  final current = value['metadata'];
  final currentTanstack = tanstackMetadata(value) ?? <String, dynamic>{};
  return <String, dynamic>{
    ...value,
    'metadata': <String, dynamic>{
      if (_isRecord(current)) ..._asRecord(current),
      'tanstack': <String, dynamic>{...currentTanstack, ...tanstack},
    },
  };
}

/// True when the value is a non-empty list of valid content parts.
bool isContentPartArray(dynamic value) =>
    value is List && value.isNotEmpty && value.every(isContentPart);

/// Structural check for a single content part.
bool isContentPart(dynamic value) {
  if (!_isRecord(value)) return false;
  final part = _asRecord(value);
  final type = part['type'];
  if (type is! String || !_contentPartTypes.contains(type)) return false;
  if (type == 'text') return part['content'] is String;
  final source = part['source'];
  if (!_isRecord(source)) return false;
  final src = _asRecord(source);
  if (src['value'] is! String) return false;
  if (src['type'] == 'file') {
    return (src['value'] as String).isNotEmpty &&
        (src['provider'] == null || src['provider'] is String);
  }
  if (src['type'] == 'data') return src['mimeType'] is String;
  return src['type'] == 'url';
}

/// True when the value is a valid tool result outcome.
bool isToolResultOutcome(dynamic value) =>
    value == 'cancelled' || value == 'denied';

/// Error text for a failed tool result.
String toolResultErrorText(dynamic output) {
  if (_isRecord(output) && output['error'] is String) {
    return output['error'] as String;
  }
  return output is String ? output : 'Tool execution failed';
}

/// Normalize a tool's return value for transport.
dynamic normalizeToolResult(dynamic result) {
  if (result is String) return result;
  if (isContentPartArray(result)) return result;
  return jsonEncode(result);
}

/// True for a provider-executed tool call.
bool isProviderExecutedToolCall(dynamic part) =>
    _isRecord(part) &&
    _isRecord(part['metadata']) &&
    (part['metadata'] as Map)['providerExecuted'] == true;

/// True when [id] is a `${parentId}-segment-${n}` assistant message.
bool isAssistantSegmentOf(String? id, String parentId) =>
    id != null && id.startsWith('$parentId-segment-');

/// Prefix of a redacted thinking block id.
const redactedThinkingIdPrefix = 'redacted_thinking-';

/// True when an id names a redacted thinking block.
bool isRedactedThinkingId(dynamic id) =>
    id is String && id.startsWith(redactedThinkingIdPrefix);

bool _isUiResourcePart(dynamic value) {
  if (!_isRecord(value)) return false;
  final part = _asRecord(value);
  if (part['type'] != 'ui-resource') return false;
  if (part['toolCallId'] is! String || part['toolName'] is! String) {
    return false;
  }
  final resource = part['resource'];
  if (!_isRecord(resource)) return false;
  return resource['uri'] is String && resource['mimeType'] is String;
}

String _uiResourceKey(Map<String, dynamic> part) {
  final resource = _asRecord(part['resource']);
  return '${part['toolCallId']}\u0000${part['toolName']}\u0000${resource['uri']}';
}

Map<String, dynamic> _appendUiResources(
  Map<String, dynamic> ui,
  List<Map<String, dynamic>> resources,
) {
  if (resources.isEmpty) return ui;
  final parts = (ui['parts'] as List).cast<Map<String, dynamic>>();
  final seen = <String>{
    for (final part in parts)
      if (_isUiResourcePart(part)) _uiResourceKey(part),
  };
  final extra = <Map<String, dynamic>>[];
  for (final part in resources) {
    if (seen.add(_uiResourceKey(part))) extra.add(part);
  }
  if (extra.isEmpty) return ui;
  return <String, dynamic>{
    ...ui,
    'parts': <Map<String, dynamic>>[...parts, ...extra],
  };
}

dynamic _encryptedValueFrom(dynamic value) {
  if (_isRecord(value) && value.containsKey('encryptedValue')) {
    final fromSpec = _nonEmptyString(value['encryptedValue']);
    if (fromSpec != null) return fromSpec;
  }
  return _nonEmptyString(tanstackMetadata(value)?['signature']);
}

Map<String, dynamic> _redactedFrom(dynamic value) =>
    _isRecord(value) && isRedactedThinkingId(value['id'])
        ? <String, dynamic>{'redacted': true}
        : <String, dynamic>{};

bool _isTextContentPart(dynamic part) =>
    _isRecord(part) && _contentPartTypes.contains(part['type']);

String _getTextContent(dynamic content) {
  if (content == null) return '';
  if (content is String) return content;
  if (content is List) {
    return content
        .where((part) => _isRecord(part) && part['type'] == 'text')
        .map((part) => _string(part['content']))
        .join();
  }
  return '';
}

dynamic _collapseContentParts(List<Map<String, dynamic>> parts) {
  if (parts.isEmpty) return null;
  final allText = parts.every((part) => part['type'] == 'text');
  if (allText) {
    final joined = parts.map((part) => _string(part['content'])).join();
    return joined.isEmpty ? null : joined;
  }
  return parts;
}

dynamic _toolResultContent(dynamic content) {
  if (content is List) return content;
  return _getTextContent(content);
}

Map<String, dynamic> _optionalCreatedAt(Map<String, dynamic> source) {
  final createdAt = coerceCreatedAt(source['createdAt']);
  return createdAt != null
      ? <String, dynamic>{'createdAt': createdAt}
      : <String, dynamic>{};
}

String _historyTextFromParts(List<dynamic> parts) {
  final blocks = <String>[];
  for (final raw in parts) {
    if (!_isRecord(raw)) continue;
    final part = _asRecord(raw);
    if (part['type'] == 'text' && part['content'] != '') {
      blocks.add(_string(part['content']));
    } else if (part['type'] == 'structured-output' &&
        part['status'] == 'complete' &&
        part['raw'] != '') {
      blocks.add(_string(part['raw']));
    } else if (part['type'] == 'subagent') {
      final nested = subagentHistoryText(part);
      if (nested.isNotEmpty) blocks.add(nested);
    }
  }
  return blocks.join('\n\n');
}

/// Child text folded into the parent history for a later turn.
String subagentHistoryText(Map<String, dynamic> part) {
  final subagent = _asRecord(part['subagent']);
  final messages = subagent['messages'];
  final blocks = <String>[];
  if (messages is List) {
    for (final raw in messages) {
      if (!_isRecord(raw) || !raw.containsKey('parts')) continue;
      final text = _historyTextFromParts(raw['parts'] as List).trim();
      if (text.isNotEmpty) blocks.add(text);
    }
  }
  if (blocks.isEmpty) return '';
  return '${_string(subagent['name'])}:\n${blocks.join('\n\n')}';
}

/// Wire subagent message id, when present and not a parts-based UI message.
String? wireSubagentRunId(dynamic message) {
  if (!_isRecord(message) || message.containsKey('parts')) return null;
  final id = message['subagentRunId'];
  return _nonEmptyString(id);
}

Map<String, dynamic>? wireSubagentInfo(dynamic message) {
  if (!_isRecord(message)) return null;
  final metadata = message['metadata'];
  if (!_isRecord(metadata)) return null;
  final tanstack = metadata['tanstack'];
  if (!_isRecord(tanstack)) return null;
  final subagent = tanstack['subagent'];
  if (!_isRecord(subagent)) return null;
  final name = subagent['name'];
  final status = subagent['status'];
  if (name is! String) return null;
  if (!<String>['running', 'finished', 'error', 'suspended'].contains(status)) {
    return null;
  }
  return <String, dynamic>{
    'name': name,
    'status': status,
    if (subagent['description'] is String)
      'description': subagent['description'],
    if (_isRecord(subagent['error']) && subagent['error']['message'] is String)
      'error': <String, dynamic>{
        'message': subagent['error']['message'],
        if (subagent['error']['code'] is String)
          'code': subagent['error']['code'],
      },
    if (subagent['interruptIds'] is List)
      'interruptIds':
          (subagent['interruptIds'] as List).whereType<String>().toList(),
    if (subagent['parentSubagentRunId'] is String)
      'parentSubagentRunId': subagent['parentSubagentRunId'],
    if (subagent['parentToolCallId'] is String)
      'parentToolCallId': subagent['parentToolCallId'],
    if (_isRecord(subagent['metadata'])) 'metadata': subagent['metadata'],
    if (subagent['placeholder'] == true) 'placeholder': true,
  };
}

Map<String, dynamic> _untagWireMessage(Map<String, dynamic> message) {
  final rest = <String, dynamic>{...message}..remove('subagentRunId');
  final metadata = rest['metadata'];
  if (!_isRecord(metadata)) return rest;
  final tanstack = metadata['tanstack'];
  if (!_isRecord(tanstack) || !tanstack.containsKey('subagent')) return rest;
  final tanstackRest = <String, dynamic>{..._asRecord(tanstack)}
    ..remove('subagent');
  rest['metadata'] = <String, dynamic>{
    ..._asRecord(metadata),
    'tanstack': tanstackRest
  };
  return rest;
}

/// A direct child group from a subagent wire transcript.
class SubagentWireGroup {
  final String id;
  Map<String, dynamic> info;
  final List<dynamic> messages;
  final int hostIndex;

  SubagentWireGroup({
    required this.id,
    required this.info,
    required this.messages,
    required this.hostIndex,
  });
}

/// Split wire messages into the parent's own messages and child groups.
({List<dynamic> top, List<SubagentWireGroup> groups}) splitSubagentWire(
  List<dynamic> messages,
) {
  final parentOf = <String, String?>{};
  for (final message in messages) {
    final id = wireSubagentRunId(message);
    if (id != null && !parentOf.containsKey(id)) {
      parentOf[id] =
          wireSubagentInfo(message)?['parentSubagentRunId'] as String?;
    }
  }
  String rootOf(String id) {
    var current = id;
    for (var depth = 0; depth < 64; depth++) {
      final parent = parentOf[current];
      if (parent == null || !parentOf.containsKey(parent)) return current;
      current = parent;
    }
    return current;
  }

  final top = <dynamic>[];
  final groups = <String, SubagentWireGroup>{};
  for (final message in messages) {
    final id = wireSubagentRunId(message);
    if (id == null) {
      top.add(message);
      continue;
    }
    final root = rootOf(id);
    var group = groups[root];
    if (group == null) {
      group = SubagentWireGroup(
        id: root,
        info: <String, dynamic>{'name': 'subagent', 'status': 'finished'},
        messages: <dynamic>[],
        hostIndex: top.length - 1,
      );
      groups[root] = group;
    }
    if (id != root) {
      group.messages.add(message);
      continue;
    }
    final info = wireSubagentInfo(message);
    if (info != null) group.info = info;
    if (info?['placeholder'] != true) {
      group.messages.add(_untagWireMessage(_asRecord(message)));
    }
  }
  return (top: top, groups: groups.values.toList());
}

Map<String, dynamic> _toolCallFromWire(
  Map<String, dynamic> toolCall,
  dynamic bag,
) {
  final fromBag = _isRecord(bag) ? _asRecord(bag) : null;
  final encrypted = _encryptedValueFrom(toolCall);
  if (bag == null && encrypted == null) {
    return <String, dynamic>{...toolCall, 'metadata': null};
  }
  if (fromBag == null && encrypted == null) return toolCall;
  return <String, dynamic>{
    ...toolCall,
    'metadata': <String, dynamic>{
      ...?fromBag,
      if (encrypted != null) 'thoughtSignature': encrypted,
    },
  };
}

/// Convert UI or model messages to model messages.
List<Map<String, dynamic>> convertMessagesToModelMessages(
  List<dynamic> messages,
) {
  final split = splitSubagentWire(messages);
  if (split.groups.isEmpty) return _convertOwnMessages(messages);

  final blocks = <String?, List<String>>{};
  for (final group in split.groups) {
    if (group.info['parentToolCallId'] != null) continue;
    final text = _subagentWireText(group.messages);
    if (text.isEmpty) continue;
    String? hostId;
    for (var i = group.hostIndex; i >= 0 && i < split.top.length; i--) {
      final message = split.top[i];
      if (_isRecord(message) &&
          message['role'] == 'assistant' &&
          tanstackMetadata(message)?['continues'] == null) {
        hostId = message['id'] is String ? message['id'] as String : null;
        break;
      }
    }
    blocks.putIfAbsent(hostId, () => <String>[]).add(
          '${group.info['name']}:\n$text',
        );
  }

  final converted = _convertOwnMessages(split.top);
  blocks.forEach((hostId, texts) {
    final block = texts.join('\n\n');
    final index = hostId == null
        ? -1
        : converted.indexWhere(
            (message) =>
                message['role'] == 'assistant' && message['id'] == hostId,
          );
    if (index < 0) {
      converted.add(<String, dynamic>{'role': 'assistant', 'content': block});
      return;
    }
    final host = converted[index];
    final content = host['content'];
    converted[index] = <String, dynamic>{
      ...host,
      'content': content is String && content.isNotEmpty
          ? '$content\n\n$block'
          : content is List
              ? <dynamic>[
                  ...content,
                  <String, dynamic>{'type': 'text', 'content': block},
                ]
              : block,
    };
  });
  return converted;
}

String _subagentWireText(List<dynamic> messages) {
  final blocks = <String>[];
  for (final message in messages) {
    if (!_isRecord(message) || message['role'] != 'assistant') continue;
    if (wireSubagentRunId(message) != null) continue;
    final content = message['content'];
    if (content is String && content.trim().isNotEmpty) {
      blocks.add(content.trim());
    }
  }
  for (final group in splitSubagentWire(messages).groups) {
    final text = _subagentWireText(group.messages);
    if (text.isNotEmpty) blocks.add('${group.info['name']}:\n$text');
  }
  return blocks.join('\n\n');
}

List<Map<String, dynamic>> _convertOwnMessages(List<dynamic> messages) {
  final anchoredToolCallIds = <String>{};
  for (final message in messages) {
    if (!_isRecord(message) || !message.containsKey('parts')) continue;
    for (final part in message['parts'] as List) {
      if (_isRecord(part) && part['type'] == 'tool-result') {
        anchoredToolCallIds.add(_string(part['toolCallId']));
      }
    }
  }

  final modelMessages = <Map<String, dynamic>>[];
  var pendingThinking = <Map<String, dynamic>>[];
  Map<String, dynamic>? lastAssistantRow;
  String? lastAssistantRowId;

  for (final raw in messages) {
    if (!_isRecord(raw)) continue;
    final message = _asRecord(raw);
    if (message.containsKey('parts')) {
      modelMessages.addAll(uiMessageToModelMessages(message));
      continue;
    }

    final modelMessage = _restoreModelMessageCreatedAt(
      restoreToolResultOwnership(message),
    );
    final role = modelMessage['role'];

    if (role == 'tool' &&
        modelMessage['toolCallId'] != null &&
        anchoredToolCallIds.contains(modelMessage['toolCallId'])) {
      continue;
    }

    if (role == 'reasoning') {
      final content = _string(message['content']);
      final signature = _encryptedValueFrom(message);
      if (content.isNotEmpty || signature != null) {
        pendingThinking.add(<String, dynamic>{
          'content': content,
          if (signature != null) 'signature': signature,
          ..._redactedFrom(message),
        });
      }
      continue;
    }

    if (role == 'activity') continue;

    if (role == 'developer') {
      modelMessages.add(<String, dynamic>{
        'role': 'system',
        'content': _string(message['content']),
        if (modelMessage['name'] != null) 'name': modelMessage['name'],
        ..._optionalCreatedAt(modelMessage),
        if (modelMessage['metadata'] != null)
          'metadata': modelMessage['metadata'],
      });
      continue;
    }

    if (role == 'user' && message['content'] is List) {
      final content = (message['content'] as List).cast<dynamic>();
      final aguiShape = content.any(
        (part) =>
            _isRecord(part) &&
            part['type'] == 'text' &&
            part.containsKey('text') &&
            !part.containsKey('content'),
      );
      if (!aguiShape) {
        modelMessages.add(modelMessage);
        continue;
      }
      final convertedParts = aguiContentToContentParts(content);
      final parts = convertedParts is List ? convertedParts : <dynamic>[];
      modelMessages.add(<String, dynamic>{
        'role': 'user',
        'content': _collapseContentParts(
          parts
              .where(_isTextContentPart)
              .map((part) => _asRecord(part))
              .toList(),
        ),
        if (message['id'] != null) 'id': message['id'],
        if (modelMessage['name'] != null) 'name': modelMessage['name'],
        ..._optionalCreatedAt(modelMessage),
        if (modelMessage['metadata'] != null)
          'metadata': modelMessage['metadata'],
      });
      continue;
    }

    if (role == 'assistant') {
      final source = modelMessage;
      final toolCallMetadata = tanstackMetadata(message)?['toolCallMetadata'];
      final wireCalls = source['toolCalls'];
      final toolCalls = wireCalls is List
          ? wireCalls.map((call) {
              final map = _asRecord(call);
              return _toolCallFromWire(
                map,
                _isRecord(toolCallMetadata)
                    ? toolCallMetadata[map['id']]
                    : null,
              );
            }).toList()
          : null;
      final row = <String, dynamic>{
        ...source,
        if (toolCalls != null) 'toolCalls': toolCalls,
        if (pendingThinking.isNotEmpty)
          'thinking': <dynamic>[
            ...(source['thinking'] is List ? source['thinking'] as List : []),
            ...pendingThinking,
          ],
      };
      pendingThinking = <Map<String, dynamic>>[];
      final continues = tanstackMetadata(message)?['continues'];
      if (lastAssistantRow != null &&
          identical(modelMessages.lastOrNull, lastAssistantRow) &&
          continues != null &&
          continues == lastAssistantRowId) {
        final joined = _joinAssistantRows(lastAssistantRow, row);
        modelMessages[modelMessages.length - 1] = joined;
        lastAssistantRow = joined;
        lastAssistantRowId =
            source['id'] is String ? source['id'] as String : null;
      } else {
        modelMessages.add(row);
        lastAssistantRow = row;
        lastAssistantRowId =
            source['id'] is String ? source['id'] as String : null;
      }
      continue;
    }

    modelMessages.add(modelMessage);
  }
  return modelMessages;
}

List<Map<String, dynamic>> _blockOrderEntries(Map<String, dynamic> message) {
  final blocks = _orderedAssistantBlocks(message);
  if (blocks != null) {
    return blocks.map((block) {
      if (block['type'] == 'thinking') {
        return <String, dynamic>{'type': 'thinking'};
      }
      if (block['type'] == 'text') {
        return <String, dynamic>{'type': 'text', 'text': block['text']};
      }
      return <String, dynamic>{
        'type': 'tool-call',
        'id': (block['toolCall'] as Map)['id'],
      };
    }).toList();
  }
  return <Map<String, dynamic>>[
    for (final _
        in (message['thinking'] is List ? message['thinking'] as List : []))
      <String, dynamic>{'type': 'thinking'},
    if (message['content'] is String)
      <String, dynamic>{'type': 'text', 'text': message['content']},
    for (final call
        in (message['toolCalls'] is List ? message['toolCalls'] as List : []))
      <String, dynamic>{
        'type': 'tool-call',
        'id': call is Map ? call['id'] : null,
      },
  ];
}

Map<String, dynamic> _joinAssistantRows(
  Map<String, dynamic> previous,
  Map<String, dynamic> row,
) {
  final text = [previous['content'], row['content']].whereType<String>().join();
  final thinking = <dynamic>[
    ...(previous['thinking'] is List ? previous['thinking'] as List : []),
    ...(row['thinking'] is List ? row['thinking'] as List : []),
  ];
  final toolCalls = <dynamic>[
    ...(previous['toolCalls'] is List ? previous['toolCalls'] as List : []),
    ...(row['toolCalls'] is List ? row['toolCalls'] as List : []),
  ];
  final blockOrder = _buildBlockOrder(<Map<String, dynamic>>[
    ..._blockOrderEntries(previous),
    ..._blockOrderEntries(row),
  ]);
  final rowResources = tanstackMetadata(row)?['uiResources'];
  final metadata = mergeMetadata(
    _isRecord(previous['metadata']) ? _asRecord(previous['metadata']) : null,
    row['metadata'],
  );
  Map<String, dynamic>? joinedMetadata = metadata == null
      ? null
      : <String, dynamic>{
          ...metadata,
          if (_isRecord(metadata['tanstack']))
            'tanstack': <String, dynamic>{..._asRecord(metadata['tanstack'])},
        };
  if (joinedMetadata != null && _isRecord(joinedMetadata['tanstack'])) {
    final tanstack = <String, dynamic>{..._asRecord(joinedMetadata['tanstack'])}
      ..remove('continues');
    if (tanstack.isEmpty) {
      joinedMetadata.remove('tanstack');
    } else {
      joinedMetadata['tanstack'] = tanstack;
    }
    if (joinedMetadata.isEmpty) joinedMetadata = null;
  }
  final merged = <String, dynamic>{...previous};
  if (joinedMetadata == null) {
    merged.remove('metadata');
  } else {
    merged['metadata'] = joinedMetadata;
  }
  var base = merged;
  if (rowResources is List && rowResources.isNotEmpty) {
    base = withTanstackMetadata(merged, <String, dynamic>{
      'uiResources': <dynamic>[
        ...(tanstackMetadata(previous)?['uiResources'] is List
            ? tanstackMetadata(previous)!['uiResources'] as List
            : <dynamic>[]),
        ...rowResources,
      ],
    });
  }
  return <String, dynamic>{
    ...base,
    if (text.isNotEmpty) 'content': text,
    if (toolCalls.isNotEmpty) 'toolCalls': toolCalls,
    if (thinking.isNotEmpty) 'thinking': thinking,
    if (blockOrder != null) 'blockOrder': blockOrder,
  };
}

Map<String, dynamic> _restoreModelMessageCreatedAt(
  Map<String, dynamic> message,
) {
  final createdAt = coerceCreatedAt(message['createdAt']) ??
      coerceCreatedAt(tanstackMetadata(message)?['createdAt']);
  if (createdAt == null) {
    if (!message.containsKey('createdAt')) return message;
    return <String, dynamic>{...message}..remove('createdAt');
  }
  return <String, dynamic>{...message, 'createdAt': createdAt};
}

/// Restore tool result ownership fields stored in `metadata.tanstack.toolResult`.
Map<String, dynamic> restoreToolResultOwnership(Map<String, dynamic> message) {
  if (message['role'] != 'tool') return message;
  final owned = tanstackMetadata(message)?['toolResult'];
  if (!_isRecord(owned)) return message;
  if (owned.containsKey('content') && !isContentPartArray(owned['content'])) {
    return message;
  }
  final next = <String, dynamic>{...message};
  if (!owned.containsKey('id')) next.remove('id');
  if (!owned.containsKey('createdAt')) next.remove('createdAt');
  if (owned['id'] is String) next['id'] = owned['id'];
  if (owned['createdAt'] is String) {
    final createdAt = coerceCreatedAt(owned['createdAt']);
    if (createdAt != null) next['createdAt'] = createdAt;
  }
  if (isContentPartArray(owned['content'])) next['content'] = owned['content'];
  final sourceMetadata = message['metadata'];
  if (_isRecord(sourceMetadata)) {
    final tanstack = sourceMetadata['tanstack'];
    if (_isRecord(tanstack)) {
      final restTanstack = <String, dynamic>{..._asRecord(tanstack)}
        ..remove('toolResult');
      final restMetadata = <String, dynamic>{..._asRecord(sourceMetadata)};
      if (restTanstack.isNotEmpty) {
        restMetadata['tanstack'] = restTanstack;
      } else {
        restMetadata.remove('tanstack');
      }
      if (restMetadata.isNotEmpty) {
        next['metadata'] = restMetadata;
      } else {
        next.remove('metadata');
      }
    }
  }
  return next;
}

Map<String, dynamic>? _assistantMetadata(Map<String, dynamic> uiMessage) {
  final parts = (uiMessage['parts'] as List)
      .where(_isUiResourcePart)
      .map((part) => _asRecord(part))
      .toList();
  final current = _isRecord(uiMessage['metadata'])
      ? _asRecord(uiMessage['metadata'])
      : <String, dynamic>{};
  final tanstack = <String, dynamic>{...?tanstackMetadata(uiMessage)};
  final run = tanstack['run'];
  if (_isRecord(run)) {
    tanstack['run'] = <String, dynamic>{..._asRecord(run)}
      ..remove('startedAt')
      ..remove('finishedAt');
  }
  for (final key in <String>[
    'createdAt',
    'continues',
    'structuredOutput',
    'toolCallMetadata',
    'toolResult',
    'toolResultOutcome',
    'uiResources',
  ]) {
    tanstack.remove(key);
  }
  if (parts.isNotEmpty) tanstack['uiResources'] = parts;
  final result = <String, dynamic>{...current};
  if (tanstack.isNotEmpty) {
    result['tanstack'] = tanstack;
  } else {
    result.remove('tanstack');
  }
  return result.isEmpty ? null : result;
}

bool _isToolCallIncluded(Map<String, dynamic> part) =>
    <String?>[
      'input-complete',
      'complete',
      'approval-requested',
      'approval-responded',
      'error',
    ].contains(part['state']) ||
    part.containsKey('output');

Map<String, dynamic> _buildUserOrToolMessage(Map<String, dynamic> uiMessage) {
  final contentParts = <Map<String, dynamic>>[];
  for (final raw in uiMessage['parts'] as List) {
    if (_isTextContentPart(raw)) contentParts.add(_asRecord(raw));
  }
  return <String, dynamic>{
    'id': uiMessage['id'],
    'role': uiMessage['role'],
    'content': _collapseContentParts(contentParts),
    if (uiMessage['name'] != null) 'name': uiMessage['name'],
    ..._optionalCreatedAt(uiMessage),
    if (uiMessage['metadata'] != null) 'metadata': uiMessage['metadata'],
  };
}

/// Convert an assistant UI message into one or more model messages.
List<Map<String, dynamic>> _buildAssistantMessages(
  Map<String, dynamic> uiMessage,
) {
  final messageList = <Map<String, dynamic>>[];
  var contentParts = <Map<String, dynamic>>[];
  var toolCalls = <Map<String, dynamic>>[];
  var order = <Map<String, dynamic>>[];
  var pendingThinking = <Map<String, dynamic>>[];
  Map<String, dynamic>? structuredOutput;
  final emittedToolResultIds = <String>{};
  final identityFields = <String, dynamic>{
    'id': uiMessage['id'],
    if (uiMessage['name'] != null) 'name': uiMessage['name'],
    ..._optionalCreatedAt(uiMessage),
  };
  final metadata = _assistantMetadata(uiMessage);
  final assistantFields = <String, dynamic>{
    ...identityFields,
    if (metadata != null) 'metadata': metadata,
  };

  void flushSegment([bool force = false]) {
    final content = _collapseContentParts(contentParts);
    final hasContent = content != null;
    final hasToolCalls = toolCalls.isNotEmpty;
    final hasThinking = pendingThinking.isNotEmpty;
    final blockOrder = content is List ? null : _buildBlockOrder(order);
    if (force || hasContent || hasToolCalls || hasThinking) {
      messageList.add(<String, dynamic>{
        ...assistantFields,
        'role': 'assistant',
        'content': content,
        if (hasToolCalls) 'toolCalls': toolCalls,
        if (hasThinking) 'thinking': pendingThinking,
        if (structuredOutput != null) 'structuredOutput': structuredOutput,
        if (blockOrder != null) 'blockOrder': blockOrder,
      });
      pendingThinking = <Map<String, dynamic>>[];
    }
    contentParts = <Map<String, dynamic>>[];
    toolCalls = <Map<String, dynamic>>[];
    order = <Map<String, dynamic>>[];
    structuredOutput = null;
  }

  for (final raw in uiMessage['parts'] as List) {
    if (!_isRecord(raw)) continue;
    final part = _asRecord(raw);
    switch (part['type']) {
      case 'text':
        contentParts.add(part);
        order.add(<String, dynamic>{
          'type': 'text',
          'text': _string(part['content']),
        });
        break;
      case 'image':
      case 'audio':
      case 'video':
      case 'document':
        contentParts.add(part);
        break;
      case 'tool-call':
        if (_isToolCallIncluded(part)) {
          toolCalls.add(<String, dynamic>{
            'id': part['id'],
            'type': 'function',
            'function': <String, dynamic>{
              'name': part['name'],
              'arguments': part['arguments'],
            },
            if (part['metadata'] != null) 'metadata': part['metadata'],
          });
          order.add(<String, dynamic>{'type': 'tool-call', 'id': part['id']});
        }
        break;
      case 'tool-result':
        flushSegment(messageList.isEmpty);
        final toolCallId = _string(part['toolCallId']);
        if (<String?>['complete', 'error'].contains(part['state']) &&
            !emittedToolResultIds.contains(toolCallId)) {
          final resultMetadata = part['outcome'] == null
              ? part['metadata']
              : withTanstackMetadata(part, <String, dynamic>{
                  'toolResultOutcome': part['outcome'],
                })['metadata'];
          messageList.add(<String, dynamic>{
            if (part['id'] != null) 'id': part['id'],
            ..._optionalCreatedAt(part),
            'role': 'tool',
            'content': part['content'],
            'toolCallId': toolCallId,
            if (part['name'] != null) 'name': part['name'],
            if (resultMetadata != null) 'metadata': resultMetadata,
            if (part['error'] != null) 'error': part['error'],
          });
          emittedToolResultIds.add(toolCallId);
        }
        break;
      case 'thinking':
        if (_string(part['content']).isNotEmpty || part['signature'] != null) {
          if (toolCalls.any(isProviderExecutedToolCall)) flushSegment();
          pendingThinking.add(<String, dynamic>{
            'content': _string(part['content']),
            if (part['signature'] != null) 'signature': part['signature'],
            if (part['redacted'] == true) 'redacted': true,
          });
          order.add(<String, dynamic>{'type': 'thinking'});
        }
        break;
      case 'structured-output':
        if (part['status'] == 'complete') {
          final serialized =
              part['raw'] is String && (part['raw'] as String).isNotEmpty
                  ? part['raw'] as String
                  : part['data'] != null
                      ? safeJsonStringify(part['data'])
                      : '';
          if (serialized.isNotEmpty) {
            contentParts.add(
              <String, dynamic>{'type': 'text', 'content': serialized},
            );
            order.add(<String, dynamic>{'type': 'text', 'text': serialized});
            structuredOutput = part;
          }
        }
        break;
      case 'ui-resource':
      case 'activity':
        break;
      case 'subagent':
        {
          final subagent = _asRecord(part['subagent']);
          final block = subagent['parentToolCallId'] == null
              ? subagentHistoryText(part)
              : '';
          if (block.isNotEmpty) {
            final prefix = contentParts.isNotEmpty ? '\n\n' : '';
            final text = '$prefix$block';
            contentParts
                .add(<String, dynamic>{'type': 'text', 'content': text});
            order.add(<String, dynamic>{'type': 'text', 'text': text});
          }
          break;
        }
    }
  }

  flushSegment();

  for (final raw in uiMessage['parts'] as List) {
    if (!_isRecord(raw) || raw['type'] != 'tool-call') continue;
    final part = _asRecord(raw);
    final id = _string(part['id']);
    if (part.containsKey('output') && !emittedToolResultIds.contains(id)) {
      messageList.add(<String, dynamic>{
        'role': 'tool',
        'content': normalizeToolResult(part['output']),
        'toolCallId': id,
      });
      emittedToolResultIds.add(id);
    }
    final approval =
        _isRecord(part['approval']) ? _asRecord(part['approval']) : null;
    if (!part.containsKey('output') &&
        part['state'] == 'approval-responded' &&
        approval?['approved'] != null &&
        !emittedToolResultIds.contains(id)) {
      final approved = approval!['approved'] == true;
      messageList.add(<String, dynamic>{
        'role': 'tool',
        'content': jsonEncode(<String, dynamic>{
          'approved': approved,
          if (approved) 'pendingExecution': true,
          'message': approved
              ? 'User approved this action'
              : 'User denied this action',
        }),
        'toolCallId': id,
        if (!approved)
          'metadata': <String, dynamic>{
            'tanstack': <String, dynamic>{'toolResultOutcome': 'denied'},
          },
      });
      emittedToolResultIds.add(id);
    }
  }

  if (messageList.isEmpty) {
    messageList.add(<String, dynamic>{
      ...assistantFields,
      'role': 'assistant',
      'content': null,
    });
  }
  return messageList;
}

/// Convert a UI message to model messages, preserving part interleaving.
List<Map<String, dynamic>> uiMessageToModelMessages(
  Map<String, dynamic> uiMessage,
) {
  final role = uiMessage['role'];
  if (role == 'system' || role == 'activity') return <Map<String, dynamic>>[];
  if (role != 'assistant') {
    return <Map<String, dynamic>>[_buildUserOrToolMessage(uiMessage)];
  }
  return _buildAssistantMessages(uiMessage);
}

Map<String, dynamic> _thinkingToPart(Map<String, dynamic> thinking) =>
    <String, dynamic>{
      'type': 'thinking',
      'content': _string(thinking['content']),
      if (thinking['signature'] != null) 'signature': thinking['signature'],
      if (thinking['redacted'] == true) 'redacted': true,
    };

Map<String, dynamic> _toolCallToPart(Map<String, dynamic> toolCall) {
  final function = _asRecord(toolCall['function']);
  final arguments = _string(function['arguments']);
  dynamic input;
  try {
    input = jsonDecode(arguments);
  } catch (_) {
    input = null;
  }
  return <String, dynamic>{
    'type': 'tool-call',
    'id': toolCall['id'],
    'name': function['name'],
    'arguments': arguments,
    'state': 'input-complete',
    if (input != null) 'input': input,
    if (toolCall['metadata'] != null) 'metadata': toolCall['metadata'],
  };
}

Map<String, dynamic>? _snapshotStructuredOutput(dynamic value) {
  if (!_isRecord(value)) return null;
  final status = value['status'];
  if (!<String>['streaming', 'complete', 'error'].contains(status) ||
      value['raw'] is! String) {
    return null;
  }
  final base = <String, dynamic>{
    'type': 'structured-output',
    'raw': value['raw'],
    if (value['partial'] != null) 'partial': value['partial'],
    if (value['reasoning'] != null && (value['reasoning'] as String).isNotEmpty)
      'reasoning': value['reasoning'],
    if (value['errorMessage'] != null) 'errorMessage': value['errorMessage'],
  };
  if (status != 'complete') {
    return <String, dynamic>{...base, 'status': status};
  }
  if (value['data'] == null) return null;
  return <String, dynamic>{
    ...base,
    'status': 'complete',
    'data': value['data']
  };
}

/// Convert a model message to a UI message.
Map<String, dynamic> modelMessageToUIMessage(
  Map<String, dynamic> modelMessage, [
  String? id,
]) {
  final parts = <Map<String, dynamic>>[];
  final createdAt = coerceCreatedAt(modelMessage['createdAt']);

  if (modelMessage['role'] == 'assistant' && modelMessage['thinking'] is List) {
    for (final raw in modelMessage['thinking'] as List) {
      final thinking = _asRecord(raw);
      if (_string(thinking['content']).isEmpty &&
          thinking['signature'] == null) {
        continue;
      }
      parts.add(_thinkingToPart(thinking));
    }
  }

  final structuredOutput = modelMessage['structuredOutput'] is Map
      ? _asRecord(modelMessage['structuredOutput'])
      : _snapshotStructuredOutput(
          tanstackMetadata(modelMessage)?['structuredOutput'],
        );

  if (modelMessage['role'] == 'assistant' && structuredOutput != null) {
    final content = modelMessage['content'];
    final raw = _string(structuredOutput['raw']);
    if (content is String && content.isNotEmpty && content != raw) {
      final text = raw.isNotEmpty && content.endsWith(raw)
          ? content.substring(0, content.length - raw.length)
          : content;
      if (text.isNotEmpty) {
        parts.add(<String, dynamic>{'type': 'text', 'content': text});
      }
    }
    parts.add(structuredOutput);
  } else if (modelMessage['role'] == 'tool' &&
      modelMessage['toolCallId'] != null) {
    final rawOutcome = tanstackMetadata(modelMessage)?['toolResultOutcome'];
    final outcome = isToolResultOutcome(rawOutcome) ? rawOutcome : null;
    final resultState =
        modelMessage['error'] == null && outcome == null ? 'complete' : 'error';
    parts.add(<String, dynamic>{
      'type': 'tool-result',
      'toolCallId': modelMessage['toolCallId'],
      'content': _toolResultContent(modelMessage['content']),
      'state': resultState,
      if (outcome != null) 'outcome': outcome,
      if (modelMessage['id'] != null) 'id': modelMessage['id'],
      if (modelMessage['name'] != null) 'name': modelMessage['name'],
      if (modelMessage['metadata'] != null)
        'metadata': modelMessage['metadata'],
      if (createdAt != null) 'createdAt': createdAt,
      if (modelMessage['error'] != null) 'error': modelMessage['error'],
    });
  } else if (modelMessage['content'] is List) {
    for (final part in modelMessage['content'] as List) {
      if (_isRecord(part)) parts.add(_asRecord(part));
    }
  } else {
    final text = _getTextContent(modelMessage['content']);
    if (text.isNotEmpty) {
      parts.add(<String, dynamic>{'type': 'text', 'content': text});
    }
  }

  if (modelMessage['toolCalls'] is List) {
    for (final call in modelMessage['toolCalls'] as List) {
      parts.add(_toolCallToPart(_asRecord(call)));
    }
  }

  final ordered =
      modelMessage['role'] == 'assistant' && structuredOutput == null
          ? _orderedAssistantBlocks(modelMessage)
          : null;
  if (ordered != null) {
    parts
      ..clear()
      ..addAll(ordered.expand((block) {
        if (block['type'] == 'text') {
          return <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'content': block['text']},
          ];
        }
        if (block['type'] == 'tool-call') {
          return <Map<String, dynamic>>[
            _toolCallToPart(_asRecord(block['toolCall'])),
          ];
        }
        final thinking = _asRecord(block['thinking']);
        return _string(thinking['content']).isNotEmpty ||
                thinking['signature'] != null
            ? <Map<String, dynamic>>[_thinkingToPart(thinking)]
            : <Map<String, dynamic>>[];
      }));
  }

  final ui = <String, dynamic>{
    'id': id ?? (modelMessage['id'] ?? generateMessageId()),
    'role': modelMessage['role'] == 'tool' ? 'assistant' : modelMessage['role'],
    'parts': parts,
    if (modelMessage['name'] != null) 'name': modelMessage['name'],
    if (createdAt != null) 'createdAt': createdAt,
    if (modelMessage['metadata'] != null) 'metadata': modelMessage['metadata'],
  };
  final storedResources = tanstackMetadata(modelMessage)?['uiResources'];
  return _appendUiResources(
    ui,
    storedResources is List
        ? storedResources.where(_isUiResourcePart).map(_asRecord).toList()
        : <Map<String, dynamic>>[],
  );
}

Map<String, dynamic> _applySnapshotMetadata(
  dynamic source,
  Map<String, dynamic> ui,
) {
  final normalizedParts = (ui['parts'] as List).map((raw) {
    final part = _asRecord(raw);
    if (part['type'] != 'tool-result') return part;
    final createdAt = coerceCreatedAt(part['createdAt']);
    part.remove('createdAt');
    if (createdAt != null) part['createdAt'] = createdAt;
    return part;
  }).toList();
  var next = <String, dynamic>{...ui, 'parts': normalizedParts};
  if (_isRecord(source) && source['name'] is String) {
    next['name'] = source['name'];
  }

  Map<String, dynamic>? metadata;
  if (_isRecord(source) && _isRecord(source['metadata'])) {
    metadata = _asRecord(source['metadata']);
    next['metadata'] = metadata;
  }

  final createdAt = coerceCreatedAt(next['createdAt']) ??
      (metadata != null
          ? coerceCreatedAt(tanstackMetadata(metadata)?['createdAt'])
          : null);
  if (createdAt != null) {
    next['createdAt'] = createdAt;
  } else {
    next.remove('createdAt');
  }

  final uiResources = tanstackMetadata(metadata)?['uiResources'];
  return _appendUiResources(
    next,
    uiResources is List
        ? uiResources.where(_isUiResourcePart).map(_asRecord).toList()
        : <Map<String, dynamic>>[],
  );
}

/// Normalize one AG-UI snapshot message into a UI message map.
Map<String, dynamic> aguiSnapshotMessageToUIMessage(dynamic raw) {
  if (!_isRecord(raw)) {
    return <String, dynamic>{
      'id': generateMessageId(),
      'role': 'assistant',
      'parts': <Map<String, dynamic>>[],
    };
  }
  final message = _asRecord(raw);
  if (message.containsKey('parts')) {
    return _applySnapshotMetadata(message, <String, dynamic>{
      ...message,
      'id':
          _string(message['id']).isEmpty ? generateMessageId() : message['id'],
    });
  }

  final id = _string(message['id']).isEmpty
      ? generateMessageId()
      : message['id'] as String;

  switch (message['role']) {
    case 'user':
      return _applySnapshotMetadata(message, <String, dynamic>{
        'id': id,
        'role': 'user',
        'parts': _aguiUserContentToParts(message['content']),
      });
    case 'assistant':
      {
        final metadata = tanstackMetadata(message);
        final toolCallMetadata = metadata?['toolCallMetadata'];
        final structuredOutput =
            _snapshotStructuredOutput(metadata?['structuredOutput']);
        final wireCalls = message['toolCalls'];
        final toolCalls = wireCalls is List
            ? wireCalls.map((call) {
                final map = _asRecord(call);
                final callMetadata = _isRecord(toolCallMetadata)
                    ? toolCallMetadata[map['id']]
                    : null;
                return callMetadata != null
                    ? <String, dynamic>{...map, 'metadata': callMetadata}
                    : map;
              }).toList()
            : null;
        return _applySnapshotMetadata(
          message,
          modelMessageToUIMessage(<String, dynamic>{
            'role': 'assistant',
            'content': message['content'],
            if (message['name'] != null) 'name': message['name'],
            if (toolCalls != null) 'toolCalls': toolCalls,
            if (structuredOutput != null) 'structuredOutput': structuredOutput,
          }, id),
        );
      }
    case 'tool':
      {
        final restored = restoreToolResultOwnership(message);
        final createdAt = coerceCreatedAt(restored['createdAt']) ??
            coerceCreatedAt(tanstackMetadata(restored)?['createdAt']);
        return _applySnapshotMetadata(
          restored,
          modelMessageToUIMessage(<String, dynamic>{
            'role': 'tool',
            'content': isContentPartArray(restored['content'])
                ? restored['content']
                : aguiContentToContentParts(restored['content']),
            'toolCallId': restored['toolCallId'],
            if (restored['name'] is String) 'name': restored['name'],
            if (restored['id'] is String) 'id': restored['id'],
            if (restored['metadata'] != null) 'metadata': restored['metadata'],
            if (createdAt != null) 'createdAt': createdAt,
            if (restored['error'] != null) 'error': restored['error'],
          }, id),
        );
      }
    case 'system':
    case 'developer':
      return _applySnapshotMetadata(message, <String, dynamic>{
        'id': id,
        'role': 'system',
        'parts': _string(message['content']).isNotEmpty
            ? <Map<String, dynamic>>[
                <String, dynamic>{
                  'type': 'text',
                  'content': message['content'],
                },
              ]
            : <Map<String, dynamic>>[],
      });
    case 'reasoning':
      {
        final signature = _encryptedValueFrom(message);
        final content = _string(message['content']);
        return _applySnapshotMetadata(message, <String, dynamic>{
          'id': id,
          'role': 'assistant',
          'parts': content.isNotEmpty || signature != null
              ? <Map<String, dynamic>>[
                  <String, dynamic>{
                    'type': 'thinking',
                    'content': content,
                    if (signature != null) 'signature': signature,
                    ..._redactedFrom(message),
                  },
                ]
              : <Map<String, dynamic>>[],
        });
      }
    case 'activity':
      return _applySnapshotMetadata(message, <String, dynamic>{
        'id': id,
        'role': 'activity',
        'parts': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'activity',
            'activityType': message['activityType'],
            'content': jsonDecode(jsonEncode(message['content'])),
          },
        ],
      });
    default:
      return _applySnapshotMetadata(message, <String, dynamic>{
        'id': id,
        'role': 'assistant',
        'parts': <Map<String, dynamic>>[],
      });
  }
}

List<Map<String, dynamic>> _aguiUserContentToParts(dynamic content) {
  final converted = aguiContentToContentParts(content);
  if (converted is String) {
    return converted.isEmpty
        ? <Map<String, dynamic>>[]
        : <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'content': converted},
          ];
  }
  if (converted is List) {
    return converted.where(_isRecord).map(_asRecord).toList();
  }
  return <Map<String, dynamic>>[];
}

/// Convert AG-UI wire content parts to TanStack content parts.
dynamic aguiContentToContentParts(dynamic content) {
  if (content is String) return content;
  if (content is! List) return content;
  return content.map((raw) {
    if (!_isRecord(raw)) return raw;
    final part = _asRecord(raw);
    if (part['type'] != 'text') return part;
    final text = part.remove('text');
    part['content'] = text;
    return part;
  }).toList();
}

/// Convert model messages to UI messages, merging tool results into the
/// preceding assistant turn.
List<Map<String, dynamic>> modelMessagesToUIMessages(
  List<Map<String, dynamic>> modelMessages,
) {
  final uiMessages = <Map<String, dynamic>>[];
  Map<String, dynamic>? currentAssistantMessage;

  for (final msg in modelMessages) {
    if (msg['role'] == 'tool') {
      if (msg['toolCallId'] != null && currentAssistantMessage != null) {
        final content = _toolResultContent(msg['content']);
        final rawOutcome = tanstackMetadata(msg)?['toolResultOutcome'];
        final outcome = isToolResultOutcome(rawOutcome) ? rawOutcome : null;
        final resultState =
            msg['error'] == null && outcome == null ? 'complete' : 'error';
        final parts = currentAssistantMessage['parts'] as List;
        Map<String, dynamic>? toolCallPart;
        for (final raw in parts) {
          if (_isRecord(raw) &&
              raw['type'] == 'tool-call' &&
              raw['id'] == msg['toolCallId']) {
            toolCallPart = raw.cast<String, dynamic>();
            break;
          }
        }
        if (toolCallPart != null) {
          if (content is String) {
            try {
              toolCallPart['output'] = jsonDecode(content);
            } catch (_) {
              toolCallPart['output'] = content;
            }
          } else {
            toolCallPart['output'] = content;
          }
          toolCallPart['state'] = resultState;
        }
        parts.add(<String, dynamic>{
          'type': 'tool-result',
          'toolCallId': msg['toolCallId'],
          'content': content,
          'state': resultState,
          if (outcome != null) 'outcome': outcome,
          if (msg['id'] != null && msg['id'] != currentAssistantMessage['id'])
            'id': msg['id'],
          if (msg['name'] != null) 'name': msg['name'],
          if (msg['metadata'] != null) 'metadata': msg['metadata'],
          ..._optionalCreatedAt(msg),
          if (msg['error'] != null) 'error': msg['error'],
        });
      } else {
        uiMessages.add(
          modelMessageToUIMessage(
              msg, msg['id'] is String ? msg['id'] as String : null),
        );
      }
    } else {
      final uiMessage = modelMessageToUIMessage(
        msg,
        msg['id'] is String ? msg['id'] as String : null,
      );
      if (msg['role'] == 'assistant' &&
          currentAssistantMessage != null &&
          (msg['id'] == currentAssistantMessage['id'] ||
              isAssistantSegmentOf(
                msg['id'] is String ? msg['id'] as String : null,
                currentAssistantMessage['id'] as String,
              ))) {
        (currentAssistantMessage['parts'] as List)
            .addAll(uiMessage['parts'] as List);
        continue;
      }
      uiMessages.add(uiMessage);
      currentAssistantMessage = msg['role'] == 'assistant' ? uiMessage : null;
    }
  }
  return uiMessages;
}

/// Normalize a UI or model message to a UI message.
Map<String, dynamic> normalizeToUIMessage(
  Map<String, dynamic> message,
  String Function() generateId,
) {
  if (message.containsKey('parts')) {
    final parts = (message['parts'] as List).map((raw) {
      final part = _asRecord(raw);
      if (part['type'] != 'tool-result') return part;
      final createdAt = coerceCreatedAt(part['createdAt']);
      part.remove('createdAt');
      if (createdAt != null) part['createdAt'] = createdAt;
      return part;
    }).toList();
    return <String, dynamic>{
      ...message,
      'parts': parts,
      'id': _string(message['id']).isEmpty ? generateId() : message['id'],
      'createdAt': coerceCreatedAt(message['createdAt']) ?? DateTime.now(),
    };
  }
  final ui = modelMessageToUIMessage(message, generateId());
  return <String, dynamic>{
    ...ui,
    'createdAt': coerceCreatedAt(message['createdAt']) ?? DateTime.now(),
  };
}

// ---------------------------------------------------------------------------
// Block order
// ---------------------------------------------------------------------------

List<Map<String, dynamic>>? _buildBlockOrder(
  List<Map<String, dynamic>> entries,
) {
  final blocks = <Map<String, dynamic>>[];
  var thinking = 0;
  var isDefault = true;
  for (final entry in entries) {
    final last = blocks.isEmpty ? null : blocks.last;
    if (entry['type'] == 'thinking') {
      if (last != null && last['type'] != 'thinking') isDefault = false;
      blocks.add(<String, dynamic>{'type': 'thinking', 'index': thinking++});
    } else if (entry['type'] == 'text') {
      final text = _string(entry['text']);
      if (text.isEmpty) continue;
      if (last?['type'] == 'text') {
        last!['length'] = (last['length'] as int) + text.length;
        continue;
      }
      if (last?['type'] == 'tool-call') isDefault = false;
      blocks.add(<String, dynamic>{'type': 'text', 'length': text.length});
    } else {
      blocks.add(<String, dynamic>{
        'type': 'tool-call',
        'id': entry['id'],
      });
    }
  }
  return isDefault ? null : blocks;
}

List<Map<String, dynamic>>? _orderedAssistantBlocks(
  Map<String, dynamic> message,
) {
  final order = message['blockOrder'];
  if (order is! List || order.isEmpty) return null;
  final contentValue = message['content'];
  final content = contentValue is String ? contentValue : '';
  if (contentValue != null && contentValue is! String) return null;
  final thinking = message['thinking'] is List
      ? (message['thinking'] as List).map(_asRecord).toList()
      : <Map<String, dynamic>>[];
  final toolCalls = message['toolCalls'] is List
      ? (message['toolCalls'] as List).map(_asRecord).toList()
      : <Map<String, dynamic>>[];
  final usedThinking = <int>{};
  final usedCalls = <String>{};
  final blocks = <Map<String, dynamic>>[];
  var offset = 0;
  for (final raw in order) {
    if (!_isRecord(raw)) return null;
    final block = _asRecord(raw);
    if (block['type'] == 'thinking') {
      final index = block['index'];
      if (index is! int ||
          index < 0 ||
          index >= thinking.length ||
          usedThinking.contains(index)) {
        return null;
      }
      usedThinking.add(index);
      blocks.add(<String, dynamic>{
        'type': 'thinking',
        'thinking': thinking[index],
      });
    } else if (block['type'] == 'text') {
      final length = block['length'];
      if (length is! int || length <= 0 || offset + length > content.length) {
        return null;
      }
      blocks.add(<String, dynamic>{
        'type': 'text',
        'text': content.substring(offset, offset + length),
      });
      offset += length;
    } else if (block['type'] == 'tool-call') {
      final id = block['id'];
      if (id is! String || usedCalls.contains(id)) return null;
      Map<String, dynamic>? call;
      for (final candidate in toolCalls) {
        if (candidate['id'] == id) {
          call = candidate;
          break;
        }
      }
      if (call == null) return null;
      usedCalls.add(id);
      blocks.add(<String, dynamic>{'type': 'tool-call', 'toolCall': call});
    } else {
      return null;
    }
  }
  if (offset != content.length ||
      usedThinking.length != thinking.length ||
      usedCalls.length != toolCalls.length) {
    return null;
  }
  return blocks;
}

// ---------------------------------------------------------------------------
// Activity sidecars (frontend-only AG-UI ActivityMessage rows)
// ---------------------------------------------------------------------------

/// Convert one persisted activity sidecar row to a UI message.
Map<String, dynamic> activityRecordToUIMessage(Map<String, dynamic> record) {
  return <String, dynamic>{
    'id': record['id'] ?? generateMessageId(),
    'role': 'activity',
    'parts': <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'activity',
        'activityType': record['activityType'],
        'content': _clone(record['content']),
        if (record['subagentRunId'] != null)
          'subagentRunId': record['subagentRunId'],
      },
    ],
    if (_isRecord(record['metadata'])) 'metadata': _clone(record['metadata']),
  };
}

/// Insert persisted activity rows into a model-derived UI transcript at each
/// record's stored `index`. Earlier records win when indexes tie.
List<Map<String, dynamic>> interleaveActivityRecords(
  List<Map<String, dynamic>> modelUI,
  List<Map<String, dynamic>> records,
) {
  final out = <Map<String, dynamic>>[...modelUI];
  final sorted = <Map<String, dynamic>>[...records]..sort(
      (a, b) => (a['index'] as int? ?? 0).compareTo(b['index'] as int? ?? 0));
  for (final record in sorted) {
    final index = record['index'] is int ? record['index'] as int : 0;
    out.insert(index.clamp(0, out.length), activityRecordToUIMessage(record));
  }
  return out;
}

/// Collect inbound activity messages as sidecar rows, keeping their source
/// position in `index`. Accepts UI-shaped and AG-UI-shaped activity messages.
List<Map<String, dynamic>> peelInboundActivities(List<dynamic> messages) {
  final records = <Map<String, dynamic>>[];
  for (var index = 0; index < messages.length; index++) {
    final raw = messages[index];
    if (!_isRecord(raw) || raw['role'] != 'activity') continue;
    final message = _asRecord(raw);
    Map<String, dynamic> source;
    final parts = message['parts'];
    if (parts is List) {
      final part = parts.whereType<Map>().cast<Map>().firstWhere(
            (part) => part['type'] == 'activity',
            orElse: () => <String, dynamic>{},
          );
      source = _asRecord(part);
    } else {
      source = message;
    }
    if (source['activityType'] is! String || !_isRecord(source['content'])) {
      continue;
    }
    final subagentRunId = source['subagentRunId'] ?? message['subagentRunId'];
    records.add(<String, dynamic>{
      'id': _string(message['id']).isNotEmpty
          ? message['id']
          : generateMessageId(),
      'activityType': source['activityType'],
      'content': _clone(source['content']),
      'index': index,
      if (subagentRunId is String) 'subagentRunId': subagentRunId,
      if (_isRecord(message['metadata']))
        'metadata': _clone(message['metadata']),
    });
  }
  return records;
}
