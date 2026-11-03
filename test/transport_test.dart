import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';
import 'package:test/test.dart';

void main() {
  group('SseChatTransport', () {
    test('sends headers/body, parses split UTF-8 and unknown events', () async {
      final requests = <http.Request>[];
      final fake = _FakeClient((request) async {
        requests.add(request as http.Request);
        final payload = utf8.encode(
          'data: {"type":"SOMETHING_NEW","value":"مرحبا"}\n\n'
          'data: [DONE]\n\n',
        );
        return _sse(_chunk(payload, 3));
      });
      final transport = SseChatTransport(
        'https://example.test/chat',
        headers: () => {'X-Test': 'yes'},
        clientFactory: () => fake,
      );

      final events = await transport.stream({'hello': 'world'}).toList();

      expect(events, [
        {'type': 'SOMETHING_NEW', 'value': 'مرحبا'},
      ]);
      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://example.test/chat');
      expect(request.headers['X-Test'], 'yes');
      expect(request.headers['Content-Type'], 'application/json');
      expect(request.headers['Accept'], 'text/event-stream');
      expect(jsonDecode(request.body), {'hello': 'world'});
      expect(fake.closed, isTrue);
    });

    test('CRLF comments, id/event fields and multiline data are accepted',
        () async {
      final fake = _FakeClient(
        (_) async => _sse([
          utf8.encode(
            'id: 4\r\n'
            'event: custom\r\n'
            ': comment\r\n'
            'data: {"type":"CUSTOM",\r\n'
            'data: "name":"approval-requested",\r\n'
            'data: "value":{}}\r\n'
            '\r\n',
          ),
          utf8.encode('data: [DONE]\r\n\r\n'),
        ]),
      );
      final transport = SseChatTransport(
        'https://example.test/chat',
        headers: () => const {},
        clientFactory: () => fake,
      );

      final events = await transport.stream({}).toList();
      expect(events, [
        {
          'type': 'CUSTOM',
          'name': 'approval-requested',
          'value': <String, dynamic>{},
        },
      ]);
    });

    test('401 refreshes once, re-evaluates headers and replays the body',
        () async {
      final bodies = <String>[];
      final auths = <String>[];
      var calls = 0;
      var refreshes = 0;
      var token = 'old';

      final fake = _FakeClient((request) async {
        final req = request as http.Request;
        calls += 1;
        bodies.add(req.body);
        auths.add(req.headers['Authorization'] ?? '');
        if (calls == 1) {
          return _sse(
            [utf8.encode('unauthorized')],
            status: 401,
            reasonPhrase: 'Unauthorized',
          );
        }
        return _sse([
          utf8.encode('data: {"type":"CUSTOM","name":"ok"}\n\n'),
          utf8.encode('data: [DONE]\n\n'),
        ]);
      });

      final transport = SseChatTransport(
        'https://example.test/chat',
        headers: () => {'Authorization': 'Bearer $token'},
        clientFactory: () => fake,
        onUnauthorized: () async {
          refreshes += 1;
          token = 'new';
        },
      );

      final events = await transport.stream({'messages': []}).toList();

      expect(refreshes, 1);
      expect(calls, 2);
      expect(auths, ['Bearer old', 'Bearer new']);
      expect(bodies[0], bodies[1]);
      expect(events.single['name'], 'ok');
      expect(fake.closed, isTrue);
    });

    test('a second 401 is not retried', () async {
      var calls = 0;
      var refreshes = 0;
      final fake = _FakeClient((_) async {
        calls += 1;
        return _sse(
          [utf8.encode('still unauthorized')],
          status: 401,
          reasonPhrase: 'Unauthorized',
        );
      });
      final transport = SseChatTransport(
        'https://example.test/chat',
        headers: () => const {},
        clientFactory: () => fake,
        onUnauthorized: () async {
          refreshes += 1;
        },
      );

      try {
        await transport.stream({}).drain<void>();
        fail('expected ChatTransportException');
      } on ChatTransportException catch (e) {
        expect(e.status, 401);
        expect(e.code, 'UNKNOWN');
        expect(e.message, 'still unauthorized');
      }
      expect(calls, 2);
      expect(refreshes, 1);
      expect(fake.closed, isTrue);
    });

    test('plain-text non-2xx body becomes a typed exception', () async {
      final fake = _FakeClient(
        (_) async => _sse(
          [utf8.encode('permission denied')],
          status: 403,
          reasonPhrase: 'Forbidden',
        ),
      );
      final transport = SseChatTransport(
        'https://example.test/chat',
        headers: () => const {},
        clientFactory: () => fake,
      );

      try {
        await transport.stream({}).drain<void>();
        fail('expected ChatTransportException');
      } on ChatTransportException catch (e) {
        expect(e.status, 403);
        expect(e.statusCode, 403);
        expect(e.code, 'UNKNOWN');
        expect(e.message, 'permission denied');
      }
    });

    test('nested/root JSON server error is parsed', () async {
      final fake = _FakeClient(
        (_) async => _sse(
          [
            utf8.encode(
              '{"error":{"code":"INSUFFICIENT_CREDITS",'
              '"message":"No credits"}}',
            ),
          ],
          status: 402,
          reasonPhrase: 'Payment Required',
        ),
      );
      final transport = SseChatTransport(
        'https://example.test/chat',
        headers: () => const {},
        clientFactory: () => fake,
      );

      try {
        await transport.stream({}).drain<void>();
        fail('expected ChatTransportException');
      } on ChatTransportException catch (e) {
        expect(e.status, 402);
        expect(e.code, 'INSUFFICIENT_CREDITS');
        expect(e.message, 'No credits');
      }
    });

    test('root JSON message list is joined', () async {
      final fake = _FakeClient(
        (_) async => _sse(
          [utf8.encode('{"code":"BAD_INPUT","message":["a","b"]}')],
          status: 400,
          reasonPhrase: 'Bad Request',
        ),
      );
      final transport = SseChatTransport(
        'https://example.test/chat',
        headers: () => const {},
        clientFactory: () => fake,
      );

      try {
        await transport.stream({}).drain<void>();
        fail('expected ChatTransportException');
      } on ChatTransportException catch (e) {
        expect(e.status, 400);
        expect(e.code, 'BAD_INPUT');
        expect(e.message, 'a · b');
      }
    });

    test('malformed data throws a FormatException', () async {
      final fake = _FakeClient(
        (_) async => _sse([utf8.encode('data: {nope}\n\n')]),
      );
      final transport = SseChatTransport(
        'https://example.test/chat',
        headers: () => const {},
        clientFactory: () => fake,
      );

      await expectLater(
        transport.stream({}).drain<void>(),
        throwsA(isA<FormatException>()),
      );
      expect(fake.closed, isTrue);
    });

    test('non-object JSON data throws a FormatException', () async {
      final fake = _FakeClient(
        (_) async => _sse([utf8.encode('data: [1,2]\n\n')]),
      );
      final transport = SseChatTransport(
        'https://example.test/chat',
        headers: () => const {},
        clientFactory: () => fake,
      );

      await expectLater(
        transport.stream({}).drain<void>(),
        throwsA(isA<FormatException>()),
      );
    });

    test('RUN_ERROR is emitted then closes a silent socket', () async {
      final body = StreamController<List<int>>();
      final fake = _FakeClient((_) async {
        scheduleMicrotask(() {
          body.add(
              utf8.encode('data: {"type":"RUN_ERROR","message":"boom"}\n\n'));
        });
        return http.StreamedResponse(body.stream, 200);
      });
      final transport = SseChatTransport(
        'https://example.test/chat',
        headers: () => const {},
        clientFactory: () => fake,
      );

      final events = await transport
          .stream({})
          .toList()
          .timeout(const Duration(seconds: 2));

      expect(events.single, {'type': 'RUN_ERROR', 'message': 'boom'});
      expect(fake.closed, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(body.hasListener, isFalse);
      await body.close();
    });

    test('[DONE] is terminal and closes a silent socket', () async {
      final body = StreamController<List<int>>();
      final fake = _FakeClient((_) async {
        scheduleMicrotask(() {
          body.add(
            utf8.encode(
              'data: {"type":"TEXT_MESSAGE_CONTENT","delta":"hi"}\n\n'
              'data: [DONE]\n\n',
            ),
          );
        });
        return http.StreamedResponse(body.stream, 200);
      });
      final transport = SseChatTransport(
        'https://example.test/chat',
        headers: () => const {},
        clientFactory: () => fake,
      );

      final events = await transport
          .stream({})
          .toList()
          .timeout(const Duration(seconds: 2));

      expect(events.single, {
        'type': 'TEXT_MESSAGE_CONTENT',
        'delta': 'hi',
      });
      expect(fake.closed, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(body.hasListener, isFalse);
      await body.close();
    });

    test('keeps every event across multiple RUN_FINISHED iterations until EOF',
        () async {
      final body = StreamController<List<int>>();
      final fake = _FakeClient((_) async {
        scheduleMicrotask(() {
          body.add(
            utf8.encode(
              'data: {"type":"RUN_FINISHED","finishReason":"tool_calls"}\n\n'
              'data: {"type":"TOOL_CALL_RESULT","toolCallId":"tc1",'
              '"content":"ok"}\n\n'
              'data: {"type":"TEXT_MESSAGE_START"}\n\n'
              'data: {"type":"TEXT_MESSAGE_CONTENT","delta":"Final answer"}'
              '\n\n'
              'data: {"type":"TEXT_MESSAGE_END"}\n\n'
              'data: {"type":"RUN_FINISHED","finishReason":"stop"}\n\n',
            ),
          );
          body.close();
        });
        return http.StreamedResponse(body.stream, 200);
      });
      final transport = SseChatTransport(
        'https://example.test/chat',
        headers: () => const {},
        clientFactory: () => fake,
      );

      final events = await transport
          .stream({})
          .toList()
          .timeout(const Duration(seconds: 2));

      expect(events.map((e) => e['type']).toList(), [
        'RUN_FINISHED',
        'TOOL_CALL_RESULT',
        'TEXT_MESSAGE_START',
        'TEXT_MESSAGE_CONTENT',
        'TEXT_MESSAGE_END',
        'RUN_FINISHED',
      ]);
      expect(events.first['finishReason'], 'tool_calls');
      expect(events[3]['delta'], 'Final answer');
      expect(events.last['finishReason'], 'stop');
      expect(fake.closed, isTrue);
    });

    test('cancelling closes the client and response subscription promptly',
        () async {
      final body = StreamController<List<int>>();
      var bodyCancelled = false;
      body.onCancel = () {
        bodyCancelled = true;
      };
      final fake = _FakeClient(
        (_) async => http.StreamedResponse(body.stream, 200),
      );
      final transport = SseChatTransport(
        'https://example.test/chat',
        headers: () => const {},
        clientFactory: () => fake,
      );

      final subscription = transport.stream({}).listen((_) {});
      await _waitFor(() => body.hasListener);
      final watch = Stopwatch()..start();
      await subscription.cancel().timeout(const Duration(seconds: 1));
      watch.stop();

      expect(fake.closed, isTrue);
      await _waitFor(() => bodyCancelled);
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
      await body.close();
    });

    test('idle timeout surfaces a TimeoutException and closes the client',
        () async {
      final body = StreamController<List<int>>();
      final fake = _FakeClient(
        (_) async => http.StreamedResponse(body.stream, 200),
      );
      final transport = SseChatTransport(
        'https://example.test/chat',
        headers: () => const {},
        clientFactory: () => fake,
        idleTimeout: const Duration(milliseconds: 40),
      );

      await expectLater(
        transport.stream({}),
        emitsError(isA<TimeoutException>()),
      );
      expect(fake.closed, isTrue);
      await body.close();
    });
  });
}

http.StreamedResponse _sse(
  List<List<int>> chunks, {
  int status = 200,
  String reasonPhrase = 'OK',
}) =>
    http.StreamedResponse(
      Stream<List<int>>.fromIterable(chunks),
      status,
      reasonPhrase: reasonPhrase,
    );

List<List<int>> _chunk(List<int> bytes, int size) {
  final chunks = <List<int>>[];
  for (var i = 0; i < bytes.length; i += size) {
    chunks.add(bytes.sublist(i, (i + size).clamp(0, bytes.length)));
  }
  return chunks;
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) {
      fail('Condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _FakeClient extends http.BaseClient {
  _FakeClient(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
      _handler;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _handler(request);

  @override
  void close() {
    closed = true;
  }
}
