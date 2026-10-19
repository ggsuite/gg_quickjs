// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:path/path.dart' as p;

// #############################################################################
/// The folders that JavaScript may read and write through the global `fs`
/// object and `import`, granted by [JsRuntimeOptions.fileSystem].
///
/// A path is allowed when it is absolute and, with `..` and every symbolic
/// link resolved, lies in one of the roots: in [readRoots] or [writeRoots]
/// for a read, in [writeRoots] for a write. A root itself is resolved the
/// same way, so a link to a root grants nothing beyond it.
///
/// ```dart
/// final options = JsRuntimeOptions(
///   fileSystem: JsFileSystemAccess(
///     readRoots: ['/data/scripts'],
///     writeRoots: ['/data/output'],
///   ),
/// );
/// ```
final class JsFileSystemAccess {
  /// Creates a file system grant.
  ///
  /// - [readRoots] the folders JavaScript may read
  /// - [writeRoots] the folders JavaScript may read and write
  const JsFileSystemAccess({
    this.readRoots = const [],
    this.writeRoots = const [],
  });

  /// Creates an example grant for tests and docs.
  factory JsFileSystemAccess.example({
    List<String>? readRoots,
    List<String>? writeRoots,
  }) => JsFileSystemAccess(
    readRoots: readRoots ?? [Directory.systemTemp.path],
    writeRoots: writeRoots ?? const [],
  );

  // ...........................................................................
  /// The canonical path of [path] when JavaScript may read it; null
  /// otherwise, also when it does not exist.
  String? resolveRead(String path) {
    final canonical = _canonical(path);
    if (canonical == null) return null;
    return _within(canonical, [...readRoots, ...writeRoots]) ? canonical : null;
  }

  /// The canonical path of [path] when JavaScript may write it; null
  /// otherwise. The parent folder must exist; an existing link is resolved.
  String? resolveWrite(String path) {
    if (!p.isAbsolute(path)) return null;
    final name = p.basename(path);
    if (name.isEmpty || name == '.' || name == '..') return null;
    final existing = _canonical(path);
    // A link that leads nowhere would let a write create its target.
    if (existing == null &&
        FileSystemEntity.typeSync(path, followLinks: false) ==
            FileSystemEntityType.link) {
      return null;
    }
    final parent = _canonical(p.dirname(path));
    final canonical =
        existing ?? (parent == null ? null : p.join(parent, name));
    if (canonical == null) return null;
    return _within(canonical, writeRoots) ? canonical : null;
  }

  // ...........................................................................
  /// The folders that JavaScript may read.
  final List<String> readRoots;

  /// The folders that JavaScript may read and write.
  final List<String> writeRoots;

  // ...........................................................................
  // The path with `..` and every link resolved; null when it is relative or
  // does not exist.
  static String? _canonical(String path) {
    if (!p.isAbsolute(path)) return null;
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) return null;
    return type == FileSystemEntityType.directory
        ? Directory(path).resolveSymbolicLinksSync()
        : File(path).resolveSymbolicLinksSync();
  }

  static bool _within(String canonical, List<String> roots) {
    for (final root in roots) {
      final canonicalRoot = _canonical(root);
      if (canonicalRoot == null) continue;
      if (p.equals(canonical, canonicalRoot) ||
          p.isWithin(canonicalRoot, canonical)) {
        return true;
      }
    }
    return false;
  }
}
