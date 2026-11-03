import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Opaque key derived from a user-present passkey PRF ceremony.
final class KeyringEncryptionKey {
  final SecretKey _key;
  KeyringEncryptionKey._(this._key);
}

/// WebCrypto-compatible AES-GCM ciphertext, including its 128-bit tag.
final class EncryptedKeyring {
  final Uint8List iv;
  final Uint8List ciphertext;

  EncryptedKeyring({required List<int> iv, required List<int> ciphertext})
      : iv = Uint8List.fromList(iv),
        ciphertext = Uint8List.fromList(ciphertext);
}

/// HKDF-SHA256 with TanStack's `byok:keyring:v1` domain separation.
Future<KeyringEncryptionKey> deriveAesKey(List<int> prfOutput) async {
  if (prfOutput.length != 32 ||
      prfOutput.any((value) => value < 0 || value > 255)) {
    throw ArgumentError('Invalid passkey PRF byte array');
  }
  final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: SecretKey(prfOutput),
    nonce: const [],
    info: utf8.encode('byok:keyring:v1'),
  );
  return KeyringEncryptionKey._(key);
}

Future<EncryptedKeyring> encryptKeyring(
  KeyringEncryptionKey key,
  Map<String, String> keys,
) async {
  final box = await AesGcm.with256bits().encrypt(
    utf8.encode(jsonEncode(keys)),
    secretKey: key._key,
  );
  return EncryptedKeyring(
    iv: box.nonce,
    ciphertext: [...box.cipherText, ...box.mac.bytes],
  );
}

Future<Map<String, String>> decryptKeyring(
  KeyringEncryptionKey key,
  List<int> iv,
  List<int> ciphertext,
) async {
  if (iv.length != 12 || ciphertext.length < 16) {
    throw const FormatException('Invalid AES-GCM keyring envelope');
  }
  final cleartext = await AesGcm.with256bits().decrypt(
    SecretBox(
      ciphertext.sublist(0, ciphertext.length - 16),
      nonce: iv,
      mac: Mac(ciphertext.sublist(ciphertext.length - 16)),
    ),
    secretKey: key._key,
  );
  final parsed = jsonDecode(utf8.decode(cleartext));
  if (parsed is! Map) return {};
  final provider = RegExp(r'^[a-z][a-z0-9-]{0,63}$');
  return {
    for (final entry in parsed.entries)
      if (entry.key is String &&
          provider.hasMatch(entry.key as String) &&
          entry.value is String &&
          (entry.value as String).isNotEmpty)
        entry.key as String: entry.value as String,
  };
}
