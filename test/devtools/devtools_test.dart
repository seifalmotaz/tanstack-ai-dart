import 'package:tanstack_ai_dart/devtools.dart';
import 'package:tanstack_ai_dart/platform.dart';
import 'package:test/test.dart';

import 'support.dart';

Map<String, dynamic> toolFixture({
  String? hookId = 'thread-1',
  String? threadId = 'thread-1',
  String? runId = 'run-fixture',
  String toolName = 'weather',
  Object? input = const <String, Object?>{'city': 'Paris'},
  Object? output = const <String, Object?>{'temperature': 21},
  String? toolCallId = 'fixture-call',
  String? messageId = 'fixture-message',
  bool? execute,
  Map<String, dynamic>? message,
  String? errorText,
}) =>
    <String, dynamic>{
      if (hookId != null) 'hookId': hookId,
      if (threadId != null) 'threadId': threadId,
      if (runId != null) 'runId': runId,
      'toolName': toolName,
      'input': input,
      'output': output,
      if (execute != null) 'execute': execute,
      if (message != null) 'message': message,
      if (toolCallId != null) 'toolCallId': toolCallId,
      if (messageId != null) 'messageId': messageId,
      if (errorText != null) 'errorText': errorText,
    };

void mountForFixtures(ChatHarness harness) {
  harness.bridge.emitRegistered();
  harness.eventClient.clear();
}

void main() {
  group('ChatClient devtools bridge', () {
    test('does not emit hook lifecycle events before devtools is mounted', () {
      final harness = ChatHarness();

      expect(harness.eventClient.emitted('hook:registered'), isEmpty);
      expect(harness.eventClient.emitted('hook:state-snapshot'), isEmpty);

      harness.bridge.dispose();

      expect(harness.eventClient.emitted('hook:unregistered'), isEmpty);
    });

    test('registers a generated hookId when construct had no threadId', () {
      final harness = ChatHarness(
        hookId: 'thread-generated-1',
        threadId: 'thread-generated-1',
        displayName: 'Skills',
      );

      harness.bridge.mountWithTools(0);

      final registered =
          harness.eventClient.emitted('hook:registered').single.payload;
      expect(registered['hookId'], startsWith('thread-'));
      expect(registered['displayName'], 'Skills');
      expect(registered['lifecycle'], 'mounted');

      final created =
          harness.eventClient.emitted('client:created').single.payload;
      expect(created['clientId'], startsWith('thread-'));
      expect(created['hookId'], startsWith('thread-'));

      harness.bridge.dispose();
    });

    test('can register again after a mount cleanup cycle', () {
      final harness = ChatHarness();

      harness.bridge.emitRegistered();
      harness.bridge.dispose();
      harness.eventClient.clear();

      harness.bridge.emitRegistered();

      final registered =
          harness.eventClient.emitted('hook:registered').single.payload;
      expect(registered['hookId'], 'thread-1');
      expect(registered['lifecycle'], 'mounted');

      harness.bridge.dispose();
    });

    test('binds hook identity to threadId', () {
      final harness = ChatHarness(
        hookId: 'support-42',
        threadId: 'support-42',
      );

      harness.bridge.emitRegistered();

      final payload =
          harness.eventClient.emitted('hook:registered').single.payload;
      expect(payload['hookId'], 'support-42');
      expect(payload['clientId'], 'support-42');
      expect(payload['threadId'], 'support-42');
      expect(payload.containsKey('correlationId'), isFalse);

      harness.bridge.dispose();
    });

    test('does not unregister a superseded client that shares a threadId', () {
      final eventClient = InMemoryAIDevtoolsEventClient();
      final first = ChatHarness(
        hookId: 'support-42',
        threadId: 'support-42',
        eventClient: eventClient,
      );
      final second = ChatHarness(
        hookId: 'support-42',
        threadId: 'support-42',
        eventClient: eventClient,
      );

      first.bridge.emitRegistered();
      second.bridge.emitRegistered();
      eventClient.clear();

      first.bridge.dispose();
      expect(eventClient.emitted('hook:unregistered'), isEmpty);

      second.bridge.dispose();
      final unregistered =
          eventClient.emitted('hook:unregistered').single.payload;
      expect(unregistered['hookId'], 'support-42');
      expect(unregistered['threadId'], 'support-42');
    });

    test('registers the chat hook and emits the initial state snapshot', () {
      final harness = ChatHarness();

      harness.bridge.mountWithTools(0);

      final registered =
          harness.eventClient.emitted('hook:registered').single.payload;
      expect(registered['eventId'], isA<String>());
      expect(registered['eventType'], 'hook:registered');
      expect(registered['timestamp'], isA<num>());
      expect(registered['source'], 'client');
      expect(registered['visibility'], 'client-state');
      expect(registered['hookId'], 'thread-1');
      expect(registered['clientId'], 'thread-1');
      expect(registered['threadId'], 'thread-1');
      expect(registered['hookName'], 'useChat');
      expect(registered['framework'], 'react');
      expect(registered['outputKind'], 'chat');
      expect(registered['lifecycle'], 'mounted');

      final snapshots = harness.eventClient.emitted('hook:state-snapshot');
      expect(snapshots, isNotEmpty);
      final snapshot = snapshots.last.payload;
      expect(snapshot['eventId'], isA<String>());
      expect(snapshot['eventType'], 'hook:state-snapshot');
      expect(snapshot['source'], 'client');
      expect(snapshot['visibility'], 'client-state');
      expect(snapshot['hookId'], 'thread-1');
      expect(snapshot['clientId'], 'thread-1');
      expect(snapshot['threadId'], 'thread-1');
      expect(snapshot['hookName'], 'useChat');
      expect(snapshot['framework'], 'react');
      expect(snapshot['outputKind'], 'chat');
      final state = snapshot['state'] as Map;
      expect(state['messages'], isEmpty);
      expect(state['status'], 'ready');
      expect(state['isLoading'], isFalse);
      expect(state['activeRunIds'], isEmpty);

      harness.bridge.dispose();
    });

    test('emits the configured devtools display name', () {
      final harness = ChatHarness(displayName: 'Recipe Assistant');

      harness.bridge.mountWithTools(0);

      expect(
        harness.eventClient.emitted('hook:registered').single.payload,
        containsPair('displayName', 'Recipe Assistant'),
      );
      expect(
        harness.eventClient.emitted('hook:state-snapshot').last.payload,
        containsPair('displayName', 'Recipe Assistant'),
      );

      harness.bridge.dispose();
    });

    test('registers client tool metadata for devtools discovery', () {
      final harness = ChatHarness(
        tools: <AIDevtoolsTool>[
          AIDevtoolsTool(
            name: 'weather',
            description: 'Lookup weather',
            needsApproval: true,
            metadata: const <String, Object?>{'fixture': true},
            inputSchema: const <String, Object?>{'type': 'object'},
            outputSchema: const <String, Object?>{'type': 'object'},
          ),
        ],
      );

      harness.bridge.mountWithTools(0);

      final payload =
          harness.eventClient.emitted('tools:registered').single.payload;
      expect(payload['hookId'], 'thread-1');
      expect(payload['hookName'], 'useChat');
      expect(payload['framework'], 'react');
      expect(payload['outputKind'], 'chat');
      final tools = payload['tools'] as List;
      expect(tools, hasLength(1));
      expect(
        tools.single,
        containsPair('name', 'weather'),
      );
      expect(
        tools.single,
        containsPair('description', 'Lookup weather'),
      );
      expect(
        (tools.single as Map)['inputSchema'],
        containsPair('type', 'object'),
      );
      expect(
        (tools.single as Map)['outputSchema'],
        containsPair('type', 'object'),
      );
      expect((tools.single as Map)['needsApproval'], isTrue);
      expect((tools.single as Map)['metadata'], {'fixture': true});

      harness.bridge.dispose();
    });

    test('responds to devtools state requests for its hook', () {
      final harness = ChatHarness();
      harness.bridge.mountWithTools(0);
      harness.eventClient.clear();

      harness.eventClient.dispatch('devtools:request-state', {
        'targetHookId': 'thread-1',
      });

      final registered =
          harness.eventClient.emitted('hook:registered').single.payload;
      expect(registered['hookId'], 'thread-1');
      expect(registered['clientId'], 'thread-1');
      expect(registered['threadId'], 'thread-1');
      expect(registered['hookName'], 'useChat');
      expect(registered['outputKind'], 'chat');

      final tools =
          harness.eventClient.emitted('tools:registered').single.payload;
      expect(tools['hookId'], 'thread-1');
      expect(tools['tools'], isEmpty);

      final snapshot =
          harness.eventClient.emitted('hook:state-snapshot').single.payload;
      expect(snapshot['hookId'], 'thread-1');
      expect(snapshot['clientId'], 'thread-1');
      expect(snapshot['threadId'], 'thread-1');
      final state = snapshot['state'] as Map;
      expect(state['messages'], isEmpty);
      expect(state['status'], 'ready');
      expect(state['isLoading'], isFalse);
      expect(state['activeRunIds'], isEmpty);

      harness.bridge.dispose();
    });

    test('uses the resilient devtools emitter for hook registration sync', () {
      final harness = ChatHarness();
      harness.bridge.mountWithTools(0);

      expect(
        harness.eventClient.emitted('hook:registered').last.payload,
        containsPair('lifecycle', 'mounted'),
      );

      harness.eventClient.clear();
      harness.eventClient.dispatch('devtools:request-state', {
        'targetHookId': 'thread-1',
      });

      expect(
        harness.eventClient.emitted('hook:registered').single.payload,
        containsPair('lifecycle', 'mounted'),
      );
      final snapshot =
          harness.eventClient.emitted('hook:state-snapshot').single.payload;
      expect((snapshot['state'] as Map)['messages'], isEmpty);

      harness.bridge.dispose();
    });

    test('does not respond to devtools state requests for another hook', () {
      final harness = ChatHarness();
      harness.bridge.mountWithTools(0);
      harness.eventClient.clear();

      harness.eventClient.dispatch('devtools:request-state', {
        'targetHookId': 'other-hook',
      });

      expect(harness.eventClient.emitted('hook:registered'), isEmpty);
      expect(harness.eventClient.emitted('hook:state-snapshot'), isEmpty);

      harness.bridge.dispose();
    });

    test('applies a devtools tool fixture as a normal assistant message',
        () async {
      final harness = ChatHarness();
      mountForFixtures(harness);

      final fixture = toolFixture();
      harness.eventClient.dispatch('devtools:tool-fixture:apply', fixture);

      await waitFor(() => harness.messages.length == 1);
      final message = harness.messages.single;
      expect(message['id'], 'fixture-message');
      expect(message['role'], 'assistant');
      expect(message['createdAt'], isA<String>());
      final parts = message['parts'] as List;
      expect(parts, hasLength(2));
      expect(parts[0], {
        'type': 'tool-call',
        'id': 'fixture-call',
        'name': 'weather',
        'arguments': '{"city":"Paris"}',
        'input': {'city': 'Paris'},
        'state': 'input-complete',
        'output': {'temperature': 21},
      });
      expect(parts[1], {
        'type': 'tool-result',
        'toolCallId': 'fixture-call',
        'content': '{"temperature":21}',
        'state': 'complete',
      });

      final applied = harness.eventClient
          .emitted('devtools:tool-fixture:applied')
          .single
          .payload;
      expect(applied['hookId'], 'thread-1');
      expect(applied['threadId'], 'thread-1');
      expect(applied['runId'], 'run-fixture');
      expect(applied['toolName'], fixture['toolName']);
      expect(applied['input'], fixture['input']);
      expect(applied['output'], fixture['output']);
      expect(applied['messageId'], 'fixture-message');
      expect(applied['toolCallId'], 'fixture-call');
      expect(applied['visibility'], 'user-visible');

      final created =
          harness.eventClient.emitted('text:message:created').single.payload;
      expect(created['hookId'], 'thread-1');
      expect(created['threadId'], 'thread-1');
      expect(created['runId'], 'run-fixture');
      expect(created['toolCallId'], 'fixture-call');
      expect(created['messageId'], 'fixture-message');
      expect(created['role'], 'assistant');
      expect(created['parts'], parts);
      expect(created['visibility'], 'user-visible');

      final state = latestState(harness.eventClient);
      expect(state['messages'], harness.messages);

      harness.bridge.dispose();
    });

    test(
        'generates fresh ids when replaying a fixture from an existing tool call',
        () async {
      final existingMessage = <String, dynamic>{
        'id': 'fixture-message',
        'role': 'assistant',
        'parts': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'tool-call',
            'id': 'fixture-call',
            'name': 'weather',
            'arguments': '{"city":"Paris"}',
            'input': {'city': 'Paris'},
            'state': 'input-complete',
            'output': {'temperature': 21},
          },
          <String, dynamic>{
            'type': 'tool-result',
            'toolCallId': 'fixture-call',
            'content': '{"temperature":21}',
            'state': 'complete',
          },
        ],
      };
      final harness = ChatHarness(initialMessages: [existingMessage]);
      mountForFixtures(harness);

      harness.eventClient
          .dispatch('devtools:tool-fixture:apply', toolFixture());

      await waitFor(() => harness.messages.length == 2);
      final replayed = harness.messages[1];
      final parts = replayed['parts'] as List;
      final toolCall = parts[0] as Map;
      final toolResult = parts[1] as Map;

      expect(replayed['id'], isNot('fixture-message'));
      expect(toolCall['type'], 'tool-call');
      expect(toolCall['name'], 'weather');
      expect(toolCall['input'], {'city': 'Paris'});
      expect(toolCall['id'], isNot('fixture-call'));
      expect(toolResult['type'], 'tool-result');
      expect(toolResult['toolCallId'], toolCall['id']);

      final created =
          harness.eventClient.emitted('text:message:created').single.payload;
      expect(created['messageId'], replayed['id']);
      expect(created['toolCallId'], toolCall['id']);

      harness.bridge.dispose();
    });

    test('replays the full source message when a fixture includes one',
        () async {
      final existingMessage = <String, dynamic>{
        'id': 'source-message',
        'role': 'assistant',
        'parts': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'thinking',
            'content': 'Need to inspect the catalog.',
          },
          <String, dynamic>{
            'type': 'tool-call',
            'id': 'source-tool-call',
            'name': 'weather',
            'arguments': '{"city":"Paris"}',
            'input': {'city': 'Paris'},
            'state': 'input-complete',
          },
          <String, dynamic>{
            'type': 'tool-result',
            'toolCallId': 'source-tool-call',
            'content': '{"temperature":21}',
            'state': 'complete',
          },
          <String, dynamic>{
            'type': 'text',
            'content': 'Paris is mild today.',
          },
        ],
      };
      final harness = ChatHarness(initialMessages: [existingMessage]);
      mountForFixtures(harness);

      harness.eventClient.dispatch(
        'devtools:tool-fixture:apply',
        toolFixture(
          messageId: 'source-message',
          toolCallId: 'source-tool-call',
          message: <String, dynamic>{
            'id': 'source-message',
            'role': 'assistant',
            'parts': existingMessage['parts'],
          },
        ),
      );

      await waitFor(() => harness.messages.length == 2);
      final replayed = harness.messages[1];
      final parts = replayed['parts'] as List;
      final toolCall = parts[1] as Map;
      final toolResult = parts[2] as Map;

      expect(replayed['id'], isNot('source-message'));
      expect(replayed['role'], 'assistant');
      expect(parts[0], {
        'type': 'thinking',
        'content': 'Need to inspect the catalog.',
      });
      expect(toolCall['type'], 'tool-call');
      expect(toolCall['id'], isNot('source-tool-call'));
      expect(toolCall['name'], 'weather');
      expect(toolCall['input'], {'city': 'Paris'});
      expect(toolCall['output'], {'temperature': 21});
      expect(toolResult['type'], 'tool-result');
      expect(toolResult['toolCallId'], toolCall['id']);
      expect(toolResult['content'], '{"temperature":21}');
      expect(parts[3], {
        'type': 'text',
        'content': 'Paris is mild today.',
      });

      final created =
          harness.eventClient.emitted('text:message:created').single.payload;
      expect(created['messageId'], replayed['id']);
      expect(created['toolCallId'], toolCall['id']);
      expect(created['parts'], replayed['parts']);

      harness.bridge.dispose();
    });

    test('executes the registered client tool when firing a fixture', () async {
      Object? receivedInput;
      final harness = ChatHarness(
        tools: <AIDevtoolsTool>[
          AIDevtoolsTool(
            name: 'weather',
            description: 'Get the weather for a city',
            inputSchema: const <String, Object?>{'type': 'object'},
            execute: (input) {
              receivedInput = input;
              final city = (input as Map)['city'];
              return <String, Object?>{'city': city, 'temperature': 23};
            },
          ),
        ],
      );
      mountForFixtures(harness);

      harness.eventClient.dispatch(
        'devtools:tool-fixture:apply',
        toolFixture(
          input: const <String, Object?>{'city': 'Berlin'},
          output: null,
          execute: true,
        ),
      );

      await waitFor(() {
        final parts = harness.messages.first['parts'];
        if (parts is! List) return false;
        return parts.any(
          (part) =>
              part is Map &&
              part['type'] == 'tool-call' &&
              part['name'] == 'weather' &&
              part['output'] != null,
        );
      });

      final message = harness.messages.first;
      final parts = message['parts'] as List;
      final toolCall = parts.firstWhere(
        (part) => part is Map && part['type'] == 'tool-call',
      ) as Map;
      final toolResult = parts.firstWhere(
        (part) => part is Map && part['type'] == 'tool-result',
      ) as Map;

      expect(receivedInput, {'city': 'Berlin'});
      expect(toolCall['type'], 'tool-call');
      expect(toolCall['name'], 'weather');
      expect(toolCall['input'], {'city': 'Berlin'});
      expect(toolCall['output'], {'city': 'Berlin', 'temperature': 23});
      expect(toolResult['type'], 'tool-result');
      expect(toolResult['content'], '{"city":"Berlin","temperature":23}');

      harness.bridge.dispose();
    });

    test('routes hook-scoped fixture events to the latest bridge for a hook id',
        () async {
      final eventClient = InMemoryAIDevtoolsEventClient();
      final staleClient = ChatHarness(
        hookId: 'shared-thread',
        threadId: 'shared-thread',
        eventClient: eventClient,
      );
      final activeClient = ChatHarness(
        hookId: 'shared-thread',
        threadId: 'shared-thread',
        eventClient: eventClient,
      );
      staleClient.bridge.emitRegistered();
      activeClient.bridge.emitRegistered();
      eventClient.clear();

      eventClient.dispatch(
        'devtools:tool-fixture:apply',
        toolFixture(
          hookId: 'shared-thread',
          threadId: 'shared-thread',
          runId: null,
        ),
      );

      await waitFor(() => activeClient.messages.length == 1);

      expect(staleClient.messages, isEmpty);
      expect(activeClient.messages, hasLength(1));
      expect((activeClient.messages.single['parts'] as List)[0],
          containsPair('name', 'weather'));

      staleClient.bridge.dispose();
      activeClient.bridge.dispose();
    });

    test('keeps superseded duplicate hook bridges silent when they emit later',
        () {
      final eventClient = InMemoryAIDevtoolsEventClient();
      final firstClient = ChatHarness(
        hookId: 'shared-thread',
        threadId: 'shared-thread',
        eventClient: eventClient,
      );
      final duplicateClient = ChatHarness(
        hookId: 'shared-thread',
        threadId: 'shared-thread',
        eventClient: eventClient,
      );
      firstClient.bridge.emitRegistered();
      duplicateClient.bridge.emitRegistered();
      eventClient.clear();

      firstClient.bridge.emitSnapshot();
      expect(eventClient.emitted('hook:state-snapshot'), isEmpty);

      firstClient.bridge.dispose();
      expect(eventClient.emitted('hook:unregistered'), isEmpty);

      duplicateClient.bridge.dispose();
      final unregistered =
          eventClient.emitted('hook:unregistered').single.payload;
      expect(unregistered['hookId'], 'shared-thread');
      expect(unregistered['threadId'], 'shared-thread');
    });

    test(
        'includes thread and tool call context when applying a fixture without a run id',
        () async {
      final harness = ChatHarness();
      mountForFixtures(harness);

      harness.eventClient.dispatch(
        'devtools:tool-fixture:apply',
        toolFixture(
          runId: null,
          toolCallId: 'thread-only-call',
          messageId: 'thread-only-message',
          toolName: 'weather',
          input: const <String, Object?>{'city': 'Rome'},
          output: const <String, Object?>{'temperature': 24},
        ),
      );

      await waitFor(() => harness.messages.length == 1);

      final created =
          harness.eventClient.emitted('text:message:created').single.payload;
      expect(created['threadId'], 'thread-1');
      expect(created['toolCallId'], 'thread-only-call');
      expect(created['messageId'], 'thread-only-message');
      expect(created['visibility'], 'user-visible');

      harness.bridge.dispose();
    });

    test(
        'marks fixture tool results as errored when devtools provides error text',
        () async {
      final harness = ChatHarness();
      mountForFixtures(harness);

      harness.eventClient.dispatch(
        'devtools:tool-fixture:apply',
        toolFixture(output: null, errorText: 'Tool failed'),
      );

      await waitFor(() => harness.messages.length == 1);

      final parts = harness.messages.single['parts'] as List;
      expect(parts[0], containsPair('type', 'tool-call'));
      expect(parts[0], containsPair('output', null));
      expect(parts[1], {
        'type': 'tool-result',
        'toolCallId': 'fixture-call',
        'content': 'null',
        'state': 'error',
        'error': 'Tool failed',
      });

      expect(
        harness.eventClient
            .emitted('devtools:tool-fixture:applied')
            .single
            .payload,
        containsPair('errorText', 'Tool failed'),
      );

      harness.bridge.dispose();
    });

    test('ignores devtools tool fixtures for another thread', () async {
      final harness = ChatHarness();
      mountForFixtures(harness);

      harness.eventClient.dispatch(
        'devtools:tool-fixture:apply',
        toolFixture(hookId: null, threadId: 'other-thread'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(harness.messages, isEmpty);
      expect(
        harness.eventClient.emitted('devtools:tool-fixture:applied'),
        isEmpty,
      );

      harness.bridge.dispose();
    });

    test('ignores unscoped devtools tool fixtures', () async {
      final harness = ChatHarness();
      mountForFixtures(harness);

      harness.eventClient.dispatch(
        'devtools:tool-fixture:apply',
        toolFixture(hookId: null, threadId: null),
      );
      await Future<void>.delayed(Duration.zero);

      expect(harness.messages, isEmpty);
      expect(
        harness.eventClient.emitted('devtools:tool-fixture:applied'),
        isEmpty,
      );

      harness.bridge.dispose();
    });

    test('ignores devtools tool fixtures for another hook', () async {
      final harness = ChatHarness();
      mountForFixtures(harness);

      harness.eventClient.dispatch(
        'devtools:tool-fixture:apply',
        toolFixture(hookId: 'other-hook'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(harness.messages, isEmpty);
      expect(
        harness.eventClient.emitted('devtools:tool-fixture:applied'),
        isEmpty,
      );

      harness.bridge.dispose();
    });

    test('disposes the hook bridge idempotently', () {
      final harness = ChatHarness();
      harness.bridge.mountWithTools(0);
      harness.eventClient.clear();

      harness.bridge.dispose();
      harness.bridge.dispose();

      expect(harness.eventClient.emitted('hook:unregistered'), hasLength(1));
      expect(harness.eventClient.unsubscribeCalls, 2);
    });

    test('emits a snapshot when messages are set manually', () {
      final harness = ChatHarness();
      harness.bridge.mountWithTools(0);
      harness.eventClient.clear();

      const userMessage = <String, dynamic>{
        'id': 'msg-user',
        'role': 'user',
        'parts': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'content': 'Hello'},
        ],
      };
      harness.messages.add(userMessage);
      harness.bridge.emitSnapshot();

      final state = latestState(harness.eventClient);
      expect(state['messages'], [userMessage]);

      harness.bridge.dispose();
    });

    test('emits a snapshot when messages are cleared', () {
      final harness = ChatHarness();
      harness.bridge.mountWithTools(0);
      harness.messages.add(<String, dynamic>{
        'id': 'msg-user',
        'role': 'user',
        'parts': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'content': 'Hello'},
        ],
      });
      harness.eventClient.clear();

      harness.messages.clear();
      harness.bridge.emitSnapshot();

      expect(latestState(harness.eventClient)['messages'], isEmpty);

      harness.bridge.dispose();
    });

    test('emits chat run lifecycle events for hook run tracking', () {
      final harness = ChatHarness();
      harness.bridge.mountWithTools(0);
      harness.eventClient.clear();

      harness.bridge.beginRun('run-1', 'thread-1');
      harness.bridge.emitRunLifecycle(
        AIDevtoolsRunEventType.created,
        'run-1',
        AIDevtoolsRunStatus.created,
      );
      harness.bridge.emitRunLifecycle(
        AIDevtoolsRunEventType.started,
        'run-1',
        AIDevtoolsRunStatus.started,
      );
      harness.bridge.emitRunLifecycle(
        AIDevtoolsRunEventType.completed,
        'run-1',
        AIDevtoolsRunStatus.completed,
      );

      expect(
        harness.eventClient.emitted('run:created').single.payload,
        containsPair('runId', 'run-1'),
      );
      expect(
        harness.eventClient.emitted('run:started').single.payload,
        containsPair('status', 'started'),
      );
      expect(
        harness.eventClient.emitted('run:completed').single.payload,
        containsPair('status', 'completed'),
      );
      for (final name in <String>[
        'run:created',
        'run:started',
        'run:completed',
      ]) {
        final payload = harness.eventClient.emitted(name).single.payload;
        expect(payload['hookId'], 'thread-1');
        expect(payload['threadId'], 'thread-1');
        expect(payload['runId'], 'run-1');
      }

      harness.bridge.dispose();
    });

    test('links streamed text and tool events to the current run context', () {
      final harness = ChatHarness();
      harness.bridge.mountWithTools(0);
      harness.eventClient.clear();

      harness.bridge.beginRun('run-1', 'thread-1');
      harness.bridge.events.textUpdated('stream-1', 'msg-text', 'h');
      harness.bridge.events.toolCallStateChanged(
        'stream-1',
        'msg-tool',
        'call-1',
        'weather',
        'input-complete',
        '{"city":"Paris"}',
      );

      final text =
          harness.eventClient.emitted('text:chunk:content').single.payload;
      expect(text['threadId'], 'thread-1');
      expect(text['runId'], 'run-1');

      final tool =
          harness.eventClient.emitted('tools:call:updated').single.payload;
      expect(tool['threadId'], 'thread-1');
      expect(tool['runId'], 'run-1');
      expect(tool['toolCallId'], 'call-1');

      harness.bridge.dispose();
    });

    test('uses stream lifecycle run ids when the server emits them', () {
      final harness = ChatHarness();
      harness.bridge.mountWithTools(0);
      harness.eventClient.clear();

      harness.bridge.beginRun('client-run', 'thread-1');
      harness.bridge.observeChunk(<String, dynamic>{
        'type': 'RUN_STARTED',
        'threadId': 'server-thread',
        'runId': 'server-run',
      });
      harness.bridge.events.textUpdated('stream', 'msg-server', 's');

      final text =
          harness.eventClient.emitted('text:chunk:content').single.payload;
      expect(text['threadId'], 'server-thread');
      expect(text['runId'], 'server-run');
      expect(text['messageId'], 'msg-server');

      harness.bridge.observeChunk(<String, dynamic>{
        'type': 'RUN_FINISHED',
        'runId': 'server-run',
      });
      expect(harness.bridge.getCurrentRunEventContext(), isNull);

      harness.bridge.dispose();
    });

    test(
        'emits structured output updates and snapshots streamed structured parts',
        () {
      final finalObject = <String, Object?>{'title': 'Pasta', 'servings': 2};
      final harness = ChatHarness(
        initialMessages: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'msg-structured',
            'role': 'assistant',
            'parts': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'structured-output',
                'status': 'complete',
                'raw': '{"title":"Pasta","servings":2}',
                'data': finalObject,
                'partial': finalObject,
              },
            ],
          },
        ],
      );
      harness.bridge.mountWithTools(0);
      harness.eventClient.clear();
      harness.bridge.beginRun('run-structured', 'thread-1');

      harness.bridge.events.structuredOutputChanged(
        'structured-output:started',
        'stream',
        'msg-structured',
        const ChatClientStructuredOutputEvent(status: 'streaming'),
      );
      harness.bridge.events.structuredOutputChanged(
        'structured-output:updated',
        'stream',
        'msg-structured',
        ChatClientStructuredOutputEvent(
          status: 'streaming',
          raw: '{"title":"Pasta","servings":2}',
          partial: finalObject,
        ),
      );
      harness.bridge.events.structuredOutputChanged(
        'structured-output:completed',
        'stream',
        'msg-structured',
        ChatClientStructuredOutputEvent(
          status: 'complete',
          raw: '{"title":"Pasta","servings":2}',
          data: finalObject,
        ),
      );

      final started = harness.eventClient
          .emitted('structured-output:started')
          .single
          .payload;
      expect(started['hookId'], 'thread-1');
      expect(started['clientId'], 'thread-1');
      expect(started['threadId'], 'thread-1');
      expect(started['runId'], 'run-structured');
      expect(started['messageId'], 'msg-structured');
      expect(started['status'], 'streaming');

      final updated = harness.eventClient
          .emitted('structured-output:updated')
          .single
          .payload;
      expect(updated['status'], 'streaming');
      expect(updated['raw'], '{"title":"Pasta","servings":2}');
      expect(updated['partial'], finalObject);

      final completed = harness.eventClient
          .emitted('structured-output:completed')
          .single
          .payload;
      expect(completed['status'], 'complete');
      expect(completed['raw'], '{"title":"Pasta","servings":2}');
      expect(completed['data'], finalObject);

      final message =
          (latestState(harness.eventClient)['messages'] as List).single as Map;
      final part = (message['parts'] as List).singleWhere(
        (candidate) =>
            candidate is Map && candidate['type'] == 'structured-output',
      ) as Map;
      expect(part['status'], 'complete');
      expect(part['raw'], '{"title":"Pasta","servings":2}');
      expect(part['data'], finalObject);
      expect(part['partial'], finalObject);

      harness.bridge.dispose();
    });

    test(
        're-emits memory:* devtools events from a transported memory:state CUSTOM chunk',
        () {
      final harness = ChatHarness();
      harness.bridge.mountWithTools(0);
      harness.eventClient.clear();
      harness.bridge.beginRun('run-mem', 'thread-1');

      harness.bridge.recordMemoryState(<String, dynamic>{
        'scope': <String, dynamic>{'threadId': 'sess-1'},
        'adapter': 'in-memory',
        'query': 'what is my name?',
        'recall': <String, dynamic>{
          'fragmentCount': 2,
          'hasTools': false,
          'systemPromptChars': 96,
          'durationMs': 4,
        },
        'snapshot': <String, dynamic>{
          'takenAt': '2026-07-22T00:00:00.000Z',
          'data': <String, dynamic>{
            'records': <Object?>[
              <String, dynamic>{
                'id': 'r1',
                'text': 'name is Jack',
                'kind': 'message',
              },
            ],
          },
          'facts': <Object?>[
            <String, dynamic>{
              'id': 'r1',
              'text': 'name is Jack',
              'source': 'user',
            },
          ],
        },
      });

      final retrieveStarted =
          harness.eventClient.emitted('memory:retrieve:started').single.payload;
      expect(retrieveStarted['scope'], {'threadId': 'sess-1'});
      expect(retrieveStarted['adapter'], 'in-memory');
      expect(retrieveStarted['query'], 'what is my name?');

      final retrieveCompleted = harness.eventClient
          .emitted('memory:retrieve:completed')
          .single
          .payload;
      expect(retrieveCompleted['adapter'], 'in-memory');
      expect(retrieveCompleted['fragmentCount'], 2);
      expect(retrieveCompleted['hasTools'], isFalse);
      expect(retrieveCompleted['systemPromptChars'], 96);
      expect(retrieveCompleted['durationMs'], 4);

      final snapshot =
          harness.eventClient.emitted('memory:snapshot').single.payload;
      expect(snapshot['adapter'], 'in-memory');
      expect(snapshot['takenAt'], '2026-07-22T00:00:00.000Z');
      expect(snapshot['facts'], [
        {'id': 'r1', 'text': 'name is Jack', 'source': 'user'},
      ]);

      harness.eventClient.clear();
      harness.eventClient
          .dispatch('devtools:request-state', <String, dynamic>{});
      expect(
        harness.eventClient.emitted('memory:retrieve:completed').single.payload,
        containsPair('fragmentCount', 2),
      );

      harness.bridge.dispose();
    });

    test(
        're-emits compaction started, state, and ended from transported CUSTOM chunks',
        () {
      final harness = ChatHarness();
      harness.bridge.mountWithTools(0);
      harness.eventClient.clear();
      harness.bridge.beginRun('run-cmp', 'thread-1');

      harness.bridge.recordCompactionEvent(
        'compaction:started',
        <String, dynamic>{
          'before': 400,
          'messagesBefore': 8,
          'reusedCheckpoint': false,
          'maxTokens': 400,
          'strategyKey': 'evict-oldest:half:maxTokens=400',
        },
      );
      harness.bridge.recordCompactionState(<String, dynamic>{
        'before': 400,
        'after': 180,
        'messagesBefore': 8,
        'messagesAfter': 3,
        'reusedCheckpoint': false,
        'maxTokens': 400,
        'strategyKey': 'evict-oldest:half:maxTokens=400',
        'dropped': <Object?>[
          <String, dynamic>{'role': 'user', 'tokens': 40, 'text': 'old turn'},
        ],
        'result': <Object?>[
          <String, dynamic>{'role': 'user', 'tokens': 10, 'text': 'omitted'},
        ],
      });
      harness.bridge.recordCompactionEvent(
        'compaction:ended',
        <String, dynamic>{
          'after': 180,
          'messagesAfter': 3,
          'reusedCheckpoint': false,
          'maxTokens': 400,
          'durationMs': 12,
          'strategyKey': 'evict-oldest:half:maxTokens=400',
        },
      );

      final started =
          harness.eventClient.emitted('compaction:started').single.payload;
      expect(started['before'], 400);
      expect(started['messagesBefore'], 8);
      expect(started['reusedCheckpoint'], isFalse);
      expect(started['maxTokens'], 400);

      final state =
          harness.eventClient.emitted('compaction:state').single.payload;
      expect(state['before'], 400);
      expect(state['after'], 180);
      expect(state['messagesBefore'], 8);
      expect(state['messagesAfter'], 3);
      expect(state['reusedCheckpoint'], isFalse);
      expect(state['maxTokens'], 400);
      expect(state['strategyKey'], 'evict-oldest:half:maxTokens=400');
      expect(state['dropped'], [
        {'role': 'user', 'tokens': 40, 'text': 'old turn'},
      ]);
      expect(state['result'], [
        {'role': 'user', 'tokens': 10, 'text': 'omitted'},
      ]);

      final ended =
          harness.eventClient.emitted('compaction:ended').single.payload;
      expect(ended['after'], 180);
      expect(ended['messagesAfter'], 3);
      expect(ended['durationMs'], 12);

      harness.eventClient.clear();
      harness.eventClient
          .dispatch('devtools:request-state', <String, dynamic>{});
      expect(
        harness.eventClient.emitted('compaction:started').single.payload,
        containsPair('before', 400),
      );
      expect(
        harness.eventClient.emitted('compaction:state').single.payload,
        containsPair('after', 180),
      );
      expect(
        harness.eventClient.emitted('compaction:ended').single.payload,
        containsPair('durationMs', 12),
      );

      harness.bridge.dispose();
    });

    test(
        're-emits skills:snapshot from a transported skills:state CUSTOM chunk',
        () {
      final harness = ChatHarness();
      harness.bridge.mountWithTools(0);
      harness.eventClient.clear();
      harness.bridge.beginRun('run-skills', 'thread-1');

      harness.bridge.recordSkillsState(<String, dynamic>{
        'catalog': <Object?>[
          <String, dynamic>{
            'name': 'pirate-speak',
            'description': 'talk like a pirate',
          },
        ],
        'activated': <Object?>[],
      });

      final snapshot =
          harness.eventClient.emitted('skills:snapshot').single.payload;
      expect(snapshot['catalog'], [
        {'name': 'pirate-speak', 'description': 'talk like a pirate'},
      ]);
      expect(snapshot['activated'], isEmpty);

      harness.eventClient.clear();
      harness.eventClient
          .dispatch('devtools:request-state', <String, dynamic>{});
      expect(
        harness.eventClient.emitted('skills:snapshot').single.payload,
        containsPair('catalog', [
          {'name': 'pirate-speak', 'description': 'talk like a pirate'},
        ]),
      );

      harness.bridge.dispose();
    });

    test('emits structured output completion without streamed deltas', () {
      final finalObject = <String, Object?>{'title': 'Risotto', 'servings': 4};
      final harness = ChatHarness(
        initialMessages: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'msg-structured-terminal',
            'role': 'assistant',
            'parts': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'structured-output',
                'status': 'complete',
                'raw': '{"title":"Risotto","servings":4}',
                'data': finalObject,
                'partial': finalObject,
              },
            ],
          },
        ],
      );
      harness.bridge.mountWithTools(0);
      harness.eventClient.clear();
      harness.bridge.beginRun('run-risotto', 'thread-1');

      harness.bridge.events.structuredOutputChanged(
        'structured-output:completed',
        'stream',
        'msg-structured-terminal',
        ChatClientStructuredOutputEvent(
          status: 'complete',
          raw: '{"title":"Risotto","servings":4}',
          data: finalObject,
        ),
      );

      final completed = harness.eventClient
          .emitted('structured-output:completed')
          .single
          .payload;
      expect(completed['hookId'], 'thread-1');
      expect(completed['clientId'], 'thread-1');
      expect(completed['threadId'], 'thread-1');
      expect(completed['runId'], 'run-risotto');
      expect(completed['messageId'], 'msg-structured-terminal');
      expect(completed['status'], 'complete');
      expect(completed['raw'], '{"title":"Risotto","servings":4}');
      expect(completed['data'], finalObject);

      final message =
          (latestState(harness.eventClient)['messages'] as List).single as Map;
      final part = (message['parts'] as List).singleWhere(
        (candidate) =>
            candidate is Map && candidate['type'] == 'structured-output',
      ) as Map;
      expect(part['status'], 'complete');
      expect(part['raw'], '{"title":"Risotto","servings":4}');
      expect(part['data'], finalObject);
      expect(part['partial'], finalObject);

      harness.bridge.dispose();
    });

    test('preserves structured output parts across multiple chat turns', () {
      final firstObject = <String, Object?>{'title': 'Pasta', 'servings': 2};
      final secondObject = <String, Object?>{'title': 'Soup', 'servings': 3};
      final harness = ChatHarness(
        initialMessages: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'msg-structured-first',
            'role': 'assistant',
            'parts': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'structured-output',
                'status': 'complete',
                'data': firstObject,
              },
            ],
          },
          <String, dynamic>{
            'id': 'msg-structured-second',
            'role': 'assistant',
            'parts': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'structured-output',
                'status': 'complete',
                'data': secondObject,
              },
            ],
          },
        ],
      );
      harness.bridge.mountWithTools(0);

      final messages = latestState(harness.eventClient)['messages'] as List;
      Map<String, dynamic> partFor(String messageId) {
        final message = messages.singleWhere(
          (candidate) => candidate is Map && candidate['id'] == messageId,
        ) as Map;
        return (message['parts'] as List).singleWhere(
          (candidate) =>
              candidate is Map && candidate['type'] == 'structured-output',
        ) as Map<String, dynamic>;
      }

      expect(partFor('msg-structured-first')['data'], firstObject);
      expect(partFor('msg-structured-second')['data'], secondObject);

      harness.bridge.dispose();
    });

    test('emits approval requests that arrive after run finish', () {
      final harness = ChatHarness(
        initialMessages: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'msg-approval',
            'role': 'assistant',
            'parts': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'tool-call',
                'id': 'approval-call-1',
                'name': 'addToCart',
                'arguments': '{"guitarId":"6","quantity":1}',
                'input': <String, dynamic>{'guitarId': '6', 'quantity': 1},
                'state': 'approval-requested',
                'approval': <String, dynamic>{
                  'id': 'approval-approval-call-1',
                  'needsApproval': true,
                },
              },
            ],
          },
        ],
      );
      harness.bridge.mountWithTools(0);
      harness.eventClient.clear();
      harness.bridge.beginRun('run-approval', 'thread-1');
      harness.bridge.observeChunk(<String, dynamic>{
        'type': 'RUN_FINISHED',
        'runId': 'run-approval',
      });

      harness.bridge.events.approvalRequested(
        'stream',
        'msg-approval',
        'approval-call-1',
        'addToCart',
        const <String, Object?>{'guitarId': '6', 'quantity': 1},
        'approval-approval-call-1',
      );

      final requested = harness.eventClient
          .emitted('tools:approval:requested')
          .single
          .payload;
      expect(requested['hookId'], 'thread-1');
      expect(requested['clientId'], 'thread-1');
      expect(requested['threadId'], 'thread-1');
      expect(requested['runId'], 'run-approval');
      expect(requested['streamId'], 'stream');
      expect(requested['messageId'], 'msg-approval');
      expect(requested['toolCallId'], 'approval-call-1');
      expect(requested['toolName'], 'addToCart');
      expect(requested['input'], {'guitarId': '6', 'quantity': 1});
      expect(requested['approvalId'], 'approval-approval-call-1');

      final message =
          (latestState(harness.eventClient)['messages'] as List).single as Map;
      final toolCall = (message['parts'] as List).single as Map;
      expect(toolCall['state'], 'approval-requested');
      expect((toolCall['approval'] as Map)['id'], 'approval-approval-call-1');

      harness.bridge.dispose();
    });

    test('emits approval responses and snapshots the approval decision', () {
      final harness = ChatHarness(
        initialMessages: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'msg-approval',
            'role': 'assistant',
            'parts': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'tool-call',
                'id': 'approval-call-1',
                'name': 'addToCart',
                'arguments': '{"guitarId":"6","quantity":1}',
                'input': <String, dynamic>{'guitarId': '6', 'quantity': 1},
                'state': 'approval-requested',
                'approval': <String, dynamic>{
                  'id': 'approval-approval-call-1',
                  'needsApproval': true,
                  'approved': null,
                },
              },
            ],
          },
        ],
      );
      harness.bridge.mountWithTools(0);
      harness.eventClient.clear();

      harness.bridge.events.toolApprovalResponded(
        'approval-approval-call-1',
        'approval-call-1',
        true,
      );

      final responded = harness.eventClient
          .emitted('tools:approval:responded')
          .single
          .payload;
      expect(responded['hookId'], 'thread-1');
      expect(responded['clientId'], 'thread-1');
      expect(responded['toolCallId'], 'approval-call-1');
      expect(responded['approvalId'], 'approval-approval-call-1');
      expect(responded['approved'], isTrue);

      final message =
          (latestState(harness.eventClient)['messages'] as List).single as Map;
      final toolCall = (message['parts'] as List).single as Map;
      expect(toolCall['state'], 'approval-requested');

      harness.bridge.dispose();
    });
  });

  group('createChatDevtoolsBridge by environment', () {
    test('emits no devtools events in production', () {
      final harness = ChatHarness();
      final bridge = createChatDevtoolsBridge(
        harness.options,
        production: true,
      );

      bridge.mountWithTools(0);

      expect(harness.eventClient.events, isEmpty);
      expect(bridge, isA<NoOpChatDevtoolsBridge>());
      bridge.dispose();
    });

    test('emits devtools events in development', () {
      final harness = ChatHarness();
      final bridge = createChatDevtoolsBridge(
        harness.options,
        production: false,
      );

      bridge.mountWithTools(0);

      expect(harness.eventClient.emitted('hook:registered'), isNotEmpty);
      expect(bridge, isNot(isA<NoOpChatDevtoolsBridge>()));
      bridge.dispose();
    });
  });
}
