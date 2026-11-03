import 'dart:async';
import 'dart:convert';

import 'snapshot_atom.dart';

/// Ported from `packages/ai-client/src/audio-recorder.ts`.
///
/// `getUserMedia` and `MediaRecorder` are browser-only. Pure Dart has no
/// built-in microphone or recorder, so both are supplied through
/// [AudioRecorderPlatform]. Without an injected platform the recorder reports
/// unsupported and `start()` throws [UnsupportedError]; the package does not
/// pretend to capture audio natively.

enum AudioRecorderState { idle, recording, stopping }

class AudioRecorderOptions {
  /// Forwarded to the platform as `{'audio': audio ?? true}`.
  final Object? audio;
  final String? mimeType;
  final void Function(Object error)? onError;

  const AudioRecorderOptions({this.audio, this.mimeType, this.onError});
}

/// Recorded output. `bytes` replaces the upstream browser `Blob`.
class AudioRecording {
  final List<int> bytes;
  final String base64;
  final String mimeType;
  final int durationMs;

  /// Ready-to-use audio content part, matching the upstream wire shape.
  final Map<String, dynamic> part;

  AudioRecording({
    required this.bytes,
    required this.base64,
    required this.mimeType,
    required this.durationMs,
    required this.part,
  });
}

abstract class MediaStreamHandle {
  void stop();
}

abstract class MediaRecorderHandle {
  String get mimeType;
  void start();
  void stop();
  set onDataAvailable(void Function(List<int> data)? callback);
  set onStop(void Function()? callback);
  set onError(void Function(Object error)? callback);
}

abstract class AudioRecorderPlatform {
  bool get isSupported;
  Future<MediaStreamHandle> getUserMedia(Object constraints);
  bool isTypeSupported(String mimeType);
  MediaRecorderHandle createRecorder(
    MediaStreamHandle stream, {
    String? mimeType,
  });
}

class _UnavailableAudioRecorderPlatform implements AudioRecorderPlatform {
  const _UnavailableAudioRecorderPlatform();

  @override
  bool get isSupported => false;

  @override
  Future<MediaStreamHandle> getUserMedia(Object constraints) =>
      Future<MediaStreamHandle>.error(
        UnsupportedError(
          'Audio capture is unavailable in pure Dart. Inject an '
          'AudioRecorderPlatform backed by navigator.mediaDevices/MediaRecorder.',
        ),
      );

  @override
  bool isTypeSupported(String mimeType) => false;

  @override
  MediaRecorderHandle createRecorder(
    MediaStreamHandle stream, {
    String? mimeType,
  }) =>
      throw UnsupportedError('MediaRecorder is unavailable in pure Dart.');
}

/// Framework-agnostic audio recorder over an injected browser platform.
class AudioRecorder {
  final AudioRecorderOptions options;
  final AudioRecorderPlatform platform;
  final Duration stopTimeout;
  final FutureOr<List<int>> Function(List<List<int>> chunks)? assembleBytes;

  MediaRecorderHandle? _recorder;
  MediaStreamHandle? _stream;
  List<List<int>> _chunks = <List<int>>[];
  int _startedAt = 0;
  AudioRecorderState _state = AudioRecorderState.idle;
  final Set<void Function(AudioRecorderState)> _listeners =
      <void Function(AudioRecorderState)>{};

  bool _starting = false;
  bool _pendingCancel = false;
  void Function(AudioRecording recording)? _stopResolve;
  void Function(Object error)? _stopReject;

  AudioRecorder({
    this.options = const AudioRecorderOptions(),
    AudioRecorderPlatform? platform,
    this.stopTimeout = const Duration(seconds: 10),
    this.assembleBytes,
  }) : platform = platform ?? const _UnavailableAudioRecorderPlatform();

  /// Feature detection for the injected platform.
  bool get isSupported => platform.isSupported;

  AudioRecorderState get state => _state;

  void Function() subscribe(void Function(AudioRecorderState) callback) {
    _listeners.add(callback);
    return () => _listeners.remove(callback);
  }

  AudioRecorderState getSnapshot() => _state;

  void _setState(AudioRecorderState state) {
    _state = state;
    notifyListeners([
      for (final listener in _listeners) () => listener(state),
    ]);
  }

  Future<void> start() async {
    if (_state != AudioRecorderState.idle || _starting) return;
    _starting = true;
    try {
      final stream = await platform.getUserMedia({
        'audio': options.audio ?? true,
      });
      if (_pendingCancel) {
        stream.stop();
        return;
      }
      _stream = stream;
      final wanted = options.mimeType;
      final useMimeType =
          wanted != null && platform.isTypeSupported(wanted) ? wanted : null;
      final recorder = platform.createRecorder(
        stream,
        mimeType: useMimeType,
      );
      _chunks = <List<int>>[];
      recorder.onDataAvailable = (data) {
        if (data.isNotEmpty) _chunks.add(List<int>.of(data));
      };
      recorder.onStop = () {
        unawaited(finalize());
      };
      recorder.onError = (error) {
        handleError(error);
      };
      _recorder = recorder;
      _startedAt = DateTime.now().millisecondsSinceEpoch;
      recorder.start();
      _setState(AudioRecorderState.recording);
    } catch (error) {
      releaseStream();
      _recorder = null;
      _setState(AudioRecorderState.idle);
      notifyError(error);
      rethrow;
    } finally {
      _starting = false;
      _pendingCancel = false;
    }
  }

  Future<AudioRecording> stop() {
    if (_state != AudioRecorderState.recording || _recorder == null) {
      return Future<AudioRecording>.error(
        StateError('AudioRecorder.stop() called while not recording'),
      );
    }
    _setState(AudioRecorderState.stopping);
    final recorder = _recorder!;
    final completer = Completer<AudioRecording>();
    late Timer watchdog;
    watchdog = Timer(stopTimeout, () {
      if (_state != AudioRecorderState.stopping) return;
      detachRecorder();
      if (_chunks.isNotEmpty) {
        unawaited(finalize());
      } else {
        handleError(
          StateError('Recording stop timed out after 10s with no audio'),
        );
      }
    });
    _stopResolve = (recording) {
      watchdog.cancel();
      completer.complete(recording);
    };
    _stopReject = (error) {
      watchdog.cancel();
      completer.completeError(error);
    };
    recorder.stop();
    return completer.future;
  }

  void cancel() {
    if (_starting) {
      _pendingCancel = true;
      return;
    }
    if (_state == AudioRecorderState.idle) return;
    final recorder = _recorder;
    if (recorder != null) {
      detachRecorder();
      try {
        recorder.stop();
      } catch (error) {
        notifyError(error);
      }
    }
    releaseStream();
    _recorder = null;
    _chunks = <List<int>>[];
    final reject = _stopReject;
    _stopResolve = null;
    _stopReject = null;
    reject?.call(StateError('Recording cancelled'));
    _setState(AudioRecorderState.idle);
  }

  Future<void> finalize() async {
    final mimeType = _recorder?.mimeType ?? 'audio/webm';
    final durationMs = DateTime.now().millisecondsSinceEpoch - _startedAt;
    try {
      // Yield once. A synchronous cancel() after stop() therefore settles the
      // pending stop promise before finalize publishes its late result.
      await Future<void>.value();
      final assemble = assembleBytes;
      final bytes = assemble != null
          ? await assemble(_chunks)
          : <int>[
              for (final chunk in _chunks) ...chunk,
            ];
      final base64Value = base64Encode(bytes);
      final recording = AudioRecording(
        bytes: bytes,
        base64: base64Value,
        mimeType: mimeType,
        durationMs: durationMs,
        part: {
          'type': 'audio',
          'source': {
            'type': 'data',
            'value': base64Value,
            'mimeType': mimeType,
          },
        },
      );
      releaseStream();
      _recorder = null;
      _chunks = <List<int>>[];
      final resolve = _stopResolve;
      _stopResolve = null;
      _stopReject = null;
      resolve?.call(recording);
      _setState(AudioRecorderState.idle);
    } catch (error) {
      handleError(error);
    }
  }

  void handleError(Object error) {
    releaseStream();
    _recorder = null;
    _chunks = <List<int>>[];
    final reject = _stopReject;
    _stopResolve = null;
    _stopReject = null;
    reject?.call(error);
    _setState(AudioRecorderState.idle);
    notifyError(error);
  }

  void notifyError(Object error) {
    try {
      options.onError?.call(error);
    } catch (_) {
      // A user onError that throws must not propagate into recorder internals.
    }
  }

  void releaseStream() {
    _stream?.stop();
    _stream = null;
  }

  void detachRecorder() {
    final recorder = _recorder;
    if (recorder == null) return;
    recorder.onStop = null;
    recorder.onError = null;
    recorder.onDataAvailable = null;
  }
}
