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
  late JsRuntime runtime;

  setUp(() => runtime = JsRuntime());
  tearDown(() => runtime.dispose());

  group('JsRuntime', () {
    group('JsRuntime(options)', () {
      test('refuses limits that are not positive', () {
        for (final options in [
          const JsRuntimeOptions(memoryLimit: 0),
          const JsRuntimeOptions(maxStackSize: 0),
          const JsRuntimeOptions(gcThreshold: -1),
          const JsRuntimeOptions(timeout: Duration.zero),
        ]) {
          expect(() => JsRuntime(options: options), throwsArgumentError);
        }
      });

      test('throws JsOutOfMemoryError when the limit leaves no room', () {
        expect(
          () => JsRuntime(options: const JsRuntimeOptions(memoryLimit: 1024)),
          throwsA(
            isA<JsOutOfMemoryError>().having(
              (e) => e.message,
              'message',
              'the memory limit leaves no room for a runtime',
            ),
          ),
        );
      });

      test('throws JsOutOfMemoryError when the capabilities do not fit', () {
        // Between a limit too low for the runtime and one that fits all,
        // some limits let the runtime start but not its capabilities.
        final outcomes = <String>{};
        for (var limit = 64 * 1024; limit < 400 * 1024; limit += 2048) {
          try {
            JsRuntime(
              options: JsRuntimeOptions(
                memoryLimit: limit,
                onConsole: (_, _) {},
                timers: true,
              ),
            ).dispose();
            outcomes.add('started');
          } on JsOutOfMemoryError catch (error) {
            outcomes.add(error.message);
          }
        }
        expect(outcomes, contains('started'));
        expect(outcomes, contains('out of memory'));
      });

      test('does not keep its isolate alive', () async {
        final exited = ReceivePort();
        await Isolate.spawn((_) => JsRuntime(), null, onExit: exited.sendPort);
        await exited.first.timeout(const Duration(seconds: 10));
      });
    });

    group('JsRuntime.example()', () {
      test('applies the example limits', () {
        final example = JsRuntime.example();
        addTearDown(example.dispose);
        expect(example.options.memoryLimit, 32 * 1024 * 1024);
        expect(example.memoryUsage.limit, 32 * 1024 * 1024);
      });
    });

    group('evaluate(code, sourceUrl)', () {
      test('converts the primitives of JavaScript', () {
        expect(runtime.evaluate('undefined'), isNull);
        expect(runtime.evaluate('null'), isNull);
        expect(runtime.evaluate('true'), isTrue);
        expect(runtime.evaluate('false'), isFalse);
        expect(runtime.evaluate('6 * 7'), 42);
        expect(runtime.evaluate('2 ** 40'), 1099511627776);
        expect(runtime.evaluate('0.5'), 0.5);
        expect(runtime.evaluate('0.5 * 4'), 2);
        expect(runtime.evaluate('-0'), isA<double>());
        expect(runtime.evaluate('NaN'), isNaN);
        expect(runtime.evaluate('-Infinity'), double.negativeInfinity);
        expect(runtime.evaluate('"Grüße 🎉"'), 'Grüße 🎉');
        expect(runtime.evaluate('2n ** 70n'), BigInt.two.pow(70));
      });

      test('converts arrays, objects, maps and sets', () {
        expect(
          runtime.evaluate(
            '({list: [1, "a", [true]], nested: {x: null}, '
            'map: new Map([[1, "one"], ["k", 2]]), set: new Set([1, 2])})',
          ),
          {
            'list': [
              1,
              'a',
              [true],
            ],
            'nested': {'x': null},
            'map': {1: 'one', 'k': 2},
            'set': {1, 2},
          },
        );
      });

      test('converts dates, errors and typed arrays', () {
        expect(
          runtime.evaluate('new Date(Date.UTC(2026, 9, 19, 12, 0, 0, 5))'),
          DateTime.utc(2026, 10, 19, 12, 0, 0, 5),
        );
        expect(runtime.evaluate('new Date(NaN)'), isNull);
        expect(
          runtime.evaluate('new TypeError("bad")'),
          isA<JsTypeError>().having((e) => e.message, 'message', 'bad'),
        );
        expect(runtime.evaluate('new Uint8Array([1, 2, 3])'), [1, 2, 3]);
        expect(
          runtime.evaluate('new Int16Array([-1, 300])'),
          isA<Int16List>().having((list) => list, 'values', [-1, 300]),
        );
        expect(runtime.evaluate('new Float16Array([0.5, 2])'), [0.5, 2]);
        expect(
          (runtime.evaluate('new Uint8Array([7, 8]).buffer')! as ByteBuffer)
              .asUint8List(),
          [7, 8],
        );
      });

      test('returns a function as a JsFunction', () {
        final add = runtime.evaluate('(a, b) => a + b')! as JsFunction;
        expect(add([20, 22]), 42);
      });

      test('returns a promise as a Future', () async {
        expect(await (runtime.evaluate('Promise.resolve(42)')! as Future), 42);
        await expectLater(
          runtime.evaluate('Promise.reject(new RangeError("no"))')! as Future,
          throwsA(isA<JsRangeError>()),
        );
        await expectLater(
          runtime.evaluate('Promise.reject(42)')! as Future,
          throwsA(
            isA<JsError>().having((e) => e.thrownValue, 'thrownValue', 42),
          ),
        );
      });

      test('runs the pending jobs before it returns', () {
        runtime.evaluate(
          'var done = false; Promise.resolve().then(() => '
          'done = true);',
        );
        expect(runtime.getGlobal('done'), isTrue);
      });

      test('refuses a cyclic value', () {
        expect(
          () => runtime.evaluate('const a = {}; a.self = a; a'),
          throwsA(isA<JsTypeError>()),
        );
      });

      test('reads the entries of a Map through its iterator', () {
        expect(
          () => runtime.evaluate(
            'Map.prototype[Symbol.iterator] = function* () {\n'
            '  yield {get 0() { throw new Error("entry"); }};\n'
            '};\n'
            'new Map([[1, 2]])',
          ),
          throwsA(isA<JsError>().having((e) => e.message, 'message', 'entry')),
        );
      });

      test('refuses a value nested too deeply', () {
        expect(
          () => runtime.evaluate(
            'let v = []; for (let i = 0; i < 300; i++) v = [v]; v',
          ),
          throwsA(isA<JsRangeError>()),
        );
      });

      test('throws errors with their line and column', () {
        expect(
          () => runtime.evaluate('\n  null.x', sourceUrl: 'main.js'),
          throwsA(
            isA<JsTypeError>()
                .having((e) => e.line, 'line', 2)
                .having((e) => e.column, 'column', 3)
                .having((e) => e.stack, 'stack', contains('main.js:2:3')),
          ),
        );
        expect(
          () => runtime.evaluate('let = = 3', sourceUrl: 'syntax.js'),
          throwsA(isA<JsSyntaxError>().having((e) => e.line, 'line', 1)),
        );
        expect(
          () => runtime.evaluate('answer'),
          throwsA(isA<JsReferenceError>()),
        );
        expect(
          () => runtime.evaluate('new Array(-1)'),
          throwsA(isA<JsRangeError>()),
        );
        expect(
          () => runtime.evaluate('throw new URIError("u")'),
          throwsA(isA<JsError>().having((e) => e.name, 'name', 'URIError')),
        );
        expect(
          () => runtime.evaluate('throw "plain"'),
          throwsA(
            isA<JsError>()
                .having((e) => e.message, 'message', 'plain')
                .having((e) => e.thrownValue, 'thrownValue', 'plain'),
          ),
        );
      });

      test('describes an error it cannot convert', () {
        expect(
          () => runtime.evaluate('const e = {}; e.e = e; throw e;'),
          throwsA(
            isA<JsError>().having(
              (e) => e.message,
              'message',
              'the thrown value cannot be converted',
            ),
          ),
        );
      });
    });

    group('evaluateHandle(code, sourceUrl)', () {
      test('returns handles of each kind', () {
        withJsValues((scope) {
          expect(scope.own(runtime.evaluateHandle('1')), isA<JsPrimitive>());
          expect(scope.own(runtime.evaluateHandle('({})')), isA<JsObject>());
          expect(
            scope.own(runtime.evaluateHandle('() => 1')),
            isA<JsFunction>(),
          );
          expect(
            scope.own(runtime.evaluateHandle('Promise.resolve()')),
            isA<JsPromise>(),
          );
          expect(
            scope.own(runtime.evaluateHandle('new ArrayBuffer(2)')),
            isA<JsArrayBuffer>(),
          );
        });
      });
    });

    group('evaluateModule(code, sourceUrl)', () {
      test('returns the exports after top-level await', () async {
        final exports = await runtime.evaluateModule(
          'export const answer = await Promise.resolve(42);\n'
          'export function twice(x) { return 2 * x; }',
        );
        expect(exports['answer'], 42);
        expect((exports['twice']! as JsFunction)([21]), 42);
      });

      test('imports registered modules and loaded modules', () async {
        final runtime = JsRuntime(
          options: JsRuntimeOptions(
            moduleLoader: (name) =>
                name == 'lib/loaded.js' ? 'export const b = 2;' : null,
          ),
        );
        addTearDown(runtime.dispose);
        runtime.registerModules({'lib/registered.js': 'export const a = 1;'});
        final exports = await runtime.evaluateModule(
          "import { a } from './registered.js';\n"
          "import { b } from './loaded.js';\n"
          'export const sum = a + b;\n'
          'export const url = import.meta.url;',
          sourceUrl: 'lib/main.js',
        );
        expect(exports, {'sum': 3, 'url': 'lib/main.js'});
      });

      test('fails for an unknown module or a failing loader', () async {
        final runtime = JsRuntime(
          options: JsRuntimeOptions(
            moduleLoader: (name) => name == 'broken'
                ? throw JsError(message: 'the loader broke')
                : name == 'odd'
                ? throw StateError('odd')
                : null,
          ),
        );
        addTearDown(runtime.dispose);
        await expectLater(
          runtime.evaluateModule("import 'missing';"),
          throwsA(
            isA<JsReferenceError>().having(
              (e) => e.message,
              'message',
              "could not load module 'missing'",
            ),
          ),
        );
        await expectLater(
          runtime.evaluateModule("import 'broken';"),
          throwsA(
            isA<JsReferenceError>().having(
              (e) => e.message,
              'message',
              "could not load module 'broken': the loader broke",
            ),
          ),
        );
        await expectLater(
          runtime.evaluateModule("import 'odd';"),
          throwsA(
            isA<JsReferenceError>().having(
              (e) => e.message,
              'message',
              contains('Bad state: odd'),
            ),
          ),
        );
      });

      test('fails when the module throws', () async {
        await expectLater(
          runtime.evaluateModule('throw new TypeError("module");'),
          throwsA(isA<JsTypeError>()),
        );
        await expectLater(
          runtime.evaluateModule('export const = 1;'),
          throwsA(isA<JsSyntaxError>()),
        );
      });
    });

    group('call(name, arguments)', () {
      test('calls a global function', () {
        runtime.evaluate('function add(a, b) { return a + b; }');
        expect(runtime.call('add', [20, 22]), 42);
      });

      test('throws a JsTypeError for a value that is no function', () {
        runtime.evaluate('var notAFunction = 1;');
        expect(
          () => runtime.call('notAFunction'),
          throwsA(
            isA<JsTypeError>().having(
              (e) => e.message,
              'message',
              'notAFunction is not a function',
            ),
          ),
        );
      });
    });

    group('getGlobal(name), setGlobal(name, value)', () {
      test('exchange Dart values', () {
        final values = <String, Object?>{
          'number': 7,
          'large': 1 << 40,
          'huge': 1 << 60,
          'double': 0.25,
          'string': 'text',
          'bool': true,
          'nothing': null,
          'big': BigInt.parse('123456789012345678901234567890'),
          'list': [1, 'two', null],
          'map': {'a': 1},
          'dart map': {1: 'one'},
          'set': {'x'},
          'date': DateTime.utc(2026, 1, 2),
          'bytes': Uint8List.fromList([1, 2]),
          'buffer': Uint8List.fromList([3, 4]).buffer,
          'int32': Int32List.fromList([-5, 5]),
          'error': JsTypeError(message: 'from Dart'),
        };
        values.forEach(runtime.setGlobal);
        expect(runtime.getGlobal('huge'), BigInt.from(1 << 60));
        expect(runtime.evaluate('typeof huge'), 'bigint');
        expect(
          runtime.evaluate(
            'dart_map_is_map = this["dart map"] '
            'instanceof Map',
          ),
          isTrue,
        );
        expect(runtime.evaluate('error instanceof TypeError'), isTrue);
        for (final name in [
          'number',
          'large',
          'double',
          'string',
          'bool',
          'nothing',
          'big',
          'list',
          'map',
          'dart map',
          'set',
          'date',
          'bytes',
          'int32',
        ]) {
          expect(runtime.getGlobal(name), values[name], reason: name);
        }
        expect((runtime.getGlobal('buffer')! as ByteBuffer).asUint8List(), [
          3,
          4,
        ]);
      });

      test('passes jsUndefined as undefined', () {
        runtime.setGlobal('value', jsUndefined);
        expect(runtime.evaluate('value === undefined'), isTrue);
      });

      test('turns a Dart function into a JavaScript function', () {
        runtime.setGlobal(
          'twice',
          (List<Object?> args) => 2 * (args[0]! as int),
        );
        expect(runtime.evaluate('twice(21)'), 42);
      });

      test('turns a Future into a promise', () async {
        runtime.setGlobal('later', Future<Object?>.value(42));
        expect(await (runtime.evaluate('later')! as Future), 42);
        runtime.setGlobal('failing', Future<Object?>.error(StateError('no')));
        await expectLater(
          runtime.evaluate('failing')! as Future,
          throwsA(
            isA<JsError>().having(
              (e) => e.message,
              'message',
              'Bad '
                  'state: no',
            ),
          ),
        );
        runtime.setGlobal('odd', Future<Object?>.value(Object()));
        await expectLater(
          runtime.evaluate('odd')! as Future,
          throwsA(isA<JsTypeError>()),
        );
      });

      test('refuses a value JavaScript cannot take', () {
        expect(() => runtime.setGlobal('x', Object()), throwsArgumentError);
        expect(
          () => runtime.setGlobal('x', (int a, int b) => a + b),
          throwsArgumentError,
        );
      });

      test('refuses a handle of another runtime or a disposed one', () {
        final other = JsRuntime();
        addTearDown(other.dispose);
        final foreign = other.evaluateHandle('({})');
        expect(() => runtime.setGlobal('x', foreign), throwsArgumentError);
        final own = runtime.evaluateHandle('({})')..dispose();
        expect(() => runtime.setGlobal('x', own), throwsStateError);
      });
    });

    group('registerFunction(name, function)', () {
      test('lets JavaScript call Dart synchronously', () {
        runtime.registerFunction('greet', (args) => 'Hello ${args[0]}!');
        expect(runtime.evaluate('greet("Dart")'), 'Hello Dart!');
      });

      test('gives JavaScript a promise of a Future', () async {
        runtime.registerFunction('later', (args) async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return (args[0]! as int) * 2;
        });
        final result = runtime.evaluate('(async () => await later(21))()');
        expect(await (result! as Future), 42);
      });

      test('raises the errors of Dart in JavaScript', () {
        runtime
          ..registerFunction('typed', (_) => throw JsRangeError(message: 'r'))
          ..registerFunction('plain', (_) => throw StateError('s'))
          ..registerFunction('argument', (_) => throw ArgumentError('a'))
          ..registerFunction('unsupported', (_) => Object());
        expect(
          runtime.evaluate(
            '[typed, plain, argument, unsupported].map((f) => { '
            'try { f(); } catch (e) { return `\${e.name}: \${e.message}`; } })',
          ),
          [
            'RangeError: r',
            'Error: Bad state: s',
            'TypeError: a',
            startsWith('TypeError: '),
          ],
        );
      });

      test('passes JavaScript functions and promises to Dart', () async {
        late JsFunction callback;
        late Future<Object?> promise;
        runtime.registerFunction('take', (args) {
          callback = args[0]! as JsFunction;
          promise = args[1]! as Future<Object?>;
          return null;
        });
        runtime.evaluate('take((x) => x + 1, Promise.resolve("p"))');
        expect(callback([41]), 42);
        expect(await promise, 'p');
      });
    });

    group('JsRuntime.spawn(options)', () {
      test('returns a runtime on a worker isolate', () async {
        final isolated = await JsRuntime.spawn();
        expect(await isolated.evaluate('6 * 7'), 42);
        await isolated.dispose();
      });
    });

    group('compile(code, sourceUrl, module), evaluateBytecode(bytecode)', () {
      test('run a compiled script', () {
        final bytecode = runtime.compile('[1, 2].map((x) => 2 * x)');
        expect(bytecode.bytes, isNotEmpty);
        expect(runtime.evaluateBytecode(bytecode), [2, 4]);
        final other = JsRuntime();
        addTearDown(other.dispose);
        expect(other.evaluateBytecode(bytecode), [2, 4]);
      });

      test('run a compiled module', () async {
        runtime.registerModules({'dep': 'export const base = 40;'});
        final bytecode = runtime.compile(
          "import { base } from 'dep'; export const answer = base + 2;",
          module: true,
        );
        final exports = await (runtime.evaluateBytecode(bytecode)! as Future);
        expect(exports, {'answer': 42});
      });

      test('throw for a syntax error or broken bytecode', () {
        expect(() => runtime.compile('let = ;'), throwsA(isA<JsSyntaxError>()));
        expect(
          () => runtime.evaluateBytecode(JsBytecode.example()),
          throwsA(isA<JsException>()),
        );
      });
    });

    group('nativeAddress', () {
      test('is the address of the native runtime', () {
        expect(runtime.nativeAddress, isNot(0));
      });
    });

    group('options.network, options.fileSystem', () {
      test('install fetch and fs', () {
        final granted = JsRuntime(
          options: JsRuntimeOptions(
            network: JsNetworkAccess.example(),
            fileSystem: JsFileSystemAccess.example(),
          ),
        );
        addTearDown(granted.dispose);
        expect(granted.evaluate('[typeof fetch, typeof fs]'), [
          'function',
          'object',
        ]);
      });
    });

    group('JsRegistration.revoke()', () {
      test('removes the global function', () {
        final registration = runtime.registerFunction('f', (_) => 1);
        runtime.evaluate('var kept = f;');
        registration.revoke();
        expect(runtime.evaluate('typeof f'), 'undefined');
        expect(
          () => runtime.evaluate('kept()'),
          throwsA(
            isA<JsTypeError>().having(
              (e) => e.message,
              'message',
              'the host function was revoked',
            ),
          ),
        );
      });
    });

    group('JsObject', () {
      test('lists keys and calls with this', () {
        withJsValues((scope) {
          final object = scope.own(
            runtime.evaluateHandle('({a: 1, b: 2, get() { return this.a; }})'),
          ) as JsObject;
          expect(object.keys, ['a', 'b', 'get']);
          final get = scope.own(object.getHandle('get')) as JsFunction;
          expect(get([], object), 1);
        });
      });
    });

    group('executePendingJobs()', () {
      test('runs jobs that settle outside of a call', () async {
        final completer = Completer<Object?>();
        runtime
          ..setGlobal('pending', completer.future)
          ..evaluate('var seen; pending.then((v) => seen = v);');
        completer.complete('done');
        await Future<void>.delayed(Duration.zero);
        runtime.executePendingJobs();
        expect(runtime.getGlobal('seen'), 'done');
      });
    });

    group('options.timeout', () {
      test('interrupts JavaScript that runs too long', () {
        final runtime = JsRuntime(
          options: const JsRuntimeOptions(timeout: Duration(milliseconds: 50)),
        );
        addTearDown(runtime.dispose);
        expect(
          () => runtime.evaluate('for (;;) {}'),
          throwsA(
            isA<JsInterruptedError>().having(
              (e) => e.timedOut,
              'timedOut',
              true,
            ),
          ),
        );
        expect(runtime.evaluate('1 + 1'), 2);
      });

      test('covers the conversion of the result', () {
        final runtime = JsRuntime(
          options: const JsRuntimeOptions(timeout: Duration(milliseconds: 50)),
        );
        addTearDown(runtime.dispose);
        expect(
          () => runtime.evaluate('const a = []; a.length = 2 ** 32 - 1; a'),
          throwsA(
            isA<JsInterruptedError>().having(
              (e) => e.timedOut,
              'timedOut',
              true,
            ),
          ),
        );
        expect(
          () =>
              runtime.evaluate('const b = []; b.length = 2 ** 32 - 1; throw b'),
          throwsA(
            isA<JsError>().having(
              (e) => e.message,
              'message',
              'the thrown value cannot be converted',
            ),
          ),
        );
      });

      test('covers the pending jobs of a call', () {
        final runtime = JsRuntime(
          options: const JsRuntimeOptions(timeout: Duration(milliseconds: 50)),
        );
        addTearDown(runtime.dispose);
        expect(
          () =>
              runtime.evaluate('Promise.resolve().then(() => { for (;;) {} })'),
          throwsA(isA<JsInterruptedError>()),
        );
      });
    });

    group('interrupt()', () {
      test('stops JavaScript from a host function', () {
        runtime.registerFunction('stop', (_) {
          runtime.interrupt();
          return null;
        });
        expect(
          () => runtime.evaluate('stop(); for (;;) {}'),
          throwsA(
            isA<JsInterruptedError>()
                .having((e) => e.timedOut, 'timedOut', false)
                .having((e) => e.message, 'message', 'interrupted'),
          ),
        );
        expect(runtime.evaluate('2'), 2);
      });

      test('stops the conversion of a result', () {
        runtime.registerFunction('stop', (_) {
          runtime.interrupt();
          return null;
        });
        expect(
          () => runtime.evaluate(
            'const a = []; a.length = 2 ** 32 - 1; stop(); a',
          ),
          throwsA(
            isA<JsInterruptedError>().having(
              (e) => e.timedOut,
              'timedOut',
              false,
            ),
          ),
        );
      });
    });

    group('options.memoryLimit', () {
      test('throws JsOutOfMemoryError when JavaScript allocates too much', () {
        final runtime = JsRuntime(
          options: const JsRuntimeOptions(memoryLimit: 4 * 1024 * 1024),
        );
        addTearDown(runtime.dispose);
        expect(
          () => runtime.evaluate(
            '(() => { const a = []; '
            'for (;;) a.push(new Array(1000).fill(1)); })()',
          ),
          throwsA(isA<JsOutOfMemoryError>()),
        );
        expect(runtime.evaluate('"still alive"'), 'still alive');
      });

      test('limits a converted value to four times the limit', () {
        final runtime = JsRuntime(
          options: const JsRuntimeOptions(memoryLimit: 4 * 1024 * 1024),
        );
        addTearDown(runtime.dispose);
        runtime.evaluate(
          'var v = "x".repeat(1 << 16); '
          'for (let i = 0; i < 12; i++) v = [v, v]; 0',
        );
        expect(() => runtime.evaluate('v'), throwsA(isA<JsOutOfMemoryError>()));
        expect(
          () => runtime.evaluate('throw v'),
          throwsA(
            isA<JsError>().having(
              (e) => e.message,
              'message',
              'the thrown value cannot be converted',
            ),
          ),
        );
        expect(runtime.evaluate('v[0][0].length'), 2);
      });
    });

    group('options.maxStackSize', () {
      test('throws JsStackOverflowError for an endless recursion', () {
        expect(
          () => runtime.evaluate('function f() { return 1 + f(); } f()'),
          throwsA(isA<JsStackOverflowError>()),
        );
      });
    });

    group('options.onUnhandledRejection', () {
      test('receives the reasons of unhandled rejections', () async {
        final reasons = <Object?>[];
        final runtime = JsRuntime(
          options: JsRuntimeOptions(onUnhandledRejection: reasons.add),
        );
        addTearDown(runtime.dispose);
        runtime.evaluate(
          'Promise.reject(new TypeError("lost"));\n'
          'Promise.reject(7);\n'
          'Promise.reject(1).catch(() => {});',
        );
        await Future<void>.delayed(Duration.zero);
        expect(reasons, [
          isA<JsTypeError>().having((e) => e.message, 'message', 'lost'),
          isA<JsError>().having((e) => e.thrownValue, 'thrownValue', 7),
        ]);
      });

      test('receives errors of JavaScript that runs after a Future', () async {
        final reasons = <Object?>[];
        final runtime = JsRuntime(
          options: JsRuntimeOptions(
            onUnhandledRejection: reasons.add,
            timeout: const Duration(milliseconds: 50),
          ),
        );
        addTearDown(runtime.dispose);
        final completer = Completer<Object?>();
        runtime
          ..setGlobal('pending', completer.future)
          ..evaluate('pending.then(() => { for (;;) {} });');
        completer.complete(1);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(reasons, [isA<JsInterruptedError>()]);
      });

      test('drops them without a handler', () async {
        runtime.evaluate('Promise.reject(1); 0');
        await Future<void>.delayed(Duration.zero);
        expect(runtime.evaluate('1'), 1);
      });
    });

    group('memoryUsage', () {
      test('counts the memory of the runtime', () {
        final usage = runtime.memoryUsage;
        expect(usage.allocatedBytes, greaterThan(0));
        expect(usage.allocations, greaterThan(0));
        expect(usage.limit, isNull);
        expect(usage.objects, greaterThan(0));
        expect(usage.functions, greaterThan(0));
        expect(usage.strings, greaterThanOrEqualTo(0));
        expect(usage.usedBytes, greaterThan(0));
      });
    });

    group('runGc()', () {
      test('frees unreachable objects', () {
        runtime
          ..evaluate('globalThis.garbage = new Array(10000).fill({});')
          ..evaluate('globalThis.garbage = null;');
        final before = runtime.memoryUsage.allocatedBytes;
        runtime.runGc();
        expect(runtime.memoryUsage.allocatedBytes, lessThanOrEqualTo(before));
      });
    });

    group('dispose()', () {
      test('makes every further call throw a StateError', () {
        final runtime = JsRuntime()..dispose();
        expect(runtime.isDisposed, isTrue);
        runtime.dispose();
        expect(() => runtime.evaluate('1'), throwsStateError);
        expect(() => runtime.interrupt(), throwsStateError);
        expect(() => runtime.runGc(), throwsStateError);
        expect(() => runtime.memoryUsage, throwsStateError);
        expect(() => runtime.registerModules({}), throwsStateError);
        expect(
          () => runtime.registerFunction('f', (_) => null),
          throwsStateError,
        );
      });

      test('cannot run while JavaScript runs', () {
        runtime.registerFunction('dispose', (_) {
          runtime.dispose();
          return null;
        });
        expect(
          () => runtime.evaluate('dispose()'),
          throwsA(
            isA<JsError>().having(
              (e) => e.message,
              'message',
              contains('cannot be disposed while it runs'),
            ),
          ),
        );
      });

      test('ends the futures of pending promises', () async {
        final runtime = JsRuntime();
        final pending = runtime.evaluate('new Promise(() => {})')! as Future;
        final ignored = runtime.evaluate('new Promise(() => {})')! as Future;
        runtime.dispose();
        await expectLater(pending, throwsA(isA<JsInterruptedError>()));
        expect(ignored, isA<Future<Object?>>());
      });

      test('ignores a Future that completes after it', () async {
        final runtime = JsRuntime();
        final completer = Completer<Object?>();
        runtime
          ..setGlobal('pending', completer.future)
          ..dispose();
        completer.complete(1);
        await Future<void>.delayed(Duration.zero);
        expect(runtime.isDisposed, isTrue);
      });
    });

    group('the sandbox', () {
      test('offers no file, network, timer or console API by default', () {
        expect(
          runtime.evaluate(
            '["fetch", "fs", "std", "os", "require", "process", "console", '
            '"setTimeout", "setInterval", "XMLHttpRequest", "WebSocket", '
            '"Deno", "Bun"].filter((name) => typeof globalThis[name] '
            '!== "undefined")',
          ),
          isEmpty,
        );
      });

      test('imports neither std nor os nor files', () async {
        for (final name in ['std', 'os', 'qjs:std', 'qjs:os', '/etc/hosts']) {
          await expectLater(
            runtime.evaluateModule("import '$name';"),
            throwsA(isA<JsReferenceError>()),
            reason: name,
          );
        }
      });

      test('blocks Atomics.wait', () {
        expect(
          () => runtime.evaluate(
            'Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1)',
          ),
          throwsA(isA<JsTypeError>()),
        );
      });
    });
  });
}
