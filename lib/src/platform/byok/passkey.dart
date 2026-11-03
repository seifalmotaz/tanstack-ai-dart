import 'dart:async';
import 'dart:math' as math;

import '../../crypto/passkey_crypto.dart' as dart_crypto;
import 'providers.dart';
import 'storage.dart';

export '../../crypto/passkey_crypto.dart' show DartPasskeyCrypto;

/// Ported from `packages/ai-client/src/byok/passkey.ts`.
///
/// WebAuthn PRF, HKDF, AES-256-GCM, and IndexedDB are native capabilities.
/// Dart implements the HKDF/AES-256-GCM keyring crypto in
/// `lib/src/crypto/keyring_crypto.dart` and exposes it as
/// [DartPasskeyCrypto], the default for [PasskeyCrypto]. A host still injects a
/// [PasskeyPlatform] for the WebAuthn ceremony and record store; without one,
/// `isPasskeyStorageSupported()` is `false`, `defaultByokStorage()` falls back
/// to memory, and explicit `passkeyStorage()` operations throw
/// [UnsupportedError].

const String _hkdfInfo = 'byok:keyring:v1';

class StoredKeyringRecord {
  final List<int> credentialId;
  final List<int> salt;
  final List<int> iv;
  final List<int> ciphertext;
  final KeyPreview preview;

  const StoredKeyringRecord({
    required this.credentialId,
    required this.salt,
    required this.iv,
    required this.ciphertext,
    required this.preview,
  });
}

class PasskeyRegistration {
  final List<int> credentialId;
  final List<int> salt;
  final List<int>? prf;
  final bool prfEnabled;

  const PasskeyRegistration({
    required this.credentialId,
    required this.salt,
    this.prf,
    this.prfEnabled = false,
  });
}

class EncryptedKeyring {
  final List<int> iv;
  final List<int> ciphertext;

  const EncryptedKeyring({required this.iv, required this.ciphertext});
}

/// Keyring cryptography contract. [DartPasskeyCrypto] is the real default;
/// hosts may override it for a platform-backed implementation.
abstract class PasskeyCrypto {
  Future<Object> deriveAesKey(List<int> prfOutput);
  Future<EncryptedKeyring> encryptKeyring(Object key, Keyring keys);
  Future<Keyring> decryptKeyring(
    Object key,
    List<int> iv,
    List<int> ciphertext,
  );
}

abstract class PasskeyRecordStore {
  Future<StoredKeyringRecord?> get();
  Future<void> put(StoredKeyringRecord record);
  Future<void> clear();
}

/// Host seam for the WebAuthn ceremony and encrypted record store.
///
/// Extend this class (rather than only implementing it) to inherit [crypto]'s
/// real [DartPasskeyCrypto] default. A class that uses `implements` must supply
/// [crypto] explicitly because Dart does not inherit interface defaults.
abstract class PasskeyPlatform {
  bool get isSupported;

  /// `null` means "cannot tell"; treated as secure, matching upstream.
  bool? get isSecureContext;

  /// `null` means the environment does not expose user-activation state.
  bool? get userActivationIsActive;

  Future<PasskeyRegistration> register({
    required String rpName,
    required String userName,
    String? rpId,
    required List<int> salt,
  });

  Future<List<int>> evaluatePrf(
    List<int> credentialId,
    List<int> salt,
  );

  /// Hosts may override this, but the real Dart HKDF/AES-GCM implementation is
  /// the default so only the WebAuthn ceremony and record store are required.
  PasskeyCrypto get crypto => const dart_crypto.DartPasskeyCrypto();

  PasskeyRecordStore get store;
}

class PasskeyStorageOptions {
  final String rpName;
  final String userName;
  final String? rpId;

  const PasskeyStorageOptions({
    this.rpName = 'BYOK',
    this.userName = 'byok-keyring',
    this.rpId,
  });
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

KeyPreview _previewOf(Keyring keys) {
  final preview = <String, String>{};
  for (final entry in keys.entries) {
    if (entry.value.isEmpty || !isProviderId(entry.key)) continue;
    preview[entry.key] = entry.value.length > 4
        ? entry.value.substring(entry.value.length - 4)
        : '';
  }
  return preview;
}

bool isPasskeyStorageSupported([PasskeyPlatform? platform]) =>
    platform?.isSupported ?? false;

List<int> _validatedPrfBytes(Object prfOutput) {
  if (prfOutput is! List ||
      prfOutput.length != 32 ||
      prfOutput.any(
        (byte) => byte is! int || byte < 0 || byte > 255,
      )) {
    throw StateError('Invalid passkey PRF byte array');
  }
  return prfOutput.cast<int>();
}

Future<Object> deriveAesKey(
  Object prfOutput, {
  PasskeyCrypto? crypto,
}) =>
    (crypto ?? const dart_crypto.DartPasskeyCrypto())
        .deriveAesKey(_validatedPrfBytes(prfOutput));

Future<EncryptedKeyring> encryptKeyring(
  Object key,
  Keyring keys, {
  PasskeyCrypto? crypto,
}) =>
    (crypto ?? const dart_crypto.DartPasskeyCrypto()).encryptKeyring(key, keys);

Future<Keyring> decryptKeyring(
  Object key,
  List<int> iv,
  List<int> ciphertext, {
  PasskeyCrypto? crypto,
}) async =>
    _sanitizeKeyring(
      await (crypto ?? const dart_crypto.DartPasskeyCrypto())
          .decryptKeyring(key, iv, ciphertext),
    );

class PasskeyKeyringStorage implements KeyringStorage {
  final PasskeyPlatform? platform;
  final PasskeyStorageOptions options;

  Object? _cachedKey;
  List<int>? _cachedCredentialId;
  List<int>? _cachedSalt;

  PasskeyKeyringStorage(this.platform, this.options);

  PasskeyPlatform get _requirePlatform {
    final value = platform;
    if (value == null) {
      throw UnsupportedError(
        'Passkey storage needs a host PasskeyPlatform for the WebAuthn '
        'ceremony and IndexedDB record store.',
      );
    }
    return value;
  }

  @override
  String get id => 'passkey';

  @override
  String get label => 'Passkey-encrypted (this device)';

  @override
  bool get persistent => true;

  @override
  bool get unlockable => true;

  @override
  String? get warning =>
      'Keys are encrypted with your passkey and unlocked with biometrics. '
      'This protects saved keys if your device is stolen, but not against code '
      'running on this page after you unlock.';

  void _requireUserActivation(String action) {
    final isActive = _requirePlatform.userActivationIsActive;
    if (isActive == false) {
      throw StateError(
        'Passkey $action needs a fresh user action (e.g. a click). Run it '
        'directly from the event handler, before awaiting other work.',
      );
    }
  }

  Future<Map<String, Object>> _ensureKey() async {
    final platform = _requirePlatform;
    final cachedKey = _cachedKey;
    final cachedCredentialId = _cachedCredentialId;
    final cachedSalt = _cachedSalt;
    if (cachedKey != null && cachedCredentialId != null && cachedSalt != null) {
      return {
        'key': cachedKey,
        'credentialId': cachedCredentialId,
        'salt': cachedSalt,
      };
    }

    final existing = await platform.store.get();
    late Object key;
    late List<int> credentialId;
    late List<int> salt;
    if (existing != null) {
      _requireUserActivation('unlock');
      final prf = await platform.evaluatePrf(
        existing.credentialId,
        existing.salt,
      );
      key = await deriveAesKey(prf, crypto: platform.crypto);
      credentialId = existing.credentialId;
      salt = existing.salt;
    } else {
      final random = math.Random.secure();
      final saltBytes =
          List<int>.generate(32, (_) => random.nextInt(256), growable: false);
      final registration = await platform.register(
        rpName: options.rpName,
        userName: options.userName,
        rpId: options.rpId,
        salt: saltBytes,
      );
      if (!registration.prfEnabled) {
        throw StateError(
          'This authenticator does not support the WebAuthn PRF extension',
        );
      }
      final prf = registration.prf ??
          await platform.evaluatePrf(
            registration.credentialId,
            registration.salt,
          );
      key = await deriveAesKey(prf, crypto: platform.crypto);
      credentialId = registration.credentialId;
      salt = registration.salt;
    }
    _cachedKey = key;
    _cachedCredentialId = credentialId;
    _cachedSalt = salt;
    return {'key': key, 'credentialId': credentialId, 'salt': salt};
  }

  @override
  FutureOr<KeyPreview> Function()? get peek => () async {
        if (platform == null) {
          throw UnsupportedError(
            'Passkey preview is unavailable without a PasskeyPlatform.',
          );
        }
        final existing = await platform!.store.get();
        return existing?.preview ?? <String, String>{};
      };

  @override
  Future<Keyring> load() async {
    final platform = _requirePlatform;
    final existing = await platform.store.get();
    if (existing == null) return <String, String>{};
    final key = (await _ensureKey())['key']!;
    return decryptKeyring(
      key,
      existing.iv,
      existing.ciphertext,
      crypto: platform.crypto,
    );
  }

  @override
  Future<void> save(Keyring keys) async {
    final platform = _requirePlatform;
    final existing = await platform.store.get();
    final hasKeys = keys.values.any((value) => value.isNotEmpty);
    if (!hasKeys && existing == null) return;

    final meta = await _ensureKey();
    final key = meta['key']!;
    final credentialId = (meta['credentialId']! as List).cast<int>();
    final salt = (meta['salt']! as List).cast<int>();
    final encrypted = await encryptKeyring(
      key,
      keys,
      crypto: platform.crypto,
    );
    await platform.store.put(StoredKeyringRecord(
      credentialId: credentialId,
      salt: salt,
      iv: encrypted.iv,
      ciphertext: encrypted.ciphertext,
      preview: _previewOf(keys),
    ));
  }

  @override
  Future<void> clear() async {
    clearCache();
    await _requirePlatform.store.clear();
  }

  void clearCache() {
    _cachedKey = null;
    _cachedCredentialId = null;
    _cachedSalt = null;
  }
}

KeyringStorage passkeyStorage(
  PasskeyPlatform? platform, [
  PasskeyStorageOptions options = const PasskeyStorageOptions(),
]) =>
    PasskeyKeyringStorage(platform, options);

/// Passkey-encrypted storage when WebAuthn is available in a secure context.
/// Otherwise session memory with a warning. This is not an automatic PRF
/// fallback: a host that injects a platform still gets the PRF error on first
/// save if the authenticator lacks the extension.
KeyringStorage defaultByokStorage({
  PasskeyPlatform? platform,
  PasskeyStorageOptions options = const PasskeyStorageOptions(),
}) {
  final secure = platform?.isSecureContext ?? true;
  if (!isPasskeyStorageSupported(platform) || !secure) {
    return _MemoryByokStorage(
      warning:
          'Passkeys are unavailable in this context. Keys stay in memory for '
          'this tab only.',
    );
  }
  return passkeyStorage(platform, options);
}

class _MemoryByokStorage implements KeyringStorage {
  @override
  final String? warning;

  _MemoryByokStorage({this.warning});

  @override
  String get id => 'memory';

  @override
  String get label => 'Session only (not saved)';

  @override
  bool get persistent => false;

  @override
  bool get unlockable => false;

  @override
  FutureOr<KeyPreview> Function()? get peek => null;

  @override
  FutureOr<Keyring> load() => <String, String>{};

  @override
  FutureOr<void> save(Keyring keys) {}

  @override
  FutureOr<void> clear() {}
}

// Referenced in documentation/tests; upstream HKDF info string is retained so
// a browser crypto adapter can use the exact same derivation.
String get byokHkdfInfo => _hkdfInfo;
