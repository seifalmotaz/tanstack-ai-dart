import 'dart:async';

/// Ported from `packages/ai-client/src/byok/storage.ts`.

typedef Keyring = Map<String, String>;
typedef KeyPreview = Map<String, String>;

abstract class KeyringStorage {
  String get id;
  String get label;
  bool get persistent;
  bool get unlockable;
  String? get warning;
  FutureOr<KeyPreview> Function()? get peek;
  FutureOr<Keyring> load();
  FutureOr<void> save(Keyring keys);
  FutureOr<void> clear();
}

class MemoryKeyringStorage implements KeyringStorage {
  @override
  String get id => 'memory';

  @override
  String get label => 'Session only (not saved)';

  @override
  bool get persistent => false;

  @override
  bool get unlockable => false;

  @override
  String? get warning =>
      'Keys stay in memory for this tab only. They are not saved across reloads.';

  @override
  FutureOr<KeyPreview> Function()? get peek => null;

  @override
  FutureOr<Keyring> load() => <String, String>{};

  @override
  FutureOr<void> save(Keyring keys) {}

  @override
  FutureOr<void> clear() {}
}

KeyringStorage memoryStorage() => MemoryKeyringStorage();
