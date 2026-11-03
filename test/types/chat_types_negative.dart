// Negative Dart type fixture for the ported chat surface.
//
// Every line marked "expect-error" must produce the named analyzer diagnostic.
// Verify with:
//   dart analyze test/types/chat_types_negative.dart
// The positive companion must stay clean:
//   dart analyze test/types/chat_types_positive.dart
// ignore_for_file: unused_local_variable, unused_element

import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/platform.dart' show ChatPersistedState;
import 'package:tanstack_ai_dart/connections.dart' as conn;

void negativeCases() {
  // Upstream: `id` is not a ChatClientOptions field; `threadId` is.
  // expect-error: undefined_named_parameter (id)
  ChatClientOptions(id: 'thread-1');

  // Upstream: threadId is a string.
  // expect-error: argument_type_not_assignable (int to String?)
  ChatClientOptions(threadId: 1);

  // Dart's typed persistence constructors enforce the JS conditional contract.
  // expect-error: missing_required_argument
  ChatPersistenceOptions.server();

  // expect-error: missing_required_argument
  ChatPersistenceOptions.stored(adapter: _Store());

  // History belongs to server-authoritative persistence, never a custom store.
  // expect-error: undefined_named_parameter
  ChatPersistenceOptions.stored(
      threadId: 't',
      adapter: _Store(),
      history: const ChatHistoryConfig(pageSize: 20));

  // Upstream: queue accepts ChatQueueConfig, not the string shorthand here.
  // expect-error: argument_type_not_assignable (String to ChatQueueConfig?)
  ChatClientOptions(queue: 'queue');

  // Upstream: byok is a ByokClient, never a raw key.
  // expect-error: argument_type_not_assignable (String to ByokClient?)
  ChatClient(byokClient: 'sk-live-secret');

  // Upstream: onResponse takes no parameters and returns FutureOr<void>.
  // expect-error: argument_type_not_assignable (callback shape)
  ChatClient(onResponse: (int code) {});

  // Upstream ChatFetcher receives ChatFetcherInput, not a raw string.
  final conn.ChatFetcher wrongInput =
      // expect-error: invalid_assignment (String input)
      (String input, {signal, headers}) =>
          const Stream<Map<String, dynamic>>.empty();

  // Upstream ChatFetcher must return Response-like or AsyncIterable, never null.
  // expect-error: return_of_invalid_type_from_closure (Null to Object)
  final conn.ChatFetcher nullFetcher = (input, {signal, headers}) => null;

  // Upstream tool execute receives (input, context); one positional arg is not
  // assignable.
  // expect-error: argument_type_not_assignable (execute arity)
  ChatClientTool(name: 'lookup', execute: (input) => 1);

  // Upstream onChunk receives Map<String, dynamic>, not a String.
  // expect-error: argument_type_not_assignable (String chunk)
  ChatClientOptions(onChunk: (String chunk) {});
}

class _Store implements ChatClientPersistence {
  @override
  Object? getItem(String id) => null;
  @override
  void setItem(String id, ChatPersistedState state) {}
  @override
  void removeItem(String id) {}
}
