// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'gg_quickjs_native.dart';
import 'js_bytecode.dart';
import 'js_exception.dart';
import 'js_isolate_worker.dart';
import 'js_memory_usage.dart';
import 'js_runtime.dart';
import 'js_runtime_options.dart';
import 'js_value_codec.dart';

// #############################################################################
/// A [JsRuntime] on a worker isolate of its own, called asynchronously.
///
/// It offers the methods of [JsRuntime] as futures, so that JavaScript never
/// blocks the calling isolate. Values cross as copies: Dart functions,
/// futures and handles cannot be passed, and JavaScript functions, symbols
/// and nested promises in results arrive as null. A result that is a
/// promise is awaited in the worker.
///
/// Registered functions run on the calling isolate; JavaScript receives a
/// promise of their result. [JsRuntimeOptions.onConsole] and
/// [JsRuntimeOptions.onUnhandledRejection] run on the calling isolate too,
/// [JsRuntimeOptions.moduleLoader] and [JsNetworkAccess.allowUrl] on the
/// worker, so they must be sendable to it.
///
/// ```dart
/// final runtime = await JsRuntime.spawn();
/// print(await runtime.evaluate('6 * 7')); // 42
/// await runtime.dispose();
/// ```
final class JsIsolateRuntime {
  JsIsolateRuntime._(this.options);

  /// Spawns the worker isolate with a runtime of [options]; throws what the
  /// creation of the runtime throws, e.g. a [JsOutOfMemoryError].
  static Future<JsIsolateRuntime> spawn({
    JsRuntimeOptions options = const JsRuntimeOptions(),
  }) async {
    final runtime = JsIsolateRuntime._(options);
    await runtime._start();
    return runtime;
  }

  // ...........................................................................
  /// [JsRuntime.evaluate] on the worker; a promise is awaited there.
  Future<Object?> evaluate(
    String code, {
    String sourceUrl = JsRuntime.defaultSourceUrl,
  }) => _request(JsWorkerOperation.evaluate, (code, sourceUrl));

  /// [JsRuntime.evaluateModule] on the worker.
  Future<Map<String, Object?>> evaluateModule(
    String code, {
    String sourceUrl = JsRuntime.defaultModuleUrl,
  }) async =>
      (await _request(JsWorkerOperation.evaluateModule, (code, sourceUrl)))!
          as Map<String, Object?>;

  /// [JsRuntime.call] on the worker.
  Future<Object?> call(
    String name, [
    List<Object?> arguments = const [],
  ]) async => _request(JsWorkerOperation.call, (name, _transfer(arguments)));

  /// [JsRuntime.getGlobal] on the worker.
  Future<Object?> getGlobal(String name) =>
      _request(JsWorkerOperation.getGlobal, name);

  /// [JsRuntime.setGlobal] on the worker.
  Future<void> setGlobal(String name, Object? value) async =>
      _request(JsWorkerOperation.setGlobal, (name, _transfer(value)));

  /// Makes [function] callable from JavaScript as the global function
  /// [name]; it runs on the calling isolate and JavaScript gets a promise of
  /// its result.
  Future<JsIsolateRegistration> registerFunction(
    String name,
    JsHostFunction function,
  ) async {
    final id = _nextFunctionId++;
    _functions[id] = function;
    await _request(JsWorkerOperation.registerFunction, (name, id));
    return JsIsolateRegistration._(runtime: this, name: name, id: id);
  }

  /// [JsRuntime.registerModules] on the worker.
  Future<void> registerModules(Map<String, String> modules) =>
      _request(JsWorkerOperation.registerModules, {...modules});

  /// [JsRuntime.compile] on the worker.
  Future<JsBytecode> compile(
    String code, {
    String sourceUrl = JsRuntime.defaultSourceUrl,
    bool module = false,
  }) async => JsBytecode(
    (await _request(JsWorkerOperation.compile, (code, sourceUrl, module)))!
        as Uint8List,
  );

  /// [JsRuntime.evaluateBytecode] on the worker; the exports of a module are
  /// awaited there.
  Future<Object?> evaluateBytecode(JsBytecode bytecode) =>
      _request(JsWorkerOperation.evaluateBytecode, bytecode.bytes);

  /// [JsRuntime.executePendingJobs] on the worker.
  Future<void> executePendingJobs() =>
      _request(JsWorkerOperation.executePendingJobs);

  /// Interrupts the JavaScript that the worker runs now; works while the
  /// worker is busy, as it sets a flag of the native runtime directly.
  void interrupt() {
    if (!_disposed) interruptNativeRuntime(_address);
  }

  /// [JsRuntime.runGc] on the worker.
  Future<void> runGc() => _request(JsWorkerOperation.runGc);

  /// Disposes the runtime and ends the worker isolate.
  ///
  /// By default the calls in flight end with a [JsInterruptedError], and
  /// running JavaScript is interrupted. With [graceful] the calls in flight
  /// end first; new calls throw a [StateError] at once either way.
  Future<void> dispose({bool graceful = false}) async {
    if (!_disposed) {
      _disposed = true;
      if (graceful) {
        await Future.wait([
          for (final request in [..._requests.values])
            request.future.then<void>((_) {}, onError: (Object _) {}),
        ]);
      } else {
        closeNativeRuntime(_address);
        _cancel(JsInterruptedError(message: 'the runtime was disposed'));
      }
      _worker.send((_nextRequestId++, JsWorkerOperation.dispose, null));
    }
    await _exited.future;
  }

  // ...........................................................................
  /// The limits and capabilities of the runtime.
  final JsRuntimeOptions options;

  /// Whether [dispose] was called.
  bool get isDisposed => _disposed;

  /// [JsRuntime.memoryUsage] of the worker.
  Future<JsMemoryUsage> get memoryUsage async {
    final fields =
        (await _request(JsWorkerOperation.memoryUsage))! as List<Object?>;
    return JsMemoryUsage(
      allocatedBytes: fields[0]! as int,
      allocations: fields[1]! as int,
      limit: fields[2] as int?,
      usedBytes: fields[3]! as int,
      objects: fields[4]! as int,
      strings: fields[5]! as int,
      functions: fields[6]! as int,
    );
  }

  // ...........................................................................
  static const _codec = JsValueCodec();

  final _port = ReceivePort();
  final _ready = Completer<void>();
  final _exited = Completer<void>();
  final _requests = <int, Completer<Object?>>{};
  final _functions = <int, JsHostFunction>{};
  late final SendPort _worker;
  late final int _address;
  var _nextRequestId = 1;
  var _nextFunctionId = 1;
  var _disposed = false;

  Future<void> _start() async {
    _port.listen(_receive);
    try {
      await Isolate.spawn(
        jsIsolateWorkerMain,
        (_port.sendPort, JsWorkerConfig.of(options)),
        onExit: _port.sendPort,
        debugName: 'gg_quickjs',
      );
    } catch (_) {
      _port.close();
      rethrow;
    }
    await _ready.future;
  }

  static TransferableTypedData _transfer(Object? value) =>
      TransferableTypedData.fromList([_codec.encode(value)]);

  Future<Object?> _request(JsWorkerOperation operation, [Object? payload]) {
    if (_disposed) {
      return Future.error(StateError('The JsIsolateRuntime is disposed'));
    }
    final id = _nextRequestId++;
    final completer = Completer<Object?>();
    _requests[id] = completer;
    _worker.send((id, operation, payload));
    return completer.future;
  }

  void _cancel(Object error) {
    final requests = [..._requests.values];
    _requests.clear();
    for (final request in requests) {
      request.future.ignore();
      request.completeError(error);
    }
  }

  void _receive(Object? message) {
    switch (message) {
      case (JsWorkerEvent.ready, (SendPort worker, int address)):
        _worker = worker;
        _address = address;
        _ready.complete();
      case (JsWorkerEvent.failed, Object error):
        _ready.completeError(error);
      case (JsWorkerEvent.result, (int id, TransferableTypedData value)):
        _requests.remove(id)?.complete(JsIsolateWorker.receive(value));
      case (JsWorkerEvent.error, (int id, Object error)):
        _requests.remove(id)?.completeError(error);
      case (
        JsWorkerEvent.call,
        (int callId, int functionId, TransferableTypedData arguments),
      ):
        unawaited(_serve(callId, functionId, arguments));
      case (JsWorkerEvent.console, (int level, String text)):
        options.onConsole?.call(JsConsoleLevel.values[level], text);
      case (JsWorkerEvent.rejection, TransferableTypedData reason):
        options.onUnhandledRejection?.call(JsIsolateWorker.receive(reason));
      case null:
        // The worker isolate ended, after dispose() or by an error.
        final ended = StateError('The worker of the JsIsolateRuntime ended');
        _port.close();
        _disposed = true;
        _cancel(ended);
        if (!_ready.isCompleted) _ready.completeError(ended);
        _exited.complete();
    }
  }

  // Runs a registered function for JavaScript on the worker.
  Future<void> _serve(
    int callId,
    int functionId,
    TransferableTypedData arguments,
  ) async {
    var ok = true;
    Uint8List bytes;
    try {
      final function = _functions[functionId];
      if (function == null) {
        throw JsTypeError(message: 'the host function was revoked');
      }
      var value = function(
        JsIsolateWorker.receive(arguments)! as List<Object?>,
      );
      if (value is Future<Object?>) value = await value;
      bytes = _codec.encode(value);
    } catch (error) {
      ok = false;
      bytes = _codec.encode(JsException.fromDartError(error));
    }
    _worker.send((callId, ok, TransferableTypedData.fromList([bytes])));
  }

  Future<void> _revoke(JsIsolateRegistration registration) async {
    _functions.remove(registration.id);
    await _request(JsWorkerOperation.revoke, registration.id);
  }
}

// #############################################################################
/// A Dart function that [JsIsolateRuntime.registerFunction] made callable
/// from JavaScript.
final class JsIsolateRegistration {
  JsIsolateRegistration._({
    required this._runtime,
    required this.name,
    required this.id,
  });

  // ...........................................................................
  /// Revokes the function; a no-op when it is revoked already.
  Future<void> revoke() async {
    if (_revoked) return;
    _revoked = true;
    await _runtime._revoke(this);
  }

  // ...........................................................................
  /// The name of the global function.
  final String name;

  /// The id of the function in its runtime.
  final int id;

  /// Whether [revoke] was called.
  bool get isRevoked => _revoked;

  // ...........................................................................
  final JsIsolateRuntime _runtime;
  var _revoked = false;
}
