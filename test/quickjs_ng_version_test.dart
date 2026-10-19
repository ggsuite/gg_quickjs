// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_quickjs/gg_quickjs.dart';
import 'package:test/test.dart';

void main() {
  group('quickjsNgVersion', () {
    test('is the version that src/quickjs-ng/quickjs.h declares', () {
      final header = File('src/quickjs-ng/quickjs.h').readAsStringSync();
      String part(String name) =>
          RegExp('#define QJS_VERSION_$name (\\d+)')
              .firstMatch(header)!
              .group(1)!;
      expect(
        quickjsNgVersion,
        '${part('MAJOR')}.${part('MINOR')}.${part('PATCH')}',
      );
    });
  });
}
