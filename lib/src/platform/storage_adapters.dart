import 'dart:async';
import 'dart:convert';

import 'message_date_normalizer.dart';
import 'persistence_types.dart';

/// Ported from `packages/ai-client/src/storage-adapters.ts`.
///
/// `localStorage`, `sessionStorage`, and IndexedDB are browser-only. The
/// adapters below never silently substitute an in-memory store: the host must
/// inject a [WebStorageProvider] / [IndexedDbProvider]. When it does not, each
/// operation throws or rejects with [StorageUnavailableError]. This is the
/// explicit pure-Dart "unavailable platform capability" contract.

class StorageUnavailableError extends Error {
  final String storageName;
  final String message;

  StorageUnavailableError(this.storageName)
      : message = '$storageName is not available in this environment.';

  @override
  String toString() => 'StorageUnavailableError: $message';
}

class WebStoragePersistenceOptions {
  final String keyPrefix;
  final String Function(ChatPersistedState value)? serialize;
  final ChatPersistedState Function(String value)? deserialize;

  const WebStoragePersistenceOptions({
    this.keyPrefix = 'tanstack-ai:',
    this.serialize,
    this.deserialize,
  });
}

class IndexedDBPersistenceOptions {
  final String databaseName;
  final String objectStoreName;
  final String keyPrefix;

  const IndexedDBPersistenceOptions({
    this.databaseName = 'tanstack-ai',
    this.objectStoreName = 'persistence',
    this.keyPrefix = 'tanstack-ai:',
  });
}

/// Synchronous web storage surface (`localStorage` / `sessionStorage`).
abstract class WebStorage {
  String? getItem(String key);
  void setItem(String key, String value);
  void removeItem(String key);
}

abstract class WebStorageProvider {
  WebStorage? get localStorage;
  WebStorage? get sessionStorage;
}

class _NoWebStorageProvider implements WebStorageProvider {
  const _NoWebStorageProvider();

  @override
  WebStorage? get localStorage => null;

  @override
  WebStorage? get sessionStorage => null;
}

/// Async IndexedDB surface. Hosts provide a browser-backed implementation.
abstract class IndexedDbStorage {
  Future<Object?> get(String key);
  Future<void> put(String key, Object? value);
  Future<void> delete(String key);
}

abstract class IndexedDbProvider {
  IndexedDbStorage? open({
    required String databaseName,
    required String objectStoreName,
  });
}

class _NoIndexedDbProvider implements IndexedDbProvider {
  const _NoIndexedDbProvider();

  @override
  IndexedDbStorage? open({
    required String databaseName,
    required String objectStoreName,
  }) =>
      null;
}

Object? _jsonSafe(Object? value) {
  if (value is DateTime) return value.toIso8601String();
  if (value is Map) {
    return {
      for (final entry in value.entries) '${entry.key}': _jsonSafe(entry.value),
    };
  }
  if (value is List) return value.map(_jsonSafe).toList(growable: false);
  return value;
}

String _stringifyJson(ChatPersistedState value) {
  final serialized = jsonEncode(_jsonSafe(value.toJson()));
  return serialized;
}

ChatPersistedState _revivePersistedState(ChatPersistedState state) {
  return ChatPersistedState(
    messages: normalizeMessagesDates(state.messages),
    resume: state.resume,
  );
}

ChatStorageAdapter _createWebStoragePersistence(
  String storageName, {
  required WebStorage? Function() getStorage,
  WebStoragePersistenceOptions options = const WebStoragePersistenceOptions(),
}) {
  final serialize = options.serialize ?? _stringifyJson;
  final deserialize = options.deserialize ??
      (value) => ChatPersistedState.fromJson(
            Map<String, dynamic>.from(jsonDecode(value) as Map),
          );
  String key(String id) => '${options.keyPrefix}$id';

  WebStorage requireStorage() {
    final storage = getStorage();
    if (storage == null) throw StorageUnavailableError(storageName);
    return storage;
  }

  return _ChatStorageAdapter(
    getItem: (id) {
      final item = requireStorage().getItem(key(id));
      return item == null ? null : _revivePersistedState(deserialize(item));
    },
    setItem: (id, value) => requireStorage().setItem(key(id), serialize(value)),
    removeItem: (id) => requireStorage().removeItem(key(id)),
  );
}

class _ChatStorageAdapter implements ChatStorageAdapter {
  final FutureOr<ChatPersistedState?> Function(String id) _getItem;
  final FutureOr<void> Function(String id, ChatPersistedState value) _setItem;
  final FutureOr<void> Function(String id) _removeItem;

  _ChatStorageAdapter({
    required FutureOr<ChatPersistedState?> Function(String id) getItem,
    required FutureOr<void> Function(String id, ChatPersistedState value)
        setItem,
    required FutureOr<void> Function(String id) removeItem,
  })  : _getItem = getItem,
        _setItem = setItem,
        _removeItem = removeItem;

  @override
  FutureOr<ChatPersistedState?> getItem(String id) => _getItem(id);

  @override
  FutureOr<void> setItem(String id, ChatPersistedState value) =>
      _setItem(id, value);

  @override
  FutureOr<void> removeItem(String id) => _removeItem(id);
}

ChatStorageAdapter localStoragePersistence({
  WebStoragePersistenceOptions options = const WebStoragePersistenceOptions(),
  WebStorageProvider provider = const _NoWebStorageProvider(),
}) =>
    _createWebStoragePersistence(
      'localStorage',
      getStorage: () => provider.localStorage,
      options: options,
    );

ChatStorageAdapter sessionStoragePersistence({
  WebStoragePersistenceOptions options = const WebStoragePersistenceOptions(),
  WebStorageProvider provider = const _NoWebStorageProvider(),
}) =>
    _createWebStoragePersistence(
      'sessionStorage',
      getStorage: () => provider.sessionStorage,
      options: options,
    );

ChatStorageAdapter indexedDBPersistence({
  IndexedDBPersistenceOptions options = const IndexedDBPersistenceOptions(),
  IndexedDbProvider provider = const _NoIndexedDbProvider(),
}) {
  String key(String id) => '${options.keyPrefix}$id';

  IndexedDbStorage requireStorage() {
    final storage = provider.open(
      databaseName: options.databaseName,
      objectStoreName: options.objectStoreName,
    );
    if (storage == null) throw StorageUnavailableError('indexedDB');
    return storage;
  }

  return _ChatStorageAdapter(
    getItem: (id) async {
      final raw = await requireStorage().get(key(id));
      if (raw is ChatPersistedState) return _revivePersistedState(raw);
      if (raw is Map) {
        return _revivePersistedState(
          ChatPersistedState.fromJson(Map<String, dynamic>.from(raw)),
        );
      }
      return null;
    },
    setItem: (id, value) => requireStorage().put(key(id), value.toJson()),
    removeItem: (id) => requireStorage().delete(key(id)),
  );
}
