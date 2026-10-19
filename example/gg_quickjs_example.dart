// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

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
