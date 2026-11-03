/// Controls when accumulated streamed text should notify consumers.
abstract class ChunkStrategy {
  bool shouldEmit(String chunk, String accumulated);
  void reset() {}
}

class ImmediateStrategy extends ChunkStrategy {
  @override
  bool shouldEmit(String chunk, String accumulated) => true;
}

class PunctuationStrategy extends ChunkStrategy {
  static final _punctuation = RegExp(r'[.,!?;:\n]');

  @override
  bool shouldEmit(String chunk, String accumulated) =>
      _punctuation.hasMatch(chunk);
}

class BatchStrategy extends ChunkStrategy {
  final int batchSize;
  int _count = 0;

  BatchStrategy([this.batchSize = 5]);

  @override
  bool shouldEmit(String chunk, String accumulated) {
    if (++_count >= batchSize) {
      _count = 0;
      return true;
    }
    return false;
  }

  @override
  void reset() => _count = 0;
}

class WordBoundaryStrategy extends ChunkStrategy {
  static final _whitespace = RegExp(r'\s$');

  @override
  bool shouldEmit(String chunk, String accumulated) =>
      _whitespace.hasMatch(chunk);
}

class CompositeStrategy extends ChunkStrategy {
  final List<ChunkStrategy> strategies;

  CompositeStrategy(this.strategies);

  @override
  bool shouldEmit(String chunk, String accumulated) =>
      strategies.any((strategy) => strategy.shouldEmit(chunk, accumulated));

  @override
  void reset() {
    for (final strategy in strategies) {
      strategy.reset();
    }
  }
}
