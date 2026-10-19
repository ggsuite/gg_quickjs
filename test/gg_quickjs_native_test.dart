// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:gg_quickjs/gg_quickjs.dart';
import 'package:gg_quickjs/src/gg_quickjs_native.dart';
import 'package:test/test.dart';

void main() {
  group('gg_quickjs_native', () {
    test('ggQjsVersion() names the QuickJS-ng version', () {
      expect(ggQjsVersion().cast<Utf8>().toDartString(), quickjsNgVersion);
    });

    test('opens, interrupts, closes and disposes a native runtime', () {
      final runtime = openNativeRuntime(
        memoryLimit: 0,
        maxStackSize: 256 * 1024,
        gcThreshold: 0,
        timeoutMicroseconds: 0,
        hostCall: nullptr,
        hostRelease: nullptr,
        moduleLoad: nullptr,
        rejection: nullptr,
      );
      expect(runtime, isNot(nullptr));
      interruptNativeRuntime(runtime.address);
      closeNativeRuntime(runtime.address);
      ggQjsDispose(runtime);
    });
  });
}
