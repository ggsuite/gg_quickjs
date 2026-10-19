// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:ffi';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:ffi/ffi.dart';
import 'package:gg_quickjs/hook.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';
import 'package:test/test.dart';

void main() {
  group('QuickjsNgBuild', () {
    group('QuickjsNgBuild.example()', () {
      test('names a library', () {
        expect(QuickjsNgBuild.example().libraryName, 'example_quickjs_ng');
        expect(
          QuickjsNgBuild.example(
            libraryName: 'other',
            optimizationLevel: OptimizationLevel.o3,
          ).optimizationLevel,
          OptimizationLevel.o3,
        );
        expect(const QuickjsNgBuild().libraryName, 'quickjs_ng');
      });
    });

    group('includeDirectory(), sources()', () {
      test('point to the QuickJS-ng sources of the package', () async {
        final directory = await QuickjsNgBuild.includeDirectory();
        expect(File('${directory}quickjs.h').existsSync(), isTrue);
        final sources = await QuickjsNgBuild.sources();
        expect(sources, hasLength(QuickjsNgBuild.sourceFiles.length));
        for (final source in sources) {
          expect(File(source).existsSync(), isTrue, reason: source);
        }
      });
    });

    group('defines(os), compilerFlags(os), libraryFlags(os), '
        'systemLibraries(os)', () {
      test('fit each platform', () {
        for (final os in [
          OS.android,
          OS.iOS,
          OS.linux,
          OS.macOS,
          OS.windows,
          OS.fuchsia,
        ]) {
          expect(QuickjsNgBuild.defines(os), containsPair('_GNU_SOURCE', null));
          expect(
            QuickjsNgBuild.compilerFlags(os),
            os == OS.windows
                ? contains('/experimental:c11atomics')
                : contains('-fvisibility=hidden'),
          );
          expect(QuickjsNgBuild.libraryFlags(os), isA<List<String>>());
          expect(QuickjsNgBuild.systemLibraries(os), isA<List<String>>());
        }
        expect(QuickjsNgBuild.defines(OS.windows), contains('_WIN32_WINNT'));
        expect(
          QuickjsNgBuild.libraryFlags(OS.android),
          contains('-Wl,-z,max-page-size=16384'),
        );
        expect(
          QuickjsNgBuild.libraryFlags(OS.macOS),
          contains('-Wl,-dead_strip'),
        );
        expect(
          QuickjsNgBuild.libraryFlags(OS.linux),
          contains('-Wl,--exclude-libs,ALL'),
        );
        expect(QuickjsNgBuild.libraryFlags(OS.windows), isEmpty);
        expect(QuickjsNgBuild.systemLibraries(OS.linux), ['m', 'pthread']);
        expect(QuickjsNgBuild.systemLibraries(OS.android), ['m']);
        expect(QuickjsNgBuild.systemLibraries(OS.iOS), isEmpty);
      });
    });

    group('run(input, output, logger)', () {
      test('builds QuickJS-ng that a library of the hook links', () async {
        const quickjs = QuickjsNgBuild(libraryName: 'consumer_quickjs_ng');
        await testCodeBuildHook(
          mainMethod: (args) => build(args, (input, output) async {
            final os = input.config.code.targetOS;
            await quickjs.run(input: input, output: output);
            await CBuilder.library(
              name: 'quickjs_ng_consumer',
              assetName: 'quickjs_ng_consumer.dart',
              sources: const ['test/fixtures/quickjs_ng_consumer.c'],
              includes: [await QuickjsNgBuild.includeDirectory()],
              flags: QuickjsNgBuild.libraryFlags(os),
              libraries: [
                quickjs.libraryName,
                ...QuickjsNgBuild.systemLibraries(os),
              ],
            ).run(input: input, output: output);
          }),
          check: (input, output) {
            expect(
              output.dependencies.map((uri) => uri.pathSegments.last),
              containsAll(QuickjsNgBuild.sourceFiles),
            );
            // The output folder of the hook exists only during the check.
            final library = output.assets.code.single.file!;
            final dylib = DynamicLibrary.open(library.toFilePath());
            final eval = dylib
                .lookupFunction<
                  Int32 Function(Pointer<Utf8>),
                  int Function(Pointer<Utf8>)
                >('consumer_eval');
            final code = '1 + 1'.toNativeUtf8();
            expect(eval(code), 2);
            malloc.free(code);
            // QuickJS-ng stays hidden inside the library of the consumer.
            expect(dylib.providesSymbol('JS_NewRuntime'), isFalse);
          },
        );
      });
    });
  });
}
