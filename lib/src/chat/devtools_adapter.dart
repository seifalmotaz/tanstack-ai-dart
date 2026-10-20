/// Seam between the real [ChatClient] state and the canonical devtools bridge.
///
/// The bridge only knows the injected closures, so the client keeps ownership
/// of identities, messages, tools, run tracking and disposal.
library;

import '../devtools/devtools.dart';
import '../devtools/devtools_noop.dart';
import '../devtools/devtools_types.dart';
import '../platform/tool_types.dart';

class ChatDevtoolsAdapter {
  final AIDevtoolsClientMetadata metadata;
  final ChatDevtoolsBridge bridge;

  bool _mounted = false;

  ChatDevtoolsAdapter({
    required this.metadata,
    ChatDevtoolsBridgeFactory? factory,
    required String Function() hookId,
    required String? Function() threadId,
    required AIDevtoolsChatSnapshot Function() getSnapshot,
    required List<Map<String, dynamic>> Function() getMessages,
    required void Function(List<Map<String, dynamic>> messages) setMessages,
    required void Function(
      String toolCallId,
      Object? output, [
      String? errorText,
    ]) addToolResult,
    required String Function(String prefix) generateId,
    required Iterable<ClientTool<dynamic, dynamic>> Function() getTools,
    required Object? Function() getContext,
  }) : bridge = (factory ?? createNoOpChatDevtoolsBridge)(
          ChatDevtoolsBridgeOptions(
            // The live getters below are the source of truth; these frozen
            // values only satisfy construction before the thread id exists.
            hookId: '',
            clientId: '',
            hookIdGetter: hookId,
            clientIdGetter: hookId,
            threadIdGetter: threadId,
            metadata: metadata,
            getSnapshot: getSnapshot,
            getMessages: getMessages,
            setMessages: setMessages,
            addToolResult: addToolResult,
            generateId: generateId,
            getTools: () => <AIDevtoolsTool>[
              for (final tool in getTools())
                AIDevtoolsTool(
                  name: tool.name,
                  description: tool.description,
                  inputSchema: tool.inputSchema?.jsonSchema,
                  outputSchema: tool.outputSchema?.jsonSchema,
                  needsApproval: tool.needsApproval,
                  metadata: tool.metadata,
                  execute: !tool.hasExecute
                      ? null
                      : (input) => tool.invoke(
                            input,
                            ToolCallContext(context: getContext()),
                          ),
                ),
            ],
          ),
        );

  bool get isMounted => _mounted;

  void mount(int initialMessageCount) {
    if (_mounted) return;
    _mounted = true;
    bridge.mountWithTools(initialMessageCount);
  }

  void emitSnapshot() {
    if (_mounted) bridge.emitSnapshot();
  }

  void notifyToolsChanged() {
    if (_mounted) bridge.notifyToolsChanged();
  }

  void dispose() {
    _mounted = false;
    bridge.dispose();
  }
}
