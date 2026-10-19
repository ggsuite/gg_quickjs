// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:gg_quickjs/hook.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

// Builds the native library of the Dart binding in two steps, as a package
// that uses package:gg_quickjs/hook.dart does: QuickJS-ng as a static
// library, then the C bridge src/gg_quickjs.c linked with it into the
// dynamic library gg_quickjs. Only the entry points of src/gg_quickjs.h are
// visible. In profile and release builds the link hook drops the library
// from an app that never creates a JsRuntime.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    final logger = Logger('')
      ..level = Level.ALL
      ..onRecord.listen((record) => stdout.writeln(record.message));
    const quickjs = QuickjsNgBuild(libraryName: 'gg_quickjs_ng');
    await quickjs.run(input: input, output: output, logger: logger);
    final bridge = CBuilder.library(
      name: input.packageName,
      assetName: bindingAsset,
      sources: const ['src/gg_quickjs.c'],
      includes: ['src', await QuickjsNgBuild.includeDirectory()],
      std: os == OS.windows ? null : 'gnu11',
      optimizationLevel: OptimizationLevel.o2,
      flags: [
        if (os == OS.windows) ...['/std:c11', '/experimental:c11atomics'],
        ...QuickjsNgBuild.libraryFlags(os),
      ],
      libraries: [quickjs.libraryName, ...QuickjsNgBuild.systemLibraries(os)],
    );
    await bridge.run(
      input: input,
      output: output,
      routing: [
        if (input.config.linkingEnabled)
          ToLinkHook(input.packageName)
        else
          const ToAppBundle(),
      ],
      logger: logger,
    );
  });
}

/// The asset id of the native library, the library of its @Native members.
const String bindingAsset = 'src/gg_quickjs_native.dart';
