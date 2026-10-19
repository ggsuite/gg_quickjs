// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

part of 'js_runtime.dart';

// #############################################################################
/// A handle of a JavaScript value that stays in its [JsRuntime].
///
/// A handle holds its value until [dispose], the disposal of its runtime or
/// its garbage collection in Dart; [withJsValues] releases a scope of them.
/// It belongs to the runtime that created it and works only there.
sealed class JsValue {
  JsValue._(this._runtime, this._address) {
    _finalizer.attach(this, _JsRelease(_runtime, _address), detach: this);
  }

  // ...........................................................................
  /// Converts the value to a Dart value, as [JsRuntime.evaluate] does.
  Object? toDart() {
    _checkAlive();
    return _runtime._toDart(this);
  }

  /// Releases the value; a no-op when it is released already.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    _runtime._free(_address);
  }

  // ...........................................................................
  /// The runtime of the value.
  JsRuntime get runtime => _runtime;

  /// Whether [dispose] was called.
  bool get isDisposed => _disposed;

  // ...........................................................................
  final JsRuntime _runtime;
  final int _address;
  var _disposed = false;

  static final _finalizer = Finalizer<_JsRelease>((release) => release.run());

  void _checkAlive() {
    if (_disposed) throw StateError('The $runtimeType is disposed');
  }
}

// #############################################################################
/// A handle of a primitive value, e.g. of a symbol or of a number that
/// [JsRuntime.evaluateHandle] returned.
final class JsPrimitive extends JsValue {
  JsPrimitive._(super._runtime, super._address) : super._();
}

// #############################################################################
/// A handle of a JavaScript object.
final class JsObject extends JsValue {
  JsObject._(super._runtime, super._address) : super._();

  // ...........................................................................
  /// Reads the property [key], a [String] or an [int], as a Dart value.
  Object? get(Object key) {
    _checkAlive();
    return _runtime._get(_address, key, JsRuntime._convert);
  }

  /// Reads the property [key] as a handle.
  JsValue getHandle(Object key) {
    _checkAlive();
    return _runtime._get(_address, key, JsRuntime._handle)! as JsValue;
  }

  /// Writes [value] to the property [key].
  void set(Object key, Object? value) {
    _checkAlive();
    _runtime._set(_address, key, _runtime._codec.encode(value));
  }

  /// The own enumerable string keys of the object.
  List<String> get keys {
    _checkAlive();
    return _runtime._keys(_address);
  }
}

// #############################################################################
/// A handle of a JavaScript function; callable like a Dart function.
///
/// ```dart
/// final add = runtime.evaluate('(a, b) => a + b') as JsFunction;
/// print(add([20, 22])); // 42
/// ```
final class JsFunction extends JsObject {
  JsFunction._(super._runtime, super._address) : super._();

  // ...........................................................................
  /// Calls the function with [arguments] and [thisArg] as `this`; returns
  /// the result as a Dart value.
  Object? call([List<Object?> arguments = const [], JsValue? thisArg]) {
    _checkAlive();
    return _runtime._call(this, thisArg, arguments, JsRuntime._convert);
  }

  /// Calls the function and returns the result as a handle.
  JsValue callHandle([List<Object?> arguments = const [], JsValue? thisArg]) {
    _checkAlive();
    return _runtime._call(this, thisArg, arguments, JsRuntime._handle)!
        as JsValue;
  }
}

// #############################################################################
/// A handle of a JavaScript promise.
final class JsPromise extends JsObject {
  JsPromise._(super._runtime, super._address) : super._();

  // ...........................................................................
  /// A future that completes with the value of the promise, or with a
  /// [JsException] when it rejects.
  Future<Object?> get future {
    _checkAlive();
    return _runtime._future(this);
  }
}

// #############################################################################
/// A handle of a JavaScript `ArrayBuffer`.
final class JsArrayBuffer extends JsObject {
  JsArrayBuffer._(super._runtime, super._address) : super._();

  // ...........................................................................
  /// A copy of the bytes of the buffer.
  Uint8List get bytes => (toDart()! as ByteBuffer).asUint8List();
}

// #############################################################################
/// Releases the value of a handle that Dart collected.
class _JsRelease {
  _JsRelease(this.runtime, this.address);

  final JsRuntime runtime;
  final int address;

  void run() => runtime._free(address);
}
