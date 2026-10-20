import 'dart:convert';

abstract interface class JSONParser {
  /// Returns null for an unparseable prefix or a JSON null value.
  dynamic parse(String jsonString);
}

/// Incremental tool-argument parser matching TanStack's partial-json defaults.
class PartialJSONParser implements JSONParser {
  const PartialJSONParser();

  @override
  dynamic parse(String jsonString) {
    if (jsonString.trim().isEmpty) return null;
    try {
      return _Reader(jsonString.trim()).value();
    } on FormatException {
      return null;
    }
  }
}

const defaultJSONParser = PartialJSONParser();

dynamic parsePartialJSON(String jsonString) =>
    defaultJSONParser.parse(jsonString);

class _Reader {
  final String source;
  int position = 0;
  _Reader(this.source);

  String get current => position < source.length ? source[position] : '';

  void whitespace() {
    while (current.isNotEmpty && ' \n\r\t'.contains(current)) {
      position++;
    }
  }

  dynamic value() {
    whitespace();
    if (current.isEmpty) throw const FormatException('Incomplete JSON');
    if (current == '"') return string();
    if (current == '{') return object();
    if (current == '[') return array();
    final tail = source.substring(position);
    for (final literal in <String, dynamic>{
      'null': null,
      'true': true,
      'false': false,
      'Infinity': double.infinity,
      '-Infinity': double.negativeInfinity,
      'NaN': double.nan,
    }.entries) {
      if (tail.startsWith(literal.key) ||
          (literal.key.startsWith(tail) && tail != '-')) {
        position += literal.key.length;
        return literal.value;
      }
    }
    return number();
  }

  String string() {
    final start = position;
    var escaped = false;
    position++;
    while (position < source.length && (current != '"' || escaped)) {
      escaped = current == r'\' ? !escaped : false;
      position++;
    }
    if (current == '"') {
      position++;
      return jsonDecode(source.substring(start, position)) as String;
    }
    final end = position - (escaped ? 1 : 0);
    try {
      return jsonDecode('${source.substring(start, end)}"') as String;
    } on FormatException {
      final slash = source.lastIndexOf(r'\');
      if (slash < start) rethrow;
      return jsonDecode('${source.substring(start, slash)}"') as String;
    }
  }

  Map<String, dynamic> object() {
    position++;
    whitespace();
    final result = <String, dynamic>{};
    try {
      while (current != '}') {
        whitespace();
        if (current.isEmpty) return result;
        final key = string();
        whitespace();
        position++;
        result[key] = value();
        whitespace();
        if (current == ',') position++;
      }
    } on FormatException {
      return result;
    }
    position++;
    return result;
  }

  List<dynamic> array() {
    position++;
    final result = <dynamic>[];
    try {
      while (current != ']') {
        result.add(value());
        whitespace();
        if (current == ',') position++;
      }
    } on FormatException {
      return result;
    }
    position++;
    return result;
  }

  dynamic number() {
    final start = position;
    if (start == 0) {
      position = source.length;
    } else {
      if (current == '-') position++;
      while (current.isNotEmpty && !',]}'.contains(current)) {
        position++;
      }
    }
    try {
      return jsonDecode(source.substring(start, position));
    } on FormatException {
      final exponent = source.lastIndexOf('e');
      if (exponent < start) rethrow;
      return jsonDecode(source.substring(start, exponent));
    }
  }
}
