// Ported from
// packages/ai-client/tests/byok-client.test.ts
// plus the pure BYOK resolution cases from byok-headers.test.ts.
import 'dart:async';
import 'dart:convert';

import 'package:tanstack_ai_dart/platform.dart';
import 'package:test/test.dart';

class _UnlockableStorage implements KeyringStorage {
  _UnlockableStorage({
    required KeyringStorageSave save,
    this.peekValue = const {'openai': 'aaaa', 'anthropic': 'bbbb'},
    this.loadValue = const {
      'openai': 'sk-openai-old',
      'anthropic': 'sk-anthropic-keep',
    },
    this.loadError,
    this.peekError,
  }) : _save = save;

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

  final KeyringStorageSave _save;
  KeyPreview peekValue;
  Keyring loadValue;
  Object? loadError;
  Object? peekError;

  @override
  FutureOr<KeyPreview> Function()? get peek => () {
        if (peekError != null) return Future.error(peekError!);
        return peekValue;
      };

  @override
  FutureOr<Keyring> load() {
    if (loadError != null) return Future.error(loadError!);
    return loadValue;
  }

  @override
  FutureOr<void> save(Keyring keys) => _save(keys);

  @override
  FutureOr<void> clear() {}
}

typedef KeyringStorageSave = FutureOr<void> Function(Keyring keys);

class _FailingStorage implements KeyringStorage {
  _FailingStorage({this.failSave = false, this.failClear = false});

  final bool failSave;
  final bool failClear;

  @override
  String get id => failSave ? 'failing' : 'failing-clear';

  @override
  String get label => 'Failing';

  @override
  bool get persistent => true;

  @override
  bool get unlockable => false;

  @override
  String? get warning => null;

  @override
  FutureOr<KeyPreview> Function()? get peek => null;

  @override
  FutureOr<Keyring> load() => <String, String>{};

  @override
  FutureOr<void> save(Keyring keys) {
    if (failSave) return Future.error(StateError('quota'));
    return null;
  }

  @override
  FutureOr<void> clear() {
    if (failClear) return Future.error(StateError('idb blocked'));
    return null;
  }
}

void main() {
  group('defineByok memory', () {
    test('isolates and freezes nested snapshot state', () async {
      final byok = defineByok();
      await byok.update('openai', 'sk-abcdefghij');
      final snapshot = byok.getSnapshot();

      expect(snapshot.status, isA<Map<String, KeyStatus>>());
      expect(
        () => (snapshot.status as Map)['openai'] = const KeyStatus(
          state: KeyStatusState.set,
          masked: 'leak',
        ),
        throwsA(isA<UnsupportedError>()),
      );
      expect(byok.getSnapshot().status['openai']?.state, KeyStatusState.set);
      expect(byok.getSnapshot().status['openai']?.masked, 'ghij');
    });

    test('uses Set subscription behavior', () async {
      final byok = defineByok();
      await byok.ready();
      var calls = 0;
      void listener() => calls++;
      final first = byok.subscribe(listener);
      byok.subscribe(listener);

      byok.request('openai', 'missing');
      expect(calls, 1);
      first();
      byok.request('openai', 'missing');
      expect(calls, 1);
    });

    test('a throwing listener does not skip the next listener', () async {
      final byok = defineByok();
      await byok.ready();
      final errors = <Object>[];
      final previous = listenerErrorReporter;
      listenerErrorReporter = (error, _) => errors.add(error);
      var calls = 0;
      byok.subscribe(() {
        throw StateError('listener failed');
      });
      byok.subscribe(() => calls++);

      byok.request('openai', 'missing');

      expect(calls, 1);
      expect(byok.getSnapshot().prompt?.provider, 'openai');
      expect(errors, hasLength(1));
      listenerErrorReporter = previous;
    });

    test('updates and snapshots without exposing the raw key', () async {
      final byok = defineByok(DefineByokOptions(storage: memoryStorage()));
      await byok.update('openai', 'sk-abcdefghij');
      final snapshot = byok.getSnapshot();
      expect(snapshot.status['openai']?.state, KeyStatusState.set);
      expect(snapshot.status['openai']?.masked, 'ghij');
      expect(jsonEncode(snapshot.status.map((k, v) => MapEntry(k, v.toJson()))),
          isNot(contains('sk-abcdefghij')));
      expect(byok.headers('openai'), {'x-byok-openai': 'sk-abcdefghij'});
      expect(byok.headers('anthropic'), isEmpty);
    });

    test('sends and prepares companion credentials with the provider',
        () async {
      final account = defineByokProvider(id: 'acme-account', label: 'Account');
      final token = defineByokProvider(
        id: 'acme',
        label: 'Token',
        withProviders: [account],
      );
      final byok = defineByok(DefineByokOptions(
        providers: [token, account],
      ));
      await byok.update('acme', 'tok-abcdefghij');
      await expectLater(
        byok.prepare('acme'),
        throwsA(isA<ByokBlockedError>()),
      );
      expect(byok.getSnapshot().prompt?.provider, 'acme-account');
      expect(byok.getSnapshot().prompt?.reason, 'missing');
      await byok.update('acme-account', 'acct-1');
      await byok.prepare('acme');
      expect(byok.headers('acme'), {
        'x-byok-acme': 'tok-abcdefghij',
        'x-byok-acme-account': 'acct-1',
      });
    });

    test('update(key) throws when prompt is null', () async {
      final byok = defineByok();
      await expectLater(
        byok.update('sk-abcdefghij'),
        throwsA(predicate((error) => '$error'.contains('prompt is null'))),
      );
    });

    test('rejects empty or whitespace keys', () async {
      final byok = defineByok();
      await expectLater(
        byok.update('openai', '   '),
        throwsA(predicate((error) => '$error'.contains('non-empty'))),
      );
      expect(byok.getSnapshot().status['openai'], isNull);
    });

    test('update(key) writes the prompted provider', () async {
      final byok = defineByok();
      byok.request('anthropic', 'missing');
      await byok.update('sk-abcdefghij');
      expect(byok.getSnapshot().status['anthropic']?.state, KeyStatusState.set);
      expect(byok.getSnapshot().prompt, isNull);
    });

    test('clear removes one key or all keys', () async {
      final byok = defineByok();
      await byok.update('openai', 'sk-aaaaaaaaaa');
      await byok.update('grok', 'xai-bbbbbbbb');
      await byok.clear('openai');
      expect(byok.getSnapshot().status['openai'], isNull);
      expect(byok.getSnapshot().status['grok']?.state, KeyStatusState.set);
      await byok.clear();
      expect(byok.getSnapshot().status['grok'], isNull);
    });

    test(
        'prepare throws ByokBlockedError when the provider is empty and uncovered',
        () async {
      final byok = defineByok();
      await expectLater(
        byok.prepare('openai'),
        throwsA(isA<ByokBlockedError>()),
      );
      expect(byok.getSnapshot().prompt?.provider, 'openai');
      expect(byok.getSnapshot().prompt?.reason, 'missing');
    });

    test('prepare does not throw when server coverage is set', () async {
      final byok = defineByok();
      byok.setServerCoverage({'openai': true});
      await expectLater(byok.prepare('openai'), completes);
      expect(byok.getSnapshot().prompt, isNull);
    });

    test('prepare does not throw when server coverage is true for any slug',
        () async {
      final byok = defineByok();
      byok.setServerCoverage(true);
      await expectLater(byok.prepare('bedrock'), completes);
      await expectLater(byok.prepare('my-llm'), completes);
    });

    test('accepts slugs that are not first-party adapter names', () async {
      final byok = defineByok();
      await byok.update('bedrock', 'sk-bedrock-key');
      expect(byok.getSnapshot().status['bedrock']?.masked, '-key');
      expect(byok.headers('bedrock'), {'x-byok-bedrock': 'sk-bedrock-key'});
    });

    test('rejects invalid provider ids', () async {
      final byok = defineByok();
      await expectLater(
        byok.update('OpenAI', 'sk-abcdefghij'),
        throwsA(
          predicate((error) => '$error'.contains('Invalid BYOK provider id')),
        ),
      );
      expect(
        () => byok.headers('OpenAI'),
        throwsA(
          predicate((error) => '$error'.contains('Invalid BYOK provider id')),
        ),
      );
    });

    test('prepare skips the empty check when no provider is given', () async {
      final byok = defineByok();
      await expectLater(byok.prepare(), completes);
    });

    test('headers() without a provider emits every present key', () async {
      final byok = defineByok();
      await byok.update('openai', 'sk-aaaaaaaaaa');
      await byok.update('grok', 'xai-bbbbbbbb');
      expect(byok.headers(), {
        'x-byok-openai': 'sk-aaaaaaaaaa',
        'x-byok-grok': 'xai-bbbbbbbb',
      });
    });

    test('subscribe fires on update', () async {
      final byok = defineByok();
      var calls = 0;
      final stop = byok.subscribe(() => calls++);
      await byok.update('openai', 'sk-aaaaaaaaaa');
      expect(calls, greaterThan(0));
      stop();
    });

    test('getSnapshot returns the same object until state changes', () async {
      final byok = defineByok(DefineByokOptions(storage: memoryStorage()));
      final first = byok.getSnapshot();
      expect(identical(byok.getSnapshot(), first), isTrue);

      byok.request('openai', 'missing');
      final afterRequest = byok.getSnapshot();
      expect(identical(afterRequest, first), isFalse);
      expect(identical(byok.getSnapshot(), afterRequest), isTrue);

      await byok.update('openai', 'sk-abcdefghij');
      final afterUpdate = byok.getSnapshot();
      expect(identical(afterUpdate, afterRequest), isFalse);
      expect(identical(byok.getSnapshot(), afterUpdate), isTrue);

      await byok.clear('openai');
      final afterClear = byok.getSnapshot();
      expect(identical(afterClear, afterUpdate), isFalse);
      expect(identical(byok.getSnapshot(), afterClear), isTrue);
    });
  });

  group('defineByok unlockable update/clear', () {
    test('update loads the locked ring so other providers survive', () async {
      Keyring? saved;
      final storage = _UnlockableStorage(save: (keys) => saved = keys);

      final byok = defineByok(DefineByokOptions(storage: storage));
      await byok.update('openai', 'sk-openai-new');

      expect(saved?['openai'], 'sk-openai-new');
      expect(saved?['anthropic'], 'sk-anthropic-keep');
    });

    test('clear(provider) loads the locked ring so other providers survive',
        () async {
      Keyring? saved;
      final storage = _UnlockableStorage(save: (keys) => saved = keys);

      final byok = defineByok(DefineByokOptions(storage: storage));
      await byok.clear('openai');

      expect(saved?['anthropic'], 'sk-anthropic-keep');
      expect(saved?.containsKey('openai'), isFalse);
    });
  });

  group('defineByok persist-then-emit', () {
    test('does not mark a key saved when storage.save throws', () async {
      final byok = defineByok(
        DefineByokOptions(storage: _FailingStorage(failSave: true)),
      );
      await expectLater(
        byok.update('openai', 'sk-abcdefghij'),
        throwsA(predicate((error) => '$error'.contains('quota'))),
      );
      expect(byok.headers('openai'), isEmpty);
      expect(byok.getSnapshot().status['openai']?.state, KeyStatusState.error);
      expect(byok.getSnapshot().status['openai']?.masked, 'ghij');
      expect(byok.getSnapshot().status['openai']?.message, 'quota');
      expect(
        jsonEncode(
            byok.getSnapshot().status.map((k, v) => MapEntry(k, v.toJson()))),
        isNot(contains('sk-abcdefghij')),
      );
    });

    test('does not clear keys when storage.clear throws', () async {
      final byok = defineByok(
        DefineByokOptions(storage: _FailingStorage(failClear: true)),
      );
      await byok.update('openai', 'sk-abcdefghij');
      await expectLater(
        byok.clear(),
        throwsA(predicate((error) => '$error'.contains('idb blocked'))),
      );
      expect(byok.headers('openai'), {
        'x-byok-openai': 'sk-abcdefghij',
      });
    });
  });

  group('defineByok locked snapshot', () {
    test('peeks last-4 as locked and omits headers until unlock', () async {
      final storage = _UnlockableStorage(
        save: (_) {},
        peekValue: {'openai': 'ghij'},
        loadValue: {'openai': 'sk-abcdefghij'},
      );
      final byok = defineByok(DefineByokOptions(storage: storage));
      await byok.ready();

      expect(byok.getSnapshot().locked, isTrue);
      expect(byok.getSnapshot().status['openai']?.state, KeyStatusState.locked);
      expect(byok.getSnapshot().status['openai']?.masked, 'ghij');
      expect(byok.headers('openai'), isEmpty);

      await byok.unlock();
      expect(byok.getSnapshot().locked, isFalse);
      expect(byok.headers('openai'), {'x-byok-openai': 'sk-abcdefghij'});
    });

    test('maps a cancelled unlock to ByokBlockedError locked', () async {
      final storage = _UnlockableStorage(
        save: (_) {},
        peekValue: {'openai': 'ghij'},
        loadError: StateError('Passkey unlock was cancelled'),
      );
      final byok = defineByok(DefineByokOptions(storage: storage));
      await byok.ready();
      await expectLater(byok.unlock(), throwsA(isA<ByokBlockedError>()));
      expect(byok.getSnapshot().prompt?.provider, 'openai');
      expect(byok.getSnapshot().prompt?.reason, 'locked');
      expect(byok.getSnapshot().locked, isTrue);
      expect(byok.headers('openai'), isEmpty);
    });

    test('records peek failures on the snapshot', () async {
      final storage = _UnlockableStorage(
        save: (_) {},
        peekValue: const <String, String>{},
        loadValue: const <String, String>{},
        peekError: StateError('IndexedDB blocked'),
      );
      final byok = defineByok(DefineByokOptions(storage: storage));
      await byok.ready();
      expect(byok.getSnapshot().storageError, contains('IndexedDB blocked'));
      expect(byok.getSnapshot().locked, isTrue);
    });
  });

  group('byok resolution helpers', () {
    test('resolves the callback first, then candidates', () {
      expect(
        resolveByokProviderId(() => 'openai', ['anthropic']),
        'openai',
      );
      expect(
        resolveByokProviderId(null, ['anthropic', 'grok']),
        'anthropic',
      );
      expect(
        resolveByokProviderId(() => 'OpenAI', ['OpenAI', 'openai']),
        'openai',
      );
      expect(resolveByokProviderId(null, ['OpenAI']), isNull);
    });

    test('prepareResolvedByokHeaders throws for an unresolved provider',
        () async {
      final byok = defineByok(DefineByokOptions(storage: memoryStorage()));
      await expectLater(
        prepareResolvedByokHeaders(byok, null),
        throwsA(isA<ByokUnresolvedProviderError>()),
      );
    });

    test('prepareResolvedByokHeaders prepares and stamps only the slug',
        () async {
      final byok = defineByok(DefineByokOptions(storage: memoryStorage()));
      await byok.update('openai', 'sk-live');
      await byok.update('anthropic', 'sk-anthropic');
      expect(
        await prepareResolvedByokHeaders(byok, 'openai'),
        {'x-byok-openai': 'sk-live'},
      );
    });
  });
}
