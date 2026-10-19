// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';
import 'dart:isolate';

import 'package:record_use/record_use.dart';
import 'package:test/test.dart';

import '../../hook/link.dart';

void main() {
  group('hook/link.dart', () {
    test('keeps the library without recordings', () {
      expect(usesBinding(null), isTrue);
    });

    test('drops the library of an app that calls no member', () {
      expect(usesBinding(Recordings(calls: {}, instances: {})), isFalse);
      const other = Method('speak', Library('package:other/other.dart'));
      expect(
        usesBinding(
          Recordings(
            calls: {
              other: [_call],
            },
            instances: {},
          ),
        ),
        isFalse,
      );
      expect(
        usesBinding(
          Recordings(
            calls: {for (final member in bindingMembers) member: []},
            instances: {},
          ),
        ),
        isFalse,
      );
    });

    for (final member in bindingMembers) {
      test('keeps the library of an app that calls ${member.name}', () {
        expect(
          usesBinding(
            Recordings(
              calls: {
                member: [_call],
              },
              instances: {},
            ),
          ),
          isTrue,
        );
      });
    }

    test('names every function that the package records', () async {
      final file = await Isolate.resolvePackageUri(Uri.parse(nativeLibrary));
      final source = await File.fromUri(file!).readAsString();
      final recorded = [
        for (final match in RegExp(
          r'@RecordUse\(\)\n(?:[\w<>]+ )+(\w+)\(',
        ).allMatches(source))
          Method(match.group(1)!, const Library(nativeLibrary)),
      ];
      expect(recorded, unorderedEquals(bindingMembers));
    });
  });
}

const _call = CallWithArguments(
  positionalArguments: [],
  namedArguments: {},
  loadingUnit: LoadingUnit('main'),
);
