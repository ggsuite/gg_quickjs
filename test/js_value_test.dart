// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

import 'package:gg_quickjs/gg_quickjs.dart';
import 'package:test/test.dart';

void main() {
  late JsRuntime runtime;

  setUp(() => runtime = JsRuntime());
  tearDown(() => runtime.dispose());

  group('JsValue', () {
    group('toDart()', () {
      test('converts the value', () {
        final value = runtime.evaluateHandle('({a: [1, 2]})');
        expect(value.toDart(), {
          'a': [1, 2],
        });
        expect(value.runtime, same(runtime));
        value.dispose();
      });

      test('throws a StateError after dispose()', () {
        final value = runtime.evaluateHandle('1')..dispose();
        expect(value.isDisposed, isTrue);
        expect(
          value.toDart,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'The JsPrimitive is disposed',
            ),
          ),
        );
        value.dispose();
      });
    });

    group('dispose()', () {
      test('is a no-op after the runtime is disposed', () {
        final other = JsRuntime();
        final value = other.evaluateHandle('({})');
        other.dispose();
        value.dispose();
        expect(value.isDisposed, isTrue);
      });

      test('happens when Dart collects the handle', () async {
        int objects() => runtime.memoryUsage.objects;
        final before = objects();
        void createGarbage() {
          for (var i = 0; i < 100; i++) {
            runtime.evaluateHandle('({})');
          }
        }

        createGarbage();
        expect(objects(), greaterThanOrEqualTo(before + 100));
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        var garbage = <Object>[];
        while (objects() >= before + 100 && DateTime.now().isBefore(deadline)) {
          garbage = [for (var i = 0; i < 100000; i++) Object()];
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(garbage, isNotEmpty);
        expect(objects(), lessThan(before + 100));
      });
    });
  });

  group('JsObject', () {
    group('get(key), getHandle(key), set(key, value), keys', () {
      test('read and write properties', () {
        final object =
            runtime.evaluateHandle('({a: 1, 0: "zero"})') as JsObject;
        expect(object.get('a'), 1);
        expect(object.get(0), 'zero');
        object.set('b', [1, 2]);
        expect(object.keys, ['0', 'a', 'b']);
        final b = object.getHandle('b');
        expect(b, isA<JsObject>());
        expect(b.toDart(), [1, 2]);
        b.dispose();
        object.dispose();
        expect(() => object.get('a'), throwsStateError);
        expect(() => object.getHandle('a'), throwsStateError);
        expect(() => object.set('a', 1), throwsStateError);
        expect(() => object.keys, throwsStateError);
      });
    });
  });

  group('JsFunction', () {
    group('call(arguments, thisArg), callHandle(arguments, thisArg)', () {
      test('call the function', () {
        final function = runtime.evaluateHandle(
          '(function (a) { return [this?.x, a]; })',
        ) as JsFunction;
        final self = runtime.evaluateHandle('({x: "self"})');
        expect(function(['a']), [null, 'a']);
        expect(function.call(['a'], self), ['self', 'a']);
        final result = function.callHandle(['b'], self);
        expect(result.toDart(), ['self', 'b']);
        result.dispose();
        function.dispose();
        expect(() => function.call(), throwsStateError);
        expect(() => function.callHandle(), throwsStateError);
      });
    });
  });

  group('JsPromise', () {
    group('future', () {
      test('completes with the value of the promise', () async {
        final promise =
            runtime.evaluateHandle('Promise.resolve(42)') as JsPromise;
        expect(await promise.future, 42);
        promise.dispose();
        expect(() => promise.future, throwsStateError);
      });
    });
  });

  group('JsArrayBuffer', () {
    group('bytes', () {
      test('copies the bytes of the buffer', () {
        final buffer = runtime.evaluateHandle(
          'new Uint8Array([1, 2, 3]).buffer',
        ) as JsArrayBuffer;
        expect(buffer.bytes, Uint8List.fromList([1, 2, 3]));
        buffer.dispose();
      });
    });
  });

  group('JsPrimitive', () {
    test('holds a symbol', () {
      final symbol = runtime.evaluate('Symbol("s")');
      expect(symbol, isA<JsPrimitive>());
      runtime.setGlobal('symbol', symbol);
      expect(runtime.evaluate('typeof symbol'), 'symbol');
    });
  });
}
