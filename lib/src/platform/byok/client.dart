import 'dart:async';

import '../snapshot_atom.dart';
import 'errors.dart';
import 'providers.dart';
import 'storage.dart';

/// Ported from `packages/ai-client/src/byok/client.ts`.

enum KeyStatusState { empty, set, locked, error }

class KeyStatus {
  final KeyStatusState state;
  final String? masked;
  final String? message;

  const KeyStatus({required this.state, this.masked, this.message});

  Map<String, dynamic> toJson() => {
        'state': state.name,
        if (masked != null) 'masked': masked,
        if (message != null) 'message': message,
      };
}

class ByokPrompt {
  final String provider;
  final String reason;

  const ByokPrompt({required this.provider, required this.reason});
}

class ByokSnapshot {
  final Map<String, KeyStatus> status;
  final bool locked;
  final ByokPrompt? prompt;
  final String? storageError;

  const ByokSnapshot({
    required this.status,
    required this.locked,
    this.prompt,
    this.storageError,
  });
}

const ByokSnapshot emptyByokSnapshot = ByokSnapshot(
  status: <String, KeyStatus>{},
  locked: false,
);

/// Upstream constant spelling for the initial empty keyring snapshot.
// ignore: constant_identifier_names
const EMPTY_BYOK_SNAPSHOT = emptyByokSnapshot;

class DefineByokOptions {
  final KeyringStorage? storage;
  final List<ByokProvider>? providers;

  const DefineByokOptions({this.storage, this.providers});
}

final Expando<List<String>> _registeredProviderIds =
    Expando<List<String>>('registeredByokProviderIds');

String? byokFallbackProviderId(ByokClient byok) {
  final savedIds = byok
      .keys()
      .entries
      .where((entry) => entry.value.isNotEmpty)
      .map((entry) => entry.key)
      .where(isProviderId)
      .toList();
  if (savedIds.length == 1) return savedIds.first;
  final registered = _registeredProviderIds[byok] ?? const <String>[];
  if (registered.length == 1) return registered.first;
  return null;
}

String _requireProviderId(String value) {
  if (!isProviderId(value)) {
    throw ArgumentError('Invalid BYOK provider id: $value');
  }
  return value;
}

String _errorMessage(Object? error, String fallback) =>
    error is Error || error is Exception
        ? error.toString().replaceFirst(RegExp(r'^[^:]+:\s*'), '')
        : fallback;

bool _isByokCeremonyCancel(Object? error) {
  if (error == null) return false;
  final text = error.toString().toLowerCase();
  final type = error.runtimeType.toString();
  if (type == 'NotAllowedError' || type.contains('NotAllowedError')) {
    return true;
  }
  return text.contains('cancelled') ||
      text.contains('canceled') ||
      text.contains('not allowed');
}

Keyring _sanitizeKeyring(Object? value) {
  if (value is! Map) return <String, String>{};
  final keys = <String, String>{};
  for (final entry in value.entries) {
    final provider = entry.key;
    final key = entry.value;
    if (isProviderId(provider) && key is String && key.isNotEmpty) {
      keys['$provider'] = key;
    }
  }
  return keys;
}

class ByokClient {
  final KeyringStorage storage;

  Keyring _keys = <String, String>{};
  Map<String, KeyStatus> _statuses = <String, KeyStatus>{};
  late bool _locked;
  ByokPrompt? _prompt;
  bool _coverageAll = false;
  Map<String, bool> _coverage = <String, bool>{};
  final Map<String, List<String>> _companions = <String, List<String>>{};
  String? _storageError;
  late ByokSnapshot _snapshot;
  final Set<void Function()> _listeners = <void Function()>{};
  late final Future<void> _ready;

  ByokClient([DefineByokOptions options = const DefineByokOptions()])
      : storage = options.storage ?? memoryStorage() {
    final registered = <String>[];
    for (final provider in options.providers ?? const <ByokProvider>[]) {
      final id = _requireProviderId(provider.id);
      registered.add(id);
      final companions = provider.withCompanions;
      if (companions.isNotEmpty) {
        _companions[id] = companions
            .map((companion) => _requireProviderId(companion.id))
            .toList();
      }
    }
    _registeredProviderIds[this] = registered;
    _locked = storage.unlockable;
    _snapshot = _buildSnapshot();
    _ready = _hydrate();
  }

  Future<void> ready() => _ready;

  void Function() subscribe(void Function() listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  ByokSnapshot getSnapshot() => _snapshot;

  ByokSnapshot _buildSnapshot() => ByokSnapshot(
        status: Map<String, KeyStatus>.unmodifiable(_statuses),
        locked: _locked,
        prompt: _prompt,
        storageError: _storageError,
      );

  Keyring keys() => Map<String, String>.of(_keys);

  void request(String provider, String reason) {
    _prompt = ByokPrompt(
      provider: _requireProviderId(provider),
      reason: reason,
    );
    _emit();
  }

  void setServerCoverage(Object flags) {
    if (flags is bool) {
      _coverageAll = flags;
      _coverage = <String, bool>{};
      return;
    }
    if (flags is Map) {
      _coverageAll = false;
      _coverage = {
        ..._coverage,
        for (final entry in flags.entries)
          if (entry.key is String && entry.value is bool)
            entry.key as String: entry.value as bool,
      };
    }
  }

  bool _hasCoverage(String provider) =>
      _coverageAll || _coverage[provider] == true;

  List<String> _expand(String provider) =>
      <String>[provider, ...?_companions[provider]];

  Map<String, String> headers([String? provider]) {
    final headers = <String, String>{};
    if (provider != null) {
      _requireProviderId(provider);
      for (final id in _expand(provider)) {
        final key = _keys[id];
        if (key != null && key.isNotEmpty) headers[byokHeaderName(id)] = key;
      }
      return headers;
    }
    for (final entry in _keys.entries) {
      if (entry.value.isNotEmpty) {
        headers[byokHeaderName(entry.key)] = entry.value;
      }
    }
    return headers;
  }

  Future<void> prepare([String? provider]) async {
    await _ready;
    if (storage.unlockable && _locked) {
      await unlock();
    }
    if (provider == null) return;
    _requireProviderId(provider);
    for (final id in _expand(provider)) {
      if ((_keys[id] ?? '').isNotEmpty || _hasCoverage(id)) continue;
      request(id, 'missing');
      throw ByokBlockedError(id, 'missing');
    }
  }

  Future<void> update(String providerOrKey, [String? key]) async {
    await _ready;
    late String provider;
    late String nextKey;
    if (key == null) {
      final prompt = _prompt;
      if (prompt == null) {
        throw StateError('byok.update(key) cannot run when prompt is null');
      }
      provider = prompt.provider;
      nextKey = providerOrKey;
    } else {
      provider = _requireProviderId(providerOrKey);
      nextKey = key;
    }
    nextKey = nextKey.trim();
    if (nextKey.isEmpty) {
      throw ArgumentError('BYOK key must be non-empty');
    }
    if (storage.unlockable && _locked) {
      await unlock();
    }
    final previousKeys = _keys;
    final previousStatuses = Map<String, KeyStatus>.of(_statuses);
    final previousLocked = _locked;
    final previousPrompt = _prompt;
    final previousStorageError = _storageError;
    final next = <String, String>{..._keys, provider: nextKey};
    try {
      await storage.save(next);
    } catch (error) {
      _keys = previousKeys;
      _statuses = previousStatuses;
      _locked = previousLocked;
      _prompt = previousPrompt;
      _storageError = previousStorageError;
      _statuses = {
        ..._statuses,
        provider: KeyStatus(
          state: KeyStatusState.error,
          masked: maskKey(nextKey),
          message: _errorMessage(error, 'Failed to persist $provider key'),
        ),
      };
      _emit();
      rethrow;
    }
    _keys = next;
    _statuses = {
      ..._statuses,
      provider: KeyStatus(state: KeyStatusState.set, masked: maskKey(nextKey)),
    };
    _locked = false;
    _prompt = null;
    _storageError = null;
    _emit();
  }

  Future<void> clear([String? provider]) async {
    await _ready;
    if (provider != null) {
      _requireProviderId(provider);
      if (storage.unlockable && _locked) {
        await unlock();
      }
      final previousKeys = _keys;
      final previousStatuses = Map<String, KeyStatus>.of(_statuses);
      final next = Map<String, String>.of(_keys)..remove(provider);
      try {
        await storage.save(next);
      } catch (error) {
        _keys = previousKeys;
        _statuses = previousStatuses;
        _emit();
        rethrow;
      }
      _keys = next;
      _statuses = Map<String, KeyStatus>.of(_statuses)..remove(provider);
      _emit();
      return;
    }
    final previousKeys = _keys;
    final previousStatuses = _statuses;
    final previousLocked = _locked;
    final previousPrompt = _prompt;
    try {
      await storage.clear();
    } catch (error) {
      _keys = previousKeys;
      _statuses = previousStatuses;
      _locked = previousLocked;
      _prompt = previousPrompt;
      _emit();
      rethrow;
    }
    _keys = <String, String>{};
    _statuses = <String, KeyStatus>{};
    _locked = false;
    _prompt = null;
    _storageError = null;
    _emit();
  }

  Future<void> unlock() async {
    await _ready;
    if (!storage.unlockable) return;
    try {
      final loaded = _sanitizeKeyring(await storage.load());
      _keys = <String, String>{...loaded, ..._keys};
      for (final entry in loaded.entries) {
        if (!isProviderId(entry.key) || entry.value.isEmpty) continue;
        final existing = _statuses[entry.key];
        if (existing == null || existing.state == KeyStatusState.locked) {
          _statuses[entry.key] = KeyStatus(
            state: KeyStatusState.set,
            masked: maskKey(entry.value),
          );
        }
      }
      _locked = false;
      _storageError = null;
      _emit();
    } catch (error) {
      if (_isByokCeremonyCancel(error)) {
        final provider = _lockedProvider();
        if (provider != null) {
          request(provider, 'locked');
          throw ByokBlockedError(provider, 'locked');
        }
      }
      _storageError = _errorMessage(error, 'Failed to unlock keyring');
      _emit();
      if (error is Exception) rethrow;
      throw Exception(error);
    }
  }

  String? _lockedProvider() {
    final prompt = _prompt;
    if (prompt != null && isProviderId(prompt.provider)) return prompt.provider;
    for (final entry in _statuses.entries) {
      if (entry.value.state == KeyStatusState.locked &&
          isProviderId(entry.key)) {
        return entry.key;
      }
    }
    return null;
  }

  Future<void> _hydrate() async {
    if (storage.unlockable) {
      final peek = storage.peek;
      if (peek == null) return;
      try {
        final preview = await peek();
        for (final entry in preview.entries) {
          if (!isProviderId(entry.key) || _statuses.containsKey(entry.key)) {
            continue;
          }
          _statuses[entry.key] = KeyStatus(
            state: KeyStatusState.locked,
            masked: entry.value.isNotEmpty ? entry.value : '••',
          );
        }
        _locked = preview.isNotEmpty;
        _storageError = null;
        _emit();
      } catch (error) {
        _storageError = _errorMessage(error, 'Failed to read keyring');
        _emit();
      }
      return;
    }
    try {
      final loaded = _sanitizeKeyring(await storage.load());
      _keys = <String, String>{...loaded, ..._keys};
      for (final entry in loaded.entries) {
        if (!isProviderId(entry.key) || entry.value.isEmpty) continue;
        _statuses[entry.key] = KeyStatus(
          state: KeyStatusState.set,
          masked: maskKey(entry.value),
        );
      }
      _storageError = null;
      _emit();
    } catch (error) {
      _storageError = _errorMessage(error, 'Failed to read keyring');
      _emit();
    }
  }

  void _emit() {
    _snapshot = _buildSnapshot();
    notifyListeners(_listeners);
  }
}

ByokClient defineByok(
        [DefineByokOptions options = const DefineByokOptions()]) =>
    ByokClient(options);
