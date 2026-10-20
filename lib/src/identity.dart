import 'dart:math';

final _random = Random.secure();
final _seed = List.generate(2,
        (_) => _random.nextInt(0x100000000).toRadixString(36).padLeft(7, '0'))
    .join();
int _sequence = 0;

/// Unique within an isolate, with independent entropy across clients/isolates.
String generateIdentity(String prefix) =>
    '$prefix-${DateTime.now().millisecondsSinceEpoch}-'
    '$_seed${(_sequence++).toRadixString(36)}';
