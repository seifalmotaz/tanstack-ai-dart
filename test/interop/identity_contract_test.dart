@TestOn('vm')
library;

import 'dart:isolate';

import 'package:tanstack_ai_dart/src/identity.dart';
import 'package:test/test.dart';

void main() {
  test('run and message identities stay unique across isolates', () async {
    final batches = await Future.wait(List.generate(
        4,
        (_) => Isolate.run(
            () => List.generate(1000, (_) => generateIdentity('msg')))));
    final ids = batches.expand((batch) => batch).toList();
    expect(ids.toSet().length, ids.length);
    expect(ids.every((id) => id.startsWith('msg-')), isTrue);
  });
}
