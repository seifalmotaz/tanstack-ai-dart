# Persistence and resume

Choose a stable conversation ID before enabling persistence. User IDs alone are
usually insufficient when a user can own multiple conversations. Keep tenant
isolation and storage access control in your application and backend.

Import `package:tanstack_ai_dart/tanstack_ai_dart.dart` for these recipes.

## Use server-authoritative history

The server option uses the connection's hydration and join-run handlers. History
paging is configured on that persistence choice:

<!-- example: example/recipes.dart#server-persistence -->
```dart
ChatClient serverHistory(ConnectionAdapter connection, String threadId) =>
    ChatClient(
      threadId: threadId,
      connection: connection,
      persistence: ChatPersistenceOptions.server(
        history: const ChatHistoryConfig(pageSize: 20),
      ),
    );
```
<!-- /example -->

Call `await client.attach()` after construction. Read `hasOlderMessages` and call
`await client.loadOlderMessages()` to fetch earlier pages. Backend handlers must
support the paging contract; changing page size cannot add server capabilities.

## Store messages in your application

Provide an adapter that stores the complete chat record:

<!-- example: example/recipes.dart#stored-persistence -->
```dart
ChatClient storedHistory(
  ConnectionAdapter connection,
  ChatClientPersistence storage,
  String threadId,
) =>
    ChatClient(
      threadId: threadId,
      connection: connection,
      persistence: ChatPersistenceOptions.stored(
        adapter: storage,
      ),
    );
```
<!-- /example -->

`ChatClientPersistence` defines `getItem(id)`, `setItem(id, ChatPersistedState)`,
and `removeItem(id)`. Methods may be synchronous or asynchronous. Store the
messages and resume snapshot as one record, using `state.toJson()` and
`ChatPersistedState.fromJson(...)` at your serialization boundary.
`ChatStorageAdapter` offers a typed read result for new implementations.

The SDK does not install a device database, browser store, or secure-storage
plugin. Inject the application's storage implementation. A memory-only adapter
cannot preserve a conversation across process restarts.

## Rejoin a live run

A resume pointer identifies the prior thread and run. `ChatResumeSnapshot` also
carries pending interrupts. Pass restored state through configured storage or
`initialResumeSnapshot`, then attach the client. The connection and backend must
provide replay support.

Hydrated pending interrupts and replay failures have explicit client handling.
A quiet connection does not prove that a run is dead. Do not erase a resume
pointer merely because no new tokens have arrived.

`stop()` intentionally cancels and resets pending run state. Use the lifecycle
operations described in [chat and rendering](chat.md) when leaving a view.
`clear()` also removes configured client storage; provide an explicit application
confirmation if losing that conversation would surprise the user.
