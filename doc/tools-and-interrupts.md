# Tools and interrupts

Tools run application code on the client. Define the input, output, validation,
and approval policy deliberately. The SDK does not grant access to operating
system or business actions on its own.

Import `package:tanstack_ai_dart/tanstack_ai_dart.dart` for the examples below.

## Define a typed tool

Use `ClientTool<TInput, TOutput>` in an ordinary Dart list. A validating schema
can decode raw wire values into an application model before execution:

<!-- example: example/recipes.dart#tool -->
```dart
ClientTool<String, int> lengthTool() => ClientTool<String, int>(
      name: 'length',
      description: 'Count characters in text',
      inputSchema: StandardSchema(
        (value) => value is String
            ? SchemaValidationResult.success(value)
            : const SchemaValidationResult.failure(
                [SchemaIssue('Expected text')],
              ),
        schema: {'type': 'string'},
      ),
      execute: (text, context) => text.length,
    );
```
<!-- /example -->

Register it with `client.tools = [lengthTool()]`, or pass the list to the chat
constructor. Execution callbacks return `FutureOr<TOutput>` and receive a
`ToolCallContext` containing caller context, thread and tool-call IDs, and cancellation.

`RawJsonSchema` describes a schema but does not validate inputs. Use
`StandardSchema` when validation or decoding is required. Output schemas can
validate the returned value as well. The Dart type arguments describe the
callback contract; they do not derive a runtime validator from a Dart class.

## Request approval

Set `needsApproval: true` on a tool whose execution requires the user's choice.
Render pending approvals from the client's interrupt/tool state. When the user
answers an approval interrupt:

<!-- example: example/recipes.dart#approval -->
```dart
void answerApproval(ChatInterrupt interrupt, bool approved) {
  interrupt.resolveApproval(approved);
}
```
<!-- /example -->

Approval response submission and automatic continuation use the active run
context. Do not submit a normal message while a blocking interrupt is pending.
The client rejects that operation so the interrupted run is not bypassed.

For manually executed tools, use `addToolResult(toolCallId: ..., output: ...)`
with the ID supplied by the active tool call. Preserve explicit `null` outputs;
missing output and an output whose value is `null` are different protocol states.

## Handle generic interrupts

`ChatInterruptDefinition` registers an interrupt and optional schemas/validation.
Inspect `client.getInterruptState()` or `snapshot.interruptState` for pending
items. `resolveInterrupts`, `cancelInterrupts`, and `retryInterrupts` operate on
managed pending definitions. `resumeInterruptsUnsafe` accepts serialized
resolution entries with an explicit interrupted thread and run for recovery.

Keep the server's interrupt IDs and response shape intact. Low-level unsafe
resume operations require explicit durable IDs and should be reserved for an
integration that owns those IDs. Never infer an approval from the language
model's text response.

## Keep application context typed at the boundary

Caller context is `Object?` because one client may register heterogeneous tools.
Validate or cast it to your own model before using it. Dart does not reproduce
TypeScript intersections of every registered tool's context requirements.
See [API compatibility](../API_COMPATIBILITY.md) for other language adaptations.
