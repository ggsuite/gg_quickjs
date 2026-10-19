// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_quickjs/gg_quickjs.dart';
import 'package:test/test.dart';

void main() {
  group('JsMemoryUsage', () {
    group('JsMemoryUsage.example()', () {
      test('holds realistic values', () {
        final usage = JsMemoryUsage.example(allocatedBytes: 1, limit: 2);
        expect(usage.allocatedBytes, 1);
        expect(usage.limit, 2);
        expect(JsMemoryUsage.example().limit, isNull);
      });
    });

    group('toString()', () {
      test('names every field', () {
        expect(
          JsMemoryUsage.example().toString(),
          'JsMemoryUsage(allocatedBytes: 262144, allocations: 1830, '
          'limit: null, usedBytes: 241920, objects: 412, strings: 960, '
          'functions: 520)',
        );
      });
    });

    group('JsRuntime.memoryUsage', () {
      test('reports the limit', () {
        final runtime = JsRuntime(
          options: const JsRuntimeOptions(memoryLimit: 8 << 20),
        );
        addTearDown(runtime.dispose);
        expect(runtime.memoryUsage.limit, 8 << 20);
      });
    });
  });
}
