/// Canonical cancellation contract from `lib/src/cancellation.dart`.
///
/// The connections module re-exports the main implementation instead of
/// maintaining a second signal class. Both `isCancelled`/`isAborted` and
/// `addListener`/`onAbort` are therefore shared across transports, tools,
/// media and generations.
library;

export '../cancellation.dart';
