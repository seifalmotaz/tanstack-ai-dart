/// Ported from `packages/ai-client/src/generation-reconstruct.ts`.
///
/// Per-activity `reconstructResult` mappers. Each mapper rebuilds the concrete
/// typed result from the metadata that survived persistence plus the durable
/// artifact refs, or returns `null` when the snapshot cannot rebuild one.
library;

import 'generation_types.dart';

List<String> _mediaUrls(
  GenerationRestoredResult restored,
  String mediaType,
) =>
    [
      for (final artifact in restored.artifacts)
        if (artifact.role == 'output' &&
            artifact.source.mediaType == mediaType &&
            artifact.url != null)
          artifact.url!,
    ];

/// image → `{ id, model, images: [{ url }], artifacts }`.
Map<String, dynamic>? reconstructImageResult(
  GenerationRestoredResult restored,
) {
  final urls = _mediaUrls(restored, 'image');
  if (urls.isEmpty) return null;
  return {
    'id': restored.id ?? '',
    'model': restored.model ?? '',
    'images': [
      for (final url in urls) {'url': url},
    ],
    if (restored.artifacts.isNotEmpty)
      'artifacts': [
        for (final artifact in restored.artifacts) artifact.toJson(),
      ],
  };
}

/// tts → `{ id, model, audio: '', format, contentType, artifacts }`.
Map<String, dynamic>? reconstructSpeechResult(
  GenerationRestoredResult restored,
) {
  PersistedArtifactRef? ref;
  for (final artifact in restored.artifacts) {
    if (artifact.role == 'output' &&
        artifact.source.mediaType == 'audio' &&
        artifact.url != null) {
      ref = artifact;
      break;
    }
  }
  if (ref == null) return null;
  final contentType = ref.mimeType.isEmpty ? null : ref.mimeType;
  return {
    'id': restored.id ?? '',
    'model': restored.model ?? '',
    'audio': '',
    'format':
        contentType?.split('/').length == 2 ? contentType!.split('/')[1] : '',
    if (contentType != null) 'contentType': contentType,
    'artifacts': [
      for (final artifact in restored.artifacts) artifact.toJson(),
    ],
  };
}

/// audio → `{ id, model, audio: { url }, artifacts }`.
Map<String, dynamic>? reconstructAudioResult(
  GenerationRestoredResult restored,
) {
  final urls = _mediaUrls(restored, 'audio');
  if (urls.isEmpty) return null;
  return {
    'id': restored.id ?? '',
    'model': restored.model ?? '',
    'audio': {'url': urls.first},
    if (restored.artifacts.isNotEmpty)
      'artifacts': [
        for (final artifact in restored.artifacts) artifact.toJson(),
      ],
  };
}

/// transcription → `{ id, model, text, artifacts }`.
Map<String, dynamic>? reconstructTranscriptionResult(
  GenerationRestoredResult restored,
) {
  if (restored.text == null) return null;
  return {
    'id': restored.id ?? '',
    'model': restored.model ?? '',
    'text': restored.text,
    if (restored.artifacts.isNotEmpty)
      'artifacts': [
        for (final artifact in restored.artifacts) artifact.toJson(),
      ],
  };
}

/// summarize → `{ id, model, summary, usage }` (needs persisted `usage`).
Map<String, dynamic>? reconstructSummarizeResult(
  GenerationRestoredResult restored,
) {
  if (restored.text == null || restored.usage == null) return null;
  return {
    'id': restored.id ?? '',
    'model': restored.model ?? '',
    'summary': restored.text,
    'usage': restored.usage,
  };
}
