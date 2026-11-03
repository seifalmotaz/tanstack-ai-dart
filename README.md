# tanstack_ai_dart

A framework-independent Dart client for TanStack AI chat and generation. Use it
from Dart or Flutter to stream responses, run client tools, handle approvals,
and restore conversations.

[![CI](https://github.com/seifalmotaz/tanstack-ai-dart/actions/workflows/ci.yml/badge.svg)](https://github.com/seifalmotaz/tanstack-ai-dart/actions/workflows/ci.yml)

This is an **unofficial community port**, not a package maintained by TanStack.
It provides a Dart API over a pinned TanStack protocol. Server orchestration and
model-provider adapters belong to your backend.

<!-- compatibility:start -->
| Compatibility | Supported target |
| --- | --- |
| Dart package API | `0.3.1` |
| Dart SDK | `>=3.6.2 <4.0.0` |
| Official client | `@tanstack/ai-client 0.40.0` |
| Official core protocol | `@tanstack/ai 0.70.0` |
| Upstream source | [`7095ebbf1b59175f0cd339c1c477d6af55b312de`](https://github.com/TanStack/ai/tree/7095ebbf1b59175f0cd339c1c477d6af55b312de) |
<!-- compatibility:end -->

## Install

Add the package from [pub.dev](https://pub.dev/packages/tanstack_ai_dart):

```sh
# Dart
dart pub add tanstack_ai_dart

# Flutter
flutter pub add tanstack_ai_dart
```

Or add it to `pubspec.yaml`:

```yaml
dependencies:
  tanstack_ai_dart: ^0.3.1
```

Run `dart pub get` or `flutter pub get` after editing `pubspec.yaml` manually.
See [GitHub releases](https://github.com/seifalmotaz/tanstack-ai-dart/releases)
for tagged source and versioned LLM references.

Use a backend endpoint that implements the supported TanStack streaming protocol.
An arbitrary LLM-provider URL is not a compatible chat endpoint.

## Send a message

Call this function with your backend URL. It subscribes to typed state, sends a
message, and releases the client even if a request fails.

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

For a runnable command-line example:

```sh
dart run example/quickstart.dart http://localhost:3000/api/chat "Hello"
```

This command makes a real request to the endpoint you supply. See
[getting started](https://github.com/seifalmotaz/tanstack-ai-dart/blob/main/doc/getting-started.md) for setup and error handling.

## What you can build

| Capability | Guide |
| --- | --- |
| Chat streams, cancellation, queues, and immutable state | [Chat and rendering](https://github.com/seifalmotaz/tanstack-ai-dart/blob/main/doc/chat.md) |
| SSE, NDJSON, JSON polling, WebSocket, and custom fetchers | [Connections and authentication](https://github.com/seifalmotaz/tanstack-ai-dart/blob/main/doc/connections.md) |
| History, storage adapters, and live-run replay | [Persistence and resume](https://github.com/seifalmotaz/tanstack-ai-dart/blob/main/doc/persistence.md) |
| Typed tools, schemas, approvals, and interrupts | [Tools and interrupts](https://github.com/seifalmotaz/tanstack-ai-dart/blob/main/doc/tools-and-interrupts.md) |
| Generation, video, and result snapshots | [Generation](https://github.com/seifalmotaz/tanstack-ai-dart/blob/main/doc/generation.md) |
| Flutter integration, BYOK, and host capabilities | [Platform support](https://github.com/seifalmotaz/tanstack-ai-dart/blob/main/doc/platform-support.md) |
| Public imports and API entry points | [API reference map](https://github.com/seifalmotaz/tanstack-ai-dart/blob/main/doc/api-reference.md) |

The core has no Flutter dependency. Flutter apps can use
`StreamBuilder<ChatSnapshot>` or their existing state-management library.
Audio, WebAuthn, device storage, WebSocket sockets, and MCP host integration need
application-supplied implementations. See the platform guide before choosing a
feature that depends on hardware or a browser host.

## Compatibility

Behavior is checked against the pinned official client tests. Dart uses enums,
named configuration, typed response variants, and streams. TypeScript conditional
inference and JavaScript call signatures are not the Dart API contract.

Read [API compatibility](https://github.com/seifalmotaz/tanstack-ai-dart/blob/main/API_COMPATIBILITY.md), [parity methodology](https://github.com/seifalmotaz/tanstack-ai-dart/blob/main/PARITY.md),
and [validation evidence](https://github.com/seifalmotaz/tanstack-ai-dart/blob/main/VALIDATION.md) for the scope and limits. Earlier call
signatures remain available through explicit legacy entry points. Existing
users should read the [0.3 migration guide](https://github.com/seifalmotaz/tanstack-ai-dart/blob/main/MIGRATION.md).

## Contribute and stay current

Start with [CONTRIBUTING.md](https://github.com/seifalmotaz/tanstack-ai-dart/blob/main/CONTRIBUTING.md). The
[upstream update guide](https://github.com/seifalmotaz/tanstack-ai-dart/blob/main/doc/maintainers/upstream-updates.md) explains how to
review new official TypeScript changes, update the port and mappings, and prove
compatibility before advancing the supported version. The
[release guide](https://github.com/seifalmotaz/tanstack-ai-dart/blob/main/doc/maintainers/releasing.md) covers public releases.

Ask usage questions in
[Discussions](https://github.com/seifalmotaz/tanstack-ai-dart/discussions).
Read the [community guidelines](https://github.com/seifalmotaz/tanstack-ai-dart/blob/main/CODE_OF_CONDUCT.md)
and [private security reporting policy](https://github.com/seifalmotaz/tanstack-ai-dart/blob/main/SECURITY.md).

Report reproducible Dart SDK problems in
[GitHub issues](https://github.com/seifalmotaz/tanstack-ai-dart/issues).
Include the SDK version, transport, platform, and a sanitized reproduction.

## Documentation for coding assistants

Use [llms.txt](https://raw.githubusercontent.com/seifalmotaz/tanstack-ai-dart/main/llms.txt) as the documentation index or
[llms-full.txt](https://raw.githubusercontent.com/seifalmotaz/tanstack-ai-dart/main/llms-full.txt) for the combined reference. Both are generated
from the same documentation and examples used by contributors.

## License

[MIT](https://github.com/seifalmotaz/tanstack-ai-dart/blob/main/LICENSE). Upstream code and attribution are recorded in
[THIRD_PARTY_NOTICES](https://github.com/seifalmotaz/tanstack-ai-dart/blob/main/THIRD_PARTY_NOTICES).
