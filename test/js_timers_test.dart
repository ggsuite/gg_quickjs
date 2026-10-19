// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';

import 'package:gg_quickjs/gg_quickjs.dart';
import 'package:test/test.dart';

void main() {
  late JsRuntime runtime;
  late List<Object?> errors;

  setUp(() {
    errors = [];
    runtime = JsRuntime(
      options: JsRuntimeOptions(timers: true, onUnhandledRejection: errors.add),
    );
  });
  tearDown(() => runtime.dispose());

  Future<void> wait(int milliseconds) =>
      Future<void>.delayed(Duration(milliseconds: milliseconds));

  // Waits until [done] holds, at most ten seconds.
  Future<void> until(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!done() && DateTime.now().isBefore(deadline)) {
      await wait(2);
    }
  }

  group('setTimeout(callback, delay, ...args)', () {
    test('calls the callback once with its arguments', () async {
      runtime.evaluate(
        'var calls = []; setTimeout((a, b) => calls.push(a + b), 5, 20, 22); '
        'setTimeout(() => calls.push("now"));',
      );
      await until(() => (runtime.getGlobal('calls')! as List).length == 2);
      expect(runtime.getGlobal('calls'), ['now', 42]);
    });

    test('runs the jobs of the callback', () async {
      final result = runtime.evaluate(
        'new Promise((resolve) => setTimeout(() => resolve("later"), 1))',
      );
      expect(await (result! as Future), 'later');
    });

    test('reports the error of a callback', () async {
      runtime.evaluate('setTimeout(() => { throw new RangeError("t"); }, 1)');
      await until(() => errors.isNotEmpty);
      expect(errors, [isA<JsRangeError>()]);
    });

    test('refuses a callback that is no function', () {
      expect(
        () => runtime.evaluate('setTimeout("code", 1)'),
        throwsA(isA<JsTypeError>()),
      );
      expect(
        () => runtime.evaluate('setTimeout()'),
        throwsA(isA<JsTypeError>()),
      );
    });
  });

  group('clearTimeout(id)', () {
    test('cancels a timeout', () async {
      runtime.evaluate(
        'var fired = false; const id = setTimeout(() => fired = true, 5); '
        'clearTimeout(id); clearTimeout(); clearTimeout(12345);',
      );
      await wait(20);
      expect(runtime.getGlobal('fired'), isFalse);
    });
  });

  group('setInterval(callback, delay), clearInterval(id)', () {
    test('repeat until cleared', () async {
      runtime.evaluate(
        'var ticks = 0; const id = setInterval(() => { '
        'if (++ticks === 3) clearInterval(id); }, 2); '
        'var zero = 0; const fast = setInterval(() => { '
        'if (++zero === 2) clearInterval(fast); }); clearInterval();',
      );
      await until(
        () => runtime.getGlobal('ticks') == 3 && runtime.getGlobal('zero') == 2,
      );
      await wait(20);
      expect(runtime.getGlobal('ticks'), 3);
      expect(runtime.getGlobal('zero'), 2);
    });
  });

  group('dispose()', () {
    test('cancels the pending timers', () async {
      final other = JsRuntime(options: const JsRuntimeOptions(timers: true));
      other
        ..evaluate('setTimeout(() => {}, 5); setInterval(() => {}, 5);')
        ..dispose();
      await wait(20);
      expect(other.isDisposed, isTrue);
    });
  });

  group('without timers', () {
    test('the timer functions are absent', () {
      final other = JsRuntime();
      addTearDown(other.dispose);
      expect(
        other.evaluate(
          '[typeof setTimeout, typeof setInterval, typeof clearTimeout, '
          'typeof clearInterval]',
        ),
        ['undefined', 'undefined', 'undefined', 'undefined'],
      );
    });
  });
}
