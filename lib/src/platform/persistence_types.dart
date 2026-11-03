import 'dart:async';

/// Ported from `packages/ai-client/src/types.ts` persistence slice.
///
/// Message transcripts use JSON-compatible maps because UIMessage parts are an
/// extensible protocol union. Configuration/state containers are typed.

class ChatResumeState {
  final String threadId;
  final String runId;

  const ChatResumeState({required this.threadId, required this.runId});

  factory ChatResumeState.fromJson(Map<String, dynamic> json) =>
      ChatResumeState(
        threadId: '${json['threadId'] ?? ''}',
        runId: '${json['runId'] ?? ''}',
      );

  Map<String, dynamic> toJson() => {'threadId': threadId, 'runId': runId};
}

class ChatResumeSnapshot {
  final ChatResumeState resumeState;
  final List<Map<String, dynamic>> pendingInterrupts;

  const ChatResumeSnapshot({
    required this.resumeState,
    this.pendingInterrupts = const <Map<String, dynamic>>[],
  });

  factory ChatResumeSnapshot.fromJson(Map<String, dynamic> json) =>
      ChatResumeSnapshot(
        resumeState: ChatResumeState.fromJson(
          Map<String, dynamic>.from(
            json['resumeState'] as Map? ?? const <String, dynamic>{},
          ),
        ),
        pendingInterrupts: (json['pendingInterrupts'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(growable: false),
      );

  Map<String, dynamic> toJson() => {
        'resumeState': resumeState.toJson(),
        if (pendingInterrupts.isNotEmpty)
          'pendingInterrupts': pendingInterrupts,
      };
}

/// The single record a [ChatClientPersistence] adapter stores per chat.
class ChatPersistedState {
  final List<Map<String, dynamic>> messages;
  final ChatResumeSnapshot? resume;

  ChatPersistedState({required this.messages, this.resume});

  factory ChatPersistedState.fromJson(Map<String, dynamic> json) =>
      ChatPersistedState(
        messages: (json['messages'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(growable: false),
        resume: json['resume'] is Map
            ? ChatResumeSnapshot.fromJson(
                Map<String, dynamic>.from(json['resume'] as Map),
              )
            : null,
      );

  Map<String, dynamic> toJson() => {
        'messages': messages,
        if (resume != null) 'resume': resume!.toJson(),
      };
}

/// Generic persistence adapter. `getItem` is [FutureOr] so sync web storage and
/// async IndexedDB share one contract. Legacy bare message arrays are accepted
/// by `ChatPersistor` normalization.
abstract class ChatClientPersistence {
  FutureOr<Object?> getItem(String id);
  FutureOr<void> setItem(String id, ChatPersistedState state);
  FutureOr<void> removeItem(String id);
}

/// Typed storage adapter for a single chat record.
abstract class ChatStorageAdapter implements ChatClientPersistence {
  @override
  FutureOr<ChatPersistedState?> getItem(String id);
  @override
  FutureOr<void> setItem(String id, ChatPersistedState value);
  @override
  FutureOr<void> removeItem(String id);
}
