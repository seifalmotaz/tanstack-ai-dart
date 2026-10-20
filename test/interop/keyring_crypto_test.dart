import 'dart:convert';
import 'dart:io';

import 'package:tanstack_ai_dart/src/crypto/keyring_crypto.dart';
import 'package:test/test.dart';

void main() {
  final fixture = jsonDecode(File(
    'test/processing/fixtures/keyring_webcrypto.json',
  ).readAsStringSync()) as Map;
  final prf = List<int>.from(fixture['prf'] as List);
  final iv = List<int>.from(fixture['iv'] as List);
  final ciphertext = List<int>.from(fixture['ciphertext'] as List);
  final keys = Map<String, String>.from(fixture['keys'] as Map);

  // Upstream: ai-client/tests/byok-passkey.test.ts.
  group('passkey crypto', () {
    test('round-trips a keyring through AES-256-GCM', () async {
      final key = await deriveAesKey(prf);
      final sealed = await encryptKeyring(key, keys);
      expect(await decryptKeyring(key, sealed.iv, sealed.ciphertext), keys);
    });
  });
  group('WebCrypto interoperability and authentication', () {
    test('decrypts the upstream HKDF and AES-GCM format', () async {
      final key = await deriveAesKey(prf);
      expect(await decryptKeyring(key, iv, ciphertext), keys);
    });
    test('rejects modified ciphertext', () async {
      final key = await deriveAesKey(prf);
      final modified = [...ciphertext];
      modified[0] ^= 1;
      await expectLater(
          decryptKeyring(key, iv, modified), throwsA(isA<Exception>()));
    });
    test('rejects a different PRF key', () async {
      final key = await deriveAesKey(List.filled(32, 255));
      await expectLater(
          decryptKeyring(key, iv, ciphertext), throwsA(isA<Exception>()));
    });
    test('uses a fresh random nonce on every encryption', () async {
      final key = await deriveAesKey(prf);
      final first = await encryptKeyring(key, keys);
      final second = await encryptKeyring(key, keys);
      expect(first.iv.length, 12);
      expect(first.iv, isNot(second.iv));
      expect(first.ciphertext, isNot(second.ciphertext));
    });
    test('rejects invalid PRF bytes and malformed envelopes', () async {
      await expectLater(deriveAesKey([1]), throwsArgumentError);
      await expectLater(
          deriveAesKey(List.filled(32, 256)), throwsArgumentError);
      final key = await deriveAesKey(prf);
      await expectLater(
          decryptKeyring(key, [], ciphertext), throwsFormatException);
      await expectLater(decryptKeyring(key, iv, []), throwsFormatException);
    });
  });
}
