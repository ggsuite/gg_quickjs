// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_quickjs/gg_quickjs.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late String base;
  late JsRuntime runtime;

  Future<void> serve(HttpRequest request) async {
    final response = request.response;
    final body = await utf8.decoder.bind(request).join();
    switch (request.uri.path) {
      case '/text':
        response.headers.set('x-test', 'yes');
        response.write('hello');
      case '/json':
        response.headers.contentType = ContentType.json;
        response.write('{"a": [1, 2]}');
      case '/bytes':
        response.add([0, 1, 255]);
      case '/host':
        response.write(request.headers.value(HttpHeaders.hostHeader));
      case '/large':
        response.add(List.filled(2 * 1024 * 1024, 7));
      case '/echo':
        response.write(
          jsonEncode({
            'method': request.method,
            'header': request.headers.value('x-h'),
            'body': body,
          }),
        );
      case '/redirect':
        await response.redirect(Uri.parse('/text'));
        return;
      case '/see-other':
        await response.redirect(
          Uri.parse('/echo'),
          status: HttpStatus.seeOther,
        );
        return;
      case '/found':
        await response.redirect(Uri.parse('/echo'));
        return;
      case '/temporary':
        await response.redirect(
          Uri.parse('/echo'),
          status: HttpStatus.temporaryRedirect,
        );
        return;
      case '/loop':
        await response.redirect(Uri.parse('/loop'));
        return;
      case '/outside':
        await response.redirect(
          Uri.parse('http://127.0.0.1:${server.port}/text'),
        );
        return;
      default:
        response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  }

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(serve);
    base = 'http://localhost:${server.port}';
    runtime = JsRuntime(
      options: JsRuntimeOptions(
        network: JsNetworkAccess(
          allowedHosts: {'localhost:${server.port}'},
          maxRedirects: 2,
        ),
      ),
    );
    runtime.setGlobal('base', base);
  });

  tearDown(() async {
    runtime.dispose();
    await server.close(force: true);
  });

  Future<Object?> run(String code) async =>
      (runtime.evaluate('(async () => { $code })()')! as Future);

  group('fetch(url, init)', () {
    test('reads a response as text, JSON and bytes', () async {
      expect(
        await run(
          'const r = await fetch(base + "/text");\n'
          'return [r.status, r.ok, r.statusText, r.url, r.redirected,\n'
          '  r.headers.get("X-Test"), r.headers.get("none"),\n'
          '  r.headers.has("x-test"), r.headers.entries().length > 0,\n'
          '  await r.text()];',
        ),
        [
          200,
          true,
          'OK',
          '$base/text',
          false,
          'yes',
          null,
          true,
          true,
          'hello',
        ],
      );
      expect(await run('return (await fetch(base + "/json")).json();'), {
        'a': [1, 2],
      });
      expect(
        await run(
          'const r = await fetch(base + "/bytes");\n'
          'return [new Uint8Array(await r.arrayBuffer()), await r.bytes()];',
        ),
        [
          [0, 1, 255],
          [0, 1, 255],
        ],
      );
      expect(await run('return (await fetch(base + "/none")).ok;'), isFalse);
    });

    test('sends methods, headers and bodies', () async {
      expect(
        await run(
          'const send = async (body) => (await fetch(base + "/echo", '
          '{method: "post", headers: {"x-h": 7}, body})).json();\n'
          'return [await send("text"),\n'
          '  await send(new Uint8Array([104, 105])),\n'
          '  await send(new Uint8Array([111, 107]).buffer), await send(42),\n'
          '  await send(null)];',
        ),
        [
          {'method': 'POST', 'header': '7', 'body': 'text'},
          {'method': 'POST', 'header': '7', 'body': 'hi'},
          {'method': 'POST', 'header': '7', 'body': 'ok'},
          {'method': 'POST', 'header': '7', 'body': '42'},
          {'method': 'POST', 'header': '7', 'body': ''},
        ],
      );
    });

    test('drops the headers that HTTP itself controls', () async {
      expect(
        await run(
          'const r = await fetch(base + "/host", '
          '{headers: {Host: "admin.internal", Connection: "upgrade"}});\n'
          'return r.text();',
        ),
        'localhost:${server.port}',
      );
    });

    test('refuses a response beyond the memory limit', () async {
      final limited = JsRuntime(
        options: JsRuntimeOptions(
          memoryLimit: 1024 * 1024,
          network: JsNetworkAccess(allowedHosts: {'localhost:${server.port}'}),
        ),
      );
      addTearDown(limited.dispose);
      await expectLater(
        limited.evaluate('fetch("$base/large")')! as Future<Object?>,
        throwsA(
          isA<JsRangeError>().having(
            (e) => e.message,
            'message',
            'fetch: the response of $base/large exceeds the memory limit',
          ),
        ),
      );
    });

    test('follows the redirects it allows', () async {
      expect(
        await run(
          'const r = await fetch(base + "/redirect");\n'
          'return [r.redirected, r.url, await r.text()];',
        ),
        [true, '$base/text', 'hello'],
      );
      const post = '{method: "POST", body: "b"}';
      expect(
        await run(
          'return Promise.all(["/see-other", "/found", "/temporary"].map(\n'
          '  async (path) => (await fetch(base + path, $post)).json()));',
        ),
        [
          {'method': 'GET', 'header': null, 'body': ''},
          {'method': 'GET', 'header': null, 'body': ''},
          {'method': 'POST', 'header': null, 'body': 'b'},
        ],
      );
    });

    test('rejects URLs and redirects that are not allowed', () async {
      for (final (path, message) in [
        ('http://127.0.0.1:${server.port}/text', 'is not allowed'),
        ('$base/outside', 'is not allowed'),
        ('$base/loop', 'too many redirects'),
      ]) {
        await expectLater(
          run('return fetch("$path");'),
          throwsA(
            isA<JsTypeError>().having(
              (e) => e.message,
              'message',
              contains(message),
            ),
          ),
          reason: path,
        );
      }
    });
  });

  group('without options.network', () {
    test('fetch is absent', () {
      final other = JsRuntime();
      addTearDown(other.dispose);
      expect(other.evaluate('typeof fetch'), 'undefined');
    });
  });
}
