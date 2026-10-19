// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_quickjs/gg_quickjs.dart';
import 'package:test/test.dart';

void main() {
  group('jsUndefined', () {
    test('becomes undefined in JavaScript', () {
      final runtime = JsRuntime();
      addTearDown(runtime.dispose);
      runtime.evaluate('function f(a = "default") { return a; }');
      expect(runtime.call('f', [jsUndefined]), 'default');
      expect(runtime.call('f', [null]), isNull);
    });

    test('prints as undefined', () {
      expect(jsUndefined.toString(), 'undefined');
    });
  });
}
