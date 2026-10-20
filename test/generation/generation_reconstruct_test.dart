// Covers `packages/ai-client/src/generation-reconstruct.ts`. The upstream
// suite exercises the image mapper through the client restore path; the other
// activity mappers are pinned here directly.
import 'package:tanstack_ai_dart/generation.dart';
import 'package:test/test.dart';

PersistedArtifactRef artifact({
  String activity = 'image',
  String mediaType = 'image',
  String mimeType = 'image/png',
  String? url = '/api/artifacts/a',
  String role = 'output',
}) =>
    PersistedArtifactRef(
      role: role,
      artifactId: 'artifact-1',
      threadId: 'thread-1',
      runId: 'run-1',
      name: 'file',
      mimeType: mimeType,
      size: 10,
      createdAt: '2026-07-06T00:00:00.000Z',
      url: url,
      source: PersistedArtifactSource(
        activity: activity,
        path: 'thread-1/run-1/file',
        provider: 'test',
        model: 'model',
        mediaType: mediaType,
      ),
    );

GenerationRestoredResult restored({
  List<PersistedArtifactRef> artifacts = const [],
  String? text,
  Map<String, dynamic>? usage,
}) =>
    GenerationRestoredResult(
      id: 'result-1',
      model: 'model-1',
      text: text,
      usage: usage,
      artifacts: artifacts,
    );

void main() {
  test('reconstructImageResult maps durable output image urls', () {
    expect(
      reconstructImageResult(restored(artifacts: [
        artifact(),
        artifact(url: null),
        artifact(role: 'input'),
      ])),
      {
        'id': 'result-1',
        'model': 'model-1',
        'images': [
          {'url': '/api/artifacts/a'}
        ],
        'artifacts': [
          artifact().toJson(),
          artifact(url: null).toJson(),
          artifact(role: 'input').toJson(),
        ],
      },
    );
    expect(reconstructImageResult(restored()), isNull);
  });

  test('reconstructAudioResult maps the first durable audio url', () {
    expect(
      reconstructAudioResult(restored(artifacts: [
        artifact(
          activity: 'audio',
          mediaType: 'audio',
          mimeType: 'audio/mpeg',
          url: '/api/artifacts/audio',
        ),
      ])),
      {
        'id': 'result-1',
        'model': 'model-1',
        'audio': {'url': '/api/artifacts/audio'},
        'artifacts': [
          artifact(
            activity: 'audio',
            mediaType: 'audio',
            mimeType: 'audio/mpeg',
            url: '/api/artifacts/audio',
          ).toJson(),
        ],
      },
    );
    expect(reconstructAudioResult(restored()), isNull);
  });

  test('reconstructSpeechResult keeps audio empty and derives format', () {
    expect(
      reconstructSpeechResult(restored(artifacts: [
        artifact(
          activity: 'tts',
          mediaType: 'audio',
          mimeType: 'audio/wav',
          url: '/api/artifacts/speech',
        ),
      ])),
      {
        'id': 'result-1',
        'model': 'model-1',
        'audio': '',
        'format': 'wav',
        'contentType': 'audio/wav',
        'artifacts': [
          artifact(
            activity: 'tts',
            mediaType: 'audio',
            mimeType: 'audio/wav',
            url: '/api/artifacts/speech',
          ).toJson(),
        ],
      },
    );
    expect(reconstructSpeechResult(restored()), isNull);
  });

  test(
      'reconstructSpeechResult rebuilds a TTSResult that surfaces the durable url via artifacts',
      () {
    final result = reconstructSpeechResult(restored(artifacts: [
      artifact(
          activity: 'tts',
          mediaType: 'audio',
          mimeType: 'audio/mpeg',
          url: '/api/artifacts?id=artifact-speech-1'),
    ]));
    expect(result, isNotNull);
    expect(result!['audio'], '');
    expect(result['contentType'], 'audio/mpeg');
    expect(result['format'], 'mpeg');
    expect((result['artifacts'] as List).first['url'],
        '/api/artifacts?id=artifact-speech-1');
  });

  test(
      'reconstructSpeechResult returns null when no audio output artifact carries a url',
      () {
    expect(reconstructSpeechResult(restored()), isNull);
    expect(
        reconstructSpeechResult(restored(artifacts: [
          artifact(
              activity: 'tts',
              mediaType: 'audio',
              mimeType: 'audio/mpeg',
              url: null),
        ])),
        isNull);
  });

  test('reconstructTranscriptionResult needs persisted text', () {
    expect(
      reconstructTranscriptionResult(restored(text: 'Hello world')),
      {
        'id': 'result-1',
        'model': 'model-1',
        'text': 'Hello world',
      },
    );
    expect(reconstructTranscriptionResult(restored()), isNull);
  });

  test('reconstructSummarizeResult needs persisted text and usage', () {
    expect(
      reconstructSummarizeResult(
        restored(
          text: 'short version',
          usage: const {'promptTokens': 1, 'completionTokens': 2},
        ),
      ),
      {
        'id': 'result-1',
        'model': 'model-1',
        'summary': 'short version',
        'usage': const {'promptTokens': 1, 'completionTokens': 2},
      },
    );
    expect(reconstructSummarizeResult(restored(text: 'short version')), isNull);
    expect(
      reconstructSummarizeResult(
        restored(usage: const {'promptTokens': 1}),
      ),
      isNull,
    );
  });
}
