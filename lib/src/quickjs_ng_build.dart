// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';
import 'dart:isolate';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

// #############################################################################
/// Builds QuickJS-ng as a static library in the build hook of a package that
/// links it into a native library of its own.
///
/// The library holds the core engine only, without `quickjs-libc`: no file
/// system, no network and no process access. Its symbols are hidden, so that
/// several packages of one app each link their own copy without a clash.
///
/// ```dart
/// // hook/build.dart of a package
/// import 'package:code_assets/code_assets.dart';
/// import 'package:gg_quickjs/hook.dart';
/// import 'package:hooks/hooks.dart';
/// import 'package:native_toolchain_c/native_toolchain_c.dart';
///
/// void main(List<String> args) async {
///   await build(args, (input, output) async {
///     if (!input.config.buildCodeAssets) return;
///     final os = input.config.code.targetOS;
///     const quickjs = QuickjsNgBuild();
///     await quickjs.run(input: input, output: output);
///     await CBuilder.library(
///       name: input.packageName,
///       assetName: 'src/my_bindings.dart',
///       sources: ['src/my_engine.c'],
///       includes: [await QuickjsNgBuild.includeDirectory()],
///       flags: QuickjsNgBuild.libraryFlags(os),
///       libraries: [
///         quickjs.libraryName,
///         ...QuickjsNgBuild.systemLibraries(os),
///       ],
///     ).run(input: input, output: output);
///   });
/// }
/// ```
final class QuickjsNgBuild {
  /// Creates the build of the static library [libraryName].
  ///
  /// - [libraryName] the name of the static library in the hook output, e.g.
  ///   `quickjs_ng` for `libquickjs_ng.a`
  /// - [optimizationLevel] the optimization of the compiler
  const QuickjsNgBuild({
    this.libraryName = 'quickjs_ng',
    this.optimizationLevel = OptimizationLevel.o2,
  });

  /// Creates an example build for tests and docs.
  factory QuickjsNgBuild.example({
    String? libraryName,
    OptimizationLevel? optimizationLevel,
  }) => QuickjsNgBuild(
    libraryName: libraryName ?? 'example_quickjs_ng',
    optimizationLevel: optimizationLevel ?? OptimizationLevel.o2,
  );

  // ...........................................................................
  /// Compiles QuickJS-ng for the target of [input] into the static library
  /// [libraryName] in the output directory of the hook, where a [CBuilder]
  /// of the same hook finds it through `libraries: [libraryName]`.
  ///
  /// - [input] the input of the build hook
  /// - [output] the output of the build hook; it gets the sources as
  ///   dependencies, no asset
  /// - [logger] receives the compiler output; a default logger otherwise
  Future<void> run({
    required BuildInput input,
    required BuildOutputBuilder output,
    Logger? logger,
  }) async {
    final os = input.config.code.targetOS;
    final builder = CBuilder.library(
      name: libraryName,
      sources: await sources(),
      includes: [await includeDirectory()],
      linkModePreference: LinkModePreference.static,
      optimizationLevel: optimizationLevel,
      std: os == OS.windows ? null : 'gnu11',
      defines: defines(os),
      flags: compilerFlags(os),
    );
    await builder.run(input: input, output: output, logger: logger);
  }

  // ...........................................................................
  /// The name of the static library in the hook output.
  final String libraryName;

  /// The optimization of the compiler.
  final OptimizationLevel optimizationLevel;

  // ...........................................................................
  /// The C sources of QuickJS-ng, relative to [includeDirectory].
  static const List<String> sourceFiles = [
    'dtoa.c',
    'libregexp.c',
    'libunicode.c',
    'quickjs.c',
  ];

  /// The directory of the QuickJS-ng sources and of `quickjs.h`, an absolute
  /// path resolved through the package config of the running hook.
  static Future<String> includeDirectory() async {
    final library = await Isolate.resolvePackageUri(
      Uri.parse('package:gg_quickjs/'),
    );
    return Directory.fromUri(library!.resolve('../src/quickjs-ng/'))
        .absolute
        .path;
  }

  /// The absolute paths of the C sources of QuickJS-ng.
  static Future<List<String>> sources() async {
    final directory = await includeDirectory();
    return [
      for (final file in sourceFiles)
        File.fromUri(Directory(directory).uri.resolve(file)).path,
    ];
  }

  /// The defines that QuickJS-ng needs on [os].
  static Map<String, String?> defines(OS os) => {
    '_GNU_SOURCE': null,
    if (os == OS.windows) ...{
      'WIN32_LEAN_AND_MEAN': null,
      '_WIN32_WINNT': '0x0601',
    },
  };

  /// The compiler flags for the QuickJS-ng sources on [os]: hidden symbols,
  /// a section per function so that the linker drops what nobody calls,
  /// unsigned `char` as upstream builds it, no warnings of third-party code.
  static List<String> compilerFlags(OS os) => os == OS.windows
      ? const ['/std:c11', '/experimental:c11atomics', '/J', '/w']
      : const [
          '-fvisibility=hidden',
          '-ffunction-sections',
          '-fdata-sections',
          '-funsigned-char',
          '-w',
        ];

  /// The flags for the native library that links QuickJS-ng on [os]: hidden
  /// symbols, unused code dropped, the static library kept inside and, on
  /// Android, 16 KB pages.
  static List<String> libraryFlags(OS os) => switch (os) {
    OS.android => const [
      '-fvisibility=hidden',
      '-Wl,-z,max-page-size=16384',
      '-Wl,--exclude-libs,ALL',
      '-Wl,--gc-sections',
    ],
    OS.linux => const [
      '-fvisibility=hidden',
      '-Wl,--exclude-libs,ALL',
      '-Wl,--gc-sections',
    ],
    OS.iOS || OS.macOS => const ['-fvisibility=hidden', '-Wl,-dead_strip'],
    _ => const [],
  };

  /// The system libraries that QuickJS-ng needs on [os].
  static List<String> systemLibraries(OS os) => switch (os) {
    OS.android => const ['m'],
    OS.linux => const ['m', 'pthread'],
    _ => const [],
  };
}
