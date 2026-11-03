/// Unofficial Dart client for TanStack AI, with legacy transport compatibility.
library;

export 'chat.dart';
export 'connections.dart'
    hide
        ChatHydrationResult,
        normalizeMessageDates,
        tanstackMetadata,
        withTanstackMetadata;
export 'generation.dart';
export 'platform.dart';
export 'processing.dart';
export 'devtools.dart';
export 'src/sse_parser.dart';
export 'src/transport.dart';
