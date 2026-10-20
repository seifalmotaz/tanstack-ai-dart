import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;

@JS('globalThis')
external JSObject get _global;

bool isHidden() => web.document.hidden;

Future<void> yieldToHost() async {
  final scheduler = _global.getProperty<JSAny?>('scheduler'.toJS);
  if (scheduler != null && scheduler.isA<JSObject>()) {
    final object = scheduler as JSObject;
    final yieldFunction = object.getProperty<JSAny?>('yield'.toJS);
    if (yieldFunction != null && yieldFunction.isA<JSFunction>()) {
      await object.callMethod<JSPromise<JSAny?>>('yield'.toJS).toDart;
      return;
    }
  }
  await Future<void>.delayed(Duration.zero);
}
