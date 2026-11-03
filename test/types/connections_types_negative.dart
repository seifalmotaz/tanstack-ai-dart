// ignore_for_file: unused_local_variable
import 'package:tanstack_ai_dart/connections.dart';

void invalidBounds() {
  final adapter = stream((request) => const Stream.empty());
  // expect-error: missing_required_argument
  adapter.connect!([]);
  // Non-finite JS numbers cannot inhabit Dart's int bounds or Duration input.
  // expect-error: argument_type_not_assignable
  ReconnectOptions(maxAttempts: double.nan);
  // expect-error: argument_type_not_assignable
  ReconnectOptions(maxAttempts: double.infinity);
  // expect-error: argument_type_not_assignable
  Duration(milliseconds: double.infinity);
}
