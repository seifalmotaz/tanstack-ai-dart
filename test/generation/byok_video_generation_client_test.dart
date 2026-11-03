// Ported from `packages/ai-client/tests/byok-video-generation-client.test.ts`.
import 'package:tanstack_ai_dart/byok.dart' as byok;
import 'package:tanstack_ai_dart/connections.dart';
import 'package:tanstack_ai_dart/generation.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const elevenLabsKey = 'el-live-secret';
const videoResult = VideoGenerateResult(
  jobId: 'job-1',
  status: 'completed',
  url: 'https://example.com/v.mp4',
);

void main() {
  group('VideoGenerationClient byok', () {
    test('passes elevenlabs headers to the fetcher after updateOptions',
        () async {
      final clientByok = byok.ByokClient(
        byok.DefineByokOptions(storage: byok.memoryStorage()),
      );
      await clientByok.update('elevenlabs', elevenLabsKey);
      final calls = <Map<String, String>?>[];
      final client = VideoGenerationClient<VideoGenerateResult>(
        fetcher: (input, options) async {
          calls.add(options.headers);
          return videoResult;
        },
        byok: clientByok,
      );

      client.updateOptions(byokProvider: () => 'elevenlabs');
      await client.generate(const VideoGenerateInput(prompt: 'hello'));

      expect(calls.single, {'x-byok-elevenlabs': elevenLabsKey});
    });

    test('stamps headers on the connection runContext', () async {
      final clientByok = byok.ByokClient(
        byok.DefineByokOptions(storage: byok.memoryStorage()),
      );
      await clientByok.update('elevenlabs', elevenLabsKey);
      RunAgentInputContext? context;
      final connection = ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {
          context = runContext;
          yield runFinished('run-1');
        },
      );
      final client = VideoGenerationClient<VideoGenerateResult>(
        connection: connection,
        byok: clientByok,
        byokProvider: () => 'elevenlabs',
      );

      await client.generate(const VideoGenerateInput(prompt: 'hello'));

      expect(context?.headers, {'x-byok-elevenlabs': elevenLabsKey});
    });

    test('requests a missing key when the fetcher throws ByokMissingError',
        () async {
      final clientByok = byok.ByokClient(
        byok.DefineByokOptions(storage: byok.memoryStorage()),
      );
      await clientByok.update('elevenlabs', elevenLabsKey);
      final client = VideoGenerationClient<VideoGenerateResult>(
        fetcher: (input, options) async {
          throw byok.ByokMissingError('elevenlabs');
        },
        byok: clientByok,
        byokProvider: () => 'elevenlabs',
      );

      await client.generate(const VideoGenerateInput(prompt: 'hello'));

      expect(clientByok.getSnapshot().prompt?.provider, 'elevenlabs');
      expect(clientByok.getSnapshot().prompt?.reason, 'missing');
      expect(client.getError(), isA<byok.ByokMissingError>());
    });

    test('stops the failed run when the BYOK request subscriber stops',
        () async {
      final clientByok = byok.ByokClient(
        byok.DefineByokOptions(storage: byok.memoryStorage()),
      );
      await clientByok.update('elevenlabs', elevenLabsKey);
      final errors = <Object?>[];
      late VideoGenerationClient<VideoGenerateResult> client;
      client = VideoGenerationClient<VideoGenerateResult>(
        fetcher: (input, options) async {
          throw byok.ByokMissingError('elevenlabs');
        },
        byok: clientByok,
        byokProvider: () => 'elevenlabs',
        onErrorChange: errors.add,
      );
      clientByok.subscribe(() {
        if (clientByok.getSnapshot().prompt != null) client.stop();
      });

      await client.generate(const VideoGenerateInput(prompt: 'first'));

      expect(client.getStatus(), GenerationClientState.idle);
      expect(client.getError(), isNull);
      expect(errors.whereType<Object>(), isEmpty);
    });

    test('does not let a failed BYOK run overwrite a replacement', () async {
      final clientByok = byok.ByokClient(
        byok.DefineByokOptions(storage: byok.memoryStorage()),
      );
      await clientByok.update('elevenlabs', elevenLabsKey);
      final second = Deferred<Object?>();
      Future<void>? secondGenerate;
      var replaced = false;
      final client = VideoGenerationClient<VideoGenerateResult>(
        fetcher: (input, options) async {
          if (input.prompt == 'first') {
            throw byok.ByokMissingError('elevenlabs');
          }
          return second.promise;
        },
        byok: clientByok,
        byokProvider: () => 'elevenlabs',
      );
      clientByok.subscribe(() {
        if (clientByok.getSnapshot().prompt == null || replaced) return;
        replaced = true;
        client.stop();
        secondGenerate = client.generate(
          const VideoGenerateInput(prompt: 'second'),
        );
      });

      await client.generate(const VideoGenerateInput(prompt: 'first'));

      expect(client.getStatus(), GenerationClientState.generating);
      expect(client.getError(), isNull);
      second.resolve(videoResult);
      await secondGenerate;
    });

    test(
        'requests a missing key when the fetcher returns a byokMissing Response',
        () async {
      final clientByok = byok.ByokClient(
        byok.DefineByokOptions(storage: byok.memoryStorage()),
      );
      await clientByok.update('elevenlabs', elevenLabsKey);
      final client = VideoGenerationClient<VideoGenerateResult>(
        fetcher: (input, options) async =>
            GenerationResponse.byokMissing('elevenlabs'),
        byok: clientByok,
        byokProvider: () => 'elevenlabs',
      );

      await client.generate(const VideoGenerateInput(prompt: 'hello'));

      expect(clientByok.getSnapshot().prompt?.provider, 'elevenlabs');
      expect(clientByok.getSnapshot().prompt?.reason, 'missing');
    });

    test('does not call the fetcher when the provider key is missing',
        () async {
      final clientByok = byok.ByokClient();
      var calls = 0;
      final client = VideoGenerationClient<VideoGenerateResult>(
        fetcher: (input, options) async {
          calls++;
          return videoResult;
        },
        byok: clientByok,
        byokProvider: () => 'elevenlabs',
      );

      await client.generate(const VideoGenerateInput(prompt: 'hello'));

      expect(calls, 0);
      expect(client.getError(), isA<byok.ByokBlockedError>());
      expect(clientByok.getSnapshot().prompt?.provider, 'elevenlabs');
      expect(clientByok.getSnapshot().prompt?.reason, 'missing');
    });

    test('does not send every stored key when no provider resolves', () async {
      final clientByok = byok.ByokClient(
        byok.DefineByokOptions(storage: byok.memoryStorage()),
      );
      await clientByok.update('openai', 'sk-live-secret');
      await clientByok.update('elevenlabs', elevenLabsKey);
      var calls = 0;
      final client = VideoGenerationClient<VideoGenerateResult>(
        fetcher: (input, options) async {
          calls++;
          return videoResult;
        },
        byok: clientByok,
      );

      await client.generate(const VideoGenerateInput(prompt: 'hello'));

      expect(calls, 0);
      expect(client.getError(), isA<byok.ByokUnresolvedProviderError>());
    });
  });
}
