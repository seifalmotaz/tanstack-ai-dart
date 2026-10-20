import 'package:http/http.dart' as http;

/// VM/native fallback. Cookies are managed by the host HTTP stack; Dart has no
/// per-request credentials switch, so these options are deliberately inert.
http.Client createNativeHttpClient({
  String? credentials,
  bool withCredentials = false,
  bool xhr = false,
}) =>
    http.Client();
