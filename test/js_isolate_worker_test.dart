// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:gg_quickjs/gg_quickjs.dart';
import 'package:gg_quickjs/src/js_isolate_worker.dart';
import 'package:test/test.dart';

void main() {
  group('JsWorkerConfig', () {
    group('JsWorkerConfig.of(options), toOptions(...)', () {
      test('keep the limits and forward the callbacks', () {
        void onConsole(JsConsoleLevel level, String message) {}
        void onRejection(Object? reason) {}
        String? loader(String name) => null;
        final options = JsRuntimeOptions(
          memoryLimit: 1,
          maxStackSize: 2,
          gcThreshold: 3,
          timeout: const Duration(seconds: 4),
          onConsole: onConsole,
          onUnhandledRejection: onRejection,
          timers: true,
          network: JsNetworkAccess.example(),
          fileSystem: JsFileSystemAccess.example(),
          moduleLoader: loader,
        );
        final config = JsWorkerConfig.of(options);
        expect(config.console, isTrue);
        expect(config.rejections, isTrue);
        final copy = config.toOptions(
          onConsole: onConsole,
          onUnhandledRejection: onRejection,
        );
        expect(copy.memoryLimit, 1);
        expect(copy.maxStackSize, 2);
        expect(copy.gcThreshold, 3);
        expect(copy.timeout, const Duration(seconds: 4));
        expect(copy.onConsole, onConsole);
        expect(copy.onUnhandledRejection, onRejection);
        expect(copy.timers, isTrue);
        expect(copy.network, options.network);
        expect(copy.fileSystem, options.fileSystem);
        expect(copy.moduleLoader, loader);
        final plain = JsWorkerConfig.of(const JsRuntimeOptions())
            .toOptions(onConsole: onConsole, onUnhandledRejection: onRejection);
        expect(plain.onConsole, isNull);
        expect(plain.onUnhandledRejection, isNull);
      });
    });

    group('JsWorkerConfig.example()', () {
      test('has a console', () {
        expect(JsWorkerConfig.example().console, isTrue);
        expect(JsWorkerConfig.example(console: false).console, isFalse);
        expect(JsWorkerConfig.example().memoryLimit, 32 * 1024 * 1024);
      });
    });
  });

  group('JsIsolateWorker', () {
    group('transfer(value), receive(data)', () {
      test('copy data and drop what cannot be copied', () {
        expect(
          JsIsolateWorker.receive(
            JsIsolateWorker.transfer([1, (List<Object?> a) => null]),
          ),
          [1, null],
        );
      });
    });

    group('sendable(error)', () {
      test('keeps exceptions and wraps other errors', () {
        final typeError = JsTypeError(message: 't');
        expect(JsIsolateWorker.sendable(typeError), same(typeError));
        expect(
          JsIsolateWorker.sendable(
            JsError(message: 'm', thrownValue: [1, (List<Object?> a) => null]),
          ),
          isA<JsError>().having((e) => e.thrownValue, 'thrownValue', [1, null]),
        );
        final plain = JsError(message: 'plain');
        expect(JsIsolateWorker.sendable(plain), same(plain));
        expect(
          JsIsolateWorker.sendable(StateError('s')),
          isA<RemoteError>().having(
            (e) => e.toString(),
            'text',
            'Bad state: s',
          ),
        );
      });
    });

    group('start()', () {
      test('reports a runtime that cannot be created', () async {
        final owner = ReceivePort();
        addTearDown(owner.close);
        jsIsolateWorkerMain((
          owner.sendPort,
          JsWorkerConfig.of(const JsRuntimeOptions(memoryLimit: 1024)),
        ));
        final (kind, error) = await owner.first as (JsWorkerEvent, Object?);
        expect(kind, JsWorkerEvent.failed);
        expect(error, isA<JsOutOfMemoryError>());
      });
    });

    group('the requests of the owner', () {
      late ReceivePort owner;
      late StreamIterator<Object?> events;
      late SendPort worker;
      var nextId = 1;

      Future<Object?> next() async {
        expect(await events.moveNext(), isTrue);
        return events.current;
      }

      Future<Object?> request(JsWorkerOperation operation, [Object? payload]) {
        worker.send((nextId++, operation, payload));
        return next();
      }

      Object? resultOf(Object? event) => switch (event) {
        (JsWorkerEvent.result, (int _, TransferableTypedData value)) =>
          JsIsolateWorker.receive(value),
        _ => throw StateError('no result: $event'),
      };

      setUp(() async {
        owner = ReceivePort();
        events = StreamIterator(owner);
        jsIsolateWorkerMain((
          owner.sendPort,
          JsWorkerConfig.of(
            JsRuntimeOptions(
              onConsole: (_, _) {},
              onUnhandledRejection: (_) {},
            ),
          ),
        ));
        final (kind, (port, address)) =
            await next() as (JsWorkerEvent, (SendPort, int));
        expect(kind, JsWorkerEvent.ready);
        expect(address, isNot(0));
        worker = port;
      });

      tearDown(() async {
        await events.cancel();
        owner.close();
      });

      Future<void> dispose() async {
        expect(resultOf(await request(JsWorkerOperation.dispose)), isNull);
        expect(await next(), (JsWorkerEvent.disposed, null));
      }

      test('run JavaScript and answer with copies', () async {
        TransferableTypedData transfer(Object? value) =>
            JsIsolateWorker.transfer(value);

        expect(
          resultOf(
            await request(JsWorkerOperation.evaluate, ('6 * 7', 'a.js')),
          ),
          42,
        );
        expect(
          resultOf(
            await request(JsWorkerOperation.registerModules, {
              'dep': 'export const x = 1;',
            }),
          ),
          isNull,
        );
        expect(
          resultOf(
            await request(JsWorkerOperation.evaluateModule, (
              "export { x } from 'dep';",
              'm.js',
            )),
          ),
          {'x': 1},
        );
        expect(
          resultOf(
            await request(JsWorkerOperation.setGlobal, ('v', transfer([1]))),
          ),
          isNull,
        );
        expect(resultOf(await request(JsWorkerOperation.getGlobal, 'v')), [1]);
        await request(JsWorkerOperation.evaluate, (
          'function add(a, b) { return a + b; }',
          'f.js',
        ));
        expect(
          resultOf(
            await request(JsWorkerOperation.call, ('add', transfer([20, 22]))),
          ),
          42,
        );
        final bytes = resultOf(
          await request(JsWorkerOperation.compile, ('1 + 1', 'c.js', false)),
        );
        expect(bytes, isA<Uint8List>());
        expect(
          resultOf(await request(JsWorkerOperation.evaluateBytecode, bytes)),
          2,
        );
        for (final operation in [
          JsWorkerOperation.executePendingJobs,
          JsWorkerOperation.runGc,
        ]) {
          expect(resultOf(await request(operation)), isNull);
        }
        expect(
          resultOf(await request(JsWorkerOperation.memoryUsage)),
          hasLength(7),
        );
        await dispose();
      });

      test('answers errors, console output and rejections', () async {
        final (kind, (_, error)) = await request(JsWorkerOperation.evaluate, (
          'null.x',
          'e.js',
        )) as (JsWorkerEvent, (int, Object));
        expect(kind, JsWorkerEvent.error);
        expect(error, isA<JsTypeError>());
        worker.send((
          nextId++,
          JsWorkerOperation.evaluate,
          ('console.log("hi"); Promise.reject(3); 0', 'c.js'),
        ));
        expect(await next(), (JsWorkerEvent.console, (1, 'hi')));
        // The rejection is reported before the result is sent.
        final (rejection, reason) =
            await next() as (JsWorkerEvent, TransferableTypedData);
        expect(rejection, JsWorkerEvent.rejection);
        expect(
          JsIsolateWorker.receive(reason),
          isA<JsError>().having((e) => e.message, 'message', '3'),
        );
        expect(resultOf(await next()), 0);
        await dispose();
      });

      test('calls registered functions in the owner', () async {
        expect(
          resultOf(await request(JsWorkerOperation.registerFunction, ('f', 7))),
          isNull,
        );
        worker.send((
          nextId++,
          JsWorkerOperation.evaluate,
          (
            'Promise.all([f(1), f(2).catch((e) => e.message), '
                'f(3).catch((e) => e.message)])',
            'r.js',
          ),
        ));
        final calls = <(int, int, Object?)>[];
        for (var i = 0; i < 3; i++) {
          final event = await next();
          final (_, (callId, functionId, arguments)) =
              event! as (JsWorkerEvent, (int, int, TransferableTypedData));
          calls.add((callId, functionId, JsIsolateWorker.receive(arguments)));
        }
        expect(calls.map((call) => call.$2), [7, 7, 7]);
        expect(calls.map((call) => call.$3), [
          [1],
          [2],
          [3],
        ]);
        // A reply for no pending call is ignored.
        worker.send((999, true, JsIsolateWorker.transfer(0)));
        worker.send((calls[0].$1, true, JsIsolateWorker.transfer('one')));
        worker.send((
          calls[1].$1,
          false,
          JsIsolateWorker.transfer(JsRangeError(message: 'two')),
        ));
        worker.send((calls[2].$1, false, JsIsolateWorker.transfer(3)));
        expect(resultOf(await next()), ['one', 'two', '3']);
        expect(resultOf(await request(JsWorkerOperation.revoke, 7)), isNull);
        expect(
          resultOf(await request(JsWorkerOperation.evaluate, ('typeof f', ''))),
          'undefined',
        );
        await dispose();
      });
    });
  });
}
