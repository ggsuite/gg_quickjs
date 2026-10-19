// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'js_bytecode.dart';
import 'js_exception.dart';
import 'js_file_system_access.dart';
import 'js_network_access.dart';
import 'js_runtime.dart';
import 'js_runtime_options.dart';
import 'js_value_codec.dart';

// #############################################################################
/// The requests of a [JsIsolateRuntime] to its worker isolate.
enum JsWorkerOperation {
  /// [JsRuntime.evaluate] with (code, source URL).
  evaluate,

  /// [JsRuntime.evaluateModule] with (code, source URL).
  evaluateModule,

  /// [JsRuntime.call] with (name, encoded arguments).
  call,

  /// [JsRuntime.getGlobal] with the name.
  getGlobal,

  /// [JsRuntime.setGlobal] with (name, encoded value).
  setGlobal,

  /// [JsRuntime.registerFunction] with (name, function id).
  registerFunction,

  /// [JsRegistration.revoke] with the function id.
  revoke,

  /// [JsRuntime.registerModules] with the modules.
  registerModules,

  /// [JsRuntime.compile] with (code, source URL, module).
  compile,

  /// [JsRuntime.evaluateBytecode] with the bytes.
  evaluateBytecode,

  /// [JsRuntime.executePendingJobs].
  executePendingJobs,

  /// [JsRuntime.memoryUsage].
  memoryUsage,

  /// [JsRuntime.runGc].
  runGc,

  /// [JsRuntime.dispose].
  dispose,
}

// #############################################################################
/// The messages of a worker isolate to its [JsIsolateRuntime].
enum JsWorkerEvent {
  /// The runtime exists: (worker port, native address).
  ready,

  /// The runtime could not be created: the error.
  failed,

  /// A request succeeded: (request id, encoded value).
  result,

  /// A request failed: (request id, error).
  error,

  /// JavaScript called a registered function: (call id, function id,
  /// encoded arguments).
  call,

  /// JavaScript wrote to `console`: (level index, message).
  console,

  /// An unhandled rejection: the encoded reason.
  rejection,

  /// The runtime is disposed.
  disposed,
}

// #############################################################################
/// The options of a worker runtime without the callbacks that stay in the
/// owner isolate.
final class JsWorkerConfig {
  /// Creates a config.
  const JsWorkerConfig({
    required this.memoryLimit,
    required this.maxStackSize,
    required this.gcThreshold,
    required this.timeout,
    required this.console,
    required this.rejections,
    required this.timers,
    required this.network,
    required this.fileSystem,
    required this.moduleLoader,
  });

  /// Creates the config of [options].
  factory JsWorkerConfig.of(JsRuntimeOptions options) => JsWorkerConfig(
    memoryLimit: options.memoryLimit,
    maxStackSize: options.maxStackSize,
    gcThreshold: options.gcThreshold,
    timeout: options.timeout,
    console: options.onConsole != null,
    rejections: options.onUnhandledRejection != null,
    timers: options.timers,
    network: options.network,
    fileSystem: options.fileSystem,
    moduleLoader: options.moduleLoader,
  );

  /// Creates an example config for tests and docs.
  factory JsWorkerConfig.example({bool? console}) =>
      JsWorkerConfig.of(JsRuntimeOptions.example())._withConsole(console);

  // ...........................................................................
  /// The options of the worker runtime, with [onConsole] and
  /// [onUnhandledRejection] that forward to the owner.
  JsRuntimeOptions toOptions({
    required JsConsoleHandler onConsole,
    required JsRejectionHandler onUnhandledRejection,
  }) => JsRuntimeOptions(
    memoryLimit: memoryLimit,
    maxStackSize: maxStackSize,
    gcThreshold: gcThreshold,
    timeout: timeout,
    onConsole: console ? onConsole : null,
    onUnhandledRejection: rejections ? onUnhandledRejection : null,
    timers: timers,
    network: network,
    fileSystem: fileSystem,
    moduleLoader: moduleLoader,
  );

  // ...........................................................................
  /// [JsRuntimeOptions.memoryLimit].
  final int? memoryLimit;

  /// [JsRuntimeOptions.maxStackSize].
  final int maxStackSize;

  /// [JsRuntimeOptions.gcThreshold].
  final int? gcThreshold;

  /// [JsRuntimeOptions.timeout].
  final Duration? timeout;

  /// Whether `console` exists and forwards to the owner.
  final bool console;

  /// Whether unhandled rejections go to the owner.
  final bool rejections;

  /// [JsRuntimeOptions.timers].
  final bool timers;

  /// [JsRuntimeOptions.network].
  final JsNetworkAccess? network;

  /// [JsRuntimeOptions.fileSystem].
  final JsFileSystemAccess? fileSystem;

  /// [JsRuntimeOptions.moduleLoader], run in the worker isolate.
  final JsModuleLoader? moduleLoader;

  // ...........................................................................
  JsWorkerConfig _withConsole(bool? console) => JsWorkerConfig(
    memoryLimit: memoryLimit,
    maxStackSize: maxStackSize,
    gcThreshold: gcThreshold,
    timeout: timeout,
    console: console ?? true,
    rejections: rejections,
    timers: timers,
    network: network,
    fileSystem: fileSystem,
    moduleLoader: moduleLoader,
  );
}

// .............................................................................
/// The entry point of a worker isolate: creates the runtime of the config
/// and serves the owner behind the send port.
void jsIsolateWorkerMain((SendPort, JsWorkerConfig) start) {
  final (owner, config) = start;
  JsIsolateWorker(owner: owner, config: config).start();
}

// #############################################################################
/// The worker side of a [JsIsolateRuntime]: owns the [JsRuntime] and serves
/// the requests of the owner isolate.
final class JsIsolateWorker {
  /// Creates a worker that answers [owner].
  JsIsolateWorker({required this.owner, required this.config});

  // ...........................................................................
  /// Creates the runtime and tells the owner that it is ready, or why it
  /// failed.
  void start() {
    try {
      _runtime = JsRuntime(
        options: config.toOptions(
          onConsole: (level, message) =>
              owner.send((JsWorkerEvent.console, (level.index, message))),
          onUnhandledRejection: (reason) =>
              owner.send((JsWorkerEvent.rejection, transfer(reason))),
        ),
      );
    } catch (error) {
      _port.close();
      owner.send((JsWorkerEvent.failed, sendable(error)));
      return;
    }
    _port.listen(_receive);
    owner.send((JsWorkerEvent.ready, (_port.sendPort, _runtime.nativeAddress)));
  }

  // ...........................................................................
  /// The port of the owner isolate.
  final SendPort owner;

  /// The options of the runtime.
  final JsWorkerConfig config;

  // ...........................................................................
  /// Encodes [value] as copied data; values that cannot be copied, e.g.
  /// functions, become null.
  static TransferableTypedData transfer(Object? value) =>
      TransferableTypedData.fromList([_codec.encode(value)]);

  /// Decodes copied data.
  static Object? receive(TransferableTypedData data) =>
      _codec.decode(data.materialize().asUint8List());

  /// An error that can cross to the owner isolate: a [JsException] with a
  /// copied thrown value, a [RemoteError] for any other error.
  static Object sendable(Object error) => switch (error) {
    JsError(:final thrownValue) when thrownValue != null => JsError(
      name: error.name,
      message: error.message,
      stack: error.stack,
      thrownValue: receive(transfer(thrownValue)),
    ),
    JsException() => error,
    _ => RemoteError('$error', ''),
  };

  // ...........................................................................
  static const _codec = JsValueCodec(dropUncopyable: true);

  final _port = ReceivePort();
  late final JsRuntime _runtime;
  final _calls = <int, Completer<Object?>>{};
  final _registrations = <int, JsRegistration>{};
  var _nextCall = 1;

  void _receive(Object? message) {
    switch (message) {
      case (int id, JsWorkerOperation operation, Object? payload):
        unawaited(_handle(id, operation, payload));
      case (int callId, bool ok, TransferableTypedData value):
        _complete(callId, ok, receive(value));
    }
  }

  Future<void> _handle(
    int id,
    JsWorkerOperation operation,
    Object? payload,
  ) async {
    try {
      final value = await _perform(operation, payload);
      owner.send((JsWorkerEvent.result, (id, transfer(value))));
    } catch (error) {
      owner.send((JsWorkerEvent.error, (id, sendable(error))));
    }
    if (operation == JsWorkerOperation.dispose) {
      _port.close();
      owner.send((JsWorkerEvent.disposed, null));
    }
  }

  Future<Object?> _perform(JsWorkerOperation operation, Object? payload) async {
    final runtime = _runtime;
    switch (operation) {
      case JsWorkerOperation.evaluate:
        final (code, sourceUrl) = payload! as (String, String);
        return runtime.evaluate(code, sourceUrl: sourceUrl);
      case JsWorkerOperation.evaluateModule:
        final (code, sourceUrl) = payload! as (String, String);
        return runtime.evaluateModule(code, sourceUrl: sourceUrl);
      case JsWorkerOperation.call:
        final (name, arguments) = payload! as (String, TransferableTypedData);
        return runtime.call(name, receive(arguments)! as List<Object?>);
      case JsWorkerOperation.getGlobal:
        return runtime.getGlobal(payload! as String);
      case JsWorkerOperation.setGlobal:
        final (name, value) = payload! as (String, TransferableTypedData);
        runtime.setGlobal(name, receive(value));
      case JsWorkerOperation.registerFunction:
        final (name, functionId) = payload! as (String, int);
        _registrations[functionId] = runtime.registerFunction(
          name,
          (arguments) => _callOwner(functionId, arguments),
        );
      case JsWorkerOperation.revoke:
        _registrations.remove(payload! as int)?.revoke();
      case JsWorkerOperation.registerModules:
        runtime.registerModules(payload! as Map<String, String>);
      case JsWorkerOperation.compile:
        final (code, sourceUrl, module) = payload! as (String, String, bool);
        return runtime
            .compile(code, sourceUrl: sourceUrl, module: module)
            .bytes;
      case JsWorkerOperation.evaluateBytecode:
        return runtime.evaluateBytecode(JsBytecode(payload! as Uint8List));
      case JsWorkerOperation.executePendingJobs:
        runtime.executePendingJobs();
      case JsWorkerOperation.memoryUsage:
        final usage = runtime.memoryUsage;
        return [
          usage.allocatedBytes,
          usage.allocations,
          usage.limit,
          usage.usedBytes,
          usage.objects,
          usage.strings,
          usage.functions,
        ];
      case JsWorkerOperation.runGc:
        runtime.runGc();
      case JsWorkerOperation.dispose:
        runtime.dispose();
    }
    return null;
  }

  Future<Object?> _callOwner(int functionId, List<Object?> arguments) {
    final callId = _nextCall++;
    final completer = Completer<Object?>();
    _calls[callId] = completer;
    owner.send((JsWorkerEvent.call, (callId, functionId, transfer(arguments))));
    return completer.future;
  }

  void _complete(int callId, bool ok, Object? value) {
    final completer = _calls.remove(callId);
    if (completer == null) return;
    if (ok) {
      completer.complete(value);
    } else {
      completer.completeError(JsException.fromThrown(value));
    }
  }
}
