// Ported from
// packages/ai-client/tests/audio-recorder.test.ts
import 'dart:async';

import 'package:tanstack_ai_dart/platform.dart';
import 'package:test/test.dart';

class _FakeStream implements MediaStreamHandle {
  int stops = 0;

  @override
  void stop() => stops++;
}

class _FakeRecorder implements MediaRecorderHandle {
  final _FakePlatform platform;
  final MediaStreamHandle stream;
  final String? requestedMimeType;
  void Function(List<int> data)? _onData;
  void Function()? _onStop;
  void Function(Object error)? _onError;
  String state = 'inactive';

  _FakeRecorder(this.platform, this.stream, this.requestedMimeType);

  @override
  String get mimeType => requestedMimeType ?? 'audio/webm';

  @override
  void start() {
    state = 'recording';
  }

  @override
  void stop() {
    state = 'inactive';
    _onData?.call(<int>[1, 2, 3]);
    _onStop?.call();
  }

  @override
  set onDataAvailable(void Function(List<int> data)? callback) =>
      _onData = callback;

  @override
  set onStop(void Function()? callback) => _onStop = callback;

  @override
  set onError(void Function(Object error)? callback) => _onError = callback;

  void triggerError(Object error) => _onError?.call(error);
}

class _FakePlatform implements AudioRecorderPlatform {
  final bool supported;
  final Object? mediaError;
  final bool noStop;
  final bool noData;
  Future<MediaStreamHandle>? pendingStream;

  _FakePlatform({
    this.supported = true,
    this.mediaError,
    this.noStop = false,
    this.noData = false,
  });

  Object? lastConstraints;
  _FakeRecorder? lastRecorder;
  _FakeStream? lastStream;

  @override
  bool get isSupported => supported;

  @override
  Future<MediaStreamHandle> getUserMedia(Object constraints) {
    lastConstraints = constraints;
    final pending = pendingStream;
    if (pending != null) return pending;
    if (mediaError != null) return Future.error(mediaError!);
    return Future.value(lastStream = _FakeStream());
  }

  @override
  bool isTypeSupported(String mimeType) => true;

  @override
  MediaRecorderHandle createRecorder(
    MediaStreamHandle stream, {
    String? mimeType,
  }) {
    final recorder = _FakeRecorder(this, stream, mimeType);
    lastRecorder = recorder;
    if (noStop) return _NoStopRecorder(recorder, noData: noData);
    return recorder;
  }
}

class _NoStopRecorder implements MediaRecorderHandle {
  final _FakeRecorder inner;
  final bool noData;

  _NoStopRecorder(this.inner, {required this.noData});

  @override
  String get mimeType => inner.mimeType;

  @override
  void start() => inner.start();

  @override
  void stop() {
    inner.state = 'inactive';
    if (!noData) {
      inner._onData?.call(<int>[1, 2, 3]);
    }
    // Intentionally never calls onStop.
  }

  @override
  set onDataAvailable(void Function(List<int> data)? callback) =>
      inner.onDataAvailable = callback;
  @override
  set onStop(void Function()? callback) => inner.onStop = callback;
  @override
  set onError(void Function(Object error)? callback) =>
      inner.onError = callback;
}

void main() {
  group('AudioRecorder', () {
    test('uses Set subscription behavior and reports repeated states',
        () async {
      final recorder = AudioRecorder(
        platform: _FakePlatform(mediaError: StateError('denied')),
      );
      var calls = 0;
      void listener(AudioRecorderState _) => calls++;
      final first = recorder.subscribe(listener);
      recorder.subscribe(listener);

      await expectLater(recorder.start(), throwsA(isA<StateError>()));
      expect(calls, 1);
      first();
      await expectLater(recorder.start(), throwsA(isA<StateError>()));
      expect(calls, 1);
    });

    test('isSupported() is true when media APIs exist', () {
      expect(AudioRecorder(platform: _FakePlatform()).isSupported, isTrue);
    });

    test('isSupported() is false when MediaRecorder is missing', () {
      expect(
        AudioRecorder(platform: _FakePlatform(supported: false)).isSupported,
        isFalse,
      );
      expect(AudioRecorder().isSupported, isFalse);
    });

    test('AudioRecorder getSnapshot matches state', () {
      final recorder = AudioRecorder(platform: _FakePlatform());
      expect(recorder.getSnapshot(), AudioRecorderState.idle);
      expect(recorder.getSnapshot(), recorder.state);
    });

    test('records start->stop and produces base64 + a ready audio part',
        () async {
      final platform = _FakePlatform();
      final recorder = AudioRecorder(platform: platform);
      final states = <AudioRecorderState>[];
      recorder.subscribe(states.add);

      await recorder.start();
      expect(recorder.state, AudioRecorderState.recording);
      expect(platform.lastConstraints, {'audio': true});

      final recording = await recorder.stop();
      expect(recording.mimeType, 'audio/webm');
      expect(recording.base64, 'AQID');
      expect(recording.part, {
        'type': 'audio',
        'source': {'type': 'data', 'value': 'AQID', 'mimeType': 'audio/webm'},
      });
      expect(recording.durationMs, isA<int>());
      expect(recorder.state, AudioRecorderState.idle);
      expect(states, contains(AudioRecorderState.recording));
      expect(states, contains(AudioRecorderState.idle));
    });

    test('a throwing listener does not skip others or strand stop()', () async {
      final errors = <Object>[];
      final previous = listenerErrorReporter;
      listenerErrorReporter = (error, _) => errors.add(error);
      final states = <AudioRecorderState>[];
      final recorder = AudioRecorder(platform: _FakePlatform());
      recorder.subscribe((_) {
        throw StateError('listener failed');
      });
      recorder.subscribe(states.add);

      await recorder.start();
      final recording = await recorder.stop();

      expect(recording.base64, 'AQID');
      expect(states, [
        AudioRecorderState.recording,
        AudioRecorderState.stopping,
        AudioRecorderState.idle,
      ]);
      expect(recorder.state, AudioRecorderState.idle);
      expect(errors, isNotEmpty);
      listenerErrorReporter = previous;
    });

    test('stops microphone tracks on stop', () async {
      final platform = _FakePlatform();
      final recorder = AudioRecorder(platform: platform);
      await recorder.start();
      await recorder.stop();
      expect(platform.lastStream!.stops, 1);
    });

    test('routes getUserMedia rejection to onError and rethrows', () async {
      Object? reported;
      final recorder = AudioRecorder(
        platform: _FakePlatform(mediaError: StateError('Permission denied')),
        options: AudioRecorderOptions(onError: (error) => reported = error),
      );
      await expectLater(recorder.start(), throwsA(isA<StateError>()));
      expect(reported, isNotNull);
      expect(recorder.state, AudioRecorderState.idle);
    });

    test('cancel() releases the mic and produces no recording', () async {
      final platform = _FakePlatform();
      final recorder = AudioRecorder(platform: platform);
      await recorder.start();
      recorder.cancel();
      expect(platform.lastStream!.stops, 1);
      expect(recorder.state, AudioRecorderState.idle);
    });

    test('rejects stop() when not recording', () async {
      final recorder = AudioRecorder(platform: _FakePlatform());
      await expectLater(recorder.stop(), throwsA(isA<StateError>()));
    });

    test('honors a supported custom mimeType', () async {
      final platform = _FakePlatform();
      final recorder = AudioRecorder(
        platform: platform,
        options: const AudioRecorderOptions(mimeType: 'audio/mp4'),
      );
      await recorder.start();
      expect(platform.lastRecorder?.requestedMimeType, 'audio/mp4');
      await recorder.stop();
    });

    test('onerror preserves the underlying error detail', () async {
      Object? reported;
      final platform = _FakePlatform();
      final recorder = AudioRecorder(
        platform: platform,
        options: AudioRecorderOptions(onError: (error) => reported = error),
      );
      await recorder.start();
      platform.lastRecorder!.triggerError(StateError('NotAllowedError'));
      expect(reported, isNotNull);
      expect('$reported', contains('NotAllowedError'));
      expect(recorder.state, AudioRecorderState.idle);
    });

    test('cancel during finalize settles stop() exactly once', () async {
      final recorder = AudioRecorder(platform: _FakePlatform());
      await recorder.start();

      var resolved = 0;
      var rejected = 0;
      final settled = recorder.stop().then(
            (_) => resolved++,
            onError: (_) => rejected++,
          );
      recorder.cancel();
      await settled;
      await Future<void>.value();
      await Future<void>.value();

      expect(rejected, 1);
      expect(resolved, 0);
      expect(recorder.state, AudioRecorderState.idle);
    });

    test('routes a finalize failure to onError and rejects stop()', () async {
      Object? reported;
      final recorder = AudioRecorder(
        platform: _FakePlatform(),
        options: AudioRecorderOptions(onError: (error) => reported = error),
        assembleBytes: (_) => Future.error(StateError('decode failed')),
      );
      await recorder.start();

      await expectLater(recorder.stop(), throwsA(isA<StateError>()));
      expect('$reported', contains('decode failed'));
      expect(recorder.state, AudioRecorderState.idle);
    });

    test('a throwing onError still rejects the pending stop() promise',
        () async {
      final errors = <Object>[];
      final previous = listenerErrorReporter;
      listenerErrorReporter = (error, _) => errors.add(error);
      var onErrorCalls = 0;
      final recorder = AudioRecorder(
        platform: _FakePlatform(),
        options: AudioRecorderOptions(onError: (_) {
          onErrorCalls++;
          throw StateError('user handler blew up');
        }),
        assembleBytes: (_) => Future.error(StateError('decode failed')),
      );
      await recorder.start();

      await expectLater(recorder.stop(), throwsA(isA<StateError>()));
      expect(onErrorCalls, 1);
      expect(recorder.state, AudioRecorderState.idle);
      listenerErrorReporter = previous;
    });

    test('stop() watchdog recovers buffered audio when onstop never fires',
        () async {
      final platform = _FakePlatform(noStop: true);
      final recorder = AudioRecorder(
        platform: platform,
        stopTimeout: const Duration(milliseconds: 10),
      );
      await recorder.start();
      final recording = await recorder.stop();
      expect(recording.base64, 'AQID');
      expect(recording.mimeType, 'audio/webm');
      expect(recorder.state, AudioRecorderState.idle);
    });

    test('stop() watchdog rejects when no audio was captured', () async {
      final platform = _FakePlatform(noStop: true, noData: true);
      final recorder = AudioRecorder(
        platform: platform,
        stopTimeout: const Duration(milliseconds: 10),
      );
      await recorder.start();
      Object? capturedError;
      var resolved = false;
      await recorder.stop().then<void>(
        (_) {
          resolved = true;
        },
        onError: (Object error) {
          capturedError = error;
        },
      );
      expect(resolved, isFalse);
      expect(capturedError, isA<StateError>());
      expect('$capturedError', contains('timed out'));
      expect(recorder.state, AudioRecorderState.idle);
    });

    test('cancel() during a pending start() releases the mic and never records',
        () async {
      final platform = _FakePlatform();
      final completer = Completer<MediaStreamHandle>();
      platform.pendingStream = completer.future;
      final recorder = AudioRecorder(platform: platform);
      final startPromise = recorder.start();
      recorder.cancel();
      final stream = _FakeStream();
      completer.complete(stream);
      await startPromise;

      expect(stream.stops, 1);
      expect(recorder.state, AudioRecorderState.idle);

      platform.pendingStream = null;
      await recorder.start();
      expect(recorder.state, AudioRecorderState.recording);
      await recorder.stop();
    });
  });
}
