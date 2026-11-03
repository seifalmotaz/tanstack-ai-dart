// Upstream reference: packages/ai-client/tests/chat-client-abort.test.ts
import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/connections.dart' as conn;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('ChatClient abort and stop', () {
    test('stop cancels the active stream and ignores late chunks', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('hi');
      final assistant = client.getMessages().last;
      await client.stop();

      transport.emit(<String, dynamic>{
        'type': 'TEXT_MESSAGE_CONTENT',
        'delta': 'late',
      });
      transport.emit(<String, dynamic>{
        'type': 'RUN_ERROR',
        'message': 'late error',
      });
      await transport.close();
      await pump();

      expect(client.isStreaming, isFalse);
      expect(client.getStatus(), 'ready');
      expect(client.getError(), isNull);
      expect(assistant.answer, '');
      expect(assistant.streaming, isFalse);
    });

    test('stop flushes queued messages and pending continuation work',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('first');
      await client.sendText('second');
      await client.stop();
      expect(client.getQueue(), isEmpty);
      expect(client.getResumeState(), isNull);
      expect(client.getInterrupts(), isEmpty);
    });

    test('stop leaves the subscription flag set', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('hi');
      expect(client.getIsSubscribed(), isTrue);
      await client.stop();
      expect(client.getIsSubscribed(), isTrue);
      await client.unsubscribe();
      expect(client.getIsSubscribed(), isFalse);
    });

    test(
        'a stream error then stop keeps the terminal error once, then clears on send',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('first');
      await emitAll(transport, <Map<String, dynamic>>[
        <String, dynamic>{'type': 'RUN_ERROR', 'message': 'boom'},
      ]);
      await transport.close();
      await pump();
      expect(client.getStatus(), 'error');
      expect(client.getError(), contains('boom'));
      await client.sendText('second');
      expect(client.getError(), isNull);
      await client.stop();
    });

    test('stop during an approved action marks it interrupted exactly once',
        () async {
      final part = AssistantPart.tool(
        id: 'tc1',
        name: 'write',
        approval: AssistantApproval(id: 'approval'),
      );
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        messages: <AssistantTurn>[
          AssistantTurn(
              id: 'a', role: 'assistant', parts: <AssistantPart>[part]),
        ],
      );
      await client.approve(part, true);
      await client.stop();
      final firstOutput = '${part.output}';
      await client.stop();
      expect(part.state, 'error');
      expect('${part.output}', firstOutput);
    });

    test('a throwing stream listener does not prevent stop()', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        messages: <AssistantTurn>[
          AssistantTurn(
            id: 'a',
            role: 'assistant',
            parts: <AssistantPart>[AssistantPart.text('x')],
          ),
        ],
        onChanged: () => throw StateError('listener'),
      );
      await client.sendText('hi');
      await client.stop();
      expect(client.isStreaming, isFalse);
    });

    test('should create AbortController and pass signal to adapter', () async {
      conn.CancellationSignal? seen;
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {
          seen = signal;
          yield <String, dynamic>{
            'type': 'RUN_FINISHED',
            'runId': 'r',
            'threadId': 't',
            'outcome': <String, dynamic>{'type': 'success'},
          };
        },
      );
      final client = ChatClient(connection: connection);
      await client.sendText('hi');
      expect(seen, isNotNull);
      expect(seen!.isCancelled, isFalse);
    });

    test('should preserve partial content when aborted', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('hi');
      transport.emit(<String, dynamic>{'type': 'TEXT_MESSAGE_START'});
      transport.emit(<String, dynamic>{
        'type': 'TEXT_MESSAGE_CONTENT',
        'delta': 'partial',
      });
      await pump();
      await client.stop();
      expect(client.getMessages().last.answer, 'partial');
    });

    test('should create new AbortController for each request', () async {
      final signals = <conn.CancellationSignal?>[];
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {
          signals.add(signal);
          yield <String, dynamic>{
            'type': 'RUN_FINISHED',
            'runId': 'r${signals.length}',
            'threadId': 't',
            'outcome': <String, dynamic>{'type': 'success'},
          };
        },
      );
      final client = ChatClient(connection: connection);
      await client.sendText('one');
      await pump(4);
      await client.sendText('two');
      await pump(4);
      expect(signals, hasLength(2));
      expect(identical(signals[0], signals[1]), isFalse);
    });

    test('should resolve cleanly when stop() is called during onResponse',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      final sending = client.sendText('hi');
      await client.stop();
      await sending;
      expect(client.isStreaming, isFalse);
    });

    test(
        'should resolve cleanly when reload() supersedes the stream during onResponse',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        messages: <AssistantTurn>[userMessage('u', 'hi')],
      );
      await client.sendText('next');
      await client.reload();
      expect(transport.bodies.length, greaterThanOrEqualTo(2));
      await client.stop();
    });
  });
}
