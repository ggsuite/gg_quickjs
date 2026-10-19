// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:record_use/record_use.dart';

// Keeps the native library of the Dart binding - QuickJS-ng included - in a
// profile or release build only when the app runs JavaScript through
// gg_quickjs: the functions that open and interrupt a native runtime are
// recorded with @RecordUse. Without recordings the library stays, since
// nothing says it is unused. An app that embeds QuickJS-ng only through the
// build hook of another package then carries one copy, that package's.
void main(List<String> args) async {
  await link(args, (input, output) async {
    // The recordings are a dependency: the hooks runner caches a link by the
    // recordings of the build that ran it first.
    // ignore: deprecated_member_use
    final recordings = input.recordedUsagesFile;
    if (recordings != null) output.dependencies.add(recordings);
    if (usesBinding(input.recordedUses)) {
      output.assets.code.addAll(input.assets.code);
    }
  });
}

/// The library of the recorded functions; test/hook/link_test.dart checks
/// it and [bindingMembers] against the sources, so that a rename cannot drop
/// the native library of an app that uses it.
const String nativeLibrary = 'package:gg_quickjs/src/gg_quickjs_native.dart';

/// The functions that every use of the native library calls first.
const List<DefinitionWithStaticCalls> bindingMembers = [
  Method('openNativeRuntime', Library(nativeLibrary)),
  Method('interruptNativeRuntime', Library(nativeLibrary)),
];

/// Whether an app with the recorded [uses] needs the native library.
bool usesBinding(Recordings? uses) =>
    uses == null ||
    bindingMembers.any((member) => (uses.calls[member] ?? const []).isNotEmpty);
