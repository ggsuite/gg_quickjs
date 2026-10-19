// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// A native library of another package that links the static QuickJS-ng
// library of QuickjsNgBuild, for test/quickjs_ng_build_test.dart.

#include <string.h>

#include "quickjs.h"

#if defined(_WIN32)
#define CONSUMER_EXPORT __declspec(dllexport)
#else
#define CONSUMER_EXPORT __attribute__((visibility("default")))
#endif

// Evaluates  and returns its result as an integer, -1 on an error.
CONSUMER_EXPORT int consumer_eval(const char* code) {
  JSRuntime* runtime = JS_NewRuntime();
  JSContext* context = JS_NewContext(runtime);
  JSValue value =
      JS_Eval(context, code, strlen(code), "<consumer>", JS_EVAL_TYPE_GLOBAL);
  int result = -1;
  if (!JS_IsException(value)) JS_ToInt32(context, &result, value);
  JS_FreeValue(context, value);
  JS_FreeContext(context);
  JS_FreeRuntime(runtime);
  return result;
}
