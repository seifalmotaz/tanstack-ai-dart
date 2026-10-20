/// Chat surface targeting TanStack AI client 0.40.0.
///
/// The root barrel also exports this surface. This library exposes the chat client, queue/history/interrupt configuration, run
/// ownership helpers and UI selectors.
library;

export 'src/client.dart' show ChatClient, ChatClientStatus, SubagentHandle;
export 'src/protocol.dart';
export 'src/transport.dart'
    show ChatTransport, SseChatTransport, ChatTransportException;
export 'src/chat/types.dart';
export 'src/chat/interrupt_manager.dart';
export 'src/chat/cleared_stream_tracker.dart';
export 'src/chat/connection_transport.dart';
export 'src/chat/run_ownership.dart';
export 'src/chat/ui_selectors.dart';
export 'src/chat/typed_ui.dart';
export 'src/chat/processing_scheduler.dart' show StreamProcessingScheduler;
