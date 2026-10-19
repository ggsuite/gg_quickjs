// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'js_exception.dart';
import 'js_file_system_access.dart';
import 'js_runtime.dart';

// .............................................................................
/// Installs the global `fs` object of [runtime], whose functions reach only
/// the folders that [access] allows. Each takes an absolute path and returns
/// a promise, rejected for a path that [access] does not allow:
///
/// - `fs.readText(path)`, `fs.readBytes(path)` to a string or a
///   `Uint8Array`
/// - `fs.writeText(path, text)`, `fs.writeBytes(path, bytes)`
/// - `fs.exists(path)`, `fs.list(path)` to the names in a folder
/// - `fs.remove(path)` for a file
void installJsFiles(JsRuntime runtime, JsFileSystemAccess access) {
  String readable(List<Object?> arguments) =>
      _path(arguments, access.resolveRead, 'read');
  String writable(List<Object?> arguments) =>
      _path(arguments, access.resolveWrite, 'write');

  runtime.setGlobal('fs', <String, Object?>{
    'readText': (List<Object?> arguments) async =>
        File(readable(arguments)).readAsString(),
    'readBytes': (List<Object?> arguments) async =>
        File(readable(arguments)).readAsBytes(),
    'writeText': (List<Object?> arguments) async {
      await File(writable(arguments)).writeAsString('${arguments[1]}');
      return null;
    },
    'writeBytes': (List<Object?> arguments) async {
      final bytes = arguments.length > 1 ? arguments[1] : null;
      if (bytes is! TypedData) {
        throw JsTypeError(message: 'fs.writeBytes takes a typed array');
      }
      await File(writable(arguments)).writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      return null;
    },
    'exists': (List<Object?> arguments) async =>
        _argument(arguments) != null &&
        access.resolveRead(_argument(arguments)!) != null,
    'list': (List<Object?> arguments) async =>
        (await Directory(readable(arguments)).list().map(_name).toList())
          ..sort(),
    'remove': (List<Object?> arguments) async {
      await File(writable(arguments)).delete();
      return null;
    },
  });
}

/// The source of the module file [name] when [access] allows to read it;
/// null when [name] is no absolute path or no file system is granted.
String? readJsModuleFile(String name, JsFileSystemAccess? access) {
  if (access == null || !p.isAbsolute(name)) return null;
  final path = access.resolveRead(name);
  if (path == null) {
    throw JsError(message: 'access to $name is not allowed');
  }
  return File(path).readAsStringSync();
}

String _name(FileSystemEntity entity) => p.basename(entity.path);

String? _argument(List<Object?> arguments) {
  final path = arguments.isEmpty ? null : arguments[0];
  return path is String ? path : null;
}

String _path(
  List<Object?> arguments,
  String? Function(String path) resolve,
  String operation,
) {
  final path = _argument(arguments);
  if (path == null) throw JsTypeError(message: 'fs: the path must be a string');
  return resolve(path) ??
      (throw JsError(message: 'fs: $operation access to $path is not allowed'));
}
