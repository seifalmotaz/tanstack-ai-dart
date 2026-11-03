# Chat and rendering

Import `package:tanstack_ai_dart/tanstack_ai_dart.dart`. The
[analyzed recipes](../example/recipes.dart) supply all examples below.

## Read state

Use `client.snapshot`, `client.state`, and `client.isLoading`. `ChatClientState`
contains `submitted`, `streaming`, `ready`, and `error`.
`ChatSnapshot.connectionStatus` uses `ChatConnectionState`, a separate enum.

Listen to `client.states` for updates. Each listener has its own initial snapshot
and pause buffer. Cancelling one listener does not cancel the run or other
listeners. Snapshot errors are data in the state, not stream error events.
A slow paused listener can buffer updates, so cancel unused subscriptions.

`messages` and snapshots are read-only. Use `setMessagesManually(...)` to replace
a transcript; the client copies the input. `getMessages()` is a retained legacy
accessor to live data and should not be used in new UI code.

## Send text or parts

Use `sendText(String)` for text. Typed message input also preserves an explicit
message ID and metadata:

<!-- example: example/recipes.dart#message -->
```dart
Future<void> sendParts(ChatClient client) => client.sendMessage(
      ChatMessageInput.parts(
        [AssistantPart.text('Show properties in Cairo')],
        id: 'customer-message-1',
        metadata: {'language': 'en'},
      ),
    );
```
<!-- /example -->

Unknown wire fields are preserved through conversion. User interface rendering
should use read-only views rather than mutate protocol models.

## Render parts exhaustively

`message.chatParts` and `part.chatPart` produce sealed immutable views. This
switch handles the variants available in the current Dart API:

<!-- example: example/recipes.dart#rendering -->
```dart
String summarizePart(ChatPart part) => switch (part) {
      ChatTextPart(:final content) => content,
      ChatThinkingPart(:final content) => content,
      ChatToolCallPart(:final name) => 'Tool: $name',
      ChatToolResultPart(:final output) => 'Result: $output',
      ChatActivityPart(:final activityType) => 'Activity: $activityType',
      ChatStructuredPart(:final data) => 'Data: $data',
      ChatSubagentPart(:final id) => 'Agent: $id',
      ChatMediaPart(:final mediaType) => 'Media: $mediaType',
      ChatUnknownPart(:final type) => 'Unsupported part: $type',
    };
```
<!-- /example -->

Every view exposes `wire`, the deep-frozen JSON representation. Future protocol
types become `ChatUnknownPart`. Opaque application objects retain their identity;
use immutable models if they are included in outputs.

## Configure busy behavior

The queue can enqueue, drop, or interrupt a message submitted during a run.
Its drain policy supports FIFO or batch behavior. Configure a bounded queue for
your application's workload:

<!-- example: example/recipes.dart#queue -->
```dart
ChatClient queuedChat(ConnectionAdapter connection) => ChatClient(
      connection: connection,
      queue: const ChatQueueConfig(
        whenBusy: QueueWhenBusy.queue,
        maxSize: 10,
        onOverflow: QueueOverflow.reject,
      ),
    );
```
<!-- /example -->

Read `snapshot.queue` to show pending items. The `reject` overflow policy does
not add the new item when the queue is full; a returned send future does not
serve as an explicit enqueue acknowledgement.

## Stop, clear, or replace

- `await client.stop()` cancels the active run, clears queued input, and resets
  pending interrupt state. It is not a storage-preserving pause operation.
- `await client.clear()` clears the conversation and configured stored state.
- `await client.reload()` regenerates from the retained user conversation.
- `client.replaceConnection(next)` replaces the transport and cancels current
  subscription/run ownership. It does not mutate an adapter already in use.

Use typed setters for runtime options: `body`, `forwardedProps`, `context`,
`tools`, `queueConfig`, `byok`, and callbacks. Assign `null` to a nullable option
when you intend to clear it. Read [persistence and resume](persistence.md) before
choosing how to leave and later rejoin a conversation.
