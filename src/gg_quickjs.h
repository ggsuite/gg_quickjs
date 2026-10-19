// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The C bridge between the Dart binding of gg_quickjs and QuickJS-ng: one
// runtime with one context per GgQjsRuntime. Values cross the bridge in a
// compact encoding (see the GG_QJS_TAG_* constants and
// lib/src/js_value_codec.dart); objects that stay in JavaScript cross as
// handles, boxes of a JSValue that the bridge owns until Dart frees them.
//
// Every entry point that runs JavaScript updates the stack top on its
// outermost call, sets the deadline of the time budget, runs the pending
// jobs when it returns to Dart and reports unhandled rejections. The
// conversion of a value to Dart keeps to the time budget and to four times
// the memory limit. Only gg_qjs_interrupt and gg_qjs_close may be called
// from another thread.

#ifndef GG_QUICKJS_H
#define GG_QUICKJS_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define GG_QJS_EXPORT __declspec(dllexport)
#else
#define GG_QJS_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// The tags of the value encoding.
#define GG_QJS_TAG_UNDEFINED 0
#define GG_QJS_TAG_NULL 1
#define GG_QJS_TAG_FALSE 2
#define GG_QJS_TAG_TRUE 3
#define GG_QJS_TAG_INT32 4
#define GG_QJS_TAG_FLOAT64 5
#define GG_QJS_TAG_STRING 6
#define GG_QJS_TAG_BIGINT 7
#define GG_QJS_TAG_ARRAY 8
#define GG_QJS_TAG_OBJECT 9
#define GG_QJS_TAG_DATE 10
#define GG_QJS_TAG_BYTES 11
#define GG_QJS_TAG_ERROR 12
#define GG_QJS_TAG_HANDLE 13
#define GG_QJS_TAG_MAP 14
#define GG_QJS_TAG_SET 15
#define GG_QJS_TAG_HOST_FUNCTION 16

// The status of an entry point.
#define GG_QJS_OK 0
#define GG_QJS_EXCEPTION 1

// How an entry point returns its JavaScript result.
#define GG_QJS_CONVERT 0
#define GG_QJS_HANDLE 1

// A buffer that the bridge allocates with gg_qjs_malloc and the receiver
// frees with gg_qjs_free.
typedef struct GgQjsBytes {
  uint8_t* data;
  size_t length;
} GgQjsBytes;

typedef struct GgQjsRuntime GgQjsRuntime;

// Calls the host function `id` with the encoded array `args`; writes the
// encoded result (GG_QJS_OK) or the encoded value to throw
// (GG_QJS_EXCEPTION) into `result`.
typedef int32_t (*GgQjsHostCall)(int64_t id, const uint8_t* args,
                                 size_t length, GgQjsBytes* result);

// Tells that JavaScript no longer references the host function `id`.
typedef void (*GgQjsHostRelease)(int64_t id);

// Writes the source of the module `name` into `source`: GG_QJS_OK, 1 when
// the module is unknown, 2 with a message in `source` when it is refused.
typedef int32_t (*GgQjsModuleLoad)(const char* name, GgQjsBytes* source);

// Receives the encoded reason of an unhandled rejection.
typedef void (*GgQjsRejection)(const uint8_t* reason, size_t length);

// The version of QuickJS-ng, e.g. "0.17.0".
GG_QJS_EXPORT const char* gg_qjs_version(void);

// The allocator of the buffers that cross the bridge.
GG_QJS_EXPORT void* gg_qjs_malloc(size_t size);
GG_QJS_EXPORT void gg_qjs_free(void* block);

// Creates a runtime; 0 disables a limit. NULL when the memory limit is too
// low for the runtime itself.
GG_QJS_EXPORT GgQjsRuntime* gg_qjs_new(int64_t memory_limit,
                                       int64_t max_stack_size,
                                       int64_t gc_threshold,
                                       int64_t timeout_us,
                                       GgQjsHostCall host_call,
                                       GgQjsHostRelease host_release,
                                       GgQjsModuleLoad module_load,
                                       GgQjsRejection rejection);

// Frees the runtime with every handle; no call may run at that time.
GG_QJS_EXPORT void gg_qjs_dispose(GgQjsRuntime* runtime);

// Interrupts the JavaScript that runs now; callable from any thread.
GG_QJS_EXPORT void gg_qjs_interrupt(GgQjsRuntime* runtime);

// Interrupts all JavaScript from now on, so that a runtime that is about
// to be disposed returns quickly; callable from any thread.
GG_QJS_EXPORT void gg_qjs_close(GgQjsRuntime* runtime);

// Evaluates a script; `code` ends with a zero byte after `length` bytes.
GG_QJS_EXPORT int32_t gg_qjs_eval(GgQjsRuntime* runtime, const char* code,
                                  size_t length, const char* filename,
                                  int32_t mode, GgQjsBytes* result);

// Evaluates a module; the result is an array of the handles of the
// evaluation promise and of the module namespace.
GG_QJS_EXPORT int32_t gg_qjs_eval_module(GgQjsRuntime* runtime,
                                         const char* code, size_t length,
                                         const char* filename,
                                         GgQjsBytes* result);

// Compiles a script or a module into bytecode, returned raw.
GG_QJS_EXPORT int32_t gg_qjs_compile(GgQjsRuntime* runtime, const char* code,
                                     size_t length, const char* filename,
                                     int32_t module, GgQjsBytes* result);

// Evaluates bytecode; the result is an array [is module, result or
// promise handle, namespace handle or undefined].
GG_QJS_EXPORT int32_t gg_qjs_eval_bytecode(GgQjsRuntime* runtime,
                                           const uint8_t* bytecode,
                                           size_t length, int32_t mode,
                                           GgQjsBytes* result);

// Calls the function handle `function` with `self` (0: undefined) and the
// encoded array `args`.
GG_QJS_EXPORT int32_t gg_qjs_call(GgQjsRuntime* runtime, uint64_t function,
                                  uint64_t self, const uint8_t* args,
                                  size_t length, int32_t mode,
                                  GgQjsBytes* result);

// Reads the property with the encoded `key` of the handle `object`
// (0: the global object).
GG_QJS_EXPORT int32_t gg_qjs_get(GgQjsRuntime* runtime, uint64_t object,
                                 const uint8_t* key, size_t key_length,
                                 int32_t mode, GgQjsBytes* result);

// Writes the encoded `value` to the property `key` of `object`.
GG_QJS_EXPORT int32_t gg_qjs_set(GgQjsRuntime* runtime, uint64_t object,
                                 const uint8_t* key, size_t key_length,
                                 const uint8_t* value, size_t value_length,
                                 GgQjsBytes* result);

// Deletes the property `key` of `object`.
GG_QJS_EXPORT int32_t gg_qjs_delete(GgQjsRuntime* runtime, uint64_t object,
                                    const uint8_t* key, size_t key_length,
                                    GgQjsBytes* result);

// The own enumerable string keys of `object` as an encoded array.
GG_QJS_EXPORT int32_t gg_qjs_keys(GgQjsRuntime* runtime, uint64_t object,
                                  GgQjsBytes* result);

// Converts the value of a handle.
GG_QJS_EXPORT int32_t gg_qjs_to_value(GgQjsRuntime* runtime, uint64_t handle,
                                      GgQjsBytes* result);

// Frees a handle. A running call holds its function, `this` and the value
// it converts, but an encoded value must not name a freed handle, so the
// Dart binding frees the handles of a call once it returns.
GG_QJS_EXPORT void gg_qjs_free_handle(GgQjsRuntime* runtime, uint64_t handle);

// Creates a promise; the result is an array of the handles of the promise
// and of its resolve and reject functions.
GG_QJS_EXPORT int32_t gg_qjs_new_promise(GgQjsRuntime* runtime,
                                         GgQjsBytes* result);

// Runs the pending jobs.
GG_QJS_EXPORT int32_t gg_qjs_run_jobs(GgQjsRuntime* runtime,
                                      GgQjsBytes* result);

// Writes the memory usage: allocated bytes, allocations, the limit, used
// bytes, objects, strings and functions.
GG_QJS_EXPORT void gg_qjs_memory_usage(GgQjsRuntime* runtime,
                                       int64_t* fields);

// Runs the garbage collector.
GG_QJS_EXPORT void gg_qjs_run_gc(GgQjsRuntime* runtime);

#ifdef __cplusplus
}
#endif

#endif  // GG_QUICKJS_H
