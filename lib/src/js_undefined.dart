// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// #############################################################################
/// JavaScript's `undefined` as a Dart value.
///
/// Values from JavaScript bring `undefined` as `null`; pass [jsUndefined]
/// where JavaScript must receive `undefined` rather than `null`, e.g. for a
/// parameter with a default value.
final class JsUndefined {
  const JsUndefined._();

  @override
  String toString() => 'undefined';
}

/// The value that becomes `undefined` in JavaScript.
const JsUndefined jsUndefined = JsUndefined._();
