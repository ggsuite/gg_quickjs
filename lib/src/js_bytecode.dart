// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

// #############################################################################
/// A script or a module compiled by [JsRuntime.compile], for
/// [JsRuntime.evaluateBytecode].
///
/// The bytes belong to the QuickJS-ng version of the package that compiled
/// them. QuickJS-ng does not verify bytecode: evaluate only bytecode that
/// this package compiled, never bytecode from an untrusted source.
final class JsBytecode {
  /// Creates bytecode from the [bytes] that [JsRuntime.compile] returned.
  const JsBytecode(this.bytes);

  /// Creates example bytecode for tests and docs; it does not evaluate.
  factory JsBytecode.example({Uint8List? bytes}) =>
      JsBytecode(bytes ?? Uint8List.fromList(const [0x05, 0x00, 0x00]));

  // ...........................................................................
  /// The serialized bytecode.
  final Uint8List bytes;
}
