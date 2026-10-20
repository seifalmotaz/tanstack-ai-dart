import 'dart:convert';

import 'package:http/http.dart' as http;

import 'cancellation.dart';
import 'http_common.dart';
import 'types.dart';

/// A cursor to a run that is still generating.
class ActiveRun {
  final String runId;

  const ActiveRun(this.runId);

  Map<String, dynamic> toJson() => {'runId': runId};
}

/// Pending human-in-the-loop interrupts for a thread.
class ChatInterrupts {
  final String runId;
  final List<WireMessage> pending;

  const ChatInterrupts({required this.runId, required this.pending});
}

/// Paging metadata for a chat hydration window.
class ChatHydrationPage {
  final bool truncated;
  final String? cursor;

  const ChatHydrationPage({this.truncated = false, this.cursor});

  const ChatHydrationPage.full()
      : truncated = false,
        cursor = null;
}

/// Paging options for a chat hydrate GET. Omit both to load the full thread.
class ChatHydrateOptions {
  final int? limit;
  final String? before;

  const ChatHydrateOptions({this.limit, this.before});
}

/// Server-resolved hydration for a chat thread.
class ChatHydrationResult {
  final List<WireMessage> messages;
  final ActiveRun? activeRun;
  final ChatInterrupts? interrupts;
  final ChatHydrationPage page;

  const ChatHydrationResult({
    required this.messages,
    this.activeRun,
    this.interrupts,
    this.page = const ChatHydrationPage.full(),
  });
}

/// Server-resolved hydration for a generation thread.
class GenerationHydrationResult {
  final Map<String, dynamic>? resumeSnapshot;
  final ActiveRun? activeRun;

  const GenerationHydrationResult({this.resumeSnapshot, this.activeRun});
}

/// GET a chat hydration endpoint (`?threadId`, optional `limit` / `before`).
Future<ChatHydrationResult> fetchThreadHydration(
  http.Client client,
  String url,
  Map<String, String> headers,
  String threadId,
  ChatHydrateOptions? options, {
  CancellationSignal? signal,
}) async {
  final values = <String, String>{'threadId': threadId};
  if (options?.limit != null) values['limit'] = '${options!.limit}';
  if (options?.before != null) values['before'] = options!.before!;
  final data = await _getJson(
    client,
    withSearchParams(url, values),
    headers,
    signal,
  );
  final map = data is Map ? data : const <String, dynamic>{};

  final activeRunRaw = map['activeRun'];
  final activeRun = activeRunRaw is Map && activeRunRaw['runId'] is String
      ? ActiveRun(activeRunRaw['runId'] as String)
      : null;

  final interruptsRaw = map['interrupts'];
  ChatInterrupts? interrupts;
  if (interruptsRaw is Map &&
      interruptsRaw['runId'] is String &&
      interruptsRaw['pending'] is List &&
      (interruptsRaw['pending'] as List).isNotEmpty) {
    interrupts = ChatInterrupts(
      runId: interruptsRaw['runId'] as String,
      pending: (interruptsRaw['pending'] as List)
          .whereType<Map>()
          .map((item) => item.map((k, v) => MapEntry('$k', v)))
          .toList(),
    );
  }

  return ChatHydrationResult(
    messages: map['messages'] is List
        ? normalizeMessageDates(
            (map['messages'] as List)
                .whereType<Map>()
                .map((item) => item.map((k, v) => MapEntry('$k', v)))
                .toList(),
          )
        : <WireMessage>[],
    activeRun: activeRun,
    interrupts: interrupts,
    page: _readPage(map['page']),
  );
}

/// GET a generation hydration endpoint (`?threadId`).
///
/// A 200 carrying `null` is a genuine miss. Any other non-object body is a
/// broken endpoint and throws instead of being presented as a fresh thread.
Future<GenerationHydrationResult> fetchGenerationHydration(
  http.Client client,
  String url,
  Map<String, String> headers,
  String threadId, {
  CancellationSignal? signal,
}) async {
  final target = withSearchParams(url, {'threadId': threadId});
  final raw = await _getJson(client, target, headers, signal);
  if (raw == null) {
    return const GenerationHydrationResult();
  }
  if (raw is! Map) {
    final kind = raw is List ? 'an array' : 'a ${raw.runtimeType}';
    throw FormatException(
      'Generation hydration expected a JSON object from $target, '
      'received $kind.',
    );
  }
  final activeRunRaw = raw['activeRun'];
  final activeRun = activeRunRaw is Map && activeRunRaw['runId'] is String
      ? ActiveRun(activeRunRaw['runId'] as String)
      : null;
  final snapshot = raw['resumeSnapshot'];
  return GenerationHydrationResult(
    resumeSnapshot: snapshot is Map
        ? snapshot.map((key, value) => MapEntry('$key', value))
        : null,
    activeRun: activeRun,
  );
}

/// Normalize only the date fields TanStack owns: message `createdAt` and part
/// `createdAt`. Invalid dates are removed, matching `normalizeMessagesDates`.
List<WireMessage> normalizeMessageDates(List<WireMessage> messages) {
  final out = <WireMessage>[];
  for (final message in messages) {
    final normalized = Map<String, dynamic>.from(message);
    _normalizeDate(normalized);
    final parts = normalized['parts'];
    if (parts is List) {
      normalized['parts'] = [
        for (final part in parts)
          if (part is Map)
            () {
              final copy = part.map((key, value) => MapEntry('$key', value));
              _normalizeDate(copy);
              return copy;
            }()
          else
            part,
      ];
    }
    out.add(normalized);
  }
  return out;
}

void _normalizeDate(Map<String, dynamic> value) {
  final raw = value['createdAt'];
  if (raw is! String) return;
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) {
    value.remove('createdAt');
  } else {
    value['createdAt'] = parsed;
  }
}

ChatHydrationPage _readPage(Object? value) {
  if (value is! Map || value['truncated'] != true) {
    return const ChatHydrationPage.full();
  }
  final cursor = value['cursor'];
  if (cursor is! String || cursor.isEmpty) {
    return const ChatHydrationPage.full();
  }
  return ChatHydrationPage(truncated: true, cursor: cursor);
}

Future<Object?> _getJson(
  http.Client client,
  String url,
  Map<String, String> headers,
  CancellationSignal? signal,
) async {
  final request = http.AbortableRequest(
    'GET',
    Uri.parse(url),
    abortTrigger: signal?.whenCancelled,
  )..headers.addAll({'Accept': 'application/json', ...headers});
  final response = await client.send(request);
  await assertResponseOk(response);
  final body = await response.stream.transform(utf8.decoder).join();
  if (signal?.isCancelled ?? false) return null;
  return jsonDecode(body);
}

/// Merge [values] into a URL's existing query parameters.
String withSearchParams(String url, Map<String, String> values) {
  final uri = Uri.parse(url);
  final query = <String, String>{...uri.queryParameters, ...values};
  return uri.replace(queryParameters: query).toString();
}
