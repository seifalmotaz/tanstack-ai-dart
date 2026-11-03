# Connect your first chat

You need Dart at the minimum version listed in the [README](../README.md), a
compatible backend, and any credentials that backend requires. The SDK does not
select a model, create backend routes, or supply provider credentials.

## Install and configure

1. Add the Git dependency from the README while the package is unpublished.
2. Run `dart pub get`.
3. Pass your chat route URL to `fetchServerSentEvents`.
4. Add authentication with a fixed header or an async options provider. See
   [connections and authentication](connections.md).

## Run a request

This function is maintained in [basic_chat.dart](../example/basic_chat.dart).
Call `runChat` with your application's backend URL.

<!-- example: example/basic_chat.dart -->
```dart
import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';

Future<void> runChat(String endpoint) async {
  final client = ChatClient(
    connection: fetchServerSentEvents(endpoint),
    threadId: 'conversation-123',
  );
  final subscription = client.states.listen((snapshot) {
    for (final message in snapshot.messages) {
      print('${message.role}: ${message.answer}');
    }
  });

  try {
    await client.attach();
    await client.sendText('Hello');
    if (client.error != null) {
      throw StateError(client.error!);
    }
  } finally {
    await subscription.cancel();
    await client.dispose();
  }
}
```
<!-- /example -->

For a direct send on an idle connected client, await `sendText`, then inspect
`client.error` or the snapshot error. Busy-message queue/drop policies may return
before another run completes; observe snapshots for the actual conversation state. Request failures are represented in client state, so
successful completion of the returned future alone does not prove a successful
model response. Invalid API operations can still throw, so keep cleanup in
`finally`.

## Understand ownership

Create a client for the conversation or view that owns it. `attach()` restores
configured history and replay state. Creating a client alone does not join an
existing run. Chat `detach()` is synchronous and releases the attached view;
`dispose()` is asynchronous and ends ownership. Cancel state subscriptions when
their owner no longer needs updates.

`client.snapshot` reads current state. Each listener to `client.states` receives
an initial snapshot, followed by updates. The stream closes on disposal.
Read [chat and rendering](chat.md) before modifying message state.

## Add Flutter UI

Use `StreamBuilder<ChatSnapshot>` with `stream: client.states` and
`initialData: client.snapshot`. Create the client outside `build()`, then attach
it when the conversation owner becomes active. Release ownership when the view
is disposed. Flutter's synchronous `State.dispose()` cannot await a future;
arrange asynchronous cleanup through your app's lifecycle or handle the
`client.dispose()` future explicitly.

The package ships a headless client. Message widgets, Markdown rendering,
attachments, and app navigation belong to the consuming application.
