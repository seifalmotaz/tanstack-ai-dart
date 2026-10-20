import 'dart:convert';
import 'dart:io';

/// Audit a `dart test --reporter json` run against explicit per-case mappings.
///
/// A mapping is verified only when its named Dart test actually ran and
/// passed. Test titles, test counts, fixtures, and mapping status alone never
/// count as coverage.
void main(List<String> args) {
  if (args.length < 2 || args.length > 4) {
    stderr.writeln(
      'Usage: dart run tool/parity_audit.dart dart-tests.json report.json '
      '[mappings-dir] [markdown-path]',
    );
    exitCode = 64;
    return;
  }

  final upstream =
      jsonDecode(File('tool/upstream_tests.json').readAsStringSync())
          as Map<String, dynamic>;
  final tests = _readTests(File(args[0]));
  final mappingDir = args.length >= 3 ? Directory(args[2]) : Directory('test');
  final mappings = _readMappings(mappingDir);
  final inventoryByFile = <String, List<(String key, String name)>>{};
  for (final source in upstream['files'] as List) {
    final file = source['file'] as String;
    for (final test in source['tests'] as List) {
      final name = test['name'] as String;
      inventoryByFile
          .putIfAbsent(file, () => <(String, String)>[])
          .add((_key(file, name), name));
    }
  }
  final orphanMappings = <Map<String, dynamic>>[];
  for (final entry in mappings.entries) {
    if (entry.kind == 'compile' ||
        entry.kind == 'notRepresentable' ||
        entry.raw.containsKey('upstreamAssertion')) {
      continue;
    }
    final exact = inventoryByFile[entry.upstreamFile]
            ?.where((candidate) => candidate.$2 == entry.upstreamName)
            .toList() ??
        const <(String, String)>[];
    if (exact.length == 1) {
      entry.resolvedKey = exact.single.$1;
      continue;
    }
    final candidates = inventoryByFile[entry.upstreamFile]
            ?.where((candidate) =>
                candidate.$2.endsWith(' ${entry.upstreamName}') ||
                entry.upstreamName.endsWith(' ${candidate.$2}'))
            .toList() ??
        const <(String, String)>[];
    final uniqueKeys = candidates.map((candidate) => candidate.$1).toSet();
    if (uniqueKeys.length == 1) {
      entry.resolvedKey = uniqueKeys.single;
    } else if (uniqueKeys.length > 1) {
      orphanMappings.add({
        ...entry.report,
        'reason': 'ambiguous shortened upstream name',
        'candidates': candidates.map((candidate) => candidate.$2).toList(),
      });
    } else {
      orphanMappings.add({
        ...entry.report,
        'reason': 'no upstream inventory case matches this mapping',
      });
    }
  }
  final markdownPath = args.length >= 4
      ? args[3]
      : '${Directory.current.path}/.dart_tool/parity_remaining.md';

  final byKey = <String, List<_MappingEntry>>{};
  for (final entry in mappings.entries) {
    final key = entry.resolvedKey ?? entry.key;
    byKey.putIfAbsent(key, () => <_MappingEntry>[]).add(entry);
  }

  final cases = <Map<String, dynamic>>[];
  final gapDetails = <String, List<Map<String, dynamic>>>{
    'mappedButFailed': <Map<String, dynamic>>[],
    'mappedButMissing': <Map<String, dynamic>>[],
    'mappedButSkipped': <Map<String, dynamic>>[],
    'mappedButAmbiguous': <Map<String, dynamic>>[],
    'notImplemented': <Map<String, dynamic>>[],
    'mappingStatusConflicts': <Map<String, dynamic>>[],
    'unmapped': <Map<String, dynamic>>[],
  };
  final compileCases = <Map<String, dynamic>>[];
  final adaptations = <Map<String, dynamic>>[];
  final notRepresentable = <Map<String, dynamic>>[];
  final titleOnlyCandidates = <Map<String, dynamic>>[];
  final verifiedKeys = <String>{};
  final mappedKeys = <String>{};
  final inventoryKeys = <String>{};

  for (final source in upstream['files'] as List) {
    final file = source['file'] as String;
    final sourceCases = <Map<String, dynamic>>[];
    for (final test in source['tests'] as List) {
      final name = test['name'] as String;
      final key = _key(file, name);
      inventoryKeys.add(key);
      final entries = byKey[key] ?? const <_MappingEntry>[];
      if (entries.isNotEmpty) mappedKeys.add(key);

      final verifiedEntries = <_MappingEntry>[];
      final entryReports = <Map<String, dynamic>>[];
      final failures = <_TargetFailure>[];
      var hasNotImplemented = false;
      final conflicts = <String>[];
      for (final entry in entries) {
        final kind = entry.kind;
        if (kind == 'compile') {
          compileCases.add(entry.report);
          continue;
        }
        if (kind == 'notRepresentable') {
          notRepresentable.add(entry.report);
          continue;
        }
        if (kind == 'adaptation') adaptations.add(entry.report);
        if (entry.isNotImplemented) hasNotImplemented = true;
        if (entry.isDeclaredFailing) {
          failures.add(_TargetFailure(entry, 'declared-failing'));
        }

        if (entry.status == 'moved' ||
            entry.dartTestName == null ||
            entry.dartFile == null) {
          entryReports.add({...entry.report, 'verified': false});
          continue;
        }
        final match = _match(entry, tests);
        final report = <String, dynamic>{
          ...entry.report,
          'kind': kind,
          if (match.suite != null) 'dartSuite': match.suite,
          if (match.name != null) 'dartMatchedName': match.name,
          'verified': match.passed,
        };
        entryReports.add(report);
        if (match.passed) {
          if (entry.isDeclaredFailing || entry.isNotImplemented) {
            conflicts.add('${entry.mappingPath}:${entry.status ?? 'mapped'}');
          } else {
            verifiedEntries.add(entry);
          }
        } else {
          failures.add(_TargetFailure(entry, match.failure));
        }
      }

      final verified = verifiedEntries.isNotEmpty;
      if (verified) verifiedKeys.add(key);
      if (conflicts.isNotEmpty) {
        gapDetails['mappingStatusConflicts']!.add({
          'upstreamFile': file,
          'upstream': name,
          'dartPassedFor': verifiedEntries
              .map((entry) => {
                    'file': entry.dartFile,
                    'test': entry.dartTestName,
                  })
              .toList(),
          'conflictingStatuses': conflicts,
        });
      }

      String? failureKind;
      if (!verified && entries.isNotEmpty) {
        if (hasNotImplemented) {
          failureKind = 'notImplemented';
        } else if (failures
            .any((failure) => failure.kind == 'declared-failing')) {
          failureKind = 'mappedButFailed';
        } else if (failures.any((failure) => failure.kind == 'skipped')) {
          failureKind = 'mappedButSkipped';
        } else if (failures.any((failure) => failure.kind == 'failed')) {
          failureKind = 'mappedButFailed';
        } else if (failures.any((failure) => failure.kind == 'ambiguous')) {
          failureKind = 'mappedButAmbiguous';
        } else if (failures.any((failure) => failure.kind == 'missing')) {
          failureKind = 'mappedButMissing';
        } else if (entries.every((entry) =>
            entry.kind == 'compile' || entry.kind == 'notRepresentable')) {
          failureKind = null;
        } else {
          failureKind = 'mappedButMissing';
        }
        if (failureKind != null) {
          gapDetails[failureKind]!.add({
            'upstreamFile': file,
            'upstream': name,
            'failure': failureKind,
            'mappings': entryReports,
          });
        }
      }

      if (entries.isEmpty) {
        final candidate =
            _titleCandidate(file, name, test['title'] as String?, tests);
        if (candidate != null) {
          titleOnlyCandidates.add({
            'upstreamFile': file,
            'upstream': name,
            'dartSuite': candidate.suite,
            'dartTestName': candidate.name,
            'reason': 'title-only; no explicit per-case mapping',
          });
        } else {
          gapDetails['unmapped']!.add({
            'upstreamFile': file,
            'upstream': name,
            'failure': 'unmapped',
          });
        }
      }

      sourceCases.add({
        'upstream': name,
        'status': verified
            ? 'verified'
            : failureKind ?? (entries.isEmpty ? 'unmapped' : 'non-runtime'),
        'verified': verified,
        'mappings': entryReports,
      });
    }
    cases.add({'file': file, 'tests': sourceCases});
  }

  // Mapping-only rows are compile/adaptation declarations (TypeScript type
  // cases, moved analyzer fixtures) rather than runtime inventory entries.
  for (final entry in mappings.entries) {
    if (inventoryKeys.contains(entry.key)) continue;
    if (entry.kind == 'notRepresentable') {
      notRepresentable.add(entry.report);
    } else if (entry.kind == 'compile') {
      compileCases.add(entry.report);
    } else {
      adaptations.add(entry.report);
    }
  }

  final runtimeTests = upstream['runtimeTests'] as int;
  final verifiedRuntime = verifiedKeys.length;
  final unmappedCount =
      gapDetails['unmapped']!.length + titleOnlyCandidates.length;
  final gapCount =
      gapDetails.values.fold<int>(0, (sum, list) => sum + list.length) +
          titleOnlyCandidates.length;
  final report = <String, dynamic>{
    'upstreamVersion': upstream['version'],
    'upstreamCommit': upstream['commit'],
    'upstreamPassed': upstream['baselinePassed'],
    'dartPassed': tests.values
        .where(
            (test) => test.passed && test.name.startsWith('loading ') == false)
        .length,
    'verifiedRuntime': verifiedRuntime,
    'nameMatched': verifiedRuntime,
    'mappedRuntime': mappedKeys.length,
    'uncovered': runtimeTests - verifiedRuntime,
    'unmapped': unmappedCount,
    'mappedButFailed': gapDetails['mappedButFailed']!.length,
    'mappedButMissing': gapDetails['mappedButMissing']!.length,
    'mappedButSkipped': gapDetails['mappedButSkipped']!.length,
    'mappedButAmbiguous': gapDetails['mappedButAmbiguous']!.length,
    'notImplemented': gapDetails['notImplemented']!.length,
    'mappingStatusConflicts': gapDetails['mappingStatusConflicts']!.length,
    'compileCases': compileCases.length,
    'adaptations': adaptations.length,
    'notRepresentable': notRepresentable.length,
    'titleOnlyReviewCandidates': titleOnlyCandidates.length,
    'orphanMappings': orphanMappings.length,
    'mappingFiles': mappings.files,
    'notice':
        'Only an explicit mapping to a Dart test that actually passed counts '
            'as verified. Titles, test counts, fixtures, and mapping status alone '
            'are not coverage.',
    'gaps': gapDetails,
    'compileCaseDetails': compileCases,
    'adaptationDetails': adaptations,
    'notRepresentableDetails': notRepresentable,
    'titleOnlyCandidateDetails': titleOnlyCandidates,
    'orphanMappingDetails': orphanMappings,
    'files': cases,
  };
  File(args[1]).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(report)}\n');
  final markdownFile = File(markdownPath);
  markdownFile.parent.createSync(recursive: true);
  markdownFile.writeAsStringSync(_markdown(report));

  stdout.writeln(
    'Upstream: $runtimeTests; verified: $verifiedRuntime; '
    'mapped: ${mappedKeys.length}; unmapped: $unmappedCount; gaps: $gapCount; '
    'compile: ${compileCases.length}; adaptations: ${adaptations.length}; '
    'not-representable: ${notRepresentable.length}; '
    'title-only review: ${titleOnlyCandidates.length}; '
    'orphan mappings: ${orphanMappings.length}.',
  );
  if (unmappedCount != 0 || gapCount != 0) exitCode = 1;
}

class _DartTest {
  final String name;
  final String? suite;
  final String? result;
  final bool skipped;
  final bool hidden;

  const _DartTest({
    required this.name,
    this.suite,
    this.result,
    this.skipped = false,
    this.hidden = false,
  });

  bool get passed =>
      result == 'success' &&
      !skipped &&
      !hidden &&
      !name.startsWith('loading ');
}

class _MatchResult {
  final String? suite;
  final String? name;
  final bool passed;
  final String failure;

  const _MatchResult({
    this.suite,
    this.name,
    this.passed = false,
    this.failure = 'missing',
  });
}

class _TargetFailure {
  final _MappingEntry entry;
  final String kind;
  const _TargetFailure(this.entry, this.kind);
}

class _Mappings {
  final List<_MappingEntry> entries;
  final List<String> files;
  const _Mappings(this.entries, this.files);
}

class _MappingEntry {
  final String mappingPath;
  final String upstreamFile;
  final String upstreamName;
  final String? upstreamTitle;
  final String? dartFile;
  final String? dartTestName;
  final String? movedTo;
  final String? status;
  final Map<String, dynamic> raw;
  String? resolvedKey;

  _MappingEntry({
    required this.mappingPath,
    required this.upstreamFile,
    required this.upstreamName,
    required this.raw,
    this.upstreamTitle,
    this.dartFile,
    this.dartTestName,
    this.movedTo,
    this.status,
  });

  String get key => _key(upstreamFile, upstreamName);

  bool get isNotImplemented => <String>{
        'not-implemented',
        'not_implemented',
        'blocked',
        'removed',
      }.contains(status);

  bool get isDeclaredFailing => <String>{
        'failing',
        'failed',
        'ported-failing',
      }.contains(status);

  String get kind {
    if (status == 'not-representable') return 'notRepresentable';
    if (upstreamFile.endsWith('.test-d.ts') ||
        status == 'ported-static' ||
        status == 'ported-static-adapted' ||
        status == 'preserved-existing' ||
        (dartTestName == null && dartFile != null)) {
      return 'compile';
    }
    if (status == 'moved') return 'compile';
    if (status == 'runtime-preserved' ||
        status == 'runtime-selector-name-check' ||
        status == 'ported-static-adapted' ||
        raw.containsKey('dartAdaptation') ||
        raw.containsKey('adaptation')) {
      return 'adaptation';
    }
    return 'runtime';
  }

  Map<String, dynamic> get report => <String, dynamic>{
        'mapping': mappingPath,
        'upstreamFile': upstreamFile,
        'upstream': upstreamName,
        if (upstreamTitle != null) 'upstreamTitle': upstreamTitle,
        if (dartFile != null) 'dartFile': dartFile,
        if (dartTestName != null) 'dartTestName': dartTestName,
        if (movedTo != null) 'movedTo': movedTo,
        if (status != null) 'status': status,
        'kind': kind,
        if (raw['actualAssertions'] != null)
          'actualAssertions': raw['actualAssertions'],
        if (raw['dartAdaptation'] != null)
          'dartAdaptation': raw['dartAdaptation'],
        if (raw['adaptation'] != null) 'adaptation': raw['adaptation'],
      };
}

String _key(String file, String name) => '$file\u0000$name';

_Mappings _readMappings(Directory root) {
  final entries = <_MappingEntry>[];
  final files = <String>[];
  if (!root.existsSync()) return _Mappings(entries, files);
  final mappingFiles = root
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) =>
          file.path.endsWith('.json') &&
          file.path.contains('mapping') &&
          !file.path.endsWith('upstream_tests.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in mappingFiles) {
    Map<String, dynamic> raw;
    try {
      raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    files.add(_relative(file.path));
    final defaultUpstreamFile = _string(raw['upstreamFile']);
    for (final key in <String>['mapped', 'cases']) {
      final list = raw[key];
      if (list is! List) continue;
      for (final item in list) {
        if (item is! Map) continue;
        final map = item is Map<String, dynamic>
            ? item
            : Map<String, dynamic>.from(item);
        final upstreamFile =
            _string(map['upstreamFile']) ?? defaultUpstreamFile;
        final upstreamName = _string(map['upstreamName']) ??
            _string(map['upstreamAssertion']) ??
            (map['upstreamLine'] == null
                ? null
                : 'line ${map['upstreamLine']}');
        if (upstreamFile == null || upstreamName == null) continue;
        entries.add(_MappingEntry(
          mappingPath: _relative(file.path),
          upstreamFile: upstreamFile,
          upstreamName: upstreamName,
          upstreamTitle: _string(map['upstreamTitle']),
          dartFile: _string(map['dartFile']),
          dartTestName: _string(map['dartTestName']),
          movedTo: _string(map['movedTo']),
          status: _string(map['status']),
          raw: map,
        ));
      }
    }
  }
  return _Mappings(entries, files);
}

Map<int, _DartTest> _readTests(File input) {
  final suites = <int, String>{};
  final started = <int, Map<String, dynamic>>{};
  final done = <int, Map<String, dynamic>>{};
  for (final line in input.readAsLinesSync()) {
    Map<String, dynamic> event;
    try {
      event = jsonDecode(line) as Map<String, dynamic>;
    } on FormatException {
      continue;
    }
    final type = event['type'];
    if (type == 'suite') {
      final suite = event['suite'] as Map;
      final path = suite['path'] as String?;
      if (path != null) suites[suite['id'] as int] = _relative(path);
    } else if (type == 'testStart') {
      final test = Map<String, dynamic>.from(event['test'] as Map);
      started[test['id'] as int] = test;
    } else if (type == 'testDone') {
      done[event['testID'] as int] = event;
    }
  }
  final out = <int, _DartTest>{};
  for (final entry in started.entries) {
    final test = entry.value;
    final result = done[entry.key];
    out[entry.key] = _DartTest(
      name: test['name'] as String? ?? '',
      suite: suites[test['suiteID'] as int?],
      result: result?['result'] as String?,
      skipped: result?['skipped'] == true,
      hidden: result?['hidden'] == true,
    );
  }
  return out;
}

_MatchResult _match(_MappingEntry entry, Map<int, _DartTest> tests) {
  final file = _relative(entry.dartFile!);
  final target = _cleanName(entry.dartTestName!);
  final inFile = tests.values
      .where((test) =>
          test.suite == file &&
          !test.name.startsWith('loading ') &&
          !test.hidden)
      .toList();
  var exact = inFile.where((test) => _cleanName(test.name) == target).toList();
  var matches = exact.isNotEmpty
      ? exact
      : inFile
          .where((test) => _cleanName(test.name).endsWith(' $target'))
          .toList();
  if (matches.isEmpty) {
    final any = tests.values.where(
      (test) =>
          !test.name.startsWith('loading ') &&
          (_cleanName(test.name) == target ||
              _cleanName(test.name).endsWith(' $target')),
    );
    if (any.isNotEmpty) {
      return _MatchResult(
        suite: any.first.suite,
        name: any.first.name,
        failure: 'missing',
      );
    }
    return const _MatchResult(failure: 'missing');
  }
  if (matches.length > 1) {
    final passedMatches = matches.where((test) => test.passed).toList();
    if (passedMatches.length == 1) {
      return _MatchResult(
        suite: passedMatches.single.suite,
        name: passedMatches.single.name,
        passed: true,
      );
    }
    return _MatchResult(
      suite: file,
      name: matches.first.name,
      failure: 'ambiguous',
    );
  }
  final match = matches.single;
  if (match.skipped) {
    return _MatchResult(
      suite: match.suite,
      name: match.name,
      failure: 'skipped',
    );
  }
  if (!match.passed) {
    return _MatchResult(
      suite: match.suite,
      name: match.name,
      failure: 'failed',
    );
  }
  return _MatchResult(suite: match.suite, name: match.name, passed: true);
}

_DartTest? _titleCandidate(
  String upstreamFile,
  String upstreamName,
  String? title,
  Map<int, _DartTest> tests,
) {
  final needles = <String>{
    _cleanName(upstreamName),
    if (title != null) _cleanName(title),
  };
  final matches = tests.values.where((test) {
    if (!test.passed || test.name.startsWith('loading ')) return false;
    final name = _cleanName(test.name);
    return needles.any((needle) => name == needle || name.endsWith(' $needle'));
  }).toList();
  if (matches.length != 1) return null;
  return matches.single;
}

String? _string(dynamic value) =>
    value is String && value.isNotEmpty ? value : null;

String _cleanName(String value) => value.replaceAll("\\'", "'").trim();

String _relative(String path) {
  var normalized = path.replaceAll('\\', '/');
  final cwd = Directory.current.absolute.path.replaceAll('\\', '/');
  if (normalized.startsWith('$cwd/')) {
    normalized = normalized.substring(cwd.length + 1);
  }
  while (normalized.startsWith('./')) {
    normalized = normalized.substring(2);
  }
  return normalized;
}

String _markdown(Map<String, dynamic> report) {
  final out = StringBuffer()
    ..writeln('# Parity remaining')
    ..writeln()
    ..writeln('- Upstream Vitest baseline: ${report['upstreamVersion']} / '
        '${report['upstreamCommit']}')
    ..writeln('- Verified by explicit passing Dart test: '
        '${report['verifiedRuntime']} / ${report['upstreamPassed']}')
    ..writeln('- Mapped upstream cases: ${report['mappedRuntime']}')
    ..writeln('- Unmapped: ${report['unmapped']}')
    ..writeln('- Mapped but failed: ${report['mappedButFailed']}')
    ..writeln('- Mapped but missing: ${report['mappedButMissing']}')
    ..writeln('- Mapped but skipped: ${report['mappedButSkipped']}')
    ..writeln('- Mapped but ambiguous: ${report['mappedButAmbiguous']}')
    ..writeln('- Not implemented: ${report['notImplemented']}')
    ..writeln('- Mapping status conflicts: '
        '${report['mappingStatusConflicts']}')
    ..writeln('- Compile cases: ${report['compileCases']}')
    ..writeln('- Adaptations: ${report['adaptations']}')
    ..writeln('- Not representable: ${report['notRepresentable']}')
    ..writeln('- Title-only review candidates: '
        '${report['titleOnlyReviewCandidates']}')
    ..writeln('- Orphan mappings: ${report['orphanMappings']}')
    ..writeln()
    ..writeln('> ${report['notice']}')
    ..writeln();

  void section(String title, String key) {
    final list = (report['gaps'] as Map)[key] as List? ?? const [];
    out.writeln('## $title (${list.length})');
    out.writeln();
    for (final item in list) {
      final map = item as Map;
      out.writeln('- `${map['upstreamFile']}` — ${map['upstream']}');
    }
    if (list.isEmpty) out.writeln('_None._');
    out.writeln();
  }

  section('Mapped but failed', 'mappedButFailed');
  section('Mapped but missing', 'mappedButMissing');
  section('Mapped but skipped', 'mappedButSkipped');
  section('Mapped but ambiguous', 'mappedButAmbiguous');
  section('Not implemented', 'notImplemented');
  section('Mapping status conflicts', 'mappingStatusConflicts');
  section('Unmapped', 'unmapped');

  out.writeln('## Title-only review candidates '
      '(${report['titleOnlyReviewCandidates']})');
  out.writeln();
  for (final item in report['titleOnlyCandidateDetails'] as List) {
    final map = item as Map;
    out.writeln('- `${map['upstreamFile']}` — ${map['upstream']} '
        '→ `${map['dartSuite']}` :: ${map['dartTestName']}');
  }
  if ((report['titleOnlyCandidateDetails'] as List).isEmpty) {
    out.writeln('_None._');
  }
  out.writeln();

  out.writeln('## Orphan mappings (${report['orphanMappings']})');
  out.writeln();
  for (final item in report['orphanMappingDetails'] as List) {
    final map = item as Map;
    out.writeln('- `${map['mapping']}` — `${map['upstreamFile']}` :: '
        '${map['upstream']} (${map['reason']})');
  }
  if ((report['orphanMappingDetails'] as List).isEmpty) out.writeln('_None._');
  out.writeln();

  out.writeln('## Compile cases (${report['compileCases']})');
  out.writeln();
  for (final item in report['compileCaseDetails'] as List) {
    final map = item as Map;
    out.writeln('- `${map['upstreamFile']}` — ${map['upstream']} '
        '→ `${map['dartFile'] ?? ''}`');
  }
  if ((report['compileCaseDetails'] as List).isEmpty) out.writeln('_None._');
  out.writeln();

  out.writeln('## Adaptations (${report['adaptations']})');
  out.writeln();
  for (final item in report['adaptationDetails'] as List) {
    final map = item as Map;
    out.writeln('- `${map['upstreamFile']}` — ${map['upstream']} '
        '→ `${map['dartFile'] ?? map['movedTo'] ?? ''}`');
  }
  if ((report['adaptationDetails'] as List).isEmpty) out.writeln('_None._');
  out.writeln();

  out.writeln('## Not representable (${report['notRepresentable']})');
  out.writeln();
  for (final item in report['notRepresentableDetails'] as List) {
    final map = item as Map;
    out.writeln('- `${map['upstreamFile']}` — ${map['upstream']}');
  }
  if ((report['notRepresentableDetails'] as List).isEmpty) {
    out.writeln('_None._');
  }
  out.writeln();
  return out.toString();
}
