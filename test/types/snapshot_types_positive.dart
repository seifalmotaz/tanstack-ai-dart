import 'package:tanstack_ai_dart/generation.dart';

void main() {
  GenerationClient<String, Map<String, int>, Map<String, int>>(
    copySnapshotResult: (value) => Map<String, int>.unmodifiable(value),
  );
  GenerationClient<String, List<int>, List<int>>(
    copySnapshotResult: (value) => List<int>.unmodifiable(value),
  );
  VideoGenerationClient<Map<String, int>>(
    copySnapshotResult: (value) => Map<String, int>.unmodifiable(value),
  );
}
