import 'dart:convert';

import '../identity.dart' as identity;
import '../processing/agui_wire.dart' as agui;
import 'types.dart';

export '../processing/agui_wire.dart' show uiMessagesToWire;

/// Read `metadata.tanstack` from a chunk, if present.
Map<String, dynamic>? tanstackMetadata(StreamChunk chunk) {
  final metadata = chunk['metadata'];
  if (metadata is! Map) return null;
  final tanstack = metadata['tanstack'];
  if (tanstack is! Map) return null;
  return tanstack.map((key, value) => MapEntry('$key', value));
}

/// Merge [tanstack] into `metadata.tanstack`, preserving other metadata.
StreamChunk withTanstackMetadata(
  StreamChunk chunk,
  Map<String, dynamic> tanstack,
) {
  final metadata = chunk['metadata'];
  final current = metadata is Map
      ? Map<String, dynamic>.from(metadata)
      : <String, dynamic>{};
  final currentTanstack = tanstackMetadata(chunk) ?? <String, dynamic>{};
  return {
    ...chunk,
    'metadata': {
      ...current,
      'tanstack': {...currentTanstack, ...tanstack},
    },
  };
}

/// Rebuild the pre-wire chunk shape after SSE/NDJSON/WebSocket ingest.
///
/// Copies `metadata.tanstack` extras back to top-level fields, restores the
/// `usage[]` wire array into TanStack's `{promptTokens,...}` shape, and repairs
/// `toolName` / `TOOL_CALL_END.input` aliases the wire does not keep.
StreamChunk restoreInboundChunk(StreamChunk chunk) {
  _restorePublicUsage(chunk);
  final tanstack = tanstackMetadata(chunk);
  if (tanstack == null) return chunk;

  for (final entry in tanstack.entries) {
    final key = entry.key;
    if (key == 'usage' || key == 'interruptErrors') continue;
    if (chunk[key] == null && entry.value != null) {
      chunk[key] = entry.value;
    }
  }
  if (tanstack['interruptErrors'] != null) {
    chunk['tanstack:interruptErrors'] = tanstack['interruptErrors'];
  }
  return chunk;
}

void _restorePublicUsage(StreamChunk chunk) {
  final type = chunk['type'];
  if (type == 'RUN_FINISHED' || type == 'RUN_ERROR') {
    final usage = chunk['usage'];
    if (usage is List || _isTanstackUsage(usage)) {
      final rebuilt = _rebuildTokenUsage(
        usage,
        tanstackMetadata(chunk)?['usage'],
      );
      if (rebuilt != null) chunk['usage'] = rebuilt;
    }
  }

  if (type == 'TOOL_CALL_START' &&
      chunk['toolName'] == null &&
      chunk['toolCallName'] != null) {
    chunk['toolName'] = chunk['toolCallName'];
  }

  if (type == 'TOOL_CALL_END' && chunk['input'] == null) {
    final tanstack = tanstackMetadata(chunk);
    final input = tanstack?['input'];
    if (input != null) {
      chunk['input'] = input;
    } else if (tanstack?['args'] is String) {
      chunk['input'] = _tryJson(tanstack!['args'] as String);
    }
  }
}

bool _isTanstackUsage(Object? usage) =>
    usage is Map && usage.containsKey('promptTokens');

Map<String, dynamic>? _rebuildTokenUsage(Object? usage, Object? leftover) {
  if (_isTanstackUsage(usage)) {
    return (usage as Map).map((key, value) => MapEntry('$key', value));
  }
  final leftovers = leftover is Map
      ? leftover.map((key, value) => MapEntry('$key', value))
      : null;

  if (usage is List) {
    if (usage.isEmpty && leftovers == null) return null;
    var input = 0;
    var output = 0;
    var total = 0;
    int? cached;
    int? cacheWrite;
    int? reasoning;
    for (final entry in usage) {
      if (entry is! Map) continue;
      input += _intValue(entry['inputTokens']);
      output += _intValue(entry['outputTokens']);
      total += _intValue(entry['totalTokens']);
      if (entry['cachedInputTokens'] is num) {
        cached = (cached ?? 0) + (entry['cachedInputTokens'] as num).toInt();
      }
      if (entry['cacheWriteInputTokens'] is num) {
        cacheWrite =
            (cacheWrite ?? 0) + (entry['cacheWriteInputTokens'] as num).toInt();
      }
      if (entry['reasoningTokens'] is num) {
        reasoning =
            (reasoning ?? 0) + (entry['reasoningTokens'] as num).toInt();
      }
    }
    final promptDetails = <String, dynamic>{
      if (cached != null) 'cachedTokens': cached,
      if (cacheWrite != null) 'cacheWriteTokens': cacheWrite,
      if (leftovers?['promptTokensDetails'] is Map)
        ...(leftovers!['promptTokensDetails'] as Map)
            .map((key, value) => MapEntry('$key', value)),
    };
    final completionDetails = <String, dynamic>{
      if (reasoning != null) 'reasoningTokens': reasoning,
      if (leftovers?['completionTokensDetails'] is Map)
        ...(leftovers!['completionTokensDetails'] as Map)
            .map((key, value) => MapEntry('$key', value)),
    };
    return {
      if (leftovers != null) ...leftovers,
      'promptTokens': input,
      'completionTokens': output,
      'totalTokens': total,
      if (promptDetails.isNotEmpty) 'promptTokensDetails': promptDetails,
      if (completionDetails.isNotEmpty)
        'completionTokensDetails': completionDetails,
    };
  }

  if (leftovers == null) return null;
  return {
    ...leftovers,
    'promptTokens': 0,
    'completionTokens': 0,
    'totalTokens': 0,
  };
}

int _intValue(Object? value) => value is num ? value.toInt() : 0;

Object? _tryJson(String raw) {
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

/// Build the AG-UI `RunAgentInput` payload shared by every POST adapter.
///
/// Precedence (later wins): static adapter `body`, then
/// `runContext.forwardedProps`, then per-send `data`. The legacy `data` field
/// mirrors `forwardedProps` for older servers.
Map<String, dynamic> buildRunAgentInputBody(
  List<WireMessage> messages,
  Map<String, dynamic>? data,
  RunAgentInputContext? runContext, {
  Map<String, dynamic>? body,
}) {
  final forwardedProps = <String, dynamic>{
    ...?body,
    ...?runContext?.forwardedProps,
    ...?data,
  };
  return {
    'threadId': runContext?.threadId ?? identity.generateIdentity('thread'),
    'runId': runContext?.runId ?? identity.generateIdentity('run'),
    if (runContext?.parentRunId != null) 'parentRunId': runContext!.parentRunId,
    if (runContext?.resume != null) 'resume': runContext!.resume,
    'state': <String, dynamic>{},
    'messages': agui.uiMessagesToWire(messages),
    'tools': runContext?.clientTools?.map((tool) => tool.toJson()).toList() ??
        <dynamic>[],
    'context': <dynamic>[],
    'forwardedProps': forwardedProps,
    'data': <String, dynamic>{...forwardedProps},
  };
}
