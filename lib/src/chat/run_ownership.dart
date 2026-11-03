/// Port of upstream `run-ownership.ts`.
///
/// Dart has no `AbortController`, so ownership is modelled as a mutable
/// generation token. A run owns the client while it is the latest started run
/// and has not been cancelled.
class ChatRunToken {
  bool cancelled = false;

  void cancel() => cancelled = true;

  bool get isActive => !cancelled;
}

/// True while [controller] is the client's current, uncancelled run.
bool ownsRun(ChatRunToken? current, ChatRunToken controller) =>
    !controller.cancelled && identical(current, controller);

/// True without a token: that caller does not own a run.
bool owns(ChatRunToken? current, ChatRunToken? controller) =>
    controller == null || ownsRun(current, controller);

/// Run [steps] in order while [controller] owns the client. Returns whether
/// [controller] still owns the client afterwards.
bool whileOwned(
  ChatRunToken? Function() getCurrent,
  ChatRunToken? controller,
  List<void Function()> steps,
) {
  for (final step in steps) {
    if (!owns(getCurrent(), controller)) return false;
    step();
  }
  return owns(getCurrent(), controller);
}
