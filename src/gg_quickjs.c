// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The C bridge of the Dart binding; see gg_quickjs.h.

#include "gg_quickjs.h"

#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <malloc.h>
#include <windows.h>
#elif defined(__APPLE__)
#include <malloc/malloc.h>
#include <time.h>
#else
#include <malloc.h>
#include <time.h>
#endif

#include "quickjs.h"

// ############################################################################
// Constants

// The deepest nesting of arrays and objects that a conversion follows.
#define GG_QJS_MAX_DEPTH 256

// A conversion checks the time budget and the interrupt after this many
// values.
#define GG_QJS_POLL_INTERVAL 1024

// The encoding of a value may take this many times the memory limit. Only
// references make an encoding larger than the value, e.g. a sparse array or
// one object referenced again and again.
#define GG_QJS_ENCODING_FACTOR 4

// The kinds of GG_QJS_TAG_HANDLE.
#define GG_QJS_HANDLE_OTHER 0
#define GG_QJS_HANDLE_OBJECT 1
#define GG_QJS_HANDLE_FUNCTION 2
#define GG_QJS_HANDLE_PROMISE 3
#define GG_QJS_HANDLE_ARRAY_BUFFER 4

// The kinds of GG_QJS_TAG_BYTES: an ArrayBuffer, then the typed arrays.
#define GG_QJS_BYTES_ARRAY_BUFFER 0
#define GG_QJS_BYTES_UINT8 1
#define GG_QJS_BYTES_INT8 2
#define GG_QJS_BYTES_UINT8_CLAMPED 3
#define GG_QJS_BYTES_INT16 4
#define GG_QJS_BYTES_UINT16 5
#define GG_QJS_BYTES_INT32 6
#define GG_QJS_BYTES_UINT32 7
#define GG_QJS_BYTES_FLOAT32 8
#define GG_QJS_BYTES_FLOAT64 9
#define GG_QJS_BYTES_BIG_INT64 10
#define GG_QJS_BYTES_BIG_UINT64 11

// Why an entry point failed, the first byte of an exception result.
#define GG_QJS_THROWN 0
#define GG_QJS_INTERRUPTED 1
#define GG_QJS_TIMED_OUT 2
#define GG_QJS_OUT_OF_MEMORY 3

// The helpers the bridge creates before any script runs, so that no script
// can replace them.
static const char kHelpers[] =
    "(() => {\n"
    "  const from = Array.from;\n"
    "  const MapClass = Map;\n"
    "  const SetClass = Set;\n"
    "  const toBigInt = BigInt;\n"
    "  const errors = { Error, EvalError, InternalError, RangeError,\n"
    "    ReferenceError, SyntaxError, TypeError, URIError };\n"
    "  const has = Object.prototype.hasOwnProperty;\n"
    "  return [\n"
    "    (value) => from(value),\n"
    "    (entries) => new MapClass(entries),\n"
    "    (values) => new SetClass(values),\n"
    "    (text) => toBigInt(text),\n"
    "    (name, message) => {\n"
    "      const Type = has.call(errors, name) ? errors[name] : Error;\n"
    "      const error = new Type(message);\n"
    "      if (Type === Error && name !== 'Error') error.name = name;\n"
    "      return error;\n"
    "    },\n"
    "  ];\n"
    "})()";

#define GG_QJS_HELPER_ARRAY_FROM 0
#define GG_QJS_HELPER_NEW_MAP 1
#define GG_QJS_HELPER_NEW_SET 2
#define GG_QJS_HELPER_BIGINT 3
#define GG_QJS_HELPER_ERROR 4
#define GG_QJS_HELPER_COUNT 5

// The longest timeout, a century in microseconds.
static const int64_t kMaxTimeoutUs = INT64_C(100) * 365 * 24 * 3600 * 1000000;

// ############################################################################
// Types

// A JSValue that Dart holds.
typedef struct GgQjsBox {
  JSValue value;
  struct GgQjsBox* prev;
  struct GgQjsBox* next;
} GgQjsBox;

// A rejected promise without a handler yet.
typedef struct GgQjsRejected {
  JSValue promise;
  JSValue reason;
  struct GgQjsRejected* next;
} GgQjsRejected;

// The id of a host function; finalized with the function.
typedef struct GgQjsToken {
  int64_t id;
} GgQjsToken;

struct GgQjsRuntime {
  JSRuntime* rt;
  JSContext* ctx;
  JSClassID token_class;
  // The allocator enforces the memory limit, so that it knows when a
  // script ran out of memory: QuickJS-ng then throws null when it has no
  // memory left for an error object.
  size_t memory_limit;
  size_t allocated;
  bool out_of_memory;
  // Lifts the limit: QuickJS-ng 0.17.0 does not recover from running out
  // of memory while it parses, so the code that Dart passes compiles
  // without the limit, and an error is described without it.
  bool unlimited;
  int64_t timeout_ns;
  int64_t deadline_ns;
  int depth;
  bool interrupted;
  bool timed_out;
  bool describing;
  atomic_int interrupt_requested;
  atomic_int closing;
  GgQjsBox* boxes;
  GgQjsRejected* rejected;
  JSValue helpers[GG_QJS_HELPER_COUNT];
  GgQjsHostCall host_call;
  GgQjsHostRelease host_release;
  GgQjsModuleLoad module_load;
  GgQjsRejection rejection;
};

// A growing buffer of an encoded value.
typedef struct GgQjsBuffer {
  uint8_t* data;
  size_t length;
  size_t capacity;
  bool failed;
  // The largest length; 0 for none.
  size_t limit;
} GgQjsBuffer;

// The state of an encoding: the objects on the way down, to find cycles.
typedef struct GgQjsEncoder {
  GgQjsRuntime* r;
  GgQjsBuffer buffer;
  void* path[GG_QJS_MAX_DEPTH];
  int depth;
  uint32_t count;
} GgQjsEncoder;

// A cursor in an encoded value.
typedef struct GgQjsReader {
  const uint8_t* data;
  size_t length;
  size_t position;
} GgQjsReader;

// ############################################################################
// Time

static int64_t now_ns(void) {
#if defined(_WIN32)
  LARGE_INTEGER frequency;
  LARGE_INTEGER counter;
  QueryPerformanceFrequency(&frequency);
  QueryPerformanceCounter(&counter);
  const int64_t seconds = counter.QuadPart / frequency.QuadPart;
  const int64_t rest = counter.QuadPart % frequency.QuadPart;
  return seconds * 1000000000 + rest * 1000000000 / frequency.QuadPart;
#else
  struct timespec time;
  clock_gettime(CLOCK_MONOTONIC, &time);
  return (int64_t)time.tv_sec * 1000000000 + time.tv_nsec;
#endif
}

// ############################################################################
// The allocator

static size_t usable_size(const void* block) {
#if defined(_WIN32)
  return _msize((void*)block);
#elif defined(__APPLE__)
  return malloc_size(block);
#else
  return malloc_usable_size((void*)block);
#endif
}

// Whether `size` more bytes fit the limit; notes when they do not.
static bool fits(GgQjsRuntime* r, size_t size) {
  if (r->memory_limit == 0 || r->unlimited ||
      r->allocated + size <= r->memory_limit) {
    return true;
  }
  r->out_of_memory = true;
  return false;
}

static void* heap_malloc(void* opaque, size_t size) {
  GgQjsRuntime* r = (GgQjsRuntime*)opaque;
  if (!fits(r, size)) return NULL;
  void* block = malloc(size);
  if (block != NULL) r->allocated += usable_size(block);
  return block;
}

static void* heap_calloc(void* opaque, size_t count, size_t size) {
  GgQjsRuntime* r = (GgQjsRuntime*)opaque;
  if (size != 0 && count > SIZE_MAX / size) return NULL;
  if (!fits(r, count * size)) return NULL;
  void* block = calloc(count, size);
  if (block != NULL) r->allocated += usable_size(block);
  return block;
}

static void heap_free(void* opaque, void* block) {
  if (block == NULL) return;
  ((GgQjsRuntime*)opaque)->allocated -= usable_size(block);
  free(block);
}

static void* heap_realloc(void* opaque, void* block, size_t size) {
  GgQjsRuntime* r = (GgQjsRuntime*)opaque;
  if (block == NULL) return heap_malloc(opaque, size);
  if (size == 0) {
    heap_free(opaque, block);
    return NULL;
  }
  const size_t old = usable_size(block);
  if (size > old && !fits(r, size - old)) return NULL;
  void* moved = realloc(block, size);
  if (moved != NULL) r->allocated = r->allocated - old + usable_size(moved);
  return moved;
}

static size_t heap_usable_size(const void* block) {
  return block != NULL ? usable_size(block) : 0;
}

static const JSMallocFunctions kHeap = {heap_calloc, heap_malloc, heap_free,
                                        heap_realloc, heap_usable_size};

// ############################################################################
// Buffers

static bool buffer_reserve(GgQjsBuffer* b, size_t extra) {
  if (b->failed) return false;
  if (b->limit != 0 && (extra > b->limit || b->length > b->limit - extra)) {
    b->failed = true;
    return false;
  }
  if (b->length + extra <= b->capacity) return true;
  size_t capacity = b->capacity == 0 ? 256 : b->capacity;
  while (capacity < b->length + extra) capacity *= 2;
  uint8_t* data = (uint8_t*)realloc(b->data, capacity);
  if (data == NULL) {
    b->failed = true;
    return false;
  }
  b->data = data;
  b->capacity = capacity;
  return true;
}

static void buffer_raw(GgQjsBuffer* b, const void* data, size_t length) {
  if (!buffer_reserve(b, length)) return;
  if (length > 0) memcpy(b->data + b->length, data, length);
  b->length += length;
}

static void buffer_u8(GgQjsBuffer* b, uint8_t value) {
  buffer_raw(b, &value, 1);
}

static void buffer_u32(GgQjsBuffer* b, uint32_t value) {
  buffer_raw(b, &value, 4);
}

static void buffer_u64(GgQjsBuffer* b, uint64_t value) {
  buffer_raw(b, &value, 8);
}

static void buffer_f64(GgQjsBuffer* b, double value) {
  buffer_raw(b, &value, 8);
}

static void buffer_string(GgQjsBuffer* b, const char* text, size_t length) {
  buffer_u32(b, (uint32_t)length);
  buffer_raw(b, text, length);
}

static void buffer_free(GgQjsBuffer* b) {
  free(b->data);
  b->data = NULL;
  b->length = 0;
  b->capacity = 0;
}

// Hands the buffer to the receiver as GgQjsBytes.
static void buffer_take(GgQjsBuffer* b, GgQjsBytes* out) {
  out->data = b->data;
  out->length = b->length;
  b->data = NULL;
  b->length = 0;
  b->capacity = 0;
}

// ############################################################################
// Readers

static bool read_raw(GgQjsReader* r, size_t length, const uint8_t** out) {
  if (r->length - r->position < length) return false;
  *out = r->data + r->position;
  r->position += length;
  return true;
}

static bool read_u8(GgQjsReader* r, uint8_t* out) {
  const uint8_t* data;
  if (!read_raw(r, 1, &data)) return false;
  *out = data[0];
  return true;
}

static bool read_u32(GgQjsReader* r, uint32_t* out) {
  const uint8_t* data;
  if (!read_raw(r, 4, &data)) return false;
  memcpy(out, data, 4);
  return true;
}

static bool read_u64(GgQjsReader* r, uint64_t* out) {
  const uint8_t* data;
  if (!read_raw(r, 8, &data)) return false;
  memcpy(out, data, 8);
  return true;
}

static bool read_f64(GgQjsReader* r, double* out) {
  const uint8_t* data;
  if (!read_raw(r, 8, &data)) return false;
  memcpy(out, data, 8);
  return true;
}

static bool read_string(GgQjsReader* r, const char** text, size_t* length) {
  uint32_t size;
  const uint8_t* data;
  if (!read_u32(r, &size) || !read_raw(r, size, &data)) return false;
  *text = (const char*)data;
  *length = size;
  return true;
}

// ############################################################################
// Handles

static GgQjsBox* box_new(GgQjsRuntime* r, JSValue value) {
  GgQjsBox* box = (GgQjsBox*)malloc(sizeof(GgQjsBox));
  if (box == NULL) {
    JS_FreeValue(r->ctx, value);
    return NULL;
  }
  box->value = value;
  box->prev = NULL;
  box->next = r->boxes;
  if (r->boxes != NULL) r->boxes->prev = box;
  r->boxes = box;
  return box;
}

static void box_free(GgQjsRuntime* r, GgQjsBox* box) {
  if (box->prev != NULL) box->prev->next = box->next;
  if (box->next != NULL) box->next->prev = box->prev;
  if (r->boxes == box) r->boxes = box->next;
  JS_FreeValueRT(r->rt, box->value);
  free(box);
}

static JSValue box_value(uint64_t handle) {
  return ((GgQjsBox*)(uintptr_t)handle)->value;
}

// ############################################################################
// Encoding

static int encode_value(GgQjsEncoder* e, JSValueConst value);
static int interrupt_handler(JSRuntime* rt, void* opaque);

// Throws the uncatchable error of an interrupted script.
static void throw_interrupted(JSContext* ctx) {
  JS_ThrowInternalError(ctx, "interrupted");
  JSValue error = JS_GetException(ctx);
  JS_SetUncatchableError(ctx, error);
  JS_Throw(ctx, error);
}

// Whether a conversion may go on; throws when it may not. It stops when its
// encoding outgrows the limit of encoder_init and, every
// GG_QJS_POLL_INTERVAL values, at the time budget, an interrupt or the
// closing of the runtime, so that a value of references, e.g. a sparse
// array, stays within the limits of the runtime. The description of an
// error ignores an interrupt, as the interrupt is what it describes.
static bool encoder_continues(GgQjsEncoder* e) {
  GgQjsRuntime* r = e->r;
  if (e->buffer.failed) {
    JS_ThrowOutOfMemory(r->ctx);
    return false;
  }
  if (++e->count % GG_QJS_POLL_INTERVAL != 0) return true;
  bool stop = r->describing
                  ? atomic_load(&r->closing) ||
                        (r->deadline_ns != 0 && now_ns() > r->deadline_ns)
                  : interrupt_handler(r->rt, r) != 0;
  if (stop) throw_interrupted(r->ctx);
  return !stop;
}

// Writes the property `name` of `object` as a string; empty when it is
// missing or cannot be read.
static void encode_string_property(GgQjsEncoder* e, JSValueConst object,
                                   const char* name) {
  JSContext* ctx = e->r->ctx;
  JSValue property = JS_GetPropertyStr(ctx, object, name);
  const char* text = NULL;
  size_t length = 0;
  if (!JS_IsUndefined(property) && !JS_IsException(property)) {
    text = JS_ToCStringLen(ctx, &length, property);
  }
  if (text == NULL) {
    JS_FreeValue(ctx, JS_GetException(ctx));
    length = 0;
  }
  buffer_string(&e->buffer, text != NULL ? text : "", length);
  if (text != NULL) JS_FreeCString(ctx, text);
  JS_FreeValue(ctx, property);
}

static int handle_kind(GgQjsRuntime* r, JSValueConst value) {
  if (!JS_IsObject(value)) return GG_QJS_HANDLE_OTHER;
  if (JS_IsFunction(r->ctx, value)) return GG_QJS_HANDLE_FUNCTION;
  if (JS_IsPromise(value)) return GG_QJS_HANDLE_PROMISE;
  if (JS_IsArrayBuffer(value)) return GG_QJS_HANDLE_ARRAY_BUFFER;
  return GG_QJS_HANDLE_OBJECT;
}

// Writes a handle of `value`; a promise that Dart receives counts as
// handled, Dart reports its rejection.
static int encode_handle(GgQjsEncoder* e, JSValueConst value) {
  GgQjsRuntime* r = e->r;
  int kind = handle_kind(r, value);
  if (kind == GG_QJS_HANDLE_PROMISE) JS_PromiseMarkAsHandled(r->ctx, value);
  GgQjsBox* box = box_new(r, JS_DupValue(r->ctx, value));
  if (box == NULL) {
    JS_ThrowOutOfMemory(r->ctx);
    return -1;
  }
  buffer_u8(&e->buffer, GG_QJS_TAG_HANDLE);
  buffer_u8(&e->buffer, (uint8_t)kind);
  buffer_u64(&e->buffer, (uint64_t)(uintptr_t)box);
  return 0;
}

static int encode_list(GgQjsEncoder* e, uint8_t tag, JSValueConst list) {
  JSContext* ctx = e->r->ctx;
  int64_t length = 0;
  if (JS_GetLength(ctx, list, &length) < 0) return -1;
  buffer_u8(&e->buffer, tag);
  buffer_u32(&e->buffer, (uint32_t)length);
  for (int64_t i = 0; i < length; ++i) {
    JSValue item = JS_GetPropertyUint32(ctx, list, (uint32_t)i);
    if (JS_IsException(item)) return -1;
    int status = encode_value(e, item);
    JS_FreeValue(ctx, item);
    if (status < 0) return -1;
  }
  return 0;
}

// Writes a Map as its entries or a Set as its values, through
// Array.from.
static int encode_collection(GgQjsEncoder* e, uint8_t tag,
                             JSValueConst collection) {
  GgQjsRuntime* r = e->r;
  JSContext* ctx = r->ctx;
  JSValue items = JS_Call(ctx, r->helpers[GG_QJS_HELPER_ARRAY_FROM],
                          JS_UNDEFINED, 1, &collection);
  if (JS_IsException(items)) return -1;
  int status = 0;
  if (tag == GG_QJS_TAG_SET) {
    status = encode_list(e, tag, items);
  } else {
    int64_t length = 0;
    status = JS_GetLength(ctx, items, &length);
    buffer_u8(&e->buffer, tag);
    buffer_u32(&e->buffer, (uint32_t)length);
    for (int64_t i = 0; status == 0 && i < length; ++i) {
      // A script may replace the iterator of Map, so an entry may be
      // anything; a failed read leaves an exception, never a value.
      JSValue entry = JS_GetPropertyUint32(ctx, items, (uint32_t)i);
      JSValue key = JS_IsException(entry)
                        ? JS_EXCEPTION
                        : JS_GetPropertyUint32(ctx, entry, 0);
      JSValue item = JS_IsException(key) ? JS_EXCEPTION
                                         : JS_GetPropertyUint32(ctx, entry, 1);
      status = JS_IsException(item) ? -1 : encode_value(e, key);
      if (status == 0) status = encode_value(e, item);
      JS_FreeValue(ctx, item);
      JS_FreeValue(ctx, key);
      JS_FreeValue(ctx, entry);
    }
  }
  JS_FreeValue(ctx, items);
  return status < 0 ? -1 : 0;
}

static uint8_t bytes_kind(int typed_array_type) {
  switch (typed_array_type) {
    case JS_TYPED_ARRAY_UINT8:
      return GG_QJS_BYTES_UINT8;
    case JS_TYPED_ARRAY_INT8:
      return GG_QJS_BYTES_INT8;
    case JS_TYPED_ARRAY_UINT8C:
      return GG_QJS_BYTES_UINT8_CLAMPED;
    case JS_TYPED_ARRAY_INT16:
      return GG_QJS_BYTES_INT16;
    case JS_TYPED_ARRAY_UINT16:
      return GG_QJS_BYTES_UINT16;
    case JS_TYPED_ARRAY_INT32:
      return GG_QJS_BYTES_INT32;
    case JS_TYPED_ARRAY_UINT32:
      return GG_QJS_BYTES_UINT32;
    case JS_TYPED_ARRAY_FLOAT32:
      return GG_QJS_BYTES_FLOAT32;
    case JS_TYPED_ARRAY_FLOAT64:
      return GG_QJS_BYTES_FLOAT64;
    case JS_TYPED_ARRAY_BIG_INT64:
      return GG_QJS_BYTES_BIG_INT64;
    default:
      return GG_QJS_BYTES_BIG_UINT64;
  }
}

static int encode_typed_array(GgQjsEncoder* e, JSValueConst value,
                              int type) {
  JSContext* ctx = e->r->ctx;
  size_t offset = 0;
  size_t length = 0;
  size_t element_size = 0;
  JSValue buffer =
      JS_GetTypedArrayBuffer(ctx, value, &offset, &length, &element_size);
  if (JS_IsException(buffer)) return -1;
  size_t size = 0;
  uint8_t* data = JS_GetArrayBuffer(ctx, &size, buffer);
  // A detached buffer has no data.
  if (data == NULL) {
    JS_FreeValue(ctx, JS_GetException(ctx));
    length = 0;
  }
  buffer_u8(&e->buffer, GG_QJS_TAG_BYTES);
  buffer_u8(&e->buffer, bytes_kind(type));
  buffer_u32(&e->buffer, (uint32_t)length);
  if (length > 0) buffer_raw(&e->buffer, data + offset, length);
  JS_FreeValue(ctx, buffer);
  return 0;
}

static int encode_array_buffer(GgQjsEncoder* e, JSValueConst value) {
  JSContext* ctx = e->r->ctx;
  size_t size = 0;
  uint8_t* data = JS_GetArrayBuffer(ctx, &size, value);
  if (data == NULL) {
    JS_FreeValue(ctx, JS_GetException(ctx));
    size = 0;
  }
  buffer_u8(&e->buffer, GG_QJS_TAG_BYTES);
  buffer_u8(&e->buffer, GG_QJS_BYTES_ARRAY_BUFFER);
  buffer_u32(&e->buffer, (uint32_t)size);
  if (size > 0) buffer_raw(&e->buffer, data, size);
  return 0;
}

static int encode_plain_object(GgQjsEncoder* e, JSValueConst value) {
  JSContext* ctx = e->r->ctx;
  JSPropertyEnum* properties = NULL;
  uint32_t count = 0;
  if (JS_GetOwnPropertyNames(ctx, &properties, &count, value,
                             JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) < 0) {
    return -1;
  }
  buffer_u8(&e->buffer, GG_QJS_TAG_OBJECT);
  buffer_u32(&e->buffer, count);
  int status = 0;
  for (uint32_t i = 0; status == 0 && i < count; ++i) {
    size_t length = 0;
    const char* key = JS_AtomToCStringLen(ctx, &length, properties[i].atom);
    if (key == NULL) {
      status = -1;
      break;
    }
    buffer_string(&e->buffer, key, length);
    JS_FreeCString(ctx, key);
    JSValue item = JS_GetProperty(ctx, value, properties[i].atom);
    status = JS_IsException(item) ? -1 : encode_value(e, item);
    JS_FreeValue(ctx, item);
  }
  JS_FreePropertyEnum(ctx, properties, count);
  return status;
}

static int encode_error(GgQjsEncoder* e, JSValueConst value) {
  buffer_u8(&e->buffer, GG_QJS_TAG_ERROR);
  encode_string_property(e, value, "name");
  encode_string_property(e, value, "message");
  encode_string_property(e, value, "stack");
  return 0;
}

static int encode_object(GgQjsEncoder* e, JSValueConst value) {
  GgQjsRuntime* r = e->r;
  JSContext* ctx = r->ctx;
  if (JS_IsFunction(ctx, value) || JS_IsPromise(value)) {
    return encode_handle(e, value);
  }
  void* identity = JS_VALUE_GET_PTR(value);
  for (int i = 0; i < e->depth; ++i) {
    if (e->path[i] == identity) {
      JS_ThrowTypeError(ctx, "cannot convert a cyclic value");
      return -1;
    }
  }
  if (e->depth == GG_QJS_MAX_DEPTH) {
    JS_ThrowRangeError(ctx, "cannot convert a value nested deeper than %d",
                       GG_QJS_MAX_DEPTH);
    return -1;
  }
  e->path[e->depth++] = identity;
  int status;
  int type = JS_GetTypedArrayType(value);
  if (JS_IsError(value)) {
    status = encode_error(e, value);
  } else if (JS_IsArray(value) || type == JS_TYPED_ARRAY_FLOAT16) {
    status = encode_list(e, GG_QJS_TAG_ARRAY, value);
  } else if (JS_IsDate(value)) {
    double time = 0;
    status = JS_ToFloat64(ctx, &time, value);
    buffer_u8(&e->buffer, GG_QJS_TAG_DATE);
    buffer_f64(&e->buffer, time);
  } else if (JS_IsArrayBuffer(value)) {
    status = encode_array_buffer(e, value);
  } else if (type >= 0) {
    status = encode_typed_array(e, value, type);
  } else if (JS_IsMap(value)) {
    status = encode_collection(e, GG_QJS_TAG_MAP, value);
  } else if (JS_IsSet(value)) {
    status = encode_collection(e, GG_QJS_TAG_SET, value);
  } else {
    status = encode_plain_object(e, value);
  }
  e->depth--;
  return status < 0 ? -1 : 0;
}

static int encode_text(GgQjsEncoder* e, uint8_t tag, JSValueConst value) {
  JSContext* ctx = e->r->ctx;
  size_t length = 0;
  const char* text = JS_ToCStringLen(ctx, &length, value);
  if (text == NULL) return -1;
  buffer_u8(&e->buffer, tag);
  buffer_string(&e->buffer, text, length);
  JS_FreeCString(ctx, text);
  return 0;
}

static int encode_value(GgQjsEncoder* e, JSValueConst value) {
  if (!encoder_continues(e)) return -1;
  if (JS_IsUndefined(value)) {
    buffer_u8(&e->buffer, GG_QJS_TAG_UNDEFINED);
  } else if (JS_IsNull(value)) {
    buffer_u8(&e->buffer, GG_QJS_TAG_NULL);
  } else if (JS_IsBool(value)) {
    buffer_u8(&e->buffer,
              JS_VALUE_GET_BOOL(value) ? GG_QJS_TAG_TRUE : GG_QJS_TAG_FALSE);
  } else if (JS_VALUE_GET_TAG(value) == JS_TAG_INT) {
    buffer_u8(&e->buffer, GG_QJS_TAG_INT32);
    int32_t number = JS_VALUE_GET_INT(value);
    buffer_raw(&e->buffer, &number, 4);
  } else if (JS_IsNumber(value)) {
    double number = 0;
    JS_ToFloat64(e->r->ctx, &number, value);
    buffer_u8(&e->buffer, GG_QJS_TAG_FLOAT64);
    buffer_f64(&e->buffer, number);
  } else if (JS_IsString(value)) {
    return encode_text(e, GG_QJS_TAG_STRING, value);
  } else if (JS_IsBigInt(value)) {
    return encode_text(e, GG_QJS_TAG_BIGINT, value);
  } else if (JS_IsObject(value)) {
    return encode_object(e, value);
  } else {
    // A symbol stays in JavaScript.
    return encode_handle(e, value);
  }
  return 0;
}

// The largest encoding of a value: GG_QJS_ENCODING_FACTOR times the memory
// limit, 0 for none without a limit.
static size_t encoding_limit(const GgQjsRuntime* r) {
  if (r->memory_limit > SIZE_MAX / GG_QJS_ENCODING_FACTOR) return SIZE_MAX;
  return r->memory_limit * GG_QJS_ENCODING_FACTOR;
}

static void encoder_init(GgQjsEncoder* e, GgQjsRuntime* r) {
  e->r = r;
  memset(&e->buffer, 0, sizeof(e->buffer));
  e->buffer.limit = encoding_limit(r);
  e->depth = 0;
  e->count = 0;
}

// Encodes `value` as a converted value or as a handle into `out`;
// GG_QJS_OK, or -1 with a pending exception.
static int encode_result(GgQjsRuntime* r, JSValueConst value, int32_t mode,
                         GgQjsBytes* out) {
  GgQjsEncoder e;
  encoder_init(&e, r);
  int status = mode == GG_QJS_HANDLE ? encode_handle(&e, value)
                                     : encode_value(&e, value);
  if (status == 0 && e.buffer.failed) {
    JS_ThrowOutOfMemory(r->ctx);
    status = -1;
  }
  if (status < 0) {
    buffer_free(&e.buffer);
    return -1;
  }
  buffer_take(&e.buffer, out);
  return GG_QJS_OK;
}

// ############################################################################
// Decoding

static JSValue decode_value(GgQjsRuntime* r, GgQjsReader* in, int depth);

static JSValue malformed(JSContext* ctx) {
  return JS_ThrowTypeError(ctx, "gg_quickjs: malformed value");
}

static JSTypedArrayEnum typed_array_type(uint8_t kind) {
  switch (kind) {
    case GG_QJS_BYTES_INT8:
      return JS_TYPED_ARRAY_INT8;
    case GG_QJS_BYTES_UINT8_CLAMPED:
      return JS_TYPED_ARRAY_UINT8C;
    case GG_QJS_BYTES_INT16:
      return JS_TYPED_ARRAY_INT16;
    case GG_QJS_BYTES_UINT16:
      return JS_TYPED_ARRAY_UINT16;
    case GG_QJS_BYTES_INT32:
      return JS_TYPED_ARRAY_INT32;
    case GG_QJS_BYTES_UINT32:
      return JS_TYPED_ARRAY_UINT32;
    case GG_QJS_BYTES_FLOAT32:
      return JS_TYPED_ARRAY_FLOAT32;
    case GG_QJS_BYTES_FLOAT64:
      return JS_TYPED_ARRAY_FLOAT64;
    case GG_QJS_BYTES_BIG_INT64:
      return JS_TYPED_ARRAY_BIG_INT64;
    case GG_QJS_BYTES_BIG_UINT64:
      return JS_TYPED_ARRAY_BIG_UINT64;
    default:
      return JS_TYPED_ARRAY_UINT8;
  }
}

static JSValue decode_bytes(GgQjsRuntime* r, GgQjsReader* in) {
  JSContext* ctx = r->ctx;
  uint8_t kind;
  uint32_t length;
  const uint8_t* data;
  if (!read_u8(in, &kind) || !read_u32(in, &length) ||
      !read_raw(in, length, &data)) {
    return malformed(ctx);
  }
  if (kind == GG_QJS_BYTES_UINT8) {
    return JS_NewUint8ArrayCopy(ctx, data, length);
  }
  JSValue buffer = JS_NewArrayBufferCopy(ctx, data, length);
  if (kind == GG_QJS_BYTES_ARRAY_BUFFER || JS_IsException(buffer)) {
    return buffer;
  }
  JSValue array = JS_NewTypedArray(ctx, 1, &buffer, typed_array_type(kind));
  JS_FreeValue(ctx, buffer);
  return array;
}

// Calls the helper `index` with `argc` values it takes over.
static JSValue call_helper(GgQjsRuntime* r, int index, int argc,
                          JSValue* argv) {
  JSValue result =
      JS_Call(r->ctx, r->helpers[index], JS_UNDEFINED, argc, argv);
  for (int i = 0; i < argc; ++i) JS_FreeValue(r->ctx, argv[i]);
  return result;
}

static JSValue decode_text(GgQjsRuntime* r, GgQjsReader* in) {
  const char* text;
  size_t length;
  if (!read_string(in, &text, &length)) return malformed(r->ctx);
  return JS_NewStringLen(r->ctx, text, length);
}

// Reads `count` values into an array; for a Map, `count` pairs.
static JSValue decode_items(GgQjsRuntime* r, GgQjsReader* in, int depth,
                            bool pairs) {
  JSContext* ctx = r->ctx;
  uint32_t count;
  if (!read_u32(in, &count)) return malformed(ctx);
  JSValue array = JS_NewArray(ctx);
  for (uint32_t i = 0; i < count && !JS_IsException(array); ++i) {
    JSValue item;
    if (pairs) {
      item = JS_NewArray(ctx);
      for (uint32_t j = 0; j < 2 && !JS_IsException(item); ++j) {
        JSValue part = decode_value(r, in, depth + 1);
        if (JS_IsException(part) ||
            JS_DefinePropertyValueUint32(ctx, item, j, part,
                                         JS_PROP_C_W_E) < 0) {
          JS_FreeValue(ctx, item);
          item = JS_EXCEPTION;
        }
      }
    } else {
      item = decode_value(r, in, depth + 1);
    }
    if (JS_IsException(item) ||
        JS_DefinePropertyValueUint32(ctx, array, i, item, JS_PROP_C_W_E) <
            0) {
      JS_FreeValue(ctx, array);
      array = JS_EXCEPTION;
    }
  }
  return array;
}

static JSValue decode_object(GgQjsRuntime* r, GgQjsReader* in, int depth) {
  JSContext* ctx = r->ctx;
  uint32_t count;
  if (!read_u32(in, &count)) return malformed(ctx);
  JSValue object = JS_NewObject(ctx);
  for (uint32_t i = 0; i < count && !JS_IsException(object); ++i) {
    const char* key;
    size_t length;
    if (!read_string(in, &key, &length)) {
      JS_FreeValue(ctx, object);
      return malformed(ctx);
    }
    JSAtom atom = JS_NewAtomLen(ctx, key, length);
    JSValue item = decode_value(r, in, depth + 1);
    if (atom == JS_ATOM_NULL || JS_IsException(item) ||
        JS_DefinePropertyValue(ctx, object, atom, item, JS_PROP_C_W_E) < 0) {
      if (atom == JS_ATOM_NULL) JS_FreeValue(ctx, item);
      JS_FreeValue(ctx, object);
      object = JS_EXCEPTION;
    }
    if (atom != JS_ATOM_NULL) JS_FreeAtom(ctx, atom);
  }
  return object;
}

static JSValue decode_error(GgQjsRuntime* r, GgQjsReader* in) {
  JSContext* ctx = r->ctx;
  JSValue parts[2];
  parts[0] = decode_text(r, in);
  parts[1] = decode_text(r, in);
  JSValue stack = decode_text(r, in);
  JS_FreeValue(ctx, stack);
  if (JS_IsException(parts[0]) || JS_IsException(parts[1]) ||
      JS_IsException(stack)) {
    JS_FreeValue(ctx, parts[0]);
    JS_FreeValue(ctx, parts[1]);
    return JS_EXCEPTION;
  }
  return call_helper(r, GG_QJS_HELPER_ERROR, 2, parts);
}

static JSValue host_trampoline(JSContext* ctx, JSValueConst self, int argc,
                               JSValueConst* argv, int magic,
                               JSValueConst* data);

static JSValue decode_host_function(GgQjsRuntime* r, GgQjsReader* in) {
  JSContext* ctx = r->ctx;
  uint64_t id;
  const char* name;
  size_t name_length;
  uint32_t length;
  if (!read_u64(in, &id) || !read_string(in, &name, &name_length) ||
      !read_u32(in, &length)) {
    return malformed(ctx);
  }
  GgQjsToken* token = (GgQjsToken*)malloc(sizeof(GgQjsToken));
  if (token == NULL) return JS_ThrowOutOfMemory(ctx);
  token->id = (int64_t)id;
  JSValue holder = JS_NewObjectClass(ctx, (int)r->token_class);
  if (JS_IsException(holder)) {
    free(token);
    return holder;
  }
  JS_SetOpaque(holder, token);
  char* cname = (char*)malloc(name_length + 1);
  if (cname == NULL) {
    JS_FreeValue(ctx, holder);
    return JS_ThrowOutOfMemory(ctx);
  }
  memcpy(cname, name, name_length);
  cname[name_length] = 0;
  JSValue function = JS_NewCFunctionData2(ctx, host_trampoline, cname,
                                         (int)length, 0, 1, &holder);
  free(cname);
  JS_FreeValue(ctx, holder);
  return function;
}

static JSValue decode_value(GgQjsRuntime* r, GgQjsReader* in, int depth) {
  JSContext* ctx = r->ctx;
  uint8_t tag;
  if (depth > GG_QJS_MAX_DEPTH) {
    return JS_ThrowRangeError(ctx, "cannot convert a value nested deeper "
                                   "than %d", GG_QJS_MAX_DEPTH);
  }
  if (!read_u8(in, &tag)) return malformed(ctx);
  switch (tag) {
    case GG_QJS_TAG_UNDEFINED:
      return JS_UNDEFINED;
    case GG_QJS_TAG_NULL:
      return JS_NULL;
    case GG_QJS_TAG_FALSE:
      return JS_FALSE;
    case GG_QJS_TAG_TRUE:
      return JS_TRUE;
    case GG_QJS_TAG_INT32: {
      uint32_t number;
      if (!read_u32(in, &number)) return malformed(ctx);
      return JS_NewInt32(ctx, (int32_t)number);
    }
    case GG_QJS_TAG_FLOAT64: {
      double number;
      if (!read_f64(in, &number)) return malformed(ctx);
      return JS_NewFloat64(ctx, number);
    }
    case GG_QJS_TAG_STRING:
      return decode_text(r, in);
    case GG_QJS_TAG_BIGINT: {
      JSValue text = decode_text(r, in);
      if (JS_IsException(text)) return text;
      return call_helper(r, GG_QJS_HELPER_BIGINT, 1, &text);
    }
    case GG_QJS_TAG_ARRAY:
      return decode_items(r, in, depth, false);
    case GG_QJS_TAG_OBJECT:
      return decode_object(r, in, depth);
    case GG_QJS_TAG_DATE: {
      double time;
      if (!read_f64(in, &time)) return malformed(ctx);
      return JS_NewDate(ctx, time);
    }
    case GG_QJS_TAG_BYTES:
      return decode_bytes(r, in);
    case GG_QJS_TAG_ERROR:
      return decode_error(r, in);
    case GG_QJS_TAG_HANDLE: {
      uint8_t kind;
      uint64_t handle;
      if (!read_u8(in, &kind) || !read_u64(in, &handle)) {
        return malformed(ctx);
      }
      return JS_DupValue(ctx, box_value(handle));
    }
    case GG_QJS_TAG_MAP: {
      JSValue entries = decode_items(r, in, depth, true);
      if (JS_IsException(entries)) return entries;
      return call_helper(r, GG_QJS_HELPER_NEW_MAP, 1, &entries);
    }
    case GG_QJS_TAG_SET: {
      JSValue values = decode_items(r, in, depth, false);
      if (JS_IsException(values)) return values;
      return call_helper(r, GG_QJS_HELPER_NEW_SET, 1, &values);
    }
    case GG_QJS_TAG_HOST_FUNCTION:
      return decode_host_function(r, in);
    default:
      return malformed(ctx);
  }
}

static JSValue decode(GgQjsRuntime* r, const uint8_t* data, size_t length) {
  GgQjsReader in = {data, length, 0};
  return decode_value(r, &in, 0);
}

// Reads an encoded array into `*argv`; false with a pending exception.
static bool decode_arguments(GgQjsRuntime* r, const uint8_t* data,
                             size_t length, int* argc, JSValue** argv) {
  JSContext* ctx = r->ctx;
  *argc = 0;
  *argv = NULL;
  JSValue list = decode(r, data, length);
  if (JS_IsException(list)) return false;
  int64_t count = 0;
  if (JS_GetLength(ctx, list, &count) < 0) {
    JS_FreeValue(ctx, list);
    return false;
  }
  *argv = (JSValue*)malloc(sizeof(JSValue) * (size_t)(count > 0 ? count : 1));
  if (*argv == NULL) {
    JS_FreeValue(ctx, list);
    JS_ThrowOutOfMemory(ctx);
    return false;
  }
  for (int64_t i = 0; i < count; ++i) {
    (*argv)[i] = JS_GetPropertyUint32(ctx, list, (uint32_t)i);
  }
  *argc = (int)count;
  JS_FreeValue(ctx, list);
  return true;
}

static void free_arguments(GgQjsRuntime* r, int argc, JSValue* argv) {
  for (int i = 0; i < argc; ++i) JS_FreeValue(r->ctx, argv[i]);
  free(argv);
}

// ############################################################################
// Entering and leaving

static int interrupt_handler(JSRuntime* rt, void* opaque) {
  (void)rt;
  GgQjsRuntime* r = (GgQjsRuntime*)opaque;
  if (r->describing) return 0;
  if (atomic_load(&r->closing) || atomic_load(&r->interrupt_requested)) {
    r->interrupted = true;
    return 1;
  }
  if (r->deadline_ns != 0 && now_ns() > r->deadline_ns) {
    r->interrupted = true;
    r->timed_out = true;
    return 1;
  }
  return 0;
}

static void enter(GgQjsRuntime* r) {
  if (r->depth++ > 0) return;
  JS_UpdateStackTop(r->rt);
  atomic_store(&r->interrupt_requested, 0);
  r->interrupted = false;
  r->timed_out = false;
  r->out_of_memory = false;
  r->deadline_ns = r->timeout_ns > 0 ? now_ns() + r->timeout_ns : 0;
}

// Writes the pending exception into `out`, the reason byte first.
static int32_t describe(GgQjsRuntime* r, GgQjsBytes* out) {
  JSContext* ctx = r->ctx;
  JSValue exception = JS_GetException(ctx);
  uint8_t reason = GG_QJS_THROWN;
  if (r->interrupted) {
    reason = r->timed_out ? GG_QJS_TIMED_OUT : GG_QJS_INTERRUPTED;
  } else if (JS_IsNull(exception) && r->out_of_memory) {
    reason = GG_QJS_OUT_OF_MEMORY;
  }
  // The description may need memory and time that the script used up.
  r->describing = true;
  r->unlimited = true;
  GgQjsEncoder e;
  encoder_init(&e, r);
  buffer_u8(&e.buffer, reason);
  if (encode_value(&e, exception) < 0 || e.buffer.failed) {
    JS_FreeValue(ctx, JS_GetException(ctx));
    // The fallback fits the capacity of the reason byte, also when the
    // value outgrew the limit.
    e.buffer.length = 1;
    e.buffer.failed = e.buffer.data == NULL;
    e.buffer.limit = 0;
    buffer_u8(&e.buffer, GG_QJS_TAG_ERROR);
    buffer_string(&e.buffer, "Error", 5);
    buffer_string(&e.buffer, "the thrown value cannot be converted", 36);
    buffer_string(&e.buffer, "", 0);
  }
  JS_FreeValue(ctx, exception);
  r->describing = false;
  r->unlimited = false;
  if (e.buffer.failed) {
    buffer_free(&e.buffer);
    out->data = NULL;
    out->length = 0;
  } else {
    buffer_take(&e.buffer, out);
  }
  return GG_QJS_EXCEPTION;
}

// Runs the pending jobs; false with a pending exception.
static bool run_jobs(GgQjsRuntime* r) {
  while (JS_IsJobPending(r->rt)) {
    JSContext* job = NULL;
    if (JS_ExecutePendingJob(r->rt, &job) < 0) return false;
  }
  return true;
}

static void report_rejections(GgQjsRuntime* r) {
  while (r->rejected != NULL) {
    GgQjsRejected* rejected = r->rejected;
    r->rejected = rejected->next;
    GgQjsBytes reason = {NULL, 0};
    r->describing = true;
    r->unlimited = true;
    if (encode_result(r, rejected->reason, GG_QJS_CONVERT, &reason) < 0) {
      JS_FreeValue(r->ctx, JS_GetException(r->ctx));
    }
    r->describing = false;
    r->unlimited = false;
    r->rejection(reason.data, reason.length);
    free(reason.data);
    JS_FreeValue(r->ctx, rejected->promise);
    JS_FreeValue(r->ctx, rejected->reason);
    free(rejected);
  }
}

// Ends an entry: describes an exception and, on the outermost entry, runs
// the pending jobs and reports the unhandled rejections.
static int32_t leave(GgQjsRuntime* r, int status, GgQjsBytes* out) {
  int32_t result = status < 0 ? describe(r, out) : GG_QJS_OK;
  if (r->depth == 1) {
    if (!r->interrupted && !run_jobs(r)) {
      if (result == GG_QJS_OK) {
        free(out->data);
        result = describe(r, out);
      } else {
        JS_FreeValue(r->ctx, JS_GetException(r->ctx));
      }
    }
    report_rejections(r);
    r->deadline_ns = 0;
  }
  r->depth--;
  return result;
}

// Compiles a script or a module without the memory limit.
static JSValue compile(GgQjsRuntime* r, const char* code, size_t length,
                       const char* filename, int type) {
  r->unlimited = true;
  JSValue compiled =
      JS_Eval(r->ctx, code, length, filename, type | JS_EVAL_FLAG_COMPILE_ONLY);
  r->unlimited = false;
  return compiled;
}

// ############################################################################
// Callbacks of QuickJS-ng

static JSValue host_trampoline(JSContext* ctx, JSValueConst self, int argc,
                               JSValueConst* argv, int magic,
                               JSValueConst* data) {
  (void)self;
  (void)magic;
  GgQjsRuntime* r = (GgQjsRuntime*)JS_GetContextOpaque(ctx);
  GgQjsToken* token = (GgQjsToken*)JS_GetOpaque(data[0], r->token_class);
  GgQjsEncoder e;
  encoder_init(&e, r);
  buffer_u8(&e.buffer, GG_QJS_TAG_ARRAY);
  buffer_u32(&e.buffer, (uint32_t)argc);
  for (int i = 0; i < argc; ++i) {
    if (encode_value(&e, argv[i]) < 0) {
      buffer_free(&e.buffer);
      return JS_EXCEPTION;
    }
  }
  if (e.buffer.failed) {
    buffer_free(&e.buffer);
    return JS_ThrowOutOfMemory(ctx);
  }
  GgQjsBytes result = {NULL, 0};
  int32_t status =
      r->host_call(token->id, e.buffer.data, e.buffer.length, &result);
  buffer_free(&e.buffer);
  if (result.data == NULL) {
    return JS_ThrowInternalError(ctx, "gg_quickjs: the host function failed");
  }
  JSValue value = decode(r, result.data, result.length);
  gg_qjs_free(result.data);
  if (JS_IsException(value) || status == GG_QJS_OK) return value;
  return JS_Throw(ctx, value);
}

static void token_finalizer(JSRuntime* rt, JSValueConst value) {
  GgQjsRuntime* r = (GgQjsRuntime*)JS_GetRuntimeOpaque(rt);
  GgQjsToken* token = (GgQjsToken*)JS_GetOpaque(value, r->token_class);
  r->host_release(token->id);
  free(token);
}

static JSModuleDef* module_loader(JSContext* ctx, const char* name,
                                  void* opaque) {
  GgQjsRuntime* r = (GgQjsRuntime*)opaque;
  GgQjsBytes source = {NULL, 0};
  int32_t status = r->module_load(name, &source);
  if (status != GG_QJS_OK) {
    if (status == 2 && source.data != NULL) {
      JS_ThrowReferenceError(ctx, "could not load module '%s': %.*s", name,
                             (int)source.length, (const char*)source.data);
    } else {
      JS_ThrowReferenceError(ctx, "could not load module '%s'", name);
    }
    gg_qjs_free(source.data);
    return NULL;
  }
  JSValue module = compile(r, (const char*)source.data, source.length, name,
                           JS_EVAL_TYPE_MODULE);
  gg_qjs_free(source.data);
  if (JS_IsException(module)) return NULL;
  JSModuleDef* definition = (JSModuleDef*)JS_VALUE_GET_PTR(module);
  JSValue meta = JS_GetImportMeta(ctx, definition);
  if (!JS_IsException(meta)) {
    JS_DefinePropertyValueStr(ctx, meta, "url", JS_NewString(ctx, name),
                              JS_PROP_C_W_E);
  }
  JS_FreeValue(ctx, meta);
  JS_FreeValue(ctx, module);
  return definition;
}

static void rejection_tracker(JSContext* ctx, JSValueConst promise,
                              JSValueConst reason, bool is_handled,
                              void* opaque) {
  GgQjsRuntime* r = (GgQjsRuntime*)opaque;
  if (is_handled) {
    GgQjsRejected** link = &r->rejected;
    while (*link != NULL) {
      GgQjsRejected* rejected = *link;
      if (JS_VALUE_GET_PTR(rejected->promise) == JS_VALUE_GET_PTR(promise)) {
        *link = rejected->next;
        JS_FreeValue(ctx, rejected->promise);
        JS_FreeValue(ctx, rejected->reason);
        free(rejected);
        return;
      }
      link = &rejected->next;
    }
    return;
  }
  GgQjsRejected* rejected = (GgQjsRejected*)malloc(sizeof(GgQjsRejected));
  if (rejected == NULL) return;
  rejected->promise = JS_DupValue(ctx, promise);
  rejected->reason = JS_DupValue(ctx, reason);
  rejected->next = NULL;
  GgQjsRejected** last = &r->rejected;
  while (*last != NULL) last = &(*last)->next;
  *last = rejected;
}

// ############################################################################
// Public entry points

const char* gg_qjs_version(void) { return JS_GetVersion(); }

void* gg_qjs_malloc(size_t size) { return malloc(size > 0 ? size : 1); }

void gg_qjs_free(void* block) { free(block); }

static bool create_helpers(GgQjsRuntime* r) {
  JSContext* ctx = r->ctx;
  JSValue helpers = JS_Eval(ctx, kHelpers, sizeof(kHelpers) - 1,
                            "<gg_quickjs>", JS_EVAL_TYPE_GLOBAL);
  if (JS_IsException(helpers)) {
    JS_FreeValue(ctx, JS_GetException(ctx));
    return false;
  }
  bool ok = true;
  for (int i = 0; i < GG_QJS_HELPER_COUNT; ++i) {
    r->helpers[i] = JS_GetPropertyUint32(ctx, helpers, (uint32_t)i);
    ok = ok && JS_IsFunction(ctx, r->helpers[i]);
  }
  JS_FreeValue(ctx, helpers);
  return ok;
}

GgQjsRuntime* gg_qjs_new(int64_t memory_limit, int64_t max_stack_size,
                         int64_t gc_threshold, int64_t timeout_us,
                         GgQjsHostCall host_call,
                         GgQjsHostRelease host_release,
                         GgQjsModuleLoad module_load,
                         GgQjsRejection rejection) {
  GgQjsRuntime* r = (GgQjsRuntime*)calloc(1, sizeof(GgQjsRuntime));
  if (r == NULL) return NULL;
  for (int i = 0; i < GG_QJS_HELPER_COUNT; ++i) r->helpers[i] = JS_UNDEFINED;
  r->host_call = host_call;
  r->host_release = host_release;
  r->module_load = module_load;
  r->rejection = rejection;
  // A timeout beyond a century counts as a century, so that no deadline
  // overflows.
  r->timeout_ns = timeout_us <= 0              ? 0
                  : timeout_us < kMaxTimeoutUs ? timeout_us * 1000
                                               : kMaxTimeoutUs * 1000;
  atomic_init(&r->interrupt_requested, 0);
  atomic_init(&r->closing, 0);
  r->rt = JS_NewRuntime2(&kHeap, r);
  if (r->rt == NULL) {
    free(r);
    return NULL;
  }
  JS_SetRuntimeOpaque(r->rt, r);
  JS_UpdateStackTop(r->rt);
  JS_SetMaxStackSize(r->rt, max_stack_size > 0 ? (size_t)max_stack_size : 0);
  if (gc_threshold > 0) JS_SetGCThreshold(r->rt, (size_t)gc_threshold);
  JS_SetInterruptHandler(r->rt, interrupt_handler, r);
  // Atomics.wait would block the isolate.
  JS_SetCanBlock(r->rt, false);
  JS_SetHostPromiseRejectionTracker(r->rt, rejection_tracker, r);
  JS_SetModuleLoaderFunc(r->rt, NULL, module_loader, r);
  JSClassDef token_class = {"GgQuickjsHostFunction", token_finalizer, NULL,
                            NULL, NULL};
  JS_NewClassID(r->rt, &r->token_class);
  if (JS_NewClass(r->rt, r->token_class, &token_class) < 0) {
    gg_qjs_dispose(r);
    return NULL;
  }
  r->ctx = JS_NewContext(r->rt);
  if (r->ctx != NULL) JS_SetContextOpaque(r->ctx, r);
  if (r->ctx == NULL || !create_helpers(r)) {
    gg_qjs_dispose(r);
    return NULL;
  }
  // The limit applies once the context exists: QuickJS-ng 0.17.0 does not
  // recover from running out of memory inside JS_NewContext. A limit that
  // the runtime itself exceeds fails the creation.
  r->memory_limit = memory_limit <= 0                     ? 0
                    : (uint64_t)memory_limit > SIZE_MAX ? SIZE_MAX
                                                        : (size_t)memory_limit;
  if (r->memory_limit != 0 && r->allocated > r->memory_limit) {
    gg_qjs_dispose(r);
    return NULL;
  }
  return r;
}

void gg_qjs_dispose(GgQjsRuntime* r) {
  while (r->boxes != NULL) box_free(r, r->boxes);
  while (r->rejected != NULL) {
    GgQjsRejected* rejected = r->rejected;
    r->rejected = rejected->next;
    JS_FreeValueRT(r->rt, rejected->promise);
    JS_FreeValueRT(r->rt, rejected->reason);
    free(rejected);
  }
  for (int i = 0; i < GG_QJS_HELPER_COUNT; ++i) {
    JS_FreeValueRT(r->rt, r->helpers[i]);
  }
  if (r->ctx != NULL) JS_FreeContext(r->ctx);
  JS_FreeRuntime(r->rt);
  free(r);
}

void gg_qjs_interrupt(GgQjsRuntime* r) {
  atomic_store(&r->interrupt_requested, 1);
}

void gg_qjs_close(GgQjsRuntime* r) { atomic_store(&r->closing, 1); }

int32_t gg_qjs_eval(GgQjsRuntime* r, const char* code, size_t length,
                    const char* filename, int32_t mode, GgQjsBytes* out) {
  enter(r);
  JSValue compiled = compile(r, code, length, filename, JS_EVAL_TYPE_GLOBAL);
  JSValue value = JS_IsException(compiled) ? JS_EXCEPTION
                                           : JS_EvalFunction(r->ctx, compiled);
  int status = JS_IsException(value) ? -1 : encode_result(r, value, mode, out);
  JS_FreeValue(r->ctx, value);
  return leave(r, status, out);
}

// Evaluates a compiled module and encodes [promise, namespace].
static int evaluate_module(GgQjsEncoder* e, JSValue module) {
  JSContext* ctx = e->r->ctx;
  JSModuleDef* definition = (JSModuleDef*)JS_VALUE_GET_PTR(module);
  JSValue promise = JS_EvalFunction(ctx, module);
  if (JS_IsException(promise)) return -1;
  JSValue space = JS_GetModuleNamespace(ctx, definition);
  int status = encode_handle(e, promise);
  if (status == 0 && !JS_IsException(space)) {
    status = encode_handle(e, space);
  } else {
    status = -1;
  }
  JS_FreeValue(ctx, space);
  JS_FreeValue(ctx, promise);
  return status;
}

static int32_t finish_buffer(GgQjsRuntime* r, int status, GgQjsBuffer* b,
                             GgQjsBytes* out) {
  if (status == 0 && b->failed) {
    JS_ThrowOutOfMemory(r->ctx);
    status = -1;
  }
  if (status < 0) {
    buffer_free(b);
  } else {
    buffer_take(b, out);
  }
  return leave(r, status, out);
}

int32_t gg_qjs_eval_module(GgQjsRuntime* r, const char* code, size_t length,
                           const char* filename, GgQjsBytes* out) {
  enter(r);
  JSContext* ctx = r->ctx;
  GgQjsEncoder e;
  encoder_init(&e, r);
  JSValue module = compile(r, code, length, filename, JS_EVAL_TYPE_MODULE);
  int status = -1;
  if (!JS_IsException(module)) {
    JSValue meta = JS_GetImportMeta(ctx, (JSModuleDef*)JS_VALUE_GET_PTR(module));
    if (!JS_IsException(meta)) {
      JS_DefinePropertyValueStr(ctx, meta, "url", JS_NewString(ctx, filename),
                                JS_PROP_C_W_E);
    }
    JS_FreeValue(ctx, meta);
    buffer_u8(&e.buffer, GG_QJS_TAG_ARRAY);
    buffer_u32(&e.buffer, 2);
    status = evaluate_module(&e, module);
  }
  return finish_buffer(r, status, &e.buffer, out);
}

int32_t gg_qjs_compile(GgQjsRuntime* r, const char* code, size_t length,
                       const char* filename, int32_t module,
                       GgQjsBytes* out) {
  enter(r);
  JSContext* ctx = r->ctx;
  JSValue compiled = compile(r, code, length, filename,
                             module ? JS_EVAL_TYPE_MODULE : JS_EVAL_TYPE_GLOBAL);
  int status = -1;
  if (!JS_IsException(compiled)) {
    size_t size = 0;
    r->unlimited = true;
    uint8_t* bytes = JS_WriteObject(ctx, &size, compiled, JS_WRITE_OBJ_BYTECODE);
    r->unlimited = false;
    if (bytes != NULL) {
      out->data = (uint8_t*)gg_qjs_malloc(size);
      if (out->data != NULL) {
        memcpy(out->data, bytes, size);
        out->length = size;
        status = 0;
      } else {
        JS_ThrowOutOfMemory(ctx);
      }
      js_free(ctx, bytes);
    }
    JS_FreeValue(ctx, compiled);
  }
  return leave(r, status, out);
}

int32_t gg_qjs_eval_bytecode(GgQjsRuntime* r, const uint8_t* bytecode,
                             size_t length, int32_t mode, GgQjsBytes* out) {
  enter(r);
  JSContext* ctx = r->ctx;
  GgQjsEncoder e;
  encoder_init(&e, r);
  r->unlimited = true;
  JSValue compiled = JS_ReadObject(ctx, bytecode, length, JS_READ_OBJ_BYTECODE);
  r->unlimited = false;
  int status = -1;
  if (!JS_IsException(compiled)) {
    bool module = JS_VALUE_GET_TAG(compiled) == JS_TAG_MODULE;
    buffer_u8(&e.buffer, GG_QJS_TAG_ARRAY);
    buffer_u32(&e.buffer, 3);
    buffer_u8(&e.buffer, module ? GG_QJS_TAG_TRUE : GG_QJS_TAG_FALSE);
    if (module) {
      if (JS_ResolveModule(ctx, compiled) < 0) {
        JS_FreeValue(ctx, compiled);
      } else {
        status = evaluate_module(&e, compiled);
      }
    } else {
      JSValue value = JS_EvalFunction(ctx, compiled);
      if (!JS_IsException(value)) {
        status = mode == GG_QJS_HANDLE ? encode_handle(&e, value)
                                       : encode_value(&e, value);
        buffer_u8(&e.buffer, GG_QJS_TAG_UNDEFINED);
      }
      JS_FreeValue(ctx, value);
    }
  }
  return finish_buffer(r, status, &e.buffer, out);
}

// The object `handle` refers to, or the global object for 0; owned.
static JSValue target(GgQjsRuntime* r, uint64_t handle) {
  return handle != 0 ? JS_DupValue(r->ctx, box_value(handle))
                     : JS_GetGlobalObject(r->ctx);
}

int32_t gg_qjs_call(GgQjsRuntime* r, uint64_t function, uint64_t self,
                    const uint8_t* args, size_t length, int32_t mode,
                    GgQjsBytes* out) {
  enter(r);
  JSContext* ctx = r->ctx;
  int argc = 0;
  JSValue* argv = NULL;
  int status = -1;
  if (decode_arguments(r, args, length, &argc, &argv)) {
    // Owned, as a host function may free the handles during the call.
    JSValue callee = target(r, function);
    JSValue receiver = self != 0 ? target(r, self) : JS_UNDEFINED;
    JSValue value = JS_Call(ctx, callee, receiver, argc, argv);
    status = JS_IsException(value) ? -1 : encode_result(r, value, mode, out);
    JS_FreeValue(ctx, value);
    JS_FreeValue(ctx, receiver);
    JS_FreeValue(ctx, callee);
    free_arguments(r, argc, argv);
  }
  return leave(r, status, out);
}

static JSAtom decode_key(GgQjsRuntime* r, const uint8_t* key, size_t length) {
  JSValue value = decode(r, key, length);
  if (JS_IsException(value)) return JS_ATOM_NULL;
  JSAtom atom = JS_ValueToAtom(r->ctx, value);
  JS_FreeValue(r->ctx, value);
  return atom;
}

int32_t gg_qjs_get(GgQjsRuntime* r, uint64_t object, const uint8_t* key,
                   size_t key_length, int32_t mode, GgQjsBytes* out) {
  enter(r);
  JSContext* ctx = r->ctx;
  int status = -1;
  JSAtom atom = decode_key(r, key, key_length);
  if (atom != JS_ATOM_NULL) {
    JSValue owner = target(r, object);
    JSValue value = JS_GetProperty(ctx, owner, atom);
    status = JS_IsException(value) ? -1 : encode_result(r, value, mode, out);
    JS_FreeValue(ctx, value);
    JS_FreeValue(ctx, owner);
    JS_FreeAtom(ctx, atom);
  }
  return leave(r, status, out);
}

int32_t gg_qjs_set(GgQjsRuntime* r, uint64_t object, const uint8_t* key,
                   size_t key_length, const uint8_t* value,
                   size_t value_length, GgQjsBytes* out) {
  enter(r);
  JSContext* ctx = r->ctx;
  int status = -1;
  JSAtom atom = decode_key(r, key, key_length);
  if (atom != JS_ATOM_NULL) {
    JSValue item = decode(r, value, value_length);
    if (!JS_IsException(item)) {
      JSValue owner = target(r, object);
      status = JS_SetProperty(ctx, owner, atom, item) < 0 ? -1 : 0;
      JS_FreeValue(ctx, owner);
    }
    JS_FreeAtom(ctx, atom);
  }
  return leave(r, status, out);
}

int32_t gg_qjs_delete(GgQjsRuntime* r, uint64_t object, const uint8_t* key,
                      size_t key_length, GgQjsBytes* out) {
  enter(r);
  JSContext* ctx = r->ctx;
  int status = -1;
  JSAtom atom = decode_key(r, key, key_length);
  if (atom != JS_ATOM_NULL) {
    JSValue owner = target(r, object);
    status = JS_DeleteProperty(ctx, owner, atom, 0) < 0 ? -1 : 0;
    JS_FreeValue(ctx, owner);
    JS_FreeAtom(ctx, atom);
  }
  return leave(r, status, out);
}

int32_t gg_qjs_keys(GgQjsRuntime* r, uint64_t object, GgQjsBytes* out) {
  enter(r);
  JSContext* ctx = r->ctx;
  JSValue owner = target(r, object);
  JSPropertyEnum* properties = NULL;
  uint32_t count = 0;
  int status = -1;
  GgQjsBuffer b = {NULL, 0, 0, false, 0};
  if (JS_GetOwnPropertyNames(ctx, &properties, &count, owner,
                             JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) == 0) {
    status = 0;
    buffer_u8(&b, GG_QJS_TAG_ARRAY);
    buffer_u32(&b, count);
    for (uint32_t i = 0; i < count && status == 0; ++i) {
      size_t length = 0;
      const char* name = JS_AtomToCStringLen(ctx, &length, properties[i].atom);
      if (name == NULL) {
        status = -1;
      } else {
        buffer_u8(&b, GG_QJS_TAG_STRING);
        buffer_string(&b, name, length);
        JS_FreeCString(ctx, name);
      }
    }
    JS_FreePropertyEnum(ctx, properties, count);
  }
  JS_FreeValue(ctx, owner);
  return finish_buffer(r, status, &b, out);
}

int32_t gg_qjs_to_value(GgQjsRuntime* r, uint64_t handle, GgQjsBytes* out) {
  enter(r);
  // Owned, as a getter may call a host function that frees the handle.
  JSValue value = target(r, handle);
  int status = encode_result(r, value, GG_QJS_CONVERT, out);
  JS_FreeValue(r->ctx, value);
  return leave(r, status, out);
}

void gg_qjs_free_handle(GgQjsRuntime* r, uint64_t handle) {
  box_free(r, (GgQjsBox*)(uintptr_t)handle);
}

int32_t gg_qjs_new_promise(GgQjsRuntime* r, GgQjsBytes* out) {
  enter(r);
  JSContext* ctx = r->ctx;
  GgQjsBuffer b = {NULL, 0, 0, false, 0};
  JSValue functions[2];
  JSValue promise = JS_NewPromiseCapability(ctx, functions);
  int status = -1;
  if (!JS_IsException(promise)) {
    GgQjsEncoder e;
    encoder_init(&e, r);
    buffer_u8(&e.buffer, GG_QJS_TAG_ARRAY);
    buffer_u32(&e.buffer, 3);
    status = encode_handle(&e, promise);
    if (status == 0) status = encode_handle(&e, functions[0]);
    if (status == 0) status = encode_handle(&e, functions[1]);
    b = e.buffer;
    JS_FreeValue(ctx, functions[0]);
    JS_FreeValue(ctx, functions[1]);
    JS_FreeValue(ctx, promise);
  }
  return finish_buffer(r, status, &b, out);
}

int32_t gg_qjs_run_jobs(GgQjsRuntime* r, GgQjsBytes* out) {
  enter(r);
  return leave(r, 0, out);
}

void gg_qjs_memory_usage(GgQjsRuntime* r, int64_t* fields) {
  JSMemoryUsage usage;
  JS_ComputeMemoryUsage(r->rt, &usage);
  fields[0] = usage.malloc_size;
  fields[1] = usage.malloc_count;
  fields[2] = (int64_t)r->memory_limit;
  fields[3] = usage.memory_used_size;
  fields[4] = usage.obj_count;
  fields[5] = usage.str_count;
  fields[6] = usage.js_func_count + usage.c_func_count;
}

void gg_qjs_run_gc(GgQjsRuntime* r) { JS_RunGC(r->rt); }
