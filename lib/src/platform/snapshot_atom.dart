import 'dart:async';
import 'dart:collection';

/// Ported from `packages/ai-client/src/snapshot-atom.ts`.
///
/// Dart has no `Object.freeze`; published values are unmodifiable copies
/// instead. Class instances and other non-plain objects keep their identity,
/// matching the upstream `cloneSnapshotValue` rule.

typedef ListenerErrorReporter = void Function(
  Object error,
  StackTrace stackTrace,
);

/// Reports a listener error without stopping the caller.
///
/// Tests and hosts can replace this to capture listener failures.
ListenerErrorReporter listenerErrorReporter = (error, stackTrace) {
  Zone.current.print('$error\n$stackTrace');
};

void reportListenerError(Object error, [StackTrace? stackTrace]) {
  listenerErrorReporter(error, stackTrace ?? StackTrace.current);
}

/// Call every listener. One listener's throw does not skip the others.
void notifyListeners(Iterable<void Function()> listeners) {
  for (final listener in List<void Function()>.of(listeners)) {
    try {
      listener();
    } catch (error, stackTrace) {
      reportListenerError(error, stackTrace);
    }
  }
}

/// Minimal atom surface used by the ported client code.
class Atom<T> {
  T _value;
  final Set<void Function()> _listeners = <void Function()>{};

  Atom(this._value);

  T get() => _value;

  void set(T value) {
    if (identical(_value, value)) return;
    _value = value;
    notifyListeners(_listeners);
  }

  void update(T Function(T previous) updater) {
    set(updater(_value));
  }

  AtomSubscription subscribe(void Function() listener) {
    _listeners.add(listener);
    return AtomSubscription(() => _listeners.remove(listener));
  }
}

class AtomSubscription {
  final void Function() unsubscribe;
  AtomSubscription(this.unsubscribe);
}

Atom<T> createAtom<T>(T initialValue) => Atom<T>(initialValue);

bool _isPlainObject(Object? value) => value is Map;

/// Copy plain JSON data recursively and make every collection read-only.
/// Non-collection objects keep their identity.
Object? cloneSnapshotValue(Object? value) =>
    _cloneSnapshotValue(value, Map<Object, Object>.identity());

Object? _cloneSnapshotValue(Object? value, Map<Object, Object> cache) {
  if (value is List) {
    final cached = cache[value];
    if (cached != null) return cached;
    final backing = <Object?>[];
    final view = UnmodifiableListView<Object?>(backing);
    cache[value] = view;
    for (final item in value) {
      backing.add(_cloneSnapshotValue(item, cache));
    }
    return view;
  }
  if (value is Map) {
    final cached = cache[value];
    if (cached != null) return cached;
    if (value.keys.every((key) => key is String)) {
      final backing = <String, dynamic>{};
      final view = UnmodifiableMapView<String, dynamic>(backing);
      cache[value] = view;
      for (final entry in value.entries) {
        backing[entry.key as String] = _cloneSnapshotValue(entry.value, cache);
      }
      return view;
    }
    final backing = <Object?, Object?>{};
    final view = UnmodifiableMapView<Object?, Object?>(backing);
    cache[value] = view;
    for (final entry in value.entries) {
      backing[entry.key] = _cloneSnapshotValue(entry.value, cache);
    }
    return view;
  }
  return value;
}

typedef SnapshotResultCopier<T> = T Function(T value);

/// Thrown when a typed collection cannot be rebuilt with its runtime type.
///
/// JSON containers and scalar-typed JSON collections are copied automatically.
/// Other reified collection types need the client's `copySnapshotResult`
/// callback to preserve their declared key/value types.
class SnapshotCopyException implements Exception {
  const SnapshotCopyException(this.resultType);

  final Type resultType;

  @override
  String toString() =>
      'Cannot publish a read-only $resultType snapshot without losing its '
      'collection type. Provide copySnapshotResult for typed collections.';
}

/// Copy [value] for publication while preserving its static type.
///
/// Use [copy] for other typed collection shapes. It must return an isolated,
/// read-only value. Opaque result objects keep their identity.
T cloneSnapshotResult<T>(T value, {SnapshotResultCopier<T>? copy}) {
  if (copy != null) return copy(value);
  final cloned = cloneSnapshotValue(value);
  if (cloned is T) return cloned;
  for (final copier in _jsonScalarCopiers) {
    final scalarCopy = copier(value);
    if (scalarCopy != null && scalarCopy is T) return scalarCopy as T;
  }
  throw SnapshotCopyException(value.runtimeType);
}

// JSON scalar collections retain their reified Dart types without a caller copier.
final _jsonScalarCopiers = <Object? Function(Object?)>[
  _copyJsonScalars<Null>,
  _copyJsonScalars<bool>,
  _copyJsonScalars<int>,
  _copyJsonScalars<double>,
  _copyJsonScalars<num>,
  _copyJsonScalars<String>,
  _copyJsonScalars<bool?>,
  _copyJsonScalars<int?>,
  _copyJsonScalars<double?>,
  _copyJsonScalars<num?>,
  _copyJsonScalars<String?>,
];

Object? _copyJsonScalars<T>(Object? value) {
  if (value is List<T>) return List<T>.unmodifiable(value);
  if (value is Map<String, T>) return Map<String, T>.unmodifiable(value);
  return null;
}

Object? _freezePlainData(Object? value) {
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_freezePlainData));
  }
  if (value is! Map) return value;
  final copy = <Object?, Object?>{};
  for (final entry in value.entries) {
    copy[entry.key] = _freezePlainData(entry.value);
  }
  return Map<Object?, Object?>.unmodifiable(copy);
}

/// Freeze a copy of one message part map.
///
/// Tool `input` / `output`, `source`, `approval`, tool-result `content`, and
/// subagent transcripts become read-only copies. Non-map values keep identity.
Map<String, dynamic> freezeSnapshotPart(
  Map<String, dynamic> part, [
  Map<Object, Object>? cache,
]) {
  final copy = Map<String, dynamic>.of(part);
  final source = part['source'];
  if (_isPlainObject(source)) {
    copy['source'] = Map<Object?, Object?>.unmodifiable(
      Map<Object?, Object?>.of(source as Map),
    );
  }
  final approval = part['approval'];
  if (part['type'] == 'tool-call' && _isPlainObject(approval)) {
    copy['approval'] = Map<Object?, Object?>.unmodifiable(
      Map<Object?, Object?>.of(approval as Map),
    );
  }
  final content = part['content'];
  if (part['type'] == 'tool-result' && content is List) {
    copy['content'] = List<Object?>.unmodifiable(
      content.map(
        (item) => item is Map<String, dynamic>
            ? freezeSnapshotPart(item, cache)
            : item,
      ),
    );
  }
  if (part.containsKey('input')) {
    copy['input'] = _freezePlainData(part['input']);
  }
  if (part.containsKey('output')) {
    copy['output'] = _freezePlainData(part['output']);
  }
  final subagent = part['subagent'];
  if (part['type'] == 'subagent' && _isPlainObject(subagent)) {
    final sub = Map<String, dynamic>.from(subagent as Map);
    final messages = sub['messages'];
    if (messages is List) {
      sub['messages'] = freezeSnapshotMessages(
        cache ?? <Object, Object>{},
        messages.whereType<Map<String, dynamic>>().toList(),
      );
    }
    copy['subagent'] = Map<String, dynamic>.unmodifiable(sub);
  }
  return Map<String, dynamic>.unmodifiable(copy);
}

T _cached<T extends Object>(
  Map<Object, Object> cache,
  T value,
  T Function(T value) freeze,
) {
  final frozen = cache[value];
  if (frozen is T) return frozen;
  final created = freeze(value);
  cache[value] = created;
  return created;
}

/// Freeze a copy of each message and its parts. Unchanged message and part
/// objects reuse their previously frozen copy.
List<Map<String, dynamic>> freezeSnapshotMessages(
  Map<Object, Object> cache,
  List<Map<String, dynamic>> messages,
) {
  return List<Map<String, dynamic>>.unmodifiable(
    messages.map(
      (message) => _cached(cache, message, (value) {
        final parts = value['parts'];
        final frozenParts = parts is List
            ? List<Map<String, dynamic>>.unmodifiable(
                parts.whereType<Map<String, dynamic>>().map(
                      (part) => _cached(
                        cache,
                        part,
                        (partValue) => freezeSnapshotPart(partValue, cache),
                      ),
                    ),
              )
            : parts;
        return Map<String, dynamic>.unmodifiable({
          ...value,
          'parts': frozenParts,
        });
      }),
    ),
  );
}

/// Merge a partial update into a map atom and make the result read-only.
/// Skips notify when every provided field is identical to the current value.
void patchAtom(
  Atom<Map<String, dynamic>> atom,
  Map<String, dynamic> patch,
) {
  atom.update((previous) {
    var changed = false;
    final next = Map<String, dynamic>.of(previous);
    for (final entry in patch.entries) {
      if (identical(previous[entry.key], entry.value)) continue;
      next[entry.key] = entry.value;
      changed = true;
    }
    return changed ? Map<String, dynamic>.unmodifiable(next) : previous;
  });
}

const int _maxListenerReentry = 8;

/// Subscribe to an atom with an unsubscribe function.
void Function() subscribeAtom<T>(Atom<T> atom, void Function() listener) {
  var running = false;
  final subscription = atom.subscribe(() {
    // A change made from inside the listener must not recurse into this same
    // subscriber. The loop below sees it, while other subscribers still run.
    if (running) return;
    running = true;
    try {
      var spins = 0;
      late T seen;
      do {
        seen = atom.get();
        try {
          listener();
        } catch (error, stackTrace) {
          reportListenerError(error, stackTrace);
        }
        spins++;
      } while (!identical(atom.get(), seen) && spins < _maxListenerReentry);
    } finally {
      running = false;
    }
  });
  return subscription.unsubscribe;
}
