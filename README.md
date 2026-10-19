<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# gg_quickjs

English | [Deutsch](README.de.md)

[![CI](https://github.com/ggsuite/gg_quickjs/actions/workflows/quick_check.yaml/badge.svg)](https://github.com/ggsuite/gg_quickjs/actions/workflows/quick_check.yaml)
[![pub package](https://img.shields.io/pub/v/gg_quickjs.svg)](https://pub.dev/packages/gg_quickjs)

QuickJS-ng for Dart - its C sources for the build hooks of native packages and
a Dart binding with typed values, a background isolate and a sandbox.

It carries QuickJS-ng 0.17.0 and runs on iOS, Android, macOS, Linux and
Windows, not on the web. A build hook compiles it from source on the machine
that builds the app: no download, no prebuilt binary.

## Motivation

- Several packages of an app may need QuickJS-ng in their own native code.
  `gg_quickjs` holds its sources once and gives the build hooks of those
  packages one call to compile them into their own library, each copy with
  hidden symbols, so that the copies never clash.
- The QuickJS packages on pub.dev bind older engines, download prebuilt
  binaries, return results as strings or poll promises with timers, and none
  offers its C sources to other build hooks.
- An app that runs scripts wants limits and a sandbox it can trust by
  default: no files, no network, no timers and no console until Dart grants
  them.

## Installation

```bash
dart pub add gg_quickjs
```

The build hook needs a C compiler for the target: Xcode for iOS and macOS,
the Android NDK that Flutter uses, Clang or GCC on Linux, Visual Studio on
Windows.

## Usage

```dart
import 'package:gg_quickjs/gg_quickjs.dart';

Future<void> main() async {
  // A runtime with limits that grants console output and nothing else
  final runtime = JsRuntime(
    options: JsRuntimeOptions(
      memoryLimit: 32 * 1024 * 1024,
      timeout: const Duration(seconds: 1),
      onConsole: (level, message) => print('[${level.name}] $message'),
    ),
  );

  // Values cross as Dart values
  print(runtime.evaluate('({answer: 6 * 7, primes: [2, 3, 5]})'));

  // A Dart function for JavaScript; its Future becomes a promise
  runtime.registerFunction('greet', (args) async => 'Hello ${args[0]}!');
  print(await (runtime.evaluate('greet("Dart")')! as Future<Object?>));

  // Errors of JavaScript as typed exceptions
  try {
    runtime.evaluate('null.answer', sourceUrl: 'main.js');
  } on JsTypeError catch (error) {
    print('${error.name} at ${error.line}:${error.column}: ${error.message}');
  }

  // The sandbox: no network and no files unless Dart grants them
  runtime.evaluate('console.log(typeof fetch, typeof fs)');
  runtime.dispose();

  // The same API as futures, with the runtime on a background isolate
  final background = await JsRuntime.spawn();
  print(await background.evaluate('[1, 2, 3].map((x) => x * x)'));
  await background.dispose();
}
```

It prints:

```text
{answer: 42, primes: [2, 3, 5]}
Hello Dart!
TypeError at 1:1: cannot read property 'answer' of null
[log] undefined undefined
[1, 4, 9]
```

### Exchange values

`evaluate`, `call`, `getGlobal` and the arguments of host functions convert
values both ways:

| JavaScript | Dart |
| --- | --- |
| `undefined`, `null` | `null`; pass `jsUndefined` for `undefined` |
| boolean, string | `bool`, `String` |
| number | `int` when integral and safe, else `double` |
| `bigint` | `BigInt`; an `int` beyond 2^53 becomes one |
| array, object | `List`, `Map` with `String` keys |
| `Map`, `Set` | `Map`, `Set` |
| `Date` | `DateTime` in UTC |
| `ArrayBuffer`, typed arrays | `ByteBuffer`, `Uint8List` and the other typed lists |
| `Error` | the `JsException` of its kind |
| function | `JsFunction`; a Dart function becomes a JavaScript function |
| promise | `Future`; a `Future` becomes a promise |

`evaluateHandle` keeps a value in JavaScript as a `JsValue`: `JsObject`,
`JsFunction`, `JsPromise`, `JsArrayBuffer` or `JsPrimitive`. A handle lives
until `dispose()`, until Dart collects it or until its runtime is disposed;
`withJsValues` releases a scope of them:

```dart
final sum = withJsValues((scope) {
  final add = scope.own(runtime.evaluateHandle('(a, b) => a + b'));
  return (add as JsFunction)([20, 22]);
});
```

### Run modules and bytecode

```dart
runtime.registerModules({'math': 'export const twice = (x) => 2 * x;'});
final exports = await runtime.evaluateModule(
  "import { twice } from 'math'; export const answer = twice(21);",
);
final bytecode = runtime.compile('6 * 7');
print([exports['answer'], runtime.evaluateBytecode(bytecode)]); // [42, 42]
```

`import` resolves registered modules first, then
`JsRuntimeOptions.moduleLoader`, then, with a file system grant, the files
below its roots. Evaluate only bytecode that this package compiled.

### Limit and interrupt

`JsRuntimeOptions` takes `memoryLimit`, `maxStackSize`, `gcThreshold` and
`timeout`, the time that one call into JavaScript may take with its pending
jobs. `interrupt()` stops the JavaScript that runs now. Errors arrive as the
sealed `JsException`: `JsSyntaxError`, `JsTypeError`, `JsReferenceError`,
`JsRangeError`, `JsInterruptedError`, `JsOutOfMemoryError`,
`JsStackOverflowError` and `JsError` for the rest, each with `name`,
`message`, `stack`, `line` and `column`.

### Use a background isolate

`JsRuntime.spawn()` returns a `JsIsolateRuntime`: one worker isolate owns
the runtime, the methods return futures and values cross as copies.
Registered functions run on the calling isolate, so JavaScript receives a
promise of their result. `interrupt()` sets a flag of the native runtime and
works while the worker is busy; `dispose()` interrupts the calls in flight,
`dispose(graceful: true)` lets them end.

### Grant capabilities

The sandbox is a capability policy: without a grant the objects do not exist
in JavaScript, and the engine is built without `quickjs-libc`, so there is
no `std` or `os` module.

```dart
final runtime = JsRuntime(
  options: JsRuntimeOptions(
    onConsole: (level, message) => print(message),
    timers: true,
    network: JsNetworkAccess(
      allowedHosts: {'api.example.com'},
      allowUrl: (url) => url.path.startsWith('/v1/'),
    ),
    fileSystem: JsFileSystemAccess(
      readRoots: ['/data/scripts'],
      writeRoots: ['/data/output'],
    ),
  ),
);
```

- `onConsole` adds `console`; `timers` adds `setTimeout`, `setInterval`,
  `clearTimeout` and `clearInterval` on Dart timers.
- `network` adds `fetch`, which reaches only the allowed hosts and checks
  every redirect again.
- `fileSystem` adds a global `fs` with `readText`, `readBytes`, `writeText`,
  `writeBytes`, `exists`, `list` and `remove`, and lets `import` load files.
  Paths must be absolute; `..` and symbolic links are resolved before the
  check, so neither escapes a root.

### Build QuickJS-ng into your own native library

`package:gg_quickjs/hook.dart` is for the build hook of a package with native
code of its own. `QuickjsNgBuild.run` compiles QuickJS-ng as a static library
into the output of the hook, and the library of the package links it:

```dart
// hook/build.dart
import 'package:code_assets/code_assets.dart';
import 'package:gg_quickjs/hook.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    const quickjs = QuickjsNgBuild(libraryName: 'my_engine_quickjs_ng');
    await quickjs.run(input: input, output: output);
    await CBuilder.library(
      name: input.packageName,
      assetName: 'src/my_engine_bindings.dart',
      sources: ['src/my_engine.c'],
      includes: [await QuickjsNgBuild.includeDirectory()],
      flags: QuickjsNgBuild.libraryFlags(os),
      libraries: [quickjs.libraryName, ...QuickjsNgBuild.systemLibraries(os)],
    ).run(input: input, output: output);
  });
}
```

The helper also names the sources, the defines and the compiler flags per
platform for a build of your own. It builds the core only, without
`quickjs-libc`. The package depends on `gg_quickjs`, `hooks`, `code_assets`
and `native_toolchain_c`; ship the `NOTICE` of QuickJS-ng with the app.

## Limitations

- The sandbox is a capability policy, not a defense against hostile code.
  QuickJS-ng is an interpreter written in C; a bug in it can corrupt the
  memory of the app. Run code you do not trust in a separate process.
- QuickJS-ng 0.17.0 does not always recover from running out of memory while
  it compiles: the code that Dart passes compiles without the memory limit,
  but `eval` or `new Function` in a script that has used up its memory may
  crash the process.
- `maxStackSize` counts from the call into JavaScript; the default of 256
  KiB allows about 250 nested calls. The native stack of a Dart isolate holds
  about 1 MiB on 64-bit platforms, so a limit beyond 512 KiB may crash
  instead of throwing a `JsStackOverflowError`.
- `timeout` and `interrupt()` stop JavaScript, not a Dart host function or a
  `fetch` in flight.
- Apple's App Review Guidelines restrict code that an app downloads and runs
  (guideline 4.7, see also 2.5.2). Ship the scripts of an iOS app with it, or
  check the guidelines before you run scripts from elsewhere.
- No web support, no `Atomics.wait`, no `std` or `os` module.

## Documentation

- The API reference on [pub.dev](https://pub.dev/documentation/gg_quickjs/latest/)
- The C bridge between Dart and QuickJS-ng: [src/gg_quickjs.h](src/gg_quickjs.h)
- QuickJS-ng: [github.com/quickjs-ng/quickjs](https://github.com/quickjs-ng/quickjs)

## How it works

- `hook/build.dart` compiles QuickJS-ng with `QuickjsNgBuild` and links it
  with the bridge `src/gg_quickjs.c` into the dynamic library `gg_quickjs`,
  a native asset. `hook/link.dart` drops it from a release build of an app
  that never creates a `JsRuntime`.
- Values cross the bridge in a compact binary encoding; objects that stay in
  JavaScript cross as handles. After each call into JavaScript the bridge
  runs the pending jobs of promises and reports unhandled rejections.
- The bridge updates the stack top on every call, so that a runtime may move
  between the threads of an isolate, enforces the memory limit in its
  allocator and stops a call through the interrupt handler of QuickJS-ng.

## Status

Before 1.0 — the API may change between minor versions. The versions of
`gg_quickjs` are its own; `quickjsNgVersion` names the QuickJS-ng version it
carries. Unlike other ggsuite packages, its types are named `Js…`
(`JsRuntime`, `JsValue`, `JsException`) without the `Gg` prefix, after the
vocabulary of the QuickJS packages on pub.dev.

## Contributing

- Follow the [development guide](doc/guides/develop-guide.md), the
  [code guide](doc/guides/code-guide.md) and the
  [test guide](doc/guides/test-guide.md).
- Update QuickJS-ng with `node tool/update-quickjs-ng.js <tag>`, e.g.
  `v0.17.0`; the script copies the subset and sets the version constant.

## License

MIT — see [LICENSE](LICENSE). QuickJS-ng is MIT licensed as well, see
[NOTICE](NOTICE) and [src/quickjs-ng/LICENSE](src/quickjs-ng/LICENSE).
