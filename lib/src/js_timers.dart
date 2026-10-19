// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';

import 'js_exception.dart';
import 'js_runtime.dart';

// .............................................................................
/// Installs `setTimeout`, `setInterval`, `clearTimeout` and `clearInterval`
/// in [runtime] on Dart timers of the calling isolate; returns the function
/// that cancels every timer.
///
/// A callback runs as a call into JavaScript with its pending jobs; its
/// error goes to [JsRuntime.reportUncaughtError].
void Function() installJsTimers(JsRuntime runtime) {
  final timers = <int, (Timer, JsFunction)>{};
  var nextId = 1;

  void cancel(Object? id) {
    final entry = timers.remove(id);
    if (entry == null) return;
    entry.$1.cancel();
    entry.$2.dispose();
  }

  Object? schedule(List<Object?> arguments, {required bool repeat}) {
    final callback = arguments.isEmpty ? null : arguments[0];
    if (callback is! JsFunction) {
      throw JsTypeError(message: 'the callback must be a function');
    }
    final delay = arguments.length > 1 ? arguments[1] : null;
    final milliseconds = delay is num && delay > 0
        ? delay.clamp(0, _maxDelay).toInt()
        : 0;
    final rest = arguments.length > 2
        ? arguments.sublist(2)
        : const <Object?>[];
    final id = nextId++;
    void fire() {
      if (!repeat) timers.remove(id);
      try {
        callback(rest);
      } catch (error) {
        runtime.reportUncaughtError(error);
      } finally {
        if (!repeat) callback.dispose();
      }
    }

    final duration = Duration(milliseconds: milliseconds);
    final timer = repeat
        ? Timer.periodic(
            milliseconds > 0 ? duration : const Duration(milliseconds: 1),
            (_) => fire(),
          )
        : Timer(duration, fire);
    timers[id] = (timer, callback);
    return id;
  }

  runtime
    ..registerFunction(
      'setTimeout',
      (arguments) => schedule(arguments, repeat: false),
    )
    ..registerFunction(
      'setInterval',
      (arguments) => schedule(arguments, repeat: true),
    )
    ..registerFunction('clearTimeout', (arguments) {
      if (arguments.isNotEmpty) cancel(arguments[0]);
      return null;
    })
    ..registerFunction('clearInterval', (arguments) {
      if (arguments.isNotEmpty) cancel(arguments[0]);
      return null;
    });

  return () {
    for (final (timer, _) in timers.values) {
      timer.cancel();
    }
    timers.clear();
  };
}

// The longest delay in milliseconds, 2^31 - 1 as in browsers; a longer one,
// `Infinity` included, waits that long.
const _maxDelay = 0x7fffffff;
