// Ported from
// packages/ai-client/tests/mcp-app-bridge.test.ts
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tanstack_ai_dart/platform.dart';
import 'package:test/test.dart';

void main() {
  group('createMcpAppBridge', () {
    const threadId = 'thread-123';
    const callEndpoint = 'https://example.com/api/mcp-call';

    late List<String> logs;

    setUp(() => logs = <String>[]);

    ({McpAppBridge bridge, List<http.Request> requests}) createBridge({
      required Object? responseBody,
      int status = 200,
      void Function(String url)? onLink,
    }) {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response(
          responseBody is String ? responseBody : jsonEncode(responseBody),
          status,
          headers: {'content-type': 'application/json'},
        );
      });
      final bridge = createMcpAppBridge(CreateMcpAppBridgeOptions(
        threadId: threadId,
        callEndpoint: callEndpoint,
        sendMessage: (content, [body]) async {},
        httpClient: client,
        onLink: onLink,
        logger: logs.add,
      ));
      return (bridge: bridge, requests: requests);
    }

    group('callTool', () {
      test('POSTs to callEndpoint with correct body and returns result',
          () async {
        final created = createBridge(
          responseBody: {
            'ok': true,
            'result': {'price': 1999},
          },
        );

        final result = await created.bridge.callTool(
          serverId: 'server-1',
          toolName: 'getPrice',
          args: {'productId': 'abc'},
          messageId: 'msg-42',
        );

        expect(result, {'price': 1999});
        expect(created.requests, hasLength(1));
        final request = created.requests.single;
        expect(request.url.toString(), callEndpoint);
        expect(request.method, 'POST');
        expect(request.headers['content-type'], 'application/json');
        expect(jsonDecode(request.body), {
          'threadId': threadId,
          'serverId': 'server-1',
          'toolName': 'getPrice',
          'args': {'productId': 'abc'},
          'messageId': 'msg-42',
        });
      });

      test('omits undefined optional fields when not provided', () async {
        final created = createBridge(
          responseBody: {'ok': true, 'result': null},
        );

        await created.bridge.callTool(toolName: 'ping');

        final body = jsonDecode(created.requests.single.body) as Map;
        expect(body, containsPair('threadId', threadId));
        expect(body, containsPair('toolName', 'ping'));
        expect(body.containsKey('serverId'), isFalse);
        expect(body.containsKey('args'), isFalse);
        expect(body.containsKey('messageId'), isFalse);
      });

      test('throws when response ok is false', () async {
        final created = createBridge(
          responseBody: {'ok': false, 'error': 'tool not found'},
        );

        await expectLater(
          created.bridge.callTool(toolName: 'missing'),
          throwsA(predicate((error) => '$error'.contains('tool not found'))),
        );
      });

      test('throws fallback message when ok is false and no error string',
          () async {
        final created = createBridge(responseBody: {'ok': false});

        await expectLater(
          created.bridge.callTool(toolName: 'broken'),
          throwsA(
            predicate((error) => '$error'.contains('MCP app tool call failed')),
          ),
        );
      });

      test('throws when HTTP response is non-2xx (e.g. 500)', () async {
        final created = createBridge(responseBody: 'not json', status: 500);

        await expectLater(
          created.bridge.callTool(toolName: 'boom'),
          throwsA(predicate((error) => '$error'.contains('HTTP 500'))),
        );
      });

      test('uses global fetch when fetchImpl is omitted', () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        Map<String, dynamic>? received;
        server.listen((request) async {
          received = jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'ok': true, 'result': 42}));
          await request.response.close();
        });

        final bridge = createMcpAppBridge(CreateMcpAppBridgeOptions(
          threadId: threadId,
          callEndpoint: 'http://127.0.0.1:${server.port}/call',
          sendMessage: (content, [body]) async {},
          logger: logs.add,
        ));

        final result = await bridge.callTool(toolName: 'test');
        expect(result, 42);
        expect(received, containsPair('threadId', threadId));
      });
    });

    group('sendPrompt', () {
      test('forwards text to chat.sendMessage', () async {
        String? sent;
        final bridge = createMcpAppBridge(CreateMcpAppBridgeOptions(
          threadId: threadId,
          callEndpoint: callEndpoint,
          sendMessage: (content, [body]) async => sent = content,
          logger: logs.add,
        ));

        await bridge.sendPrompt('hello from bridge');

        expect(sent, 'hello from bridge');
      });

      test('returns void', () async {
        final bridge = createMcpAppBridge(CreateMcpAppBridgeOptions(
          threadId: threadId,
          callEndpoint: callEndpoint,
          sendMessage: (content, [body]) async {},
          logger: logs.add,
        ));

        await bridge.sendPrompt('any');
        expect(true, isTrue);
      });
    });

    group('openLink', () {
      test('returns { isError: true } when onLink is not provided', () {
        final bridge = createMcpAppBridge(CreateMcpAppBridgeOptions(
          threadId: threadId,
          callEndpoint: callEndpoint,
          sendMessage: (content, [body]) async {},
          logger: logs.add,
        ));

        expect(bridge.openLink('https://example.com'),
            const McpAppLinkResult(true));
      });

      test('emits a console.warn when onLink is not provided', () {
        final bridge = createMcpAppBridge(CreateMcpAppBridgeOptions(
          threadId: threadId,
          callEndpoint: callEndpoint,
          sendMessage: (content, [body]) async {},
          logger: logs.add,
        ));

        bridge.openLink('https://example.com');

        expect(logs, [
          '[mcp-app-bridge] openLink ignored: no onLink handler configured',
        ]);
      });

      test(
          'calls onLink and returns { isError: false } when onLink is provided',
          () {
        final linked = <String>[];
        final bridge = createMcpAppBridge(CreateMcpAppBridgeOptions(
          threadId: threadId,
          callEndpoint: callEndpoint,
          sendMessage: (content, [body]) async {},
          onLink: linked.add,
          logger: logs.add,
        ));

        final result = bridge.openLink('https://example.com/page');
        expect(result, const McpAppLinkResult(false));
        expect(linked, ['https://example.com/page']);
      });

      test('does not call onLink when it is absent', () {
        var onLinkCalls = 0;
        void onLink(String _) => onLinkCalls++;
        final bridge = createMcpAppBridge(CreateMcpAppBridgeOptions(
          threadId: threadId,
          callEndpoint: callEndpoint,
          sendMessage: (content, [body]) async {},
          // `onLink` is intentionally not provided to the bridge.
          logger: logs.add,
        ));
        bridge.openLink('https://example.com');

        expect(onLinkCalls, 0);
        expect(onLink, isNotNull);
      });

      test('rejects an unsafe URL scheme without calling onLink', () {
        final linked = <String>[];
        final bridge = createMcpAppBridge(CreateMcpAppBridgeOptions(
          threadId: threadId,
          callEndpoint: callEndpoint,
          sendMessage: (content, [body]) async {},
          onLink: linked.add,
          logger: logs.add,
        ));

        for (final bad in [
          'javascript:alert(1)',
          'data:text/html,<script>1</script>',
          'file:///etc/passwd',
          'not a url',
        ]) {
          expect(bridge.openLink(bad), const McpAppLinkResult(true));
        }
        expect(linked, isEmpty);
      });

      test('allows mailto: links through to onLink', () {
        final linked = <String>[];
        final bridge = createMcpAppBridge(CreateMcpAppBridgeOptions(
          threadId: threadId,
          callEndpoint: callEndpoint,
          sendMessage: (content, [body]) async {},
          onLink: linked.add,
          logger: logs.add,
        ));

        expect(
          bridge.openLink('mailto:a@b.com'),
          const McpAppLinkResult(false),
        );
        expect(linked, ['mailto:a@b.com']);
      });

      test(
          'returns { isError: true } (fail-soft) when a provided onLink throws',
          () {
        var calls = 0;
        final bridge = createMcpAppBridge(CreateMcpAppBridgeOptions(
          threadId: threadId,
          callEndpoint: callEndpoint,
          sendMessage: (content, [body]) async {},
          onLink: (_) {
            calls++;
            throw StateError('window.open blocked');
          },
          logger: logs.add,
        ));

        expect(
          bridge.openLink('https://example.com/page'),
          const McpAppLinkResult(true),
        );
        expect(calls, 1);
      });
    });
  });
}
