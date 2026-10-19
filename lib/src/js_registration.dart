// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

part of 'js_runtime.dart';

// #############################################################################
/// A Dart function that [JsRuntime.registerFunction] made callable from
/// JavaScript.
///
/// After [revoke] the global function is gone, and a reference that
/// JavaScript kept throws a `TypeError`.
final class JsRegistration {
  JsRegistration._({
    required this._runtime,
    required this.name,
    required this.id,
  });

  // ...........................................................................
  /// Revokes the function; a no-op when it is revoked already.
  void revoke() {
    if (_revoked) return;
    _revoked = true;
    _runtime._revoke(this);
  }

  // ...........................................................................
  /// The name of the global function.
  final String name;

  /// The id of the host function in its runtime.
  final int id;

  /// Whether [revoke] was called.
  bool get isRevoked => _revoked;

  // ...........................................................................
  final JsRuntime _runtime;
  var _revoked = false;
}
