// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'js_runtime.dart';

// #############################################################################
/// The handles that [withJsValues] releases when its body returns.
final class JsValueScope {
  JsValueScope._();

  // ...........................................................................
  /// Adds [value] to the scope and returns it.
  V own<V extends JsValue>(V value) {
    _values.add(value);
    return value;
  }

  /// Removes [value] from the scope, so that it outlives the scope; the
  /// caller disposes it.
  V release<V extends JsValue>(V value) {
    _values.remove(value);
    return value;
  }

  // ...........................................................................
  final _values = <JsValue>[];

  void _dispose() {
    for (final value in _values.reversed) {
      value.dispose();
    }
    _values.clear();
  }
}

// .............................................................................
/// Runs [body] with a scope and releases the handles it owns when [body]
/// returns or throws.
///
/// ```dart
/// final sum = withJsValues((scope) {
///   final add = scope.own(runtime.evaluateHandle('(a, b) => a + b'));
///   return (add as JsFunction)([20, 22]);
/// });
/// ```
T withJsValues<T>(T Function(JsValueScope scope) body) {
  final scope = JsValueScope._();
  try {
    return body(scope);
  } finally {
    scope._dispose();
  }
}

/// Runs the asynchronous [body] with a scope and releases the handles it
/// owns when the future of [body] completes.
Future<T> withJsValuesAsync<T>(
  Future<T> Function(JsValueScope scope) body,
) async {
  final scope = JsValueScope._();
  try {
    return await body(scope);
  } finally {
    scope._dispose();
  }
}
