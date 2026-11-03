import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:tanstack_ai_dart/connections.dart';

/// Records every request and answers with the supplied handler.
class FakeHttpClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest request)
      handler;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  FakeHttpClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return handler(request);
  }
}

http.StreamedResponse rawResponse(
  String body, {
  int status = 200,
  String reasonPhrase = 'OK',
  Map<String, String> headers = const {'content-type': 'text/event-stream'},
}) {
  return http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(body)),
    status,
    reasonPhrase: reasonPhrase,
    headers: headers,
  );
}

http.StreamedResponse jsonResponse(
  Object? body, {
  int status = 200,
  String reasonPhrase = 'OK',
}) {
  return rawResponse(
    jsonEncode(body),
    status: status,
    reasonPhrase: reasonPhrase,
    headers: const {'content-type': 'application/json'},
  );
}

http.StreamedResponse failingResponse(
  String body,
  Object error, {
  int status = 200,
}) {
  return http.StreamedResponse(
    () async* {
      yield utf8.encode(body);
      throw error;
    }(),
    status,
    reasonPhrase: 'OK',
  );
}

/// A response body that the test pushes chunks into.
class ControlledResponse {
  final StreamController<List<int>> _controller = StreamController<List<int>>();
  bool cancelled = false;

  ControlledResponse([FutureOr<void> Function()? onCancel]) {
    _controller.onCancel = () {
      cancelled = true;
      return onCancel?.call();
    };
  }

  http.StreamedResponse get response => http.StreamedResponse(
        _controller.stream,
        200,
        reasonPhrase: 'OK',
        headers: const {'content-type': 'text/event-stream'},
      );

  void write(String text) => _controller.add(utf8.encode(text));

  Future<void> close() => _controller.close();
}

Map<String, dynamic> contentChunk(String delta) => {
      'type': 'TEXT_MESSAGE_CONTENT',
      'messageId': 'm',
      'model': 'test',
      'timestamp': 0,
      'delta': delta,
      'content': delta,
    };

Map<String, dynamic> finishedChunk({
  String threadId = 't',
  String runId = 'r',
}) =>
    {
      'type': 'RUN_FINISHED',
      'threadId': threadId,
      'runId': runId,
      'model': 'test',
      'timestamp': 0,
      'metadata': {
        'tanstack': {'finishReason': 'stop'},
      },
    };

String sseEvent(Map<String, dynamic> chunk, {String? id}) =>
    '${id == null ? '' : 'id: $id\n'}data: ${jsonEncode(chunk)}\n\n';

String sseData(String data) => 'data: $data\n\n';

String ndjsonLine(Map<String, dynamic> chunk, {String? id}) =>
    '${jsonEncode(id == null ? chunk : {'id': id, 'chunk': chunk})}\n';

Map<String, String> headersOf(http.BaseRequest request) => request.headers;

String? bodyOf(http.BaseRequest request) {
  if (request is! http.Request) return null;
  return request.body.trim().isEmpty ? null : request.body;
}

Map<String, dynamic> jsonBodyOf(http.BaseRequest request) =>
    jsonDecode(bodyOf(request) ?? '{}') as Map<String, dynamic>;

Future<Object> captureError(FutureOr<Object?> Function() action) async {
  try {
    await action();
  } catch (error) {
    return error;
  }
  throw StateError('Expected the future to fail');
}

/// A fake socket used by webSocket() tests.
class FakeWebSocket implements WebSocketConnection {
  static final List<FakeWebSocket> instances = <FakeWebSocket>[];

  final Uri url;
  final List<String> sent = <String>[];
  final StreamController<String> _messages =
      StreamController<String>.broadcast();
  final Completer<void> _opened = Completer<void>();
  final Completer<SocketCloseInfo> _closed = Completer<SocketCloseInfo>();

  FakeWebSocket(this.url) {
    instances.add(this);
    scheduleMicrotask(() {
      readyState = 1;
      if (!_opened.isCompleted) _opened.complete();
    });
  }

  @override
  int readyState = 0;

  @override
  Future<void> get opened => _opened.future;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Future<SocketCloseInfo> get closed => _closed.future;

  @override
  void send(String data) {
    sent.add(data);
  }

  @override
  void close([int code = 1000, String reason = '']) {
    if (readyState == 3) return;
    readyState = 3;
    if (!_closed.isCompleted) _closed.complete(SocketCloseInfo(code, reason));
    if (!_messages.isClosed) _messages.close();
  }

  void serverClose(int code, [String reason = '']) => close(code, reason);

  void emit(Map<String, dynamic> chunk, {String? id}) {
    _messages.add(jsonEncode(id == null ? chunk : {'id': id, 'chunk': chunk}));
  }

  void emitRaw(String data) {
    _messages.add(data);
  }
}

WebSocketConnection fakeSocketFactory(
  Uri url, {
  List<String>? protocols,
}) =>
    FakeWebSocket(url);

Future<void> tick() => Future<void>.delayed(Duration.zero);

Future<List<StreamChunk>> collect(Stream<StreamChunk> stream) =>
    stream.toList();

List<String?> deltasOf(List<StreamChunk> chunks) => chunks
    .where((chunk) => chunk['type'] == 'TEXT_MESSAGE_CONTENT')
    .map((chunk) => chunk['delta'] as String?)
    .toList();
