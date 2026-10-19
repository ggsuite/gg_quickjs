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

  group('JsRegistration', () {
    group('revoke()', () {
      test('removes the function and makes kept references throw', () {
        final registration = runtime.registerFunction('answer', (_) => 42);
        expect(registration.name, 'answer');
        expect(registration.id, greaterThan(0));
        expect(registration.isRevoked, isFalse);
        runtime.evaluate('var kept = answer;');
        registration
          ..revoke()
          ..revoke();
        expect(registration.isRevoked, isTrue);
        expect(runtime.evaluate('typeof answer'), 'undefined');
        expect(() => runtime.evaluate('kept()'), throwsA(isA<JsTypeError>()));
      });

      test('keeps a newer registration of the same name', () {
        final first = runtime.registerFunction('f', (_) => 1);
        runtime.registerFunction('f', (_) => 2);
        first.revoke();
        expect(runtime.evaluate('f()'), 2);
      });

      test('is a no-op after the runtime is disposed', () {
        final other = JsRuntime();
        final registration = other.registerFunction('f', (_) => 1);
        other.dispose();
        registration.revoke();
        expect(registration.isRevoked, isTrue);
      });
    });
  });
}
