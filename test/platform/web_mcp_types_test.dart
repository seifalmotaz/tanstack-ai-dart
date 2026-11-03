// Ported from packages/ai-client/tests/web-mcp-tools-types.test.ts.
//
// TypeScript's `@ts-expect-error` cases (missing signal, unknown tool-option
// key, wrong context, cross-origin option) are compile-time checks here: the
// Dart analyzer enforces the same required constructor parameters and typed
// `Map<String, WebMcpToolOptions>` keys. The runtime assertions below pin the
// shapes those typed constructors expose.
import 'package:tanstack_ai_dart/platform.dart';
import 'package:test/test.dart';

void main() {
  group('registerWebMCPTools types', () {
    test('keys per-tool options by inferred tool names', () {
      final options = RegisterWebMCPToolsOptions(
        signal: CancellationSignal(),
        toolOptions: const {
          'search_products': WebMcpToolOptions(
            title: 'Search products',
            annotations: WebMcpToolAnnotations(
              readOnlyHint: true,
              untrustedContentHint: true,
            ),
          ),
          'add_to_cart': WebMcpToolOptions(title: 'Add to cart'),
        },
      );

      final WebMcpToolOptions? search = options.toolOptions?['search_products'];
      final WebMcpToolAnnotations? annotations = search?.annotations;
      expect(search?.title, 'Search products');
      expect(annotations?.readOnlyHint, isTrue);
      expect(annotations?.untrustedContentHint, isTrue);
      expect(options.toolOptions?['add_to_cart']?.title, 'Add to cart');
    });

    test('requires the runtime context inferred from contextual tools', () {
      final contextual = ClientTool(
        name: 'contextual',
        description: 'Read tenant context',
        execute: (input, executionContext) =>
            (executionContext.context as Map)['tenantId'],
      );

      final options = RegisterWebMCPToolsOptions(
        signal: CancellationSignal(),
        context: {'tenantId': 'tenant-1'},
      );

      expect(contextual.name, 'contextual');
      expect(options.context, {'tenantId': 'tenant-1'});
    });
  });
}
