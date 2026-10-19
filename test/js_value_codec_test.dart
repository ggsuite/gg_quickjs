// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

import 'package:gg_quickjs/gg_quickjs.dart';
import 'package:gg_quickjs/src/js_value_codec.dart';
import 'package:test/test.dart';

void main() {
  const codec = JsValueCodec();
  Object? roundTrip(Object? value) => codec.decode(codec.encode(value));

  group('JsValueCodec', () {
    group('encode(value), decode(bytes)', () {
      test('copy data both ways', () {
        final values = <Object?>[
          null,
          true,
          false,
          0,
          -2147483648,
          2147483647,
          1 << 40,
          0.5,
          double.infinity,
          'text with ünïcode',
          BigInt.parse('-123456789012345678901234567890'),
          DateTime.utc(2026, 10, 19, 12, 30),
          [1, 'a', null],
          <String, Object?>{
            'a': 1,
            'b': [true],
          },
          <Object?, Object?>{1: 'one', null: 'null'},
          <Object?>{1, 'two'},
        ];
        for (final value in values) {
          expect(roundTrip(value), value, reason: '$value');
        }
        expect(roundTrip(jsUndefined), isNull);
        expect(roundTrip(1 << 60), BigInt.from(1 << 60));
        expect(roundTrip(-0.0), isA<double>());
        expect(roundTrip(double.nan), isNaN);
        expect(roundTrip(2.0), isA<int>());
      });

      test('copy typed data with its type', () {
        final values = <TypedData, Matcher>{
          Uint8List.fromList([1, 2]): isA<Uint8List>(),
          Int8List.fromList([-1]): isA<Int8List>(),
          Uint8ClampedList.fromList([255]): isA<Uint8ClampedList>(),
          Int16List.fromList([-300]): isA<Int16List>(),
          Uint16List.fromList([300]): isA<Uint16List>(),
          Int32List.fromList([-70000]): isA<Int32List>(),
          Uint32List.fromList([70000]): isA<Uint32List>(),
          Float32List.fromList([0.5]): isA<Float32List>(),
          Float64List.fromList([0.25]): isA<Float64List>(),
          Int64List.fromList([-5]): isA<Int64List>(),
          Uint64List.fromList([5]): isA<Uint64List>(),
        };
        values.forEach((value, type) {
          final copy = roundTrip(value);
          expect(copy, type);
          expect(copy, value);
        });
        final view = Uint8List.fromList([1, 2, 3, 4]).buffer.asUint8List(1, 2);
        expect(roundTrip(view), [2, 3]);
        expect(roundTrip(ByteData(2)), [0, 0]);
        final buffer = roundTrip(Uint8List.fromList([9]).buffer)! as ByteBuffer;
        expect(buffer.asUint8List(), [9]);
      });

      test('copy errors as their kind', () {
        expect(
          roundTrip(JsTypeError(message: 'm', stack: '    at a.js:1:2\n')),
          isA<JsTypeError>()
              .having((e) => e.message, 'message', 'm')
              .having((e) => e.column, 'column', 2),
        );
      });

      test('refuse what cannot be copied', () {
        for (final value in [
          Object(),
          (List<Object?> args) => null,
          Future<Object?>.value(1),
        ]) {
          expect(
            () => codec.encode(value),
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.message,
                'message',
                contains('cannot be copied to another isolate'),
              ),
            ),
          );
        }
      });

      test('drop what cannot be copied with dropUncopyable', () {
        const dropping = JsValueCodec(dropUncopyable: true);
        final runtime = JsRuntime();
        addTearDown(runtime.dispose);
        final handle = runtime.evaluateHandle('({})');
        expect(
          dropping.decode(
            dropping.encode([
              (List<Object?> args) => null,
              Future<Object?>.value(1),
              handle,
              2,
            ]),
          ),
          [null, null, null, 2],
        );
        expect(() => dropping.encode(Object()), throwsArgumentError);
      });

      test('refuse values nested too deeply', () {
        Object? nested = 1;
        for (var i = 0; i <= JsValueCodec.maxDepth + 1; i++) {
          nested = [nested];
        }
        expect(() => codec.encode(nested), throwsArgumentError);
      });

      test('refuse an unknown tag and decode an unknown kind of bytes', () {
        expect(
          () => codec.decode(Uint8List.fromList([99])),
          throwsFormatException,
        );
        expect(codec.decode(Uint8List.fromList([11, 99, 1, 0, 0, 0, 7])), [7]);
      });

      test('decode handles to null without a host', () {
        expect(
          codec.decode(Uint8List.fromList([13, 1, 0, 0, 0, 0, 0, 0, 0, 0])),
          isNull,
        );
      });
    });

    group('with a runtime as host', () {
      test('passes functions, futures and handles', () async {
        final runtime = JsRuntime();
        addTearDown(runtime.dispose);
        runtime.setGlobal('value', {
          'f': (List<Object?> args) => 'called',
          'p': Future<Object?>.value('awaited'),
          'h': runtime.evaluateHandle('({x: 1})'),
        });
        expect(runtime.evaluate('value.f()'), 'called');
        expect(await (runtime.evaluate('value.p')! as Future), 'awaited');
        expect(runtime.evaluate('value.h.x'), 1);
        expect(
          () => runtime.setGlobal('value', Object()),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              'A Object cannot cross to JavaScript',
            ),
          ),
        );
      });
    });

    group('encodeHostFunction(id, name)', () {
      test('names the function', () {
        final runtime = JsRuntime();
        addTearDown(runtime.dispose);
        runtime.registerFunction('named', (_) => null);
        expect(runtime.evaluate('named.name'), 'named');
        expect(JsValueCodec.encodeHostFunction(id: 1, name: 'f').first, 16);
      });
    });

    group('JsValueCodec.example()', () {
      test('copies data only', () {
        expect(JsValueCodec.example().host, isNull);
        expect(JsHandleKind.values, hasLength(5));
      });
    });
  });
}
