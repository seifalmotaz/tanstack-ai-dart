// Positive analyzer fixture for the ported WebMCP registration options.
//
// Mirrors the compile-time cases in upstream
// `packages/ai-client/tests/web-mcp-tools-types.test.ts` that Dart can express:
// required signal, typed tool options, typed annotations and the `Object?`
// context slot.
//
// Not representable here (see `web_mcp_negative.dart` and
// `test/interop/web_mcp_type_mapping.json`):
// - per-tool option keys constrained to the inferred tool-name union
// - context required/inferred from contextual tools
//
// This file only needs to analyze cleanly; it is not executed.
// ignore_for_file: unused_local_variable
import 'dart:async';

import 'package:tanstack_ai_dart/platform.dart';

void positiveCases() {
  final signal = CancellationSignal();

  final options = RegisterWebMCPToolsOptions(
    signal: signal,
    toolOptions: const <String, WebMcpToolOptions>{
      'search_products': WebMcpToolOptions(
        title: 'Search products',
        annotations: WebMcpToolAnnotations(
          readOnlyHint: true,
          untrustedContentHint: true,
        ),
      ),
      'add_to_cart': WebMcpToolOptions(title: 'Add to cart'),
    },
    // Dart deliberately types this as Object?; it cannot infer a context shape
    // from ClientTool.execute. The upstream contextual-tool check is not
    // representable.
    context: const <String, Object?>{'tenantId': 'tenant-1'},
  );

  final WebMcpToolOptions? search = options.toolOptions?['search_products'];
  final WebMcpToolAnnotations? annotations = search?.annotations;
  final bool? readOnly = annotations?.readOnlyHint;
  final bool? untrusted = annotations?.untrustedContentHint;
  final Object? context = options.context;

  final tools = <ClientTool>[
    ClientTool(
      name: 'search_products',
      description: 'Search products',
      execute: (input, executionContext) async => const <Object?>[],
    ),
    ClientTool(
      name: 'add_to_cart',
      description: 'Add a product to the cart',
      execute: (input, executionContext) async =>
          const <String, Object?>{'ok': true},
    ),
  ];

  unawaited(registerWebMCPTools(tools, options));

  assert(!signal.isAborted);
  assert(search?.title == 'Search products');
  assert(readOnly == true);
  assert(untrusted == true);
  assert(context is Map);
}
