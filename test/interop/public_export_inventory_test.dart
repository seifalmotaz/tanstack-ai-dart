// Intentionally verifies retained upstream compatibility symbols.
// ignore_for_file: deprecated_member_use_from_same_package

import 'package:tanstack_ai_dart/byok.dart' as byok;
import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';
import 'package:tanstack_ai_dart/ui.dart' as ui;
import 'package:test/test.dart';

void main() {
  test('root barrel exposes 50 upstream client runtime exports', () {
    final runtime = <Object>[
      AudioRecorder,
      ChatClient,
      InterruptManager,
      createMcpAppBridge,
      getWebMCPTools,
      registerWebMCPTools,
      subscribeWebMCPTools,
      RealtimeClient,
      GenerationClient,
      VideoGenerationClient,
      GENERATION_EVENTS,
      reconstructImageResult,
      reconstructAudioResult,
      reconstructSpeechResult,
      reconstructTranscriptionResult,
      reconstructSummarizeResult,
      UnsupportedResponseStreamError,
      clientTools,
      createChatClientOptions,
      localStoragePersistence,
      sessionStoragePersistence,
      indexedDBPersistence,
      StorageUnavailableError,
      createAIDevtoolsGenerationPreview,
      fetchServerSentEvents,
      fetchHttpStream,
      fetchJson,
      xhrServerSentEvents,
      xhrHttpStream,
      stream,
      rpcStream,
      webSocket,
      StreamTruncatedError,
      DurableStreamIncompleteError,
      StreamReconnectLimitError,
      uiMessageToModelMessages,
      modelMessageToUIMessage,
      modelMessagesToUIMessages,
      convertMessagesToModelMessages,
      normalizeToUIMessage,
      generateMessageId,
      StreamProcessor,
      ImmediateStrategy,
      PunctuationStrategy,
      BatchStrategy,
      WordBoundaryStrategy,
      CompositeStrategy,
      parsePartialJSON,
      PartialJSONParser,
      defaultJSONParser,
    ];
    expect(runtime.length, 50);
  });

  test('byok barrel exposes all 11 runtime exports', () {
    final runtime = <Object>[
      byok.defineByok,
      byok.ByokClient,
      byok.EMPTY_BYOK_SNAPSHOT,
      byok.defineByokProvider,
      byok.memoryStorage,
      byok.defaultByokStorage,
      byok.decryptKeyring,
      byok.deriveAesKey,
      byok.encryptKeyring,
      byok.isPasskeyStorageSupported,
      byok.passkeyStorage,
    ];
    expect(runtime.length, 11);
  });

  test('ui barrel exposes all 6 runtime exports', () {
    final runtime = <Object>[
      ui.partTypeToKey,
      ui.selectChatUI,
      ui.automaticPartsForMessage,
      ui.collectInlineToolNames,
      ui.resolveInterruptComponent,
      ui.selectMessageUI,
    ];
    expect(runtime.length, 6);
  });

  test('root barrel exposes same-name type exports', () {
    final types = <Type>[
      AudioRecorderOptions,
      AudioRecorderState,
      InterruptManagerSubmission,
      McpAppBridge,
      CreateMcpAppBridgeOptions,
      GetWebMCPToolsOptions,
      RegisterWebMCPToolsOptions,
      SubscribeWebMCPToolsOptions,
      SubagentHandle,
      ChatClientPersistence,
      ChatPersistedState,
      ChatStorageAdapter,
      ChatResumeState,
      ChatFetcherInput,
      GenerationClientSnapshot,
      VideoGenerationClientSnapshot,
      GenerationPersistenceOptions,
      GenerationFetcherOptions,
      VideoStatusInfo,
      VideoGenerateResult,
      ImageGenerateInput,
      VideoGenerateInput,
      GenerationRestoredResult,
      WebStoragePersistenceOptions,
      IndexedDBPersistenceOptions,
      AIDevtoolsClientMetadata,
      AIDevtoolsDisplayOptions,
      AIDevtoolsGenerationMediaItem,
      AIDevtoolsGenerationPreview,
      AIDevtoolsGenerationProgress,
      AIDevtoolsGenerationVideoJob,
      PersistedArtifactRef,
      RealtimeAdapter,
      RealtimeConnection,
      RealtimeClientOptions,
      RealtimeClientState,
      RealtimeStateChangeCallback,
      GenerationHydrationResult,
      FetchConnectionOptions,
      FetchJsonOptions,
      ReconnectOptions,
      RunAgentInputContext,
      StreamConnectionHandlers,
      SubscribeConnectionAdapter,
      WebSocketConnectionOptions,
      XhrConnectionOptions,
      ChunkStrategy,
      StreamProcessorOptions,
      StreamProcessorEvents,
      InternalToolCallState,
      JSONParser,
      ChunkRecording,
      ProcessorResult,
      ProcessorState,
    ];
    expect(types.length, 54);
  });

  test('byok barrel exposes same-name type exports', () {
    final types = <Type>[
      byok.ByokPrompt,
      byok.ByokSnapshot,
      byok.DefineByokOptions,
      byok.KeyStatus,
      byok.ByokProvider,
      byok.KeyPreview,
      byok.Keyring,
      byok.KeyringStorage,
      byok.PasskeyStorageOptions,
    ];
    expect(types.length, 9);
  });

  test('ui barrel exposes same-name type exports', () {
    final types = <Type>[
      ui.ChatUISelectInput,
      ui.ChatUISelectedGenericPart,
      ui.ChatUISelectedMessage,
      ui.ChatUISelectedPart,
      ui.ChatUISelectedResultPart,
      ui.ChatUISelectedToolPart,
      ui.ChatUISelection,
    ];
    expect(types.length, 7);
  });

  test('adapted public types remain usable from their barrels', () {
    final types = <Type>[
      AssistantTurn,
      AssistantPart,
      ChatSnapshot,
      ChatInterrupt,
      ChatInterruptStatus,
      ChatQueueConfig,
      ChatSendOptions,
      ChatPersistenceOptions,
      ChatMessageInput,
      ChatHydrationInterrupts,
      ClientTool,
      QueueWhenBusy,
      PersistedArtifactSource,
    ];
    expect(types.length, 13);
  });

  test('runtime exports are callable', () {
    expect(partTypeToKey('tool-call'), 'toolCall');
    expect(partTypeToKey('custom-part'), 'customPart');
    expect(
      collectInlineToolNames({'placed': true}, ['placed', 'free']),
      ['free'],
    );
    expect(parsePartialJSON('{"a":1'), {'a': 1});
    expect(generateMessageId(), startsWith('msg-'));
    expect(clientTools(const <ClientTool>[]), isEmpty);
    expect(createChatClientOptions(const ChatClientOptions()).context, isNull);
    expect(memoryStorage().id, 'memory');
    expect(EMPTY_BYOK_SNAPSHOT.locked, isFalse);
    expect(GENERATION_EVENTS['RESULT'], 'generation:result');
    expect(defineByok().getSnapshot().locked, isFalse);
    expect(
      defineByokProvider(id: 'openai', label: 'OpenAI').id,
      'openai',
    );
    expect(isPasskeyStorageSupported(), isFalse);
    expect(
      selectChatUI(const ChatUISelectInput(messages: [])).messages,
      isEmpty,
    );
  });
}
