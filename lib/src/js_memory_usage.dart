// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// #############################################################################
/// The memory of a runtime, from [JsRuntime.memoryUsage].
final class JsMemoryUsage {
  /// Creates a memory usage.
  ///
  /// - [allocatedBytes] the bytes the runtime holds from the allocator
  /// - [allocations] the number of its allocations
  /// - [limit] the memory limit in bytes, null without a limit
  /// - [usedBytes] the bytes its objects, strings and code use
  /// - [objects] the number of objects
  /// - [strings] the number of strings
  /// - [functions] the number of functions
  const JsMemoryUsage({
    required this.allocatedBytes,
    required this.allocations,
    required this.limit,
    required this.usedBytes,
    required this.objects,
    required this.strings,
    required this.functions,
  });

  /// Creates an example memory usage for tests and docs.
  factory JsMemoryUsage.example({int? allocatedBytes, int? limit}) =>
      JsMemoryUsage(
        allocatedBytes: allocatedBytes ?? 262144,
        allocations: 1830,
        limit: limit,
        usedBytes: 241920,
        objects: 412,
        strings: 960,
        functions: 520,
      );

  // ...........................................................................
  @override
  String toString() =>
      'JsMemoryUsage(allocatedBytes: $allocatedBytes, '
      'allocations: $allocations, limit: $limit, usedBytes: $usedBytes, '
      'objects: $objects, strings: $strings, functions: $functions)';

  // ...........................................................................
  /// The bytes the runtime holds from the allocator.
  final int allocatedBytes;

  /// The number of allocations the runtime holds.
  final int allocations;

  /// The memory limit in bytes; null without a limit.
  final int? limit;

  /// The bytes that objects, strings and code use.
  final int usedBytes;

  /// The number of objects.
  final int objects;

  /// The number of strings.
  final int strings;

  /// The number of functions.
  final int functions;
}
