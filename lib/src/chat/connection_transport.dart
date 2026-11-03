import 'dart:async';

import '../connections/connection_adapter.dart';
import '../connections/types.dart' show RunAgentInputContext, WireMessage;
import '../connections/cancellation.dart';
import '../connections/hydration.dart' as conn;
import '../processing/processor.dart';
import '../protocol.dart';
import '../transport.dart';
import 'types.dart';

/// Bridges a canonical [ConnectionAdapter] onto the legacy [ChatTransport]
/// seam. ChatClient uses the modern path directly so the shared
/// [StreamProcessor] owns message identity; this adapter remains available for
/// callers that only need raw chunks.
class ConnectionChatTransport implements ChatTransport {
  final ConnectionAdapter connection;

  const ConnectionChatTransport(this.connection);

  @override
  Stream<Map<String, dynamic>> stream(
    Map<String, dynamic> body, {
    Map<String, String>? headers,
    CancellationSignal? signal,
  }) {
    final rawMessages = body['messages'];
    final messages = <WireMessage>[
      if (rawMessages is List)
        for (final row in rawMessages)
          if (row is Map) row.map((key, value) => MapEntry('$key', value)),
    ];
    final threadId = '${body['threadId'] ?? body['durableThreadId'] ?? ''}';
    final runId = '${body['runId'] ?? ''}';
    final parentRunId =
        body['parentRunId'] is String ? body['parentRunId'] as String : null;
    final resume = body['resume'] is List
        ? [
            for (final item in body['resume'] as List)
              if (item is Map)
                item.map((key, value) => MapEntry('$key', value)),
          ]
        : null;
    final forwardedProps = body['forwardedProps'] is Map
        ? Map<String, dynamic>.from(body['forwardedProps'] as Map)
        : null;
    final runContext = RunAgentInputContext(
      threadId: threadId,
      runId: runId,
      parentRunId: parentRunId,
      resume: resume,
      forwardedProps: forwardedProps,
      headers: headers,
    );

    if (connection.connect != null) {
      return connection.connect!(
        messages,
        data: forwardedProps,
        runContext: runContext,
      );
    }

    final normalized = normalizeConnectionAdapter(connection);
    late StreamController<Map<String, dynamic>> controller;
    final cancellation = CancellationController();
    final localSignal = cancellation.signal;

    StreamSubscription<Map<String, dynamic>>? subscription;
    var closed = false;

    void close() {
      if (closed) return;
      closed = true;
      cancellation.cancel();
      signal?.removeListener(close);
      unawaited(subscription?.cancel());
      if (!controller.isClosed) controller.close();
    }

    signal?.addListener(close);
    controller = StreamController<Map<String, dynamic>>(
      onListen: () {
        subscription = normalized.subscribe(signal: localSignal).listen(
          (chunk) {
            if (closed) return;
            controller.add(chunk);
            final metadata = chunk['metadata'];
            final tanstack = metadata is Map ? metadata['tanstack'] : null;
            final finishReason = chunk['finishReason'] ??
                (tanstack is Map ? tanstack['finishReason'] : null);
            if (chunk['type'] == 'RUN_ERROR' ||
                (chunk['type'] == 'RUN_FINISHED' &&
                    finishReason != 'tool_calls')) {
              close();
            }
          },
          onError: (Object error, StackTrace stack) {
            if (closed) return;
            controller.addError(error, stack);
            close();
          },
        );
        unawaited(
          normalized
              .send(
            messages,
            data: forwardedProps,
            signal: localSignal,
            runContext: runContext,
          )
              .catchError((Object error, StackTrace stack) {
            if (closed) return;
            controller.addError(error, stack);
            close();
          }),
        );
      },
      onCancel: close,
    );
    return controller.stream;
  }
}

/// Convert processor UI messages into the package's [AssistantTurn] model.
///
/// Unlike [assistantTurnsFromThread], this preserves every distinct server
/// message id. The processor already merged deltas into each message; merging
/// again here would collapse concurrent lanes and replayed messages.
List<AssistantTurn> assistantTurnsFromProcessor(
  List<Map<String, dynamic>> messages,
) {
  final out = <AssistantTurn>[];
  var index = 0;
  for (final raw in messages) {
    index += 1;
    final role = '${raw['role'] ?? ''}';
    if (role != 'user' && role != 'assistant' && role != 'activity') {
      continue;
    }
    final rawParts = raw['parts'];
    final parts = <AssistantPart>[
      if (rawParts is List)
        for (final part in rawParts)
          if (part is Map) AssistantPart.fromJson(part),
    ];
    final createdAtRaw = raw['createdAt'];
    final createdAt = createdAtRaw is DateTime
        ? createdAtRaw
        : createdAtRaw is String
            ? DateTime.tryParse(createdAtRaw)
            : null;
    out.add(
      AssistantTurn(
        id: '${raw['id'] ?? 'msg-$index'}',
        role: role,
        parts: parts,
        name: raw['name'] is String ? raw['name'] as String : null,
        metadata: raw['metadata'] is Map
            ? Map<String, dynamic>.from(raw['metadata'] as Map)
            : null,
        createdAt: createdAt,
      ),
    );
  }
  return out;
}

/// Convert turns to the processor/wire UI-message shape.
List<Map<String, dynamic>> assistantWireTurns(Iterable<AssistantTurn> turns,
        {bool includeActivity = false}) =>
    [
      for (final turn in turns)
        if (includeActivity || turn.role != 'activity')
          <String, dynamic>{
            'id': turn.id,
            'role': turn.role,
            'parts': <Map<String, dynamic>>[
              for (final part in turn.parts) part.toJson(),
            ],
            if (turn.createdAt != null) 'createdAt': turn.createdAt,
            if (turn.name != null) 'name': turn.name,
            if (turn.metadata != null) 'metadata': turn.metadata,
          },
    ];

/// Convert canonical connection hydration to the chat client's result shape.
ChatHydrationResult chatHydrationFromConnection(
  conn.ChatHydrationResult result,
) {
  return ChatHydrationResult(
    messages: assistantTurnsFromThread(<String, dynamic>{
      'messages': result.messages,
    }),
    activeRun: result.activeRun == null
        ? null
        : ChatResumeState(
            threadId: '',
            runId: result.activeRun!.runId,
          ),
    interrupts: result.interrupts == null
        ? null
        : ChatHydrationInterrupts(
            runId: result.interrupts!.runId,
            pending: result.interrupts!.pending,
          ),
    page: ChatHydrationPage(
      truncated: result.page.truncated,
      cursor: result.page.cursor,
    ),
  );
}

/// Wrap a canonical hydrate callback as a [ChatHydrateCallback].
ChatHydrateCallback connectionHydrateCallback(
  HydrateFunction hydrate,
) =>
    (threadId, options) async {
      final result = await hydrate(
        threadId,
        options: conn.ChatHydrateOptions(
          before: options.before,
          limit: options.limit,
        ),
      );
      final converted = chatHydrationFromConnection(result);
      final run = converted.activeRun;
      return ChatHydrationResult(
        messages: converted.messages,
        activeRun: run == null
            ? null
            : ChatResumeState(threadId: threadId, runId: run.runId),
        interrupts: converted.interrupts,
        page: converted.page,
      );
    };
