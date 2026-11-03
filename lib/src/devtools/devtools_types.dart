/// Data types for the TanStack AI devtools surface.
///
/// Ported from `packages/ai-client/src/devtools.ts` (TanStack AI client
/// 0.40.0). The browser event client, chat client and generation clients are
/// replaced by injected event sinks, snapshot readers and tool callbacks so
/// this library stays platform-neutral.
library;

import 'dart:async';

/// Snapshot shape every devtools bridge can serialize into a
/// `hook:state-snapshot` payload.
abstract interface class AIDevtoolsSnapshot {
  Map<String, dynamic> toJson();
}

class AIDevtoolsDisplayOptions {
  final String? name;

  const AIDevtoolsDisplayOptions({this.name});
}

class AIDevtoolsClientMetadata extends AIDevtoolsDisplayOptions {
  final String? framework;
  final String hookName;

  /// `chat`, `text`, `structured`, `image`, `video` or `audio`.
  final String? outputKind;

  const AIDevtoolsClientMetadata({
    super.name,
    this.framework,
    required this.hookName,
    this.outputKind,
  });
}

class AIDevtoolsGenerationProgress {
  final num value;
  final String? message;

  const AIDevtoolsGenerationProgress({required this.value, this.message});

  Map<String, dynamic> toJson() => {
        'value': value,
        if (message != null) 'message': message,
      };

  @override
  bool operator ==(Object other) =>
      other is AIDevtoolsGenerationProgress &&
      other.value == value &&
      other.message == message;

  @override
  int get hashCode => Object.hash(value, message);
}

class AIDevtoolsGenerationMediaItem {
  final String src;

  /// `url` or `base64`.
  final String sourceType;
  final String? mimeType;
  final String? format;
  final num? duration;

  const AIDevtoolsGenerationMediaItem({
    required this.src,
    required this.sourceType,
    this.mimeType,
    this.format,
    this.duration,
  });

  Map<String, dynamic> toJson() => {
        'src': src,
        'sourceType': sourceType,
        if (mimeType != null) 'mimeType': mimeType,
        if (format != null) 'format': format,
        if (duration != null) 'duration': duration,
      };

  @override
  bool operator ==(Object other) =>
      other is AIDevtoolsGenerationMediaItem &&
      other.src == src &&
      other.sourceType == sourceType &&
      other.mimeType == mimeType &&
      other.format == format &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(src, sourceType, mimeType, format, duration);
}

class AIDevtoolsGenerationVideoJob {
  final String jobId;
  final String? status;
  final num? progress;
  final String? error;

  const AIDevtoolsGenerationVideoJob({
    required this.jobId,
    this.status,
    this.progress,
    this.error,
  });

  Map<String, dynamic> toJson() => {
        'jobId': jobId,
        if (status != null) 'status': status,
        if (progress != null) 'progress': progress,
        if (error != null) 'error': error,
      };

  @override
  bool operator ==(Object other) =>
      other is AIDevtoolsGenerationVideoJob &&
      other.jobId == jobId &&
      other.status == status &&
      other.progress == progress &&
      other.error == error;

  @override
  int get hashCode => Object.hash(jobId, status, progress, error);
}

sealed class AIDevtoolsGenerationPreview {
  const AIDevtoolsGenerationPreview();

  String get kind;

  Map<String, dynamic> toJson();
}

class AIDevtoolsImagePreview extends AIDevtoolsGenerationPreview {
  final List<AIDevtoolsGenerationMediaItem> items;

  const AIDevtoolsImagePreview({required this.items});

  @override
  String get kind => 'image';

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'items': items.map((item) => item.toJson()).toList(),
      };

  @override
  bool operator ==(Object other) =>
      other is AIDevtoolsImagePreview && _listEquals(other.items, items);

  @override
  int get hashCode => Object.hashAll(items);
}

class AIDevtoolsAudioPreview extends AIDevtoolsGenerationPreview {
  final List<AIDevtoolsGenerationMediaItem> items;

  const AIDevtoolsAudioPreview({required this.items});

  @override
  String get kind => 'audio';

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'items': items.map((item) => item.toJson()).toList(),
      };

  @override
  bool operator ==(Object other) =>
      other is AIDevtoolsAudioPreview && _listEquals(other.items, items);

  @override
  int get hashCode => Object.hashAll(items);
}

class AIDevtoolsVideoPreview extends AIDevtoolsGenerationPreview {
  final List<AIDevtoolsGenerationMediaItem> items;
  final AIDevtoolsGenerationVideoJob? job;

  const AIDevtoolsVideoPreview({required this.items, this.job});

  @override
  String get kind => 'video';

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'items': items.map((item) => item.toJson()).toList(),
        if (job != null) 'job': job!.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      other is AIDevtoolsVideoPreview &&
      _listEquals(other.items, items) &&
      other.job == job;

  @override
  int get hashCode => Object.hash(Object.hashAll(items), job);
}

class AIDevtoolsTextPreview extends AIDevtoolsGenerationPreview {
  final String text;

  const AIDevtoolsTextPreview({required this.text});

  @override
  String get kind => 'text';

  @override
  Map<String, dynamic> toJson() => {'kind': kind, 'text': text};

  @override
  bool operator ==(Object other) =>
      other is AIDevtoolsTextPreview && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

class AIDevtoolsStructuredPreview extends AIDevtoolsGenerationPreview {
  final Object? value;

  const AIDevtoolsStructuredPreview({required this.value});

  @override
  String get kind => 'structured';

  @override
  Map<String, dynamic> toJson() => {'kind': kind, 'value': value};

  @override
  bool operator ==(Object other) =>
      other is AIDevtoolsStructuredPreview && _deepEquals(other.value, value);

  @override
  int get hashCode => value.hashCode;
}

class AIDevtoolsEmptyPreview extends AIDevtoolsGenerationPreview {
  const AIDevtoolsEmptyPreview();

  @override
  String get kind => 'empty';

  @override
  Map<String, dynamic> toJson() => {'kind': kind};

  @override
  bool operator ==(Object other) => other is AIDevtoolsEmptyPreview;

  @override
  int get hashCode => 'empty'.hashCode;
}

enum AIDevtoolsGenerationRunStatus {
  idle,
  generating,
  success,
  error,
  cancelled,
}

class AIDevtoolsGenerationRunSnapshot<TOutput> {
  final String id;
  Object? input;
  TOutput? result;
  AIDevtoolsGenerationPreview preview;
  AIDevtoolsGenerationProgress? progress;
  AIDevtoolsGenerationRunStatus status;
  bool isLoading;
  final int startedAt;
  int updatedAt;
  int? completedAt;
  String? error;
  String? jobId;
  Object? videoStatus;

  AIDevtoolsGenerationRunSnapshot({
    required this.id,
    required this.input,
    required this.result,
    required this.preview,
    required this.progress,
    required this.status,
    required this.isLoading,
    required this.startedAt,
    required this.updatedAt,
    this.completedAt,
    this.error,
    this.jobId,
    this.videoStatus,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'input': input,
        'result': result,
        'preview': preview.toJson(),
        'progress': progress?.toJson(),
        'status': status.name,
        'isLoading': isLoading,
        'startedAt': startedAt,
        'updatedAt': updatedAt,
        if (completedAt != null) 'completedAt': completedAt,
        if (error != null) 'error': error,
        if (jobId != null) 'jobId': jobId,
        if (videoStatus != null) 'videoStatus': videoStatus,
      };
}

class AIDevtoolsGenerationSnapshotBase<TOutput> implements AIDevtoolsSnapshot {
  final Object? input;
  final TOutput? result;
  final AIDevtoolsGenerationPreview preview;
  final AIDevtoolsGenerationProgress? progress;
  final AIDevtoolsGenerationRunStatus status;
  final bool isLoading;
  final String? activeRunId;
  final List<AIDevtoolsGenerationRunSnapshot<TOutput>> runs;
  final String? error;

  const AIDevtoolsGenerationSnapshotBase({
    required this.input,
    required this.result,
    required this.preview,
    required this.progress,
    required this.status,
    required this.isLoading,
    required this.activeRunId,
    required this.runs,
    this.error,
  });

  @override
  Map<String, dynamic> toJson() => {
        'input': input,
        'result': result,
        'preview': preview.toJson(),
        'progress': progress?.toJson(),
        'status': status.name,
        'isLoading': isLoading,
        'activeRunId': activeRunId,
        'runs': runs.map((run) => run.toJson()).toList(),
        if (error != null) 'error': error,
      };
}

class AIDevtoolsVideoSnapshotBase<TOutput>
    extends AIDevtoolsGenerationSnapshotBase<TOutput> {
  final String? jobId;
  final Object? videoStatus;

  const AIDevtoolsVideoSnapshotBase({
    required super.input,
    required super.result,
    required super.preview,
    required super.progress,
    required super.status,
    required super.isLoading,
    required super.activeRunId,
    required super.runs,
    super.error,
    required this.jobId,
    required this.videoStatus,
  });

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'jobId': jobId,
        'videoStatus': videoStatus,
      };
}

class AIDevtoolsGenerationPreviewInput {
  final String? outputKind;
  final Object? result;
  final Object? videoStatus;

  const AIDevtoolsGenerationPreviewInput({
    this.outputKind,
    required this.result,
    this.videoStatus,
  });
}

class AIDevtoolsChatSnapshot implements AIDevtoolsSnapshot {
  final List<Map<String, dynamic>> messages;
  final String status;
  final bool isLoading;
  final bool isSubscribed;
  final String connectionStatus;
  final bool sessionGenerating;
  final List<String> activeRunIds;
  final List<Object?>? queue;
  final String? error;
  final Map<String, dynamic> extra;

  const AIDevtoolsChatSnapshot({
    required this.messages,
    required this.status,
    required this.isLoading,
    required this.isSubscribed,
    required this.connectionStatus,
    required this.sessionGenerating,
    required this.activeRunIds,
    this.queue,
    this.error,
    this.extra = const <String, dynamic>{},
  });

  @override
  Map<String, dynamic> toJson() => {
        ...extra,
        'messages': messages,
        'status': status,
        'isLoading': isLoading,
        'isSubscribed': isSubscribed,
        'connectionStatus': connectionStatus,
        'sessionGenerating': sessionGenerating,
        'activeRunIds': activeRunIds,
        if (queue != null) 'queue': queue,
        if (error != null) 'error': error,
      };
}

class AIDevtoolsGenerationCoreState<TOutput> {
  final Object? input;
  final TOutput? result;
  final AIDevtoolsGenerationProgress? progress;
  final AIDevtoolsGenerationRunStatus status;
  final bool isLoading;
  final String? error;
  final String? jobId;
  final Object? videoStatus;

  const AIDevtoolsGenerationCoreState({
    required this.input,
    required this.result,
    required this.progress,
    required this.status,
    required this.isLoading,
    this.error,
    this.jobId,
    this.videoStatus,
  });
}

class AIDevtoolsVideoCoreState<TOutput>
    extends AIDevtoolsGenerationCoreState<TOutput> {
  const AIDevtoolsVideoCoreState({
    required super.input,
    required super.result,
    required super.progress,
    required super.status,
    required super.isLoading,
    super.error,
    required super.jobId,
    required super.videoStatus,
  });
}

/// Schema shape the bridge can serialize for devtools discovery.
abstract interface class AIDevtoolsJsonSchema {
  Object? get jsonSchema;
}

class AIDevtoolsTool {
  final String name;
  final String description;
  final Object? inputSchema;
  final Object? outputSchema;
  final bool needsApproval;
  final Object? metadata;
  final FutureOr<Object?> Function(Object? input)? execute;

  const AIDevtoolsTool({
    required this.name,
    this.description = '',
    this.inputSchema,
    this.outputSchema,
    this.needsApproval = false,
    this.metadata,
    this.execute,
  });

  bool get hasExecute => execute != null;
}

Object? aIDevtoolsSchemaToJson(Object? schema) {
  if (schema == null) return null;
  if (schema is AIDevtoolsJsonSchema) return schema.jsonSchema;
  return schema;
}

class AIDevtoolsToolFixture {
  final String? fixtureId;
  final String? hookId;
  final String? threadId;
  final String? runId;
  final String toolName;
  final Object? input;
  final Object? output;
  final bool? execute;
  final Map<String, dynamic>? message;
  final String? toolCallId;
  final String? messageId;
  final String? errorText;

  const AIDevtoolsToolFixture({
    this.fixtureId,
    this.hookId,
    this.threadId,
    this.runId,
    required this.toolName,
    required this.input,
    required this.output,
    this.execute,
    this.message,
    this.toolCallId,
    this.messageId,
    this.errorText,
  });

  factory AIDevtoolsToolFixture.fromMap(Map<String, dynamic> map) {
    final message = map['message'];
    return AIDevtoolsToolFixture(
      fixtureId: map['fixtureId'] as String?,
      hookId: map['hookId'] as String?,
      threadId: map['threadId'] as String?,
      runId: map['runId'] as String?,
      toolName: '${map['toolName'] ?? ''}',
      input: map['input'],
      output: map['output'],
      execute: map['execute'] is bool ? map['execute'] as bool : null,
      message: message is Map
          ? message.map((key, value) => MapEntry('$key', value))
          : null,
      toolCallId: map['toolCallId'] as String?,
      messageId: map['messageId'] as String?,
      errorText: map['errorText'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        if (fixtureId != null) 'fixtureId': fixtureId,
        if (hookId != null) 'hookId': hookId,
        if (threadId != null) 'threadId': threadId,
        if (runId != null) 'runId': runId,
        'toolName': toolName,
        'input': input,
        'output': output,
        if (execute != null) 'execute': execute,
        if (message != null) 'message': message,
        if (toolCallId != null) 'toolCallId': toolCallId,
        if (messageId != null) 'messageId': messageId,
        if (errorText != null) 'errorText': errorText,
      };
}

enum AIDevtoolsRunEventType {
  created('run:created'),
  started('run:started'),
  updated('run:updated'),
  completed('run:completed'),
  errored('run:errored'),
  cancelled('run:cancelled');

  final String wire;

  const AIDevtoolsRunEventType(this.wire);
}

enum AIDevtoolsRunStatus {
  created,
  started,
  updated,
  completed,
  errored,
  cancelled,
}

const Object _unset = Object();

class AIDevtoolsGenerationRunPatch<TOutput> {
  final Object? input;
  final Object? result;
  final AIDevtoolsGenerationPreview? preview;
  final Object? progress;
  final AIDevtoolsGenerationRunStatus? status;
  final bool? isLoading;
  final int? completedAt;
  final String? error;
  final bool clearError;

  const AIDevtoolsGenerationRunPatch({
    this.input = _unset,
    this.result = _unset,
    this.preview,
    this.progress = _unset,
    this.status,
    this.isLoading,
    this.completedAt,
    this.error,
    this.clearError = false,
  });

  bool get hasInput => !identical(input, _unset);
  bool get hasResult => !identical(result, _unset);
  bool get hasProgress => !identical(progress, _unset);
}

class AIDevtoolsVideoRunPatch<TOutput>
    extends AIDevtoolsGenerationRunPatch<TOutput> {
  final Object? jobId;
  final Object? videoStatus;

  const AIDevtoolsVideoRunPatch({
    super.input,
    super.result,
    super.preview,
    super.progress,
    super.status,
    super.isLoading,
    super.completedAt,
    super.error,
    super.clearError,
    this.jobId = _unset,
    this.videoStatus = _unset,
  });

  bool get hasJobId => !identical(jobId, _unset);
  bool get hasVideoStatus => !identical(videoStatus, _unset);
}

class AIDevtoolsBridgeOptions<TSnapshot extends AIDevtoolsSnapshot> {
  String hookId;
  String? threadId;
  String clientId;

  /// Optional live identity sources. When supplied, the bridge reads these on
  /// every event instead of the frozen field values above.
  final String Function()? hookIdGetter;
  final String? Function()? threadIdGetter;
  final String Function()? clientIdGetter;
  final AIDevtoolsClientMetadata metadata;
  final TSnapshot Function()? getSnapshot;
  final Iterable<AIDevtoolsTool> Function()? getTools;
  final FutureOr<void> Function(AIDevtoolsToolFixture fixture)?
      applyToolFixture;
  final AIDevtoolsEventClient eventClient;

  AIDevtoolsBridgeOptions({
    required this.hookId,
    this.threadId,
    required this.clientId,
    this.hookIdGetter,
    this.threadIdGetter,
    this.clientIdGetter,
    required this.metadata,
    this.getSnapshot,
    this.getTools,
    this.applyToolFixture,
    AIDevtoolsEventClient? eventClient,
  }) : eventClient = eventClient ?? aiDevtoolsEventClient;

  String get liveHookId => hookIdGetter != null ? hookIdGetter!() : hookId;
  String? get liveThreadId =>
      threadIdGetter != null ? threadIdGetter!() : threadId;
  String get liveClientId =>
      clientIdGetter != null ? clientIdGetter!() : clientId;
}

class ChatDevtoolsBridgeOptions
    extends AIDevtoolsBridgeOptions<AIDevtoolsChatSnapshot> {
  final List<Map<String, dynamic>> Function() getMessages;
  final void Function(List<Map<String, dynamic>> messages) setMessages;
  final void Function(String toolCallId, Object? output, [String? errorText])
      addToolResult;
  final String Function(String prefix) generateId;

  ChatDevtoolsBridgeOptions({
    required super.hookId,
    super.threadId,
    required super.clientId,
    super.hookIdGetter,
    super.threadIdGetter,
    super.clientIdGetter,
    required super.metadata,
    super.getSnapshot,
    super.getTools,
    super.applyToolFixture,
    super.eventClient,
    required this.getMessages,
    required this.setMessages,
    required this.addToolResult,
    required this.generateId,
  });
}

class GenerationDevtoolsBridgeOptions<TOutput>
    extends AIDevtoolsBridgeOptions<AIDevtoolsGenerationSnapshotBase<TOutput>> {
  final AIDevtoolsGenerationCoreState<TOutput> Function() getCoreState;
  final int maxRuns;

  GenerationDevtoolsBridgeOptions({
    required super.hookId,
    super.threadId,
    required super.clientId,
    super.hookIdGetter,
    super.threadIdGetter,
    super.clientIdGetter,
    required super.metadata,
    super.getTools,
    super.applyToolFixture,
    super.eventClient,
    required this.getCoreState,
    this.maxRuns = 20,
  });
}

class VideoDevtoolsBridgeOptions<TOutput>
    extends GenerationDevtoolsBridgeOptions<TOutput> {
  VideoDevtoolsBridgeOptions({
    required super.hookId,
    super.threadId,
    required super.clientId,
    super.hookIdGetter,
    super.threadIdGetter,
    super.clientIdGetter,
    required super.metadata,
    super.getTools,
    super.applyToolFixture,
    super.eventClient,
    required super.getCoreState,
    super.maxRuns,
  });
}

// ---------------------------------------------------------------------------
// Injected event sink / listener source.
// ---------------------------------------------------------------------------

class AIDevtoolsEvent {
  final String type;
  final Map<String, dynamic> payload;
  final String? pluginId;

  const AIDevtoolsEvent(this.type, this.payload, {this.pluginId});
}

typedef AIDevtoolsEventListener = void Function(AIDevtoolsEvent event);
typedef AIDevtoolsUnsubscribe = void Function();

abstract interface class AIDevtoolsEventClient {
  void emit(String eventName, Map<String, dynamic> payload);

  AIDevtoolsUnsubscribe on(
    String eventName,
    AIDevtoolsEventListener listener,
  );
}

class AIDevtoolsEventRecord {
  final String name;
  final Map<String, dynamic> payload;

  const AIDevtoolsEventRecord(this.name, this.payload);
}

/// In-memory sink used by tests and pure-Dart hosts.
///
/// A browser host can implement [AIDevtoolsEventClient] on top of the
/// `@tanstack/ai-event-client` bridge and pass it through bridge options.
class InMemoryAIDevtoolsEventClient implements AIDevtoolsEventClient {
  final List<AIDevtoolsEventRecord> events = <AIDevtoolsEventRecord>[];
  final Map<String, List<AIDevtoolsEventListener>> _listeners =
      <String, List<AIDevtoolsEventListener>>{};

  /// Number of listener removals performed (used by disposal tests).
  int unsubscribeCalls = 0;

  @override
  void emit(String eventName, Map<String, dynamic> payload) {
    final copy = Map<String, dynamic>.from(payload);
    events.add(AIDevtoolsEventRecord(eventName, copy));
    _dispatch(eventName, copy);
  }

  @override
  AIDevtoolsUnsubscribe on(
    String eventName,
    AIDevtoolsEventListener listener,
  ) {
    (_listeners[eventName] ??= <AIDevtoolsEventListener>[]).add(listener);
    return () {
      unsubscribeCalls += 1;
      _listeners[eventName]?.remove(listener);
    };
  }

  /// Deliver a devtools-panel message without recording it as an emission.
  void dispatch(String eventName, Map<String, dynamic> payload) {
    _dispatch(eventName, Map<String, dynamic>.from(payload));
  }

  List<AIDevtoolsEventRecord> emitted(String eventName) => events
      .where((record) => record.name == eventName)
      .toList(growable: false);

  void clear() {
    events.clear();
    unsubscribeCalls = 0;
  }

  /// Clear recordings and drop every panel listener.
  void reset() {
    clear();
    _listeners.clear();
  }

  void _dispatch(String eventName, Map<String, dynamic> payload) {
    final listeners =
        List<AIDevtoolsEventListener>.of(_listeners[eventName] ?? const []);
    for (final listener in listeners) {
      listener(
        AIDevtoolsEvent(
          'tanstack-ai-devtools:$eventName',
          payload,
          pluginId: 'tanstack-ai-devtools',
        ),
      );
    }
  }
}

final AIDevtoolsEventClient aiDevtoolsEventClient =
    InMemoryAIDevtoolsEventClient();

// ---------------------------------------------------------------------------
// Preview normalization.
// ---------------------------------------------------------------------------

AIDevtoolsGenerationPreview createAIDevtoolsGenerationPreview(
  AIDevtoolsGenerationPreviewInput input,
) {
  if (input.outputKind == 'image') {
    return _imagePreviewFromResult(input.result);
  }
  if (input.outputKind == 'audio') {
    return _audioPreviewFromResult(input.result);
  }
  if (input.outputKind == 'video') {
    return _videoPreviewFromResult(input.result, input.videoStatus);
  }
  if (input.outputKind == 'text') {
    return _textPreviewFromResult(input.result);
  }
  if (input.result == null) {
    return const AIDevtoolsEmptyPreview();
  }
  return AIDevtoolsStructuredPreview(value: input.result);
}

AIDevtoolsGenerationPreview _imagePreviewFromResult(Object? result) {
  final record = _asRecord(result);
  final rawImages = record?['images'];
  final images = rawImages is List ? rawImages : const <Object?>[];
  final items = images
      .map((image) => _mediaItemFromSource(image, 'image/png'))
      .whereType<AIDevtoolsGenerationMediaItem>()
      .toList();

  if (items.isEmpty && result != null) {
    final directItem = _mediaItemFromSource(result, 'image/png');
    if (directItem != null) items.add(directItem);
  }

  return AIDevtoolsImagePreview(items: items);
}

AIDevtoolsGenerationPreview _audioPreviewFromResult(Object? result) {
  final record = _asRecord(result);
  final audio = record?['audio'];
  final resultContentType = _stringField(record, 'contentType');
  final format = _stringField(record, 'format');
  final mimeType = resultContentType ?? _mimeTypeFromAudioFormat(format);

  final items = <AIDevtoolsGenerationMediaItem>[];
  final directItem = audio is String
      ? _base64MediaItem(
          audio,
          mimeType,
          format: format,
          duration: _numberField(record, 'duration'),
        )
      : _mediaItemFromSource(audio, mimeType, format: format);

  if (directItem != null) {
    items.add(directItem);
  }

  return AIDevtoolsAudioPreview(items: items);
}

AIDevtoolsGenerationPreview _videoPreviewFromResult(
  Object? result,
  Object? videoStatus,
) {
  final statusRecord = _asRecord(videoStatus);
  final item = _mediaItemFromSource(result, 'video/mp4') ??
      _mediaItemFromSource(videoStatus, 'video/mp4');
  final items = item == null
      ? <AIDevtoolsGenerationMediaItem>[]
      : <AIDevtoolsGenerationMediaItem>[item];
  final job = _videoJobFromStatus(statusRecord ?? _asRecord(result));

  return AIDevtoolsVideoPreview(items: items, job: job);
}

AIDevtoolsGenerationPreview _textPreviewFromResult(Object? result) {
  final record = _asRecord(result);
  final text = _stringField(record, 'text') ??
      _stringField(record, 'summary') ??
      _stringField(record, 'content') ??
      (result is String ? result : null);

  if (text != null) {
    return AIDevtoolsTextPreview(text: text);
  }
  if (result == null) {
    return const AIDevtoolsEmptyPreview();
  }
  return AIDevtoolsStructuredPreview(value: result);
}

AIDevtoolsGenerationVideoJob? _videoJobFromStatus(
  Map<String, dynamic>? record,
) {
  final jobId = _stringField(record, 'jobId');
  if (jobId == null) return null;

  final status = _stringField(record, 'status');
  final progress = _numberField(record, 'progress');
  final error = _stringField(record, 'error');
  return AIDevtoolsGenerationVideoJob(
    jobId: jobId,
    status: status,
    progress: progress,
    error: error,
  );
}

AIDevtoolsGenerationMediaItem? _mediaItemFromSource(
  Object? value,
  String defaultMimeType, {
  String? format,
  num? duration,
}) {
  final record = _asRecord(value);
  if (record == null) return null;

  final explicitContentType =
      _stringField(record, 'contentType') ?? _stringField(record, 'mimeType');
  final resolvedDuration = _numberField(record, 'duration') ?? duration;
  final resolvedFormat = _stringField(record, 'format') ?? format;
  final url = _stringField(record, 'url');
  if (url != null) {
    return AIDevtoolsGenerationMediaItem(
      src: url,
      sourceType: 'url',
      mimeType: explicitContentType,
      format: resolvedFormat,
      duration: resolvedDuration,
    );
  }

  final b64Json = _stringField(record, 'b64Json');
  if (b64Json == null) return null;

  return _base64MediaItem(
    b64Json,
    explicitContentType ?? defaultMimeType,
    format: resolvedFormat,
    duration: resolvedDuration,
  );
}

AIDevtoolsGenerationMediaItem _base64MediaItem(
  String value,
  String? mimeType, {
  String? format,
  num? duration,
}) {
  final src = value.startsWith('data:')
      ? value
      : 'data:${mimeType ?? 'application/octet-stream'};base64,$value';
  return AIDevtoolsGenerationMediaItem(
    src: src,
    sourceType: 'base64',
    mimeType: mimeType,
    format: format,
    duration: duration,
  );
}

String _mimeTypeFromAudioFormat(String? format) {
  if (format == null || format.isEmpty) return 'audio/mpeg';
  if (format == 'mp3') return 'audio/mpeg';
  return 'audio/$format';
}

Map<String, dynamic>? _asRecord(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry('$key', item));
  }
  // Typed generation results (for example VideoGenerateResult) expose toJson.
  try {
    final dynamic candidate = value;
    final json = candidate.toJson();
    if (json is Map) {
      return json.map((key, item) => MapEntry('$key', item));
    }
  } catch (_) {
    // Not a JSON-serializable value; callers fall back to structured output.
  }
  return null;
}

String? _stringField(Map<String, dynamic>? record, String field) {
  final value = record?[field];
  return value is String && value.isNotEmpty ? value : null;
}

num? _numberField(Map<String, dynamic>? record, String field) {
  final value = record?[field];
  return value is num ? value : null;
}

bool _listEquals<T>(List<T> left, List<T> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _deepEquals(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key)) return false;
      if (!_deepEquals(entry.value, right[entry.key])) return false;
    }
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_deepEquals(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}
