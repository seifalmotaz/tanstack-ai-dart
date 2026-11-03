import 'package:tanstack_ai_dart/generation.dart';
import 'package:test/test.dart';

void main() {
  group('generation snapshot contract', () {
    test('publishes a deep read-only JSON copy and keeps internal values',
        () async {
      final raw = <String, dynamic>{
        'id': '1',
        'nested': <String, dynamic>{
          'count': 1,
          'tags': <String>['a'],
        },
        'items': <Object?>[
          <String, int>{'n': 1},
        ],
      };
      final client = GenerationClient<Map<String, dynamic>,
          Map<String, dynamic>, Map<String, dynamic>>(
        fetcher: (input, options) async => raw,
      );

      await client.generate({'prompt': 'test'});

      final snapshot = client.getSnapshot();
      final published = snapshot.result!;
      expect(identical(client.getSnapshot(), snapshot), isTrue);
      expect(published, raw);
      expect(identical(published, raw), isFalse);

      expect(() => published['id'] = 'mutated', throwsUnsupportedError);
      final nested = published['nested'] as Map;
      expect(() => nested['count'] = 2, throwsUnsupportedError);
      expect(() => (nested['tags'] as List).add('b'), throwsUnsupportedError);
      final items = published['items'] as List;
      expect(() => items.add(0), throwsUnsupportedError);
      expect(
        () => (items.first as Map)['n'] = 2,
        throwsUnsupportedError,
      );

      expect(client.getResult(), same(raw));
      raw['id'] = 'raw';
      (raw['nested'] as Map)['count'] = 9;
      (raw['nested'] as Map)['tags'] = <String>['raw'];
      (raw['items'] as List).add('raw');
      expect(published['id'], '1');
      expect((published['nested'] as Map)['count'], 1);
      expect((published['nested'] as Map)['tags'], ['a']);
      expect(published['items'], [
        {'n': 1}
      ]);
    });

    test('publishes a default List<dynamic> read-only', () async {
      final raw = <dynamic>[
        1,
        <String, dynamic>{'count': 1},
      ];
      final client = GenerationClient<String, List<dynamic>, List<dynamic>>(
        fetcher: (input, options) async => raw,
      );

      await client.generate('test');

      final published = client.getSnapshot().result!;
      expect(identical(published, raw), isFalse);
      expect(() => published.add(2), throwsUnsupportedError);
      expect(() => published[0] = 2, throwsUnsupportedError);
      expect(() => (published[1] as Map)['count'] = 2, throwsUnsupportedError);

      (raw[1] as Map)['count'] = 9;
      raw.add(3);
      expect(published[1], {'count': 1});
      expect(published, [
        1,
        {'count': 1}
      ]);
      expect(client.getResult(), same(raw));
    });

    test('VideoGenerationClient publishes an onResult JSON map read-only',
        () async {
      final raw = <String, dynamic>{
        'id': '1',
        'nested': <String, dynamic>{'count': 1},
      };
      final client = VideoGenerationClient<Map<String, dynamic>>(
        fetcher: (input, options) async => const VideoGenerateResult(
          jobId: 'job-1',
          status: 'completed',
          url: 'https://example.com/video.mp4',
        ),
        onResult: (result) => GenerationTransformOutcome.value(raw),
      );

      await client.generate(const VideoGenerateInput(prompt: 'test'));

      final published = client.getSnapshot().result!;
      expect(identical(published, raw), isFalse);
      expect(published, raw);
      expect(() => published['id'] = 'mutated', throwsUnsupportedError);
      expect(
        () => (published['nested'] as Map)['count'] = 2,
        throwsUnsupportedError,
      );

      (raw['nested'] as Map)['count'] = 9;
      expect(published['nested'], {'count': 1});
      expect(client.getResult(), same(raw));
    });

    test('status patches keep the published result identity', () async {
      final raw = <String, dynamic>{'id': '1'};
      final client =
          GenerationClient<String, Map<String, dynamic>, Map<String, dynamic>>(
        fetcher: (input, options) async => raw,
      );
      final published = <Map<String, dynamic>>[];
      final stop = client.subscribe(() {
        final result = client.getSnapshot().result;
        if (result != null) published.add(result);
      });

      await client.generate('test');
      stop();

      expect(published, isNotEmpty);
      expect(
        published.every((result) => identical(result, published.first)),
        isTrue,
      );
      expect(client.getSnapshot().result, same(published.first));
    });

    test('non-JSON typed collections require a copier, never a bad cast',
        () async {
      final raw = <int, int>{1: 2};
      final client = GenerationClient<String, Map<int, int>, Map<int, int>>(
        fetcher: (input, options) async => raw,
      );

      await client.generate('test');

      expect(client.getStatus(), GenerationClientState.error);
      expect(client.getError(), isA<SnapshotCopyException>());
      expect(client.getResult(), same(raw));
      expect(raw, {1: 2});
    });

    test('inferred transformed JSON maps are read-only without a copier',
        () async {
      final client = GenerationClient(
        fetcher: (_, options) async => {'id': '1'},
        onResult: (_) =>
            GenerationTransformOutcome.value({'transformed': true}),
      );
      await client.generate('test');
      expect(client.getStatus(), GenerationClientState.success);
      final published = client.getSnapshot().result!;
      expect(() => published['transformed'] = false, throwsUnsupportedError);
      expect(client.getResult(), {'transformed': true});
    });

    test('scalar-typed JSON collections keep their Dart types', () async {
      Future<void> check<T>(T raw, void Function(T) mutate) async {
        final client = GenerationClient<String, T, T>(
          fetcher: (_, options) async => raw,
        );
        await client.generate('test');
        expect(client.getStatus(), GenerationClientState.success);
        final T published = client.getSnapshot().result as T;
        expect(published, raw);
        expect(identical(published, raw), isFalse);
        expect(() => mutate(published), throwsUnsupportedError);
      }

      await check<Map<String, int>>({'a': 1}, (v) => v['a'] = 2);
      await check<List<int>>([1], (v) => v.add(2));
      await check<Map<String, bool>>({'a': true}, (v) => v['a'] = false);
      await check<List<String?>>(['a', null], (v) => v.add('b'));
      await check<Map<String, int?>>({'a': null}, (v) => v['a'] = 2);
      await check<List<num>>([1, 2.5], (v) => v.add(3));
      await check<Map<String, Null>>({'a': null}, (v) => v.clear());
    });

    test('an explicit copier publishes typed maps and lists read-only',
        () async {
      final rawMap = <String, int>{'count': 1};
      final mapClient =
          GenerationClient<String, Map<String, int>, Map<String, int>>(
        copySnapshotResult: (value) => Map<String, int>.unmodifiable(value),
        fetcher: (input, options) async => rawMap,
      );

      await mapClient.generate('test');

      final publishedMap = mapClient.getSnapshot().result!;
      expect(() => publishedMap['count'] = 2, throwsUnsupportedError);
      expect(mapClient.getResult(), same(rawMap));
      expect(rawMap, {'count': 1});

      final rawList = <int>[1, 2];
      final listClient = GenerationClient<String, List<int>, List<int>>(
        copySnapshotResult: (value) => List<int>.unmodifiable(value),
        fetcher: (input, options) async => rawList,
      );

      await listClient.generate('test');

      final publishedList = listClient.getSnapshot().result!;
      expect(() => publishedList.add(3), throwsUnsupportedError);
      expect(() => publishedList[0] = 9, throwsUnsupportedError);
      expect(listClient.getResult(), same(rawList));
      expect(rawList, [1, 2]);
    });

    test('an explicit copier isolates nested typed collections', () async {
      final raw = <String, Map<String, int>>{
        'outer': <String, int>{'count': 1},
      };
      final client = GenerationClient<String, Map<String, Map<String, int>>,
          Map<String, Map<String, int>>>(
        copySnapshotResult: (value) =>
            Map<String, Map<String, int>>.unmodifiable({
          for (final entry in value.entries)
            entry.key: Map<String, int>.unmodifiable(entry.value),
        }),
        fetcher: (input, options) async => raw,
      );

      await client.generate('test');

      final published = client.getSnapshot().result!;
      expect(
        () => published['outer']!['count'] = 2,
        throwsUnsupportedError,
      );
      expect(() => published['next'] = {}, throwsUnsupportedError);
      expect(client.getResult(), same(raw));
      expect(raw['outer'], {'count': 1});
    });

    test('a copier failure leaves no partial published result', () async {
      final raw = <String, int>{'count': 1};
      final failure = StateError('copier failed');
      final client =
          GenerationClient<String, Map<String, int>, Map<String, int>>(
        copySnapshotResult: (value) => throw failure,
        fetcher: (input, options) async => raw,
      );

      await client.generate('test');

      expect(client.getSnapshot().result, isNull);
      expect(client.getResult(), same(raw));
      expect(client.getError(), same(failure));
      expect(client.getStatus(), GenerationClientState.error);
    });

    test('publishes cycles and repeated containers read-only', () async {
      final shared = <String, dynamic>{'count': 1};
      final sharedList = <dynamic>[1];
      final raw = <String, dynamic>{
        'a': shared,
        'b': shared,
        'listA': sharedList,
        'listB': sharedList,
      };
      raw['self'] = raw;
      sharedList.add(raw);

      final client =
          GenerationClient<String, Map<String, dynamic>, Map<String, dynamic>>(
        fetcher: (input, options) async => raw,
      );

      await client.generate('test');

      final published = client.getSnapshot().result!;
      expect(identical(published['self'], published), isTrue);
      expect(identical(published['a'], published['b']), isTrue);
      expect(identical(published['listA'], published['listB']), isTrue);
      expect(identical((published['listA'] as List).last, published), isTrue);
      expect(
        () => (published['a'] as Map)['count'] = 2,
        throwsUnsupportedError,
      );
      expect(
        () => (published['listA'] as List).add(2),
        throwsUnsupportedError,
      );
      expect(() => published['self'] = null, throwsUnsupportedError);
      expect(shared['count'], 1);
      expect(sharedList, hasLength(2));
      expect(identical(raw['self'], raw), isTrue);
    });

    test('keeps opaque result model identity', () async {
      final result = _SnapshotResult('1');
      final client = GenerationClient<String, _SnapshotResult, _SnapshotResult>(
        fetcher: (input, options) async => result,
      );

      await client.generate('test');

      expect(client.getSnapshot().result, same(result));
      expect(client.getResult(), same(result));
      expect(client.getSnapshot().result?.read(), '1');
    });
  });
}

class _SnapshotResult {
  const _SnapshotResult(this.id);

  final String id;

  String read() => id;
}
