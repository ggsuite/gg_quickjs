// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_quickjs/gg_quickjs.dart';
import 'package:gg_quickjs/src/js_files.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late String readable;
  late String writable;
  late String outside;
  late JsRuntime runtime;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('gg_quickjs_files_');
    readable = p.join(temp.path, 'readable');
    writable = p.join(temp.path, 'writable');
    outside = p.join(temp.path, 'outside');
    for (final dir in [readable, writable, outside]) {
      Directory(dir).createSync();
    }
    File(p.join(readable, 'a.txt')).writeAsStringSync('text of a');
    File(p.join(readable, 'b.bin')).writeAsBytesSync([1, 2, 3]);
    File(p.join(outside, 'secret.txt')).writeAsStringSync('secret');
    Link(p.join(readable, 'escape')).createSync(outside);
    File(p.join(readable, 'lib.js')).writeAsStringSync(
      "import { two } from './nested/two.js'; export const one = 1 + two - 2;",
    );
    Directory(p.join(readable, 'nested')).createSync();
    File(p.join(readable, 'nested', 'two.js'))
        .writeAsStringSync('export const two = 2;');
    File(p.join(outside, 'evil.js')).writeAsStringSync('export const x = 1;');
    runtime = JsRuntime(
      options: JsRuntimeOptions(
        fileSystem: JsFileSystemAccess(
          readRoots: [readable],
          writeRoots: [writable],
        ),
      ),
    );
    runtime
      ..setGlobal('readable', readable)
      ..setGlobal('writable', writable)
      ..setGlobal('outside', outside);
  });

  tearDown(() {
    runtime.dispose();
    temp.deleteSync(recursive: true);
  });

  Future<Object?> run(String code) async =>
      (runtime.evaluate('(async () => { $code })()')! as Future);

  group('fs', () {
    test('reads, lists and checks the files below the roots', () async {
      expect(
        await run(
          'return [await fs.readText(readable + "/a.txt"),\n'
          '  await fs.readBytes(readable + "/b.bin"),\n'
          '  await fs.exists(readable + "/a.txt"),\n'
          '  await fs.exists(readable + "/none"),\n'
          '  await fs.exists(outside + "/secret.txt"),\n'
          '  await fs.exists(42),\n'
          '  await fs.list(readable)];',
        ),
        [
          'text of a',
          [1, 2, 3],
          true,
          false,
          false,
          false,
          ['a.txt', 'b.bin', 'escape', 'lib.js', 'nested'],
        ],
      );
    });

    test('writes and removes files below the write roots', () async {
      await run(
        'await fs.writeText(writable + "/t.txt", "written");\n'
        'await fs.writeBytes(writable + "/b.bin", new Uint8Array([4, 5]));',
      );
      expect(File(p.join(writable, 't.txt')).readAsStringSync(), 'written');
      expect(File(p.join(writable, 'b.bin')).readAsBytesSync(), [4, 5]);
      await run('await fs.remove(writable + "/t.txt");');
      expect(File(p.join(writable, 't.txt')).existsSync(), isFalse);
    });

    test('rejects paths beyond the roots', () async {
      for (final code in [
        'fs.readText(outside + "/secret.txt")',
        'fs.readText(readable + "/../outside/secret.txt")',
        'fs.readText(readable + "/escape/secret.txt")',
        'fs.writeText(readable + "/new.txt", "x")',
        'fs.writeText(outside + "/new.txt", "x")',
        'fs.remove(readable + "/a.txt")',
        'fs.list(outside)',
      ]) {
        await expectLater(
          run('return $code;'),
          throwsA(
            isA<JsError>().having(
              (e) => e.message,
              'message',
              contains('is not allowed'),
            ),
          ),
          reason: code,
        );
      }
      expect(File(p.join(readable, 'a.txt')).existsSync(), isTrue);
    });

    test('rejects arguments of the wrong type', () async {
      await expectLater(
        run('return fs.readText(42);'),
        throwsA(isA<JsTypeError>()),
      );
      await expectLater(
        run('return fs.writeBytes(writable + "/x.bin", "text");'),
        throwsA(isA<JsTypeError>()),
      );
    });
  });

  group('import', () {
    test('loads module files below the read roots', () async {
      final exports = await runtime.evaluateModule(
        "export { one } from './lib.js';",
        sourceUrl: p.join(readable, 'main.js'),
      );
      expect(exports, {'one': 1});
    });

    test('refuses module files beyond the roots', () async {
      await expectLater(
        runtime.evaluateModule(
          "import '../outside/evil.js';",
          sourceUrl: p.join(readable, 'main.js'),
        ),
        throwsA(
          isA<JsReferenceError>().having(
            (e) => e.message,
            'message',
            contains('is not allowed'),
          ),
        ),
      );
    });
  });

  group('readJsModuleFile(name, access)', () {
    test('reads nothing without access or for a relative name', () {
      expect(readJsModuleFile(p.join(readable, 'lib.js'), null), isNull);
      expect(
        readJsModuleFile('lib.js', JsFileSystemAccess(readRoots: [readable])),
        isNull,
      );
    });
  });

  group('without options.fileSystem', () {
    test('fs is absent and files do not import', () async {
      final other = JsRuntime();
      addTearDown(other.dispose);
      expect(other.evaluate('typeof fs'), 'undefined');
      await expectLater(
        other.evaluateModule(
          "import './lib.js';",
          sourceUrl: p.join(readable, 'main.js'),
        ),
        throwsA(isA<JsReferenceError>()),
      );
    });
  });
}
