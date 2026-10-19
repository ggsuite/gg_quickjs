// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:gg_quickjs/gg_quickjs.dart';
import 'package:test/test.dart';

void main() {
  late JsIsolateRuntime runtime;

  setUp(() async => runtime = await JsRuntime.spawn());
  tearDown(() => runtime.dispose());

  group('JsIsolateRuntime', () {
    group('spawn(options)', () {
      test('throws what the creation of the runtime throws', () async {
        await expectLater(
          JsIsolateRuntime.spawn(
            options: const JsRuntimeOptions(memoryLimit: 1024),
          ),
          throwsA(isA<JsOutOfMemoryError>()),
        );
      });

      test('throws for options that cannot reach the worker', () async {
        final port = ReceivePort();
        addTearDown(port.close);
        await expectLater(
          JsIsolateRuntime.spawn(
            options: JsRuntimeOptions(
              moduleLoader: (name) => port.hashCode.toString(),
            ),
          ),
          throwsArgumentError,
        );
      });
    });

    group('evaluate(code, sourceUrl)', () {
      test('returns copies of the values', () async {
        expect(await runtime.evaluate('6 * 7'), 42);
        expect(
          await runtime.evaluate('({a: [1, 2n], b: new Uint8Array([3])})'),
          {
            'a': [1, BigInt.two],
            'b': [3],
          },
        );
        expect(await runtime.evaluate('() => 1'), isNull);
        expect(runtime.options.timers, isFalse);
      });

      test('awaits a promise in the worker', () async {
        expect(await runtime.evaluate('Promise.resolve("later")'), 'later');
      });

      test('throws the errors of JavaScript', () async {
        await expectLater(
          runtime.evaluate('null.x', sourceUrl: 'main.js'),
          throwsA(
            isA<JsTypeError>().having(
              (e) => e.stack,
              'stack',
              contains('main.js'),
            ),
          ),
        );
        await expectLater(
          runtime.evaluate('throw {}'),
          throwsA(
            isA<JsError>().having(
              (e) => e.thrownValue,
              'value',
              <String, Object?>{},
            ),
          ),
        );
        await expectLater(
          runtime.evaluate('throw (() => 1)'),
          throwsA(isA<JsError>().having((e) => e.thrownValue, 'value', isNull)),
        );
      });
    });

    group('evaluateModule(code, sourceUrl)', () {
      test('returns the exports that can be copied', () async {
        await runtime.registerModules({'dep': 'export const base = 40;'});
        expect(
          await runtime.evaluateModule(
            "import { base } from 'dep';\n"
            'export const answer = base + 2;\n'
            'export function f() {}',
          ),
          {'answer': 42, 'f': null},
        );
      });
    });

    group('call(name, arguments), getGlobal(name), setGlobal(name, value)', () {
      test('exchange copies of values', () async {
        await runtime.evaluate('function add(a, b) { return a + b; }');
        expect(await runtime.call('add', [20, 22]), 42);
        await runtime.setGlobal('bytes', Uint8List.fromList([1, 2]));
        expect(await runtime.getGlobal('bytes'), [1, 2]);
        await expectLater(
          runtime.setGlobal('f', (List<Object?> args) => null),
          throwsArgumentError,
        );
      });
    });

    group('registerFunction(name, function)', () {
      test('runs the function on the calling isolate', () async {
        final isolates = <String>[];
        final registration = await runtime.registerFunction('where', (args) {
          isolates.add(Isolate.current.debugName ?? '');
          return 'called with ${args.first}';
        });
        expect(registration.name, 'where');
        expect(registration.id, greaterThan(0));
        expect(await runtime.evaluate('where(1)'), 'called with 1');
        expect(isolates, [Isolate.current.debugName ?? '']);
      });

      test('awaits a Future and raises errors', () async {
        await runtime.registerFunction('later', (args) async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return 2 * (args.first! as int);
        });
        await runtime.registerFunction(
          'typed',
          (_) => throw JsRangeError(message: 'r'),
        );
        await runtime.registerFunction('plain', (_) => throw StateError('s'));
        await runtime.registerFunction(
          'argument',
          (_) => throw ArgumentError('a'),
        );
        expect(await runtime.evaluate('later(21)'), 42);
        expect(
          await runtime.evaluate(
            'Promise.all([typed, plain, argument].map((f) => '
            'f().catch((e) => e.name + ": " + e.message)))',
          ),
          ['RangeError: r', 'Error: Bad state: s', 'TypeError: a'],
        );
      });

      test('refuses a call that arrives after revoke()', () async {
        final registration = await runtime.registerFunction('f', (_) => 1);
        // The worker runs f() before it receives the revocation.
        final result = runtime.evaluate('f()');
        final revoked = registration.revoke();
        await expectLater(
          result,
          throwsA(
            isA<JsTypeError>().having(
              (e) => e.message,
              'message',
              'the host function was revoked',
            ),
          ),
        );
        await revoked;
      });

      test('stops the function after revoke()', () async {
        final registration = await runtime.registerFunction('f', (_) => 1);
        await runtime.evaluate('var kept = f;');
        await registration.revoke();
        await registration.revoke();
        expect(registration.isRevoked, isTrue);
        expect(await runtime.evaluate('typeof f'), 'undefined');
        await expectLater(
          runtime.evaluate('kept()'),
          throwsA(isA<JsTypeError>()),
        );
      });
    });

    group('compile(code, sourceUrl, module), evaluateBytecode(bytecode)', () {
      test('compile in the worker and evaluate there', () async {
        final script = await runtime.compile('[1, 2].length');
        expect(await runtime.evaluateBytecode(script), 2);
        final module = await runtime.compile(
          'export const x = await Promise.resolve(1);',
          module: true,
        );
        expect(await runtime.evaluateBytecode(module), {'x': 1});
      });
    });

    group('executePendingJobs(), memoryUsage, runGc()', () {
      test('run in the worker', () async {
        await runtime.executePendingJobs();
        await runtime.runGc();
        final usage = await runtime.memoryUsage;
        expect(usage.allocatedBytes, greaterThan(0));
        expect(usage.limit, isNull);
      });
    });

    group('interrupt()', () {
      test('stops JavaScript while the worker is busy', () async {
        final started = Completer<void>();
        await runtime.registerFunction('started', (_) {
          started.complete();
          return null;
        });
        final result = runtime.evaluate('started(); for (;;) {}');
        await started.future;
        runtime.interrupt();
        await expectLater(
          result,
          throwsA(
            isA<JsInterruptedError>().having(
              (e) => e.timedOut,
              'timedOut',
              false,
            ),
          ),
        );
        expect(await runtime.evaluate('1'), 1);
      });
    });

    group('options.onConsole, options.onUnhandledRejection', () {
      test('run on the calling isolate', () async {
        final lines = <String>[];
        final reasons = <Object?>[];
        final other = await JsRuntime.spawn(
          options: JsRuntimeOptions(
            onConsole: (level, message) => lines.add('${level.name} $message'),
            onUnhandledRejection: reasons.add,
          ),
        );
        await other.evaluate('console.warn("w"); Promise.reject(7); 0');
        await other.evaluate('0');
        await other.dispose();
        expect(lines, ['warn w']);
        expect(reasons, [
          isA<JsError>().having((e) => e.message, 'message', '7'),
        ]);
      });

      test('are optional', () async {
        await runtime.evaluate('Promise.reject(1); 0');
        expect(await runtime.evaluate('typeof console'), 'undefined');
      });
    });

    group('dispose(graceful)', () {
      test('interrupts the calls in flight', () async {
        final started = Completer<void>();
        await runtime.registerFunction('started', (_) {
          started.complete();
          return null;
        });
        final result = runtime.evaluate('started(); for (;;) {}');
        await started.future;
        await runtime.dispose();
        await expectLater(result, throwsA(isA<JsInterruptedError>()));
        expect(runtime.isDisposed, isTrue);
        runtime.interrupt();
        await expectLater(runtime.evaluate('1'), throwsStateError);
        await runtime.dispose();
      });

      test('lets the calls in flight end with graceful', () async {
        final release = Completer<Object?>();
        await runtime.registerFunction('wait', (_) => release.future);
        final result = runtime.evaluate('wait()');
        final disposed = runtime.dispose(graceful: true);
        await expectLater(runtime.evaluate('1'), throwsStateError);
        release.complete('done');
        expect(await result, 'done');
        await disposed;
      });
    });
  });
}
