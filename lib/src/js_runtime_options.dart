// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'js_exception.dart';
import 'js_file_system_access.dart';
import 'js_network_access.dart';

// #############################################################################
/// The level of a `console` call in JavaScript.
enum JsConsoleLevel {
  /// `console.debug`.
  debug,

  /// `console.log`.
  log,

  /// `console.info`.
  info,

  /// `console.warn`.
  warn,

  /// `console.error`.
  error,
}

/// Receives a line that JavaScript wrote to `console`.
typedef JsConsoleHandler = void Function(JsConsoleLevel level, String message);

/// Receives the reason of a promise that JavaScript rejected without a
/// handler, or the error of a timer callback.
typedef JsRejectionHandler = void Function(Object? reason);

/// Returns the source of the module [name], or null when it does not know
/// it.
typedef JsModuleLoader = String? Function(String name);

// #############################################################################
/// The limits and capabilities of a [JsRuntime].
///
/// Everything that reaches beyond the runtime is off by default and absent
/// in JavaScript until granted here: `console` with [onConsole], timers with
/// [timers], `fetch` with [network], the global `fs` and file modules with
/// [fileSystem].
final class JsRuntimeOptions {
  /// Creates options.
  ///
  /// - [memoryLimit] the bytes the runtime may allocate; null for no limit
  /// - [maxStackSize] the bytes of native stack that JavaScript may use
  /// - [gcThreshold] the bytes after which the garbage collector runs; null
  ///   for the default of QuickJS-ng
  /// - [timeout] the time that one call into JavaScript may take, its
  ///   pending jobs included; null for no limit
  /// - [onConsole] receives `console` output; the `console` object exists
  ///   only with it
  /// - [onUnhandledRejection] receives the reasons of unhandled rejections
  ///   and the errors of timer callbacks
  /// - [timers] whether `setTimeout`, `setInterval`, `clearTimeout` and
  ///   `clearInterval` exist
  /// - [network] the hosts that `fetch` may reach; `fetch` exists only with
  ///   it
  /// - [fileSystem] the folders that `fs` and `import` may read and write;
  ///   `fs` exists only with it
  /// - [moduleLoader] loads the modules that are not registered
  const JsRuntimeOptions({
    this.memoryLimit,
    this.maxStackSize = defaultMaxStackSize,
    this.gcThreshold,
    this.timeout,
    this.onConsole,
    this.onUnhandledRejection,
    this.timers = false,
    this.network,
    this.fileSystem,
    this.moduleLoader,
  });

  /// Creates example options for tests and docs: 32 MB of memory and one
  /// second per call.
  factory JsRuntimeOptions.example({
    int? memoryLimit,
    Duration? timeout,
    JsConsoleHandler? onConsole,
  }) => JsRuntimeOptions(
    memoryLimit: memoryLimit ?? 32 * 1024 * 1024,
    timeout: timeout ?? const Duration(seconds: 1),
    onConsole: onConsole,
  );

  // ...........................................................................
  /// Returns a copy with the given values replaced.
  JsRuntimeOptions copyWith({
    int? memoryLimit,
    int? maxStackSize,
    int? gcThreshold,
    Duration? timeout,
    JsConsoleHandler? onConsole,
    JsRejectionHandler? onUnhandledRejection,
    bool? timers,
    JsNetworkAccess? network,
    JsFileSystemAccess? fileSystem,
    JsModuleLoader? moduleLoader,
  }) => JsRuntimeOptions(
    memoryLimit: memoryLimit ?? this.memoryLimit,
    maxStackSize: maxStackSize ?? this.maxStackSize,
    gcThreshold: gcThreshold ?? this.gcThreshold,
    timeout: timeout ?? this.timeout,
    onConsole: onConsole ?? this.onConsole,
    onUnhandledRejection: onUnhandledRejection ?? this.onUnhandledRejection,
    timers: timers ?? this.timers,
    network: network ?? this.network,
    fileSystem: fileSystem ?? this.fileSystem,
    moduleLoader: moduleLoader ?? this.moduleLoader,
  );

  // ...........................................................................
  /// The bytes the runtime may allocate; null for no limit.
  final int? memoryLimit;

  /// The bytes of native stack that JavaScript may use, counted from the
  /// call into JavaScript.
  ///
  /// The thread of a Dart isolate has a native stack of about 1 MiB on
  /// 64-bit platforms and less on 32-bit ones; a limit beyond 512 KiB may
  /// overrun it and crash the process instead of throwing a
  /// [JsStackOverflowError].
  final int maxStackSize;

  /// The bytes after which the garbage collector runs; null for the default
  /// of QuickJS-ng.
  final int? gcThreshold;

  /// The time that one call into JavaScript may take, its pending jobs
  /// included; null for no limit.
  final Duration? timeout;

  /// Receives `console` output; without it, `console` does not exist.
  final JsConsoleHandler? onConsole;

  /// Receives the reasons of unhandled rejections and the errors of timer
  /// callbacks; without it, they are dropped.
  final JsRejectionHandler? onUnhandledRejection;

  /// Whether the timer functions exist.
  final bool timers;

  /// The network that `fetch` may reach; without it, `fetch` does not exist.
  final JsNetworkAccess? network;

  /// The folders that `fs` and `import` may read and write; without it, `fs`
  /// does not exist and `import` loads no file.
  final JsFileSystemAccess? fileSystem;

  /// Loads the modules that are not registered; null for none.
  final JsModuleLoader? moduleLoader;

  // ...........................................................................
  /// The default of [maxStackSize]: 256 KiB, which the native stack of a
  /// Dart isolate holds on every platform, about 250 nested JavaScript
  /// calls.
  static const int defaultMaxStackSize = 256 * 1024;
}
