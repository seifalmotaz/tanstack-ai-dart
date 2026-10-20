// Upstream references:
// - packages/ai-client/tests/devtools.test.ts (40 cases)
// - packages/ai-client/tests/chat-client.test.ts devtools events (4 cases)
// - packages/ai-client/tests/chat-client-noop-devtools.test.ts (5 cases)
//
// These tests instantiate the REAL ChatClient with a real ChatDevtoolsBridge.
// No ChatHarness or placeholder constants are used. A missing client/devtools
// API must surface as a concrete failing expectation here so Codex can wire it.
import 'dart:async';
import 'dart:convert';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/connections.dart' hide ChatHydrationResult;
import 'package:tanstack_ai_dart/src/devtools/devtools.dart';
import 'package:tanstack_ai_dart/src/devtools/devtools_factories.dart';
import 'package:tanstack_ai_dart/src/devtools/devtools_types.dart';
import 'package:test/test.dart';

InMemoryAIDevtoolsEventClient get _sink =>
    aiDevtoolsEventClient as InMemoryAIDevtoolsEventClient;

List<AIDevtoolsEventRecord> _emitted(String name) => _sink.emitted(name);

Map<String, dynamic> _payload(String name) => _emitted(name).last.payload;

Future<void> _pump([int turns = 8]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _waitFor(bool Function() condition, {int attempts = 300}) async {
  for (var i = 0; i < attempts; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('Timed out waiting for condition');
}

Map<String, dynamic> _latestState() {
  final snapshots = _emitted('hook:state-snapshot');
  if (snapshots.isEmpty) {
    throw StateError('Expected at least one hook:state-snapshot');
  }
  final raw = snapshots.last.payload['state'];
  if (raw is! Map) throw StateError('Snapshot has no state map');
  return raw.map((key, value) => MapEntry('$key', value));
}

List<Map<String, dynamic>> _latestMessages() =>
    (_latestState()['messages'] as List? ?? const <Object?>[])
        .whereType<Map>()
        .map((map) => map.map((key, value) => MapEntry('$key', value)))
        .toList();

Map<String, dynamic>? _findToolCall(String id) {
  for (final message in _latestMessages()) {
    final parts = message['parts'];
    if (parts is! List) continue;
    for (final part in parts.whereType<Map>()) {
      if (part['type'] == 'tool-call' && part['id'] == id) {
        return part.map((key, value) => MapEntry('$key', value));
      }
    }
  }
  return null;
}

Map<String, dynamic>? _findStructuredPart(String messageId) {
  for (final message in _latestMessages()) {
    if (message['id'] != messageId) continue;
    final parts = message['parts'];
    if (parts is! List) continue;
    for (final part in parts.whereType<Map>()) {
      if (part['type'] == 'structured-output') {
        return part.map((key, value) => MapEntry('$key', value));
      }
    }
  }
  return null;
}

ConnectionAdapter _adapter(
  List<List<Map<String, dynamic>>> runs, {
  List<RunAgentInputContext>? contexts,
}) {
  var calls = 0;
  return ConnectionAdapter(
    connect: (messages, {data, signal, runContext}) async* {
      if (runContext != null) contexts?.add(runContext);
      final chunks =
          calls < runs.length ? runs[calls] : const <Map<String, dynamic>>[];
      calls += 1;
      for (final chunk in chunks) {
        if (signal?.isCancelled == true) return;
        yield chunk;
      }
    },
  );
}

class _ManualConnection {
  final StreamController<Map<String, dynamic>> controller =
      StreamController<Map<String, dynamic>>();
  final List<RunAgentInputContext> contexts = <RunAgentInputContext>[];

  late final ConnectionAdapter adapter = ConnectionAdapter(
    connect: (messages, {data, signal, runContext}) {
      if (runContext != null) contexts.add(runContext);
      return controller.stream;
    },
  );
}

List<Map<String, dynamic>> _textChunks(
  String text, {
  String threadId = 'thread-1',
  String runId = 'run-1',
  String messageId = 'msg-1',
}) {
  final chunks = <Map<String, dynamic>>[
    {
      'type': 'RUN_STARTED',
      'threadId': threadId,
      'runId': runId,
      'timestamp': 1,
    },
    {
      'type': 'TEXT_MESSAGE_START',
      'messageId': messageId,
      'role': 'assistant',
      'timestamp': 1,
    },
  ];
  for (final char in text.split('')) {
    chunks.add({
      'type': 'TEXT_MESSAGE_CONTENT',
      'messageId': messageId,
      'delta': char,
      'timestamp': 1,
    });
  }
  chunks.addAll([
    {'type': 'TEXT_MESSAGE_END', 'messageId': messageId, 'timestamp': 1},
    {
      'type': 'RUN_FINISHED',
      'threadId': threadId,
      'runId': runId,
      'timestamp': 1,
      'outcome': {'type': 'success'},
      'metadata': {
        'tanstack': {'finishReason': 'stop'},
      },
    },
  ]);
  return chunks;
}

List<Map<String, dynamic>> _toolChunks({
  String toolCallId = 'tool-1',
  String toolName = 'getWeather',
  String arguments = '{"city":"NYC"}',
  String threadId = 'thread-1',
  String runId = 'run-1',
  String messageId = 'msg-tool',
  bool includeRunStarted = true,
}) =>
    <Map<String, dynamic>>[
      if (includeRunStarted)
        {'type': 'RUN_STARTED', 'threadId': threadId, 'runId': runId},
      {
        'type': 'TOOL_CALL_START',
        'messageId': messageId,
        'toolCallId': toolCallId,
        'toolCallName': toolName,
      },
      {
        'type': 'TOOL_CALL_ARGS',
        'messageId': messageId,
        'toolCallId': toolCallId,
        'delta': arguments,
      },
      {
        'type': 'TOOL_CALL_END',
        'messageId': messageId,
        'toolCallId': toolCallId,
        'toolCallName': toolName,
      },
      {
        'type': 'RUN_FINISHED',
        'threadId': threadId,
        'runId': runId,
        'outcome': {'type': 'success'},
      },
    ];

AssistantTurn _user(String id, String text) => AssistantTurn(
      id: id,
      role: 'user',
      parts: <AssistantPart>[AssistantPart.text(text)],
    );

AssistantTurn _assistantText(String id, String text) => AssistantTurn(
      id: id,
      role: 'assistant',
      parts: <AssistantPart>[AssistantPart.text(text)],
    );

ChatClient _client({
  String? threadId = 'thread-1',
  ChatTransport? transport,
  ConnectionAdapter? connection,
  List<AssistantTurn>? initialMessages,
  List<ClientTool>? tools,
  Map<String, dynamic>? context,
  ChatHydrateCallback? hydrate,
  String? devtoolsName,
  bool mount = true,
  ChatDevtoolsBridge Function(ChatDevtoolsBridgeOptions)? factory,
}) {
  final client = ChatClient(
    threadId: threadId,
    transport: transport,
    connection: connection ?? (transport == null ? _adapter(const []) : null),
    messages: initialMessages,
    tools: tools,
    context: context,
    hydrate: hydrate,
    devtools: AIDevtoolsClientMetadata(
      name: devtoolsName,
      framework: 'react',
      hookName: 'useChat',
    ),
    devtoolsBridgeFactory: factory ?? (options) => ChatDevtoolsBridge(options),
  );
  if (mount) client.mountDevtools();
  return client;
}

void main() {
  setUp(() {
    _sink.reset();
  });

  group('ChatClient devtools bridge', () {
    test('does not emit hook lifecycle events before devtools is mounted',
        () async {
      final client = _client(mount: false);
      expect(_emitted('hook:registered'), isEmpty);
      expect(_emitted('hook:state-snapshot'), isEmpty);

      await client.dispose();

      expect(_emitted('hook:unregistered'), isEmpty);
    });

    test('registers a generated hookId when construct had no threadId',
        () async {
      final client = _client(threadId: null, devtoolsName: 'Skills');
      addTearDown(client.dispose);

      final registered = _payload('hook:registered');
      expect(registered['hookId'], startsWith('thread-'));
      expect(registered['displayName'], 'Skills');
      expect(registered['lifecycle'], 'mounted');

      final created = _payload('client:created');
      expect(created['clientId'], startsWith('thread-'));
      expect(created['hookId'], startsWith('thread-'));
      expect(created['clientId'], created['hookId']);
    });

    test('can register again after a mount cleanup cycle', () async {
      final client = _client(mount: false);
      client.mountDevtools();
      await client.dispose();
      _sink.clear();

      client.mountDevtools();

      final registered = _emitted('hook:registered');
      expect(registered, hasLength(1));
      expect(registered.single.payload['hookId'], 'thread-1');
      expect(registered.single.payload['lifecycle'], 'mounted');
      await client.dispose();
    });

    test('binds hook identity to threadId', () async {
      final client = _client(threadId: 'support-42');
      addTearDown(client.dispose);

      final payload = _payload('hook:registered');
      expect(payload['hookId'], 'support-42');
      expect(payload['clientId'], 'support-42');
      expect(payload['threadId'], 'support-42');
      expect(payload.containsKey('correlationId'), isFalse);
    });

    test('does not unregister a superseded client that shares a threadId',
        () async {
      final first = _client(threadId: 'support-42');
      final second = _client(threadId: 'support-42');
      _sink.clear();

      await first.dispose();
      expect(_emitted('hook:unregistered'), isEmpty);

      await second.dispose();
      final unregistered = _emitted('hook:unregistered');
      expect(unregistered, hasLength(1));
      expect(unregistered.single.payload['hookId'], 'support-42');
      expect(unregistered.single.payload['threadId'], 'support-42');
    });

    test('registers the chat hook and emits the initial state snapshot',
        () async {
      final client = _client();
      addTearDown(client.dispose);

      final registered = _payload('hook:registered');
      expect(registered['eventId'], isA<String>());
      expect(registered['eventType'], 'hook:registered');
      expect(registered['source'], 'client');
      expect(registered['visibility'], 'client-state');
      expect(registered['hookId'], 'thread-1');
      expect(registered['clientId'], 'thread-1');
      expect(registered['threadId'], 'thread-1');
      expect(registered['hookName'], 'useChat');
      expect(registered['framework'], 'react');
      expect(registered['outputKind'], 'chat');
      expect(registered['lifecycle'], 'mounted');

      final snapshot = _payload('hook:state-snapshot');
      expect(snapshot['eventId'], isA<String>());
      expect(snapshot['eventType'], 'hook:state-snapshot');
      expect(snapshot['source'], 'client');
      expect(snapshot['visibility'], 'client-state');
      expect(snapshot['hookId'], 'thread-1');
      expect(snapshot['clientId'], 'thread-1');
      expect(snapshot['threadId'], 'thread-1');
      final state = snapshot['state'] as Map;
      expect(state['messages'], isEmpty);
      expect(state['status'], 'ready');
      expect(state['isLoading'], false);
      expect(state['activeRunIds'], isEmpty);
    });

    test('emits the configured devtools display name', () async {
      final client = _client(devtoolsName: 'Recipe Assistant');
      addTearDown(client.dispose);

      final registered = _payload('hook:registered');
      expect(registered['hookName'], 'useChat');
      expect(registered['displayName'], 'Recipe Assistant');
      final snapshot = _payload('hook:state-snapshot');
      expect(snapshot['displayName'], 'Recipe Assistant');
    });

    test('registers client tool metadata for devtools discovery', () async {
      final tool = ClientTool(
        name: 'weather',
        description: 'Lookup weather',
        needsApproval: true,
        metadata: const <String, dynamic>{'fixture': true},
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'city': <String, dynamic>{'type': 'string'},
          },
        },
        outputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'temperature': <String, dynamic>{'type': 'number'},
          },
        },
      );
      final client = _client(tools: <ClientTool>[tool]);
      addTearDown(client.dispose);

      final payload = _payload('tools:registered');
      expect(payload['hookId'], 'thread-1');
      expect(payload['hookName'], 'useChat');
      expect(payload['framework'], 'react');
      expect(payload['outputKind'], 'chat');
      final tools = payload['tools'] as List;
      expect(tools, hasLength(1));
      final registered = tools.single as Map;
      expect(registered['name'], 'weather');
      expect(registered['description'], 'Lookup weather');
      expect(registered['inputSchema'], containsPair('type', 'object'));
      expect(registered['outputSchema'], containsPair('type', 'object'));
      expect(registered['needsApproval'], true);
      expect(registered['metadata'], <String, dynamic>{'fixture': true});
    });

    test('responds to devtools state requests for its hook', () async {
      final client = _client();
      addTearDown(client.dispose);
      _sink.clear();

      _sink.dispatch('devtools:request-state', {'targetHookId': 'thread-1'});
      await _pump();

      final registered = _payload('hook:registered');
      expect(registered['hookId'], 'thread-1');
      expect(registered['clientId'], 'thread-1');
      expect(registered['threadId'], 'thread-1');
      expect(registered['hookName'], 'useChat');
      expect(registered['outputKind'], 'chat');

      final tools = _payload('tools:registered');
      expect(tools['hookId'], 'thread-1');
      expect(tools['tools'], isEmpty);

      final snapshot = _payload('hook:state-snapshot');
      expect(snapshot['hookId'], 'thread-1');
      expect(snapshot['clientId'], 'thread-1');
      expect(snapshot['threadId'], 'thread-1');
      final state = snapshot['state'] as Map;
      expect(state['messages'], isEmpty);
      expect(state['status'], 'ready');
      expect(state['isLoading'], false);
      expect(state['activeRunIds'], isEmpty);
    });

    test('uses the resilient devtools emitter for hook registration sync',
        () async {
      final client = _client();
      addTearDown(client.dispose);
      expect(_payload('hook:registered')['lifecycle'], 'mounted');

      _sink.clear();
      _sink.dispatch('devtools:request-state', {'targetHookId': 'thread-1'});
      await _pump();

      expect(_payload('hook:registered')['lifecycle'], 'mounted');
      expect(_payload('hook:registered')['hookId'], 'thread-1');
      expect(_payload('hook:state-snapshot')['hookId'], 'thread-1');
      expect(
        (_payload('hook:state-snapshot')['state'] as Map)['messages'],
        isEmpty,
      );
    });

    test('does not respond to devtools state requests for another hook',
        () async {
      final client = _client();
      addTearDown(client.dispose);
      _sink.clear();

      _sink.dispatch('devtools:request-state', {'targetHookId': 'other-hook'});
      await _pump();

      expect(_emitted('hook:registered'), isEmpty);
      expect(_emitted('hook:state-snapshot'), isEmpty);
    });

    test('applies a devtools tool fixture as a normal assistant message',
        () async {
      final client = _client();
      addTearDown(client.dispose);
      _sink.clear();

      _sink.dispatch('devtools:tool-fixture:apply', _fixtureMap());
      await _waitFor(() => client.getMessages().length == 1);

      final message = client.getMessages().single;
      expect(message.id, 'fixture-message');
      expect(message.role, 'assistant');
      final call = message.parts.firstWhere((part) => part.type == 'tool-call');
      expect(call.id, 'fixture-call');
      expect(call.name, 'weather');
      expect(call.arguments, '{"city":"Paris"}');
      expect(call.input, {'city': 'Paris'});
      expect(call.state, 'input-complete');
      expect(call.output, {'temperature': 21});
      final result =
          message.parts.firstWhere((part) => part.type == 'tool-result');
      expect(result.toolCallId, 'fixture-call');
      expect(result.content, '{"temperature":21}');
      expect(result.state, 'complete');
      expect(message.createdAt, isNotNull);

      final applied = _payload('devtools:tool-fixture:applied');
      expect(applied['hookId'], 'thread-1');
      expect(applied['threadId'], 'thread-1');
      expect(applied['runId'], 'run-fixture');
      expect(applied['toolName'], 'weather');
      expect(applied['input'], {'city': 'Paris'});
      expect(applied['output'], {'temperature': 21});
      expect(applied['messageId'], 'fixture-message');
      expect(applied['toolCallId'], 'fixture-call');
      expect(applied['visibility'], 'user-visible');

      final created = _payload('text:message:created');
      expect(created['hookId'], 'thread-1');
      expect(created['threadId'], 'thread-1');
      expect(created['runId'], 'run-fixture');
      expect(created['toolCallId'], 'fixture-call');
      expect(created['messageId'], 'fixture-message');
      expect(created['role'], 'assistant');
      expect(created['parts'], isNotEmpty);
      expect(created['visibility'], 'user-visible');

      expect(_latestMessages().single['id'], 'fixture-message');
    });

    test(
        'generates fresh ids when replaying a fixture from an existing tool call',
        () async {
      final existing = AssistantTurn(
        id: 'fixture-message',
        role: 'assistant',
        parts: <AssistantPart>[
          AssistantPart.tool(
            id: 'fixture-call',
            name: 'weather',
            arguments: '{"city":"Paris"}',
            input: {'city': 'Paris'},
            output: {'temperature': 21},
            state: 'input-complete',
          ),
          AssistantPart(
            type: 'tool-result',
            toolCallId: 'fixture-call',
            content: '{"temperature":21}',
            state: 'complete',
            output: {'temperature': 21},
            hasOutput: true,
          ),
        ],
      );
      final client = _client(initialMessages: <AssistantTurn>[existing]);
      addTearDown(client.dispose);
      _sink.clear();

      _sink.dispatch('devtools:tool-fixture:apply', _fixtureMap());
      await _waitFor(() => client.getMessages().length == 2);

      final replay = client.getMessages()[1];
      expect(replay.id, isNot('fixture-message'));
      final call = replay.parts.firstWhere((part) => part.type == 'tool-call');
      final result =
          replay.parts.firstWhere((part) => part.type == 'tool-result');
      expect(call.name, 'weather');
      expect(call.input, {'city': 'Paris'});
      expect(call.id, isNot('fixture-call'));
      expect(result.toolCallId, call.id);
      expect(_payload('text:message:created')['messageId'], replay.id);
      expect(_payload('text:message:created')['toolCallId'], call.id);
    });

    test('replays the full source message when a fixture includes one',
        () async {
      final source = AssistantTurn(
        id: 'source-message',
        role: 'assistant',
        parts: <AssistantPart>[
          AssistantPart.thinking(
            id: 'thinking-1',
            content: 'Need to inspect the catalog.',
          ),
          AssistantPart.tool(
            id: 'source-tool-call',
            name: 'weather',
            arguments: '{"city":"Paris"}',
            input: {'city': 'Paris'},
            state: 'input-complete',
          ),
          AssistantPart(
            type: 'tool-result',
            toolCallId: 'source-tool-call',
            content: '{"temperature":21}',
            state: 'complete',
            output: {'temperature': 21},
            hasOutput: true,
          ),
          AssistantPart.text('Paris is mild today.'),
        ],
      );
      final client = _client(initialMessages: <AssistantTurn>[source]);
      addTearDown(client.dispose);
      _sink.clear();

      _sink.dispatch(
        'devtools:tool-fixture:apply',
        _fixtureMap(
          messageId: source.id,
          toolCallId: 'source-tool-call',
          message: <String, dynamic>{
            'id': source.id,
            'role': source.role,
            'parts': <Map<String, dynamic>>[
              {'type': 'thinking', 'content': 'Need to inspect the catalog.'},
              {
                'type': 'tool-call',
                'id': 'source-tool-call',
                'name': 'weather',
                'arguments': '{"city":"Paris"}',
                'input': {'city': 'Paris'},
                'state': 'input-complete',
              },
              {
                'type': 'tool-result',
                'toolCallId': 'source-tool-call',
                'content': '{"temperature":21}',
                'state': 'complete',
              },
              {'type': 'text', 'content': 'Paris is mild today.'},
            ],
          },
        ),
      );
      await _waitFor(() => client.getMessages().length == 2);

      final replay = client.getMessages()[1];
      expect(replay.id, isNot(source.id));
      expect(replay.role, source.role);
      final call = replay.parts.firstWhere((part) => part.type == 'tool-call');
      final result =
          replay.parts.firstWhere((part) => part.type == 'tool-result');
      expect(call.id, isNot('source-tool-call'));
      expect(call.name, 'weather');
      expect(call.input, {'city': 'Paris'});
      expect(call.output, {'temperature': 21});
      expect(result.toolCallId, call.id);
      expect(result.content, '{"temperature":21}');
      expect(replay.parts.first.type, 'thinking');
      expect(replay.parts.last.type, 'text');
      expect(replay.parts.last.content, 'Paris is mild today.');
      expect(_payload('text:message:created')['parts'], isNotEmpty);
    });

    test('executes the registered client tool when firing a fixture', () async {
      var calls = 0;
      final tool = ClientTool(
        name: 'weather',
        description: 'Get the weather for a city',
        inputSchema: const <String, dynamic>{'type': 'object'},
        outputSchema: const <String, dynamic>{'type': 'object'},
        execute: (input, ToolCallContext context) {
          calls += 1;
          return <String, dynamic>{
            'city': (input as Map)['city'],
            'temperature': 23,
          };
        },
      );
      final client = _client(tools: <ClientTool>[tool]);
      addTearDown(client.dispose);
      _sink.clear();

      _sink.dispatch(
        'devtools:tool-fixture:apply',
        _fixtureMap(
          input: {'city': 'Berlin'},
          output: null,
          execute: true,
        ),
      );
      await _waitFor(
        () =>
            client.getMessages().isNotEmpty &&
            client.getMessages().single.parts.any(
                  (part) => part.type == 'tool-call' && part.output != null,
                ),
      );

      expect(calls, 1);
      final message = client.getMessages().single;
      final call = message.parts.firstWhere((part) => part.type == 'tool-call');
      final result =
          message.parts.firstWhere((part) => part.type == 'tool-result');
      expect(call.name, 'weather');
      expect(call.input, {'city': 'Berlin'});
      expect(call.output, {'city': 'Berlin', 'temperature': 23});
      expect(result.content, '{"city":"Berlin","temperature":23}');
    });

    test('routes hook-scoped fixture events to the latest bridge for a hook id',
        () async {
      final stale = _client(threadId: 'shared-thread');
      final active = _client(threadId: 'shared-thread');
      addTearDown(stale.dispose);
      addTearDown(active.dispose);
      _sink.clear();

      _sink.dispatch(
        'devtools:tool-fixture:apply',
        _fixtureMap(threadId: 'shared-thread', hookId: 'shared-thread'),
      );
      await _waitFor(() => active.getMessages().length == 1);

      expect(stale.getMessages(), isEmpty);
      final applied = active.getMessages().single;
      expect(applied.id, 'fixture-message');
      final call = applied.parts.firstWhere((part) => part.type == 'tool-call');
      final result =
          applied.parts.firstWhere((part) => part.type == 'tool-result');
      expect(call.name, 'weather');
      expect(call.output, {'temperature': 21});
      expect(result.content, '{"temperature":21}');
    });

    test('keeps superseded duplicate hook bridges silent when they emit later',
        () async {
      final contexts = <RunAgentInputContext>[];
      final first = _client(
        threadId: 'shared-thread',
        connection: _adapter(<List<Map<String, dynamic>>>[
          _textChunks('from first', messageId: 'msg-first')
        ], contexts: contexts),
      );
      final duplicate = _client(threadId: 'shared-thread');
      _sink.clear();

      await first.sendMessage('start');

      expect(contexts, isNotEmpty);
      expect(_emitted('run:created'), isEmpty);
      expect(_emitted('hook:updated'), isEmpty);
      expect(_emitted('hook:state-snapshot'), isEmpty);

      await first.dispose();
      expect(_emitted('hook:unregistered'), isEmpty);

      await duplicate.dispose();
      final unregistered = _emitted('hook:unregistered');
      expect(unregistered, hasLength(1));
      expect(unregistered.single.payload['hookId'], 'shared-thread');
      expect(unregistered.single.payload['threadId'], 'shared-thread');
    });

    test(
        'includes thread and tool call context when applying a fixture without a run id',
        () async {
      final client = _client();
      addTearDown(client.dispose);
      _sink.clear();

      _sink.dispatch(
        'devtools:tool-fixture:apply',
        _fixtureMap(
          runId: null,
          input: {'city': 'Rome'},
          output: {'temperature': 24},
          toolCallId: 'thread-only-call',
          messageId: 'thread-only-message',
        ),
      );
      await _waitFor(() => client.getMessages().length == 1);

      final created = _payload('text:message:created');
      expect(created['threadId'], 'thread-1');
      expect(created['toolCallId'], 'thread-only-call');
      expect(created['messageId'], 'thread-only-message');
      expect(created['visibility'], 'user-visible');
    });

    test(
        'marks fixture tool results as errored when devtools provides error text',
        () async {
      final client = _client();
      addTearDown(client.dispose);
      _sink.clear();

      _sink.dispatch(
        'devtools:tool-fixture:apply',
        _fixtureMap(output: null, errorText: 'Tool failed'),
      );
      await _waitFor(() => client.getMessages().length == 1);

      final message = client.getMessages().single;
      final call = message.parts.firstWhere((part) => part.type == 'tool-call');
      final result =
          message.parts.firstWhere((part) => part.type == 'tool-result');
      expect(call.output, isNull);
      expect(result.toolCallId, 'fixture-call');
      expect(result.content, 'null');
      expect(result.state, 'error');
      expect(result.error, 'Tool failed');
      expect(_payload('devtools:tool-fixture:applied')['errorText'],
          'Tool failed');
    });

    test('ignores devtools tool fixtures for another thread', () async {
      final client = _client();
      addTearDown(client.dispose);
      _sink.clear();

      _sink.dispatch(
        'devtools:tool-fixture:apply',
        _fixtureMap(threadId: 'other-thread', hookId: null, runId: null),
      );
      await _pump();

      expect(client.getMessages(), isEmpty);
      expect(_emitted('devtools:tool-fixture:applied'), isEmpty);
    });

    test('ignores unscoped devtools tool fixtures', () async {
      final client = _client();
      addTearDown(client.dispose);
      _sink.clear();

      _sink.dispatch(
        'devtools:tool-fixture:apply',
        _fixtureMap(hookId: null, threadId: null, runId: null),
      );
      await _pump();

      expect(client.getMessages(), isEmpty);
      expect(_emitted('devtools:tool-fixture:applied'), isEmpty);
    });

    test('ignores devtools tool fixtures for another hook', () async {
      final client = _client();
      addTearDown(client.dispose);
      _sink.clear();

      _sink.dispatch(
        'devtools:tool-fixture:apply',
        _fixtureMap(hookId: 'other-hook'),
      );
      await _pump();

      expect(client.getMessages(), isEmpty);
      expect(_emitted('devtools:tool-fixture:applied'), isEmpty);
    });

    test('disposes the hook bridge idempotently', () async {
      final client = _client();
      _sink.clear();

      await client.dispose();
      await client.dispose();

      expect(_emitted('hook:unregistered'), hasLength(1));
      expect(_sink.unsubscribeCalls, 2);
    });

    test('emits a snapshot when messages are set manually', () async {
      final client = _client();
      addTearDown(client.dispose);
      _sink.clear();

      client.setMessagesManually(<AssistantTurn>[_user('msg-user', 'Hello')]);

      final messages =
          (_payload('hook:state-snapshot')['state'] as Map)['messages'] as List;
      expect(messages, hasLength(1));
      expect((messages.single as Map)['id'], 'msg-user');
    });

    test('emits a snapshot when messages are cleared', () async {
      final client = _client();
      addTearDown(client.dispose);
      client.setMessagesManually(<AssistantTurn>[_user('msg-user', 'Hello')]);
      _sink.clear();

      await client.clear();

      final messages =
          (_payload('hook:state-snapshot')['state'] as Map)['messages'] as List;
      expect(messages, isEmpty);
    });

    test(
        'emits a snapshot after reload removes messages after the last user message',
        () async {
      final manual = _ManualConnection();
      final client = _client(
        connection: manual.adapter,
        initialMessages: <AssistantTurn>[
          _user('msg-user', 'Hello'),
          _assistantText('msg-assistant', 'Hi'),
        ],
      );
      addTearDown(client.dispose);
      _sink.clear();

      final reloading = client.reload();
      await _pump();

      final truncating = _emitted('hook:state-snapshot').where((record) {
        final state = record.payload['state'];
        final messages = state is Map ? state['messages'] : null;
        return messages is List &&
            messages.length == 1 &&
            (messages.single as Map)['id'] == 'msg-user';
      }).toList();
      expect(truncating, isNotEmpty);

      await manual.controller.close();
      await reloading;
    });

    test('emits snapshots for manual messages, hydration and reload', () async {
      final client = _client(
        hydrate: (threadId, options) async => ChatHydrationResult(
          messages: <AssistantTurn>[
            _user('hydrated-user', 'loaded'),
            _assistantText('hydrated-assistant', 'loaded'),
          ],
        ),
      );
      addTearDown(client.dispose);
      _sink.clear();

      client.setMessagesManually(<AssistantTurn>[_user('manual', 'manual')]);
      var state = _payload('hook:state-snapshot')['state'] as Map;
      expect(((state['messages'] as List).single as Map)['id'], 'manual');

      await client.attach();
      state = _payload('hook:state-snapshot')['state'] as Map;
      expect(((state['messages'] as List).last as Map)['id'],
          'hydrated-assistant');

      final pending = client.reload();
      await _pump();
      expect(_emitted('hook:state-snapshot'), isNotEmpty);
      await client.stop();
      await pending;
    });

    test('sends live snapshots of a child agent, not the live handle',
        () async {
      final manual = _ManualConnection();
      final client = _client(connection: manual.adapter);
      addTearDown(client.dispose);
      _sink.clear();

      final sending = client.sendMessage('research');
      await _waitFor(() => manual.contexts.isNotEmpty);
      manual.controller.add({
        'type': 'RUN_STARTED',
        'threadId': 'thread-1',
        'runId': 'run-1',
      });
      manual.controller.add({
        'type': 'SUBAGENT_STARTED',
        'subagentRunId': 'sub-1',
        'name': 'researcher',
      });
      manual.controller.add({
        'type': 'TEXT_MESSAGE_START',
        'messageId': 'child-msg',
        'role': 'assistant',
        'subagentRunId': 'sub-1',
      });
      manual.controller.add({
        'type': 'TEXT_MESSAGE_CONTENT',
        'messageId': 'child-msg',
        'delta': 'notes',
        'subagentRunId': 'sub-1',
      });
      await _waitFor(() {
        final part = _subagentPart('sub-1');
        return part != null && part['status'] == 'running';
      });
      final running = _subagentPart('sub-1');
      expect(running!['messages'], isNotEmpty);
      expect(
        ((running['messages'] as List).first as Map)['parts'],
        <Map<String, dynamic>>[
          {'type': 'text', 'content': 'notes'},
        ],
      );

      manual.controller.add({
        'type': 'SUBAGENT_FINISHED',
        'subagentRunId': 'sub-1',
      });
      manual.controller.add({
        'type': 'RUN_FINISHED',
        'threadId': 'thread-1',
        'runId': 'run-1',
        'outcome': {'type': 'success'},
      });
      await manual.controller.close();
      await sending;

      await _waitFor(() {
        final part = _subagentPart('sub-1');
        return part != null && part['status'] == 'finished';
      });
      expect(running['status'], 'running');
      expect(
        identical(running, client.getSubagents().single.data),
        isFalse,
      );
    });

    test('emits chat run lifecycle events for hook run tracking', () async {
      final contexts = <RunAgentInputContext>[];
      final client = _client(
        connection: _adapter(<List<Map<String, dynamic>>>[
          _textChunks('tracked', messageId: 'msg-run')
        ], contexts: contexts),
      );
      addTearDown(client.dispose);
      _sink.clear();

      await client.sendMessage('start');

      expect(contexts, isNotEmpty);
      final runId = contexts.first.runId;
      final created = _emitted('run:created');
      final started = _emitted('run:started');
      final completed = _emitted('run:completed');
      expect(created, hasLength(1));
      expect(started, hasLength(1));
      expect(completed, hasLength(1));
      for (final record in <AIDevtoolsEventRecord>[
        created.single,
        started.single,
        completed.single,
      ]) {
        expect(record.payload['hookId'], 'thread-1');
        expect(record.payload['threadId'], 'thread-1');
        expect(record.payload['runId'], runId);
      }
      expect(created.single.payload['status'], 'created');
      expect(started.single.payload['status'], 'started');
      expect(completed.single.payload['status'], 'completed');
    });

    test('links streamed text and tool events to the current run context',
        () async {
      final contexts = <RunAgentInputContext>[];
      final client = _client(
        connection: _adapter(<List<Map<String, dynamic>>>[
          <Map<String, dynamic>>[
            {
              'type': 'TEXT_MESSAGE_CONTENT',
              'messageId': 'msg-text',
              'delta': 'h',
            },
            {
              'type': 'TEXT_MESSAGE_CONTENT',
              'messageId': 'msg-text',
              'delta': 'i',
            },
            ..._toolChunks(
              messageId: 'msg-tool',
              includeRunStarted: false,
            ),
          ]
        ], contexts: contexts),
      );
      addTearDown(client.dispose);
      _sink.clear();

      await client.sendMessage('start');

      expect(contexts, isNotEmpty);
      final text = _payload('text:chunk:content');
      expect(text['threadId'], contexts.first.threadId);
      expect(text['runId'], contexts.first.runId);
      final tool = _payload('tools:call:updated');
      expect(tool['threadId'], contexts.first.threadId);
      expect(tool['runId'], contexts.first.runId);
      expect(tool['toolCallId'], 'tool-1');
    });

    test('uses stream lifecycle run ids when the server emits them', () async {
      final contexts = <RunAgentInputContext>[];
      final client = _client(
        connection: _adapter(<List<Map<String, dynamic>>>[
          <Map<String, dynamic>>[
            {
              'type': 'RUN_STARTED',
              'threadId': 'server-thread',
              'runId': 'server-run',
            },
            {
              'type': 'TEXT_MESSAGE_CONTENT',
              'messageId': 'msg-server',
              'delta': 's',
            },
            {
              'type': 'RUN_FINISHED',
              'threadId': 'server-thread',
              'runId': 'server-run',
            },
          ]
        ], contexts: contexts),
      );
      addTearDown(client.dispose);
      _sink.clear();

      await client.sendMessage('start');

      expect(contexts.first.runId, isNot('server-run'));
      final text = _payload('text:chunk:content');
      expect(text['threadId'], 'server-thread');
      expect(text['runId'], 'server-run');
      expect(text['messageId'], 'msg-server');
    });

    test(
        'emits structured output updates and snapshots streamed structured parts',
        () async {
      final contexts = <RunAgentInputContext>[];
      final finalObject = <String, dynamic>{'title': 'Pasta', 'servings': 2};
      final client = _client(
        connection: _adapter(<List<Map<String, dynamic>>>[
          <Map<String, dynamic>>[
            {
              'type': 'CUSTOM',
              'metadata': {
                'tanstack': {'model': 'test'}
              },
              'name': 'structured-output.start',
              'value': {'messageId': 'msg-structured'},
            },
            {
              'type': 'TEXT_MESSAGE_CONTENT',
              'messageId': 'msg-structured',
              'delta': '{"title":"Pasta"',
            },
            {
              'type': 'TEXT_MESSAGE_CONTENT',
              'messageId': 'msg-structured',
              'delta': ',"servings":2}',
            },
            {
              'type': 'CUSTOM',
              'metadata': {
                'tanstack': {'model': 'test'}
              },
              'name': 'structured-output.complete',
              'value': {
                'object': finalObject,
                'raw': '{"title":"Pasta","servings":2}',
                'messageId': 'msg-structured',
              },
            },
          ]
        ], contexts: contexts),
      );
      addTearDown(client.dispose);
      _sink.clear();

      await client.sendMessage('make recipe');

      final started = _emitted('structured-output:started');
      final updated = _emitted('structured-output:updated');
      final completed = _emitted('structured-output:completed');
      expect(started, hasLength(1));
      expect(updated, isNotEmpty);
      expect(completed, hasLength(1));
      expect(started.single.payload['hookId'], 'thread-1');
      expect(started.single.payload['clientId'], 'thread-1');
      expect(started.single.payload['threadId'], contexts.first.threadId);
      expect(started.single.payload['runId'], contexts.first.runId);
      expect(started.single.payload['messageId'], 'msg-structured');
      expect(started.single.payload['status'], 'streaming');
      expect(
        updated.map((record) => record.payload['raw']),
        contains('{"title":"Pasta","servings":2}'),
      );
      final lastUpdate = updated.last.payload;
      expect(lastUpdate['status'], 'streaming');
      expect(lastUpdate['partial'], finalObject);
      expect(completed.single.payload['status'], 'complete');
      expect(completed.single.payload['raw'], '{"title":"Pasta","servings":2}');
      expect(completed.single.payload['data'], finalObject);

      final part = _findStructuredPart('msg-structured');
      expect(part, isNotNull);
      expect(part!['status'], 'complete');
      expect(part['raw'], '{"title":"Pasta","servings":2}');
      expect(part['data'], finalObject);
      expect(part['partial'], finalObject);
    });

    test(
        're-emits memory:* devtools events from a transported memory:state CUSTOM chunk',
        () async {
      final contexts = <RunAgentInputContext>[];
      final client = _client(
        connection: _adapter(<List<Map<String, dynamic>>>[
          <Map<String, dynamic>>[
            {'type': 'RUN_STARTED', 'threadId': 'thread-1', 'runId': 'run-mem'},
            {
              'type': 'CUSTOM',
              'metadata': {
                'tanstack': {'model': 'test'}
              },
              'name': 'memory:state',
              'value': {
                'scope': {'threadId': 'sess-1'},
                'adapter': 'in-memory',
                'query': 'what is my name?',
                'recall': {
                  'fragmentCount': 2,
                  'hasTools': false,
                  'systemPromptChars': 96,
                  'durationMs': 4,
                },
                'snapshot': {
                  'takenAt': '2026-07-22T00:00:00.000Z',
                  'data': {
                    'records': [
                      {'id': 'r1', 'text': 'name is Jack', 'kind': 'message'}
                    ],
                  },
                  'facts': [
                    {'id': 'r1', 'text': 'name is Jack', 'source': 'user'}
                  ],
                },
              },
            },
            {
              'type': 'TEXT_MESSAGE_CONTENT',
              'messageId': 'msg-mem',
              'delta': 'Your name is Jack',
            },
            {
              'type': 'RUN_FINISHED',
              'threadId': 'thread-1',
              'runId': 'run-mem'
            },
          ]
        ], contexts: contexts),
      );
      addTearDown(client.dispose);
      _sink.clear();

      await client.sendMessage('what is my name?');
      await _waitFor(() => _emitted('memory:snapshot').isNotEmpty);

      final started = _payload('memory:retrieve:started');
      expect(started['scope'], {'threadId': 'sess-1'});
      expect(started['adapter'], 'in-memory');
      expect(started['query'], 'what is my name?');
      final completed = _payload('memory:retrieve:completed');
      expect(completed['adapter'], 'in-memory');
      expect(completed['fragmentCount'], 2);
      expect(completed['hasTools'], false);
      expect(completed['systemPromptChars'], 96);
      expect(completed['durationMs'], 4);
      final snapshot = _payload('memory:snapshot');
      expect(snapshot['adapter'], 'in-memory');
      expect(snapshot['takenAt'], '2026-07-22T00:00:00.000Z');
      expect(snapshot['facts'], [
        {'id': 'r1', 'text': 'name is Jack', 'source': 'user'}
      ]);

      _sink.clear();
      _sink.dispatch('devtools:request-state', <String, dynamic>{});
      await _waitFor(() => _emitted('memory:snapshot').isNotEmpty);
      expect(_payload('memory:retrieve:completed')['fragmentCount'], 2);
    });

    test(
        're-emits compaction started, state, and ended from transported CUSTOM chunks',
        () async {
      final contexts = <RunAgentInputContext>[];
      final client = _client(
        connection: _adapter(<List<Map<String, dynamic>>>[
          <Map<String, dynamic>>[
            {'type': 'RUN_STARTED', 'threadId': 'thread-1', 'runId': 'run-cmp'},
            {
              'type': 'CUSTOM',
              'metadata': {
                'tanstack': {'model': 'test'}
              },
              'name': 'compaction:started',
              'value': {
                'before': 400,
                'messagesBefore': 8,
                'reusedCheckpoint': false,
                'maxTokens': 400,
                'strategyKey': 'evict-oldest:half:maxTokens=400',
              },
            },
            {
              'type': 'CUSTOM',
              'metadata': {
                'tanstack': {'model': 'test'}
              },
              'name': 'compaction:state',
              'value': {
                'before': 400,
                'after': 180,
                'messagesBefore': 8,
                'messagesAfter': 3,
                'reusedCheckpoint': false,
                'maxTokens': 400,
                'strategyKey': 'evict-oldest:half:maxTokens=400',
                'dropped': [
                  {'role': 'user', 'tokens': 40, 'text': 'old turn'}
                ],
                'result': [
                  {'role': 'user', 'tokens': 10, 'text': 'omitted'}
                ],
              },
            },
            {
              'type': 'CUSTOM',
              'metadata': {
                'tanstack': {'model': 'test'}
              },
              'name': 'compaction:ended',
              'value': {
                'after': 180,
                'messagesAfter': 3,
                'reusedCheckpoint': false,
                'maxTokens': 400,
                'durationMs': 12,
                'strategyKey': 'evict-oldest:half:maxTokens=400',
              },
            },
            {
              'type': 'TEXT_MESSAGE_CONTENT',
              'messageId': 'msg-cmp',
              'delta': 'ok',
            },
            {
              'type': 'RUN_FINISHED',
              'threadId': 'thread-1',
              'runId': 'run-cmp'
            },
          ]
        ], contexts: contexts),
      );
      addTearDown(client.dispose);
      _sink.clear();

      await client.sendMessage('keep going');
      await _waitFor(() => _emitted('compaction:ended').isNotEmpty);

      final started = _payload('compaction:started');
      expect(started['before'], 400);
      expect(started['messagesBefore'], 8);
      expect(started['reusedCheckpoint'], false);
      expect(started['maxTokens'], 400);
      final state = _payload('compaction:state');
      expect(state['before'], 400);
      expect(state['after'], 180);
      expect(state['messagesBefore'], 8);
      expect(state['messagesAfter'], 3);
      expect(state['strategyKey'], 'evict-oldest:half:maxTokens=400');
      expect(state['dropped'], [
        {'role': 'user', 'tokens': 40, 'text': 'old turn'}
      ]);
      expect(state['result'], [
        {'role': 'user', 'tokens': 10, 'text': 'omitted'}
      ]);
      final ended = _payload('compaction:ended');
      expect(ended['after'], 180);
      expect(ended['messagesAfter'], 3);
      expect(ended['durationMs'], 12);

      _sink.clear();
      _sink.dispatch('devtools:request-state', <String, dynamic>{});
      await _waitFor(() => _emitted('compaction:ended').isNotEmpty);
      expect(_payload('compaction:started')['before'], 400);
      expect(_payload('compaction:state')['after'], 180);
      expect(_payload('compaction:ended')['durationMs'], 12);
    });

    test(
        're-emits skills:snapshot from a transported skills:state CUSTOM chunk',
        () async {
      final contexts = <RunAgentInputContext>[];
      final client = _client(
        connection: _adapter(<List<Map<String, dynamic>>>[
          <Map<String, dynamic>>[
            {
              'type': 'RUN_STARTED',
              'threadId': 'thread-1',
              'runId': 'run-skills'
            },
            {
              'type': 'CUSTOM',
              'metadata': {
                'tanstack': {'model': 'test'}
              },
              'name': 'skills:state',
              'value': {
                'catalog': [
                  {
                    'name': 'pirate-speak',
                    'description': 'talk like a pirate',
                  }
                ],
                'activated': <Object?>[],
              },
            },
            {
              'type': 'TEXT_MESSAGE_CONTENT',
              'messageId': 'msg-skills',
              'delta': 'Ahoy',
            },
            {
              'type': 'RUN_FINISHED',
              'threadId': 'thread-1',
              'runId': 'run-skills'
            },
          ]
        ], contexts: contexts),
      );
      addTearDown(client.dispose);
      _sink.clear();

      await client.sendMessage('talk like a pirate');
      await _waitFor(() => _emitted('skills:snapshot').isNotEmpty);

      final snapshot = _payload('skills:snapshot');
      expect(snapshot['catalog'], [
        {'name': 'pirate-speak', 'description': 'talk like a pirate'}
      ]);
      expect(snapshot['activated'], isEmpty);

      _sink.clear();
      _sink.dispatch('devtools:request-state', <String, dynamic>{});
      await _waitFor(() => _emitted('skills:snapshot').isNotEmpty);
      expect((_payload('skills:snapshot')['catalog'] as List).single, {
        'name': 'pirate-speak',
        'description': 'talk like a pirate',
      });
    });

    test('batches structured output update events while preserving final state',
        () async {
      final contexts = <RunAgentInputContext>[];
      final finalObject = <String, dynamic>{'title': 'Pasta', 'servings': 2};
      final raw = jsonEncode(finalObject);
      final chunks = <Map<String, dynamic>>[
        {
          'type': 'CUSTOM',
          'metadata': {
            'tanstack': {'model': 'test'}
          },
          'name': 'structured-output.start',
          'value': {'messageId': 'msg-structured-batched'},
        },
        for (final character in raw.split(''))
          {
            'type': 'TEXT_MESSAGE_CONTENT',
            'messageId': 'msg-structured-batched',
            'delta': character,
          },
        {
          'type': 'CUSTOM',
          'metadata': {
            'tanstack': {'model': 'test'}
          },
          'name': 'structured-output.complete',
          'value': {
            'object': finalObject,
            'raw': raw,
            'messageId': 'msg-structured-batched',
          },
        },
      ];
      final client = _client(
        connection:
            _adapter(<List<Map<String, dynamic>>>[chunks], contexts: contexts),
      );
      addTearDown(client.dispose);
      _sink.clear();

      await client.sendMessage('make recipe');

      final updates = _emitted('structured-output:updated');
      expect(updates, hasLength(3));
      expect(updates[0].payload['raw'], raw.substring(0, 12));
      expect(updates[0].payload['delta'], raw.substring(0, 12));
      expect(updates[1].payload['raw'], raw.substring(0, 24));
      expect(updates[1].payload['delta'], raw.substring(12, 24));
      expect(updates[2].payload['raw'], raw);
      expect(updates[2].payload['delta'], raw.substring(24));
      expect(updates[2].payload['partial'], finalObject);
      final completed = _payload('structured-output:completed');
      expect(completed['status'], 'complete');
      expect(completed['raw'], raw);
      expect(completed['data'], finalObject);

      final part = _findStructuredPart('msg-structured-batched');
      expect(part, isNotNull);
      expect(part!['status'], 'complete');
      expect(part['raw'], raw);
      expect(part['data'], finalObject);
      expect(part['partial'], finalObject);
    });

    test('emits structured output completion without streamed deltas',
        () async {
      final contexts = <RunAgentInputContext>[];
      final finalObject = <String, dynamic>{'title': 'Risotto', 'servings': 4};
      final client = _client(
        connection: _adapter(<List<Map<String, dynamic>>>[
          <Map<String, dynamic>>[
            {
              'type': 'CUSTOM',
              'metadata': {
                'tanstack': {'model': 'test'}
              },
              'name': 'structured-output.start',
              'value': {'messageId': 'msg-structured-terminal'},
            },
            {
              'type': 'CUSTOM',
              'metadata': {
                'tanstack': {'model': 'test'}
              },
              'name': 'structured-output.complete',
              'value': {
                'object': finalObject,
                'messageId': 'msg-structured-terminal',
              },
            },
          ]
        ], contexts: contexts),
      );
      addTearDown(client.dispose);
      _sink.clear();

      await client.sendMessage('make risotto');

      final completed = _payload('structured-output:completed');
      expect(completed['hookId'], 'thread-1');
      expect(completed['clientId'], 'thread-1');
      expect(completed['threadId'], contexts.first.threadId);
      expect(completed['runId'], contexts.first.runId);
      expect(completed['messageId'], 'msg-structured-terminal');
      expect(completed['status'], 'complete');
      expect(completed['raw'], jsonEncode(finalObject));
      expect(completed['data'], finalObject);

      final part = _findStructuredPart('msg-structured-terminal');
      expect(part, isNotNull);
      expect(part!['status'], 'complete');
      expect(part['raw'], jsonEncode(finalObject));
      expect(part['data'], finalObject);
      expect(part['partial'], finalObject);
    });

    test('preserves structured output parts across multiple chat turns',
        () async {
      final contexts = <RunAgentInputContext>[];
      final firstObject = <String, dynamic>{'title': 'Pasta', 'servings': 2};
      final secondObject = <String, dynamic>{'title': 'Soup', 'servings': 3};
      final client = _client(
        connection: _adapter(<List<Map<String, dynamic>>>[
          <Map<String, dynamic>>[
            {
              'type': 'CUSTOM',
              'metadata': {
                'tanstack': {'model': 'test'}
              },
              'name': 'structured-output.start',
              'value': {'messageId': 'msg-structured-first'},
            },
            {
              'type': 'CUSTOM',
              'metadata': {
                'tanstack': {'model': 'test'}
              },
              'name': 'structured-output.complete',
              'value': {
                'object': firstObject,
                'messageId': 'msg-structured-first',
              },
            },
          ],
          <Map<String, dynamic>>[
            {
              'type': 'CUSTOM',
              'metadata': {
                'tanstack': {'model': 'test'}
              },
              'name': 'structured-output.start',
              'value': {'messageId': 'msg-structured-second'},
            },
            {
              'type': 'TEXT_MESSAGE_CONTENT',
              'messageId': 'msg-structured-second',
              'delta': '{"title":"Soup","servings":3}',
            },
            {
              'type': 'CUSTOM',
              'metadata': {
                'tanstack': {'model': 'test'}
              },
              'name': 'structured-output.complete',
              'value': {
                'object': secondObject,
                'raw': jsonEncode(secondObject),
                'messageId': 'msg-structured-second',
              },
            },
          ],
        ], contexts: contexts),
      );
      addTearDown(client.dispose);
      _sink.clear();

      await client.sendMessage('make pasta');
      await client.sendMessage('make soup');

      final first = _findStructuredPart('msg-structured-first');
      final second = _findStructuredPart('msg-structured-second');
      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(first!['status'], 'complete');
      expect(first['data'], firstObject);
      expect(second!['status'], 'complete');
      expect(second['data'], secondObject);
      expect(_emitted('structured-output:completed'), hasLength(2));
    });

    test('emits approval requests that arrive after run finish', () async {
      final contexts = <RunAgentInputContext>[];
      final client = _client(
        connection: _adapter(<List<Map<String, dynamic>>>[
          <Map<String, dynamic>>[
            ..._toolChunks(
              toolCallId: 'approval-call-1',
              toolName: 'addToCart',
              arguments: '{"guitarId":"6","quantity":1}',
              messageId: 'msg-approval',
              includeRunStarted: false,
            ),
            {
              'type': 'CUSTOM',
              'metadata': {
                'tanstack': {'model': 'test'}
              },
              'name': 'approval-requested',
              'value': {
                'toolCallId': 'approval-call-1',
                'toolName': 'addToCart',
                'input': {'guitarId': '6', 'quantity': 1},
                'approval': {
                  'id': 'approval-approval-call-1',
                  'needsApproval': true,
                },
              },
            },
          ]
        ], contexts: contexts),
      );
      addTearDown(client.dispose);
      _sink.clear();

      await client.sendMessage('add it to cart');
      await _waitFor(() => _emitted('tools:approval:requested').isNotEmpty);

      final requested = _payload('tools:approval:requested');
      expect(requested['hookId'], 'thread-1');
      expect(requested['clientId'], 'thread-1');
      expect(requested['threadId'], contexts.first.threadId);
      expect(requested['runId'], contexts.first.runId);
      expect(requested['streamId'], isNotEmpty);
      expect(requested['messageId'], isNotEmpty);
      expect(requested['toolCallId'], 'approval-call-1');
      expect(requested['toolName'], 'addToCart');
      expect(requested['input'], {'guitarId': '6', 'quantity': 1});
      expect(requested['approvalId'], 'approval-approval-call-1');

      await _waitFor(() {
        final call = _findToolCall('approval-call-1');
        return call != null &&
            call['state'] == 'approval-requested' &&
            (call['approval'] as Map?)?['id'] == 'approval-approval-call-1';
      });
    });

    test('emits approval responses and snapshots the approval decision',
        () async {
      final contexts = <RunAgentInputContext>[];
      final client = _client(
        connection: _adapter(<List<Map<String, dynamic>>>[
          _textChunks('approved', messageId: 'msg-after-approval')
        ], contexts: contexts),
        initialMessages: <AssistantTurn>[
          _user('msg-user', 'Hello'),
          AssistantTurn(
            id: 'msg-approval',
            role: 'assistant',
            parts: <AssistantPart>[
              AssistantPart.tool(
                id: 'approval-call-1',
                name: 'addToCart',
                arguments: '{"guitarId":"6","quantity":1}',
                input: {'guitarId': '6', 'quantity': 1},
                state: 'approval-requested',
                approval: AssistantApproval(
                  id: 'approval-approval-call-1',
                  needsApproval: true,
                ),
              ),
            ],
          ),
        ],
      );
      addTearDown(client.dispose);
      _sink.clear();

      await client.addToolApprovalResponse(
        id: 'approval-approval-call-1',
        approved: true,
      );

      final responded = _payload('tools:approval:responded');
      expect(responded['hookId'], 'thread-1');
      expect(responded['clientId'], 'thread-1');
      expect(responded['toolCallId'], 'approval-call-1');
      expect(responded['approvalId'], 'approval-approval-call-1');
      expect(responded['approved'], true);
      await _waitFor(() {
        final call = _findToolCall('approval-call-1');
        return call != null &&
            call['state'] == 'approval-responded' &&
            (call['approval'] as Map?)?['approved'] == true;
      });
    });

    test(
        'keeps delayed client tool results linked to their original run context',
        () async {
      final toolStarted = Completer<void>();
      final toolOutput = Completer<Object?>();
      final contexts = <RunAgentInputContext>[];
      final client = _client(
        connection: _adapter(<List<Map<String, dynamic>>>[
          _toolChunks(
            toolCallId: 'call-1',
            toolName: 'delayed_tool',
            includeRunStarted: false,
            arguments: '{}',
            messageId: 'msg-1',
          ),
          _textChunks('new run', messageId: 'msg-2'),
        ], contexts: contexts),
        tools: <ClientTool>[
          ClientTool(
            name: 'delayed_tool',
            description: 'Delayed tool',
            execute: (input, ToolCallContext context) {
              if (!toolStarted.isCompleted) toolStarted.complete();
              return toolOutput.future;
            },
          ),
        ],
      );
      addTearDown(client.dispose);
      _sink.clear();

      final firstRun = client.sendMessage('first');
      await toolStarted.future;
      await client.stop();
      final secondRun = client.sendMessage('second');
      await _waitFor(() => contexts.length == 2);

      toolOutput.complete(<String, dynamic>{'ok': true});
      await Future.wait<void>(<Future<void>>[firstRun, secondRun]);

      expect(contexts[0].runId, isNot(contexts[1].runId));
      final added = _emitted('tools:result:added');
      expect(
        added.any((record) =>
            record.payload['runId'] == contexts[0].runId &&
            record.payload['toolCallId'] == 'call-1' &&
            record.payload['toolName'] == 'delayed_tool'),
        isTrue,
      );
      expect(
        added.any((record) =>
            record.payload['runId'] == contexts[1].runId &&
            record.payload['toolCallId'] == 'call-1'),
        isFalse,
      );
    });
  });

  group('ChatClient devtools events', () {
    test('should emit text:message:created event when assistant message starts',
        () async {
      final client = _client(
        connection: _adapter(
            <List<Map<String, dynamic>>>[_textChunks('Hello, world!')]),
      );
      addTearDown(client.dispose);
      _sink.clear();

      await client.sendMessage('Hello');

      expect(
        _emitted('text:message:created')
            .any((record) => record.payload['role'] == 'assistant'),
        isTrue,
      );
    });

    test('should emit text:chunk:content events during streaming', () async {
      final client = _client(
        connection: _adapter(
            <List<Map<String, dynamic>>>[_textChunks('Hello, world!')]),
      );
      addTearDown(client.dispose);
      _sink.clear();

      await client.sendMessage('Hello');

      expect(_emitted('text:chunk:content').length, greaterThan(0));
    });

    test('should emit tools:call:updated events for tool calls', () async {
      final client = _client(
        connection: _adapter(<List<Map<String, dynamic>>>[_toolChunks()]),
      );
      addTearDown(client.dispose);
      _sink.clear();

      await client.sendMessage('What is the weather?');

      expect(_emitted('tools:call:updated').length, greaterThan(0));
    });

    test('should emit text:chunk:thinking events for thinking content',
        () async {
      final client = _client(
        connection: _adapter(<List<Map<String, dynamic>>>[
          <Map<String, dynamic>>[
            for (final char in 'Let me think...'.split(''))
              {
                'type': 'REASONING_MESSAGE_CONTENT',
                'messageId': 'reasoning-msg-1',
                'delta': char,
              },
            for (final char in 'Here is my answer'.split(''))
              {
                'type': 'TEXT_MESSAGE_CONTENT',
                'messageId': 'msg-1',
                'delta': char,
              },
            {
              'type': 'RUN_FINISHED',
              'threadId': 'thread-msg-1',
              'runId': 'run-msg-1',
            },
          ]
        ]),
      );
      addTearDown(client.dispose);
      _sink.clear();

      await client.sendMessage('Hello');

      expect(_emitted('text:chunk:thinking').length, greaterThan(0));
    });
  });

  group('createChatDevtoolsBridge by environment', () {
    test('emits no devtools events in production', () async {
      final client = _client(
        connection:
            _adapter(<List<Map<String, dynamic>>>[_textChunks('Hi there')]),
        factory: (options) =>
            createChatDevtoolsBridge(options, production: true),
      );
      addTearDown(client.dispose);

      await client.sendMessage('hello');

      expect(_sink.events, isEmpty);
    });

    test('emits devtools events in development', () async {
      final client = _client(
        connection:
            _adapter(<List<Map<String, dynamic>>>[_textChunks('Hi there')]),
        factory: (options) =>
            createChatDevtoolsBridge(options, production: false),
      );
      addTearDown(client.dispose);

      await client.sendMessage('hello');

      expect(_sink.events, isNotEmpty);
    });

    test('does not throw when there is no process global', () {
      expect(
        () => ChatClient(
          connection: _adapter(const []),
          devtools: const AIDevtoolsClientMetadata(hookName: 'useChat'),
          devtoolsBridgeFactory: (options) =>
              createChatDevtoolsBridge(options, production: false),
        ),
        returnsNormally,
      );
    });
  });

  group('ChatClient with default no-op devtools bridge', () {
    test('sends the first message and appends it', () async {
      final client = ChatClient(
        connection:
            _adapter(<List<Map<String, dynamic>>>[_textChunks('Hi there')]),
      );
      addTearDown(client.dispose);

      await client.sendMessage('hello');

      final messages = client.getMessages();
      expect(messages.first.role, 'user');
      expect(messages.first.parts.single.type, 'text');
      expect(messages.first.parts.single.content, 'hello');
      expect(messages.last.role, 'assistant');
    });

    test('updates tools without throwing', () {
      final client = ChatClient(connection: _adapter(const []));
      addTearDown(client.dispose);

      expect(
        () => (client as dynamic).updateOptions(tools: <ClientTool>[]),
        returnsNormally,
      );
    });
  });
}

Map<String, dynamic> _fixtureMap({
  String? hookId = 'thread-1',
  String? threadId = 'thread-1',
  String? runId = 'run-fixture',
  String toolName = 'weather',
  Object? input = const <String, dynamic>{'city': 'Paris'},
  Object? output = const <String, dynamic>{'temperature': 21},
  bool? execute,
  String? toolCallId = 'fixture-call',
  String? messageId = 'fixture-message',
  String? errorText,
  Map<String, dynamic>? message,
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

Map<String, dynamic>? _subagentPart(String id) {
  for (final message in _latestMessages()) {
    final parts = message['parts'];
    if (parts is! List) continue;
    for (final part in parts.whereType<Map>()) {
      if (part['type'] == 'subagent' &&
          (part['subagent'] as Map?)?['id'] == id) {
        return (part['subagent'] as Map)
            .map((key, value) => MapEntry('$key', value));
      }
    }
  }
  return null;
}
