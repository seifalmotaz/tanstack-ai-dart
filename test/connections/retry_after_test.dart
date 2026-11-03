import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:tanstack_ai_dart/connections.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  test('cancels an unread error body before retry', () async {
    var cancelled = false;
    final body = StreamController<List<int>>(onCancel: () => cancelled = true);
    final response = http.StreamedResponse(body.stream, 503);
    await expectLater(
        assertResponseOk(response), throwsA(isA<HttpStatusException>()));
    expect(cancelled, isTrue);
  });
  test('parses Retry-After seconds, dates, and invalid values', () async {
    Future<Duration?> retry(String value) async {
      try {
        await assertResponseOk(
            rawResponse('', status: 503, headers: {'retry-after': value}));
      } on HttpStatusException catch (error) {
        return error.retryAfter;
      }
      fail('expected a status error');
    }

    expect(await retry('1.5'), const Duration(milliseconds: 1500));
    expect(await retry('Sun, 06 Nov 1994 08:49:37 GMT'), Duration.zero);
    expect(await retry('Wed, 01 Jan 2099 00:00:00 GMT'),
        greaterThan(Duration.zero));
    expect(await retry('-1'), isNull);
    expect(await retry('invalid'), isNull);
    expect(await retry('1e300'), isNotNull);
  });
}
