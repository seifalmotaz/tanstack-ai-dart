// Ported from the realtime scenarios in
// packages/ai-client/tests/client-snapshots.test.ts
import 'dart:async';

import 'package:tanstack_ai_dart/platform.dart';
import 'package:test/test.dart';

class _FakeAudioVisualization implements AudioVisualization {
  @override
  double get inputLevel => 0;
  @override
  double get outputLevel => 0;
  @override
  List<int> getInputFrequencyData() => <int>[];
  @override
  List<int> getOutputFrequencyData() => <int>[];
  @override
  List<int> getInputTimeDomainData() => <int>[];
  @override
  List<int> getOutputTimeDomainData() => <int>[];
  @override
  int get inputSampleRate => 0;
  @override
  int get outputSampleRate => 0;
  @override
  void Function()? onInputAudio(
    void Function(List<double> samples, int sampleRate) callback,
  ) =>
      null;
  @override
  void Function()? onOutputAudio(
    void Function(List<double> samples, int sampleRate) callback,
  ) =>
      null;
}

class _FakeConnection implements RealtimeConnection {
  _FakeConnection({this.onStartAudioCapture});

  final void Function()? onStartAudioCapture;
  final Map<RealtimeEvent, void Function(RealtimeEventPayload)> handlers =
      <RealtimeEvent, void Function(RealtimeEventPayload)>{};
  bool disconnected = false;

  void emit(RealtimeEvent event, RealtimeEventPayload payload) =>
      handlers[event]?.call(payload);

  @override
  Future<void> disconnect() async {
    disconnected = true;
  }

  @override
  Future<void> startAudioCapture() async => onStartAudioCapture?.call();

  @override
  void stopAudioCapture() {}
  @override
  void sendText(String text) {}
  @override
  void sendImage(String imageData, String mimeType) {}
  @override
  void sendToolResult(String callId, String result) {}
  @override
  void updateSession(RealtimeSessionConfig config) {}
  @override
  void updateToken(RealtimeToken token) {}
  @override
  void interrupt() {}
  @override
  void Function() on(
    RealtimeEvent event,
    void Function(RealtimeEventPayload payload) handler,
  ) {
    handlers[event] = handler;
    return () => handlers.remove(event);
  }

  @override
  AudioVisualization getAudioVisualization() => _FakeAudioVisualization();
}

RealtimeToken _token({int expiresInMs = 120000}) => RealtimeToken(
      provider: 'test',
      token: 'token',
      expiresAt: DateTime.now().millisecondsSinceEpoch + expiresInMs,
    );

void main() {
  group('RealtimeClient', () {
    test('subscribe fires when connect fails', () async {
      final client = RealtimeClient(RealtimeClientOptions(
        getToken: () async => throw StateError('no token'),
        adapter: _ThrowingAdapter(),
      ));
      final snapshot = client.getSnapshot();
      expect(snapshot.status, RealtimeStatus.idle);
      expect(identical(client.getSnapshot(), snapshot), isTrue);

      var calls = 0;
      final stop = client.subscribe(() => calls++);
      await expectLater(client.connect(), throwsA(isA<StateError>()));

      expect(calls, greaterThan(0));
      expect(client.getSnapshot().status, RealtimeStatus.error);
      expect(identical(client.getSnapshot(), snapshot), isFalse);
      final count = calls;
      stop();
      await expectLater(client.connect(), throwsA(isA<StateError>()));
      expect(calls, count);
      client.destroy();
    });

    test('does not read connection control from its public snapshot', () async {
      var tokenCalls = 0;
      final client = RealtimeClient(RealtimeClientOptions(
        getToken: () async {
          tokenCalls++;
          throw StateError('token attempted');
        },
        adapter: _ThrowingAdapter(),
      ));

      expect(client.getSnapshot().status, RealtimeStatus.idle);
      await expectLater(client.connect(), throwsA(isA<StateError>()));
      expect(tokenCalls, 1);
      client.destroy();
    });

    test('isolates connection control from state change callbacks', () async {
      var tokenCalls = 0;
      var connectCalls = 0;
      final client = RealtimeClient(RealtimeClientOptions(
        getToken: () async {
          tokenCalls++;
          return _token();
        },
        adapter: _CallbackAdapter(() {
          connectCalls++;
          throw StateError('connect attempted');
        }),
      ));
      client.onStateChange((state) {
        // The snapshot is immutable in Dart; this callback cannot flip status.
        expect(state.status, isNot(RealtimeStatus.connected));
      });

      await expectLater(client.connect(), throwsA(isA<StateError>()));
      await expectLater(client.connect(), throwsA(isA<StateError>()));

      expect(tokenCalls, 2);
      expect(connectCalls, 2);
      client.destroy();
    });

    test(
        'keeps the transcript when connect fails and clears it after a later success',
        () async {
      var connects = 0;
      final connection = _FakeConnection();
      final client = RealtimeClient(RealtimeClientOptions(
        getToken: () async {
          connects++;
          if (connects == 2) throw StateError('no token');
          return _token();
        },
        adapter: _ConnectionAdapter(connection),
        autoCapture: false,
      ));

      await client.connect();
      client.sendText('keep me');
      expect(client.getSnapshot().messages, hasLength(1));
      await client.disconnect();
      expect(client.getSnapshot().messages, hasLength(1));

      await expectLater(client.connect(), throwsA(isA<StateError>()));
      expect(client.getSnapshot().status, RealtimeStatus.error);
      expect(client.getSnapshot().messages, hasLength(1));

      await client.connect();
      expect(client.getSnapshot().status, RealtimeStatus.connected);
      expect(client.getSnapshot().messages, isEmpty);
      client.destroy();
    });

    test('keeps a transcript that arrives while audio capture starts',
        () async {
      late _FakeConnection connection;
      connection = _FakeConnection(
        onStartAudioCapture: () => connection.emit(
          RealtimeEvent.transcript,
          const RealtimeTranscriptEvent(
            role: 'assistant',
            transcript: 'Hello',
            isFinal: false,
          ),
        ),
      );
      final client = RealtimeClient(RealtimeClientOptions(
        getToken: () async => _token(),
        adapter: _ConnectionAdapter(connection),
      ));

      await client.connect();

      expect(client.getSnapshot().status, RealtimeStatus.connected);
      expect(client.getSnapshot().pendingAssistantTranscript, 'Hello');
      client.destroy();
    });

    test('state change callbacks are isolated from a throwing one', () async {
      final errors = <Object>[];
      final previous = listenerErrorReporter;
      listenerErrorReporter = (error, _) => errors.add(error);
      final client = RealtimeClient(RealtimeClientOptions(
        getToken: () async => throw StateError('no token'),
        adapter: _ThrowingAdapter(),
      ));
      final seen = <RealtimeStatus>[];
      client.onStateChange((_) {
        throw StateError('listener failed');
      });
      client.onStateChange((state) => seen.add(state.status));

      await expectLater(client.connect(), throwsA(isA<StateError>()));

      expect(seen, [RealtimeStatus.connecting, RealtimeStatus.error]);
      expect(errors, isNotEmpty);
      await client.disconnect();
      client.destroy();
      await Future<void>.delayed(Duration.zero);
      listenerErrorReporter = previous;
    });

    test('keeps the identity of unchanged messages across snapshots', () async {
      final connection = _FakeConnection();
      final client = RealtimeClient(RealtimeClientOptions(
        getToken: () async => _token(),
        adapter: _ConnectionAdapter(connection),
        autoCapture: false,
      ));
      await client.connect();

      client.sendText('first');
      final first = client.getSnapshot().messages[0];
      client.sendText('second');

      final messages = client.getSnapshot().messages;
      expect(messages, hasLength(2));
      expect(identical(messages[0], first), isTrue);
      expect(() => messages.add(first), throwsA(isA<UnsupportedError>()));

      // A state change that is not a message change keeps the same array.
      client.stopListening();
      expect(client.getSnapshot().mode, RealtimeMode.idle);
      expect(identical(client.getSnapshot().messages, messages), isTrue);
      client.destroy();
    });
  });
}

class _ThrowingAdapter implements RealtimeAdapter {
  @override
  String get provider => 'test';

  @override
  Future<RealtimeConnection> connect(
    RealtimeToken token, [
    List<ClientTool>? clientTools,
  ]) async =>
      throw StateError('unused');
}

class _CallbackAdapter implements RealtimeAdapter {
  _CallbackAdapter(this.callback);

  final void Function() callback;

  @override
  String get provider => 'test';

  @override
  Future<RealtimeConnection> connect(
    RealtimeToken token, [
    List<ClientTool>? clientTools,
  ]) async {
    callback();
    throw StateError('unreachable');
  }
}

class _ConnectionAdapter implements RealtimeAdapter {
  _ConnectionAdapter(this.connection);

  final RealtimeConnection connection;

  @override
  String get provider => 'test';

  @override
  Future<RealtimeConnection> connect(
    RealtimeToken token, [
    List<ClientTool>? clientTools,
  ]) async =>
      connection;
}
