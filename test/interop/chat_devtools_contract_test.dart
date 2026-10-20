// Upstream reference: packages/ai-client/tests/devtools.test.ts
//
// Exercises the actual ChatClient against the canonical devtools bridge. The
// bridge is opt-in through `devtoolsBridgeFactory`; the default must stay the
// upstream no-op.
import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/src/devtools/devtools.dart';
import 'package:tanstack_ai_dart/src/devtools/devtools_types.dart';
import 'package:test/test.dart';

class _FakeTransport implements ChatTransport {
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];
  final List<StreamController<Map<String, dynamic>>> controllers =
      <StreamController<Map<String, dynamic>>>[];

  @override
  Stream<Map<String, dynamic>> stream(Map<String, dynamic> body) {
    bodies.add(body);
    final controller = StreamController<Map<String, dynamic>>();
    controllers.add(controller);
    return controller.stream;
  }

  void emit(Map<String, dynamic> event) {
    if (controllers.isEmpty || controllers.last.isClosed) return;
    controllers.last.add(event);
  }

  Future<void> close() async {
    if (controllers.isEmpty || controllers.last.isClosed) return;
    await controllers.last.close();
  }
}

Future<void> _pump([int turns = 6]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('condition was not met');
}

InMemoryAIDevtoolsEventClient get _sink =>
    aiDevtoolsEventClient as InMemoryAIDevtoolsEventClient;

List<AIDevtoolsEventRecord> _emitted(String name) => _sink.emitted(name);

Map<String, dynamic> _lastPayload(String name) => _emitted(name).last.payload;

ChatDevtoolsBridge? _bridgeFromFactory;

ChatClient _client({
  String? threadId,
  ChatTransport? transport,
  List<ClientTool>? tools,
  Map<String, dynamic>? context,
  FutureOr<void> Function()? onResponse,
  bool realDevtools = true,
}) {
  return ChatClient(
    threadId: threadId,
    transport: transport ?? _FakeTransport(),
    tools: tools,
    context: context,
    onResponse: onResponse,
    devtools: const AIDevtoolsClientMetadata(
      name: 'Contract',
      framework: 'dart',
      hookName: 'useChat',
    ),
    devtoolsBridgeFactory: realDevtools
        ? (options) {
            final bridge = ChatDevtoolsBridge(options);
            _bridgeFromFactory = bridge;
            return bridge;
          }
        : null,
  );
}

void main() {
  setUp(() {
    _sink.reset();
    _bridgeFromFactory = null;
  });

  test('defaults to the no-op bridge', () async {
    final transport = _FakeTransport();
    final client = ChatClient(
      transport: transport,
      devtools: const AIDevtoolsClientMetadata(hookName: 'useChat'),
    );
    addTearDown(client.dispose);
    client.mountDevtools();
    final pending = client.sendMessage('hello');
    await _pump();
    await transport.close();
    await pending;

    expect(_sink.events, isEmpty);
  });

  test('mount registers live identities and the initial snapshot', () async {
    final client = _client(threadId: 'thread-42');
    addTearDown(client.dispose);

    client.mountDevtools();

    final registered = _lastPayload('hook:registered');
    expect(registered['hookId'], 'thread-42');
    expect(registered['clientId'], 'thread-42');
    expect(registered['threadId'], 'thread-42');
    expect(registered['displayName'], 'Contract');
    expect(registered['framework'], 'dart');
    expect(registered['hookName'], 'useChat');
    expect(registered['outputKind'], 'chat');
    expect(registered['lifecycle'], 'mounted');

    final snapshot = _lastPayload('hook:state-snapshot');
    expect((snapshot['state'] as Map)['messages'], isEmpty);
    expect((snapshot['state'] as Map)['status'], 'ready');
    expect((snapshot['state'] as Map)['isLoading'], false);
  });

  test('generates one stable identity when construct had no threadId',
      () async {
    final client = _client();
    addTearDown(client.dispose);
    client.mountDevtools();

    final first = _lastPayload('hook:registered');
    expect(first['hookId'], startsWith('thread-'));
    expect(first['hookId'], first['threadId']);

    final pending = client.sendMessage('hello');
    await _pump();
    await (client.transport as _FakeTransport).close();
    await pending;

    expect(_emitted('run:created').single.payload['hookId'], first['hookId']);
    expect(client.threadId, first['threadId']);
  });

  test(
      'correlates created, started and completed run lifecycle with the stream',
      () async {
    final transport = _FakeTransport();
    final client = _client(threadId: 'thread-run', transport: transport);
    addTearDown(client.dispose);
    client.mountDevtools();
    final pending = client.sendMessage('hello');
    await _pump();

    transport.emit(<String, dynamic>{
      'type': 'RUN_STARTED',
      'runId': 'server-run',
      'threadId': 'thread-run',
    });
    transport.emit(<String, dynamic>{
      'type': 'TEXT_MESSAGE_START',
      'messageId': 'msg-1',
      'role': 'assistant',
    });
    transport.emit(<String, dynamic>{
      'type': 'TEXT_MESSAGE_CONTENT',
      'messageId': 'msg-1',
      'delta': 'Hi',
    });
    transport.emit(<String, dynamic>{
      'type': 'TEXT_MESSAGE_END',
      'messageId': 'msg-1',
    });
    transport.emit(<String, dynamic>{
      'type': 'RUN_FINISHED',
      'runId': 'server-run',
      'threadId': 'thread-run',
    });
    await transport.close();
    await pending;

    final created = _emitted('run:created').single.payload;
    final started = _emitted('run:started').single.payload;
    final completed = _emitted('run:completed').single.payload;
    expect(started['runId'], created['runId']);
    expect(completed['runId'], created['runId']);
    expect(created['status'], 'created');
    expect(started['status'], 'started');
    expect(completed['status'], 'completed');

    final text = _emitted('text:chunk:content').last.payload;
    expect(text['runId'], 'server-run');
    expect(text['threadId'], 'thread-run');
    expect(text['content'], 'Hi');
    expect(text['streamId'], isNotEmpty);
    expect(text['messageId'], 'msg-1');
  });

  test('stop owns the run and emits a single cancelled terminal', () async {
    final transport = _FakeTransport();
    final client = _client(threadId: 'thread-stop', transport: transport);
    addTearDown(client.dispose);
    client.mountDevtools();
    final pending = client.sendMessage('hello');
    await _pump();
    transport.emit(<String, dynamic>{
      'type': 'RUN_STARTED',
      'runId': 'server-run',
      'threadId': 'thread-stop',
    });
    await _pump();

    await client.stop();
    await pending;
    await _pump();

    expect(_emitted('run:cancelled'), hasLength(1));
    expect(_emitted('run:completed'), isEmpty);
    expect(_emitted('run:errored'), isEmpty);
  });

  test('applies a scoped tool fixture through the live snapshot callbacks',
      () async {
    final client = _client(threadId: 'thread-fixture');
    addTearDown(client.dispose);
    client.mountDevtools();

    _sink.dispatch('devtools:tool-fixture:apply', {
      'hookId': 'thread-fixture',
      'threadId': 'thread-fixture',
      'runId': 'fixture-run',
      'toolName': 'weather',
      'input': {'city': 'Paris'},
      'output': {'temperature': 21},
      'toolCallId': 'fixture-call',
      'messageId': 'fixture-message',
    });
    await _waitFor(() => client.messages.length == 1);

    final message = client.messages.single;
    expect(message.id, 'fixture-message');
    expect(message.role, 'assistant');
    final toolCall =
        message.parts.firstWhere((part) => part.type == 'tool-call');
    expect(toolCall.id, 'fixture-call');
    expect(toolCall.input, {'city': 'Paris'});
    expect(toolCall.output, {'temperature': 21});
    expect(message.parts.any((part) => part.type == 'tool-result'), isTrue);

    final fixtureEvent = _lastPayload('devtools:tool-fixture:applied');
    expect(fixtureEvent['runId'], 'fixture-run');
    expect(fixtureEvent['threadId'], 'thread-fixture');
    final messages =
        (_lastPayload('hook:state-snapshot')['state'] as Map)['messages'];
    expect((messages as List).single['id'], 'fixture-message');
  });

  test('ignores fixtures for another hook or thread', () async {
    final client = _client(threadId: 'thread-fixture');
    addTearDown(client.dispose);
    client.mountDevtools();

    _sink.dispatch('devtools:tool-fixture:apply', {
      'hookId': 'other-hook',
      'toolName': 'weather',
      'input': {},
      'output': null,
    });
    _sink.dispatch('devtools:tool-fixture:apply', {
      'threadId': 'other-thread',
      'toolName': 'weather',
      'input': {},
      'output': null,
    });
    await _pump();

    expect(client.messages, isEmpty);
    expect(_emitted('devtools:tool-fixture:applied'), isEmpty);
  });

  test('executes registered client tools for execute fixtures', () async {
    var executed = 0;
    final tool = ClientTool(
      name: 'weather',
      description: 'Weather',
      execute: (input, context) {
        executed += 1;
        return {'city': (input as Map)['city'], 'temperature': 23};
      },
    );
    final client = _client(threadId: 'thread-exec', tools: <ClientTool>[tool]);
    addTearDown(client.dispose);
    client.mountDevtools();

    _sink.dispatch('devtools:tool-fixture:apply', {
      'hookId': 'thread-exec',
      'threadId': 'thread-exec',
      'toolName': 'weather',
      'input': {'city': 'Berlin'},
      'output': null,
      'execute': true,
      'toolCallId': 'exec-call',
      'messageId': 'exec-message',
    });
    await _waitFor(
      () =>
          client.messages.isNotEmpty &&
          client.messages.single.parts.any(
            (part) => part.type == 'tool-call' && part.output != null,
          ),
    );

    expect(executed, 1);
    final call = client.messages.single.parts
        .firstWhere((part) => part.type == 'tool-call');
    expect(call.output, {'city': 'Berlin', 'temperature': 23});
    final result = client.messages.single.parts
        .firstWhere((part) => part.type == 'tool-result');
    expect(result.toolCallId, 'exec-call');
  });

  test('emits snapshots for manual messages, hydration and reload', () async {
    final transport = _FakeTransport();
    final client = ChatClient(
      threadId: 'thread-history',
      transport: transport,
      hydrate: (threadId, options) async => ChatHydrationResult(
        messages: <AssistantTurn>[
          AssistantTurn(
            id: 'hydrated-user',
            role: 'user',
            parts: <AssistantPart>[AssistantPart.text('loaded')],
          ),
          AssistantTurn(
            id: 'hydrated',
            role: 'assistant',
            parts: <AssistantPart>[AssistantPart.text('loaded')],
          ),
        ],
      ),
      devtools: const AIDevtoolsClientMetadata(hookName: 'useChat'),
      devtoolsBridgeFactory: (options) => ChatDevtoolsBridge(options),
    );
    addTearDown(client.dispose);
    client.mountDevtools();

    client.setMessagesManually(<AssistantTurn>[
      AssistantTurn(
        id: 'manual',
        role: 'user',
        parts: <AssistantPart>[AssistantPart.text('manual')],
      ),
    ]);
    var state = _lastPayload('hook:state-snapshot')['state'] as Map;
    expect((state['messages'] as List).single['id'], 'manual');

    await client.attach();
    state = _lastPayload('hook:state-snapshot')['state'] as Map;
    expect((state['messages'] as List).last['id'], 'hydrated');

    final pending = client.reload();
    await _pump();
    final bodyMessages = (transport.bodies.last['messages'] as List);
    expect(bodyMessages, isNotEmpty);
    await transport.close();
    await pending;
    expect(_emitted('hook:state-snapshot'), isNotEmpty);
  });

  test('updateOptions can install onResponse without reinstalling the client',
      () async {
    var calls = 0;
    final transport = _FakeTransport();
    final client = _client(threadId: 'thread-response', transport: transport);
    addTearDown(client.dispose);

    client.updateOptions(onResponse: () async {
      calls += 1;
    });
    final pending = client.sendMessage('hello');
    await _pump();
    await transport.close();
    await pending;

    expect(calls, 1);
  });

  test('disposes the bridge once and leaves later emissions silent', () async {
    final transport = _FakeTransport();
    final client = _client(threadId: 'thread-dispose', transport: transport);
    client.mountDevtools();
    final pending = client.sendMessage('hello');
    await _pump();
    await transport.close();
    await pending;
    _sink.events.clear();

    await client.dispose();
    await client.dispose();

    expect(_emitted('hook:unregistered'), hasLength(1));
    expect(_emitted('hook:unregistered').single.payload['reason'], 'disposed');
  });

  test('runtime context stays out of the wire while the bridge sees the run',
      () async {
    final transport = _FakeTransport();
    final client = _client(
      threadId: 'thread-context',
      transport: transport,
      context: {'secret-runtime-context': true},
    );
    addTearDown(client.dispose);
    client.mountDevtools();
    final pending = client.sendMessage('hello');
    await _pump();

    expect('${transport.bodies.single}',
        isNot(contains('secret-runtime-context')));
    await transport.close();
    await pending;
    expect(_bridgeFromFactory, isNotNull);
  });
}
