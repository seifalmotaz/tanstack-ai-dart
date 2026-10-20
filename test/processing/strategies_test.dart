// Ported from @tanstack/ai 0.70.0 tests/strategies.test.ts.
import 'package:test/test.dart';
import 'package:tanstack_ai_dart/processing.dart';

class _Fixed extends ChunkStrategy {
  final bool value;
  _Fixed(this.value);
  @override
  bool shouldEmit(String chunk, String accumulated) => value;
}

void main() {
  group('Chunk Strategies', () {
    group('ImmediateStrategy', () {
      test('should always return true', () {
        final strategy = ImmediateStrategy();
        expect(strategy.shouldEmit('', ''), true);
        expect(strategy.shouldEmit('hello', 'hello'), true);
        expect(strategy.shouldEmit('world', 'hello world'), true);
      });

      test('should work with empty strings', () {
        final strategy = ImmediateStrategy();
        expect(strategy.shouldEmit('', ''), true);
        expect(strategy.shouldEmit('', 'accumulated'), true);
      });
    });

    group('PunctuationStrategy', () {
      test('should emit when chunk contains punctuation', () {
        final strategy = PunctuationStrategy();
        expect(strategy.shouldEmit('Hello.', 'Hello.'), true);
        expect(strategy.shouldEmit('World!', 'Hello. World!'), true);
        expect(strategy.shouldEmit('How?', 'Hello. World! How?'), true);
        expect(strategy.shouldEmit('Test;', 'Test;'), true);
        expect(strategy.shouldEmit('Test:', 'Test:'), true);
      });

      test('should not emit when chunk has no punctuation', () {
        final strategy = PunctuationStrategy();
        expect(strategy.shouldEmit('Hello', 'Hello'), false);
        expect(strategy.shouldEmit('world', 'Hello world'), false);
        expect(strategy.shouldEmit('test', 'Hello world test'), false);
      });

      test('should emit on newline', () {
        final strategy = PunctuationStrategy();
        expect(strategy.shouldEmit('Line 1\n', 'Line 1\n'), true);
        expect(strategy.shouldEmit('\nLine 2', 'Line 1\n\nLine 2'), true);
      });

      test('should emit on comma', () {
        final strategy = PunctuationStrategy();
        expect(strategy.shouldEmit('Hello,', 'Hello,'), true);
        expect(strategy.shouldEmit('world,', 'Hello, world,'), true);
      });

      test('should handle punctuation in middle of chunk', () {
        final strategy = PunctuationStrategy();
        expect(strategy.shouldEmit('Hello.world', 'Hello.world'), true);
        expect(strategy.shouldEmit('test!more', 'test!more'), true);
      });
    });

    group('BatchStrategy', () {
      test('should emit every N chunks', () {
        final strategy = BatchStrategy(3);
        expect(strategy.shouldEmit('chunk1', 'chunk1'), false);
        expect(strategy.shouldEmit('chunk2', 'chunk1chunk2'), false);
        expect(strategy.shouldEmit('chunk3', 'chunk1chunk2chunk3'), true);
        expect(
            strategy.shouldEmit('chunk4', 'chunk1chunk2chunk3chunk4'), false);
        expect(strategy.shouldEmit('chunk5', 'chunk1chunk2chunk3chunk4chunk5'),
            false);
        expect(
            strategy.shouldEmit(
                'chunk6', 'chunk1chunk2chunk3chunk4chunk5chunk6'),
            true);
      });

      test('should use default batch size of 5', () {
        final strategy = BatchStrategy();
        expect(strategy.shouldEmit('chunk1', 'chunk1'), false);
        expect(strategy.shouldEmit('chunk2', 'chunk1chunk2'), false);
        expect(strategy.shouldEmit('chunk3', 'chunk1chunk2chunk3'), false);
        expect(
            strategy.shouldEmit('chunk4', 'chunk1chunk2chunk3chunk4'), false);
        expect(strategy.shouldEmit('chunk5', 'chunk1chunk2chunk3chunk4chunk5'),
            true);
      });

      test('should reset counter after emitting', () {
        final strategy = BatchStrategy(2);
        expect(strategy.shouldEmit('chunk1', 'chunk1'), false);
        expect(strategy.shouldEmit('chunk2', 'chunk1chunk2'), true);

        expect(strategy.shouldEmit('chunk3', 'chunk1chunk2chunk3'), false);
        expect(strategy.shouldEmit('chunk4', 'chunk1chunk2chunk3chunk4'), true);
      });

      test('should work with batch size of 1', () {
        final strategy = BatchStrategy(1);
        expect(strategy.shouldEmit('chunk1', 'chunk1'), true);
        expect(strategy.shouldEmit('chunk2', 'chunk1chunk2'), true);
        expect(strategy.shouldEmit('chunk3', 'chunk1chunk2chunk3'), true);
      });

      test('should reset method reset counter', () {
        final strategy = BatchStrategy(3);
        expect(strategy.shouldEmit('chunk1', 'chunk1'), false);
        expect(strategy.shouldEmit('chunk2', 'chunk1chunk2'), false);
        strategy.reset();
        expect(strategy.shouldEmit('chunk3', 'chunk1chunk2chunk3'), false);
        expect(
            strategy.shouldEmit('chunk4', 'chunk1chunk2chunk3chunk4'), false);
        expect(strategy.shouldEmit('chunk5', 'chunk1chunk2chunk3chunk4chunk5'),
            true);
      });
    });

    group('WordBoundaryStrategy', () {
      test('should emit when chunk ends with whitespace', () {
        final strategy = WordBoundaryStrategy();
        expect(strategy.shouldEmit('Hello ', 'Hello '), true);
        expect(strategy.shouldEmit('world ', 'Hello world '), true);
        expect(strategy.shouldEmit('test\n', 'Hello world test\n'), true);
        expect(strategy.shouldEmit('more\t', 'Hello world test\nmore\t'), true);
      });

      test('should not emit when chunk does not end with whitespace', () {
        final strategy = WordBoundaryStrategy();
        expect(strategy.shouldEmit('Hello', 'Hello'), false);
        expect(strategy.shouldEmit('world', 'Helloworld'), false);
        expect(strategy.shouldEmit('test', 'Helloworldtest'), false);
      });

      test('should emit on space', () {
        final strategy = WordBoundaryStrategy();
        expect(strategy.shouldEmit('word ', 'word '), true);
      });

      test('should emit on newline', () {
        final strategy = WordBoundaryStrategy();
        expect(strategy.shouldEmit('line\n', 'line\n'), true);
        expect(strategy.shouldEmit('\n', 'line\n\n'), true);
      });

      test('should emit on tab', () {
        final strategy = WordBoundaryStrategy();
        expect(strategy.shouldEmit('word\t', 'word\t'), true);
      });

      test('should not emit on punctuation without whitespace', () {
        final strategy = WordBoundaryStrategy();
        expect(strategy.shouldEmit('Hello.', 'Hello.'), false);
        expect(strategy.shouldEmit('World!', 'Hello.World!'), false);
      });

      test('should emit on whitespace even if punctuation present', () {
        final strategy = WordBoundaryStrategy();
        expect(strategy.shouldEmit('Hello. ', 'Hello. '), true);
        expect(strategy.shouldEmit('World! ', 'Hello. World! '), true);
      });
    });

    group('CompositeStrategy', () {
      test('should emit if any strategy says to emit (OR logic)', () {
        final immediate = ImmediateStrategy();
        final punctuation = PunctuationStrategy();
        final strategy = CompositeStrategy([immediate, punctuation]);
        expect(strategy.shouldEmit('hello', 'hello'), true);
        expect(strategy.shouldEmit('world', 'hello world'), true);
      });

      test('should emit if first strategy says yes, even if others say no', () {
        final batch = BatchStrategy(10);
        final punctuation = PunctuationStrategy();
        final strategy = CompositeStrategy([punctuation, batch]);
        expect(strategy.shouldEmit('Hello.', 'Hello.'), true);
      });

      test('should emit if any strategy says yes', () {
        final batch = BatchStrategy(10);
        final wordBoundary = WordBoundaryStrategy();
        final strategy = CompositeStrategy([batch, wordBoundary]);
        expect(strategy.shouldEmit('Hello ', 'Hello '), true);
      });

      test('should not emit if all strategies say no', () {
        final batch = BatchStrategy(10);
        final wordBoundary = WordBoundaryStrategy();
        final strategy = CompositeStrategy([batch, wordBoundary]);
        expect(strategy.shouldEmit('Hello', 'Hello'), false);
        expect(strategy.shouldEmit('world', 'Helloworld'), false);
      });

      test('should work with single strategy', () {
        final punctuation = PunctuationStrategy();
        final strategy = CompositeStrategy([punctuation]);
        expect(strategy.shouldEmit('Hello.', 'Hello.'), true);
        expect(strategy.shouldEmit('world', 'Hello. world'), false);
      });

      test('should work with empty strategies array', () {
        final strategy = CompositeStrategy([]);
        expect(strategy.shouldEmit('hello', 'hello'), false);
      });

      test('should reset all strategies that have reset method', () {
        final batch1 = BatchStrategy(3);
        final batch2 = BatchStrategy(5);
        final strategy = CompositeStrategy([batch1, batch2]);
        strategy.shouldEmit('chunk1', 'chunk1');
        strategy.shouldEmit('chunk2', 'chunk1chunk2');

        strategy.reset();
        expect(strategy.shouldEmit('chunk3', 'chunk1chunk2chunk3'), false);
        expect(
            strategy.shouldEmit('chunk4', 'chunk1chunk2chunk3chunk4'), false);
        expect(strategy.shouldEmit('chunk5', 'chunk1chunk2chunk3chunk4chunk5'),
            true);
      });

      test('should handle multiple strategies with different behaviors', () {
        final batch = BatchStrategy(10);
        final punctuation = PunctuationStrategy();
        final wordBoundary = WordBoundaryStrategy();
        final strategy = CompositeStrategy([batch, punctuation, wordBoundary]);
        expect(strategy.shouldEmit('Hello', 'Hello'), false);
        expect(strategy.shouldEmit('Hello.', 'Hello.'), true);
        expect(strategy.shouldEmit('world ', 'Hello. world '), true);
        expect(strategy.shouldEmit('test', 'Hello. world test'), false);
        expect(strategy.shouldEmit('more', 'Hello. world testmore'), false);
        expect(strategy.shouldEmit('!', 'Hello. world testmore!'), true);
      });

      test('should short-circuit on first true', () {
        final strategy1 = _Fixed(true);
        final strategy2 = _Fixed(false);
        final strategy3 = _Fixed(false);
        final strategy = CompositeStrategy([strategy1, strategy2, strategy3]);
        final result = strategy.shouldEmit('test', 'test');
        expect(result, true);
      });
    });

    group('Strategy edge cases', () {
      test('should handle empty chunks', () {
        final immediate = ImmediateStrategy();
        final punctuation = PunctuationStrategy();
        final wordBoundary = WordBoundaryStrategy();
        expect(immediate.shouldEmit('', ''), true);
        expect(punctuation.shouldEmit('', ''), false);
        expect(wordBoundary.shouldEmit('', ''), false);
      });

      test('should handle very long accumulated strings', () {
        final batch = BatchStrategy(3);
        final longAccumulated = List.filled(10000, 'a').join();
        expect(batch.shouldEmit('chunk1', '${longAccumulated}chunk1'), false);
        expect(batch.shouldEmit('chunk2', '${longAccumulated}chunk1chunk2'),
            false);
        expect(
            batch.shouldEmit('chunk3', '${longAccumulated}chunk1chunk2chunk3'),
            true);
      });

      test('should handle unicode characters', () {
        final punctuation = PunctuationStrategy();
        final wordBoundary = WordBoundaryStrategy();
        expect(punctuation.shouldEmit('Hello 世界.', 'Hello 世界.'), true);
        expect(wordBoundary.shouldEmit('世界 ', 'Hello 世界 '), true);
        expect(wordBoundary.shouldEmit('世界', 'Hello 世界'), false);
      });
    });
  });
}
