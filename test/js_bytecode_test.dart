// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

import 'package:gg_quickjs/gg_quickjs.dart';
import 'package:test/test.dart';

void main() {
  group('JsBytecode', () {
    group('JsBytecode(bytes)', () {
      test('holds the bytes of a compiled script', () {
        final runtime = JsRuntime();
        addTearDown(runtime.dispose);
        final bytecode = JsBytecode(runtime.compile('1 + 2').bytes);
        expect(runtime.evaluateBytecode(bytecode), 3);
      });
    });

    group('JsBytecode.example()', () {
      test('holds example bytes', () {
        expect(JsBytecode.example().bytes, isNotEmpty);
        final bytes = Uint8List.fromList([1]);
        expect(JsBytecode.example(bytes: bytes).bytes, same(bytes));
      });
    });
  });
}
