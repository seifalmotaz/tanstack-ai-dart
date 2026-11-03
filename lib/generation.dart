/// Standalone barrel for the pure-Dart port of TanStack AI client's
/// generation surfaces.
///
/// The canonical connection adapters and BYOK store are re-used from the
/// sibling `connections.dart` / `byok.dart` libraries rather than duplicated.
library;

export 'src/generation/generation_client.dart';
export 'src/generation/generation_devtools_port.dart';
export 'src/generation/generation_reconstruct.dart';
export 'src/generation/generation_types.dart' hide validateGenerationThreadId;
export 'src/generation/video_generation_client.dart';

export 'src/platform/snapshot_atom.dart'
    show SnapshotResultCopier, SnapshotCopyException;
