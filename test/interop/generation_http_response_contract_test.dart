import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';
import 'package:test/test.dart';

void main() {
  test('HTTP generation responses preserve BYOK 401 errors', () async {
    final client = GenerationClient<Object?, Object?, Object?>(
      fetcher: (_, options) async => http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode({
          'error': {
            'type': 'byok_missing',
            'provider': 'openai',
            'message': 'Missing openai API key'
          }
        }))),
        401,
      ),
    );
    addTearDown(client.dispose);
    await client.generate(null);
    expect(client.getError(), isA<ByokMissingError>());
    expect((client.getError() as ByokMissingError).provider, 'openai');
    expect(client.getIsLoading(), isFalse);
  });

  test('HTTP generation errors do not become successful SSE runs', () async {
    final client = GenerationClient<Object?, Object?, Object?>(
      fetcher: (_, options) async => http.StreamedResponse(
        Stream.value(utf8.encode('service unavailable')),
        503,
        reasonPhrase: 'Service Unavailable',
      ),
    );
    addTearDown(client.dispose);
    await client.generate(null);
    expect(client.getError(), isA<HttpStatusException>());
    expect(client.getStatus(), GenerationClientState.error);
    expect(client.getIsLoading(), isFalse);
  });
}
