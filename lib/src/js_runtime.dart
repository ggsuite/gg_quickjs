// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'gg_quickjs_native.dart';
import 'js_bytecode.dart';
import 'js_console.dart';
import 'js_exception.dart';
import 'js_fetch.dart';
import 'js_files.dart';
import 'js_isolate_runtime.dart';
import 'js_memory_usage.dart';
import 'js_runtime_options.dart';
import 'js_timers.dart';
import 'js_value_codec.dart';

part 'js_registration.dart';
part 'js_value.dart';

/// A Dart function that JavaScript calls with its arguments as one list.
///
/// It returns a value for JavaScript; a returned [Future] becomes a promise.
/// A thrown [JsException] raises the JavaScript error of its name, any other
/// error an `Error` with its text.
typedef JsHostFunction = Object? Function(List<Object?> arguments);

// #############################################################################
/// A QuickJS-ng runtime that runs JavaScript synchronously on the calling
/// isolate.
///
/// Values cross as Dart values: numbers, strings, booleans, null, [BigInt],
/// lists, maps, sets, [DateTime], typed data, errors; a JavaScript function
/// arrives as a [JsFunction], a promise as a [Future]. [evaluateHandle] and
/// [JsObject] keep JavaScript objects in JavaScript.
///
/// After every call into JavaScript the runtime runs the pending jobs of
/// promises. It reaches neither files nor the network unless
/// [JsRuntimeOptions] grants them.
///
/// ```dart
/// final runtime = JsRuntime();
/// runtime.registerFunction('greet', (args) => 'Hello ${args[0]}!');
/// print(runtime.evaluate('greet("Dart")')); // Hello Dart!
/// runtime.dispose();
/// ```
final class JsRuntime {
  /// Creates a runtime with [options]; throws an [ArgumentError] for a limit
  /// that is not positive and a [JsOutOfMemoryError] when the memory limit
  /// leaves no room for the runtime itself.
  JsRuntime({this.options = const JsRuntimeOptions()}) {
    _validate(options);
    _host = _JsRuntimeHost(this);
    _codec = JsValueCodec(host: _host);
    _hostCall = NativeCallable<GgQjsHostCallNative>.isolateLocal(
      _onHostCall,
      exceptionalReturn: 1,
    );
    _hostRelease = NativeCallable<GgQjsHostReleaseNative>.isolateLocal(
      _onHostRelease,
    );
    _moduleLoad = NativeCallable<GgQjsModuleLoadNative>.isolateLocal(
      _onModuleLoad,
      exceptionalReturn: 1,
    );
    _rejection = NativeCallable<GgQjsRejectionNative>.isolateLocal(
      _onRejection,
    );
    _native = openNativeRuntime(
      memoryLimit: options.memoryLimit ?? 0,
      maxStackSize: options.maxStackSize,
      gcThreshold: options.gcThreshold ?? 0,
      timeoutMicroseconds: options.timeout?.inMicroseconds ?? 0,
      hostCall: _hostCall.nativeFunction,
      hostRelease: _hostRelease.nativeFunction,
      moduleLoad: _moduleLoad.nativeFunction,
      rejection: _rejection.nativeFunction,
    );
    if (_native == nullptr) {
      _closeCallables();
      throw JsOutOfMemoryError(
        message: 'the memory limit leaves no room for a runtime',
      );
    }
    try {
      _install();
    } catch (_) {
      dispose();
      rethrow;
    }
  }

  /// Creates an example runtime for tests and docs, with the limits of
  /// [JsRuntimeOptions.example].
  factory JsRuntime.example({JsRuntimeOptions? options}) =>
      JsRuntime(options: options ?? JsRuntimeOptions.example());

  /// Spawns a worker isolate that owns a runtime with [options] and returns
  /// the [JsIsolateRuntime] that calls it asynchronously.
  static Future<JsIsolateRuntime> spawn({
    JsRuntimeOptions options = const JsRuntimeOptions(),
  }) => JsIsolateRuntime.spawn(options: options);

  // ...........................................................................
  /// Evaluates the script [code] and returns its completion value as a Dart
  /// value; a promise becomes a [Future].
  ///
  /// - [sourceUrl] the name of the script in stack traces and errors
  Object? evaluate(String code, {String sourceUrl = defaultSourceUrl}) =>
      _codec.decode(_evaluate(code, sourceUrl, _convert));

  /// Evaluates the script [code] and returns its completion value as a
  /// handle that keeps it in JavaScript.
  JsValue evaluateHandle(String code, {String sourceUrl = defaultSourceUrl}) =>
      _handleAt(_evaluate(code, sourceUrl, _handle), 0);

  /// Evaluates the module [code] and returns its exports once its
  /// evaluation, top-level `await` included, has finished.
  ///
  /// - [sourceUrl] the name of the module; relative imports resolve
  ///   against it, and with [JsRuntimeOptions.fileSystem] an absolute path
  ///   imports the files next to it
  Future<Map<String, Object?>> evaluateModule(
    String code, {
    String sourceUrl = defaultModuleUrl,
  }) async {
    final bytes = _withText(
      code,
      (text, length) => _withText(
        sourceUrl,
        (name, _) => _run(
          (result) => ggQjsEvalModule(_native, text, length, name, result),
        ),
      ),
    );
    return await _moduleExports(_handleAt(bytes, 5), _handleAt(bytes, 15));
  }

  /// Calls the global function [name] with [arguments] and returns its
  /// result.
  Object? call(String name, [List<Object?> arguments = const []]) {
    final function = _get(0, name, _handle)! as JsValue;
    try {
      if (function is! JsFunction) {
        throw JsTypeError(message: '$name is not a function');
      }
      return function.call(arguments);
    } finally {
      function.dispose();
    }
  }

  /// Reads the global variable [name].
  Object? getGlobal(String name) => _get(0, name, _convert);

  /// Writes [value] to the global variable [name].
  void setGlobal(String name, Object? value) =>
      _set(0, name, _codec.encode(value));

  /// Makes [function] callable from JavaScript as the global function
  /// [name] until the returned registration is revoked.
  JsRegistration registerFunction(String name, JsHostFunction function) {
    _checkAlive();
    final id = _addFunction(function);
    _set(0, name, JsValueCodec.encodeHostFunction(id: id, name: name));
    _registrations[name] = id;
    return JsRegistration._(runtime: this, name: name, id: id);
  }

  /// Registers the source of modules by name, for `import` and
  /// [evaluateModule].
  void registerModules(Map<String, String> modules) {
    _checkAlive();
    _modules.addAll(modules);
  }

  /// Compiles [code] into bytecode without running it.
  ///
  /// - [sourceUrl] the name of the script or module
  /// - [module] whether [code] is a module
  JsBytecode compile(
    String code, {
    String sourceUrl = defaultSourceUrl,
    bool module = false,
  }) {
    final bytes = _withText(
      code,
      (text, length) => _withText(
        sourceUrl,
        (name, _) => _run(
          (result) =>
              ggQjsCompile(_native, text, length, name, module ? 1 : 0, result),
        ),
      ),
    );
    return JsBytecode(bytes);
  }

  /// Evaluates [bytecode] of [compile]: a script returns its completion
  /// value as [evaluate] does, a module a [Future] of its exports as
  /// [evaluateModule] does.
  Object? evaluateBytecode(JsBytecode bytecode) {
    final bytes = _withBytes(
      bytecode.bytes,
      (data, length) => _run(
        (result) => ggQjsEvalBytecode(_native, data, length, _convert, result),
      ),
    );
    if (bytes[5] == _tagTrue) {
      return _moduleExports(_handleAt(bytes, 6), _handleAt(bytes, 16));
    }
    return _codec.decode(Uint8List.sublistView(bytes, 6));
  }

  /// Runs the jobs of settled promises that are still pending, e.g. after a
  /// [Future] that JavaScript awaits completed outside of a call.
  void executePendingJobs() => _run((result) => ggQjsRunJobs(_native, result));

  /// Interrupts the JavaScript that runs now, e.g. from a host function; a
  /// [JsInterruptedError] stops it.
  void interrupt() {
    _checkAlive();
    ggQjsInterrupt(_native);
  }

  /// Runs the garbage collector.
  void runGc() {
    _checkAlive();
    ggQjsRunGc(_native);
  }

  /// Frees the runtime and every handle; any further call throws a
  /// [StateError]. A no-op when the runtime is disposed already.
  void dispose() {
    if (_disposed) return;
    if (_depth > 0) {
      throw StateError('A JsRuntime cannot be disposed while it runs');
    }
    _disposed = true;
    for (final disposer in _disposers) {
      disposer();
    }
    ggQjsDispose(_native);
    _closeCallables();
    _functions.clear();
    final pending = [..._pending];
    _pending.clear();
    for (final completer in pending) {
      completer.future.ignore();
      completer.completeError(
        JsInterruptedError(message: 'the runtime was disposed'),
      );
    }
  }

  // ...........................................................................
  /// The limits and capabilities of the runtime.
  final JsRuntimeOptions options;

  /// Whether [dispose] was called.
  bool get isDisposed => _disposed;

  /// The memory the runtime holds.
  JsMemoryUsage get memoryUsage {
    _checkAlive();
    final fields = calloc<Int64>(7);
    try {
      ggQjsMemoryUsage(_native, fields);
      return JsMemoryUsage(
        allocatedBytes: fields[0],
        allocations: fields[1],
        limit: fields[2] > 0 ? fields[2] : null,
        usedBytes: fields[3],
        objects: fields[4],
        strings: fields[5],
        functions: fields[6],
      );
    } finally {
      calloc.free(fields);
    }
  }

  /// The address of the native runtime, for [JsIsolateRuntime.interrupt].
  @internal
  int get nativeAddress => _native.address;

  /// Reports [error] of JavaScript that no call awaits, e.g. of a timer, to
  /// [JsRuntimeOptions.onUnhandledRejection].
  @internal
  void reportUncaughtError(Object error) {
    final handler = options.onUnhandledRejection;
    if (handler != null) scheduleMicrotask(() => handler(error));
  }

  // ...........................................................................
  /// The source URL of a script that names none.
  static const String defaultSourceUrl = '<eval>';

  /// The source URL of a module that names none.
  static const String defaultModuleUrl = '<module>';

  // ...........................................................................
  late final _JsRuntimeHost _host;
  late final JsValueCodec _codec;
  late final NativeCallable<GgQjsHostCallNative> _hostCall;
  late final NativeCallable<GgQjsHostReleaseNative> _hostRelease;
  late final NativeCallable<GgQjsModuleLoadNative> _moduleLoad;
  late final NativeCallable<GgQjsRejectionNative> _rejection;
  late final Pointer<GgQjsRuntime> _native;
  late final JsFunction _then;

  final _functions = <int, Function>{};
  final _registrations = <String, int>{};
  final _modules = <String, String>{};
  final _rejections = <Object?>[];
  final _pending = <Completer<Object?>>{};
  final _disposers = <void Function()>[];
  var _nextFunctionId = 1;
  var _depth = 0;
  var _disposed = false;

  static const int _convert = 0;
  static const int _handle = 1;
  static const int _tagTrue = 3;
  static const int _timedOut = 2;
  static const int _outOfMemory = 3;

  static void _validate(JsRuntimeOptions options) {
    void positive(String name, num? value) {
      if (value != null && value <= 0) {
        throw ArgumentError.value(value, name, 'must be positive');
      }
    }

    positive('memoryLimit', options.memoryLimit);
    positive('maxStackSize', options.maxStackSize);
    positive('gcThreshold', options.gcThreshold);
    positive('timeout', options.timeout?.inMicroseconds);
  }

  // Installs the helpers and the granted capabilities before any script.
  void _install() {
    _then = evaluateHandle(
      '(promise, onFulfilled, onRejected) => '
      '{ promise.then(onFulfilled, onRejected); }',
      sourceUrl: '<gg_quickjs>',
    ) as JsFunction;
    final onConsole = options.onConsole;
    if (onConsole != null) installJsConsole(this, onConsole);
    if (options.timers) _disposers.add(installJsTimers(this));
    final network = options.network;
    if (network != null) _disposers.add(installJsFetch(this, network));
    final fileSystem = options.fileSystem;
    if (fileSystem != null) installJsFiles(this, fileSystem);
  }

  void _checkAlive() {
    if (_disposed) throw StateError('The JsRuntime is disposed');
  }

  void _closeCallables() {
    _hostCall.close();
    _hostRelease.close();
    _moduleLoad.close();
    _rejection.close();
  }

  // Calls an entry point of the bridge and returns its result; throws the
  // JavaScript exception of a failed call.
  Uint8List _run(int Function(Pointer<GgQjsBytes> result) entry) {
    _checkAlive();
    final result = calloc<GgQjsBytes>();
    _depth++;
    try {
      final status = entry(result);
      final bytes = _take(result.ref);
      if (status != 0) throw _exceptionOf(bytes);
      return bytes ?? Uint8List(0);
    } finally {
      _depth--;
      calloc.free(result);
      if (_depth == 0) _flushRejections();
    }
  }

  // Takes over a buffer of the bridge.
  static Uint8List? _take(GgQjsBytes bytes) {
    if (bytes.data == nullptr) return null;
    final copy = Uint8List.fromList(bytes.data.asTypedList(bytes.length));
    ggQjsFree(bytes.data.cast());
    return copy;
  }

  JsException _exceptionOf(Uint8List? bytes) {
    if (bytes == null || bytes[0] == _outOfMemory) return JsOutOfMemoryError();
    final value = _codec.decode(Uint8List.sublistView(bytes, 1));
    if (bytes[0] != 0) {
      return JsInterruptedError(
        timedOut: bytes[0] == _timedOut,
        stack: value is JsException ? value.stack : '',
      );
    }
    return JsException.fromThrown(value);
  }

  // Passes [text] as UTF-8 with a terminating zero, as JS_Eval needs it.
  T _withText<T>(
    String text,
    T Function(Pointer<Char> text, int length) body,
  ) => _withBytes(
    utf8.encode(text),
    (data, length) => body(data.cast(), length),
  );

  T _withBytes<T>(
    Uint8List bytes,
    T Function(Pointer<Uint8> data, int length) body,
  ) {
    final pointer = calloc<Uint8>(bytes.length + 1);
    pointer.asTypedList(bytes.length).setAll(0, bytes);
    try {
      return body(pointer, bytes.length);
    } finally {
      calloc.free(pointer);
    }
  }

  // Writes [bytes] into a buffer that the bridge takes over.
  static void _give(Pointer<GgQjsBytes> target, List<int> bytes) {
    final data = ggQjsMalloc(bytes.length + 1).cast<Uint8>();
    data.asTypedList(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0;
    target.ref
      ..data = data
      ..length = bytes.length;
  }

  Uint8List _evaluate(String code, String sourceUrl, int mode) => _withText(
    code,
    (text, length) => _withText(
      sourceUrl,
      (name, _) => _run(
        (result) => ggQjsEval(_native, text, length, name, mode, result),
      ),
    ),
  );

  // The handle that the encoded value at [offset] of [bytes] holds.
  JsValue _handleAt(Uint8List bytes, int offset) {
    final data = ByteData.sublistView(bytes);
    return _wrap(
      JsHandleKind.values[bytes[offset + 1]],
      data.getUint64(offset + 2, Endian.host),
    );
  }

  JsValue _wrap(JsHandleKind kind, int address) => switch (kind) {
    JsHandleKind.function => JsFunction._(this, address),
    JsHandleKind.promise => JsPromise._(this, address),
    JsHandleKind.arrayBuffer => JsArrayBuffer._(this, address),
    JsHandleKind.object => JsObject._(this, address),
    JsHandleKind.other => JsPrimitive._(this, address),
  };

  Future<Map<String, Object?>> _moduleExports(
    JsValue evaluation,
    JsValue namespace,
  ) async {
    try {
      await (evaluation as JsPromise).future;
      return namespace.toDart()! as Map<String, Object?>;
    } finally {
      evaluation.dispose();
      namespace.dispose();
    }
  }

  Object? _get(int object, Object key, int mode) {
    final bytes = _withBytes(
      _codec.encode(key),
      (data, length) => _run(
        (result) => ggQjsGet(_native, object, data, length, mode, result),
      ),
    );
    return mode == _handle ? _handleAt(bytes, 0) : _codec.decode(bytes);
  }

  void _set(int object, Object key, Uint8List value) {
    _withBytes(
      _codec.encode(key),
      (keyData, keyLength) => _withBytes(
        value,
        (valueData, valueLength) => _run(
          (result) => ggQjsSet(
            _native,
            object,
            keyData,
            keyLength,
            valueData,
            valueLength,
            result,
          ),
        ),
      ),
    );
  }

  void _delete(int object, Object key) {
    _withBytes(
      _codec.encode(key),
      (data, length) =>
          _run((result) => ggQjsDelete(_native, object, data, length, result)),
    );
  }

  List<String> _keys(int object) =>
      (_codec.decode(_run((result) => ggQjsKeys(_native, object, result)))!
              as List<Object?>)
          .cast<String>();

  Object? _call(
    JsValue function,
    JsValue? self,
    List<Object?> arguments,
    int mode,
  ) {
    final bytes = _withBytes(
      _codec.encode(arguments),
      (data, length) => _run(
        (result) => ggQjsCall(
          _native,
          _host.addressOf(function),
          self == null ? 0 : _host.addressOf(self),
          data,
          length,
          mode,
          result,
        ),
      ),
    );
    return mode == _handle ? _handleAt(bytes, 0) : _codec.decode(bytes);
  }

  Object? _toDart(JsValue value) => _codec.decode(
    _run((result) => ggQjsToValue(_native, _host.addressOf(value), result)),
  );

  void _free(int address) {
    if (!_disposed) ggQjsFreeHandle(_native, address);
  }

  int _addFunction(Function function) {
    if (function is! JsHostFunction) {
      throw ArgumentError.value(
        function,
        'function',
        'A Dart function for JavaScript takes its arguments as one '
            'List<Object?>',
      );
    }
    final id = _nextFunctionId++;
    _functions[id] = function;
    return id;
  }

  void _revoke(JsRegistration registration) {
    if (_disposed) return;
    _functions.remove(registration.id);
    if (_registrations[registration.name] != registration.id) return;
    _registrations.remove(registration.name);
    _delete(0, registration.name);
  }

  // A promise of JavaScript that settles with [future].
  int _promiseOf(Future<Object?> future) {
    final bytes = _run((result) => ggQjsNewPromise(_native, result));
    final promise = _handleAt(bytes, 5);
    final resolve = _handleAt(bytes, 15) as JsFunction;
    final reject = _handleAt(bytes, 25) as JsFunction;
    unawaited(
      future
          .then(
            (value) => _settle(resolve, value, reject),
            onError: (Object error) =>
                _settle(reject, JsException.fromDartError(error), null),
          )
          .whenComplete(() {
            resolve.dispose();
            reject.dispose();
          }),
    );
    // The bridge copies the promise before the microtask frees the handle.
    scheduleMicrotask(promise.dispose);
    return promise._address;
  }

  void _settle(JsFunction function, Object? value, JsFunction? reject) {
    if (_disposed) return;
    try {
      function.call([value]);
    } on ArgumentError catch (error) {
      if (reject != null) {
        _settle(reject, JsException.fromDartError(error), null);
      }
    } catch (error) {
      reportUncaughtError(error);
    }
  }

  Future<Object?> _future(JsPromise promise) {
    final completer = Completer<Object?>();
    _pending.add(completer);
    _then.call([
      promise,
      (List<Object?> arguments) {
        if (_pending.remove(completer)) completer.complete(arguments.first);
      },
      (List<Object?> arguments) {
        if (_pending.remove(completer)) {
          completer.completeError(JsException.fromThrown(arguments.first));
        }
      },
    ]);
    return completer.future;
  }

  void _flushRejections() {
    if (_rejections.isEmpty) return;
    final reasons = [..._rejections];
    _rejections.clear();
    for (final reason in reasons) {
      reportUncaughtError(JsException.fromThrown(reason));
    }
  }

  // ...........................................................................
  // The callbacks of the bridge

  int _onHostCall(
    int id,
    Pointer<Uint8> args,
    int length,
    Pointer<GgQjsBytes> result,
  ) {
    try {
      final function = _functions[id];
      if (function == null) {
        throw JsTypeError(message: 'the host function was revoked');
      }
      final arguments =
          _codec.decode(Uint8List.fromList(args.asTypedList(length)))!
              as List<Object?>;
      final value = (function as JsHostFunction)(arguments);
      _give(result, _codec.encode(value));
      return 0;
    } catch (error) {
      _give(result, _codec.encode(JsException.fromDartError(error)));
      return 1;
    }
  }

  void _onHostRelease(int id) => _functions.remove(id);

  int _onModuleLoad(Pointer<Char> name, Pointer<GgQjsBytes> source) {
    final moduleName = name.cast<Utf8>().toDartString();
    try {
      final text =
          _modules[moduleName] ??
          options.moduleLoader?.call(moduleName) ??
          readJsModuleFile(moduleName, options.fileSystem);
      if (text == null) return 1;
      _give(source, utf8.encode(text));
      return 0;
    } catch (error) {
      _give(
        source,
        utf8.encode(error is JsException ? error.message : '$error'),
      );
      return 2;
    }
  }

  void _onRejection(Pointer<Uint8> reason, int length) {
    _rejections.add(
      reason == nullptr
          ? null
          : _codec.decode(Uint8List.fromList(reason.asTypedList(length))),
    );
  }
}

// #############################################################################
/// The handles, functions and futures of a runtime for its codec.
class _JsRuntimeHost implements JsCodecHost {
  _JsRuntimeHost(this._runtime);

  final JsRuntime _runtime;

  @override
  int addressOf(JsValue handle) {
    if (!identical(handle._runtime, _runtime)) {
      throw ArgumentError.value(
        handle,
        'handle',
        'A handle of another JsRuntime',
      );
    }
    if (handle._disposed) throw StateError('The handle is disposed');
    return handle._address;
  }

  @override
  int registerFunction(Function function) => _runtime._addFunction(function);

  @override
  int promiseOf(Future<Object?> future) => _runtime._promiseOf(future);

  @override
  Object? valueOf(JsHandleKind kind, int address) {
    final handle = _runtime._wrap(kind, address);
    if (handle is! JsPromise) return handle;
    try {
      return handle.future;
    } finally {
      handle.dispose();
    }
  }
}
