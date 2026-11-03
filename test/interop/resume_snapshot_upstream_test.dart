// Faithful runtime port of
// packages/ai-client/tests/resume-snapshot.test.ts (TanStack AI 0.40.0).
//
// The upstream file has 23 cases. This fixture exercises the real Dart
// ChatClient, ChatPersistor, normalizeConnectionAdapter and storage adapters
// with connection adapters and async streams; it does not substitute
// FakeChatTransport.
import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart' as chat;
import 'package:tanstack_ai_dart/connections.dart' as conn;
import 'package:tanstack_ai_dart/platform.dart' as platform;
import 'package:test/test.dart';

Map<String, dynamic> uiMessage(
  String id,
  String content, [
  String role = 'assistant',
]) {
  return <String, dynamic>{
    'id': id,
    'role': role,
    'parts': <Map<String, dynamic>>[
      <String, dynamic>{'type': 'text', 'content': content},
    ],
    'createdAt': '2026-01-01T00:00:00.000Z',
  };
}

List<Map<String, dynamic>> runChunks(
  String runId,
  String threadId, {
  String text = 'world',
  String messageId = 'assistant-1',
}) {
  return <Map<String, dynamic>>[
    <String, dynamic>{
      'type': 'RUN_STARTED',
      'runId': runId,
      'threadId': threadId,
      'timestamp': 1,
    },
    <String, dynamic>{
      'type': 'TEXT_MESSAGE_START',
      'messageId': messageId,
      'role': 'assistant',
      'timestamp': 2,
    },
    <String, dynamic>{
      'type': 'TEXT_MESSAGE_CONTENT',
      'messageId': messageId,
      'delta': text,
      'content': text,
      'timestamp': 3,
    },
    <String, dynamic>{
      'type': 'TEXT_MESSAGE_END',
      'messageId': messageId,
      'timestamp': 4,
    },
    <String, dynamic>{
      'type': 'RUN_FINISHED',
      'runId': runId,
      'threadId': threadId,
      'timestamp': 5,
      'metadata': <String, dynamic>{
        'tanstack': <String, dynamic>{'finishReason': 'stop'},
      },
    },
  ];
}

chat.AssistantTurn? lastAssistant(List<chat.AssistantTurn> messages) {
  for (var index = messages.length - 1; index >= 0; index--) {
    if (messages[index].role == 'assistant') return messages[index];
  }
  return null;
}

String textOf(chat.AssistantTurn? turn) {
  if (turn == null) return '';
  return turn.parts
      .where((part) => part.type == 'text')
      .map((part) => part.content)
      .join();
}

Future<void> pump([int turns = 8]) async {
  for (var turn = 0; turn < turns; turn++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> waitFor(bool Function() condition, {int tries = 300}) async {
  for (var attempt = 0; attempt < tries; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('condition was not met');
}

Future<void> waitForAsync(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition was not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class MemoryAdapter implements platform.ChatClientPersistence {
  Object? value;

  MemoryAdapter([this.value]);

  @override
  FutureOr<Object?> getItem(String id) => value;

  @override
  FutureOr<void> setItem(String id, platform.ChatPersistedState state) {
    value = state;
  }

  @override
  FutureOr<void> removeItem(String id) {
    value = null;
  }
}

class AsyncMemoryAdapter implements platform.ChatClientPersistence {
  Object? value;

  AsyncMemoryAdapter(this.value);

  @override
  Future<Object?> getItem(String id) async => value;

  @override
  Future<void> setItem(String id, platform.ChatPersistedState state) async {
    value = state;
  }

  @override
  Future<void> removeItem(String id) async {
    value = null;
  }
}

class MemoryWebStorage implements platform.WebStorage {
  final Map<String, String> values = <String, String>{};

  @override
  String? getItem(String key) => values[key];

  @override
  void setItem(String key, String value) {
    values[key] = value;
  }

  @override
  void removeItem(String key) {
    values.remove(key);
  }
}

class MemoryWebStorageProvider implements platform.WebStorageProvider {
  final MemoryWebStorage storage = MemoryWebStorage();

  @override
  platform.WebStorage? get localStorage => storage;

  @override
  platform.WebStorage? get sessionStorage => null;
}

Map<String, dynamic> genericPendingInterrupt(String id, String runId) {
  return <String, dynamic>{
    'id': id,
    'reason': 'confirmation',
    'metadata': <String, dynamic>{
      'tanstack:interruptBinding': <String, dynamic>{
        'v': 1,
        'kind': 'generic',
        'interruptId': id,
        'interruptedRunId': runId,
        'generation': 1,
        'responseSchemaHash': 'none',
      },
    },
  };
}

Map<String, dynamic> clientToolPendingInterrupt({
  required String id,
  required String runId,
  required String toolName,
  required String toolCallId,
  required String outputSchemaHash,
}) {
  return <String, dynamic>{
    'id': id,
    'reason': 'tanstack:client_tool_execution',
    'toolCallId': toolCallId,
    'metadata': <String, dynamic>{
      'tanstack:interruptBinding': <String, dynamic>{
        'v': 1,
        'kind': 'client-tool-execution',
        'interruptId': id,
        'interruptedRunId': runId,
        'generation': 1,
        'toolName': toolName,
        'toolCallId': toolCallId,
        'outputSchemaHash': outputSchemaHash,
        'responseSchemaHash': outputSchemaHash,
      },
    },
  };
}

void main() {
  group('ChatPersistor combined record', () {
    test('writes messages and resume snapshot as one record', () async {
      final adapter = MemoryAdapter();
      final persistor = platform.ChatPersistor(adapter, 'chat-1', (_) {});

      persistor.notifyMessagesChanged(<Map<String, dynamic>>[
        uiMessage('m1', 'hello'),
      ]);
      persistor.persistResumeSnapshot(
        platform.ChatResumeSnapshot(
          resumeState: const platform.ChatResumeState(
            threadId: 't1',
            runId: 'r1',
          ),
        ),
      );
      await pump();

      final stored = adapter.value;
      expect(stored, isA<platform.ChatPersistedState>());
      final state = stored as platform.ChatPersistedState;
      expect(state.messages, hasLength(1));
      expect(state.resume?.resumeState.runId, 'r1');
    });

    test('clears the resume snapshot but keeps messages', () async {
      final adapter = MemoryAdapter();
      final persistor = platform.ChatPersistor(adapter, 'chat-1', (_) {});
      persistor.notifyMessagesChanged(<Map<String, dynamic>>[
        uiMessage('m1', 'hello'),
      ]);
      persistor.persistResumeSnapshot(
        platform.ChatResumeSnapshot(
          resumeState: const platform.ChatResumeState(
            threadId: 't1',
            runId: 'r1',
          ),
        ),
      );
      persistor.persistResumeSnapshot(null);
      await pump();

      final stored = adapter.value;
      expect(stored, isA<platform.ChatPersistedState>());
      final state = stored as platform.ChatPersistedState;
      expect(state.messages, hasLength(1));
      expect(state.resume, isNull);
    });

    test('normalizes a legacy bare-array record on read', () {
      final applied = <List<Map<String, dynamic>>>[];
      final adapter = MemoryAdapter(<Map<String, dynamic>>[
        uiMessage('m1', 'legacy'),
      ]);
      final persistor = platform.ChatPersistor(
        adapter,
        'chat-1',
        applied.add,
      );

      final read = persistor.readInitial();
      expect(read, isA<platform.ChatPersistedState>());
      final state = read as platform.ChatPersistedState;
      expect(state.messages.first['id'], 'm1');
      expect(state.resume, isNull);
    });
  });

  group('localStoragePersistence ergonomics', () {
    test('needs no type arg or codec and round-trips a ChatPersistedState',
        () async {
      final provider = MemoryWebStorageProvider();
      final store = platform.localStoragePersistence(provider: provider);
      final record = platform.ChatPersistedState(
        messages: <Map<String, dynamic>>[uiMessage('m1', 'hi')],
        resume: platform.ChatResumeSnapshot(
          resumeState: const platform.ChatResumeState(
            threadId: 't1',
            runId: 'r1',
          ),
        ),
      );

      await store.setItem('chat-1', record);
      final read = await store.getItem('chat-1');

      expect(read, isA<platform.ChatPersistedState>());
      expect(read!.messages.first['id'], 'm1');
      expect(read.resume?.resumeState.runId, 'r1');
    });
  });

  group('normalizeConnectionAdapter joinRun passthrough', () {
    Stream<Map<String, dynamic>> emptyStream(
      String runId, {
      conn.CancellationSignal? signal,
    }) async* {}

    test('exposes joinRun when the connection is resumable', () {
      final resumable = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {},
        joinRun: emptyStream,
      );
      final normalized = conn.normalizeConnectionAdapter(resumable);
      expect(normalized.joinRun, isNotNull);
    });

    test('omits joinRun for a plain connect adapter', () {
      final normalized = conn.normalizeConnectionAdapter(
        conn.ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {},
        ),
      );
      expect(normalized.joinRun, isNull);
    });

    test('omits joinRun when the property is present but not a function', () {
      // Dart's typed `joinRun` field cannot hold a non-function value, so the
      // upstream `joinRun: undefined` case collapses to an omitted joinRun.
      final normalized = conn.normalizeConnectionAdapter(
        conn.ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {},
          joinRun: null,
        ),
      );
      expect(normalized.joinRun, isNull);
    });
  });

  group('ChatClient auto-rejoin after reload', () {
    test('rejoins a persisted in-flight run via joinRun', () async {
      final adapter = MemoryAdapter(
        platform.ChatPersistedState(
          messages: <Map<String, dynamic>>[
            uiMessage('user-1', 'hi', 'user'),
          ],
          resume: platform.ChatResumeSnapshot(
            resumeState: const platform.ChatResumeState(
              threadId: 't1',
              runId: 'r1',
            ),
          ),
        ),
      );
      final joinIds = <String>[];
      var connectCalls = 0;
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {
          connectCalls += 1;
        },
        joinRun: (runId, {signal}) async* {
          joinIds.add(runId);
          yield* Stream<Map<String, dynamic>>.fromIterable(
            runChunks(runId, 't1'),
          );
        },
      );
      var latest = <chat.AssistantTurn>[];
      final client = chat.ChatClient(
        threadId: 't1',
        connection: connection,
        persistence: adapter,
        onMessagesChange: (messages) =>
            latest = List<chat.AssistantTurn>.of(messages),
      );
      addTearDown(client.dispose);

      expect(connectCalls, 0);
      expect(joinIds, isEmpty);

      await client.attach();
      await waitFor(() => textOf(lastAssistant(latest)) == 'world');

      expect(joinIds, <String>['r1']);
      expect(latest.any((message) => message.id == 'user-1'), isTrue);
      expect(connectCalls, 0);

      // Wrapper mounts are idempotent: a second attach must not rejoin.
      await client.attach();
      expect(joinIds, <String>['r1']);
    });

    test('drops the hydrated assistant when the rejoin stream is chunk events',
        () async {
      final adapter = MemoryAdapter(
        platform.ChatPersistedState(
          messages: <Map<String, dynamic>>[
            uiMessage('user-1', 'hi', 'user'),
            uiMessage('partial-1', 'old', 'assistant'),
          ],
          resume: platform.ChatResumeSnapshot(
            resumeState: const platform.ChatResumeState(
              threadId: 't1',
              runId: 'r1',
            ),
          ),
        ),
      );
      final joinIds = <String>[];
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {},
        joinRun: (runId, {signal}) async* {
          joinIds.add(runId);
          yield <String, dynamic>{
            'type': 'RUN_STARTED',
            'runId': 'r1',
            'threadId': 't1',
            'timestamp': 1,
          };
          yield <String, dynamic>{
            'type': 'TEXT_MESSAGE_CHUNK',
            'messageId': 'assistant-1',
            'delta': 'world',
            'timestamp': 2,
          };
          yield <String, dynamic>{
            'type': 'RUN_FINISHED',
            'runId': 'r1',
            'threadId': 't1',
            'timestamp': 3,
            'metadata': <String, dynamic>{
              'tanstack': <String, dynamic>{'finishReason': 'stop'},
            },
          };
        },
      );
      var latest = <chat.AssistantTurn>[];
      final client = chat.ChatClient(
        threadId: 't1',
        connection: connection,
        persistence: adapter,
        onMessagesChange: (messages) =>
            latest = List<chat.AssistantTurn>.of(messages),
      );
      addTearDown(client.dispose);

      await client.attach();
      await waitFor(() {
        final assistant =
            latest.where((message) => message.id == 'assistant-1');
        return assistant.isNotEmpty && textOf(assistant.first) == 'world';
      });

      expect(latest.any((message) => message.id == 'partial-1'), isFalse);
      expect(latest.any((message) => message.id == 'user-1'), isTrue);
      expect(joinIds, <String>['r1']);
    });

    test('applies a replay in one batch without yielding', () async {
      var schedulerYields = 0;
      var time = 0;
      final scheduler = chat.StreamProcessingScheduler(
        now: () {
          time += 9;
          return time;
        },
        isHidden: () => false,
        yieldToHost: () async {
          schedulerYields += 1;
        },
      );
      final joinIds = <String>[];
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {},
        joinRun: (runId, {signal}) async* {
          joinIds.add(runId);
          yield* Stream<Map<String, dynamic>>.fromIterable(
            runChunks(runId, 't1'),
          );
        },
      );
      var latest = <chat.AssistantTurn>[];
      final client = chat.ChatClient(
        threadId: 't1',
        connection: connection,
        processingScheduler: scheduler,
        initialResumeSnapshot: platform.ChatResumeSnapshot(
          resumeState: const platform.ChatResumeState(
            threadId: 't1',
            runId: 'r1',
          ),
        ),
        onMessagesChange: (messages) =>
            latest = List<chat.AssistantTurn>.of(messages),
      );
      addTearDown(client.dispose);

      await client.attach();
      await waitFor(() => textOf(lastAssistant(latest)) == 'world');

      expect(schedulerYields, 0);
      expect(joinIds, <String>['r1']);
    });

    test(
        'persistence:true hydrates history AND tails a live run from the server on mount',
        () async {
      final joinIds = <String>[];
      var connectCalls = 0;
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {
          connectCalls += 1;
        },
        joinRun: (runId, {signal}) async* {
          joinIds.add(runId);
          yield* Stream<Map<String, dynamic>>.fromIterable(
            runChunks(runId, 't1'),
          );
        },
        hydrate: (threadId, {options}) async => conn.ChatHydrationResult(
          messages: <Map<String, dynamic>>[
            uiMessage('history-1', 'earlier turn', 'user'),
          ],
          activeRun: const conn.ActiveRun('r1'),
        ),
      );
      var latest = <chat.AssistantTurn>[];
      final client = chat.ChatClient(
        threadId: 't1',
        connection: connection,
        persistence: true,
        onMessagesChange: (messages) =>
            latest = List<chat.AssistantTurn>.of(messages),
      );
      addTearDown(client.dispose);

      expect(connectCalls, 0);
      await client.attach();
      await waitFor(() => textOf(lastAssistant(latest)) == 'world');

      expect(latest.any((message) => message.id == 'history-1'), isTrue);
      expect(joinIds, <String>['r1']);
      expect(connectCalls, 0);
    });

    test('persistence:true hydrates a transcript with no active run (no tail)',
        () async {
      final joinIds = <String>[];
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {},
        joinRun: (runId, {signal}) async* {
          joinIds.add(runId);
        },
        hydrate: (threadId, {options}) async => conn.ChatHydrationResult(
          messages: <Map<String, dynamic>>[
            uiMessage('u1', 'hi', 'user'),
            uiMessage('a1', 'done', 'assistant'),
          ],
          activeRun: null,
        ),
      );
      var latest = <chat.AssistantTurn>[];
      final client = chat.ChatClient(
        threadId: 't1',
        connection: connection,
        persistence: true,
        onMessagesChange: (messages) =>
            latest = List<chat.AssistantTurn>.of(messages),
      );
      addTearDown(client.dispose);

      await client.attach();
      await waitFor(() => latest.any((message) => message.id == 'a1'));
      expect(joinIds, isEmpty);
    });

    test(
        'persistence:true restores a pending interrupt from the server on mount',
        () async {
      final joinIds = <String>[];
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {},
        joinRun: (runId, {signal}) async* {
          joinIds.add(runId);
        },
        hydrate: (threadId, {options}) async => conn.ChatHydrationResult(
          messages: <Map<String, dynamic>>[
            uiMessage('u1', 'send an email', 'user'),
          ],
          activeRun: null,
          interrupts: conn.ChatInterrupts(
            runId: 'run-paused',
            pending: <Map<String, dynamic>>[
              genericPendingInterrupt('int-1', 'run-paused'),
            ],
          ),
        ),
      );
      final client = chat.ChatClient(
        threadId: 't1',
        connection: connection,
        persistence: true,
      );
      addTearDown(client.dispose);

      await client.attach();
      await waitFor(() => client.getInterrupts().length == 1);

      final item = client.getInterrupts().single;
      expect(item.kind, 'generic');
      expect(item.canResolve, isTrue);
      expect(item.interruptedRunId, 'run-paused');
      expect(joinIds, isEmpty);
    });

    test('publishes hydrate once before live client-tool cancellation',
        () async {
      final outputSchema = <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'accountId': <String, Object?>{'type': 'string'},
        },
        'required': <Object?>['accountId'],
      };
      var executeCalls = 0;
      final lookup = platform.ClientTool(
        name: 'lookup',
        description: 'Look up an account',
        outputSchema: outputSchema,
        execute: (input, executionContext) async {
          executeCalls += 1;
          return <String, Object?>{'accountId': 'account-1'};
        },
      );
      final outputSchemaHash = platform.hashSchemaInput(lookup.outputSchema);
      final contexts = <conn.RunAgentInputContext?>[];
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {
          contexts.add(runContext);
          final runId = runContext?.runId ?? 'run-cancelled';
          final threadId = runContext?.threadId ?? 't1';
          yield <String, dynamic>{
            'type': 'RUN_STARTED',
            'runId': runId,
            'threadId': threadId,
            'timestamp': 1,
          };
          yield <String, dynamic>{
            'type': 'RUN_FINISHED',
            'runId': runId,
            'threadId': threadId,
            'timestamp': 2,
            'outcome': <String, dynamic>{'type': 'success'},
          };
        },
        joinRun: (runId, {signal}) async* {},
        hydrate: (threadId, {options}) async => conn.ChatHydrationResult(
          messages: <Map<String, dynamic>>[
            uiMessage('u1', 'look up the account', 'user'),
          ],
          activeRun: null,
          interrupts: conn.ChatInterrupts(
            runId: 'run-paused',
            pending: <Map<String, dynamic>>[
              clientToolPendingInterrupt(
                id: 'client-1',
                runId: 'run-paused',
                toolName: 'lookup',
                toolCallId: 'call-1',
                outputSchemaHash: outputSchemaHash,
              ),
            ],
          ),
        ),
      );
      final sources = <String>[];
      late final chat.ChatClient client;
      client = chat.ChatClient(
        threadId: 't1',
        connection: connection,
        persistence: true,
        tools: <platform.ClientTool>[lookup],
        onInterruptStateChange: (state, source) {
          sources.add(source);
          if (source == 'hydrate') client.cancelInterrupts();
        },
      );
      addTearDown(client.dispose);

      await client.attach();
      await waitFor(() => contexts.length == 1);
      await waitFor(() => client.getResumeState() == null);

      expect(sources.first, 'hydrate');
      expect(
        sources.where((source) => source == 'hydrate').toList(),
        <String>['hydrate'],
      );
      expect(sources, contains('live'));
      expect(contexts.single?.parentRunId, 'run-paused');
      expect(contexts.single?.resume, <Map<String, dynamic>>[
        <String, dynamic>{'interruptId': 'client-1', 'status': 'cancelled'},
      ]);
      expect(contexts, hasLength(1));
      expect(executeCalls, 0);
    });

    test(
        'restores a pending interrupt even when hydrate also reports an activeRun',
        () async {
      final joinIds = <String>[];
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {},
        joinRun: (runId, {signal}) async* {
          joinIds.add(runId);
        },
        hydrate: (threadId, {options}) async => conn.ChatHydrationResult(
          messages: <Map<String, dynamic>>[
            uiMessage('u1', 'send an email', 'user'),
          ],
          activeRun: const conn.ActiveRun('run-paused'),
          interrupts: conn.ChatInterrupts(
            runId: 'run-paused',
            pending: <Map<String, dynamic>>[
              genericPendingInterrupt('int-1', 'run-paused'),
            ],
          ),
        ),
      );
      final client = chat.ChatClient(
        threadId: 't1',
        connection: connection,
        persistence: true,
      );
      addTearDown(client.dispose);

      await client.attach();
      await waitFor(() => client.getInterrupts().length == 1);

      expect(client.getInterrupts().single.canResolve, isTrue);
      expect(joinIds, isEmpty);
    });

    test(
        'rejoins an active continuation run instead of restoring its parent interrupt',
        () async {
      final joinIds = <String>[];
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {},
        joinRun: (runId, {signal}) async* {
          joinIds.add(runId);
          yield* Stream<Map<String, dynamic>>.fromIterable(
            runChunks(runId, 't1'),
          );
        },
        hydrate: (threadId, {options}) async => conn.ChatHydrationResult(
          messages: <Map<String, dynamic>>[
            uiMessage('u1', 'send an email', 'user'),
          ],
          activeRun: const conn.ActiveRun('run-B'),
          interrupts: conn.ChatInterrupts(
            runId: 'run-A',
            pending: <Map<String, dynamic>>[
              genericPendingInterrupt('int-1', 'run-A'),
            ],
          ),
        ),
      );
      var latest = <chat.AssistantTurn>[];
      final client = chat.ChatClient(
        threadId: 't1',
        connection: connection,
        persistence: true,
        onMessagesChange: (messages) =>
            latest = List<chat.AssistantTurn>.of(messages),
      );
      addTearDown(client.dispose);

      await client.attach();
      await waitFor(() => latest.any((message) => message.id == 'assistant-1'));

      expect(joinIds, <String>['run-B']);
      expect(client.getInterrupts(), isEmpty);
    });

    test(
        'rebuilds a hydrated in-flight partial in place (no duplicate) when tailing on mount',
        () async {
      final joinIds = <String>[];
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {},
        joinRun: (runId, {signal}) async* {
          joinIds.add(runId);
          yield* Stream<Map<String, dynamic>>.fromIterable(
            runChunks(runId, 't1'),
          );
        },
        hydrate: (threadId, {options}) async => conn.ChatHydrationResult(
          messages: <Map<String, dynamic>>[
            uiMessage('user-1', 'hi', 'user'),
            <String, dynamic>{
              'id': 'assistant-1',
              'role': 'assistant',
              'parts': <Map<String, dynamic>>[
                <String, dynamic>{'type': 'text', 'content': 'wor'},
              ],
              'createdAt': '2026-01-01T00:00:00.000Z',
            },
          ],
          activeRun: const conn.ActiveRun('r1'),
        ),
      );
      var latest = <chat.AssistantTurn>[];
      final client = chat.ChatClient(
        threadId: 't1',
        connection: connection,
        persistence: true,
        onMessagesChange: (messages) =>
            latest = List<chat.AssistantTurn>.of(messages),
      );
      addTearDown(client.dispose);

      await client.attach();
      await waitFor(() => textOf(lastAssistant(latest)) == 'world');

      final assistants =
          latest.where((message) => message.role == 'assistant').toList();
      expect(assistants, hasLength(1));
      expect(textOf(assistants.single), 'world');
      expect(latest.any((message) => message.id == 'user-1'), isTrue);
      expect(joinIds, <String>['r1']);
    });

    test(
        'rejoins a live run handed to a fresh client via initialResumeSnapshot',
        () async {
      final joinIds = <String>[];
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {},
        joinRun: (runId, {signal}) async* {
          joinIds.add(runId);
          yield* Stream<Map<String, dynamic>>.fromIterable(
            runChunks(runId, 't1'),
          );
        },
      );
      var latest = <chat.AssistantTurn>[];
      final client = chat.ChatClient(
        threadId: 't1',
        connection: connection,
        initialMessages: <chat.AssistantTurn>[
          chat.AssistantTurn(
            id: 'history-1',
            role: 'user',
            parts: <chat.AssistantPart>[
              chat.AssistantPart.text('earlier turn')
            ],
          ),
        ],
        initialResumeSnapshot: platform.ChatResumeSnapshot(
          resumeState: const platform.ChatResumeState(
            threadId: 't1',
            runId: 'r1',
          ),
        ),
        onMessagesChange: (messages) =>
            latest = List<chat.AssistantTurn>.of(messages),
      );
      addTearDown(client.dispose);

      await client.attach();
      await waitFor(() => textOf(lastAssistant(latest)) == 'world');

      expect(joinIds, <String>['r1']);
      expect(latest.any((message) => message.id == 'history-1'), isTrue);
    });

    test('rejoins from an async store (getItem returns a Promise)', () async {
      final adapter = AsyncMemoryAdapter(
        platform.ChatPersistedState(
          messages: <Map<String, dynamic>>[],
          resume: platform.ChatResumeSnapshot(
            resumeState: const platform.ChatResumeState(
              threadId: 't1',
              runId: 'r1',
            ),
          ),
        ),
      );
      final joinIds = <String>[];
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {},
        joinRun: (runId, {signal}) async* {
          joinIds.add(runId);
          yield* Stream<Map<String, dynamic>>.fromIterable(
            runChunks(runId, 't1'),
          );
        },
      );
      var latest = <chat.AssistantTurn>[];
      final client = chat.ChatClient(
        threadId: 't1',
        connection: connection,
        persistence: adapter,
        onMessagesChange: (messages) =>
            latest = List<chat.AssistantTurn>.of(messages),
      );
      addTearDown(client.dispose);

      await client.attach();
      await waitFor(() => textOf(lastAssistant(latest)) == 'world');

      expect(joinIds, <String>['r1']);
    });

    test('KEEPS the resume pointer when joinRun times out before attaching',
        () async {
      final adapter = MemoryAdapter(
        platform.ChatPersistedState(
          messages: <Map<String, dynamic>>[
            uiMessage('user-1', 'hi', 'user'),
          ],
          resume: platform.ChatResumeSnapshot(
            resumeState: const platform.ChatResumeState(
              threadId: 't1',
              runId: 'quiet-run',
            ),
          ),
        ),
      );
      final joinIds = <String>[];
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {},
        joinRun: (runId, {signal}) {
          joinIds.add(runId);
          final controller = StreamController<Map<String, dynamic>>();
          signal?.onAbort(() {
            if (!controller.isClosed) controller.close();
          });
          return controller.stream;
        },
      );
      String? status;
      final client = chat.ChatClient(
        threadId: 't1',
        connection: connection,
        persistence: adapter,
        onStatusChange: (next) => status = next,
      );
      addTearDown(client.dispose);

      await client.attach();
      await waitForAsync(() =>
          joinIds.isNotEmpty && status == 'ready' && !client.getIsLoading());

      final stored = adapter.value;
      expect(stored, isA<platform.ChatPersistedState>());
      expect(
        (stored as platform.ChatPersistedState).resume?.resumeState.runId,
        'quiet-run',
      );
    });

    test(
        'clears a dead resume pointer when joinRun is REFUSED before attaching',
        () async {
      final adapter = MemoryAdapter(
        platform.ChatPersistedState(
          messages: <Map<String, dynamic>>[
            uiMessage('user-1', 'hi', 'user'),
          ],
          resume: platform.ChatResumeSnapshot(
            resumeState: const platform.ChatResumeState(
              threadId: 't1',
              runId: 'gone-run',
            ),
          ),
        ),
      );
      final joinIds = <String>[];
      Stream<Map<String, dynamic>> refused(
        String runId, {
        conn.CancellationSignal? signal,
      }) async* {
        joinIds.add(runId);
        await Future<void>.delayed(Duration.zero);
        throw StateError(
          'Unknown or expired memory stream run: "gone-run"',
        );
      }

      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {},
        joinRun: refused,
      );
      String? status;
      final client = chat.ChatClient(
        threadId: 't1',
        connection: connection,
        persistence: adapter,
        onStatusChange: (next) => status = next,
      );
      addTearDown(client.dispose);

      await client.attach();
      await waitForAsync(() =>
          joinIds.isNotEmpty && status == 'ready' && !client.getIsLoading());
      await waitFor(() {
        final stored = adapter.value;
        return stored is! platform.ChatPersistedState || stored.resume == null;
      });

      final stored = adapter.value;
      if (stored is platform.ChatPersistedState) {
        expect(stored.resume, isNull);
      } else {
        expect(stored == null || stored is List, isTrue);
      }
    });

    test('with persistence:true a dead server-tail frees the input', () async {
      final joinIds = <String>[];
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {},
        joinRun: (runId, {signal}) {
          joinIds.add(runId);
          final controller = StreamController<Map<String, dynamic>>();
          signal?.onAbort(() {
            if (!controller.isClosed) controller.close();
          });
          return controller.stream;
        },
        hydrate: (threadId, {options}) async => conn.ChatHydrationResult(
          messages: <Map<String, dynamic>>[
            uiMessage('history-1', 'seed', 'user'),
          ],
          activeRun: const conn.ActiveRun('gone-run'),
        ),
      );
      final client = chat.ChatClient(
        threadId: 't1',
        connection: connection,
        persistence: true,
      );
      addTearDown(client.dispose);

      await client.attach();
      await waitForAsync(
        () => joinIds.isNotEmpty && !client.getIsLoading(),
      );

      expect(client.getIsLoading(), isFalse);
    });

    test('surfaces post-attach rejoin errors via onError', () async {
      final adapter = MemoryAdapter(
        platform.ChatPersistedState(
          messages: <Map<String, dynamic>>[
            uiMessage('user-1', 'hi', 'user'),
          ],
          resume: platform.ChatResumeSnapshot(
            resumeState: const platform.ChatResumeState(
              threadId: 't1',
              runId: 'r1',
            ),
          ),
        ),
      );
      final joinIds = <String>[];
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {},
        joinRun: (runId, {signal}) async* {
          joinIds.add(runId);
          yield <String, dynamic>{
            'type': 'RUN_STARTED',
            'runId': 'r1',
            'threadId': 't1',
            'timestamp': 1,
          };
          yield <String, dynamic>{
            'type': 'TEXT_MESSAGE_START',
            'messageId': 'a1',
            'role': 'assistant',
            'timestamp': 2,
          };
          throw StateError('transport died mid-replay');
        },
      );
      final errors = <Object>[];
      final client = chat.ChatClient(
        threadId: 't1',
        connection: connection,
        persistence: adapter,
        onError: (error, chunk) => errors.add(error),
      );
      addTearDown(client.dispose);

      await client.attach();
      await waitFor(() => errors.isNotEmpty);

      expect('${errors.first}', contains('transport died'));
      expect(joinIds, <String>['r1']);
    });
  });
}
