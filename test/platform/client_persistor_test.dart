// Ported from
// packages/ai-client/tests/client-persistor.test.ts
import 'dart:async';

import 'package:tanstack_ai_dart/platform.dart';
import 'package:test/test.dart';

const String chatId = 'chat-1';

Future<void> flushAsync() => Future<void>.delayed(Duration.zero);

class Deferred<T> {
  final Completer<T> completer = Completer<T>();
  Future<T> get promise => completer.future;
  void resolve(T value) => completer.complete(value);
  void reject(Object error) => completer.completeError(error);
}

Map<String, dynamic> uiMessage(String id) => <String, dynamic>{
      'id': id,
      'role': 'user',
      'parts': [
        {'type': 'text', 'content': 'hi'}
      ],
    };

class MockPersistence implements ChatClientPersistence {
  Object? stored;
  int getItemCalls = 0;
  int setItemCalls = 0;
  int removeItemCalls = 0;
  final List<Map<String, dynamic>>? _storedMessages;
  final List<ChatPersistedState> setStates = <ChatPersistedState>[];
  FutureOr<void> Function(String id, ChatPersistedState state)? onSet;
  FutureOr<void> Function(String id)? onRemove;

  MockPersistence([List<Map<String, dynamic>>? stored])
      : _storedMessages = stored;

  @override
  FutureOr<Object?> getItem(String id) {
    getItemCalls++;
    if (_storedMessages != null) return _storedMessages;
    return stored;
  }

  @override
  FutureOr<void> setItem(String id, ChatPersistedState state) {
    setItemCalls++;
    setStates.add(state);
    if (onSet != null) return onSet!(id, state);
    stored = state;
    return null;
  }

  @override
  FutureOr<void> removeItem(String id) {
    removeItemCalls++;
    if (onRemove != null) return onRemove!(id);
    stored = null;
    return null;
  }
}

({ChatPersistor persistor, List<List<Map<String, dynamic>>> applied})
    createPersistor(ChatClientPersistence adapter) {
  final applied = <List<Map<String, dynamic>>>[];
  final persistor = ChatPersistor(adapter, chatId, applied.add);
  return (persistor: persistor, applied: applied);
}

Map<String, dynamic> runStarted(String runId) => {
      'type': 'RUN_STARTED',
      'threadId': 'thread-1',
      'runId': runId,
    };

Map<String, dynamic> runFinished(String runId) => {
      'type': 'RUN_FINISHED',
      'threadId': 'thread-1',
      'runId': runId,
    };

Map<String, dynamic> runError([String message = 'boom']) => {
      'type': 'RUN_ERROR',
      'message': message,
    };

Map<String, dynamic> textContent(String messageId, [String delta = 'hi']) => {
      'type': 'TEXT_MESSAGE_CONTENT',
      'messageId': messageId,
      'delta': delta,
    };

Map<String, dynamic> toolCallStart(
  String toolCallId, [
  String? parentMessageId,
]) =>
    {
      'type': 'TOOL_CALL_START',
      'toolCallId': toolCallId,
      'toolCallName': 'tool',
      if (parentMessageId != null) 'parentMessageId': parentMessageId,
    };

Map<String, dynamic> messagesSnapshot() => {
      'type': 'MESSAGES_SNAPSHOT',
      'messages': <Object?>[],
    };

void main() {
  group('ChatPersistor', () {
    group('readInitial', () {
      test('returns the stored messages from a synchronous getItem', () {
        final stored = [uiMessage('m-1')];
        final adapter = MockPersistence(stored);
        final created = createPersistor(adapter);

        final initial = created.persistor.readInitial();
        expect(initial, isA<ChatPersistedState>());
        expect((initial as ChatPersistedState).messages, stored);
        expect(adapter.getItemCalls, 1);
      });

      test('round-trips a mixed transcript that includes activity', () {
        ChatPersistedState? stored;
        final adapter = _StateAdapter(
          get: () => stored,
          set: (state) => stored = state,
        );
        final mixed = <Map<String, dynamic>>[
          uiMessage('u1'),
          {
            'id': 'act-1',
            'role': 'activity',
            'parts': [
              {
                'type': 'activity',
                'activityType': 'SEARCH',
                'content': {'query': 'tanstack'},
              },
            ],
          },
          {
            'id': 'a1',
            'role': 'assistant',
            'parts': [
              {'type': 'text', 'content': 'ok'}
            ],
          },
        ];

        createPersistor(adapter).persistor.notifyMessagesChanged(mixed);

        final next = createPersistor(adapter);
        final initial = next.persistor.readInitial() as ChatPersistedState;
        expect(initial.messages, mixed);
      });

      test('returns the promise from an asynchronous getItem', () {
        final stored = [uiMessage('m-1')];
        final adapter = MockPersistence();
        adapter.stored = Future.value(stored);
        final created = createPersistor(adapter);

        expect(created.persistor.readInitial(), isA<Future>());
      });

      test('swallows a throwing getItem and returns undefined', () {
        final adapter = _StateAdapter(
          get: () => throw StateError('storage unavailable'),
          set: (_) {},
        );
        final created = createPersistor(adapter);

        expect(created.persistor.readInitial(), isNull);
      });
    });

    group('hydrateAsync', () {
      test('applies messages once the promise resolves to a record', () async {
        final stored = [uiMessage('persisted-1')];
        final created = createPersistor(MockPersistence());

        created.persistor
            .hydrateAsync(Future.value(ChatPersistedState(messages: stored)));
        await flushAsync();

        expect(created.applied, [stored]);
      });

      test('does not apply when the promise resolves to undefined', () async {
        final created = createPersistor(MockPersistence());

        created.persistor.hydrateAsync(Future.value(null));
        await flushAsync();

        expect(created.applied, isEmpty);
      });

      test('does nothing for a synchronous (non-promise) value', () async {
        final created = createPersistor(MockPersistence());

        created.persistor
            .hydrateAsync(ChatPersistedState(messages: [uiMessage('m-1')]));
        await flushAsync();

        expect(created.applied, isEmpty);
      });

      test('does not apply if messages changed before hydration resolves',
          () async {
        final deferred = Deferred<ChatPersistedState?>();
        final created = createPersistor(MockPersistence());

        created.persistor.hydrateAsync(deferred.promise);
        created.persistor.notifyMessagesChanged([uiMessage('local-1')]);
        deferred
            .resolve(ChatPersistedState(messages: [uiMessage('persisted-1')]));
        await flushAsync();

        expect(created.applied, isEmpty);
      });

      test('swallows a rejected hydration promise', () async {
        final created = createPersistor(MockPersistence());

        created.persistor.hydrateAsync(
            Future<ChatPersistedState?>.error(StateError('read failed')));
        await flushAsync();

        expect(created.applied, isEmpty);
      });
    });

    group('notifyMessagesChanged', () {
      test('persists the messages on change', () {
        final adapter = MockPersistence();
        final created = createPersistor(adapter);
        final messages = [uiMessage('m-1')];

        created.persistor.notifyMessagesChanged(messages);

        final state = adapter.stored as ChatPersistedState;
        expect(state.messages, messages);
      });

      test('persists a snapshot, not the live array reference', () {
        final adapter = MockPersistence();
        final created = createPersistor(adapter);
        final messages = [uiMessage('m-1')];

        created.persistor.notifyMessagesChanged(messages);
        messages.add(uiMessage('m-2'));

        final persisted = adapter.stored as ChatPersistedState;
        expect(persisted.messages, hasLength(1));
      });

      test('skips exactly one write after beginClear, then resumes', () {
        final adapter = MockPersistence();
        final created = createPersistor(adapter);

        created.persistor.notifyMessagesChanged([uiMessage('m-1')]);
        created.persistor.beginClear();
        created.persistor.notifyMessagesChanged([]);
        created.persistor.notifyMessagesChanged([uiMessage('m-2')]);

        expect(adapter.setItemCalls, 2);
      });

      test('swallows a synchronous setItem error', () {
        final adapter = MockPersistence()
          ..onSet = (_, __) => throw StateError('quota exceeded');
        final created = createPersistor(adapter);

        expect(
          () => created.persistor.notifyMessagesChanged([uiMessage('m-1')]),
          returnsNormally,
        );
      });

      test('runs async writes sequentially (FIFO, no overlap)', () async {
        final first = Deferred<void>();
        final second = Deferred<void>();
        final adapter = MockPersistence();
        var calls = 0;
        adapter.onSet = (_, __) {
          calls++;
          if (calls == 1) return first.promise;
          if (calls == 2) return second.promise;
          return null;
        };
        final created = createPersistor(adapter);

        created.persistor.notifyMessagesChanged([uiMessage('a')]);
        created.persistor.notifyMessagesChanged([uiMessage('b')]);
        expect(adapter.setItemCalls, 1);

        first.resolve(null);
        await flushAsync();

        expect(adapter.setItemCalls, 2);
        expect(adapter.setStates[1].messages, [uiMessage('b')]);
      });

      test('keeps writing after an async write rejects', () async {
        final adapter = MockPersistence();
        var calls = 0;
        adapter.onSet = (_, __) {
          calls++;
          if (calls == 1) return Future<void>.error(StateError('transient'));
          return null;
        };
        final created = createPersistor(adapter);

        created.persistor.notifyMessagesChanged([uiMessage('a')]);
        created.persistor.notifyMessagesChanged([uiMessage('b')]);
        await flushAsync();

        expect(adapter.setItemCalls, 2);
      });
    });

    group('remove', () {
      test('removes the persisted conversation', () {
        final adapter = MockPersistence();
        final created = createPersistor(adapter);

        created.persistor.remove();

        expect(adapter.removeItemCalls, 1);
      });

      test('swallows a synchronous removeItem error', () {
        final adapter = MockPersistence()
          ..onRemove = (_) => throw StateError('locked');
        final created = createPersistor(adapter);

        expect(() => created.persistor.remove(), returnsNormally);
      });

      test('invalidates a queued write that a removal supersedes', () async {
        final inFlight = Deferred<void>();
        final adapter = MockPersistence();
        var calls = 0;
        adapter.onSet = (_, __) {
          calls++;
          if (calls == 1) return inFlight.promise;
          return null;
        };
        final created = createPersistor(adapter);

        created.persistor.notifyMessagesChanged([uiMessage('a')]);
        created.persistor.notifyMessagesChanged([uiMessage('b')]);
        created.persistor.remove();

        inFlight.resolve(null);
        await flushAsync();

        expect(adapter.setItemCalls, 1);
        expect(adapter.removeItemCalls, 1);
      });
    });

    group('clear-during-stream suppression', () {
      test('does not ignore chunks before a clear', () {
        final created = createPersistor(MockPersistence());

        expect(
            created.persistor.shouldIgnoreChunk(runStarted('run-1')), isFalse);
        expect(
            created.persistor.shouldIgnoreChunk(textContent('msg-1')), isFalse);
      });

      test('ignores chunks for a message id captured at clear time', () {
        final created = createPersistor(MockPersistence());
        created.persistor.snapshotClear(
          messages: [uiMessage('msg-1')],
          activeRunIds: <String>{},
          currentRunId: null,
        );

        expect(
            created.persistor.shouldIgnoreChunk(textContent('msg-1')), isTrue);
        expect(
          created.persistor.shouldIgnoreChunk(textContent('msg-other')),
          isFalse,
        );
      });

      test('ignores a RUN_STARTED for an active run captured at clear time',
          () {
        final created = createPersistor(MockPersistence());
        created.persistor.snapshotClear(
          messages: const <Map<String, dynamic>>[],
          activeRunIds: <String>{'run-1'},
          currentRunId: null,
        );

        expect(
            created.persistor.shouldIgnoreChunk(runStarted('run-1')), isTrue);
      });

      test('ignores the in-flight currentRunId captured at clear time', () {
        final created = createPersistor(MockPersistence());
        created.persistor.snapshotClear(
          messages: const <Map<String, dynamic>>[],
          activeRunIds: <String>{},
          currentRunId: 'run-current',
        );

        expect(
          created.persistor.shouldIgnoreChunk(runStarted('run-current')),
          isTrue,
        );
      });

      test('ignores runless content chunks belonging to a cleared run', () {
        final created = createPersistor(MockPersistence());
        created.persistor.snapshotClear(
          messages: const <Map<String, dynamic>>[],
          activeRunIds: <String>{'run-1'},
          currentRunId: null,
        );
        created.persistor.shouldIgnoreChunk(runStarted('run-1'));

        expect(created.persistor.shouldIgnoreChunk(textContent('late-msg')),
            isTrue);
        expect(created.persistor.shouldIgnoreChunk(messagesSnapshot()), isTrue);
      });

      test("ignores a runless 'TEXT_MESSAGE_CHUNK' belonging to a cleared run",
          () {
        final created = createPersistor(MockPersistence());
        created.persistor.snapshotClear(
          messages: const <Map<String, dynamic>>[],
          activeRunIds: <String>{'run-1'},
          currentRunId: null,
        );
        created.persistor.shouldIgnoreChunk(runStarted('run-1'));

        expect(
          created.persistor.shouldIgnoreChunk({
            'type': 'TEXT_MESSAGE_CHUNK',
            'messageId': 'late-msg',
            'delta': 'hi',
            'timestamp': 1,
          }),
          isTrue,
        );
      });

      test("ignores a runless 'TOOL_CALL_CHUNK' belonging to a cleared run",
          () {
        final created = createPersistor(MockPersistence());
        created.persistor.snapshotClear(
          messages: const <Map<String, dynamic>>[],
          activeRunIds: <String>{'run-1'},
          currentRunId: null,
        );
        created.persistor.shouldIgnoreChunk(runStarted('run-1'));

        expect(
          created.persistor.shouldIgnoreChunk({
            'type': 'TOOL_CALL_CHUNK',
            'toolCallId': 'tc-late',
            'toolCallName': 'x',
            'timestamp': 1,
          }),
          isTrue,
        );
      });

      test(
          'ignores tool chunks by cleared parentMessageId and remembers the toolCallId',
          () {
        final created = createPersistor(MockPersistence());
        created.persistor.snapshotClear(
          messages: [uiMessage('parent-msg')],
          activeRunIds: <String>{},
          currentRunId: null,
        );

        expect(
          created.persistor
              .shouldIgnoreChunk(toolCallStart('tc-1', 'parent-msg')),
          isTrue,
        );
        expect(
          created.persistor.shouldIgnoreChunk(toolCallStart('tc-1')),
          isTrue,
        );
      });
    });

    group('run lifecycle hooks', () {
      test(
          'forgets a settled run so a later run with the same id is not ignored',
          () {
        final created = createPersistor(MockPersistence());
        created.persistor.snapshotClear(
          messages: const <Map<String, dynamic>>[],
          activeRunIds: <String>{'run-1'},
          currentRunId: null,
        );
        expect(
            created.persistor.shouldIgnoreChunk(runStarted('run-1')), isTrue);

        created.persistor.onRunSettled('run-1');

        expect(
            created.persistor.shouldIgnoreChunk(runStarted('run-1')), isFalse);
      });

      test('stops ignoring runless chunks after a session-level run error', () {
        final created = createPersistor(MockPersistence());
        created.persistor.snapshotClear(
          messages: const <Map<String, dynamic>>[],
          activeRunIds: <String>{'run-1'},
          currentRunId: null,
        );
        created.persistor.shouldIgnoreChunk(runStarted('run-1'));
        expect(
            created.persistor.shouldIgnoreChunk(textContent('late-1')), isTrue);

        created.persistor.onSessionRunError();

        expect(created.persistor.shouldIgnoreChunk(textContent('late-2')),
            isFalse);
      });

      test(
          'takeRunlessRunId returns and clears the current runless run, then null',
          () {
        final created = createPersistor(MockPersistence());
        created.persistor.snapshotClear(
          messages: const <Map<String, dynamic>>[],
          activeRunIds: <String>{'run-1'},
          currentRunId: null,
        );
        created.persistor.shouldIgnoreChunk(runStarted('run-1'));

        expect(created.persistor.takeRunlessRunId(), 'run-1');
        expect(created.persistor.takeRunlessRunId(), isNull);
        expect(
            created.persistor.shouldIgnoreChunk(textContent('late')), isFalse);
      });

      test('resetIgnored only clears active-run markers, not cleared ids', () {
        final created = createPersistor(MockPersistence());
        created.persistor.snapshotClear(
          messages: [uiMessage('msg-1')],
          activeRunIds: <String>{'run-1'},
          currentRunId: null,
        );

        created.persistor.resetIgnored();

        expect(
            created.persistor.shouldIgnoreChunk(runStarted('run-1')), isTrue);
        expect(
            created.persistor.shouldIgnoreChunk(textContent('msg-1')), isTrue);
      });

      test('does not ignore an unrelated runId-less run error', () {
        final created = createPersistor(MockPersistence());

        expect(created.persistor.shouldIgnoreChunk(runError()), isFalse);
      });

      test(
          'onRunStarted for a non-cleared run does not suppress runless chunks',
          () {
        final created = createPersistor(MockPersistence());

        created.persistor.onRunStarted('run-live');

        expect(created.persistor.shouldIgnoreChunk(textContent('content')),
            isFalse);
      });

      test('advances the runless pointer when the active run finishes', () {
        final created = createPersistor(MockPersistence());
        created.persistor.snapshotClear(
          messages: const <Map<String, dynamic>>[],
          activeRunIds: <String>{'run-1', 'run-2'},
          currentRunId: null,
        );
        created.persistor.shouldIgnoreChunk(runStarted('run-1'));
        created.persistor.shouldIgnoreChunk(runStarted('run-2'));

        created.persistor.onRunSettled('run-2');

        expect(
            created.persistor.shouldIgnoreChunk(runFinished('run-2')), isFalse);
        expect(
            created.persistor.shouldIgnoreChunk(textContent('late')), isTrue);
      });

      test(
          'keeps suppressing a second cleared run after the first drains via a runless error',
          () {
        final created = createPersistor(MockPersistence());
        created.persistor.snapshotClear(
          messages: const <Map<String, dynamic>>[],
          activeRunIds: <String>{'run-1', 'run-2'},
          currentRunId: null,
        );
        created.persistor.shouldIgnoreChunk(runStarted('run-1'));
        created.persistor.shouldIgnoreChunk(runStarted('run-2'));

        expect(created.persistor.takeRunlessRunId(), 'run-2');

        expect(
          created.persistor.shouldIgnoreChunk(textContent('late-from-run-1')),
          isTrue,
        );
      });
    });
  });
}

class _StateAdapter implements ChatClientPersistence {
  final ChatPersistedState? Function() get;
  final void Function(ChatPersistedState state) set;

  _StateAdapter({required this.get, required this.set});

  @override
  FutureOr<Object?> getItem(String id) => get();

  @override
  FutureOr<void> setItem(String id, ChatPersistedState state) {
    set(state);
  }

  @override
  FutureOr<void> removeItem(String id) {}
}
