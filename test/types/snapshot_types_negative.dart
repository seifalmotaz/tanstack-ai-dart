import 'package:tanstack_ai_dart/generation.dart';

void invalidCopiers() {
  GenerationClient<String, Map<String, int>, Map<String, int>>(
    // expect-error: return_of_invalid_type_from_closure
    copySnapshotResult: (value) => <int>[],
  );
  VideoGenerationClient<List<int>>(
    // expect-error: return_of_invalid_type_from_closure
    copySnapshotResult: (value) => <String, int>{},
  );
}
