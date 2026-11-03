// Negative analyzer fixture for the ported WebMCP registration options.
//
// Every `expect-error` line must produce the named analyzer diagnostic. Run:
//   dart run tool/verify_types.dart
//
// These are the upstream compile-time restrictions that Dart can model:
// - lifecycle signal is required and typed CancellationSignal
// - per-tool option values are WebMcpToolOptions
// - annotations are WebMcpToolAnnotations with bool hints
// - unknown option/annotation fields are rejected
// - cross-origin `exposedTo` is not exposed
// - registerWebMCPTools takes List<ClientTool> and options
//
// Not representable (documented in test/interop/web_mcp_type_mapping.json):
// - constraining toolOptions keys to the inferred tool-name union
// - inferring/requiring context from contextual tools
// ignore_for_file: unused_local_variable, unused_element
import 'package:tanstack_ai_dart/platform.dart';

void negativeCases() {
  final signal = CancellationSignal();

  // Upstream: signal is required.
  // expect-error: MISSING_REQUIRED_ARGUMENT
  RegisterWebMCPToolsOptions();

  // Upstream: signal is an AbortSignal analog, not a string.
  // expect-error: ARGUMENT_TYPE_NOT_ASSIGNABLE
  RegisterWebMCPToolsOptions(signal: 'not-a-signal');

  // Upstream: cross-origin exposure is not supported.
  // expect-error: UNDEFINED_NAMED_PARAMETER
  RegisterWebMCPToolsOptions(
    signal: signal,
    exposedTo: <String>['https://agent.example'],
  );

  // Upstream: per-tool options values are WebMCPToolOptions.
  // expect-error: MAP_VALUE_TYPE_NOT_ASSIGNABLE
  RegisterWebMCPToolsOptions(
    signal: signal,
    toolOptions: <String, WebMcpToolOptions>{
      'search_products': 'wrong-value',
    },
  );

  // Upstream: annotations.readOnlyHint is a boolean hint.
  // expect-error: ARGUMENT_TYPE_NOT_ASSIGNABLE
  RegisterWebMCPToolsOptions(
    signal: signal,
    toolOptions: <String, WebMcpToolOptions>{
      'search_products': WebMcpToolOptions(
        title: 'Search products',
        annotations: WebMcpToolAnnotations(readOnlyHint: 'true'),
      ),
    },
  );

  // Upstream: WebMCPToolOptions exposes only title and annotations.
  // expect-error: UNDEFINED_NAMED_PARAMETER
  RegisterWebMCPToolsOptions(
    signal: signal,
    toolOptions: <String, WebMcpToolOptions>{
      'search_products': WebMcpToolOptions(unknownOption: true),
    },
  );

  // Upstream: annotations exposes only the two documented hints.
  // expect-error: UNDEFINED_NAMED_PARAMETER
  RegisterWebMCPToolsOptions(
    signal: signal,
    toolOptions: <String, WebMcpToolOptions>{
      'search_products': WebMcpToolOptions(
        annotations: WebMcpToolAnnotations(unknownHint: true),
      ),
    },
  );

  // Upstream: title is a string.
  // expect-error: ARGUMENT_TYPE_NOT_ASSIGNABLE
  RegisterWebMCPToolsOptions(
    signal: signal,
    toolOptions: <String, WebMcpToolOptions>{
      'search_products': WebMcpToolOptions(title: 7),
    },
  );

  // The registration call accepts the typed ClientTool list, not Object.
  // expect-error: ARGUMENT_TYPE_NOT_ASSIGNABLE
  registerWebMCPTools(<Object>[], RegisterWebMCPToolsOptions(signal: signal));

  // Options are required by registerWebMCPTools.
  // expect-error: NOT_ENOUGH_POSITIONAL_ARGUMENTS
  registerWebMCPTools(<ClientTool>[]);
}
