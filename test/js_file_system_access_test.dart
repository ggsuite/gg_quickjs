// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_quickjs/gg_quickjs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late String readable;
  late String writable;
  late String outside;
  late JsFileSystemAccess access;

  String canonical(String path) => File(path).resolveSymbolicLinksSync();

  setUp(() {
    temp = Directory.systemTemp.createTempSync('gg_quickjs_access_');
    readable = p.join(temp.path, 'readable');
    writable = p.join(temp.path, 'writable');
    outside = p.join(temp.path, 'outside');
    for (final dir in [readable, writable, outside]) {
      Directory(dir).createSync();
    }
    File(p.join(readable, 'a.txt')).writeAsStringSync('a');
    File(p.join(outside, 'secret.txt')).writeAsStringSync('secret');
    Link(p.join(readable, 'file_link'))
        .createSync(p.join(outside, 'secret.txt'));
    Link(p.join(readable, 'dir_link')).createSync(outside);
    Link(p.join(writable, 'dangling')).createSync(p.join(outside, 'new.txt'));
    Link(p.join(temp.path, 'root_link')).createSync(readable);
    access = JsFileSystemAccess(readRoots: [readable], writeRoots: [writable]);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  group('JsFileSystemAccess', () {
    group('resolveRead(path)', () {
      test('allows the files below the roots', () {
        expect(
          access.resolveRead(p.join(readable, 'a.txt')),
          canonical(p.join(readable, 'a.txt')),
        );
        File(p.join(writable, 'w.txt')).writeAsStringSync('w');
        expect(access.resolveRead(p.join(writable, 'w.txt')), isNotNull);
        expect(access.resolveRead(readable), canonical(readable));
      });

      test('refuses escapes, relative and missing paths', () {
        for (final path in [
          p.join(readable, '..', 'outside', 'secret.txt'),
          p.join(readable, 'file_link'),
          p.join(readable, 'dir_link', 'secret.txt'),
          p.join(outside, 'secret.txt'),
          'a.txt',
          p.join(readable, 'missing.txt'),
        ]) {
          expect(access.resolveRead(path), isNull, reason: path);
        }
      });

      test('resolves a root that is a link and skips a missing root', () {
        final linked = JsFileSystemAccess(
          readRoots: [
            p.join(temp.path, 'missing'),
            p.join(temp.path, 'root_link'),
          ],
        );
        expect(
          linked.resolveRead(p.join(readable, 'a.txt')),
          canonical(p.join(readable, 'a.txt')),
        );
      });
    });

    group('resolveWrite(path)', () {
      test('allows new and existing files below the write roots', () {
        expect(
          access.resolveWrite(p.join(writable, 'new.txt')),
          p.join(canonical(writable), 'new.txt'),
        );
        File(p.join(writable, 'old.txt')).writeAsStringSync('old');
        expect(
          access.resolveWrite(p.join(writable, 'old.txt')),
          canonical(p.join(writable, 'old.txt')),
        );
      });

      test('refuses read roots, escapes and odd names', () {
        for (final path in [
          p.join(readable, 'new.txt'),
          p.join(writable, '..', 'outside', 'new.txt'),
          p.join(writable, 'dangling'),
          p.join(writable, '..'),
          p.join(writable, 'missing', 'new.txt'),
          'new.txt',
          '/',
        ]) {
          expect(access.resolveWrite(path), isNull, reason: path);
        }
      });
    });

    group('JsFileSystemAccess.example()', () {
      test('reads the temporary folder', () {
        final example = JsFileSystemAccess.example();
        expect(example.readRoots, [Directory.systemTemp.path]);
        expect(example.writeRoots, isEmpty);
        expect(
          JsFileSystemAccess.example(
            readRoots: [],
            writeRoots: ['/w'],
          ).writeRoots,
          ['/w'],
        );
      });
    });
  });
}
