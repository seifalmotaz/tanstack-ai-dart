import 'dart:async';
import '../platform/persistence_types.dart';
import 'connection_transport.dart';
import 'types.dart';
import '../protocol.dart';

/// Adapt the original transcript-only callbacks to the combined store pipeline.
class LegacyChatPersistenceAdapter implements ChatClientPersistence {
  final ChatPersistence callbacks;
  LegacyChatPersistenceAdapter(this.callbacks);

  @override
  FutureOr<Object?> getItem(String id) {
    final value = callbacks.getItem?.call();
    if (value is Future<List<AssistantTurn>?>) {
      return value.then((turns) => turns == null
          ? null
          : ChatPersistedState(
              messages: assistantWireTurns(turns, includeActivity: true)));
    }
    return value == null
        ? null
        : ChatPersistedState(
            messages: assistantWireTurns(value, includeActivity: true));
  }

  @override
  FutureOr<void> setItem(String id, ChatPersistedState state) =>
      callbacks.setItem?.call(assistantTurnsFromProcessor(state.messages));

  @override
  FutureOr<void> removeItem(String id) => callbacks.removeItem?.call();
}
