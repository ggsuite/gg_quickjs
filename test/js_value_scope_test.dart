// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_quickjs/gg_quickjs.dart';
import 'package:test/test.dart';

void main() {
  late JsRuntime runtime;

  setUp(() => runtime = JsRuntime());
  tearDown(() => runtime.dispose());

  group('withJsValues(body)', () {
    test('disposes the owned values and keeps released ones', () {
      late JsValue owned;
      late JsValue released;
      final sum = withJsValues((scope) {
        owned = scope.own(runtime.evaluateHandle('(a, b) => a + b'));
        released = scope.release(scope.own(runtime.evaluateHandle('({})')));
        return (owned as JsFunction)([20, 22]);
      });
      expect(sum, 42);
      expect(owned.isDisposed, isTrue);
      expect(released.isDisposed, isFalse);
      released.dispose();
    });

    test('disposes the owned values when the body throws', () {
      late JsValue owned;
      expect(
        () => withJsValues<void>((scope) {
          owned = scope.own(runtime.evaluateHandle('({})'));
          throw StateError('body');
        }),
        throwsStateError,
      );
      expect(owned.isDisposed, isTrue);
    });
  });

  group('withJsValuesAsync(body)', () {
    test('disposes the owned values when the future completes', () async {
      late JsValue owned;
      final value = await withJsValuesAsync((scope) async {
        owned = scope.own(runtime.evaluateHandle('Promise.resolve(7)'));
        return (owned as JsPromise).future;
      });
      expect(value, 7);
      expect(owned.isDisposed, isTrue);
    });
  });
}
