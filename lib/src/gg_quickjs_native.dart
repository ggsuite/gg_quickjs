// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:ffi';

import 'package:meta/meta.dart';

// The native entry points of src/gg_quickjs.h. The library is the asset
// `package:gg_quickjs/src/gg_quickjs_native.dart` that hook/build.dart
// builds; hook/link.dart keeps it in an app that calls [openNativeRuntime]
// or [interruptNativeRuntime].

// #############################################################################
/// A buffer that crosses the bridge, `GgQjsBytes`.
final class GgQjsBytes extends Struct {
  /// The first byte.
  external Pointer<Uint8> data;

  /// The number of bytes.
  @Size()
  external int length;
}

// #############################################################################
/// A native runtime, `GgQjsRuntime`.
final class GgQjsRuntime extends Opaque {}

/// `GgQjsHostCall`.
typedef GgQjsHostCallNative = Int32 Function(
  Int64 id,
  Pointer<Uint8> args,
  Size length,
  Pointer<GgQjsBytes> result,
);

/// `GgQjsHostRelease`.
typedef GgQjsHostReleaseNative = Void Function(Int64 id);

/// `GgQjsModuleLoad`.
typedef GgQjsModuleLoadNative = Int32 Function(
  Pointer<Char> name,
  Pointer<GgQjsBytes> source,
);

/// `GgQjsRejection`.
typedef GgQjsRejectionNative = Void Function(
  Pointer<Uint8> reason,
  Size length,
);

// .............................................................................
/// Creates a native runtime, `gg_qjs_new`; recorded, so that the link hook
/// keeps the native library of an app that runs JavaScript.
@RecordUse()
Pointer<GgQjsRuntime> openNativeRuntime({
  required int memoryLimit,
  required int maxStackSize,
  required int gcThreshold,
  required int timeoutMicroseconds,
  required Pointer<NativeFunction<GgQjsHostCallNative>> hostCall,
  required Pointer<NativeFunction<GgQjsHostReleaseNative>> hostRelease,
  required Pointer<NativeFunction<GgQjsModuleLoadNative>> moduleLoad,
  required Pointer<NativeFunction<GgQjsRejectionNative>> rejection,
}) => ggQjsNew(
  memoryLimit,
  maxStackSize,
  gcThreshold,
  timeoutMicroseconds,
  hostCall,
  hostRelease,
  moduleLoad,
  rejection,
);

/// Interrupts the JavaScript that the native runtime at [address] runs now,
/// `gg_qjs_interrupt`; callable from any isolate. Recorded like
/// [openNativeRuntime].
@RecordUse()
void interruptNativeRuntime(int address) =>
    ggQjsInterrupt(Pointer<GgQjsRuntime>.fromAddress(address));

/// Interrupts all JavaScript of the native runtime at [address] from now
/// on, before its disposal, `gg_qjs_close`; callable from any isolate.
void closeNativeRuntime(int address) =>
    ggQjsClose(Pointer<GgQjsRuntime>.fromAddress(address));

// .............................................................................
/// `gg_qjs_version`.
@Native<Pointer<Char> Function()>(symbol: 'gg_qjs_version')
external Pointer<Char> ggQjsVersion();

/// `gg_qjs_malloc`.
@Native<Pointer<Void> Function(Size)>(symbol: 'gg_qjs_malloc', isLeaf: true)
external Pointer<Void> ggQjsMalloc(int size);

/// `gg_qjs_free`.
@Native<Void Function(Pointer<Void>)>(symbol: 'gg_qjs_free', isLeaf: true)
external void ggQjsFree(Pointer<Void> block);

/// `gg_qjs_new`.
@Native<
  Pointer<GgQjsRuntime> Function(
    Int64,
    Int64,
    Int64,
    Int64,
    Pointer<NativeFunction<GgQjsHostCallNative>>,
    Pointer<NativeFunction<GgQjsHostReleaseNative>>,
    Pointer<NativeFunction<GgQjsModuleLoadNative>>,
    Pointer<NativeFunction<GgQjsRejectionNative>>,
  )
>(symbol: 'gg_qjs_new')
external Pointer<GgQjsRuntime> ggQjsNew(
  int memoryLimit,
  int maxStackSize,
  int gcThreshold,
  int timeoutMicroseconds,
  Pointer<NativeFunction<GgQjsHostCallNative>> hostCall,
  Pointer<NativeFunction<GgQjsHostReleaseNative>> hostRelease,
  Pointer<NativeFunction<GgQjsModuleLoadNative>> moduleLoad,
  Pointer<NativeFunction<GgQjsRejectionNative>> rejection,
);

/// `gg_qjs_dispose`.
@Native<Void Function(Pointer<GgQjsRuntime>)>(symbol: 'gg_qjs_dispose')
external void ggQjsDispose(Pointer<GgQjsRuntime> runtime);

/// `gg_qjs_interrupt`.
@Native<Void Function(Pointer<GgQjsRuntime>)>(
  symbol: 'gg_qjs_interrupt',
  isLeaf: true,
)
external void ggQjsInterrupt(Pointer<GgQjsRuntime> runtime);

/// `gg_qjs_close`.
@Native<Void Function(Pointer<GgQjsRuntime>)>(
  symbol: 'gg_qjs_close',
  isLeaf: true,
)
external void ggQjsClose(Pointer<GgQjsRuntime> runtime);

/// `gg_qjs_eval`.
@Native<
  Int32 Function(
    Pointer<GgQjsRuntime>,
    Pointer<Char>,
    Size,
    Pointer<Char>,
    Int32,
    Pointer<GgQjsBytes>,
  )
>(symbol: 'gg_qjs_eval')
external int ggQjsEval(
  Pointer<GgQjsRuntime> runtime,
  Pointer<Char> code,
  int length,
  Pointer<Char> filename,
  int mode,
  Pointer<GgQjsBytes> result,
);

/// `gg_qjs_eval_module`.
@Native<
  Int32 Function(
    Pointer<GgQjsRuntime>,
    Pointer<Char>,
    Size,
    Pointer<Char>,
    Pointer<GgQjsBytes>,
  )
>(symbol: 'gg_qjs_eval_module')
external int ggQjsEvalModule(
  Pointer<GgQjsRuntime> runtime,
  Pointer<Char> code,
  int length,
  Pointer<Char> filename,
  Pointer<GgQjsBytes> result,
);

/// `gg_qjs_compile`.
@Native<
  Int32 Function(
    Pointer<GgQjsRuntime>,
    Pointer<Char>,
    Size,
    Pointer<Char>,
    Int32,
    Pointer<GgQjsBytes>,
  )
>(symbol: 'gg_qjs_compile')
external int ggQjsCompile(
  Pointer<GgQjsRuntime> runtime,
  Pointer<Char> code,
  int length,
  Pointer<Char> filename,
  int module,
  Pointer<GgQjsBytes> result,
);

/// `gg_qjs_eval_bytecode`.
@Native<
  Int32 Function(
    Pointer<GgQjsRuntime>,
    Pointer<Uint8>,
    Size,
    Int32,
    Pointer<GgQjsBytes>,
  )
>(symbol: 'gg_qjs_eval_bytecode')
external int ggQjsEvalBytecode(
  Pointer<GgQjsRuntime> runtime,
  Pointer<Uint8> bytecode,
  int length,
  int mode,
  Pointer<GgQjsBytes> result,
);

/// `gg_qjs_call`.
@Native<
  Int32 Function(
    Pointer<GgQjsRuntime>,
    Uint64,
    Uint64,
    Pointer<Uint8>,
    Size,
    Int32,
    Pointer<GgQjsBytes>,
  )
>(symbol: 'gg_qjs_call')
external int ggQjsCall(
  Pointer<GgQjsRuntime> runtime,
  int function,
  int self,
  Pointer<Uint8> args,
  int length,
  int mode,
  Pointer<GgQjsBytes> result,
);

/// `gg_qjs_get`.
@Native<
  Int32 Function(
    Pointer<GgQjsRuntime>,
    Uint64,
    Pointer<Uint8>,
    Size,
    Int32,
    Pointer<GgQjsBytes>,
  )
>(symbol: 'gg_qjs_get')
external int ggQjsGet(
  Pointer<GgQjsRuntime> runtime,
  int object,
  Pointer<Uint8> key,
  int keyLength,
  int mode,
  Pointer<GgQjsBytes> result,
);

/// `gg_qjs_set`.
@Native<
  Int32 Function(
    Pointer<GgQjsRuntime>,
    Uint64,
    Pointer<Uint8>,
    Size,
    Pointer<Uint8>,
    Size,
    Pointer<GgQjsBytes>,
  )
>(symbol: 'gg_qjs_set')
external int ggQjsSet(
  Pointer<GgQjsRuntime> runtime,
  int object,
  Pointer<Uint8> key,
  int keyLength,
  Pointer<Uint8> value,
  int valueLength,
  Pointer<GgQjsBytes> result,
);

/// `gg_qjs_delete`.
@Native<
  Int32 Function(
    Pointer<GgQjsRuntime>,
    Uint64,
    Pointer<Uint8>,
    Size,
    Pointer<GgQjsBytes>,
  )
>(symbol: 'gg_qjs_delete')
external int ggQjsDelete(
  Pointer<GgQjsRuntime> runtime,
  int object,
  Pointer<Uint8> key,
  int keyLength,
  Pointer<GgQjsBytes> result,
);

/// `gg_qjs_keys`.
@Native<Int32 Function(Pointer<GgQjsRuntime>, Uint64, Pointer<GgQjsBytes>)>(
  symbol: 'gg_qjs_keys',
)
external int ggQjsKeys(
  Pointer<GgQjsRuntime> runtime,
  int object,
  Pointer<GgQjsBytes> result,
);

/// `gg_qjs_to_value`.
@Native<Int32 Function(Pointer<GgQjsRuntime>, Uint64, Pointer<GgQjsBytes>)>(
  symbol: 'gg_qjs_to_value',
)
external int ggQjsToValue(
  Pointer<GgQjsRuntime> runtime,
  int handle,
  Pointer<GgQjsBytes> result,
);

/// `gg_qjs_free_handle`.
@Native<Void Function(Pointer<GgQjsRuntime>, Uint64)>(
  symbol: 'gg_qjs_free_handle',
)
external void ggQjsFreeHandle(Pointer<GgQjsRuntime> runtime, int handle);

/// `gg_qjs_new_promise`.
@Native<Int32 Function(Pointer<GgQjsRuntime>, Pointer<GgQjsBytes>)>(
  symbol: 'gg_qjs_new_promise',
)
external int ggQjsNewPromise(
  Pointer<GgQjsRuntime> runtime,
  Pointer<GgQjsBytes> result,
);

/// `gg_qjs_run_jobs`.
@Native<Int32 Function(Pointer<GgQjsRuntime>, Pointer<GgQjsBytes>)>(
  symbol: 'gg_qjs_run_jobs',
)
external int ggQjsRunJobs(
  Pointer<GgQjsRuntime> runtime,
  Pointer<GgQjsBytes> result,
);

/// `gg_qjs_memory_usage`.
@Native<Void Function(Pointer<GgQjsRuntime>, Pointer<Int64>)>(
  symbol: 'gg_qjs_memory_usage',
)
external void ggQjsMemoryUsage(
  Pointer<GgQjsRuntime> runtime,
  Pointer<Int64> fields,
);

/// `gg_qjs_run_gc`.
@Native<Void Function(Pointer<GgQjsRuntime>)>(symbol: 'gg_qjs_run_gc')
external void ggQjsRunGc(Pointer<GgQjsRuntime> runtime);
