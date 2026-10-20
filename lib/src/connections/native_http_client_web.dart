import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

/// Real browser XHR client. Used when cookie credentials are requested (the
/// fetch-backed BrowserClient in package:http does not expose `credentials`)
/// and for the XHR-named adapters.
http.Client createNativeHttpClient({
  String? credentials,
  bool withCredentials = false,
  bool xhr = false,
}) {
  final includeCookies = withCredentials || credentials == 'include';
  if (!xhr && credentials == null && !withCredentials) return http.Client();
  return _XhrClient(includeCookies);
}

class _XhrClient extends http.BaseClient {
  final bool withCredentials;

  _XhrClient(this.withCredentials);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final xhr = web.XMLHttpRequest();
    final headersReady = Completer<void>();
    final controller = StreamController<List<int>>();
    var offset = 0;

    void enqueue() {
      final text = xhr.responseText;
      if (text.length <= offset) return;
      final delta = text.substring(offset);
      offset = text.length;
      controller.add(utf8.encode(delta));
    }

    void fail(Object error) {
      if (!headersReady.isCompleted) {
        headersReady.completeError(error);
      } else if (!controller.isClosed) {
        controller.addError(error);
        unawaited(controller.close());
      }
    }

    xhr.open(request.method, request.url.toString());
    xhr.withCredentials = withCredentials;
    request.headers.forEach((name, value) => xhr.setRequestHeader(name, value));
    if (request is http.Abortable && request.abortTrigger != null) {
      unawaited(request.abortTrigger!.then((_) => xhr.abort()));
    }
    xhr.onreadystatechange = ((web.Event _) {
      if (xhr.readyState >= 2 && !headersReady.isCompleted) {
        headersReady.complete();
      }
    }).toJS;
    xhr.onprogress = ((web.ProgressEvent _) => enqueue()).toJS;
    xhr.onload = ((web.ProgressEvent _) {
      enqueue();
      if (!headersReady.isCompleted) headersReady.complete();
      if (!controller.isClosed) unawaited(controller.close());
    }).toJS;
    xhr.onerror =
        ((web.ProgressEvent _) => fail(StateError('XHR request failed'))).toJS;
    xhr.onabort = ((web.ProgressEvent _) {
      if (!headersReady.isCompleted) {
        headersReady.completeError(StateError('XHR request aborted'));
      }
      if (!controller.isClosed) unawaited(controller.close());
    }).toJS;

    if (request is http.Request) {
      xhr.send(request.body.toJS);
    } else {
      xhr.send();
    }

    return headersReady.future.then((_) {
      return http.StreamedResponse(
        controller.stream,
        xhr.status,
        reasonPhrase: xhr.statusText,
        headers: _parseHeaders(xhr.getAllResponseHeaders()),
      );
    });
  }
}

Map<String, String> _parseHeaders(String raw) {
  final headers = <String, String>{};
  for (final line in raw.split(RegExp(r'\r?\n'))) {
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    headers[line.substring(0, colon).trim().toLowerCase()] =
        line.substring(colon + 1).trim();
  }
  return headers;
}
