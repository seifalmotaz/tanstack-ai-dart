import 'dart:async';

import 'package:tanstack_ai_dart/src/snapshot_stream.dart';
import 'package:test/test.dart';

void main() {
  test(
      'each listener starts current, buffers independently and cancels independently',
      () async {
    var current = 0;
    final state = SnapshotStream(() => current);
    final first = <int>[];
    final a = state.stream.listen(first.add)..pause();
    current = 1;
    state.emit(current);
    final second = <int>[];
    final b = state.stream.listen(second.add);
    current = 2;
    state.emit(current);
    await Future<void>.delayed(Duration.zero);
    expect(second, [1, 2]);
    expect(first, isEmpty);
    a.resume();
    await Future<void>.delayed(Duration.zero);
    expect(first, [0, 1, 2]);
    await a.cancel();
    current = 3;
    state.emit(current);
    state.close();
    state.close();
    await Future<void>.delayed(Duration.zero);
    expect(second, [1, 2, 3]);
    expect(first, [0, 1, 2]);
    await b.cancel();
    expect(await state.stream.toList(), isEmpty);
  });
}
