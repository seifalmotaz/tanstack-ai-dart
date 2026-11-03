import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sse_parser.dart';

/// Error raised for a non-2xx chat response.
class ChatTransportException implements Exception {
  /// HTTP status code (`0` when the response never arrived).
  final int status;

  /// Server error code when the body contained one; otherwise `UNKNOWN`.
  final String code;

  /// Human-readable server error, or the HTTP reason phrase/plain body.
  final String message;

  const ChatTransportException({
    required this.status,
    required this.code,
    required this.message,
  });

  int get statusCode => status;

  factory ChatTransportException.fromHttp(
    int status,
    String? reasonPhrase,
    String body,
  ) {
    var code = 'UNKNOWN';
    var message = (reasonPhrase == null || reasonPhrase.trim().isEmpty)
        ? 'HTTP $status'
        : reasonPhrase.trim();

    final trimmed = body.trim();
    if (trimmed.isNotEmpty) {
      dynamic decoded;
      try {
        decoded = jsonDecode(trimmed);
      } catch (_) {
        decoded = null;
      }
      if (decoded is Map) {
        final nested = decoded['error'];
        final error = nested is Map ? nested : decoded;
        final rawCode = error['code'] ?? decoded['code'];
        if (rawCode != null && '$rawCode'.isNotEmpty) code = '$rawCode';
        final rawMessage = error['message'] ?? decoded['message'];
        if (rawMessage is List) {
          message = rawMessage.join(' · ');
        } else if (rawMessage != null && '$rawMessage'.trim().isNotEmpty) {
          message = '$rawMessage'.trim();
        }
      } else {
        message = trimmed;
      }
    }

    return ChatTransportException(
      status: status,
      code: code,
      message: message,
    );
  }

  @override
  String toString() {
    final prefix = status > 0 ? 'HTTP $status ' : '';
    return 'ChatTransportException($prefix$code): $message';
  }
}

/// Minimal seam used by [ChatClient]; implement it to fake streaming.
abstract class ChatTransport {
  Stream<Map<String, dynamic>> stream(Map<String, dynamic> body);
}

/// SSE transport for the legacy TanStack AI / AG-UI chat endpoint.
///
/// Each call to [stream] opens its own HTTP client. Cancelling the returned
/// subscription closes that client immediately, even if the server is silent.
/// A 401 is retried exactly once when [onUnauthorized] is provided; headers
/// are re-evaluated and the original body is replayed before any event is
/// consumed. Other non-2xx responses become [ChatTransportException].
///
/// The stream completes on `[DONE]`, EOF, or `RUN_ERROR`. `RUN_FINISHED` is
/// forwarded but does not close the transport: the legacy agent loop emits it
/// once per model iteration, so closing early would drop later tool results,
/// approvals, and the final answer.
class SseChatTransport implements ChatTransport {
  final String endpoint;
  final FutureOr<Map<String, String>> Function() headers;
  final http.Client Function()? clientFactory;
  final Future<void> Function()? onUnauthorized;
  final Duration connectTimeout;
  final Duration idleTimeout;

  SseChatTransport(
    this.endpoint, {
    required this.headers,
    this.clientFactory,
    this.onUnauthorized,
    this.connectTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(seconds: 90),
  });

  @override
  Stream<Map<String, dynamic>> stream(Map<String, dynamic> body) {
    late StreamController<Map<String, dynamic>> controller;
    http.Client? client;
    StreamSubscription<List<int>>? subscription;
    var cancelled = false;
    var closed = false;

    void closeClient() {
      client?.close();
      client = null;
    }

    void finish() {
      if (closed) return;
      closed = true;
      final current = subscription;
      subscription = null;
      if (current != null) unawaited(current.cancel());
      closeClient();
      if (!controller.isClosed) controller.close();
    }

    void fail(Object error, [StackTrace? stack]) {
      if (cancelled || closed) return;
      controller.addError(error, stack);
      finish();
    }

    void handleData(String data) {
      if (closed) return;
      if (data.trim() == '[DONE]') {
        finish();
        return;
      }
      if (data.trim().isEmpty) return;

      dynamic decoded;
      try {
        decoded = jsonDecode(data);
      } catch (_) {
        throw FormatException(
          'Malformed SSE data payload: ${_preview(data)}',
        );
      }
      if (decoded is! Map) {
        throw FormatException(
          'SSE data must be a JSON object, got ${decoded.runtimeType}: '
          '${_preview(data)}',
        );
      }
      final event = Map<String, dynamic>.from(decoded);
      controller.add(event);
      if (event['type'] == 'RUN_ERROR') finish();
    }

    void processFrames(List<String> frames) {
      for (final data in frames) {
        if (closed) return;
        handleData(data);
      }
    }

    Future<void> run() async {
      final activeClient = clientFactory?.call() ?? http.Client();
      client = activeClient;

      Future<http.StreamedResponse> send() async {
        final request = http.Request('POST', Uri.parse(endpoint));
        request.headers.addAll(await Future.sync(headers));
        if (!_hasHeader(request.headers, 'content-type')) {
          request.headers['Content-Type'] = 'application/json';
        }
        if (!_hasHeader(request.headers, 'accept')) {
          request.headers['Accept'] = 'text/event-stream';
        }
        request.body = jsonEncode(body);
        return activeClient.send(request).timeout(connectTimeout);
      }

      try {
        var response = await send();
        if (cancelled) return;

        if (response.statusCode == 401 && onUnauthorized != null) {
          try {
            await response.stream.drain<void>().timeout(connectTimeout);
          } catch (_) {
            // The 401 body is irrelevant; continue with the single retry.
          }
          await onUnauthorized!();
          if (cancelled) return;
          response = await send();
        }

        if (response.statusCode < 200 || response.statusCode >= 300) {
          String errorBody;
          try {
            errorBody =
                await response.stream.bytesToString().timeout(connectTimeout);
          } catch (_) {
            errorBody = '';
          }
          throw ChatTransportException.fromHttp(
            response.statusCode,
            response.reasonPhrase,
            errorBody,
          );
        }

        final parser = SseFrameParser();
        subscription = response.stream.timeout(idleTimeout).listen(
          (chunk) {
            if (closed || cancelled) return;
            try {
              processFrames(parser.add(chunk));
            } catch (e, st) {
              fail(e, st);
            }
          },
          onError: (Object e, StackTrace st) {
            fail(e, st);
          },
          onDone: () {
            if (closed || cancelled) return;
            try {
              processFrames(parser.finish());
            } catch (e, st) {
              fail(e, st);
              return;
            }
            if (closed) return;
            closed = true;
            closeClient();
            if (!controller.isClosed) controller.close();
          },
          cancelOnError: true,
        );
      } catch (e, st) {
        if (!cancelled) {
          fail(e, st);
        } else {
          closeClient();
        }
      }
    }

    controller = StreamController<Map<String, dynamic>>(
      onListen: () => unawaited(run()),
      onCancel: () async {
        cancelled = true;
        final current = subscription;
        subscription = null;
        await current?.cancel();
        closeClient();
      },
    );

    return controller.stream;
  }
}

bool _hasHeader(Map<String, String> headers, String name) =>
    headers.keys.any((key) => key.toLowerCase() == name);

String _preview(String value, [int max = 200]) {
  final flat = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= max ? flat : '${flat.substring(0, max)}…';
}
