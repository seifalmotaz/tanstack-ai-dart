import 'dart:convert';
import 'dart:io';

/// Run real cross-origin XHR/cookie/cancellation checks in Chrome.
Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    try {
      final response = request.response;
      response.headers.set('Access-Control-Allow-Origin',
          request.headers.value('origin') ?? '*');
      response.headers.set('Access-Control-Allow-Credentials', 'true');
      response.headers.set(
          'Access-Control-Allow-Headers',
          request.headers.value('access-control-request-headers') ??
              'content-type');
      response.headers
          .set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      response.headers.set('Access-Control-Allow-Private-Network', 'true');
      if (request.method == 'OPTIONS') {
        response.statusCode = 204;
        await response.close();
        return;
      }
      await request.drain<void>();
      if (request.uri.path == '/slow') {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      if (request.uri.path == '/set-cookie') {
        response.headers
            .add('Set-Cookie', 'sdk-browser=test; Path=/; SameSite=Lax');
      }
      response.write('data: ${jsonEncode({
            'type': 'CUSTOM',
            'name': 'browser',
            'cookie': request.headers.value('cookie') ?? '',
            'text': 'عميل مصري 🏡'
          })}\n\n');
      await response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      response.write(
          'data: ${jsonEncode({'type': 'RUN_FINISHED', 'runId': 'run'})}\n\n');
      await response.close();
    } on HttpException {
      // An aborted browser request may close the socket before headers.
    } on SocketException {
      // Expected when the browser aborts an in-flight request.
    }
  });
  final test = File('.dart_tool/browser_http_test.dart');
  await test.writeAsString((await File('tool/fixtures/browser_http.dart')
          .readAsString())
      .replaceAll('BROWSER_HTTP_ENDPOINT', 'http://localhost:${server.port}'));
  try {
    final process = await Process.start(Platform.resolvedExecutable,
        ['test', test.path, '--platform', 'chrome', '--reporter', 'expanded']);
    await Future.wait(
        [stdout.addStream(process.stdout), stderr.addStream(process.stderr)]);
    exitCode = await process.exitCode;
  } finally {
    await server.close(force: true);
    await test.delete();
  }
}
