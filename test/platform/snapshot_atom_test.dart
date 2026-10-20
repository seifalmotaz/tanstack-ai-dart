// Ported from
// packages/ai-client/tests/snapshot-atom.test.ts
import 'package:tanstack_ai_dart/platform.dart';
import 'package:test/test.dart';

bool _isReadOnly(Object? value) {
  try {
    if (value is Map) {
      value['probe'] = true;
    } else if (value is List) {
      value.add(null);
    } else {
      return false;
    }
    return false;
  } on UnsupportedError {
    return true;
  }
}

void main() {
  group('snapshot-atom', () {
    test(
        'patchAtom freezes the patched snapshot and keeps identity without a change',
        () {
      final atom = createAtom(<String, dynamic>{'count': 1});
      patchAtom(atom, {'count': 2});
      final snapshot = atom.get();

      expect(_isReadOnly(snapshot), isTrue);
      patchAtom(atom, {'count': 2});
      expect(identical(atom.get(), snapshot), isTrue);
    });

    test('patchAtom skips notify when every field is unchanged', () {
      final atom = createAtom(<String, dynamic>{'count': 1, 'label': 'a'});
      var calls = 0;
      final stop = subscribeAtom(atom, () => calls++);

      patchAtom(atom, {'count': 1, 'label': 'a'});
      expect(calls, 0);
      expect(atom.get(), {'count': 1, 'label': 'a'});

      patchAtom(atom, {'count': 2});
      expect(calls, 1);
      expect(atom.get(), {'count': 2, 'label': 'a'});
      stop();
    });

    test('subscribeAtom adapts { unsubscribe } to a plain cleanup', () {
      final atom = createAtom(0);
      var calls = 0;
      final stop = subscribeAtom(atom, () => calls++);

      atom.set(1);
      expect(calls, 1);
      stop();
      atom.set(2);
      expect(calls, 1);
    });

    test('isolates a throwing listener from the next subscriber', () {
      final atom = createAtom(0);
      var second = 0;
      final errors = <Object>[];
      final previousReporter = listenerErrorReporter;
      listenerErrorReporter = (error, _) => errors.add(error);
      final stopFirst = subscribeAtom(atom, () {
        throw StateError('listener failed');
      });
      final stopSecond = subscribeAtom(atom, () => second++);

      atom.set(1);

      expect(second, 1);
      expect(errors, hasLength(1));
      stopFirst();
      stopSecond();
      listenerErrorReporter = previousReporter;
    });

    test('subscribeAtom calls the listener again for a change made inside it',
        () {
      final atom = createAtom(
        <String, dynamic>{'isLoading': true, 'status': 'generating'},
      );
      final seen = <bool>[];
      final stop = subscribeAtom(atom, () {
        seen.add(atom.get()['isLoading'] as bool);
        if (atom.get()['status'] == 'idle' && atom.get()['isLoading'] == true) {
          patchAtom(atom, {'isLoading': false});
        }
      });

      patchAtom(atom, {'status': 'idle'});
      expect(seen, [true, false]);
      stop();
    });

    test('stops calling a listener that changes the atom on every call', () {
      final atom = createAtom(<String, dynamic>{'count': 0});
      var calls = 0;
      final stop = subscribeAtom(atom, () {
        calls++;
        patchAtom(atom, {'count': (atom.get()['count'] as int) + 1});
      });

      patchAtom(atom, {'count': 1});

      expect(calls, 8);
      stop();
    });

    test('reuses the frozen copy of an unchanged message and part', () {
      final cache = Map<Object, Object>.identity();
      final text = <String, dynamic>{'type': 'text', 'content': 'hi'};
      final tool = <String, dynamic>{
        'type': 'tool-call',
        'input': {'q': 'a'},
      };
      final first = <String, dynamic>{
        'id': 'm1',
        'parts': [text, tool],
      };

      final frozenFirst = freezeSnapshotMessages(cache, [first]).first;
      // The processor replaces the message and the changed part only.
      final second = <String, dynamic>{
        ...first,
        'parts': [
          {...text, 'content': 'hi!'},
          tool,
        ],
      };
      final frozenSecond = freezeSnapshotMessages(cache, [second]).first;

      expect(identical(frozenSecond, frozenFirst), isFalse);
      expect(
          identical(frozenSecond['parts'][1], frozenFirst['parts'][1]), isTrue);
      expect(identical(frozenSecond['parts'][0], frozenFirst['parts'][0]),
          isFalse);
      expect(
        identical(freezeSnapshotMessages(cache, [second]).first, frozenSecond),
        isTrue,
      );
    });

    test('cloneSnapshotValue copies plain values and keeps other objects', () {
      final instance = _Result();
      final map = <String, int>{'a': 1};

      expect(identical(cloneSnapshotValue(instance), instance), isTrue);
      expect(identical(cloneSnapshotValue(map), map), isFalse);

      final plain = <String, dynamic>{'url': 'a'};
      final copy = cloneSnapshotValue(plain) as Map;
      expect(copy, plain);
      expect(identical(copy, plain), isFalse);
      expect(_isReadOnly(copy), isTrue);
    });
  });
}

class _Result {
  String read() => 'ok';
}
