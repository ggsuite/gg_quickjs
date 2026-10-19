// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_quickjs/gg_quickjs.dart';
import 'package:test/test.dart';

void main() {
  group('JsException', () {
    group('JsException.from(name, message, stack)', () {
      test('classifies by name and message', () {
        final cases = <(String, String), Matcher>{
          ('SyntaxError', 'x'): isA<JsSyntaxError>(),
          ('TypeError', 'x'): isA<JsTypeError>(),
          ('ReferenceError', 'x'): isA<JsReferenceError>(),
          ('RangeError', 'x'): isA<JsRangeError>(),
          ('RangeError', 'Maximum call stack size exceeded'):
              isA<JsStackOverflowError>(),
          ('InternalError', 'out of memory'): isA<JsOutOfMemoryError>(),
          ('InternalError', 'x'): isA<JsError>().having(
            (e) => e.name,
            'name',
            'InternalError',
          ),
          ('URIError', 'x'): isA<JsError>(),
        };
        cases.forEach((key, matcher) {
          final (name, message) = key;
          expect(JsException.from(name: name, message: message), matcher);
        });
      });
    });

    group('JsException.fromThrown(value)', () {
      test('keeps an exception and wraps any other value', () {
        final error = JsTypeError(message: 't');
        expect(JsException.fromThrown(error), same(error));
        expect(
          JsException.fromThrown(42),
          isA<JsError>()
              .having((e) => e.message, 'message', '42')
              .having((e) => e.thrownValue, 'thrownValue', 42),
        );
      });
    });

    group('JsException.fromDartError(error)', () {
      test('maps the errors of Dart to JavaScript errors', () {
        final error = JsRangeError(message: 'r');
        expect(JsException.fromDartError(error), same(error));
        expect(
          JsException.fromDartError(ArgumentError('a')),
          isA<JsTypeError>().having((e) => e.message, 'message', 'a'),
        );
        expect(
          JsException.fromDartError(StateError('s')),
          isA<JsError>().having((e) => e.message, 'message', 'Bad state: s'),
        );
      });
    });

    group('line, column', () {
      test('come from the first frame of the stack', () {
        final error = JsException.from(
          name: 'TypeError',
          message: 'x',
          stack: '    at f (native)\n    at g (C:\\a:b.js:3:14)\n',
        );
        expect(error.line, 3);
        expect(error.column, 14);
        expect(JsTypeError(message: 'x').line, isNull);
        expect(JsTypeError(message: 'x', line: 1, column: 2).column, 2);
      });
    });

    group('toString()', () {
      test('names the error, the message and the stack', () {
        expect(JsTypeError(message: 'bad').toString(), 'TypeError: bad');
        expect(
          JsSyntaxError.example().toString(),
          'SyntaxError: unexpected token in expression\n    at main.js:1:5\n',
        );
      });
    });

    group('examples', () {
      test('carry realistic values', () {
        final examples = <JsException>[
          JsSyntaxError.example(),
          JsTypeError.example(),
          JsReferenceError.example(),
          JsRangeError.example(),
          JsInterruptedError.example(),
          JsOutOfMemoryError.example(),
          JsStackOverflowError.example(),
          JsError.example(),
        ];
        expect(examples.map((e) => e.name), [
          'SyntaxError',
          'TypeError',
          'ReferenceError',
          'RangeError',
          'InternalError',
          'InternalError',
          'RangeError',
          'Error',
        ]);
        expect(JsInterruptedError.example().timedOut, isTrue);
        expect(JsInterruptedError().timedOut, isFalse);
        expect(JsOutOfMemoryError().message, 'out of memory');
        expect(JsStackOverflowError().line, isNull);
        expect(JsError.example().line, 3);
        expect(JsError(message: 'm', thrownValue: 1).thrownValue, 1);
        expect(JsSyntaxError.example(message: 'm').message, 'm');
        expect(JsTypeError.example(message: 'm').message, 'm');
        expect(JsReferenceError.example(message: 'm').message, 'm');
        expect(JsRangeError.example(message: 'm').message, 'm');
        expect(JsOutOfMemoryError.example(message: 'm').message, 'm');
        expect(JsStackOverflowError.example(stack: '').line, isNull);
        expect(JsError.example(name: 'N', message: 'm').name, 'N');
        expect(JsInterruptedError.example(timedOut: false).timedOut, isFalse);
      });
    });
  });
}
