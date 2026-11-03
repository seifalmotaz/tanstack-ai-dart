/// Ported from `packages/ai-client/src/generation-types.ts` (TanStack AI
/// client 0.40.0).
///
/// Wire payloads (stream chunks, hydrated records, artifact refs) stay JSON
/// maps because the protocol is extensible. Configuration and client state are
/// typed classes.
library;

import 'dart:async';

import '../connections/cancellation.dart';
import '../connections/connection_adapter.dart';
import '../connections/types.dart';
import '../connections/wire.dart';

/// Canonical connection transport surface from `lib/connections.dart`.
typedef GenerationConnection = ConnectionAdapter;

/// State machine for generation clients.
enum GenerationClientState {
  idle,
  generating,
  success,
  error;

  String get wire => name;
}

/// Status of a persisted/restored generation run.
enum GenerationResumeStatus {
  idle,
  running,
  complete,
  error;

  String get wire => name;
}

/// UI snapshot published by `GenerationClient.subscribe` / `getSnapshot`.
class GenerationClientSnapshot<TOutput> {
  final TOutput? result;
  final bool isLoading;
  final Object? error;
  final GenerationClientState status;
  final String? runId;

  const GenerationClientSnapshot({
    required this.result,
    required this.isLoading,
    required this.error,
    required this.status,
    required this.runId,
  });

  const GenerationClientSnapshot.initial()
      : result = null,
        isLoading = false,
        error = null,
        status = GenerationClientState.idle,
        runId = null;
}

/// UI snapshot published by `VideoGenerationClient`.
class VideoGenerationClientSnapshot<TOutput>
    extends GenerationClientSnapshot<TOutput> {
  final String? jobId;
  final VideoStatusInfo? videoStatus;

  const VideoGenerationClientSnapshot({
    required super.result,
    required super.isLoading,
    required super.error,
    required super.status,
    required super.runId,
    required this.jobId,
    required this.videoStatus,
  });

  const VideoGenerationClientSnapshot.initial()
      : jobId = null,
        videoStatus = null,
        super.initial();
}

/// Thrown when a generation stream ends without a terminal chunk.
const String generationStreamTruncatedMessage =
    'The generation stream ended before the run finished (no RUN_FINISHED or RUN_ERROR was received) — the connection was interrupted. Generate again to retry.';

/// Reported when a restored snapshot says the run completed but the activity's
/// `reconstructResult` mapper cannot rebuild a result.
const String generationUnrestorableResultMessage =
    'The stored generation completed but its result could not be rebuilt from the persisted record (its output artifact carries no serve URL, or the fields this activity needs were not persisted). Generate again to produce a fresh result.';

/// Wrap a mount-hydration failure with context.
GenerationError createGenerationHydrationError(
  String detail, [
  Object? cause,
]) {
  final suffix = cause == null ? '' : ': ${_causeMessage(cause)}';
  return GenerationError(
    '[TanStack AI] Restoring the last generation for this thread failed — '
    '$detail$suffix',
    cause: cause,
  );
}

String _causeMessage(Object cause) {
  if (cause is GenerationError) return cause.message;
  final text = cause.toString();
  return text.replaceFirst(RegExp(r'^[^:]+:\s*'), '');
}

/// Map a persisted resume status to the client's live state machine.
GenerationClientState clientStateFromResumeStatus(
  GenerationResumeStatus status,
) {
  switch (status) {
    case GenerationResumeStatus.complete:
      return GenerationClientState.success;
    case GenerationResumeStatus.error:
      return GenerationClientState.error;
    case GenerationResumeStatus.running:
      return GenerationClientState.generating;
    case GenerationResumeStatus.idle:
      return GenerationClientState.idle;
  }
}

/// A client-side error with a stable [message] and optional [code].
class GenerationError implements Exception {
  final String message;
  final String? code;
  final Object? cause;

  const GenerationError(this.message, {this.code, this.cause});

  @override
  String toString() => 'GenerationError: $message';
}

/// Persisted artifact source metadata.
class PersistedArtifactSource {
  final String activity;
  final String path;
  final String provider;
  final String model;
  final String? mediaType;
  final String? jobId;
  final String? expiresAt;

  const PersistedArtifactSource({
    required this.activity,
    required this.path,
    required this.provider,
    required this.model,
    this.mediaType,
    this.jobId,
    this.expiresAt,
  });

  Map<String, dynamic> toJson() => {
        'activity': activity,
        'path': path,
        'provider': provider,
        'model': model,
        if (mediaType != null) 'mediaType': mediaType,
        if (jobId != null) 'jobId': jobId,
        if (expiresAt != null) 'expiresAt': expiresAt,
      };

  @override
  bool operator ==(Object other) =>
      other is PersistedArtifactSource &&
      activity == other.activity &&
      path == other.path &&
      provider == other.provider &&
      model == other.model &&
      mediaType == other.mediaType &&
      jobId == other.jobId &&
      expiresAt == other.expiresAt;

  @override
  int get hashCode => Object.hash(
        activity,
        path,
        provider,
        model,
        mediaType,
        jobId,
        expiresAt,
      );
}

/// Sanitized persisted artifact reference kept in resume snapshots.
class PersistedArtifactRef {
  final String role;
  final String artifactId;
  final String threadId;
  final String runId;
  final String name;
  final String mimeType;
  final num size;
  final String createdAt;
  final String? sourceUrl;
  final String? url;
  final PersistedArtifactSource source;

  const PersistedArtifactRef({
    required this.role,
    required this.artifactId,
    required this.threadId,
    required this.runId,
    required this.name,
    required this.mimeType,
    required this.size,
    required this.createdAt,
    required this.source,
    this.sourceUrl,
    this.url,
  });

  Map<String, dynamic> toJson() => {
        'role': role,
        'artifactId': artifactId,
        'threadId': threadId,
        'runId': runId,
        'name': name,
        'mimeType': mimeType,
        'size': size,
        'createdAt': createdAt,
        if (sourceUrl != null) 'sourceUrl': sourceUrl,
        if (url != null) 'url': url,
        'source': source.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      other is PersistedArtifactRef &&
      role == other.role &&
      artifactId == other.artifactId &&
      threadId == other.threadId &&
      runId == other.runId &&
      name == other.name &&
      mimeType == other.mimeType &&
      size == other.size &&
      createdAt == other.createdAt &&
      sourceUrl == other.sourceUrl &&
      url == other.url &&
      source == other.source;

  @override
  int get hashCode => Object.hash(
        role,
        artifactId,
        threadId,
        runId,
        name,
        mimeType,
        size,
        createdAt,
        sourceUrl,
        url,
        source,
      );
}

/// In-flight run identity plus artifact refs observed while streaming.
class GenerationResumeState {
  final String threadId;
  final String runId;
  final List<PersistedArtifactRef>? pendingArtifacts;

  const GenerationResumeState({
    required this.threadId,
    required this.runId,
    this.pendingArtifacts,
  });

  Map<String, dynamic> toJson() => {
        'threadId': threadId,
        'runId': runId,
        if (pendingArtifacts != null && pendingArtifacts!.isNotEmpty)
          'pendingArtifacts':
              pendingArtifacts!.map((artifact) => artifact.toJson()).toList(),
      };
}

/// Persisted result metadata.
class GenerationResultSnapshot {
  final String? id;
  final String? model;
  final String? status;
  final String? providerJobId;
  final String? expiresAt;
  final String? text;
  final Map<String, dynamic>? usage;
  final List<PersistedArtifactRef>? artifacts;

  const GenerationResultSnapshot({
    this.id,
    this.model,
    this.status,
    this.providerJobId,
    this.expiresAt,
    this.text,
    this.usage,
    this.artifacts,
  });

  GenerationResultSnapshot copyWith({String? providerJobId}) =>
      GenerationResultSnapshot(
        id: id,
        model: model,
        status: status,
        providerJobId: providerJobId ?? this.providerJobId,
        expiresAt: expiresAt,
        text: text,
        usage: usage,
        artifacts: artifacts,
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        if (model != null) 'model': model,
        if (status != null) 'status': status,
        if (providerJobId != null) 'providerJobId': providerJobId,
        if (expiresAt != null) 'expiresAt': expiresAt,
        if (text != null) 'text': text,
        if (usage != null) 'usage': usage,
        if (artifacts != null && artifacts!.isNotEmpty)
          'artifacts': artifacts!.map((artifact) => artifact.toJson()).toList(),
      };
}

/// Persisted error metadata.
class GenerationErrorSnapshot {
  final String message;
  final String? code;

  const GenerationErrorSnapshot({required this.message, this.code});

  Map<String, dynamic> toJson() => {
        'message': message,
        if (code != null) 'code': code,
      };
}

/// Persisted last stream event metadata.
class GenerationEventSnapshot {
  final String type;
  final String? name;
  final num? timestamp;

  const GenerationEventSnapshot(
      {required this.type, this.name, this.timestamp});

  Map<String, dynamic> toJson() => {
        'type': type,
        if (name != null) 'name': name,
        if (timestamp != null) 'timestamp': timestamp,
      };
}

/// Lightweight snapshot persisted per generation run.
class GenerationResumeSnapshot {
  static const Object _unset = Object();

  final int schemaVersion;
  final GenerationResumeState? resumeState;
  final GenerationResumeStatus status;
  final String? activity;
  final List<PersistedArtifactRef>? pendingArtifacts;
  final GenerationResultSnapshot? result;
  final GenerationErrorSnapshot? error;
  final GenerationEventSnapshot? lastEvent;

  const GenerationResumeSnapshot({
    this.schemaVersion = 1,
    required this.resumeState,
    required this.status,
    this.activity,
    this.pendingArtifacts,
    this.result,
    this.error,
    this.lastEvent,
  });

  GenerationResumeSnapshot copyWith({
    Object? resumeState = _unset,
    GenerationResumeStatus? status,
    Object? activity = _unset,
    Object? pendingArtifacts = _unset,
    Object? result = _unset,
    Object? error = _unset,
    Object? lastEvent = _unset,
  }) =>
      GenerationResumeSnapshot(
        schemaVersion: schemaVersion,
        resumeState: identical(resumeState, _unset)
            ? this.resumeState
            : resumeState as GenerationResumeState?,
        status: status ?? this.status,
        activity:
            identical(activity, _unset) ? this.activity : activity as String?,
        pendingArtifacts: identical(pendingArtifacts, _unset)
            ? this.pendingArtifacts
            : pendingArtifacts as List<PersistedArtifactRef>?,
        result: identical(result, _unset)
            ? this.result
            : result as GenerationResultSnapshot?,
        error: identical(error, _unset)
            ? this.error
            : error as GenerationErrorSnapshot?,
        lastEvent: identical(lastEvent, _unset)
            ? this.lastEvent
            : lastEvent as GenerationEventSnapshot?,
      );

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'resumeState': resumeState?.toJson(),
        'status': status.wire,
        if (activity != null) 'activity': activity,
        if (pendingArtifacts != null && pendingArtifacts!.isNotEmpty)
          'pendingArtifacts':
              pendingArtifacts!.map((artifact) => artifact.toJson()).toList(),
        if (result != null) 'result': result!.toJson(),
        if (error != null) 'error': error!.toJson(),
        if (lastEvent != null) 'lastEvent': lastEvent!.toJson(),
      };
}

/// The restorable shape handed to a client's `reconstructResult` mapper.
class GenerationRestoredResult {
  final String? id;
  final String? model;
  final String? status;
  final String? providerJobId;
  final String? expiresAt;
  final String? text;
  final Map<String, dynamic>? usage;
  final String? activity;
  final List<PersistedArtifactRef> artifacts;

  const GenerationRestoredResult({
    this.id,
    this.model,
    this.status,
    this.providerJobId,
    this.expiresAt,
    this.text,
    this.usage,
    this.activity,
    required this.artifacts,
  });
}

/// Well-known CUSTOM event names emitted by the server streaming helpers.
abstract final class GenerationEvents {
  static const String result = 'generation:result';
  static const String artifacts = 'generation:artifacts';
  static const String progress = 'generation:progress';
  static const String videoJobCreated = 'video:job:created';
  static const String videoStatus = 'video:status';
}

/// Upstream constant spelling; idiomatic callers may use [GenerationEvents].
// ignore: constant_identifier_names
const GENERATION_EVENTS = <String, String>{
  'RESULT': GenerationEvents.result,
  'ARTIFACTS': GenerationEvents.artifacts,
  'PROGRESS': GenerationEvents.progress,
  'VIDEO_JOB_CREATED': GenerationEvents.videoJobCreated,
  'VIDEO_STATUS': GenerationEvents.videoStatus,
};

/// The `persistence` / `threadId` identity shared by every generation client.
class GenerationPersistenceOptions {
  final bool persistence;
  final String? threadId;

  /// Ephemeral generation. [threadId] is optional.
  const GenerationPersistenceOptions.ephemeral({this.threadId})
      : persistence = false;

  /// Server-driven persistence. A stable [threadId] is required.
  const GenerationPersistenceOptions.persistent({required String this.threadId})
      : persistence = true;

  const GenerationPersistenceOptions({
    this.persistence = false,
    this.threadId,
  });
}

/// Extra request headers for a run (e.g. BYOK keys).
class GenerationFetcherOptions {
  /// Cancelled when the user calls `stop()`.
  final CancellationSignal signal;

  /// Extra request headers for this run.
  final Map<String, String>? headers;

  const GenerationFetcherOptions({required this.signal, this.headers});
}

/// A direct async generation request. Returns either the result or a
/// [GenerationResponse] carrying an SSE body.
typedef GenerationFetcher<TInput> = Future<Object?> Function(
  TInput input,
  GenerationFetcherOptions options,
);

/// A non-streaming (or SSE-streaming) response returned by a fetcher.
class GenerationResponse {
  final int statusCode;
  final String reasonPhrase;
  final Stream<List<int>>? body;

  const GenerationResponse({
    required this.statusCode,
    this.reasonPhrase = '',
    this.body,
  });

  bool get ok => statusCode >= 200 && statusCode < 300;

  /// A 401 body the connection adapters translate into a BYOK request.
  factory GenerationResponse.byokMissing(String provider) {
    final payload = '{"error":{"type":"byok_missing","provider":"$provider",'
        '"message":"Missing $provider API key"}}';
    return GenerationResponse(
      statusCode: 401,
      reasonPhrase: 'Unauthorized',
      body: Stream<List<int>>.value(payload.codeUnits),
    );
  }
}

/// Video status information returned during job polling.
class VideoStatusInfo {
  final String jobId;
  final String status;
  final num? progress;
  final String? url;
  final String? error;

  const VideoStatusInfo({
    required this.jobId,
    required this.status,
    this.progress,
    this.url,
    this.error,
  });

  factory VideoStatusInfo.fromJson(Object? raw) {
    final map = _asMap(raw);
    return VideoStatusInfo(
      jobId: _str(map['jobId']),
      status: _str(map['status']),
      progress: _num(map['progress']),
      url: _strOrNull(map['url']),
      error: _strOrNull(map['error']),
    );
  }

  Map<String, dynamic> toJson() => {
        'jobId': jobId,
        'status': status,
        if (progress != null) 'progress': progress,
        if (url != null) 'url': url,
        if (error != null) 'error': error,
      };

  @override
  bool operator ==(Object other) =>
      other is VideoStatusInfo &&
      jobId == other.jobId &&
      status == other.status &&
      progress == other.progress &&
      url == other.url &&
      error == other.error;

  @override
  int get hashCode => Object.hash(jobId, status, progress, url, error);
}

/// Composite result for video generation (job completion).
class VideoGenerateResult {
  final String jobId;
  final String status;
  final String url;
  final DateTime? expiresAt;
  final List<PersistedArtifactRef>? artifacts;

  const VideoGenerateResult({
    required this.jobId,
    this.status = 'completed',
    required this.url,
    this.expiresAt,
    this.artifacts,
  });

  factory VideoGenerateResult.fromJson(Object? raw) {
    final map = _asMap(raw);
    final expiresAt = map['expiresAt'];
    return VideoGenerateResult(
      jobId: _str(map['jobId']),
      status: _str(map['status'], 'completed'),
      url: _str(map['url']),
      expiresAt: expiresAt is String ? DateTime.tryParse(expiresAt) : null,
      artifacts: map['artifacts'] is List
          ? collectArtifactRefs(map['artifacts'])
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'jobId': jobId,
        'status': status,
        'url': url,
        if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
        if (artifacts != null && artifacts!.isNotEmpty)
          'artifacts': artifacts!.map((artifact) => artifact.toJson()).toList(),
      };
}

/// Input for video generation.
class VideoGenerateInput {
  /// Plain text or an ordered list of content parts.
  final Object? prompt;
  final String? size;
  final num? duration;
  final Map<String, dynamic>? modelOptions;

  const VideoGenerateInput({
    required this.prompt,
    this.size,
    this.duration,
    this.modelOptions,
  });

  Map<String, dynamic> toJson() => {
        'prompt': prompt,
        if (size != null) 'size': size,
        if (duration != null) 'duration': duration,
        if (modelOptions != null) 'modelOptions': modelOptions,
      };
}

/// Input for image generation.
class ImageGenerateInput {
  final Object? prompt;
  final int? numberOfImages;
  final String? size;
  final Map<String, dynamic>? modelOptions;

  const ImageGenerateInput({
    required this.prompt,
    this.numberOfImages,
    this.size,
    this.modelOptions,
  });

  Map<String, dynamic> toJson() => {
        'prompt': prompt,
        if (numberOfImages != null) 'numberOfImages': numberOfImages,
        if (size != null) 'size': size,
        if (modelOptions != null) 'modelOptions': modelOptions,
      };
}

/// Dart has no structural return-type distinction for `void | null | value`;
/// a transform returns one of these explicit outcomes.
sealed class GenerationTransformOutcome<TOutput> {
  const GenerationTransformOutcome();

  const factory GenerationTransformOutcome.value(TOutput value) =
      GenerationTransformValue<TOutput>;
  const factory GenerationTransformOutcome.keep() =
      GenerationTransformKeep<TOutput>;
  const factory GenerationTransformOutcome.raw() =
      GenerationTransformRaw<TOutput>;
}

class GenerationTransformValue<TOutput>
    extends GenerationTransformOutcome<TOutput> {
  final TOutput value;
  const GenerationTransformValue(this.value);
}

class GenerationTransformKeep<TOutput>
    extends GenerationTransformOutcome<TOutput> {
  const GenerationTransformKeep();
}

class GenerationTransformRaw<TOutput>
    extends GenerationTransformOutcome<TOutput> {
  const GenerationTransformRaw();
}

/// Reduces one observed stream chunk into the lightweight resume snapshot.
GenerationResumeSnapshot updateGenerationResumeSnapshot(
  GenerationResumeSnapshot? previous,
  StreamChunk chunk,
) {
  final tanstack = tanstackMetadata(chunk);
  final threadId =
      _strOrNull(chunk['threadId']) ?? _strOrNull(tanstack?['threadId']);
  final runId = _strOrNull(chunk['runId']) ?? _strOrNull(tanstack?['runId']);
  final isRunStarted = chunk['type'] == 'RUN_STARTED';
  final carried = isRunStarted ? null : previous;
  final previousArtifacts = carried?.pendingArtifacts ?? const [];

  var next = GenerationResumeSnapshot(
    schemaVersion: 1,
    resumeState: carried?.resumeState,
    status: carried?.status ?? GenerationResumeStatus.idle,
    activity: carried?.activity,
    pendingArtifacts: previousArtifacts.isNotEmpty
        ? List<PersistedArtifactRef>.of(previousArtifacts)
        : null,
    result: carried?.result,
    error: carried?.error,
    lastEvent: _createGenerationEventSnapshot(chunk),
  );

  if (threadId != null &&
      threadId.isNotEmpty &&
      runId != null &&
      runId.isNotEmpty) {
    next = next.copyWith(
      resumeState: GenerationResumeState(threadId: threadId, runId: runId),
      status: GenerationResumeStatus.running,
    );
  } else if (isRunStarted) {
    next = next.copyWith(status: GenerationResumeStatus.running);
  }

  if (chunk['type'] == 'CUSTOM') {
    if (chunk['name'] == GenerationEvents.artifacts) {
      final artifacts = collectArtifactRefs(chunk['value']);
      if (artifacts.isNotEmpty) {
        next = next.copyWith(
          pendingArtifacts: artifacts,
          activity: artifacts.first.source.activity,
        );
      }
    } else if (chunk['name'] == GenerationEvents.result) {
      final result = createGenerationResultSnapshot(chunk['value']);
      if (result != null) {
        next = next.copyWith(result: result);
        final artifacts = result.artifacts;
        if (artifacts != null && artifacts.isNotEmpty) {
          next = next.copyWith(
            pendingArtifacts: artifacts,
            activity: artifacts.first.source.activity,
          );
        }
      }
    } else if (chunk['name'] == GenerationEvents.videoJobCreated) {
      final value = chunk['value'];
      final providerJobId = value is Map ? _strOrNull(value['jobId']) : null;
      if (providerJobId != null && providerJobId.isNotEmpty) {
        final base = next.result ?? const GenerationResultSnapshot();
        next =
            next.copyWith(result: base.copyWith(providerJobId: providerJobId));
      }
    }
  } else if (chunk['type'] == 'RUN_FINISHED') {
    next = next.copyWith(
      resumeState: null,
      status: GenerationResumeStatus.complete,
    );
  } else if (chunk['type'] == 'RUN_ERROR') {
    next = next.copyWith(
      resumeState: null,
      status: GenerationResumeStatus.error,
      error: _createGenerationErrorSnapshot(chunk),
    );
  }

  return next;
}

/// Validates an untrusted hydrated value into a resume snapshot.
GenerationResumeSnapshot? parseGenerationResumeSnapshot(Object? value) {
  if (value is GenerationResumeSnapshot) {
    return parseGenerationResumeSnapshot(value.toJson());
  }
  if (value is! Map) return null;

  if (value.containsKey('schemaVersion') && value['schemaVersion'] != 1) {
    return null;
  }

  final status = _generationResumeStatusField(value['status']);
  if (status == null) return null;

  final rawResumeState = value['resumeState'];
  GenerationResumeState? resumeState;
  if (rawResumeState != null) {
    if (rawResumeState is! Map) return null;
    final threadId = _strOrNull(rawResumeState['threadId']);
    final runId = _strOrNull(rawResumeState['runId']);
    if (threadId == null ||
        threadId.isEmpty ||
        runId == null ||
        runId.isEmpty) {
      return null;
    }
    resumeState = GenerationResumeState(threadId: threadId, runId: runId);
  }

  String? activity;
  final rawActivity = value['activity'];
  if (rawActivity != null) {
    activity = _persistedArtifactActivityField(rawActivity);
  }

  final pendingArtifacts = collectArtifactRefs(value['pendingArtifacts']);
  final result = createGenerationResultSnapshot(value['result']);

  GenerationErrorSnapshot? error;
  final rawError = value['error'];
  if (rawError is Map) {
    final message = _strOrNull(rawError['message']);
    if (message != null && message.isNotEmpty) {
      final code = _strOrNull(rawError['code']);
      error = GenerationErrorSnapshot(
        message: message,
        code: (code != null && code.isNotEmpty) ? code : null,
      );
    }
  }

  return GenerationResumeSnapshot(
    schemaVersion: 1,
    resumeState: resumeState,
    status: status,
    activity: activity,
    pendingArtifacts: pendingArtifacts.isNotEmpty ? pendingArtifacts : null,
    result: result,
    error: error,
  );
}

/// Narrows an untrusted result payload into the persisted result snapshot.
GenerationResultSnapshot? createGenerationResultSnapshot(Object? value) {
  if (value is GenerationResultSnapshot) {
    return createGenerationResultSnapshot(value.toJson());
  }
  final Map<String, dynamic> map;
  if (value is VideoGenerateResult) {
    map = value.toJson();
  } else if (value is Map) {
    map = _asMap(value);
  } else {
    return null;
  }

  final artifacts = collectArtifactRefs(map['artifacts']);
  final id = _strOrNull(map['id']);
  final model = _strOrNull(map['model']);
  final status = _strOrNull(map['status']);
  final providerJobId =
      _strOrNull(map['providerJobId']) ?? _strOrNull(map['jobId']);
  final text = _strOrNull(map['text']) ?? _strOrNull(map['summary']);
  final usage = map['usage'];

  String? expiresAt;
  final rawExpiresAt = map['expiresAt'];
  if (rawExpiresAt is String) {
    expiresAt = rawExpiresAt;
  } else if (rawExpiresAt is DateTime) {
    expiresAt = rawExpiresAt.toIso8601String();
  }

  final snapshot = GenerationResultSnapshot(
    id: (id != null && id.isNotEmpty) ? id : null,
    model: (model != null && model.isNotEmpty) ? model : null,
    status: (status != null && status.isNotEmpty) ? status : null,
    providerJobId: (providerJobId != null && providerJobId.isNotEmpty)
        ? providerJobId
        : null,
    text: (text != null && text.isNotEmpty) ? text : null,
    usage: usage is Map ? _asMap(usage) : null,
    expiresAt: expiresAt,
    artifacts: artifacts.isNotEmpty ? artifacts : null,
  );

  final hasAny = snapshot.id != null ||
      snapshot.model != null ||
      snapshot.status != null ||
      snapshot.providerJobId != null ||
      snapshot.text != null ||
      snapshot.usage != null ||
      snapshot.expiresAt != null ||
      (snapshot.artifacts?.isNotEmpty ?? false);
  return hasAny ? snapshot : null;
}

/// Validates and sanitizes artifact refs, dropping raw byte fields.
List<PersistedArtifactRef> collectArtifactRefs(Object? value) {
  if (value is! List) return const [];
  final refs = <PersistedArtifactRef>[];
  for (final item in value) {
    final ref = _createPersistedArtifactRefSnapshot(item);
    if (ref != null) refs.add(ref);
  }
  return refs;
}

GenerationEventSnapshot _createGenerationEventSnapshot(StreamChunk chunk) {
  final name = _strOrNull(chunk['name']);
  final timestamp = _num(chunk['timestamp']);
  return GenerationEventSnapshot(
    type: _str(chunk['type']),
    name: (name != null && name.isNotEmpty) ? name : null,
    timestamp: timestamp,
  );
}

GenerationErrorSnapshot _createGenerationErrorSnapshot(StreamChunk chunk) {
  final nested = chunk['error'];
  final message = _strOrNull(chunk['message']) ??
      (nested is Map ? _strOrNull(nested['message']) : null) ??
      'An error occurred';
  final code = _strOrNull(chunk['code']);
  return GenerationErrorSnapshot(
    message: message,
    code: (code != null && code.isNotEmpty) ? code : null,
  );
}

PersistedArtifactRef? _createPersistedArtifactRefSnapshot(Object? value) {
  if (value is! Map) return null;
  final source = value['source'];
  if (source is! Map) return null;

  final role = _persistedArtifactRoleField(value['role']);
  final artifactId = _strOrNull(value['artifactId']);
  final threadId = _strOrNull(value['threadId']);
  final runId = _strOrNull(value['runId']);
  final name = _strOrNull(value['name']);
  final mimeType = _strOrNull(value['mimeType']);
  final size = _num(value['size']);
  final createdAt = _strOrNull(value['createdAt']);
  final activity = _persistedArtifactActivityField(source['activity']);
  final path = _strOrNull(source['path']);
  final provider = _strOrNull(source['provider']);
  final model = _strOrNull(source['model']);

  if (role == null ||
      artifactId == null ||
      artifactId.isEmpty ||
      threadId == null ||
      threadId.isEmpty ||
      runId == null ||
      runId.isEmpty ||
      name == null ||
      name.isEmpty ||
      mimeType == null ||
      mimeType.isEmpty ||
      size == null ||
      createdAt == null ||
      createdAt.isEmpty ||
      activity == null ||
      path == null ||
      path.isEmpty ||
      provider == null ||
      provider.isEmpty ||
      model == null ||
      model.isEmpty) {
    return null;
  }

  final mediaType = _persistedArtifactMediaTypeField(source['mediaType']);
  final jobId = _strOrNull(source['jobId']);
  final expiresAt = _strOrNull(source['expiresAt']);

  return PersistedArtifactRef(
    role: role,
    artifactId: artifactId,
    threadId: threadId,
    runId: runId,
    name: name,
    mimeType: mimeType,
    size: size,
    createdAt: createdAt,
    sourceUrl: _durableUrlField(value['sourceUrl']),
    url: _serveUrlField(value['url']),
    source: PersistedArtifactSource(
      activity: activity,
      path: path,
      provider: provider,
      model: model,
      mediaType: mediaType,
      jobId: (jobId != null && jobId.isNotEmpty) ? jobId : null,
      expiresAt: (expiresAt != null && expiresAt.isNotEmpty) ? expiresAt : null,
    ),
  );
}

String? _durableUrlField(Object? field) {
  if (field is! String || field.isEmpty || field.length > 2048) return null;
  final uri = Uri.tryParse(field);
  if (uri == null || !uri.hasAuthority) return null;
  return (uri.scheme == 'http' || uri.scheme == 'https') ? field : null;
}

String? _serveUrlField(Object? field) {
  if (field is! String || field.isEmpty || field.length > 2048) return null;
  if (field.startsWith('/') &&
      !field.startsWith('//') &&
      !field.contains('\\')) {
    return field;
  }
  final uri = Uri.tryParse(field);
  if (uri == null || !uri.hasAuthority) return null;
  return (uri.scheme == 'http' || uri.scheme == 'https') ? field : null;
}

String? _persistedArtifactRoleField(Object? value) {
  if (value == 'input' || value == 'output') return value as String;
  return null;
}

String? _persistedArtifactActivityField(Object? value) {
  switch (value) {
    case 'image':
    case 'audio':
    case 'tts':
    case 'video':
    case 'transcription':
      return value as String;
    default:
      return null;
  }
}

String? _persistedArtifactMediaTypeField(Object? value) {
  switch (value) {
    case 'image':
    case 'audio':
    case 'video':
    case 'document':
    case 'json':
      return value as String;
    default:
      return null;
  }
}

GenerationResumeStatus? _generationResumeStatusField(Object? value) {
  switch (value) {
    case 'idle':
      return GenerationResumeStatus.idle;
    case 'running':
      return GenerationResumeStatus.running;
    case 'complete':
      return GenerationResumeStatus.complete;
    case 'error':
      return GenerationResumeStatus.error;
    default:
      return null;
  }
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry('$key', item));
  }
  return <String, dynamic>{};
}

String _str(Object? value, [String fallback = '']) =>
    value == null ? fallback : '$value';

String? _strOrNull(Object? value) => value is String ? value : null;

num? _num(Object? value) => value is num ? value : null;
