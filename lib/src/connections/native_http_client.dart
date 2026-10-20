/// Platform-selected HTTP client used when the caller does not inject one.
///
/// The VM uses `package:http`'s IO client. On the web, the adapter uses
/// `package:web`'s XMLHttpRequest seam when cookie credentials are requested
/// or when the XHR-named adapter is used; otherwise it uses the default
/// `package:http` client (which is fetch-backed in 1.6, not XHR).
library;

export 'native_http_client_stub.dart'
    if (dart.library.js_interop) 'native_http_client_web.dart';
