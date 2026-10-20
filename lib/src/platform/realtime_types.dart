import 'tool_types.dart';

/// Ported from `packages/ai-client/src/realtime-types.ts` and the realtime
/// slice of `packages/ai/src/realtime/types.ts`.
///
/// State and configuration are typed. Usage and provider option bags stay
/// maps because they are provider-extensible protocol data.

const Object _unset = Object();

enum RealtimeStatus { idle, connecting, connected, reconnecting, error }

enum RealtimeMode { idle, listening, thinking, speaking }

class VadConfig {
  final double? threshold;
  final int? prefixPaddingMs;
  final int? silenceDurationMs;

  const VadConfig({
    this.threshold,
    this.prefixPaddingMs,
    this.silenceDurationMs,
  });

  Map<String, dynamic> toJson() => {
        if (threshold != null) 'threshold': threshold,
        if (prefixPaddingMs != null) 'prefixPaddingMs': prefixPaddingMs,
        if (silenceDurationMs != null) 'silenceDurationMs': silenceDurationMs,
      };
}

class RealtimeToolConfig {
  final String name;
  final String description;
  final Map<String, dynamic>? inputSchema;
  final Map<String, dynamic>? outputSchema;

  const RealtimeToolConfig({
    required this.name,
    this.description = '',
    this.inputSchema,
    this.outputSchema,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        if (inputSchema != null) 'inputSchema': inputSchema,
        if (outputSchema != null) 'outputSchema': outputSchema,
      };
}

class RealtimeSessionConfig {
  final String? model;
  final String? voice;
  final String? instructions;
  final List<RealtimeToolConfig>? tools;
  final String? vadMode;
  final VadConfig? vadConfig;
  final List<String>? outputModalities;
  final double? temperature;
  final Object? maxOutputTokens;
  final String? semanticEagerness;
  final Map<String, dynamic>? providerOptions;

  const RealtimeSessionConfig({
    this.model,
    this.voice,
    this.instructions,
    this.tools,
    this.vadMode,
    this.vadConfig,
    this.outputModalities,
    this.temperature,
    this.maxOutputTokens,
    this.semanticEagerness,
    this.providerOptions,
  });

  Map<String, dynamic> toJson() => {
        if (model != null) 'model': model,
        if (voice != null) 'voice': voice,
        if (instructions != null) 'instructions': instructions,
        if (tools != null)
          'tools': tools!.map((tool) => tool.toJson()).toList(),
        if (vadMode != null) 'vadMode': vadMode,
        if (vadConfig != null) 'vadConfig': vadConfig!.toJson(),
        if (outputModalities != null) 'outputModalities': outputModalities,
        if (temperature != null) 'temperature': temperature,
        if (maxOutputTokens != null) 'maxOutputTokens': maxOutputTokens,
        if (semanticEagerness != null) 'semanticEagerness': semanticEagerness,
        if (providerOptions != null) 'providerOptions': providerOptions,
      };
}

class RealtimeToken {
  final String provider;
  final String token;
  final int expiresAt;
  final RealtimeSessionConfig config;

  const RealtimeToken({
    required this.provider,
    required this.token,
    required this.expiresAt,
    this.config = const RealtimeSessionConfig(),
  });

  factory RealtimeToken.fromJson(Map<String, dynamic> json) => RealtimeToken(
        provider: '${json['provider'] ?? ''}',
        token: '${json['token'] ?? ''}',
        expiresAt: (json['expiresAt'] as num?)?.toInt() ?? 0,
        config: json['config'] is Map
            ? RealtimeSessionConfig()
            : const RealtimeSessionConfig(),
      );
}

abstract class RealtimeMessagePart {
  const RealtimeMessagePart();

  String get type;
  Map<String, dynamic> toJson();
}

class RealtimeTextPart extends RealtimeMessagePart {
  final String content;

  const RealtimeTextPart(this.content);

  @override
  String get type => 'text';

  @override
  Map<String, dynamic> toJson() => {'type': type, 'content': content};
}

class RealtimeAudioPart extends RealtimeMessagePart {
  final String transcript;
  final List<int>? audioData;
  final int? durationMs;

  const RealtimeAudioPart({
    required this.transcript,
    this.audioData,
    this.durationMs,
  });

  @override
  String get type => 'audio';

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'transcript': transcript,
        if (audioData != null) 'audioData': audioData,
        if (durationMs != null) 'durationMs': durationMs,
      };
}

class RealtimeToolCallPart extends RealtimeMessagePart {
  final String id;
  final String name;
  final String arguments;
  final Object? input;
  final Object? output;

  const RealtimeToolCallPart({
    required this.id,
    required this.name,
    this.arguments = '',
    this.input,
    this.output,
  });

  @override
  String get type => 'tool-call';

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'id': id,
        'name': name,
        'arguments': arguments,
        if (input != null) 'input': input,
        if (output != null) 'output': output,
      };
}

class RealtimeToolResultPart extends RealtimeMessagePart {
  final String toolCallId;
  final String content;

  const RealtimeToolResultPart({
    required this.toolCallId,
    required this.content,
  });

  @override
  String get type => 'tool-result';

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'toolCallId': toolCallId,
        'content': content,
      };
}

class RealtimeImagePart extends RealtimeMessagePart {
  final String data;
  final String mimeType;

  const RealtimeImagePart({required this.data, required this.mimeType});

  @override
  String get type => 'image';

  @override
  Map<String, dynamic> toJson() =>
      {'type': type, 'data': data, 'mimeType': mimeType};
}

class RealtimeMessage {
  final String id;
  final String role;
  final int timestamp;
  final List<RealtimeMessagePart> parts;
  final bool interrupted;
  final String? audioId;
  final int? durationMs;

  const RealtimeMessage({
    required this.id,
    required this.role,
    required this.timestamp,
    required this.parts,
    this.interrupted = false,
    this.audioId,
    this.durationMs,
  });

  RealtimeMessage copyWith({
    bool? interrupted,
    List<RealtimeMessagePart>? parts,
  }) =>
      RealtimeMessage(
        id: id,
        role: role,
        timestamp: timestamp,
        parts: parts ?? this.parts,
        interrupted: interrupted ?? this.interrupted,
        audioId: audioId,
        durationMs: durationMs,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'timestamp': timestamp,
        'parts': parts.map((part) => part.toJson()).toList(),
        if (interrupted) 'interrupted': interrupted,
        if (audioId != null) 'audioId': audioId,
        if (durationMs != null) 'durationMs': durationMs,
      };
}

abstract class AudioVisualization {
  double get inputLevel;
  double get outputLevel;
  List<int> getInputFrequencyData();
  List<int> getOutputFrequencyData();
  List<int> getInputTimeDomainData();
  List<int> getOutputTimeDomainData();
  int get inputSampleRate;
  int get outputSampleRate;
  void Function()? onInputAudio(
    void Function(List<double> samples, int sampleRate) callback,
  );
  void Function()? onOutputAudio(
    void Function(List<double> samples, int sampleRate) callback,
  );
}

enum RealtimeEvent {
  statusChange,
  modeChange,
  transcript,
  audioChunk,
  toolCall,
  messageComplete,
  interrupted,
  error,
  goAway,
  usage,
}

abstract class RealtimeEventPayload {
  const RealtimeEventPayload();
}

class RealtimeStatusChange extends RealtimeEventPayload {
  final RealtimeStatus status;
  const RealtimeStatusChange(this.status);
}

class RealtimeModeChange extends RealtimeEventPayload {
  final RealtimeMode mode;
  const RealtimeModeChange(this.mode);
}

class RealtimeTranscriptEvent extends RealtimeEventPayload {
  final String role;
  final String transcript;
  final bool isFinal;
  const RealtimeTranscriptEvent({
    required this.role,
    required this.transcript,
    required this.isFinal,
  });
}

class RealtimeAudioChunkEvent extends RealtimeEventPayload {
  final List<int> data;
  final int sampleRate;
  const RealtimeAudioChunkEvent({required this.data, required this.sampleRate});
}

class RealtimeToolCallEvent extends RealtimeEventPayload {
  final String? toolCallId;
  final String toolName;
  final Object? input;
  const RealtimeToolCallEvent({
    required this.toolCallId,
    required this.toolName,
    required this.input,
  });
}

class RealtimeMessageCompleteEvent extends RealtimeEventPayload {
  final RealtimeMessage message;
  const RealtimeMessageCompleteEvent(this.message);
}

class RealtimeInterruptedEvent extends RealtimeEventPayload {
  final String? messageId;
  const RealtimeInterruptedEvent(this.messageId);
}

class RealtimeErrorEvent extends RealtimeEventPayload {
  final Object error;
  const RealtimeErrorEvent(this.error);
}

class RealtimeGoAwayEvent extends RealtimeEventPayload {
  final String? timeLeft;
  const RealtimeGoAwayEvent(this.timeLeft);
}

class RealtimeUsageEvent extends RealtimeEventPayload {
  final Map<String, dynamic> usage;
  const RealtimeUsageEvent(this.usage);
}

class RealtimeClientOptions {
  final Future<RealtimeToken> Function() getToken;
  final RealtimeAdapter adapter;
  final List<ClientTool>? tools;
  final bool autoPlayback;
  final bool autoCapture;
  final String? instructions;
  final String? voice;
  final String vadMode;
  final List<String>? outputModalities;
  final double? temperature;
  final Object? maxOutputTokens;
  final String? semanticEagerness;
  final Map<String, dynamic>? providerOptions;

  final void Function(RealtimeStatus status)? onStatusChange;
  final void Function(RealtimeMode mode)? onModeChange;
  final void Function(RealtimeMessage message)? onMessage;
  final void Function(Object error)? onError;
  final void Function()? onConnect;
  final void Function()? onDisconnect;
  final void Function()? onInterrupted;
  final void Function(Map<String, dynamic> usage)? onUsage;
  final void Function(String? timeLeft)? onGoAway;

  RealtimeClientOptions({
    required this.getToken,
    required this.adapter,
    this.tools,
    this.autoPlayback = true,
    this.autoCapture = true,
    this.instructions,
    this.voice,
    this.vadMode = 'server',
    this.outputModalities,
    this.temperature,
    this.maxOutputTokens,
    this.semanticEagerness,
    this.providerOptions,
    this.onStatusChange,
    this.onModeChange,
    this.onMessage,
    this.onError,
    this.onConnect,
    this.onDisconnect,
    this.onInterrupted,
    this.onUsage,
    this.onGoAway,
  });
}

class RealtimeClientState {
  final RealtimeStatus status;
  final RealtimeMode mode;
  final List<RealtimeMessage> messages;
  final String? pendingUserTranscript;
  final String? pendingAssistantTranscript;
  final Object? error;

  const RealtimeClientState({
    this.status = RealtimeStatus.idle,
    this.mode = RealtimeMode.idle,
    this.messages = const <RealtimeMessage>[],
    this.pendingUserTranscript,
    this.pendingAssistantTranscript,
    this.error,
  });

  RealtimeClientState copyWith({
    RealtimeStatus? status,
    RealtimeMode? mode,
    List<RealtimeMessage>? messages,
    Object? pendingUserTranscript = _unset,
    Object? pendingAssistantTranscript = _unset,
    Object? error = _unset,
  }) =>
      RealtimeClientState(
        status: status ?? this.status,
        mode: mode ?? this.mode,
        messages: messages ?? this.messages,
        pendingUserTranscript: identical(pendingUserTranscript, _unset)
            ? this.pendingUserTranscript
            : pendingUserTranscript as String?,
        pendingAssistantTranscript:
            identical(pendingAssistantTranscript, _unset)
                ? this.pendingAssistantTranscript
                : pendingAssistantTranscript as String?,
        error: identical(error, _unset) ? this.error : error,
      );
}

typedef RealtimeStateChangeCallback = void Function(RealtimeClientState state);

abstract class RealtimeAdapter {
  String get provider;
  Future<RealtimeConnection> connect(
    RealtimeToken token, [
    List<ClientTool>? clientTools,
  ]);
}

abstract class RealtimeConnection {
  Future<void> disconnect();
  Future<void> startAudioCapture();
  void stopAudioCapture();
  void sendText(String text);
  void sendImage(String imageData, String mimeType);
  void sendToolResult(String callId, String result);
  void updateSession(RealtimeSessionConfig config);
  void updateToken(RealtimeToken token);
  void interrupt();
  void Function() on(
    RealtimeEvent event,
    void Function(RealtimeEventPayload payload) handler,
  );
  AudioVisualization getAudioVisualization();
}
