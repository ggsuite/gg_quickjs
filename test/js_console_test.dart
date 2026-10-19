// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_quickjs/gg_quickjs.dart';
import 'package:test/test.dart';

void main() {
  group('console', () {
    test('passes every level to onConsole', () {
      final lines = <String>[];
      final runtime = JsRuntime(
        options: JsRuntimeOptions(
          onConsole: (level, message) => lines.add('${level.name}: $message'),
        ),
      );
      addTearDown(runtime.dispose);
      runtime.evaluate(
        'console.debug("d"); console.log("l", 1, true, null, undefined);\n'
        'console.info({a: [1]}); console.warn(1n);\n'
        'const cyclic = {}; cyclic.self = cyclic; console.error(cyclic);',
      );
      expect(lines, [
        'debug: d',
        'log: l 1 true null undefined',
        'info: {"a":[1]}',
        'warn: 1',
        'error: [object Object]',
      ]);
    });

    test('prints errors with their stack', () {
      final lines = <String>[];
      final runtime = JsRuntime(
        options: JsRuntimeOptions(
          onConsole: (_, message) => lines.add(message),
        ),
      );
      addTearDown(runtime.dispose);
      runtime.evaluate(
        'console.log(new TypeError("bad")); '
        'const e = new Error("plain"); e.stack = ""; console.log(e);',
        sourceUrl: 'log.js',
      );
      expect(lines, [
        allOf(startsWith('TypeError: bad\n'), contains('log.js:1:')),
        'Error: plain',
      ]);
    });

    test('is absent without onConsole', () {
      final runtime = JsRuntime();
      addTearDown(runtime.dispose);
      expect(runtime.evaluate('typeof console'), 'undefined');
    });
  });
}
