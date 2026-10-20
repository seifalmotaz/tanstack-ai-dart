import 'dart:convert';

import 'cancellation.dart';
import 'errors.dart';
import 'reconnect.dart';
import 'sse_utils.dart';
import 'types.dart';
import 'wire.dart';

/// A parsed stream chunk paired with its adapter-owned delivery offset.
class StreamEvent {
  final StreamChunk chunk;
  final String? id;

  const StreamEvent(this.chunk, {this.id});
}

/// A re-issuable event source. Each call MUST open a fresh request.
typedef StreamEventSource = Stream<StreamEvent> Function(
  Map<String, String> extraHeaders,
  CancellationSignal? signal,
);

/// Whether [value] is a durable NDJSON `{ id, chunk }` envelope.
///
/// A bare chunk always has a top-level `type`; the envelope never does.
bool isNdjsonEnvelope(Object? value) {
  if (value is! Map) return false;
  return value.containsKey('chunk') &&
      value.containsKey('id') &&
      value['id'] is String &&
      !value.containsKey('type');
}

/// Parse SSE lines into events, pairing chunks with their `id:` offset.
Stream<StreamEvent> linesToSseEvents(
  Stream<String> lines, {
  String? fallbackThreadId,
  String? fallbackRunId,
}) async* {
  String? lastThreadId;
  String? lastRunId;
  String? lastModel;
  String? pendingId;

  await for (final line in lines) {
    if (line == 'id' || line.startsWith('id:')) {
      final rawId = line == 'id' ? '' : line.substring(3);
      pendingId = rawId.startsWith(' ') ? rawId.substring(1) : rawId;
      continue;
    }
    if (line.startsWith(':') ||
        line.startsWith('event:') ||
        line.startsWith('retry:')) {
      continue;
    }
    final data = parseSseDataLine(line);
    if (data == '[DONE]') {
      yield StreamEvent(
        withTanstackMetadata(
          {
            'type': 'RUN_FINISHED',
            'threadId': lastThreadId ?? fallbackThreadId ?? '',
            'runId': lastRunId ?? fallbackRunId ?? '',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          },
          {
            'finishReason': 'stop',
            if (lastModel != null) 'model': lastModel,
          },
        ),
      );
      return;
    }

    final decoded = jsonDecode(data);
    if (decoded is! Map) {
      throw FormatException('SSE data must be a JSON object: $data');
    }
    final chunk = restoreInboundChunk(
      decoded.map((key, value) => MapEntry('$key', value)),
    );
    if (chunk['threadId'] is String) {
      lastThreadId = chunk['threadId'] as String;
    }
    if (chunk['runId'] is String) {
      lastRunId = chunk['runId'] as String;
    }
    final model = _sseChunkModel(chunk);
    if (model != null) lastModel = model;
    final id = pendingId;
    pendingId = null;
    yield StreamEvent(chunk, id: id);
  }
}

/// Parse NDJSON lines into events. Durable `{ id, chunk }` envelopes and bare
/// chunks are auto-detected.
Stream<StreamEvent> linesToNdjsonEvents(Stream<String> lines) async* {
  await for (final line in lines) {
    final parsed = jsonDecode(line);
    if (isNdjsonEnvelope(parsed)) {
      final map = parsed as Map;
      final chunk = map['chunk'];
      if (chunk is! Map) {
        throw FormatException('NDJSON envelope chunk must be a JSON object');
      }
      yield StreamEvent(
        restoreInboundChunk(
          chunk.map((key, value) => MapEntry('$key', value)),
        ),
        id: map['id'] as String,
      );
    } else {
      if (parsed is! Map) {
        throw FormatException('NDJSON line must be a JSON object: $line');
      }
      yield StreamEvent(
        restoreInboundChunk(
          parsed.map((key, value) => MapEntry('$key', value)),
        ),
      );
    }
  }
}

/// Drive [openEventSource] with resumability.
///
/// Each event's `id` is remembered; if the connection drops or ends before a
/// terminal event, the source is re-opened with a `Last-Event-ID` header so the
/// server replays strictly after the last offset. Already-seen offsets are
/// de-duped. Untagged streams never reconnect.
Stream<StreamChunk> resumableStream(
  StreamEventSource openEventSource,
  CancellationSignal? signal,
  ReconnectOptions? reconnectOptions,
) async* {
  final tracker = ReconnectTracker(reconnectOptions);

  while (true) {
    if (signal?.isCancelled ?? false) return;
    final extraHeaders = <String, String>{
      if (tracker.lastEventId != null) 'Last-Event-ID': tracker.lastEventId!,
    };

    var sawTerminal = false;
    var progressed = false;
    try {
      await for (final event in openEventSource(extraHeaders, signal)) {
        if (tracker.note(event.id) == ReconnectNote.duplicate) continue;
        progressed = true;
        final type = event.chunk['type'];
        if (type == 'RUN_FINISHED' || type == 'RUN_ERROR') {
          sawTerminal = true;
        }
        yield event.chunk;
      }
    } catch (error) {
      if (signal?.isCancelled ?? false) return;
      final resumable =
          (error is StreamTruncatedError || error is StreamReadError) &&
              tracker.lastEventId != null;
      if (resumable) {
        await tracker.waitBeforeReconnect(progressed, signal);
        continue;
      }
      rethrow;
    }

    if (signal?.isCancelled ?? false) return;

    if (sawTerminal) return;

    if (tracker.lastEventId != null) {
      if (progressed) {
        await tracker.waitBeforeReconnect(true, signal);
        continue;
      }
      throw const DurableStreamIncompleteError();
    }

    return;
  }
}

String? _sseChunkModel(StreamChunk chunk) {
  final tanstackModel = tanstackMetadata(chunk)?['model'];
  if (tanstackModel is String) return tanstackModel;
  final usage = chunk['usage'];
  if (usage is List && usage.isNotEmpty && usage.first is Map) {
    final model = (usage.first as Map)['model'];
    if (model is String) return model;
  }
  return null;
}
