// Ported from
// packages/ai-client/tests/byok-passkey.test.ts
// and packages/ai-client/tests/byok-passkey-ceremony.test.ts
import 'dart:async';
import 'dart:convert';

import 'package:tanstack_ai_dart/platform.dart';
import 'package:test/test.dart';

/// Test double for the host WebCrypto adapter. The production package does not
/// ship or fake AES-GCM; this only exercises the delegation/lifecycle contract.
class FakePasskeyCrypto implements PasskeyCrypto {
  @override
  Future<Object> deriveAesKey(List<int> prfOutput) async =>
      'derived:${prfOutput.join(',')}';

  @override
  Future<EncryptedKeyring> encryptKeyring(Object key, Keyring keys) async =>
      EncryptedKeyring(
        iv: const [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
        ciphertext: utf8.encode(jsonEncode(keys)),
      );

  @override
  Future<Keyring> decryptKeyring(
    Object key,
    List<int> iv,
    List<int> ciphertext,
  ) async {
    final decoded = jsonDecode(utf8.decode(ciphertext)) as Map;
    return decoded.map((key, value) => MapEntry('$key', '$value'));
  }
}

class FakePasskeyStore implements PasskeyRecordStore {
  FakePasskeyStore([this.record]);

  StoredKeyringRecord? record;
  int puts = 0;

  @override
  Future<StoredKeyringRecord?> get() async => record;

  @override
  Future<void> put(StoredKeyringRecord value) async {
    puts++;
    record = value;
  }

  @override
  Future<void> clear() async {
    record = null;
  }
}

class FakePasskeyPlatform implements PasskeyPlatform {
  FakePasskeyPlatform({
    this.existing,
    this.registrationConsumesActivation = false,
    this.registrationPrf,
    this.registrationHasResult = false,
    this.evaluateResult,
    this.prfEnabled = true,
    this.supported = true,
    this.secure = true,
    this.activation = true,
  }) {
    store.record = existing;
  }

  StoredKeyringRecord? existing;
  bool registrationConsumesActivation;
  List<int>? registrationPrf;
  bool registrationHasResult;
  List<int>? evaluateResult;
  bool prfEnabled;
  bool supported;
  bool? secure;
  bool? activation;

  @override
  final FakePasskeyStore store = FakePasskeyStore();
  @override
  final FakePasskeyCrypto crypto = FakePasskeyCrypto();
  final List<List<int>> salts = <List<int>>[];
  int registerCalls = 0;
  int evaluateCalls = 0;

  @override
  bool get isSupported => supported;

  @override
  bool? get isSecureContext => secure;

  @override
  bool? get userActivationIsActive => activation;

  @override
  Future<PasskeyRegistration> register({
    required String rpName,
    required String userName,
    String? rpId,
    required List<int> salt,
  }) async {
    registerCalls++;
    salts.add(List<int>.of(salt));
    if (registrationConsumesActivation) activation = false;
    return PasskeyRegistration(
      credentialId: const [1, 2, 3],
      salt: salt,
      prf: registrationHasResult
          ? (registrationPrf ?? List<int>.filled(32, 7))
          : null,
      prfEnabled: prfEnabled,
    );
  }

  @override
  Future<List<int>> evaluatePrf(
    List<int> credentialId,
    List<int> salt,
  ) async {
    evaluateCalls++;
    return evaluateResult ?? registrationPrf ?? List<int>.filled(32, 7);
  }
}

void main() {
  group('passkey crypto', () {
    test('round-trips a keyring through AES-256-GCM', () async {
      final prf = List<int>.generate(32, (index) => index);
      final key = await deriveAesKey(prf);
      final keys = {'openai': 'sk-abcdefghij'};
      final encrypted = await encryptKeyring(key, keys);
      expect(
        await decryptKeyring(key, encrypted.iv, encrypted.ciphertext),
        keys,
      );
    });

    final invalidPrfCases = <Object?>[
      <Object?>[],
      List<Object?>.filled(32, null),
      List<Object?>.filled(31, 0),
      List<Object?>.filled(33, 0),
      List<Object?>.filled(32, -1),
      List<Object?>.filled(32, 256),
      List<Object?>.filled(32, 0.5),
      List<Object?>.filled(32, '1'),
      List<Object?>.filled(32, double.nan),
    ];
    const invalidPrfTitles = <String>[
      'rejects invalid array PRF output 0 before saving',
      'rejects invalid array PRF output 1 before saving',
      'rejects invalid array PRF output 2 before saving',
      'rejects invalid array PRF output 3 before saving',
      'rejects invalid array PRF output 4 before saving',
      'rejects invalid array PRF output 5 before saving',
      'rejects invalid array PRF output 6 before saving',
      'rejects invalid array PRF output 7 before saving',
      'rejects invalid array PRF output 8 before saving',
    ];
    for (final (index, value) in invalidPrfCases.indexed) {
      test(invalidPrfTitles[index], () async {
        final platform = FakePasskeyPlatform(registrationPrf: null)
          ..registrationHasResult = true
          ..registrationPrf = value is List<int> ? value : null;
        // Use a dynamic list through the platform contract.
        final dynamicPlatform = _DynamicPrfPlatform(platform, value);
        final storage = passkeyStorage(dynamicPlatform);
        await expectLater(
          storage.save({'openai': 'sk-test-secret'}),
          throwsA(
            predicate(
              (error) => '$error'.contains('Invalid passkey PRF byte array'),
            ),
          ),
        );
        expect(dynamicPlatform.store.puts, 0);
      });
    }
  });

  group('isPasskeyStorageSupported', () {
    test('returns a boolean', () {
      expect(isPasskeyStorageSupported(null), isFalse);
      expect(
        isPasskeyStorageSupported(FakePasskeyPlatform(supported: true)),
        isTrue,
      );
    });
  });

  group('defaultByokStorage', () {
    test('returns memory storage with a warning when passkeys are unavailable',
        () {
      final store = defaultByokStorage();
      expect(store.id, 'memory');
      expect(store.warning, contains('memory for this tab only'));
    });

    test('returns passkey storage when the injected platform is available', () {
      final store = defaultByokStorage(
        platform: FakePasskeyPlatform(supported: true),
      );
      expect(store.id, 'passkey');
    });
  });

  group('defineByok unlockable storage', () {
    test('prepare loads the locked keyring before attaching headers', () async {
      var loadCalls = 0;
      final storage = _MockPasskeyStorage(
        load: () {
          loadCalls++;
          return {'openai': 'sk-abcdefghij'};
        },
      );

      final byok = defineByok(DefineByokOptions(storage: storage));
      await byok.prepare('openai');

      expect(loadCalls, greaterThan(0));
      expect(byok.headers('openai'), {'x-byok-openai': 'sk-abcdefghij'});
    });
  });

  group('passkeyStorage ceremonies', () {
    test(
        'rejects a saved-key unlock without activation before opening a ceremony',
        () async {
      final platform = FakePasskeyPlatform(
        existing: StoredKeyringRecord(
          credentialId: const [1],
          salt: List<int>.filled(32, 1),
          iv: const [1],
          ciphertext: utf8.encode('{"openai":"sk-old"}'),
          preview: const {'openai': 'k-old'},
        ),
        activation: false,
      );

      await expectLater(
        passkeyStorage(platform).load(),
        throwsA(predicate((error) => '$error'.contains('fresh user action'))),
      );
      expect(platform.evaluateCalls, 0);
    });

    test('allows the PRF follow-up after registration consumes activation',
        () async {
      final platform = FakePasskeyPlatform(
        registrationConsumesActivation: true,
        registrationHasResult: false,
      );

      await passkeyStorage(platform).save({'openai': 'sk-test-secret'});

      expect(platform.registerCalls, 1);
      expect(platform.evaluateCalls, 1);
      expect(platform.store.puts, 1);
    });

    const registrationResultTitles = <String>[
      'saves array PRF bytes and unlocks with native bytes (registration result: true)',
      'saves array PRF bytes and unlocks with native bytes (registration result: false)',
    ];
    for (final (index, registrationHasResult) in [true, false].indexed) {
      test(registrationResultTitles[index], () async {
        final bytes = List<int>.generate(
          32,
          (index) => index == 31 ? 255 : index,
        );
        final platform = FakePasskeyPlatform(
          registrationPrf: bytes,
          registrationHasResult: registrationHasResult,
        );
        await passkeyStorage(platform).save({'openai': 'sk-test-secret'});
        final record = platform.store.record;
        expect(record, isNotNull);

        final unlockA = FakePasskeyPlatform(
          existing: record,
          evaluateResult: List<int>.of(bytes),
        );
        expect(
          await passkeyStorage(unlockA).load(),
          {'openai': 'sk-test-secret'},
        );

        final unlockB = FakePasskeyPlatform(
          existing: record,
          evaluateResult: bytes,
        );
        expect(
          await passkeyStorage(unlockB).load(),
          {'openai': 'sk-test-secret'},
        );
      });
    }
    test('uses a fresh secure random salt per registration', () async {
      final firstPlatform = FakePasskeyPlatform();
      final secondPlatform = FakePasskeyPlatform();

      await passkeyStorage(firstPlatform).save({'openai': 'sk-first'});
      await passkeyStorage(secondPlatform).save({'openai': 'sk-second'});

      expect(firstPlatform.salts, hasLength(1));
      expect(secondPlatform.salts, hasLength(1));
      expect(firstPlatform.salts.single, hasLength(32));
      expect(secondPlatform.salts.single, hasLength(32));
      expect(firstPlatform.salts.single, isNot(secondPlatform.salts.single));
    });

    test('PasskeyPlatform supplies the real Dart crypto by default', () {
      expect(
        _MinimalPasskeyPlatform().crypto,
        isA<DartPasskeyCrypto>(),
      );
    });
  });
}

class _MinimalPasskeyPlatform extends PasskeyPlatform {
  @override
  bool get isSupported => true;
  @override
  bool? get isSecureContext => true;
  @override
  bool? get userActivationIsActive => true;
  @override
  Future<PasskeyRegistration> register({
    required String rpName,
    required String userName,
    String? rpId,
    required List<int> salt,
  }) =>
      throw UnimplementedError();
  @override
  Future<List<int>> evaluatePrf(List<int> credentialId, List<int> salt) =>
      throw UnimplementedError();
  @override
  PasskeyRecordStore get store => throw UnimplementedError();
}

class _DynamicPrfPlatform implements PasskeyPlatform {
  _DynamicPrfPlatform(this.base, this.prf);

  final FakePasskeyPlatform base;
  final Object? prf;

  @override
  FakePasskeyStore get store => base.store;

  @override
  bool get isSupported => true;

  @override
  bool? get isSecureContext => true;

  @override
  bool? get userActivationIsActive => true;

  @override
  Future<PasskeyRegistration> register({
    required String rpName,
    required String userName,
    String? rpId,
    required List<int> salt,
  }) async =>
      PasskeyRegistration(
        credentialId: const [1, 2, 3],
        salt: salt,
        prf: prf is List<int> ? prf as List<int> : null,
        prfEnabled: true,
      );

  @override
  Future<List<int>> evaluatePrf(
    List<int> credentialId,
    List<int> salt,
  ) async =>
      prf is List<int> ? prf as List<int> : const <int>[];

  @override
  PasskeyCrypto get crypto => base.crypto;
}

class _MockPasskeyStorage implements KeyringStorage {
  _MockPasskeyStorage({required Keyring Function() load}) : _load = load;

  final Keyring Function() _load;

  @override
  String get id => 'mock-passkey';

  @override
  String get label => 'Mock passkey';

  @override
  bool get persistent => true;

  @override
  bool get unlockable => true;

  @override
  String? get warning => null;

  @override
  FutureOr<KeyPreview> Function()? get peek => () => {'openai': 'ghij'};

  @override
  @override
  FutureOr<Keyring> load() => _load();

  @override
  FutureOr<void> save(Keyring keys) {}

  @override
  FutureOr<void> clear() {}
}
