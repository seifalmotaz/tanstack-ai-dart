// Ported from
// packages/ai-client/tests/events.test.ts
import 'package:tanstack_ai_dart/platform.dart';
import 'package:test/test.dart';

void main() {
  group('events', () {
    late AiEventClient client;
    late DefaultChatClientEventEmitter emitter;

    setUp(() {
      client = AiEventClient();
      emitter = DefaultChatClientEventEmitter(
        'test-client-id',
        eventClient: client,
      );
    });

    Map<String, dynamic> expectedEnvelope(
      String eventType, [
      String visibility = 'client-state',
    ]) =>
        {
          'clientId': 'test-client-id',
          'hookId': 'test-client-id',
          'eventId': isA<String>(),
          'eventType': eventType,
          'source': 'client',
          'visibility': visibility,
          'timestamp': isA<int>(),
        };

    void expectEmit(int index, String name, Map<String, dynamic> data) {
      final event = client.events[index];
      expect(event.name, name);
      expect(event.data, data);
    }

    group('DefaultChatClientEventEmitter', () {
      test('emits client:created with client-state envelope fields', () {
        emitter.clientCreated(5);
        expectEmit(0, 'client:created', {
          'initialMessageCount': 5,
          ...expectedEnvelope('client:created'),
        });
      });

      test('emits client:loading:changed with client-state envelope fields',
          () {
        emitter.loadingChanged(true);
        expectEmit(0, 'client:loading:changed', {
          'isLoading': true,
          ...expectedEnvelope('client:loading:changed'),
        });
      });

      test('emits client:error:changed with null', () {
        emitter.errorChanged(null);
        expectEmit(0, 'client:error:changed', {
          'error': null,
          ...expectedEnvelope('client:error:changed'),
        });
      });

      test('emits client:error:changed with an error string', () {
        emitter.errorChanged('Something went wrong');
        expectEmit(0, 'client:error:changed', {
          'error': 'Something went wrong',
          ...expectedEnvelope('client:error:changed'),
        });
      });

      test(
          'emits text:chunk:content with user-visible envelope and run context',
          () {
        emitter.textUpdated(
            'stream-1',
            'msg-1',
            'Hello world',
            const ChatClientRunEventContext(
                threadId: 'thread-1', runId: 'run-1'));
        expectEmit(0, 'text:chunk:content', {
          'streamId': 'stream-1',
          'messageId': 'msg-1',
          'content': 'Hello world',
          'threadId': 'thread-1',
          'runId': 'run-1',
          ...expectedEnvelope('text:chunk:content', 'user-visible'),
        });
      });

      test(
          'emits text:chunk:thinking with user-visible envelope and run context',
          () {
        emitter.thinkingUpdated(
          'stream-1',
          'msg-1',
          'reasoning',
          'ing',
          const ChatClientRunEventContext(threadId: 'thread-1', runId: 'run-1'),
        );
        expectEmit(0, 'text:chunk:thinking', {
          'streamId': 'stream-1',
          'messageId': 'msg-1',
          'content': 'reasoning',
          'delta': 'ing',
          'threadId': 'thread-1',
          'runId': 'run-1',
          ...expectedEnvelope('text:chunk:thinking', 'user-visible'),
        });
      });

      test(
          'emits tools:call:updated with user-visible envelope and run context',
          () {
        emitter.toolCallStateChanged(
          'stream-1',
          'msg-1',
          'call-1',
          'get_weather',
          'input-complete',
          '{"city": "NYC"}',
          const ChatClientRunEventContext(threadId: 'thread-1', runId: 'run-1'),
        );
        expectEmit(0, 'tools:call:updated', {
          'streamId': 'stream-1',
          'messageId': 'msg-1',
          'toolCallId': 'call-1',
          'toolName': 'get_weather',
          'state': 'input-complete',
          'arguments': '{"city": "NYC"}',
          'threadId': 'thread-1',
          'runId': 'run-1',
          ...expectedEnvelope('tools:call:updated', 'user-visible'),
        });
      });

      test(
          'emits tools:approval:requested with user-visible envelope and run context',
          () {
        emitter.approvalRequested(
          'stream-1',
          'msg-1',
          'call-1',
          'get_weather',
          {'city': 'NYC'},
          'approval-1',
          const ChatClientRunEventContext(threadId: 'thread-1', runId: 'run-1'),
        );
        expectEmit(0, 'tools:approval:requested', {
          'streamId': 'stream-1',
          'messageId': 'msg-1',
          'toolCallId': 'call-1',
          'toolName': 'get_weather',
          'input': {'city': 'NYC'},
          'approvalId': 'approval-1',
          'threadId': 'thread-1',
          'runId': 'run-1',
          ...expectedEnvelope('tools:approval:requested', 'user-visible'),
        });
      });

      test('emits text:message:created with full content and run context', () {
        final uiMessage = <String, dynamic>{
          'id': 'msg-1',
          'role': 'user',
          'parts': [
            {'type': 'text', 'content': 'Hello'},
            {'type': 'text', 'content': 'World'},
          ],
          'createdAt': DateTime.now(),
        };
        emitter.messageAppended(
          uiMessage,
          streamId: 'stream-1',
          context: const ChatClientEventContext(
            threadId: 'thread-1',
            runId: 'run-1',
          ),
        );
        expectEmit(0, 'text:message:created', {
          'streamId': 'stream-1',
          'messageId': 'msg-1',
          'role': 'user',
          'content': 'Hello World',
          'parts': uiMessage['parts'],
          'threadId': 'thread-1',
          'runId': 'run-1',
          ...expectedEnvelope('text:message:created', 'user-visible'),
        });
      });

      test('handles a message with no text parts', () {
        final uiMessage = <String, dynamic>{
          'id': 'msg-1',
          'role': 'assistant',
          'parts': [
            {
              'type': 'tool-call',
              'id': 'call-1',
              'name': 'tool1',
              'arguments': '{}',
              'state': 'input-complete',
            },
          ],
          'createdAt': DateTime.now(),
        };
        emitter.messageAppended(uiMessage);
        expectEmit(0, 'text:message:created', {
          'messageId': 'msg-1',
          'role': 'assistant',
          'content': '',
          'parts': uiMessage['parts'],
          ...expectedEnvelope('text:message:created', 'user-visible'),
        });
      });

      test('emits text:message:created and text:message:user for sent messages',
          () {
        emitter.messageSent('msg-1', 'Hello world');
        expect(client.events, hasLength(2));
        expectEmit(0, 'text:message:created', {
          'messageId': 'msg-1',
          'role': 'user',
          'content': 'Hello world',
          ...expectedEnvelope('text:message:created', 'user-visible'),
        });
        expectEmit(1, 'text:message:user', {
          'messageId': 'msg-1',
          'role': 'user',
          'content': 'Hello world',
          ...expectedEnvelope('text:message:user', 'user-visible'),
        });
      });

      test('emits client:reloaded with client-state envelope fields', () {
        emitter.reloaded(3);
        expectEmit(0, 'client:reloaded', {
          'fromMessageIndex': 3,
          ...expectedEnvelope('client:reloaded'),
        });
      });

      test('emits client:stopped with client-state envelope fields', () {
        emitter.stopped();
        expectEmit(0, 'client:stopped', {
          ...expectedEnvelope('client:stopped'),
        });
      });

      test('emits client:messages:cleared with client-state envelope fields',
          () {
        emitter.messagesCleared();
        expectEmit(0, 'client:messages:cleared', {
          ...expectedEnvelope('client:messages:cleared'),
        });
      });

      test(
          'emits tools:result:added with user-visible envelope and run context',
          () {
        emitter.toolResultAdded(
          'call-1',
          'get_weather',
          {'temp': 72},
          'output-available',
          const ChatClientEventContext(threadId: 'thread-1', runId: 'run-1'),
        );
        expectEmit(0, 'tools:result:added', {
          'toolCallId': 'call-1',
          'toolName': 'get_weather',
          'output': {'temp': 72},
          'state': 'output-available',
          'threadId': 'thread-1',
          'runId': 'run-1',
          ...expectedEnvelope('tools:result:added', 'user-visible'),
        });
      });

      test(
          'emits tools:approval:responded with user-visible envelope and run context',
          () {
        emitter.toolApprovalResponded(
          'approval-1',
          'call-1',
          true,
          const ChatClientRunEventContext(threadId: 'thread-1', runId: 'run-1'),
        );
        expectEmit(0, 'tools:approval:responded', {
          'approvalId': 'approval-1',
          'toolCallId': 'call-1',
          'approved': true,
          'threadId': 'thread-1',
          'runId': 'run-1',
          ...expectedEnvelope('tools:approval:responded', 'user-visible'),
        });
      });

      test('emits devtools:tool-fixture:applied with a user-visible envelope',
          () {
        emitter.toolFixtureApplied(const ChatClientToolFixtureAppliedEvent(
          hookId: 'test-client-id',
          threadId: 'thread-1',
          runId: 'run-1',
          toolName: 'get_weather',
          input: {'city': 'NYC'},
          output: {'temp': 72},
          messageId: 'msg-fixture',
          toolCallId: 'call-fixture',
        ));
        expectEmit(0, 'devtools:tool-fixture:applied', {
          'threadId': 'thread-1',
          'runId': 'run-1',
          'toolName': 'get_weather',
          'input': {'city': 'NYC'},
          'output': {'temp': 72},
          'messageId': 'msg-fixture',
          'toolCallId': 'call-fixture',
          ...expectedEnvelope(
            'devtools:tool-fixture:applied',
            'user-visible',
          ),
        });
      });
    });
  });
}
