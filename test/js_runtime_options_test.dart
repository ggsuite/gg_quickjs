// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_quickjs/gg_quickjs.dart';
import 'package:test/test.dart';

void main() {
  group('JsRuntimeOptions', () {
    group('JsRuntimeOptions()', () {
      test('grants nothing by default', () {
        const options = JsRuntimeOptions();
        expect(options.memoryLimit, isNull);
        expect(options.maxStackSize, JsRuntimeOptions.defaultMaxStackSize);
        expect(options.gcThreshold, isNull);
        expect(options.timeout, isNull);
        expect(options.onConsole, isNull);
        expect(options.onUnhandledRejection, isNull);
        expect(options.timers, isFalse);
        expect(options.network, isNull);
        expect(options.fileSystem, isNull);
        expect(options.moduleLoader, isNull);
      });
    });

    group('JsRuntimeOptions.example()', () {
      test('limits memory and time', () {
        final options = JsRuntimeOptions.example();
        expect(options.memoryLimit, 32 * 1024 * 1024);
        expect(options.timeout, const Duration(seconds: 1));
        expect(
          JsRuntimeOptions.example(
            memoryLimit: 1,
            timeout: Duration.zero,
          ).memoryLimit,
          1,
        );
      });
    });

    group('copyWith(...)', () {
      test('replaces the given values', () {
        void onConsole(JsConsoleLevel level, String message) {}
        void onRejection(Object? reason) {}
        String? loader(String name) => null;
        final network = JsNetworkAccess.example();
        final fileSystem = JsFileSystemAccess.example();
        final copy = const JsRuntimeOptions().copyWith(
          memoryLimit: 1,
          maxStackSize: 2,
          gcThreshold: 3,
          timeout: const Duration(seconds: 4),
          onConsole: onConsole,
          onUnhandledRejection: onRejection,
          timers: true,
          network: network,
          fileSystem: fileSystem,
          moduleLoader: loader,
        );
        expect(copy.memoryLimit, 1);
        expect(copy.maxStackSize, 2);
        expect(copy.gcThreshold, 3);
        expect(copy.timeout, const Duration(seconds: 4));
        expect(copy.onConsole, onConsole);
        expect(copy.onUnhandledRejection, onRejection);
        expect(copy.timers, isTrue);
        expect(copy.network, network);
        expect(copy.fileSystem, fileSystem);
        expect(copy.moduleLoader, loader);
        final same = copy.copyWith();
        expect(same.memoryLimit, 1);
        expect(same.moduleLoader, loader);
      });
    });

    group('JsConsoleLevel', () {
      test('names the console functions', () {
        expect(JsConsoleLevel.values.map((level) => level.name), [
          'debug',
          'log',
          'info',
          'warn',
          'error',
        ]);
      });
    });
  });
}
