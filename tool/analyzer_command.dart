import 'dart:io';

/// Recent SDKs can suppress telemetry for a single command. The minimum SDK
/// rejects that flag, so leave its analyzer invocation unchanged.
List<String> analyzerArguments(List<String> arguments) {
  final version = Platform.version.split(' ').first.split('.');
  final major = int.parse(version[0]);
  final minor = int.parse(version[1]);
  return [
    if (major > 3 || major == 3 && minor >= 13) '--suppress-analytics',
    'analyze',
    ...arguments,
  ];
}
