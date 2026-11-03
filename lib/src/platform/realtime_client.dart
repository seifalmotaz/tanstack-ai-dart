import 'dart:async';
import 'dart:convert';

import 'realtime_types.dart';
import 'snapshot_atom.dart';
import 'tool_types.dart';

/// Ported from `packages/ai-client/src/realtime-client.ts`.
const int _tokenRefreshBufferMs = 60000;
const Object _absent = Object();

class RealtimeClient {
  final RealtimeClientOptions options;
  final Map<String, ClientTool> clientTools = <String, ClientTool>{};
  final Set<RealtimeStateChangeCallback> _stateChangeCallbacks =
      <RealtimeStateChangeCallback>{};
  List<void Function()> _unsubscribers = <void Function()>[];

  RealtimeConnection? _connection;
  RealtimeToken? _token;
  Timer? _tokenRefreshTimeout;

  RealtimeClientState _state = const RealtimeClientState();
  late final Atom<RealtimeClientState> _snapshotAtom;
  RealtimeClientState _snapshot = const RealtimeClientState();
  final Map<RealtimeMessage, RealtimeMessage> _frozenMessages =
      <RealtimeMessage, RealtimeMessage>{};

  String? _instructions;
  String? _voice;
  String? _vadMode;
  List<String>? _outputModalities;
  double? _temperature;
  Object? _maxOutputTokens;
  String? _semanticEagerness;
  Map<String, dynamic>? _providerOptions;

  RealtimeClient(this.options) {
    _instructions = options.instructions;
    _voice = options.voice;
    _vadMode = options.vadMode;
    _outputModalities = options.outputModalities;
    _temperature = options.temperature;
    _maxOutputTokens = options.maxOutputTokens;
    _semanticEagerness = options.semanticEagerness;
    _providerOptions = options.providerOptions;
    for (final tool in options.tools ?? const <ClientTool>[]) {
      clientTools[tool.name] = tool;
    }
    _snapshot = _buildSnapshot();
    _snapshotAtom = Atom<RealtimeClientState>(_snapshot);
  }

  Future<void> connect() async {
    if (_state.status == RealtimeStatus.connected) return;

    _updateState(status: RealtimeStatus.connecting, error: null);

    try {
      _token = await options.getToken();
      _scheduleTokenRefresh();

      final toolsList =
          clientTools.isEmpty ? null : clientTools.values.toList();
      _connection = await options.adapter.connect(_token!, toolsList);

      _updateState(
        messages: const <RealtimeMessage>[],
        pendingUserTranscript: null,
        pendingAssistantTranscript: null,
      );

      _subscribeToConnectionEvents();
      _applySessionConfig();

      if (options.autoCapture) {
        await _connection!.startAudioCapture();
      }

      _updateState(
        status: RealtimeStatus.connected,
        mode: RealtimeMode.listening,
      );
      options.onConnect?.call();
    } catch (error) {
      _updateState(status: RealtimeStatus.error, error: error);
      options.onError?.call(error);
      rethrow;
    }
  }

  Future<void> disconnect() async {
    _tokenRefreshTimeout?.cancel();
    _tokenRefreshTimeout = null;

    for (final unsubscribe in _unsubscribers) {
      unsubscribe();
    }
    _unsubscribers = <void Function()>[];

    final connection = _connection;
    if (connection != null) {
      await connection.disconnect();
      _connection = null;
    }

    _token = null;
    _updateState(
      status: RealtimeStatus.idle,
      mode: RealtimeMode.idle,
      pendingUserTranscript: null,
      pendingAssistantTranscript: null,
    );
    options.onDisconnect?.call();
  }

  void startListening() {
    final connection = _connection;
    if (connection == null || _state.status != RealtimeStatus.connected) return;
    unawaited(connection.startAudioCapture());
    _updateState(mode: RealtimeMode.listening);
  }

  void stopListening() {
    final connection = _connection;
    if (connection == null) return;
    connection.stopAudioCapture();
    _updateState(mode: RealtimeMode.idle);
  }

  void interrupt() {
    final connection = _connection;
    if (connection == null) return;
    connection.interrupt();
    _updateState(pendingAssistantTranscript: null);
  }

  void sendText(String text) {
    final connection = _connection;
    if (connection == null || _state.status != RealtimeStatus.connected) {
      return;
    }
    addMessage(RealtimeMessage(
      id: _generateId(),
      role: 'user',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      parts: <RealtimeMessagePart>[RealtimeTextPart(text)],
    ));
    connection.sendText(text);
  }

  void sendImage(String imageData, String mimeType) {
    final connection = _connection;
    if (connection == null || _state.status != RealtimeStatus.connected) {
      return;
    }
    addMessage(RealtimeMessage(
      id: _generateId(),
      role: 'user',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      parts: <RealtimeMessagePart>[
        RealtimeImagePart(data: imageData, mimeType: mimeType),
      ],
    ));
    connection.sendImage(imageData, mimeType);
  }

  RealtimeStatus get status => _state.status;
  RealtimeMode get mode => _state.mode;
  List<RealtimeMessage> get messages => _state.messages;
  Object? get error => _state.error;
  String? get pendingUserTranscript => _state.pendingUserTranscript;
  String? get pendingAssistantTranscript => _state.pendingAssistantTranscript;
  AudioVisualization? get audio => _connection?.getAudioVisualization();

  void updateSession(RealtimeSessionConfig config) {
    if (config.instructions != null) _instructions = config.instructions;
    if (config.voice != null) _voice = config.voice;
    if (config.vadMode != null) _vadMode = config.vadMode;
    if (config.outputModalities != null) {
      _outputModalities = config.outputModalities;
    }
    if (config.temperature != null) _temperature = config.temperature;
    if (config.maxOutputTokens != null) {
      _maxOutputTokens = config.maxOutputTokens;
    }
    if (config.semanticEagerness != null) {
      _semanticEagerness = config.semanticEagerness;
    }
    if (config.providerOptions != null) {
      _providerOptions = config.providerOptions;
    }
    if (_connection != null) _applySessionConfig();
  }

  void Function() onStateChange(RealtimeStateChangeCallback callback) {
    _stateChangeCallbacks.add(callback);
    return () => _stateChangeCallbacks.remove(callback);
  }

  void Function() subscribe(void Function() listener) =>
      subscribeAtom(_snapshotAtom, listener);

  RealtimeClientState getSnapshot() => _snapshotAtom.get();

  void destroy() {
    unawaited(disconnect());
    _stateChangeCallbacks.clear();
  }

  void _updateState({
    RealtimeStatus? status,
    RealtimeMode? mode,
    List<RealtimeMessage>? messages,
    Object? pendingUserTranscript = _absent,
    Object? pendingAssistantTranscript = _absent,
    Object? error = _absent,
  }) {
    final next = _state.copyWith(
      status: status,
      mode: mode,
      messages: messages,
      pendingUserTranscript: pendingUserTranscript,
      pendingAssistantTranscript: pendingAssistantTranscript,
      error: error,
    );

    final statusChanged = next.status != _state.status;
    final modeChanged = next.mode != _state.mode;
    final messagesChanged = !identical(next.messages, _state.messages);
    final userChanged =
        next.pendingUserTranscript != _state.pendingUserTranscript;
    final assistantChanged =
        next.pendingAssistantTranscript != _state.pendingAssistantTranscript;
    final errorChanged = !identical(next.error, _state.error);
    if (!statusChanged &&
        !modeChanged &&
        !messagesChanged &&
        !userChanged &&
        !assistantChanged &&
        !errorChanged) {
      return;
    }

    _state = next;
    final snapshot = messagesChanged
        ? _buildSnapshot()
        : RealtimeClientState(
            status: _state.status,
            mode: _state.mode,
            messages: _snapshot.messages,
            pendingUserTranscript: _state.pendingUserTranscript,
            pendingAssistantTranscript: _state.pendingAssistantTranscript,
            error: _state.error,
          );
    _snapshot = snapshot;
    _snapshotAtom.set(snapshot);

    notifyListeners([
      for (final callback in _stateChangeCallbacks) () => callback(snapshot),
    ]);

    if (statusChanged) options.onStatusChange?.call(_state.status);
    if (modeChanged) options.onModeChange?.call(_state.mode);
  }

  RealtimeClientState _buildSnapshot() {
    final messages = <RealtimeMessage>[];
    for (final message in _state.messages) {
      final cached = _frozenMessages[message];
      if (cached != null) {
        messages.add(cached);
        continue;
      }
      final frozen = RealtimeMessage(
        id: message.id,
        role: message.role,
        timestamp: message.timestamp,
        parts: List<RealtimeMessagePart>.unmodifiable(message.parts),
        interrupted: message.interrupted,
        audioId: message.audioId,
        durationMs: message.durationMs,
      );
      _frozenMessages[message] = frozen;
      messages.add(frozen);
    }
    return RealtimeClientState(
      status: _state.status,
      mode: _state.mode,
      messages: List<RealtimeMessage>.unmodifiable(messages),
      pendingUserTranscript: _state.pendingUserTranscript,
      pendingAssistantTranscript: _state.pendingAssistantTranscript,
      error: _state.error,
    );
  }

  void addMessage(RealtimeMessage message) {
    _updateState(
      messages: <RealtimeMessage>[..._state.messages, message],
    );
    options.onMessage?.call(message);
  }

  void _scheduleTokenRefresh() {
    final token = _token;
    if (token == null) return;
    final timeUntilExpiry =
        token.expiresAt - DateTime.now().millisecondsSinceEpoch;
    final refreshIn = <int>[
      0,
      timeUntilExpiry - _tokenRefreshBufferMs,
    ].reduce((a, b) => a > b ? a : b);
    _tokenRefreshTimeout = Timer(
      Duration(milliseconds: refreshIn),
      () => unawaited(_refreshToken()),
    );
  }

  Future<void> _refreshToken() async {
    try {
      _token = await options.getToken();
      _scheduleTokenRefresh();
      _connection?.updateToken(_token!);
    } catch (error) {
      _updateState(error: error);
      options.onError?.call(error);
    }
  }

  void _subscribeToConnectionEvents() {
    final connection = _connection;
    if (connection == null) return;

    _unsubscribers.add(connection.on(
      RealtimeEvent.statusChange,
      (payload) => _updateState(
        status: (payload as RealtimeStatusChange).status,
      ),
    ));
    _unsubscribers.add(connection.on(
      RealtimeEvent.modeChange,
      (payload) => _updateState(mode: (payload as RealtimeModeChange).mode),
    ));
    _unsubscribers.add(connection.on(RealtimeEvent.transcript, (payload) {
      final transcript = payload as RealtimeTranscriptEvent;
      if (transcript.role == 'user') {
        _updateState(
          pendingUserTranscript:
              transcript.isFinal ? null : transcript.transcript,
        );
        if (transcript.isFinal && transcript.transcript.isNotEmpty) {
          addMessage(RealtimeMessage(
            id: _generateId(),
            role: 'user',
            timestamp: DateTime.now().millisecondsSinceEpoch,
            parts: <RealtimeMessagePart>[
              RealtimeAudioPart(
                  transcript: transcript.transcript, durationMs: 0),
            ],
          ));
        }
      } else {
        _updateState(
          pendingAssistantTranscript:
              transcript.isFinal ? null : transcript.transcript,
        );
      }
    }));
    _unsubscribers.add(connection.on(RealtimeEvent.toolCall, (payload) {
      final call = payload as RealtimeToolCallEvent;
      final toolCallId = call.toolCallId;
      if (toolCallId == null) return;
      final tool = clientTools[call.toolName];
      final execute = tool?.execute;
      if (execute != null) {
        unawaited(Future<void>(() async {
          try {
            final output = await Future<Object?>.sync(
              () => execute(call.input, const ToolCallContext()),
            );
            connection.sendToolResult(
              toolCallId,
              output is String ? output : jsonEncode(output),
            );
          } catch (error) {
            connection.sendToolResult(
              toolCallId,
              jsonEncode({'error': '$error'}),
            );
          }
        }));
      } else {
        connection.sendToolResult(
          toolCallId,
          jsonEncode(
              {'error': 'Unknown or non-executable tool: ${call.toolName}'}),
        );
      }
    }));
    _unsubscribers.add(connection.on(
      RealtimeEvent.messageComplete,
      (payload) => _replaceMessage(
        (payload as RealtimeMessageCompleteEvent).message,
      ),
    ));
    _unsubscribers.add(connection.on(RealtimeEvent.interrupted, (payload) {
      final messageId = (payload as RealtimeInterruptedEvent).messageId;
      if (messageId != null) {
        _updateState(
          messages: _state.messages
              .map(
                (message) => message.id == messageId
                    ? message.copyWith(interrupted: true)
                    : message,
              )
              .toList(growable: false),
        );
      }
      _updateState(
        mode: RealtimeMode.listening,
        pendingAssistantTranscript: null,
      );
      options.onInterrupted?.call();
    }));
    _unsubscribers.add(connection.on(RealtimeEvent.error, (payload) {
      final error = (payload as RealtimeErrorEvent).error;
      _updateState(error: error);
      options.onError?.call(error);
    }));
    _unsubscribers.add(connection.on(
      RealtimeEvent.goAway,
      (payload) =>
          options.onGoAway?.call((payload as RealtimeGoAwayEvent).timeLeft),
    ));
    _unsubscribers.add(connection.on(
      RealtimeEvent.usage,
      (payload) => options.onUsage?.call((payload as RealtimeUsageEvent).usage),
    ));
  }

  void _replaceMessage(RealtimeMessage message) {
    final index = _state.messages.indexWhere((item) => item.id == message.id);
    if (index >= 0) {
      final next = List<RealtimeMessage>.of(_state.messages);
      next[index] = message;
      _updateState(messages: next);
    } else {
      addMessage(message);
    }
  }

  void _applySessionConfig() {
    final connection = _connection;
    if (connection == null) return;

    final optionsTools = options.tools;
    final hasConfig = _instructions != null ||
        _voice != null ||
        _vadMode != null ||
        (optionsTools != null && optionsTools.isNotEmpty) ||
        _outputModalities != null ||
        _temperature != null ||
        _maxOutputTokens != null ||
        _semanticEagerness != null;
    if (!hasConfig) return;

    final toolsConfig = optionsTools == null
        ? null
        : clientTools.values.map((tool) {
            final inputSchema = convertSchemaToJsonSchema(tool.inputSchema);
            final outputSchema = convertSchemaToJsonSchema(tool.outputSchema);
            return RealtimeToolConfig(
              name: tool.name,
              description: tool.description,
              inputSchema: inputSchema is Map
                  ? Map<String, dynamic>.from(inputSchema)
                  : null,
              outputSchema: outputSchema is Map
                  ? Map<String, dynamic>.from(outputSchema)
                  : null,
            );
          }).toList(growable: false);

    connection.updateSession(RealtimeSessionConfig(
      instructions: _instructions,
      voice: _voice,
      vadMode: _vadMode,
      tools: toolsConfig,
      outputModalities: _outputModalities,
      temperature: _temperature,
      maxOutputTokens: _maxOutputTokens,
      semanticEagerness: _semanticEagerness,
      providerOptions: _providerOptions,
    ));
  }

  String _generateId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    return 'msg-$now-${_randomSuffix()}';
  }

  static int _messageCounter = 0;

  String _randomSuffix() {
    _messageCounter++;
    return (_messageCounter.toRadixString(36) +
            DateTime.now().microsecondsSinceEpoch.toRadixString(36))
        .substring(0, 7);
  }
}
