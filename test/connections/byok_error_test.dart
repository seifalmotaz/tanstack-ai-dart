// Ported BYOK-401 behavior from connection-adapters' assertResponseOk /
// errorFromXhrStatus. Uses the canonical platform error so the keyring client
// and the HTTP adapters share one exception type.
import 'package:tanstack_ai_dart/byok.dart' as byok;
import 'package:tanstack_ai_dart/connections.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

Map<String, dynamic> body({
  String type = 'byok_missing',
  String provider = 'custom',
  String? message = 'Missing custom API key',
}) =>
    {
      'error': {
        'type': type,
        'provider': provider,
        if (message != null) 'message': message,
      },
    };

void main() {
  test('401 BYOK body raises the canonical ByokMissingError', () async {
    final client = FakeHttpClient(
      (_) async => jsonResponse(body(), status: 401),
    );
    final adapter = fetchServerSentEvents(
      '/api/chat',
      FetchConnectionOptions(client: client),
    );

    await expectLater(
      collect(adapter.connect!([])),
      throwsA(
        isA<byok.ByokMissingError>().having(
          (error) => error.provider,
          'provider',
          'custom',
        ),
      ),
    );
  });

  test('401 XHR BYOK body raises the canonical ByokMissingError', () async {
    final client = FakeHttpClient(
      (_) async => jsonResponse(body(provider: 'openai'), status: 401),
    );
    final adapter = xhrServerSentEvents(
      '/api/chat',
      XhrConnectionOptions(client: client),
    );

    await expectLater(
      collect(adapter.connect!([])),
      throwsA(
        isA<byok.ByokMissingError>().having(
          (error) => error.provider,
          'provider',
          'openai',
        ),
      ),
    );
  });

  test('invalid provider regex is treated as a generic 401', () async {
    final client = FakeHttpClient(
      (_) async => jsonResponse(body(provider: 'Not A Slug'), status: 401),
    );
    final adapter = fetchServerSentEvents(
      '/api/chat',
      FetchConnectionOptions(client: client),
    );

    final error = await captureError(() => collect(adapter.connect!([])));
    expect(error, isA<HttpStatusException>());
    expect(error, isNot(isA<byok.ByokMissingError>()));
  });

  test('missing message string is treated as a generic 401', () async {
    final client = FakeHttpClient(
      (_) async => jsonResponse(body(message: null), status: 401),
    );
    final adapter = fetchServerSentEvents(
      '/api/chat',
      FetchConnectionOptions(client: client),
    );

    final error = await captureError(() => collect(adapter.connect!([])));
    expect(error, isA<HttpStatusException>());
  });
}
