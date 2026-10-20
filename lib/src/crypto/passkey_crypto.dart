import '../platform/byok/passkey.dart' as platform;
import 'keyring_crypto.dart' as core;

/// Cryptographic implementation for a host's passkey ceremony and record store.
class DartPasskeyCrypto implements platform.PasskeyCrypto {
  const DartPasskeyCrypto();

  @override
  Future<Object> deriveAesKey(List<int> prfOutput) =>
      core.deriveAesKey(prfOutput);

  @override
  Future<platform.EncryptedKeyring> encryptKeyring(
    Object key,
    Map<String, String> keys,
  ) async {
    final encrypted = await core.encryptKeyring(_key(key), keys);
    return platform.EncryptedKeyring(
      iv: encrypted.iv,
      ciphertext: encrypted.ciphertext,
    );
  }

  @override
  Future<Map<String, String>> decryptKeyring(
    Object key,
    List<int> iv,
    List<int> ciphertext,
  ) =>
      core.decryptKeyring(_key(key), iv, ciphertext);

  core.KeyringEncryptionKey _key(Object value) {
    if (value is! core.KeyringEncryptionKey) {
      throw ArgumentError('Expected a key derived by DartPasskeyCrypto');
    }
    return value;
  }
}
