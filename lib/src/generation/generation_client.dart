/// Ported from `packages/ai-client/src/generation-client.ts` (TanStack AI
/// client 0.40.0).
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import '../identity.dart';

import '../connections/cancellation.dart';
import '../connections/connection_adapter.dart';
import '../connections/errors.dart' as connection_errors;
import '../connections/hydration.dart';
import '../connections/sse_utils.dart';
import '../connections/types.dart';
import '../connections/wire.dart';
import '../platform/byok/byok.dart' as platform_byok;
import 'generation_devtools_port.dart';
import 'generation_types.dart';

/// Human-readable message for any error surfaced by the clients.
String generationErrorMessage(Object? error) {
  if (error == null) return '';
  if (error is GenerationError) return error.message;
  if (error is platform_byok.ByokMissingError) return error.message;
  if (error is platform_byok.ByokBlockedError) return error.message;
  if (error is platform_byok.ByokUnresolvedProviderError) {
    return platform_byok.ByokUnresolvedProviderError.message;
  }
  if (error is connection_errors.HttpStatusException) return error.message;
  if (error is connection_errors.XhrStatusException) return error.message;
  if (error is connection_errors.UnsupportedResponseStreamError) {
    return error.toString();
  }
  return error.toString().replaceFirst(RegExp(r'^[^:]+:\s*'), '');
}

bool _isByokError(Object error) =>
    error is platform_byok.ByokMissingError ||
    error is platform_byok.ByokBlockedError ||
    error is platform_byok.ByokUnresolvedProviderError ||
    error is connection_errors.ByokMissingError;

String? _byokProviderOf(Object error) {
  if (error is platform_byok.ByokMissingError) return error.provider;
  if (error is platform_byok.ByokBlockedError) return error.provider;
  if (error is connection_errors.ByokMissingError) return error.provider;
  return null;
}

class _GenerationCallbacks<TResult, TOutput> {
  GenerationTransformOutcome<TOutput> Function(TResult result)? onResult;
  void Function(Object error)? onError;
  void Function(num progress, String? message)? onProgress;
  void Function(StreamChunk chunk)? onChunk;
  void Function(TOutput? result)? onResultChange;
  void Function(bool isLoading)? onLoadingChange;
  void Function(Object? error)? onErrorChange;
  void Function(GenerationClientState status)? onStatusChange;
  void Function(GenerationResumeSnapshot? snapshot)? onResumeSnapshotChange;
  void Function(GenerationResumeState? state)? onResumeStateChange;
  TResult? Function(GenerationRestoredResult restored)? reconstructResult;
}

/// A lightweight, generic client for one-shot generation tasks
/// (image, speech, transcription, summarize).
class GenerationClient<TInput, TResult, TOutput> {
  final ConnectionAdapter? _connection;
  final GenerationFetcher<TInput>? _fetcher;
  final HydrateGenerationFunction? _hydrateGenerationHandler;
  final JoinRunFunction? _joinRunHandler;
  final bool _serverDriven;
  late final GenerationDevtoolsBridgePort _devtoolsBridge;
  final String? _persistenceScope;
  final _GenerationCallbacks<TResult, TOutput> _callbacks;

  String _threadId;
  String _uniqueId;
  Map<String, dynamic> _body;
  platform_byok.ByokClient? _byok;
  FutureOr<String?> Function()? _byokProvider;

  TOutput? _result;
  Object? _input;
  GenerationDevtoolsProgress? _progress;
  bool _isLoading = false;
  Object? _error;
  GenerationClientState _status = GenerationClientState.idle;

  GenerationResumeSnapshot? _resumeSnapshot;
  String? _lastEmittedResumeState;
  CancellationController? _abortController;
  String? _rejoinedRunId;

  bool _devtoolsMounted = false;
  bool _disposed = false;
  bool _serverHydrationStarted = false;

  GenerationClientSnapshot<TOutput> _snapshot =
      const GenerationClientSnapshot.initial();
  final Set<void Function()> _listeners = <void Function()>{};

  GenerationClient({
    String? threadId,
    ConnectionAdapter? connection,
    GenerationFetcher<TInput>? fetcher,
    Map<String, dynamic>? body,
    platform_byok.ByokClient? byok,
    FutureOr<String?> Function()? byokProvider,
    bool persistence = false,
    HydrateGenerationFunction? hydrateGeneration,
    JoinRunFunction? joinRun,
    GenerationDevtoolsMetadata? devtools,
    GenerationDevtoolsBridgePortFactory? devtoolsBridgeFactory,
    GenerationTransformOutcome<TOutput> Function(TResult result)? onResult,
    void Function(Object error)? onError,
    void Function(num progress, String? message)? onProgress,
    void Function(StreamChunk chunk)? onChunk,
    void Function(TOutput? result)? onResultChange,
    void Function(bool isLoading)? onLoadingChange,
    void Function(Object? error)? onErrorChange,
    void Function(GenerationClientState status)? onStatusChange,
    void Function(GenerationResumeSnapshot? snapshot)? onResumeSnapshotChange,
    void Function(GenerationResumeState? state)? onResumeStateChange,
    TResult? Function(GenerationRestoredResult restored)? reconstructResult,
  })  : _threadId = threadId ?? '',
        _uniqueId = threadId ?? '',
        _persistenceScope = threadId,
        _connection = connection,
        _fetcher = fetcher,
        _hydrateGenerationHandler = hydrateGeneration,
        _joinRunHandler = joinRun,
        _body = body ?? <String, dynamic>{},
        _byok = byok,
        _byokProvider = byokProvider,
        _serverDriven = persistence,
        _callbacks = _GenerationCallbacks<TResult, TOutput>() {
    _callbacks
      ..onResult = onResult
      ..onError = onError
      ..onProgress = onProgress
      ..onChunk = onChunk
      ..onResultChange = onResultChange
      ..onLoadingChange = onLoadingChange
      ..onErrorChange = onErrorChange
      ..onStatusChange = onStatusChange
      ..onResumeSnapshotChange = onResumeSnapshotChange
      ..onResumeStateChange = onResumeStateChange
      ..reconstructResult = reconstructResult;

    if (persistence &&
        (_persistenceScope == null || _persistenceScope.isEmpty)) {
      // JS callers can bypass the type-level requirement; mirror the upstream
      // warning rather than keying persistence on a generated wire id.
      print(
        '[TanStack AI] `persistence` needs a stable `threadId` to key on. '
        'Without one nothing will be restored after a reload. Pass a '
        '`threadId` derived from your own domain (e.g. `product-123-hero`).',
      );
    }

    final metadata = GenerationDevtoolsMetadata(
      framework: devtools?.framework,
      hookName: devtools?.hookName ?? 'useGeneration',
      outputKind: devtools?.outputKind,
      name: devtools?.name,
    );
    final factory =
        devtoolsBridgeFactory ?? createNoOpGenerationDevtoolsBridgePort;
    _devtoolsBridge = factory(
      GenerationDevtoolsBridgePortOptions(
        hookId: () => _uniqueId,
        clientId: () => _uniqueId,
        threadId: () => _threadId,
        metadata: metadata,
        getCoreState: () => GenerationDevtoolsPortCoreState(
          input: _input,
          result: _result,
          progress: _progress,
          status: _status.wire,
          isLoading: _isLoading,
          error: _error == null ? null : generationErrorMessage(_error),
          jobId: null,
          videoStatus: null,
        ),
      ),
    );
  }

  // ===========================
  // Devtools / lifecycle
  // ===========================

  void mountDevtools() {
    _ensureThreadId();
    _disposed = false;
    _maybeHydrateFromServer();
    _maybeResumeInFlight();
    if (_devtoolsMounted) return;
    _devtoolsMounted = true;
    _devtoolsBridge.emitRegistered();
    _devtoolsBridge.emitSnapshot();
  }

  Future<void> generate(TInput input) async {
    if (_disposed) return;
    if (_isLoading) return;
    mountDevtools();

    _input = input;
    _progress = null;
    final abortController = CancellationController();
    _abortController = abortController;
    final signal = abortController.signal;
    final runId = _devtoolsBridge.beginRun(input);
    _patchSnapshot(runId: runId);

    try {
      if (!_ownsRun(_abortController, abortController) ||
          !_setIsLoading(true, abortController) ||
          !_setStatus(GenerationClientState.generating, abortController) ||
          !_setError(null, abortController)) {
        return;
      }

      Map<String, String>? headers;
      final currentByok = _byok;
      if (currentByok != null) {
        final provider = platform_byok.resolveByokProviderId(
          _byokProvider,
          <Object?>[
            _body['provider'],
            platform_byok.byokFallbackProviderId(currentByok)
          ],
        );
        headers = await platform_byok.prepareResolvedByokHeaders(
            currentByok, provider);
        if (!_ownsRun(_abortController, abortController)) return;
      }

      if (_fetcher != null) {
        final result = await _fetcher(
          input,
          GenerationFetcherOptions(
            signal: signal,
            headers: headers,
          ),
        );
        if (!_ownsRun(_abortController, abortController)) return;
        if (result is GenerationResponse || result is http.StreamedResponse) {
          await _processResponse(
            result as Object,
            signal,
            runId,
            abortController,
          );
        } else {
          _devtoolsBridge.ensureRunStarted(runId);
          if (!_setResult(result as TResult, abortController) ||
              !_setStatus(GenerationClientState.success, abortController)) {
            return;
          }
          _completePlainFetcherResumeSnapshot(result, abortController);
        }
      } else if (_connection != null && _connection.connect != null) {
        final mergedData = <String, dynamic>{
          ..._body,
          ..._inputData(input),
        };
        final stream = _connection.connect!(
          const <WireMessage>[],
          data: mergedData,
          signal: signal,
          runContext: _createRunContext(runId, headers),
        );
        await _processStream(stream, runId, abortController);
      } else {
        throw const GenerationError(
          'GenerationClient requires either a connection or fetcher option',
        );
      }

      if (_ownsRun(_abortController, abortController) &&
          _status == GenerationClientState.success) {
        _progress = _completeProgressValue(_progress);
        _devtoolsBridge.finishRun(
          _devtoolsBridge.getActiveRunId() ?? runId,
          'run:completed',
          'completed',
        );
      }
    } catch (rawError) {
      if (!_ownsRun(_abortController, abortController)) return;
      final error = _asError(rawError);
      if (_isByokError(error)) {
        final provider = _byokProviderOf(error);
        if (provider != null) {
          final reason = error is platform_byok.ByokBlockedError &&
                  error.reason == 'locked'
              ? 'locked'
              : 'missing';
          _byok?.request(provider, reason);
        }
      }
      if (!_ownsRun(_abortController, abortController)) return;
      _devtoolsBridge.finishRun(
        _devtoolsBridge.getActiveRunId() ?? runId,
        'run:errored',
        'errored',
        error: generationErrorMessage(error),
      );
      try {
        if (_setError(error, abortController) &&
            _setStatus(GenerationClientState.error, abortController)) {
          _recordResumeSnapshotError(error, abortController);
        }
      } finally {
        _callbacks.onError?.call(error);
      }
    } finally {
      if (identical(_abortController, abortController)) {
        _patchSnapshot(runId: null);
        _abortController = null;
        _setIsLoading(false);
      }
    }
  }

  Future<void> _processResponse(
    Object response,
    CancellationSignal signal,
    String fallbackRunId,
    CancellationController controller,
  ) async {
    final generationResponse = response is http.StreamedResponse
        ? GenerationResponse(
            statusCode: response.statusCode,
            reasonPhrase: response.reasonPhrase ?? '',
            body: response.stream)
        : response as GenerationResponse;
    if (!generationResponse.ok) {
      var body = '';
      final stream = generationResponse.body;
      if (stream != null) {
        try {
          body = await stream.transform(utf8.decoder).join();
        } catch (_) {
          body = '';
        }
      }
      if (generationResponse.statusCode == 401) {
        dynamic decoded;
        try {
          decoded = jsonDecode(body);
        } catch (_) {
          decoded = null;
        }
        if (platform_byok.isByokMissingBody(decoded) && decoded is Map) {
          final error = decoded['error'];
          final provider = error is Map ? error['provider'] : null;
          if (provider is String) {
            throw platform_byok.ByokMissingError(provider);
          }
        }
      }
      throw connection_errors.HttpStatusException(
        generationResponse.statusCode,
        generationResponse.reasonPhrase,
      );
    }
    final body = generationResponse.body;
    if (body == null) {
      throw const connection_errors.UnsupportedResponseStreamError(
        connection_errors.UnsupportedResponseStreamError.responseBody,
      );
    }
    await _processStream(
      parseSseResponse(
        http.StreamedResponse(
          body,
          generationResponse.statusCode,
          reasonPhrase: generationResponse.reasonPhrase,
        ),
        signal: signal,
      ),
      fallbackRunId,
      controller,
    );
  }

  Future<void> _processStream(
    Stream<StreamChunk> source,
    String fallbackRunId,
    CancellationController abortController,
  ) async {
    final signal = abortController.signal;
    String? streamRunId;
    var sawTerminalChunk = false;

    await for (final raw in source) {
      if (signal.isCancelled) break;
      final chunk = restoreInboundChunk(raw);
      _callbacks.onChunk?.call(chunk);
      if (!_ownsRun(_abortController, abortController) ||
          !_observeResumeSnapshot(chunk, abortController)) {
        return;
      }
      final chunkRunId =
          chunk['runId'] is String ? chunk['runId'] as String : null;

      switch (chunk['type']) {
        case 'RUN_STARTED':
          streamRunId = chunk['runId'] as String?;
          _patchSnapshot(runId: streamRunId);
          if (!_ownsRun(_abortController, abortController)) return;
          _devtoolsBridge.ensureRunStarted(streamRunId ?? fallbackRunId);
          break;
        case 'CUSTOM':
          _devtoolsBridge.ensureRunStarted(streamRunId ?? fallbackRunId);
          if (chunk['name'] == GenerationEvents.result) {
            if (!_setResult(chunk['value'] as TResult, abortController)) {
              return;
            }
          } else if (chunk['name'] == GenerationEvents.progress) {
            final value = chunk['value'];
            if (value is Map) {
              final progress = value['progress'];
              final message = value['message'];
              if (!_setProgress(
                progress is num ? progress : 0,
                message is String ? message : null,
                abortController,
              )) {
                return;
              }
            }
          }
          break;
        case 'RUN_FINISHED':
          streamRunId = chunk['runId'] as String?;
          sawTerminalChunk = true;
          _devtoolsBridge.ensureRunStarted(streamRunId ?? fallbackRunId);
          if (!_setStatus(GenerationClientState.success, abortController)) {
            return;
          }
          break;
        case 'RUN_ERROR':
          _devtoolsBridge.ensureRunStarted(
            chunkRunId ?? streamRunId ?? fallbackRunId,
          );
          final message = chunk['message'];
          throw GenerationError(
            message is String && message.isNotEmpty
                ? message
                : 'An error occurred',
          );
        default:
          break;
      }
    }

    if (!sawTerminalChunk && !signal.isCancelled) {
      throw const GenerationError(generationStreamTruncatedMessage);
    }
  }

  void stop() {
    final runId = _devtoolsBridge.getActiveRunId();
    final stoppedStatus = _status;
    final controller = _abortController;
    if (controller != null) {
      controller.cancel();
      _abortController = null;
    }
    _finishStoppedRun(runId, stoppedStatus, _error);

    final resumeStopped =
        _resumeSnapshot?.status == GenerationResumeStatus.running;
    if (_resumeSnapshot != null && resumeStopped) {
      _resumeSnapshot = _resumeSnapshot!.copyWith(
        resumeState: null,
        status: GenerationResumeStatus.idle,
      );
    }
    _isLoading = false;
    _patchSnapshot(runId: null);

    if (_abortController != null) return;
    try {
      if (stoppedStatus == GenerationClientState.generating) {
        _setStatus(GenerationClientState.idle);
        if (_abortController != null) return;
      }
      if (resumeStopped) _notifyResumeSnapshotChanged();
    } finally {
      if (_abortController == null) _setIsLoading(false);
    }
  }

  void reset() {
    stop();
    if (_abortController != null || _isLoading) return;
    _setResult(null);
    _input = null;
    _progress = null;
    _devtoolsBridge.resetRuns();
    _setError(null);
    _setStatus(GenerationClientState.idle);
    _clearResumeSnapshot();
    _devtoolsBridge.emitState();
  }

  void updateOptions({
    Object? body = _unset,
    Object? byok = _unset,
    Object? byokProvider = _unset,
    GenerationTransformOutcome<TOutput> Function(TResult result)? onResult,
    void Function(Object error)? onError,
    void Function(num progress, String? message)? onProgress,
    void Function(StreamChunk chunk)? onChunk,
  }) {
    if (!identical(body, _unset)) {
      _body = body == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(body as Map);
    }
    if (!identical(byok, _unset)) {
      _byok = byok as platform_byok.ByokClient?;
    }
    if (!identical(byokProvider, _unset)) {
      _byokProvider = byokProvider as FutureOr<String?> Function()?;
    }
    if (onResult != null) _callbacks.onResult = onResult;
    if (onError != null) _callbacks.onError = onError;
    if (onProgress != null) _callbacks.onProgress = onProgress;
    if (onChunk != null) _callbacks.onChunk = onChunk;
  }

  void dispose() {
    _disposed = true;
    final controller = _abortController;
    if (controller != null) {
      controller.cancel();
      _abortController = null;
    }
    if (_resumeSnapshot?.status != GenerationResumeStatus.running) {
      _patchSnapshot(runId: null);
    }
    _devtoolsBridge.dispose();
    _devtoolsMounted = false;
    _serverHydrationStarted = false;
    _rejoinedRunId = null;
    _setIsLoading(false);
  }

  // ===========================
  // Getters
  // ===========================

  void Function() subscribe(void Function() listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  GenerationClientSnapshot<TOutput> getSnapshot() => _snapshot;

  TOutput? getResult() => _result;

  bool getIsLoading() => _isLoading;

  Object? getError() => _error;

  GenerationClientState getStatus() => _status;

  GenerationResumeSnapshot? getResumeSnapshot() {
    final snapshot = _resumeSnapshot;
    if (snapshot == null) return null;
    return snapshot.copyWith(
      pendingArtifacts: snapshot.pendingArtifacts == null
          ? null
          : List<PersistedArtifactRef>.of(snapshot.pendingArtifacts!),
      result: snapshot.result == null
          ? null
          : GenerationResultSnapshot(
              id: snapshot.result!.id,
              model: snapshot.result!.model,
              status: snapshot.result!.status,
              providerJobId: snapshot.result!.providerJobId,
              expiresAt: snapshot.result!.expiresAt,
              text: snapshot.result!.text,
              usage: snapshot.result!.usage,
              artifacts: snapshot.result!.artifacts == null
                  ? null
                  : List<PersistedArtifactRef>.of(snapshot.result!.artifacts!),
            ),
      error: snapshot.error == null
          ? null
          : GenerationErrorSnapshot(
              message: snapshot.error!.message,
              code: snapshot.error!.code,
            ),
      lastEvent: snapshot.lastEvent == null
          ? null
          : GenerationEventSnapshot(
              type: snapshot.lastEvent!.type,
              name: snapshot.lastEvent!.name,
              timestamp: snapshot.lastEvent!.timestamp,
            ),
    );
  }

  // ===========================
  // State setters
  // ===========================

  bool _setResult(TResult? rawResult, [CancellationController? controller]) {
    if (rawResult == null) {
      _result = null;
      return _publishResult(controller);
    }

    final onResult = _callbacks.onResult;
    if (onResult != null) {
      final transformed = onResult(rawResult);
      if (!_owns(_abortController, controller)) return false;
      if (transformed is GenerationTransformKeep<TOutput>) {
        _devtoolsBridge.emitState();
        return true;
      }
      if (transformed is GenerationTransformValue<TOutput>) {
        _result = transformed.value;
        return _publishResult(controller);
      }
    }

    _result = rawResult as TOutput;
    return _publishResult(controller);
  }

  bool _publishResult([CancellationController? controller]) {
    final result = _result;
    _patchSnapshot(result: result);
    return _whileOwned(
      () => _abortController,
      controller,
      <void Function()>[
        () => _callbacks.onResultChange?.call(result),
        () => _devtoolsBridge.recordResultChange(),
      ],
    );
  }

  bool _setIsLoading(bool isLoading, [CancellationController? controller]) {
    _isLoading = isLoading;
    _patchSnapshot(isLoading: isLoading);
    return _whileOwned(
      () => _abortController,
      controller,
      <void Function()>[
        () => _callbacks.onLoadingChange?.call(isLoading),
        () => _devtoolsBridge.recordLoadingChange(),
      ],
    );
  }

  bool _setError(Object? error, [CancellationController? controller]) {
    _error = error;
    _patchSnapshot(error: error);
    return _whileOwned(
      () => _abortController,
      controller,
      <void Function()>[
        () => _callbacks.onErrorChange?.call(error),
        () => _devtoolsBridge.recordErrorChange(error),
      ],
    );
  }

  bool _setStatus(
    GenerationClientState status, [
    CancellationController? controller,
  ]) {
    _status = status;
    _patchSnapshot(status: status);
    return _whileOwned(
      () => _abortController,
      controller,
      <void Function()>[
        () => _callbacks.onStatusChange?.call(status),
        () => _devtoolsBridge.recordStatusChange(status.wire),
      ],
    );
  }

  bool _setProgress(
    num value,
    String? message, [
    CancellationController? controller,
  ]) {
    _progress = GenerationDevtoolsProgress(
      value: value,
      message: (message != null && message.isNotEmpty) ? message : null,
    );
    _callbacks.onProgress?.call(value, message);
    return _whileOwned(
      () => _abortController,
      controller,
      <void Function()>[
        () => _devtoolsBridge.recordProgressChange(),
      ],
    );
  }

  // ===========================
  // Resume snapshot handling
  // ===========================

  bool _observeResumeSnapshot(
    StreamChunk chunk,
    CancellationController controller,
  ) {
    _resumeSnapshot = updateGenerationResumeSnapshot(_resumeSnapshot, chunk);
    return _notifyResumeSnapshotChanged(controller);
  }

  bool _notifyResumeSnapshotChanged([CancellationController? controller]) {
    return _whileOwned(
      () => _abortController,
      controller,
      <void Function()>[
        () => _callbacks.onResumeSnapshotChange?.call(_resumeSnapshot),
        () => _emitResumeState(controller),
      ],
    );
  }

  void _emitResumeState([CancellationController? controller]) {
    final snapshot = _resumeSnapshot;
    final state = snapshot?.resumeState;
    final pending = snapshot?.pendingArtifacts;
    final resumeState = state == null
        ? null
        : GenerationResumeState(
            threadId: state.threadId,
            runId: state.runId,
            pendingArtifacts: (pending != null && pending.isNotEmpty)
                ? List<PersistedArtifactRef>.of(pending)
                : null,
          );
    final signature = jsonEncode(resumeState?.toJson());
    if (signature == _lastEmittedResumeState) return;
    _lastEmittedResumeState = signature;
    if (resumeState != null && resumeState.runId.isNotEmpty) {
      _patchSnapshot(runId: resumeState.runId);
    } else if (!_isLoading) {
      _patchSnapshot(runId: null);
    }
    if (!_owns(_abortController, controller)) return;
    _callbacks.onResumeStateChange?.call(resumeState);
  }

  void _repaintFromSnapshot(GenerationResumeSnapshot snapshot) {
    _resumeSnapshot = snapshot;
    _notifyResumeSnapshotChanged();
    _setStatus(clientStateFromResumeStatus(snapshot.status));
    final errorSnapshot = snapshot.error;
    _setError(
      errorSnapshot == null
          ? null
          : GenerationError(
              errorSnapshot.message,
              code: errorSnapshot.code,
            ),
    );
    final restored = _reconstructRestoredResult(snapshot);
    if (restored != null) {
      _setResult(restored);
    } else if (_callbacks.reconstructResult != null &&
        snapshot.status == GenerationResumeStatus.complete) {
      _reportUnrestorableResult();
    }
  }

  void _reportUnrestorableResult() {
    final error = const GenerationError(generationUnrestorableResultMessage);
    _setStatus(GenerationClientState.error);
    _setError(error);
    _callbacks.onError?.call(error);
  }

  void _repaintRestoredSnapshot(
    GenerationResumeSnapshot snapshot, [
    String? activeRunId,
  ]) {
    if (snapshot.status != GenerationResumeStatus.running) {
      _repaintFromSnapshot(snapshot);
      return;
    }
    final joinRun = _connection?.joinRun ?? _joinRunHandler;
    final runId = activeRunId ?? snapshot.resumeState?.runId;
    if (runId != null && runId.isNotEmpty && joinRun != null) {
      _repaintFromSnapshot(snapshot);
      _rejoinInFlight(runId);
      return;
    }
    _repaintFromSnapshot(
      snapshot.copyWith(
        resumeState: null,
        status: GenerationResumeStatus.error,
        error: const GenerationErrorSnapshot(
          message:
              'The previous generation was interrupted before it finished and '
              'cannot be resumed — generate again to retry.',
        ),
      ),
    );
  }

  TResult? _reconstructRestoredResult(GenerationResumeSnapshot snapshot) {
    final build = _callbacks.reconstructResult;
    if (build == null) return null;
    final result = snapshot.result;
    return build(
      GenerationRestoredResult(
        id: result?.id,
        model: result?.model,
        status: result?.status,
        providerJobId: result?.providerJobId,
        expiresAt: result?.expiresAt,
        text: result?.text,
        usage: result?.usage,
        activity: snapshot.activity,
        artifacts: result?.artifacts ?? const <PersistedArtifactRef>[],
      ),
    );
  }

  void _completePlainFetcherResumeSnapshot(
    Object? rawResult,
    CancellationController controller,
  ) {
    final previous = _resumeSnapshot;
    final result = createGenerationResultSnapshot(rawResult);
    _resumeSnapshot = GenerationResumeSnapshot(
      resumeState: null,
      status: GenerationResumeStatus.complete,
      activity: previous?.activity,
      pendingArtifacts: (previous?.pendingArtifacts != null &&
              previous!.pendingArtifacts!.isNotEmpty)
          ? List<PersistedArtifactRef>.of(previous.pendingArtifacts!)
          : null,
      result: result ?? previous?.result,
    );
    _notifyResumeSnapshotChanged(controller);
  }

  bool _recordResumeSnapshotError(
    Object error, [
    CancellationController? controller,
  ]) {
    if (_status != GenerationClientState.error &&
        !_setStatus(GenerationClientState.error, controller)) {
      return false;
    }
    if (!_setError(error, controller)) return false;
    if (_resumeSnapshot?.status == GenerationResumeStatus.error) return true;
    if (_resumeSnapshot == null && !_serverDriven) return true;
    final previous = _resumeSnapshot;
    _resumeSnapshot = GenerationResumeSnapshot(
      resumeState: null,
      status: GenerationResumeStatus.error,
      activity: previous?.activity,
      pendingArtifacts: (previous?.pendingArtifacts != null &&
              previous!.pendingArtifacts!.isNotEmpty)
          ? List<PersistedArtifactRef>.of(previous.pendingArtifacts!)
          : null,
      result: previous?.result,
      error: GenerationErrorSnapshot(message: generationErrorMessage(error)),
    );
    return _notifyResumeSnapshotChanged(controller);
  }

  void _clearResumeSnapshot() {
    _resumeSnapshot = null;
    _lastEmittedResumeState = null;
    _notifyResumeSnapshotChanged();
  }

  void _maybeHydrateFromServer() {
    if (!_serverDriven || _serverHydrationStarted) return;
    _serverHydrationStarted = true;
    final hydrate = _connection?.hydrateGeneration ?? _hydrateGenerationHandler;
    if (hydrate != null) {
      _hydrateFromServer();
    } else {
      print(
        '[TanStack AI] `persistence: true` (server-driven) needs a '
        '`hydrateGeneration` handler — either a connection that implements one '
        '(e.g. `fetchServerSentEvents` / `fetchHttpStream`, or `stream()` / '
        '`rpcStream()` with persistence handlers) or the `hydrateGeneration` '
        'option. Without one, nothing is persisted or restored.',
      );
    }
  }

  void _hydrateFromServer() {
    final hydrate = _connection?.hydrateGeneration ?? _hydrateGenerationHandler;
    if (hydrate == null) return;
    if (_resumeSnapshot != null ||
        _isLoading ||
        _status != GenerationClientState.idle) {
      return;
    }
    unawaited(() async {
      GenerationHydrationResult result;
      try {
        result = await hydrate(_threadId);
      } catch (cause) {
        _failHydration(
          createGenerationHydrationError(
            'the request to the server did not succeed',
            cause,
          ),
        );
        return;
      }
      final rawResumeSnapshot = result.resumeSnapshot;
      if (rawResumeSnapshot == null) return;
      final snapshot = parseGenerationResumeSnapshot(rawResumeSnapshot);
      if (snapshot == null) {
        _failHydration(
          createGenerationHydrationError(
            'the server returned a record this client cannot read (unknown '
            'schema version, or a missing/invalid `status` or `resumeState`)',
          ),
        );
        return;
      }
      if (_resumeSnapshot != null ||
          _isLoading ||
          _status != GenerationClientState.idle) {
        return;
      }
      _repaintRestoredSnapshot(snapshot, result.activeRun?.runId);
    }());
  }

  void _failHydration(Object error) {
    if (_resumeSnapshot != null ||
        _isLoading ||
        _status != GenerationClientState.idle) {
      return;
    }
    _setStatus(GenerationClientState.error);
    _setError(error);
    _callbacks.onError?.call(error);
  }

  void _maybeResumeInFlight() {
    if (_resumeSnapshot?.status != GenerationResumeStatus.running) return;
    final runId = _resumeSnapshot?.resumeState?.runId;
    if (runId != null && runId.isNotEmpty) _rejoinInFlight(runId);
  }

  void _rejoinInFlight(String runId) {
    final joinRun = _connection?.joinRun ?? _joinRunHandler;
    if (joinRun == null) return;
    if (_rejoinedRunId == runId) return;
    if (_isLoading || _abortController != null) return;
    _rejoinedRunId = runId;
    final controller = CancellationController();
    _abortController = controller;
    unawaited(() async {
      try {
        if (!_setIsLoading(true, controller) ||
            !_setStatus(GenerationClientState.generating, controller)) {
          return;
        }
        await _processStream(
          joinRun(runId, signal: controller.signal),
          runId,
          controller,
        );
      } catch (rawError) {
        if (_ownsRun(_abortController, controller)) {
          final failure = _asError(rawError);
          if (!_recordResumeSnapshotError(failure, controller)) return;
          _callbacks.onError?.call(failure);
        }
      } finally {
        if (identical(_abortController, controller)) {
          _patchSnapshot(runId: null);
          _abortController = null;
          _setIsLoading(false);
        }
      }
    }());
  }

  // ===========================
  // Snapshot store
  // ===========================

  static const Object _unset = Object();

  void _patchSnapshot({
    Object? result = _unset,
    Object? isLoading = _unset,
    Object? error = _unset,
    Object? status = _unset,
    Object? runId = _unset,
  }) {
    final next = GenerationClientSnapshot<TOutput>(
      result: identical(result, _unset) ? _snapshot.result : result as TOutput?,
      isLoading: identical(isLoading, _unset)
          ? _snapshot.isLoading
          : isLoading as bool,
      error: identical(error, _unset) ? _snapshot.error : error,
      status: identical(status, _unset)
          ? _snapshot.status
          : status as GenerationClientState,
      runId: identical(runId, _unset) ? _snapshot.runId : runId as String?,
    );
    if (_sameSnapshot(next, _snapshot)) return;
    _snapshot = next;
    _notify();
  }

  bool _sameSnapshot(
    GenerationClientSnapshot<TOutput> a,
    GenerationClientSnapshot<TOutput> b,
  ) =>
      identical(a.result, b.result) &&
      a.isLoading == b.isLoading &&
      identical(a.error, b.error) &&
      a.status == b.status &&
      a.runId == b.runId;

  void _notify() {
    for (final listener in List<void Function()>.of(_listeners)) {
      var spins = 0;
      late GenerationClientSnapshot<TOutput> seen;
      do {
        seen = _snapshot;
        try {
          listener();
        } catch (_) {
          // Listener failures are reported, never allowed to break a setter.
        }
        spins++;
      } while (!identical(seen, _snapshot) && spins < 8);
    }
  }

  // ===========================
  // Helpers
  // ===========================

  void _ensureThreadId() {
    if (_threadId.isEmpty) {
      _threadId = _generateUniqueId('generation');
    }
    _uniqueId = _threadId;
  }

  String _generateUniqueId(String prefix) => generateIdentity(prefix);

  RunAgentInputContext _createRunContext(
    String runId, [
    Map<String, String>? headers,
  ]) =>
      RunAgentInputContext(
        threadId: _threadId,
        runId: runId,
        headers: headers,
      );

  void _finishStoppedRun(
    String? runId,
    GenerationClientState status,
    Object? error,
  ) {
    if (runId == null || runId.isEmpty) return;
    if (status == GenerationClientState.success) {
      _devtoolsBridge.finishRun(runId, 'run:completed', 'completed');
    } else if (status == GenerationClientState.error) {
      _devtoolsBridge.finishRun(
        runId,
        'run:errored',
        'errored',
        error: generationErrorMessage(error),
      );
    } else {
      _devtoolsBridge.finishRun(runId, 'run:cancelled', 'cancelled');
    }
  }
}

Map<String, dynamic> _inputData(Object? input) {
  if (input is Map<String, dynamic>) return input;
  if (input is Map) {
    return input.map((key, value) => MapEntry('$key', value));
  }
  final dynamic dynamicInput = input;
  try {
    final json = dynamicInput.toJson();
    if (json is Map) {
      return json.map((key, value) => MapEntry('$key', value));
    }
  } catch (_) {
    // Not a typed input; fall through.
  }
  return <String, dynamic>{'input': input};
}

GenerationDevtoolsProgress? _completeProgressValue(
  GenerationDevtoolsProgress? progress,
) {
  if (progress == null) return null;
  return GenerationDevtoolsProgress(
    value: 100,
    message: progress.message,
  );
}

Object _asError(Object raw) {
  if (raw is Error || raw is Exception) return raw;
  return GenerationError('$raw');
}

bool _ownsRun(
  CancellationController? current,
  CancellationController controller,
) =>
    !controller.signal.isCancelled && identical(current, controller);

bool _owns(
  CancellationController? current,
  CancellationController? controller,
) =>
    controller == null || _ownsRun(current, controller);

bool _whileOwned(
  CancellationController? Function() getCurrent,
  CancellationController? controller,
  List<void Function()> steps,
) {
  for (final step in steps) {
    if (!_owns(getCurrent(), controller)) return false;
    step();
  }
  return _owns(getCurrent(), controller);
}
