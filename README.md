# tanstack_ai_dart

Unofficial, community-maintained Dart port of the TanStack AI **client** SDK.
The compatibility target is `@tanstack/ai-client` **0.40.0** with
`@tanstack/ai` **0.70.0**, pinned to upstream commit
`7095ebbf1b59175f0cd339c1c477d6af55b312de`.

This package is not maintained by TanStack. The expanded client is undergoing
parity verification; see [PARITY.md](PARITY.md) for the baseline, verification
commands, and platform boundaries. Do not infer parity from a test count.

The endpoint, authentication, tenant rules, models, and provider keys remain
caller-owned. No PinCRM URL or application credentials are embedded here.
Legacy `SseChatTransport` and approval helpers remain available for applications
using the earlier `@tanstack/ai` 0.42 protocol.

## Modern client

```dart
import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';

final client = ChatClient(
  threadId: 'conversation-123',
  connection: fetchServerSentEvents(
    'https://your-service.example/api/chat',
    FetchConnectionOptions(headers: {'Authorization': 'Bearer YOUR_TOKEN'}),
  ),
);
final unsubscribe = client.subscribeSnapshot(() {
  final snapshot = client.getSnapshot();
  // Rebuild the UI from snapshot.messages, status, error, and loading state.
});
await client.sendMessage('Hello');
unsubscribe();
await client.dispose();
```

The root library exports chat, connection adapters, generation/video, tools,
processing, BYOK, persistence, and devtools. Domain-specific imports are also
available: `chat.dart`, `connections.dart`, `generation.dart`, `platform.dart`,
`processing.dart`, `byok.dart`, `devtools.dart`, and `ui.dart`.

Connection hydration returns JSON messages; `connections.ChatHydrationResult`
and the turn-based chat hydration result are available through their respective
qualified libraries. Shared resume pointers, paging options, cancellation, and
tool types are the same classes across modules.

## Lifecycle and persistence

Call `attach()` when the consuming view mounts. It restores persisted messages,
hydrates server history, and rejoins a live run when supported. Constructing a
client does not open a replay connection. Call `detach()` when the view leaves,
and `dispose()` when the client is no longer needed. `subscribeSnapshot()`
listens for UI updates; `subscribe()` controls a persistent push transport.

Persistence choices are explicit:

- Omitted or `false`: ephemeral conversation.
- `true`, with `threadId`: server-authoritative history through the adapter's
  `hydrate`/`joinRun` methods.
- A `ChatClientPersistence` adapter, with `threadId`: client-authoritative
  storage of messages and the resume pointer in one record.

`ChatPersistenceOptions.server(...)`, `.stored(...)`, and `.ephemeral(...)`
provide typed configuration. History paging belongs to the server option.
The legacy transport also retains its original custom history callback support.

## Dart typing

Use explicit `ClientTool<TInput, TOutput>` types and a validating `ToolSchema`.
The callback receives `ToolCallContext`, including its cancellation signal and
caller context. JSON-shaped inputs can use `Map<String, dynamic>`; a schema may
validate and transform values into a custom Dart model.

`ui.dart` exposes typed tool, result, structured-output and interrupt selectors.
Tool selectors infer generic parameters from the registered `ClientTool`.
Dart cannot reproduce TypeScript's schema-derived conditional types or literal
string-key unions. Explicit generic parameters and runtime validation are used
instead; the type mapping files record those differences. Unknown tool-option
keys and arbitrary caller-context shapes are not statically inferred.

## Install

This is a draft GitHub checkpoint, not a pub.dev release. See
[NEXT_STEPS.md](NEXT_STEPS.md) for the remaining work.

```yaml
dependencies:
  tanstack_ai_dart:
    git:
      url: https://github.com/seifalmotaz/tanstack-ai-dart.git
      ref: feat/client-sdk
```

Requires Dart `>=3.6.0 <4.0.0`.

## Quick start (transport only)

This example performs a real HTTP request when you run it. Point `endpoint` at
your own chat route.

```dart
import 'dart:convert';
import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';

Future<void> main() async {
  final transport = SseChatTransport(
    'http://localhost:3000/ai/chat', // caller-owned endpoint
    headers: () => {'Content-Type': 'application/json'},
    onUnauthorized: () async {
      // Refresh credentials here; headers() is re-evaluated afterwards.
    },
  );

  final turns = <AssistantTurn>[AssistantTurn.user('Hello')];
  final body = assistantChatBody(null, turns); // legacy body shape

  await for (final event in transport.stream(body)) {
    print(jsonEncode(event));
  }
}
```

## Quick start (optional client)

`ChatClient` also accepts the legacy transport shown above. This preserves
existing event folding and approval continuation behavior.

```dart
final client = ChatClient(
  transport: transport,
  onChanged: () {
    // Rebuild your UI from client.messages / client.status / client.error.
  },
);

await client.sendText('Show me unassigned leads');

// Later, when a tool part has an approval request:
final tool = client.messages.last.tools.firstWhere(
  (p) => p.approval != null,
);
await client.approve(tool, true);  // or false to deny
await client.stop();               // cancellation closes the HTTP client
```

## Transport API

```dart
SseChatTransport(
  String endpoint, {
  required FutureOr<Map<String, String>> Function() headers,
  http.Client Function()? clientFactory,
  Future<void> Function()? onUnauthorized,
  Duration connectTimeout = const Duration(seconds: 30),
  Duration idleTimeout = const Duration(seconds: 90),
});

Stream<Map<String, dynamic>> stream(Map<String, dynamic> body);
```

Behavior:

- SSE is parsed incrementally, so split UTF-8 sequences, LF/CRLF/lone-CR
  line endings, a leading UTF-8 BOM, comments, `id`/`event` fields, and blank
  frames are handled.
- Multiple `data:` lines in one event are joined with `\n`.
- Unknown event `type`s are passed through as maps.
- Malformed JSON data throws a `FormatException` on the stream.
- `[DONE]`, EOF, and `RUN_ERROR` complete the stream. `RUN_FINISHED` is
  forwarded but does **not** close it: the legacy agent loop emits one
  `RUN_FINISHED` per model iteration (see
  `stream-transcript.ts` in the reference backend), so closing at the first
  one would drop tool results, approvals, and the final answer.
- Cancelling the subscription cancels the response subscription and closes the
  per-stream HTTP client immediately, even if the server is silent.
- A 401 triggers one refresh via `onUnauthorized`, re-evaluates `headers`, and
  replays the exact original body. Partial streams are never retried; non-401
  statuses are never retried.
- Non-2xx responses throw `ChatTransportException` with `status`, `code`, and
  `message`. Plain text and nested `{ "error": { "code", "message" } }` bodies
  are both understood.
- `connectTimeout` covers the request until response headers; `idleTimeout`
  covers silence between response bytes.

## Tested request protocol

`assistantChatBody` sends TanStack UI messages with `parts`, matching the
React client's server input on TanStack AI 0.42.x. Approval IDs and decisions
MUST remain in tool-call parts: TanStack extracts these before converting
messages to the model format. Sending only a synthetic tool result loses the
approval state and can cause another approval request instead of execution.

```json
{
  "id": "a1", "role": "assistant",
  "parts": [{
    "type": "tool-call", "id": "tc1", "name": "assign_lead",
    "arguments": "{\"leadId\":\"l1\"}",
    "state": "approval-responded",
    "approval": {"id": "approval_tc1", "needsApproval": true, "approved": true}
  }]
}
```

Absent `output` is omitted, never sent as null: TanStack treats a present output
as a completed result. Reasoning and empty assistant placeholders are omitted
from outbound wire messages. `assistantWireMessages` produces this UI shape;
`assistantModelMessages` is a lower-level projection for inspection/integrations
that explicitly expect model messages. It does not preserve approval metadata
and must not replace UI messages for an approval continuation.

The server converts an approved UI part to an internal tool message whose
content is `{"approved":true,"pendingExecution":true,"message":"User approved this action"}`.
Denial sets `approved:false` and omits `pendingExecution`.

### SSE events consumed by the reducer

`TEXT_MESSAGE_START`, `TEXT_MESSAGE_CONTENT`/`CHUNK`, `TEXT_MESSAGE_END`,
`THINKING_*`/`REASONING_*`, `TOOL_CALL_START`, `TOOL_CALL_ARGS`/`CHUNK`,
`TOOL_CALL_END`, `TOOL_CALL_RESULT`, `CUSTOM`, `RUN_FINISHED`, `RUN_ERROR`.

Approval requests arrive either as a custom event:

```json
{
  "type":"CUSTOM",
  "name":"approval-requested",
  "value":{
    "toolCallId":"tc1",
    "toolName":"assign_lead",
    "input":{"leadId":"l1"},
    "approval":{"id":"approval_tc1","needsApproval":true}
  }
}
```

or as a `RUN_FINISHED` interrupt:

```json
{
  "type":"RUN_FINISHED",
  "outcome":{
    "type":"interrupt",
    "interrupts":[{
      "id":"approval_tc9",
      "reason":"approval_required",
      "toolCallId":"tc9",
      "metadata":{"kind":"approval","toolName":"bulk_assign_leads","input":{}}
    }]
  }
}
```

Thinking/reasoning parts are never merged into `AssistantTurn.answer`.

`assistantChatBody(threadId, turns)` optionally adds `durableThreadId`,
`threadId`, `forwardedProps`, and `data` when `threadId` is non-empty. Omit it
if your server does not use durable threads.

## License

MIT. Original extracted code © 2026 SeifAlmotaz.
