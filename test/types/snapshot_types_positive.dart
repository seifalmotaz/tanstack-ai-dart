import 'package:tanstack_ai_dart/generation.dart';

void main() {
  GenerationClient<String, Map<String, int>, Map<String, int>>.legacy(
    copySnapshotResult: (value) => Map<String, int>.unmodifiable(value),
  );
  GenerationClient<String, List<int>, List<int>>.legacy(
    copySnapshotResult: (value) => List<int>.unmodifiable(value),
  );
  VideoGenerationClient<Map<String, int>>.legacy(
    copySnapshotResult: (value) => Map<String, int>.unmodifiable(value),
  );
}
