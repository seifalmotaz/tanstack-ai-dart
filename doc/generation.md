# Generation and video

Import `package:tanstack_ai_dart/tanstack_ai_dart.dart`. Use the default
`GenerationClient` constructor with a connection, or `.fetcher` for a typed
application request. Video uses `VideoGenerationClient`.

## Return a typed result

The three `GenerationClient<TInput, TResult, TOutput>` parameters represent the
request, raw result, and published output. They can be the same result type when
no transformation is needed:

<!-- example: example/recipes.dart#generation -->
```dart
Future<String?> generateText(
  Future<String> Function(String prompt, CancellationSignal signal) request,
  String prompt,
) async {
  final generator = GenerationClient<String, String, String>.fetcher(
    fetcher: (input, options) async => GenerationFetchResult.value(
      await request(input, options.signal),
    ),
  );
  try {
    await generator.generate(prompt);
    if (generator.error != null) throw generator.error!;
    return generator.result;
  } finally {
    generator.dispose();
  }
}
```
<!-- /example -->

The `request` function belongs to the application. It receives the SDK's
cancellation signal. `GenerationFetchResult.value(...)` wraps a result;
`.stream(...)` wraps decoded TanStack chunks; `.response(...)` wraps a
`package:http` streaming response. These variants keep transport responses
separate from application data.

`generate()` reports request failures through `error` and the state stream.
Check the error after awaiting it. `snapshot`, `states`, `state`, `result`, and
`isLoading` provide the current lifecycle. Generation client `stop()` and
`dispose()` are synchronous; chat's corresponding methods return futures.

## Generate video

The video fetcher receives `VideoGenerateInput` and returns a `VideoGenerateResult`:

<!-- example: example/recipes.dart#video -->
```dart
VideoGenerationClient<VideoGenerateResult> videoClient(
  Future<VideoGenerateResult> Function(
    VideoGenerateInput input,
    GenerationFetcherOptions options,
  ) request,
) =>
    VideoGenerationClient<VideoGenerateResult>.fetcher(
      fetcher: (input, options) async => GenerationFetchResult.value(
        await request(input, options),
      ),
    );
```
<!-- /example -->

Call `generate(VideoGenerateInput(...))` on the returned client, then inspect
`jobId`, `videoStatus`, and result state. The backend owns provider jobs and
artifact serving; the SDK does not create a video-provider service.

## Transform and restore

`onResult` can return a `GenerationTransformOutcome<TOutput>` to publish a
transformed result or preserve the prior value. `reconstructResult` handles
server-restored artifact records. Media-specific reconstruction helpers include
`reconstructImageResult`, `reconstructAudioResult`, and
`reconstructTranscriptionResult`.

Use `GenerationPersistenceOptions.persistent(threadId: ...)` for server-driven
persistence. The thread ID must stay stable across reloads, and the connection
must implement compatible generation hydration and replay. The default is
`.ephemeral(...)`.

## Preserve snapshot ownership

JSON maps/lists and scalar-typed JSON collections are copied read-only for
publication. The `result` getter retains the original result. Status changes
preserve the published result identity when that result has not changed.
Opaque class instances retain identity; use immutable models.

Other reified collection shapes need an explicit `copySnapshotResult` callback.
For a result such as `Map<String, List<int>>`, use this function:

<!-- example: example/recipes.dart#copier -->
```dart
Map<String, List<int>> copyScores(Map<String, List<int>> value) =>
    Map<String, List<int>>.unmodifiable({
      for (final entry in value.entries)
        entry.key: List<int>.unmodifiable(entry.value),
    });
```
<!-- /example -->

A missing compatible copier produces `SnapshotCopyException` in client error
state. A supplied copier must isolate its result and freeze nested mutable data.
