import 'dart:async';
import 'dart:convert';

import '../platform/interrupt_schema.dart';
import 'types.dart';

/// Run lineage used to keep replayed interrupt pauses closed.
class InterruptLineage {
  static const int _maxDepth = 32;

  final Map<String, String> _parents = <String, String>{};
  final Set<String> _answered = <String>{};

  bool isAnswered(String runId) => _answered.contains(runId);

  void recordStart(String runId, {String? parentRunId}) {
    if (runId.isEmpty) return;
    final parent = parentRunId;
    if (parent == null || parent.isEmpty) return;
    _parents[runId] = parent;
    if (isAnswered(runId)) markAnswered(parent);
  }

  void markAnswered(String runId) {
    var current = runId;
    var hops = 0;
    while (current.isNotEmpty && hops < _maxDepth) {
      if (!_answered.add(current)) return;
      final parent = _parents[current];
      if (parent == null) return;
      current = parent;
      hops += 1;
    }
  }

  void clear() {
    _parents.clear();
    _answered.clear();
  }
}

/// The exact batch handed to the transport for an interrupt resume.
class InterruptManagerSubmission {
  final String threadId;
  final String interruptedRunId;
  final int generation;
  final List<Map<String, dynamic>> resolutions;
  final String canonicalResolutions;
  final String fingerprint;

  const InterruptManagerSubmission({
    required this.threadId,
    required this.interruptedRunId,
    required this.generation,
    required this.resolutions,
    required this.canonicalResolutions,
    required this.fingerprint,
  });
}

class _ValidationResult {
  final bool valid;
  final Object? payload;
  final String? code;
  final String? message;

  const _ValidationResult.ok(this.payload)
      : valid = true,
        code = null,
        message = null;

  const _ValidationResult.fail(this.code, this.message)
      : valid = false,
        payload = null;
}

class _Checkpoint {
  final ChatInterruptStatus status;
  final Map<String, dynamic>? resolution;
  final Map<String, dynamic>? error;
  final int validationGeneration;

  const _Checkpoint(
    this.status,
    this.resolution,
    this.error,
    this.validationGeneration,
  );
}

class _Transaction {
  bool active = true;
}

/// Port of upstream `interrupt-manager.ts`.
class InterruptManager {
  ChatHydrationInterrupts? _hydration;
  List<ChatInterrupt> _items = <ChatInterrupt>[];
  List<ChatInterrupt> _snapshot = const <ChatInterrupt>[];
  List<Map<String, dynamic>> _rootErrors = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _submissionRootErrors = <Map<String, dynamic>>[];
  ChatInterruptState _state = ChatInterruptState.empty;
  bool _resuming = false;
  bool _disposed = false;
  InterruptManagerSubmission? _retrySubmission;
  int _submission = 0;
  _Transaction? _activeTransaction;
  List<ClientTool> _tools;
  final Map<String, ChatInterruptDefinition> _definitions;
  final InterruptLineage _lineage;
  final void Function(ChatInterruptState state, String source)? onChange;
  final FutureOr<void> Function(List<Map<String, dynamic>> resolutions)? submit;
  final FutureOr<void> Function(InterruptManagerSubmission submission)?
      submitSubmission;

  InterruptManager({
    List<ClientTool>? tools,
    List<ChatInterruptDefinition>? interrupts,
    InterruptLineage? lineage,
    this.onChange,
    this.submit,
    this.submitSubmission,
  })  : _tools = List<ClientTool>.from(tools ?? const []),
        _lineage = lineage ?? InterruptLineage(),
        _definitions = <String, ChatInterruptDefinition>{} {
    for (final definition in interrupts ?? const <ChatInterruptDefinition>[]) {
      if (_definitions.containsKey(definition.id)) {
        throw ArgumentError(
            'Duplicate interrupt definition id: ${definition.id}');
      }
      _definitions[definition.id] = definition;
    }
  }

  void updateTools(List<ClientTool> tools) {
    _tools = List<ClientTool>.from(tools);
  }

  void hydrate(
    ChatHydrationInterrupts hydration, {
    String source = 'live',
  }) {
    final threadId = hydration.effectiveThreadId;
    if (_lineage.isAnswered(hydration.runId)) return;
    _submission++;
    final pending = <Map<String, dynamic>>[
      for (final raw in hydration.pending)
        _cloneMap(raw) as Map<String, dynamic>,
    ];
    final generation = hydration.generation != 0
        ? hydration.generation
        : _maxBindingGeneration(pending);
    _hydrateInternal(
      ChatHydrationInterrupts(
        runId: hydration.runId,
        threadId: threadId,
        generation: generation,
        pending: pending,
      ),
      source,
    );
  }

  int _maxBindingGeneration(List<Map<String, dynamic>> pending) {
    var generation = 0;
    for (final raw in pending) {
      final binding = _bindingOf(raw);
      final value = binding?['generation'];
      if (value is int && value > generation) generation = value;
    }
    return generation;
  }

  void _hydrateInternal(ChatHydrationInterrupts hydration, String source) {
    _hydration = hydration;
    final firstPartyIndexes = <int, int>{};
    for (final raw in hydration.pending) {
      final binding = _bindingOf(raw);
      if (binding == null ||
          _str(binding['kind']) != 'generic' ||
          _str(binding['definitionId']).isEmpty ||
          _str(binding['key']).isEmpty ||
          binding['batchIndex'] is! int) {
        continue;
      }
      final index = binding['batchIndex'] as int;
      firstPartyIndexes[index] = (firstPartyIndexes[index] ?? 0) + 1;
    }
    _items = <ChatInterrupt>[
      for (final raw in hydration.pending)
        _classify(raw, hydration, firstPartyIndexes),
    ];
    _rootErrors = <Map<String, dynamic>>[];
    _submissionRootErrors = <Map<String, dynamic>>[];
    _retrySubmission = null;
    _resuming = false;
    _publish(source);
  }

  bool trackRunStarted(String runId, {String? parentRunId}) {
    if (runId.isEmpty) return true;
    _lineage.recordStart(runId, parentRunId: parentRunId);
    final replayed = _lineage.isAnswered(runId);
    if (replayed) _clearSupersededPause();
    return !replayed;
  }

  void trackRunSettled(String runId) {
    if (runId.isEmpty) return;
    _lineage.markAnswered(runId);
    _clearSupersededPause();
  }

  bool isRunAnswered(String runId) => _lineage.isAnswered(runId);

  void _clearSupersededPause() {
    final hydration = _hydration;
    if (hydration == null || !_lineage.isAnswered(hydration.runId)) return;
    reset();
  }

  List<ChatInterrupt> getInterrupts() => _snapshot;

  ChatInterruptState getState() => _state;

  List<Map<String, dynamic>> getDescriptors() =>
      _hydration?.pending ?? const <Map<String, dynamic>>[];

  List<Map<String, dynamic>> getInterruptErrors() => _rootErrors;

  bool getResuming() => _resuming;

  int get length => _items.length;

  bool get hasPending => _snapshot.any((item) =>
      item.resolution == null && item.status != ChatInterruptStatus.error);

  bool get isComplete =>
      _items.every((item) => !item.resumable || item.resolution != null);

  bool get hasResolvable => _items.any((item) => item.resumable);

  bool hasValidatedFirstPartyGenericBatch() =>
      _items.any((item) => item.kind == 'generic' && item.definition != null);

  void reset({
    bool preserveRootErrors = false,
    String source = 'live',
  }) {
    _submission++;
    _hydration = null;
    _items = <ChatInterrupt>[];
    _snapshot = const <ChatInterrupt>[];
    if (!preserveRootErrors) {
      _rootErrors = <Map<String, dynamic>>[];
      _submissionRootErrors = <Map<String, dynamic>>[];
    }
    _retrySubmission = null;
    _resuming = false;
    _activeTransaction = null;
    _state = ChatInterruptState.empty;
    _publish(source);
  }

  /// Resolve with a boolean (payloadless tool approvals) or run a synchronous
  /// transaction callback. Matches upstream's overloaded `resolve`.
  void resolve(Object? resolution) {
    _assertRootMutable();
    if (resolution is bool) {
      _resolveBooleanBulk(resolution);
      return;
    }
    if (resolution is Function) {
      _resolveTransaction((ChatInterrupt item) => resolution(item));
      return;
    }
    throw ArgumentError('resolve expects a bool or a transaction callback.');
  }

  /// Compatibility entry point used by the current ChatClient.
  bool resolveInterrupt(String interruptId, Object? payload) {
    final item = _find(interruptId);
    if (item == null) return false;
    _resolveItem(interruptId, payload);
    return item.canResolve;
  }

  void clearResolution(String interruptId) {
    _clearItem(interruptId);
  }

  /// Current resolutions for callers that drive the resume request manually.
  List<Map<String, dynamic>> getResolutions() => <Map<String, dynamic>>[
        for (final item in _items)
          if (item.resolution != null)
            _withContinuation(item, item.resolution!),
      ];

  void _resolveBooleanBulk(bool approved) {
    final resolvable = _items
        .where((item) => item.resumable && item.kind != 'client-tool-execution')
        .toList();
    final eligible = resolvable.every((item) =>
        item.kind == 'tool-approval' &&
        _approvalBranchSchema(item.tool, approved) == null);
    if (!eligible || resolvable.isEmpty) {
      _addRootError(
        'unsupported-bulk-operation',
        'Boolean bulk resolution requires payloadless tool approvals.',
        false,
      );
      return;
    }
    _invalidateRetry();
    for (final item in resolvable) {
      item.validationGeneration++;
      item.resolution = _cloneMap(<String, dynamic>{
        'interruptId': item.id,
        'status': 'resolved',
        'payload': <String, dynamic>{'approved': approved},
      }) as Map<String, dynamic>;
      item.status = ChatInterruptStatus.staged;
      item.error = null;
    }
    _publish();
    _maybeSubmit();
  }

  void _resolveTransaction(Object? Function(ChatInterrupt item) resolver) {
    final checkpoints = <_Checkpoint>[
      for (final item in _items)
        _Checkpoint(
          item.status,
          _cloneMap(item.resolution) as Map<String, dynamic>?,
          _cloneMap(item.error) as Map<String, dynamic>?,
          item.validationGeneration,
        ),
    ];
    final token = _Transaction();
    _activeTransaction = token;
    final stable =
        _buildSnapshot(token).where((item) => item.kind != 'unbound').toList();
    String? failureCode;
    String? failureMessage;
    try {
      for (final interrupt in stable) {
        final result = resolver(interrupt);
        if (result != null) {
          if (result is Future) {
            failureCode = 'async-resolver';
            failureMessage =
                'Interrupt transaction resolvers must be synchronous.';
          } else {
            failureCode = 'inactive-transaction';
            failureMessage =
                'Interrupt transaction resolvers must return literal undefined.';
          }
          break;
        }
      }
      if (failureCode == null) {
        final incomplete = _items.any((item) =>
            item.resumable &&
            item.kind != 'client-tool-execution' &&
            (item.resolution == null ||
                item.status != ChatInterruptStatus.staged));
        if (incomplete) {
          failureCode = 'incomplete-batch';
          failureMessage = 'Interrupt transaction did not resolve every item.';
        }
      }
    } catch (error) {
      failureCode = 'item-validation-failed';
      failureMessage = '$error';
    } finally {
      token.active = false;
      _activeTransaction = null;
    }

    if (failureCode != null) {
      _restoreCheckpoints(checkpoints);
      _addRootError(
          failureCode,
          failureMessage ??
              'Interrupt transaction '
                  'failed.',
          false);
      return;
    }
    _publish();
    _maybeSubmit();
  }

  void _restoreCheckpoints(List<_Checkpoint> checkpoints) {
    for (var index = 0; index < _items.length; index++) {
      if (index >= checkpoints.length) break;
      final item = _items[index];
      final checkpoint = checkpoints[index];
      item.status = checkpoint.status;
      item.resolution = checkpoint.resolution;
      item.error = checkpoint.error;
      item.validationGeneration = checkpoint.validationGeneration + 1;
    }
    _publish();
  }

  void cancel() {
    _assertRootMutable();
    _invalidateRetry();
    for (final item in _items) {
      if (!item.resumable) continue;
      item.validationGeneration++;
      item.resolution = _cloneMap(_withContinuation(item, <String, dynamic>{
        'interruptId': item.id,
        'status': 'cancelled',
      })) as Map<String, dynamic>;
      item.status = ChatInterruptStatus.staged;
      item.error = null;
    }
    _publish();
    _maybeSubmit();
  }

  void retry() {
    if (_resuming) {
      throw StateError('Interrupt submission is already active.');
    }
    final submission = _retrySubmission;
    if (submission == null) {
      _addRootError(
        'transport',
        'There is no retryable interrupt submission.',
        false,
      );
      return;
    }
    _submit(submission);
  }

  bool resolveToolApprovalDecision(String interruptId, bool approved) {
    final item = _find(interruptId);
    if (item == null) return false;
    final legacy = item.kind == 'generic' &&
        item.reason == 'approval_required' &&
        _isLegacyApprovalMetadata(item.metadata);
    if (item.kind != 'tool-approval' && !legacy) return false;
    _resolveItem(item.id, <String, dynamic>{'approved': approved});
    return true;
  }

  bool resolveClientToolOutput(String toolCallId, dynamic output) {
    return _resolveClientToolResult(
      toolCallId,
      available: true,
      output: output,
    );
  }

  bool resolveClientToolError(String toolCallId, String errorText) {
    return _resolveClientToolResult(
      toolCallId,
      available: false,
      errorText: errorText,
    );
  }

  bool _resolveClientToolResult(
    String toolCallId, {
    required bool available,
    Object? output,
    String? errorText,
  }) {
    ChatInterrupt? item;
    for (final candidate in _items) {
      if (candidate.kind == 'client-tool-execution' &&
          candidate.binding?['kind'] == 'client-tool-execution' &&
          candidate.binding?['toolCallId'] == toolCallId) {
        item = candidate;
        break;
      }
      if (candidate.kind == 'generic' &&
          (candidate.reason == 'tanstack:client_tool_execution' ||
              candidate.reason == 'client_tool_input') &&
          candidate.toolCallId == toolCallId &&
          _isLegacyClientToolMetadata(candidate.metadata)) {
        item = candidate;
        break;
      }
    }
    if (item == null) return false;
    if (item.kind != 'client-tool-execution') {
      if (!available) {
        _resolveItem(item.id, <String, dynamic>{'error': errorText});
        return true;
      }
      try {
        final canonical = jsonDecode(canonicalInterruptJson(output));
        _resolveItem(item.id, canonical);
      } catch (error) {
        _failClientTool(item, 'invalid-tool-output', '$error');
      }
      return true;
    }
    if (available) {
      _resolveItem(item.id, output);
      return true;
    }
    _stageClientToolError(item, errorText ?? '');
    return true;
  }

  void _stageClientToolError(ChatInterrupt item, String errorText) {
    _assertItemMutable();
    _invalidateRetry();
    if (!item.resumable) {
      item.status = ChatInterruptStatus.error;
      item.error = _itemError(
        item.id,
        'invalid-response-schema',
        'The interrupt response schema is invalid and cannot be resolved.',
      );
      _publish();
      return;
    }
    item.validationGeneration++;
    final resolution = _withContinuation(item, <String, dynamic>{
      'interruptId': item.id,
      'status': 'resolved',
      'payload': <String, dynamic>{'error': errorText},
    });
    resolution['metadata'] = <String, dynamic>{
      'tanstack': <String, dynamic>{'state': 'output-error'},
    };
    item.resolution = _cloneMap(resolution) as Map<String, dynamic>;
    item.status = ChatInterruptStatus.staged;
    item.error = null;
    _publish();
    _maybeSubmit();
  }

  void _failClientTool(ChatInterrupt item, String code, String message) {
    item.status = ChatInterruptStatus.error;
    item.resolution = null;
    final error = _itemError(item.id, code, message);
    item.error = error;
    _rootErrors = <Map<String, dynamic>>[
      ..._rootErrors.where(
        (existing) => !(existing['code'] == 'item-validation-failed' &&
            (existing['interruptIds'] as List?)?.contains(item.id) == true),
      ),
      <String, dynamic>{
        'scope': 'batch',
        'code': 'item-validation-failed',
        'message': message,
        'source': 'client',
        'retryable': false,
        'interruptIds': <String>[item.id],
        'threadId': error['threadId'],
        'interruptedRunId': error['interruptedRunId'],
        'generation': error['generation'],
      },
    ];
    _publish();
  }

  ChatInterrupt? _find(String id) {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  void _resolveItem(
    String interruptId,
    Object? payload, [
    _Transaction? transaction,
  ]) {
    _assertItemMutable(transaction);
    final item = _find(interruptId);
    if (item == null) throw StateError('Unknown interrupt: $interruptId');
    _invalidateRetry();
    if (!item.canResolve) {
      item.status = ChatInterruptStatus.error;
      item.error = _itemError(
        interruptId,
        'invalid-response-schema',
        'The interrupt response schema is invalid and cannot be resolved.',
      );
      if (transaction == null) _publish();
      return;
    }
    final generation = ++item.validationGeneration;
    final validation = _validateCandidate(item, payload);
    if (validation is Future<_ValidationResult>) {
      item.status = ChatInterruptStatus.validating;
      item.error = null;
      if (transaction == null) _publish();
      validation.then(
        (result) {
          if (generation != item.validationGeneration ||
              !_items.contains(item)) {
            return;
          }
          _applyValidation(item, result, transaction);
        },
        onError: (Object error) {
          if (generation != item.validationGeneration ||
              !_items.contains(item)) {
            return;
          }
          _applyValidation(
            item,
            _ValidationResult.fail(
              _validationCode(item),
              '$error',
            ),
            transaction,
          );
        },
      );
      return;
    }
    _applyValidation(item, validation, transaction);
  }

  void _cancelItem(String interruptId, [_Transaction? transaction]) {
    _assertItemMutable(transaction);
    final item = _find(interruptId);
    if (item == null) throw StateError('Unknown interrupt: $interruptId');
    _invalidateRetry();
    item.validationGeneration++;
    item.resolution = _cloneMap(_withContinuation(item, <String, dynamic>{
      'interruptId': interruptId,
      'status': 'cancelled',
    })) as Map<String, dynamic>;
    item.status = ChatInterruptStatus.staged;
    item.error = null;
    if (transaction == null) {
      _publish();
      _maybeSubmit();
    }
  }

  void _clearItem(String interruptId, [_Transaction? transaction]) {
    _assertItemMutable(transaction);
    final item = _find(interruptId);
    if (item == null) throw StateError('Unknown interrupt: $interruptId');
    _invalidateRetry();
    item.validationGeneration++;
    item.resolution = null;
    item.error = null;
    item.status = ChatInterruptStatus.pending;
    if (transaction == null) _publish();
  }

  void _applyValidation(
    ChatInterrupt item,
    _ValidationResult result, [
    _Transaction? transaction,
  ]) {
    if (!result.valid) {
      item.status = ChatInterruptStatus.error;
      final error = _itemError(
        item.id,
        result.code ?? _validationCode(item),
        result.message ?? 'Schema validation failed.',
      );
      item.error = error;
      if (item.kind == 'client-tool-execution') {
        _rootErrors = <Map<String, dynamic>>[
          ..._rootErrors.where(
            (existing) => !(existing['code'] == 'item-validation-failed' &&
                (existing['interruptIds'] as List?)?.contains(item.id) == true),
          ),
          <String, dynamic>{
            'scope': 'batch',
            'code': 'item-validation-failed',
            'message': error['message'],
            'source': 'client',
            'retryable': false,
            'interruptIds': <String>[item.id],
            'threadId': error['threadId'],
            'interruptedRunId': error['interruptedRunId'],
            'generation': error['generation'],
          },
        ];
      }
      if (transaction == null) _publish();
      return;
    }
    item.resolution = _cloneMap(_withContinuation(item, <String, dynamic>{
      'interruptId': item.id,
      'status': 'resolved',
      'payload': result.payload,
    })) as Map<String, dynamic>;
    item.status = ChatInterruptStatus.staged;
    item.error = null;
    if (transaction == null) {
      _publish();
      _maybeSubmit();
    }
  }

  FutureOr<_ValidationResult> _validateCandidate(
    ChatInterrupt item,
    Object? payload,
  ) {
    if (item.kind == 'generic') {
      return _validateGeneric(item, item.definition, payload);
    }
    if (item.kind == 'client-tool-execution') {
      return _validateClientTool(item, payload);
    }
    return _validateApproval(item, payload);
  }

  FutureOr<_ValidationResult> _validateGeneric(
    ChatInterrupt item,
    ChatInterruptDefinition? definition,
    Object? payload,
  ) {
    if (definition != null &&
        definition.responseSchema == null &&
        definition.validate != null) {
      try {
        definition.validate!(payload);
        return _ValidationResult.ok(payload);
      } catch (error) {
        return _ValidationResult.fail('invalid-payload', '$error');
      }
    }
    final validation = _validateWithSchema(
      definition?.responseSchema ?? item.responseSchema,
      payload,
      'invalid-payload',
    );
    if (definition == null) return validation;
    if (validation is Future<_ValidationResult>) {
      return validation.then(
        (result) => result.valid ? _ValidationResult.ok(payload) : result,
      );
    }
    return validation.valid ? _ValidationResult.ok(payload) : validation;
  }

  FutureOr<_ValidationResult> _validateClientTool(
    ChatInterrupt item,
    Object? payload,
  ) {
    final validation = _validateWithSchema(
      item.tool?.outputSchema,
      payload,
      'invalid-tool-output',
    );
    FutureOr<_ValidationResult> canonicalize(_ValidationResult result) {
      if (!result.valid) return result;
      try {
        return _ValidationResult.ok(
          jsonDecode(canonicalInterruptJson(result.payload)),
        );
      } catch (error) {
        return _ValidationResult.fail('invalid-tool-output', '$error');
      }
    }

    if (validation is Future<_ValidationResult>) {
      return validation.then(canonicalize);
    }
    return canonicalize(validation);
  }

  FutureOr<_ValidationResult> _validateApproval(
    ChatInterrupt item,
    Object? payload,
  ) {
    if (payload is! Map || payload['approved'] is! bool) {
      return const _ValidationResult.fail(
        'invalid-payload',
        'Tool approval resolutions require an approved boolean.',
      );
    }
    final approved = payload['approved'] as bool;
    final editedArgs = payload['editedArgs'];
    if (!approved && editedArgs != null) {
      return const _ValidationResult.fail(
        'invalid-edited-args',
        'Rejected tool approvals cannot edit tool arguments.',
      );
    }
    if (approved && editedArgs != null) {
      final editedValidation = _validateWithSchema(
        item.tool?.inputSchema,
        editedArgs,
        'invalid-edited-args',
      );
      if (editedValidation is Future<_ValidationResult>) {
        return editedValidation.then((result) => result.valid
            ? _validateApprovalPayload(item, payload, result.payload)
            : result);
      }
      if (!editedValidation.valid) return editedValidation;
      return _validateApprovalPayload(
        item,
        payload,
        editedValidation.payload,
      );
    }
    return _validateApprovalPayload(item, payload, null);
  }

  FutureOr<_ValidationResult> _validateApprovalPayload(
    ChatInterrupt item,
    Map payload,
    Object? validatedEditedArgs,
  ) {
    final approved = payload['approved'] == true;
    final schema = _approvalBranchSchema(item.tool, approved);
    final branchPayload = payload['payload'];
    if (schema == null && branchPayload != null) {
      return const _ValidationResult.fail(
        'invalid-payload',
        'This approval branch does not accept a payload.',
      );
    }
    if (schema != null && branchPayload == null) {
      return const _ValidationResult.fail(
        'invalid-payload',
        'This approval branch requires a payload.',
      );
    }
    final validation = _validateWithSchema(
      schema,
      branchPayload,
      'invalid-payload',
    );
    _ValidationResult build(_ValidationResult result) {
      if (!result.valid) return result;
      return _ValidationResult.ok(<String, dynamic>{
        'approved': approved,
        if (validatedEditedArgs != null) 'editedArgs': validatedEditedArgs,
        if (schema != null) 'payload': result.payload,
      });
    }

    if (validation is Future<_ValidationResult>) {
      return validation.then(build);
    }
    return build(validation);
  }

  FutureOr<_ValidationResult> _validateWithSchema(
    Object? schema,
    Object? value,
    String code,
  ) {
    if (schema == null) return _ValidationResult.ok(value);
    if (schema is StandardSchema) {
      return schema.validate(value).then((result) {
        if (result.success) return _ValidationResult.ok(result.data);
        return _ValidationResult.fail(
          code,
          result.issues.isEmpty
              ? 'Schema validation failed.'
              : result.issues.first.message,
        );
      });
    }
    // Raw JSON Schema is intentionally not compiled or validated.
    return _ValidationResult.ok(value);
  }

  Object? _approvalBranchSchema(ClientTool? tool, bool approved) {
    if (tool == null) return null;
    final approval = clientToolApprovalSchema(tool);
    if (approval is Map &&
        (approval.containsKey('approve') || approval.containsKey('reject'))) {
      return approved ? approval['approve'] : approval['reject'];
    }
    return approval;
  }

  String _validationCode(ChatInterrupt item) =>
      item.kind == 'client-tool-execution'
          ? 'invalid-tool-output'
          : 'invalid-payload';

  void _maybeSubmit() {
    final hasGeneric = _items.any((item) => item.kind == 'generic');
    final ours = _items
        .where((item) =>
            item.resumable &&
            !(hasGeneric && item.kind == 'client-tool-execution'))
        .toList();
    if (ours.isEmpty ||
        ours.any((item) =>
            item.resolution == null ||
            item.status != ChatInterruptStatus.staged)) {
      return;
    }
    final hydration = _hydration;
    if (hydration == null) return;
    // Without an injected submit callback the caller drives resume explicitly.
    if (submit == null && submitSubmission == null) return;
    final resolutions = <Map<String, dynamic>>[
      for (final item in ours) _withContinuation(item, item.resolution!),
    ]..sort((left, right) =>
        '${left['interruptId']}'.compareTo('${right['interruptId']}'));
    final frozen = _cloneMap(resolutions) as List<dynamic>;
    final canonical = canonicalInterruptJson(frozen);
    final submission = InterruptManagerSubmission(
      threadId: hydration.effectiveThreadId,
      interruptedRunId: hydration.runId,
      generation: hydration.generation,
      resolutions:
          List<Map<String, dynamic>>.unmodifiable(<Map<String, dynamic>>[
        for (final resolution in frozen)
          Map<String, dynamic>.from(resolution as Map),
      ]),
      canonicalResolutions: canonical,
      fingerprint: digestInterruptJson(canonical),
    );
    _submit(submission);
  }

  void _submit(InterruptManagerSubmission submission) {
    final operation = ++_submission;
    _resuming = true;
    _retrySubmission = null;
    for (final item in _items) {
      if (item.resumable) item.status = ChatInterruptStatus.submitting;
    }
    _publish();

    FutureOr<void> result;
    try {
      final typed = submitSubmission;
      result = typed != null
          ? typed(submission)
          : submit?.call(submission.resolutions) ?? Future<void>.value();
    } catch (error) {
      _handleSubmissionFailure(error, submission);
      _finishSubmission(operation);
      return;
    }
    Future<void>.sync(() => result).then(
      (_) => _finishSubmission(operation),
      onError: (Object error) {
        if (operation != _submission) return;
        _handleSubmissionFailure(error, submission);
        _finishSubmission(operation);
      },
    );
  }

  void _finishSubmission(int operation) {
    if (operation != _submission) return;
    _resuming = false;
    _publish();
  }

  void _handleSubmissionFailure(
    Object error,
    InterruptManagerSubmission submission,
  ) {
    final errors = _readSubmissionErrors(error);
    if (errors.isEmpty) {
      _addRootError(
        'transport',
        error is Error ? error.toString() : '$error',
        true,
        source: 'transport',
      );
      _retrySubmission = submission;
      for (final item in _items) {
        if (item.resumable) item.status = ChatInterruptStatus.error;
      }
      return;
    }

    final correlated = errors
        .where((submissionError) =>
            _submissionErrorMatchesActiveBatch(submissionError, submission))
        .toList();
    if (correlated.length != errors.length) {
      _addRootError(
        'protocol',
        'Interrupt submission errors did not match the active batch.',
        false,
      );
    }

    var nonRetryable = false;
    var retryable = false;
    final batchErrors = <Map<String, dynamic>>[];
    for (final submissionError in correlated) {
      final code = '${submissionError['code']}';
      if (code == 'stale' || code == 'expired' || code == 'conflict') {
        nonRetryable = true;
      }
      retryable = retryable || submissionError['retryable'] == true;
      if (submissionError['scope'] == 'item') {
        final id = '${submissionError['interruptId']}';
        for (final item in _items) {
          if (item.resumable && item.id == id) {
            item.status = ChatInterruptStatus.error;
            item.error = Map<String, dynamic>.from(submissionError);
          }
        }
      } else {
        batchErrors.add(Map<String, dynamic>.from(submissionError));
      }
    }
    final merged = _mergeSubmissionBatchErrors(batchErrors);
    _rootErrors = merged.$1;
    _submissionRootErrors = merged.$2;
    for (final item in _items) {
      if (item.resumable && item.status == ChatInterruptStatus.submitting) {
        item.status = ChatInterruptStatus.error;
      }
    }
    _retrySubmission = retryable && !nonRetryable ? submission : null;
  }

  (List<Map<String, dynamic>>, List<Map<String, dynamic>>)
      _mergeSubmissionBatchErrors(List<Map<String, dynamic>> incoming) {
    final replaceableIncoming =
        incoming.where((error) => error['source'] != 'transport').toList();
    bool sameCorrelation(
      Map<String, dynamic> left,
      Map<String, dynamic> right,
    ) {
      if (left['threadId'] != right['threadId'] ||
          left['interruptedRunId'] != right['interruptedRunId'] ||
          left['generation'] != right['generation']) {
        return false;
      }
      final leftIds = (left['interruptIds'] as List? ?? const <dynamic>[])
          .map((id) => '$id')
          .toList()
        ..sort();
      final rightIds = (right['interruptIds'] as List? ?? const <dynamic>[])
          .map((id) => '$id')
          .toList()
        ..sort();
      if (leftIds.length != rightIds.length) return false;
      for (var i = 0; i < leftIds.length; i++) {
        if (leftIds[i] != rightIds[i]) return false;
      }
      return true;
    }

    bool superseded(Map<String, dynamic> candidate) =>
        _submissionRootErrors
            .any((previous) => identical(previous, candidate)) &&
        replaceableIncoming.any((error) => sameCorrelation(candidate, error));

    final retainedRoot =
        _rootErrors.where((candidate) => !superseded(candidate)).toList();
    final retainedSubmission = _submissionRootErrors
        .where((candidate) => !replaceableIncoming
            .any((error) => sameCorrelation(candidate, error)))
        .toList();
    return (
      <Map<String, dynamic>>[...retainedRoot, ...incoming],
      <Map<String, dynamic>>[...retainedSubmission, ...replaceableIncoming],
    );
  }

  List<Map<String, dynamic>> _readSubmissionErrors(Object? error) {
    if (error is Map) {
      if (_isSubmissionError(error)) {
        return <Map<String, dynamic>>[Map<String, dynamic>.from(error)];
      }
      final nested = error['errors'];
      if (nested is List) {
        final parsed = <Map<String, dynamic>>[];
        for (final item in nested) {
          if (item is! Map || !_isSubmissionError(item)) {
            return const <Map<String, dynamic>>[];
          }
          parsed.add(Map<String, dynamic>.from(item));
        }
        return parsed;
      }
    }
    return const <Map<String, dynamic>>[];
  }

  bool _isSubmissionError(Map error) {
    final code = error['code'];
    final scope = error['scope'];
    if (code is! String ||
        error['message'] is! String ||
        error['retryable'] is! bool ||
        error['threadId'] is! String ||
        error['interruptedRunId'] is! String ||
        error['generation'] is! num) {
      return false;
    }
    const itemCodes = <String>{
      'invalid-payload',
      'invalid-edited-args',
      'invalid-tool-output',
      'invalid-response-schema',
      'unknown-interrupt',
      'expired',
      'stale',
      'conflict',
      'legacy-unsupported',
    };
    const batchCodes = <String>{
      'incomplete-batch',
      'item-validation-failed',
      'unsupported-bulk-operation',
      'async-resolver',
      'inactive-transaction',
      'mixed-provenance',
      'transport',
      'server',
      'protocol',
      'invalid-response-schema',
      'expired',
      'stale',
      'conflict',
      'legacy-submit-failed',
    };
    if (scope == 'item') {
      return itemCodes.contains(code) &&
          error['interruptId'] is String &&
          (error['source'] == 'client' || error['source'] == 'server');
    }
    return scope == 'batch' &&
        batchCodes.contains(code) &&
        error['interruptIds'] is List &&
        (error['interruptIds'] as List).every((id) => id is String) &&
        (error['source'] == 'client' ||
            error['source'] == 'server' ||
            error['source'] == 'transport');
  }

  bool _submissionErrorMatchesActiveBatch(
    Map<String, dynamic> error,
    InterruptManagerSubmission submission,
  ) {
    if (error['threadId'] != submission.threadId ||
        error['interruptedRunId'] != submission.interruptedRunId ||
        error['generation'] != submission.generation) {
      return false;
    }
    final ids = submission.resolutions
        .map((resolution) => '${resolution['interruptId']}');
    if (error['scope'] == 'item') {
      return ids.contains('${error['interruptId']}');
    }
    final left = (error['interruptIds'] as List).map((id) => '$id').toList()
      ..sort();
    final right = ids.toList()..sort();
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  void _addRootError(
    String code,
    String message,
    bool retryable, {
    String source = 'client',
  }) {
    final hydration = _hydration;
    if (hydration == null) return;
    _rootErrors = <Map<String, dynamic>>[
      ..._rootErrors,
      <String, dynamic>{
        'scope': 'batch',
        'code': code,
        'message': message,
        'source': source,
        'retryable': retryable,
        'interruptIds': <String>[
          for (final item in _items)
            if (item.resumable) item.id,
        ],
        'threadId': hydration.effectiveThreadId,
        'interruptedRunId': hydration.runId,
        'generation': hydration.generation,
      },
    ];
    _publish();
  }

  void _assertRootMutable() {
    if (_activeTransaction != null) {
      throw StateError('Interrupt transaction is already active.');
    }
    if (_resuming) {
      throw StateError('Interrupts cannot be mutated while submitting.');
    }
  }

  void _assertItemMutable([_Transaction? transaction]) {
    if (transaction != null && !transaction.active) {
      throw StateError('Interrupt transaction is inactive.');
    }
    if (_activeTransaction != null && transaction != _activeTransaction) {
      throw StateError('Interrupt transaction is inactive.');
    }
    if (_resuming) {
      throw StateError('Interrupts cannot be mutated while submitting.');
    }
  }

  void _invalidateRetry() => _retrySubmission = null;

  void _publish([String source = 'live']) {
    if (_disposed) return;
    if (_hydration == null) {
      _snapshot = const <ChatInterrupt>[];
      _state = ChatInterruptState(
        interrupts: _snapshot,
        pendingInterrupts: _snapshot,
        interruptErrors: List<Map<String, dynamic>>.unmodifiable(_rootErrors),
        resuming: _resuming,
      );
      onChange?.call(_state, source);
      return;
    }
    _snapshot = _buildSnapshot();
    _state = ChatInterruptState(
      interrupts: _snapshot,
      pendingInterrupts: _snapshot,
      interruptErrors: List<Map<String, dynamic>>.unmodifiable(_rootErrors),
      resuming: _resuming,
    );
    onChange?.call(_state, source);
  }

  List<ChatInterrupt> _buildSnapshot([_Transaction? transaction]) {
    final next = <ChatInterrupt>[];
    for (final item in _items) {
      if (item.kind == 'client-tool-execution' ||
          item.status == ChatInterruptStatus.submitting) {
        continue;
      }
      final unbound = item.kind == 'unbound' || item.binding == null;
      Object? Function(dynamic, [dynamic])? resolve;
      void Function()? cancel;
      void Function()? clear;
      if (!unbound) {
        resolve = (response, [options]) {
          Object? payload = response;
          if (item.kind == 'tool-approval' && response is bool) {
            payload = <String, dynamic>{'approved': response};
            if (options is Map) {
              if (response && options['editedArgs'] != null) {
                (payload as Map<String, dynamic>)['editedArgs'] =
                    options['editedArgs'];
              }
              if (options['payload'] != null) {
                (payload as Map<String, dynamic>)['payload'] =
                    options['payload'];
              }
            }
          }
          _resolveItem(item.id, payload, transaction);
          return true;
        };
        cancel = () => _cancelItem(item.id, transaction);
        clear = () => _clearItem(item.id, transaction);
      }
      next.add(ChatInterrupt(
        id: item.id,
        kind: unbound ? 'unbound' : item.kind,
        reason: item.reason,
        message: item.message,
        toolName: item.toolName,
        toolCallId: item.toolCallId,
        input: _cloneJson(item.input),
        payload: _cloneJson(item.payload),
        metadata: _cloneMap(item.metadata) as Map<String, dynamic>?,
        binding:
            unbound ? null : _cloneMap(item.binding) as Map<String, dynamic>?,
        threadId: item.threadId,
        interruptedRunId: item.interruptedRunId,
        generation: item.generation,
        originalArgs: _cloneJson(item.originalArgs),
        responseSchema: _cloneJson(item.responseSchema),
        expiresAt: item.expiresAt,
        tool: item.tool,
        definition: item.definition,
        validationGeneration: item.validationGeneration,
        status: item.status,
        canResolve: unbound ? false : item.canResolve,
        definitionId: item.definitionId,
        key: item.key,
        batchIndex: item.batchIndex,
        error: _cloneMap(item.error) as Map<String, dynamic>?,
        resolution: _cloneMap(item.resolution) as Map<String, dynamic>?,
        onResolveInterrupt: resolve,
        onCancel: cancel,
        onClearResolution: clear,
      ));
    }
    return List<ChatInterrupt>.unmodifiable(next);
  }

  ChatInterrupt _classify(
    Map<String, dynamic> raw,
    ChatHydrationInterrupts hydration,
    Map<int, int> firstPartyIndexes,
  ) {
    final metadata = raw['metadata'] is Map
        ? _cloneMap(raw['metadata']) as Map<String, dynamic>
        : <String, dynamic>{};
    final bindingRaw = metadata['tanstack:interruptBinding'];
    final binding = bindingRaw is Map
        ? _cloneMap(bindingRaw) as Map<String, dynamic>
        : null;
    final id = _str(raw['id']);
    final reason = _str(raw['reason']);
    final threadId = hydration.effectiveThreadId;
    final interruptedRunId = hydration.runId;
    final generation = hydration.generation;

    ChatInterrupt base({
      required String kind,
      bool canResolve = true,
      String? toolName,
      String? toolCallId,
      Map<String, dynamic>? error,
      String? definitionId,
      String? key,
      int? batchIndex,
      dynamic payload,
      ClientTool? tool,
      ChatInterruptDefinition? definition,
      Map<String, dynamic>? effectiveBinding,
      bool clearBinding = false,
      ChatInterruptStatus status = ChatInterruptStatus.pending,
    }) =>
        ChatInterrupt(
          id: id,
          kind: kind,
          reason: reason,
          message: raw['message'] == null ? null : _str(raw['message']),
          toolName: toolName,
          toolCallId: toolCallId,
          input: metadata['input'],
          payload: payload ?? metadata['tanstack:interruptPayload'],
          metadata: metadata,
          binding: clearBinding ? null : (effectiveBinding ?? binding),
          threadId: threadId,
          interruptedRunId: interruptedRunId,
          generation: generation,
          originalArgs: binding?['originalArgs'],
          responseSchema: raw['responseSchema'],
          expiresAt:
              raw['expiresAt'] is String ? raw['expiresAt'] as String : null,
          tool: tool,
          definition: definition,
          status: status,
          canResolve: canResolve,
          definitionId: definitionId,
          key: key,
          batchIndex: batchIndex,
          error: error,
        );

    Map<String, dynamic> derivedGenericBinding() =>
        _deriveGenericBinding(raw, hydration, binding);

    if (binding == null) {
      final legacy = _isLegacyApprovalMetadata(metadata) ||
          _isLegacyClientToolMetadata(metadata);
      if (!legacy) {
        return base(
          kind: 'unbound',
          canResolve: false,
          clearBinding: true,
        );
      }
      return base(
        kind: 'generic',
        toolName: _str(metadata['toolName']),
        toolCallId: _str(raw['toolCallId']),
        effectiveBinding: derivedGenericBinding(),
      );
    }

    final version = binding['v'];
    if (version != null && version != 1) {
      return base(
        kind: 'unbound',
        canResolve: false,
        clearBinding: true,
      );
    }

    final rawSchemaHash = _responseSchemaHash(raw);
    final candidateId = _str(binding['interruptId']);
    final candidateRun = _str(binding['interruptedRunId']);
    final candidateGeneration =
        binding['generation'] is int ? binding['generation'] as int : null;
    final bindingHash = binding['responseSchemaHash'] is String
        ? binding['responseSchemaHash'] as String
        : null;
    final correlated = candidateId == id &&
        candidateRun == interruptedRunId &&
        candidateGeneration == generation &&
        rawSchemaHash == bindingHash;
    final structurallyCorrelated = candidateId == id &&
        candidateRun == interruptedRunId &&
        candidateGeneration == generation &&
        bindingHash == (rawSchemaHash ?? bindingHash);

    final kind = _str(binding['kind']);
    final definitionId = _str(binding['definitionId']);
    final key = _str(binding['key']);
    final batchIndex =
        binding['batchIndex'] is int ? binding['batchIndex'] as int : null;

    if (_hasFirstPartyGenericMarker(binding) &&
        (!structurallyCorrelated ||
            kind != 'generic' ||
            definitionId.isEmpty ||
            key.isEmpty ||
            batchIndex == null)) {
      return base(
        kind: 'generic',
        canResolve: false,
        status: ChatInterruptStatus.error,
        effectiveBinding: derivedGenericBinding(),
        error: _itemError(
          id,
          'stale',
          'The interrupt binding does not match this interrupted run.',
        ),
      );
    }

    if (structurallyCorrelated && kind == 'tool-approval') {
      final tool = _toolNamed(_str(binding['toolName']));
      if (tool != null &&
          tool.needsApproval &&
          _str(raw['toolCallId']) == _str(binding['toolCallId']) &&
          _toolApprovalHashesMatch(binding, tool)) {
        return base(
          kind: 'tool-approval',
          toolName: tool.name,
          toolCallId: _str(binding['toolCallId']),
          tool: tool,
        );
      }
    }

    if (structurallyCorrelated && kind == 'client-tool-execution') {
      final tool = _toolNamed(_str(binding['toolName']));
      if (tool != null &&
          _str(raw['toolCallId']) == _str(binding['toolCallId']) &&
          _clientToolHashMatches(binding, tool)) {
        return base(
          kind: 'client-tool-execution',
          toolName: tool.name,
          toolCallId: _str(binding['toolCallId']),
          tool: tool,
        );
      }
    }

    if (kind == 'generic' &&
        definitionId.isNotEmpty &&
        key.isNotEmpty &&
        batchIndex != null &&
        (firstPartyIndexes[batchIndex] ?? 0) != 1) {
      return base(
        kind: 'generic',
        canResolve: false,
        status: ChatInterruptStatus.error,
        effectiveBinding: derivedGenericBinding(),
        error: _itemError(
          id,
          'stale',
          'Generic interrupt batch contains a duplicate batchIndex.',
        ),
      );
    }

    final definition = _definitions[definitionId];
    if (correlated &&
        kind == 'generic' &&
        definition != null &&
        definitionId.isNotEmpty &&
        key.isNotEmpty &&
        batchIndex != null &&
        (firstPartyIndexes[batchIndex] ?? 0) == 1) {
      final responseHash = _definitionHash(definition.responseSchema);
      final payloadHash = _definitionHash(definition.payloadSchema);
      final responseOk = responseHash == bindingHash;
      final payloadOk = definition.payloadSchema == null
          ? !binding.containsKey('payloadSchemaHash')
          : payloadHash == binding['payloadSchemaHash'];
      if (responseOk && payloadOk) {
        return base(
          kind: 'generic',
          canResolve: true,
          definitionId: definition.id,
          key: key,
          batchIndex: batchIndex,
          definition: definition,
          payload: metadata['tanstack:interruptPayload'],
        );
      }
    }

    final resumable = _isLegacyInterruptMetadata(metadata) ||
        (candidateId == id &&
            candidateRun == interruptedRunId &&
            candidateGeneration == generation &&
            (kind != 'generic' ||
                rawSchemaHash == null ||
                bindingHash == rawSchemaHash));
    return base(
      kind: 'generic',
      canResolve: resumable,
      effectiveBinding: derivedGenericBinding(),
    );
  }

  bool _toolApprovalHashesMatch(
    Map<String, dynamic> binding,
    ClientTool tool,
  ) {
    final inputHash = _bindingHash(binding, 'inputSchemaHash');
    final approvalHash = _bindingHash(binding, 'approvalSchemaHash');
    final responseHash = _bindingHash(binding, 'responseSchemaHash');
    if (inputHash == null || approvalHash == null || responseHash == null) {
      return false;
    }
    try {
      final approval = normalizeApprovalSchema(
        clientToolApprovalSchema(tool),
        tool.inputSchema,
      );
      return hashSchemaInput(tool.inputSchema) == inputHash &&
          approval.approvalSchemaHash == approvalHash &&
          approval.responseSchemaHash == responseHash;
    } catch (_) {
      return false;
    }
  }

  bool _clientToolHashMatches(
    Map<String, dynamic> binding,
    ClientTool tool,
  ) {
    final expected = _bindingHash(binding, 'outputSchemaHash');
    if (expected == null) return false;
    try {
      return hashSchemaInput(tool.outputSchema) == expected;
    } catch (_) {
      return false;
    }
  }

  Map<String, dynamic> _deriveGenericBinding(
    Map<String, dynamic> raw,
    ChatHydrationInterrupts hydration,
    Map<String, dynamic>? candidate,
  ) {
    final schemaHash = _responseSchemaHash(raw) ??
        (candidate?['responseSchemaHash'] is String
            ? candidate!['responseSchemaHash'] as String
            : null);
    return <String, dynamic>{
      'v': 1,
      'kind': 'generic',
      'interruptId': _str(raw['id']),
      'interruptedRunId': hydration.runId,
      'generation': hydration.generation,
      if (schemaHash != null) 'responseSchemaHash': schemaHash,
      if (raw['expiresAt'] is String) 'expiresAt': raw['expiresAt'],
    };
  }

  String? _responseSchemaHash(Map<String, dynamic> raw) {
    final schema = raw['responseSchema'];
    if (schema == null) return null;
    try {
      return digestInterruptJson(canonicalInterruptJson(schema));
    } catch (_) {
      return null;
    }
  }

  String? _definitionHash(Object? schema) {
    if (schema == null) return null;
    try {
      return hashInterruptDefinitionSchema(schema);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _withContinuation(
    ChatInterrupt item,
    Map<String, dynamic> resolution,
  ) {
    if (item.definitionId == null ||
        item.key == null ||
        item.batchIndex == null) {
      return resolution;
    }
    final metadata = resolution['metadata'] is Map
        ? Map<String, dynamic>.from(resolution['metadata'] as Map)
        : <String, dynamic>{};
    final binding = item.binding;
    final responseHash = binding?['responseSchemaHash'];
    final payloadHash = binding?['payloadSchemaHash'];
    metadata.putIfAbsent(
      'tanstack:interruptContinuation',
      () => <String, dynamic>{
        'v': 1,
        'definitionId': item.definitionId,
        'key': item.key,
        'batchIndex': item.batchIndex,
        'reason': item.reason,
        'message': item.message ?? '',
        if (item.expiresAt != null) 'expiresAt': item.expiresAt,
        if (responseHash is String) 'responseSchemaHash': responseHash,
        if (payloadHash is String) 'payloadSchemaHash': payloadHash,
        if (item.metadata?.containsKey('tanstack:interruptPayload') == true)
          'payload': item.metadata!['tanstack:interruptPayload'],
      },
    );
    return <String, dynamic>{...resolution, 'metadata': metadata};
  }

  ClientTool? _toolNamed(String name) {
    for (final tool in _tools) {
      if (tool.name == name) return tool;
    }
    return null;
  }

  static Map<String, dynamic>? _bindingOf(Map<String, dynamic> raw) {
    final metadata = raw['metadata'];
    if (metadata is! Map) return null;
    final binding = metadata['tanstack:interruptBinding'];
    return binding is Map ? Map<String, dynamic>.from(binding) : null;
  }

  static bool _isLegacyApprovalMetadata(Map? metadata) =>
      metadata != null &&
      metadata['kind'] == 'approval' &&
      metadata['toolName'] is String &&
      metadata.containsKey('input');

  static bool _isLegacyClientToolMetadata(Map? metadata) =>
      metadata != null &&
      metadata['kind'] == 'client_tool' &&
      metadata['toolName'] is String;

  static bool _isLegacyInterruptMetadata(Map? metadata) =>
      _isLegacyApprovalMetadata(metadata) ||
      _isLegacyClientToolMetadata(metadata);

  static bool _hasFirstPartyGenericMarker(Map<String, dynamic> binding) {
    if (binding['kind'] != 'generic') return false;
    return binding.containsKey('definitionId') ||
        binding.containsKey('key') ||
        binding.containsKey('batchIndex') ||
        binding.containsKey('payloadSchemaHash');
  }

  static String? _bindingHash(Map<String, dynamic> binding, String key) {
    final value = binding[key];
    return value is String ? value : null;
  }

  static Object? _cloneJson(Object? value) {
    try {
      return jsonDecode(canonicalInterruptJson(value));
    } catch (_) {
      return value;
    }
  }

  static Object? _cloneMap(Object? value) {
    if (value == null) return null;
    try {
      return jsonDecode(canonicalInterruptJson(value));
    } catch (_) {
      if (value is Map) {
        return <String, dynamic>{
          for (final entry in value.entries) '${entry.key}': entry.value,
        };
      }
      return value;
    }
  }

  void dispose() {
    _disposed = true;
    _submission++;
    _items = <ChatInterrupt>[];
    _hydration = null;
    _snapshot = const <ChatInterrupt>[];
    _resuming = false;
    _activeTransaction = null;
    _lineage.clear();
  }

  static String _str(Object? value) => value == null ? '' : '$value';

  Map<String, dynamic> _itemError(
    String interruptId,
    String code,
    String message,
  ) {
    final hydration = _hydration;
    return <String, dynamic>{
      'scope': 'item',
      'interruptId': interruptId,
      'code': code,
      'message': message,
      'source': 'client',
      'retryable': false,
      'threadId': hydration?.effectiveThreadId ?? '',
      'interruptedRunId': hydration?.runId ?? '',
      'generation': hydration?.generation ?? 0,
    };
  }
}
