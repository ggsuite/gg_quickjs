// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_quickjs/gg_quickjs.dart';
import 'package:test/test.dart';

void main() {
  group('JsNetworkAccess', () {
    group('allows(url)', () {
      test('checks scheme, host, port and allowUrl', () {
        final access = JsNetworkAccess(
          allowedHosts: {'example.com', '*.api.dev', 'localhost:8080'},
          allowUrl: (url) => !url.path.startsWith('/admin'),
        );
        final cases = {
          'https://example.com/a': true,
          'http://EXAMPLE.com:81/a': true,
          'https://example.com/admin': false,
          'ftp://example.com/a': false,
          'https://other.com/': false,
          'https://v1.api.dev/': true,
          'https://api.dev/': false,
          'http://localhost:8080/': true,
          'http://localhost:9090/': false,
          'file:///etc/hosts': false,
        };
        cases.forEach((url, allowed) {
          expect(access.allows(Uri.parse(url)), allowed, reason: url);
        });
      });

      test('allows every host for *', () {
        const access = JsNetworkAccess(allowedHosts: {'*'});
        expect(access.allows(Uri.parse('https://anything.org/')), isTrue);
        expect(access.maxRedirects, 5);
      });
    });

    group('JsNetworkAccess.example()', () {
      test('allows example.com', () {
        expect(
          JsNetworkAccess.example().allows(Uri.parse('https://example.com')),
          isTrue,
        );
        expect(JsNetworkAccess.example(allowedHosts: {'a.b'}).allowedHosts, {
          'a.b',
        });
      });
    });
  });
}
