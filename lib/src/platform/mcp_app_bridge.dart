import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Ported from `packages/ai-client/src/mcp-app-bridge.ts`.

class CreateMcpAppBridgeOptions {
  final String threadId;
  final String callEndpoint;
  final Future<void> Function(
    String content, [
    Map<String, dynamic>? body,
  ]) sendMessage;
  final http.Client? httpClient;
  final void Function(String url)? onLink;
  final void Function(String message)? logger;

  const CreateMcpAppBridgeOptions({
    required this.threadId,
    required this.callEndpoint,
    required this.sendMessage,
    this.httpClient,
    this.onLink,
    this.logger,
  });
}

class McpAppLinkResult {
  final bool isError;

  const McpAppLinkResult(this.isError);

  @override
  bool operator ==(Object other) =>
      other is McpAppLinkResult && other.isError == isError;

  @override
  int get hashCode => isError.hashCode;
}

class McpAppBridge {
  final CreateMcpAppBridgeOptions options;

  McpAppBridge(this.options);

  Future<Object?> callTool({
    String? serverId,
    required String toolName,
    Map<String, dynamic>? args,
    String? messageId,
  }) async {
    final body = <String, dynamic>{
      'threadId': options.threadId,
      if (serverId != null) 'serverId': serverId,
      'toolName': toolName,
      if (args != null) 'args': args,
      if (messageId != null) 'messageId': messageId,
    };

    final ownClient = options.httpClient == null ? http.Client() : null;
    final client = options.httpClient ?? ownClient!;
    try {
      final response = await client.post(
        Uri.parse(options.callEndpoint),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode(body),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'MCP app tool call failed: HTTP ${response.statusCode}',
        );
      }
      final raw = jsonDecode(response.body);
      if (raw is! Map || raw['ok'] is! bool) {
        throw StateError('MCP app tool call failed');
      }
      if (raw['ok'] != true) {
        final error = raw['error'];
        throw StateError(
          error is String && error.isNotEmpty
              ? error
              : 'MCP app tool call failed',
        );
      }
      return raw['result'];
    } finally {
      ownClient?.close();
    }
  }

  Future<void> sendPrompt(String text) => options.sendMessage(text);

  McpAppLinkResult openLink(String url) {
    if (!_isSafeLink(url)) {
      _log('[mcp-app-bridge] openLink rejected: unsupported URL scheme $url');
      return const McpAppLinkResult(true);
    }
    final onLink = options.onLink;
    if (onLink != null) {
      try {
        onLink(url);
        return const McpAppLinkResult(false);
      } catch (error) {
        _log('[mcp-app-bridge] openLink: onLink handler threw $error');
        return const McpAppLinkResult(true);
      }
    }
    _log('[mcp-app-bridge] openLink ignored: no onLink handler configured');
    return const McpAppLinkResult(true);
  }

  void _log(String message) {
    final logger = options.logger;
    if (logger != null) {
      logger(message);
    } else {
      Zone.current.print(message);
    }
  }
}

const Set<String> _safeLinkSchemes = {'http', 'https', 'mailto'};

bool _isSafeLink(String url) {
  final parsed = Uri.tryParse(url);
  if (parsed == null || parsed.scheme.isEmpty) return false;
  return _safeLinkSchemes.contains(parsed.scheme.toLowerCase());
}

McpAppBridge createMcpAppBridge(CreateMcpAppBridgeOptions options) =>
    McpAppBridge(options);
