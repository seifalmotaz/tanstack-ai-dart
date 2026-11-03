/// Ported from `packages/ai-client/src/message-date-normalizer.ts`.
library;

DateTime? _validDate(Object? value) {
  if (value is DateTime) {
    return value.isUtc || !value.isAtSameMomentAs(value) ? value : value;
  }
  if (value is! String) return null;
  return DateTime.tryParse(value);
}

Map<String, dynamic> normalizeMessageDates(Map<String, dynamic> message) {
  final messageDate = _validDate(message['createdAt']);
  final rawParts = message['parts'];
  final parts = rawParts is List
      ? rawParts.map((rawPart) {
          if (rawPart is! Map) return rawPart;
          final part = Map<String, dynamic>.from(rawPart);
          if (part['type'] != 'tool-result') return part;
          final date = _validDate(part['createdAt']);
          part.remove('createdAt');
          if (date != null) part['createdAt'] = date;
          return part;
        }).toList()
      : rawParts;
  final next = Map<String, dynamic>.of(message);
  next.remove('createdAt');
  if (messageDate != null) next['createdAt'] = messageDate;
  if (parts != null) next['parts'] = parts;
  return next;
}

List<Map<String, dynamic>> normalizeMessagesDates(
  List<Map<String, dynamic>> messages,
) =>
    messages.map(normalizeMessageDates).toList(growable: false);
