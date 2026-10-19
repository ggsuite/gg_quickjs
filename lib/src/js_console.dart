// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'js_runtime.dart';
import 'js_runtime_options.dart';

// .............................................................................
/// Installs the global `console` object of [runtime]: `debug`, `log`,
/// `info`, `warn` and `error` join their arguments by spaces and pass the
/// line to [handler]. Objects appear as JSON, errors with their stack.
void installJsConsole(JsRuntime runtime, JsConsoleHandler handler) {
  final install =
      runtime.evaluateHandle(_source, sourceUrl: '<gg_quickjs>') as JsFunction;
  try {
    install([
      (List<Object?> arguments) {
        handler(
          JsConsoleLevel.values.byName(arguments[0]! as String),
          arguments[1]! as String,
        );
        return null;
      },
    ]);
  } finally {
    install.dispose();
  }
}

const _source = '''
(sink) => {
  const format = (value) => {
    if (typeof value === 'string') return value;
    if (value instanceof Error) {
      return value.stack ? `\${value}\\n\${value.stack}` : String(value);
    }
    if (typeof value === 'object' && value !== null) {
      try {
        return JSON.stringify(value);
      } catch {
        return String(value);
      }
    }
    return String(value);
  };
  const console = {};
  for (const level of ['debug', 'log', 'info', 'warn', 'error']) {
    console[level] = (...args) => {
      sink(level, args.map(format).join(' '));
    };
  }
  Object.defineProperty(globalThis, 'console', {
    value: console,
    writable: true,
    configurable: true,
  });
}
''';
