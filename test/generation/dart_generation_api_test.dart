import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';
import 'package:test/test.dart';

void main() {
  test(
      'typed generation values preserve raw result and publish immutable state',
      () async {
    final raw = {'id': 'result', 'model': 'model'};
    final client = GenerationClient<String, Map<String, String>,
        Map<String, String>>.fetcher(
      persistence:
          const GenerationPersistenceOptions.ephemeral(threadId: 'thread'),
      fetcher: (input, options) => GenerationFetchResult.value(raw),
    );
    final states = <GenerationClientSnapshot<Map<String, String>>>[];
    final sub = client.states.listen(states.add);
    await client.generate('prompt');
    await Future<void>.delayed(Duration.zero);
    expect(client.state, GenerationClientState.success);
    expect(client.result, same(raw));
    expect(() => client.snapshot.result!['id'] = 'changed',
        throwsUnsupportedError);
    expect(client.resumeSnapshot?.result?.id, 'result');
    expect(states.first.status, GenerationClientState.idle);
    expect(states.last.status, GenerationClientState.success);
    client.dispose();
    await sub.cancel();
    expect(await client.states.toList(), isEmpty);
  });

  test('generation stream result parses the upstream chunk protocol', () async {
    final client = GenerationClient<String, String, String>.fetcher(
      fetcher: (_, options) =>
          GenerationFetchResult.stream(Stream.fromIterable([
        {'type': 'RUN_STARTED', 'threadId': 'thread', 'runId': 'run'},
        {'type': 'CUSTOM', 'name': GenerationEvents.result, 'value': 'hello'},
        {'type': 'RUN_FINISHED', 'threadId': 'thread', 'runId': 'run'},
      ])),
    );
    await client.generate('prompt');
    expect(client.state, GenerationClientState.success);
    expect(client.result, 'hello');
    client.dispose();
  });

  test('typed HTTP generation preserves HTTP status failures', () async {
    final client = GenerationClient<String, String, String>.fetcher(
      fetcher: (_, options) => GenerationFetchResult.response(
          http.StreamedResponse(Stream.value(utf8.encode('unavailable')), 503,
              reasonPhrase: 'Unavailable')),
    );
    await client.generate('prompt');
    expect(client.state, GenerationClientState.error);
    expect(client.error, isA<HttpStatusException>());
    client.dispose();
  });

  test('video typed values and streams use the same state lifecycle', () async {
    final client = VideoGenerationClient<VideoGenerateResult>.fetcher(
      fetcher: (_, options) => const GenerationFetchResult.value(
          VideoGenerateResult(
              jobId: 'job', url: 'https://example.test/video.mp4')),
    );
    final states = <VideoGenerationClientSnapshot<VideoGenerateResult>>[];
    final sub = client.states.listen(states.add);
    await client.generate(const VideoGenerateInput(prompt: 'A scene'));
    await Future<void>.delayed(Duration.zero);
    expect(client.state, GenerationClientState.success);
    expect(client.result?.jobId, 'job');
    expect(states.first.status, GenerationClientState.idle);
    expect(states.last.result?.jobId, 'job');
    client.dispose();
    await sub.cancel();
    expect(await client.states.toList(), isEmpty);
  });
  test('typed video HTTP fetchers preserve non-success status errors',
      () async {
    final client = VideoGenerationClient<VideoGenerateResult>.fetcher(
      fetcher: (_, options) => GenerationFetchResult.response(
          http.StreamedResponse(Stream.value(utf8.encode('unavailable')), 503)),
    );
    await client.generate(const VideoGenerateInput(prompt: 'A scene'));
    expect(client.error, isA<HttpStatusException>());
    expect(client.state, GenerationClientState.error);
    client.dispose();
  });
  test('typed generation stream cancellation releases a quiet source',
      () async {
    final source = StreamController<StreamChunk>();
    final listening = Completer<void>();
    source.onListen = listening.complete;
    final client = GenerationClient<String, String, String>.fetcher(
      fetcher: (_, options) => GenerationFetchResult.stream(source.stream),
    );
    final run = client.generate('prompt');
    await listening.future;
    client.stop();
    await run.timeout(const Duration(seconds: 1));
    expect(source.hasListener, isFalse);
    expect(client.state, GenerationClientState.idle);
    expect(client.error, isNull);
    await source.close();
    client.dispose();
  });
}
